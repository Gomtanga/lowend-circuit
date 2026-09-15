// WasapiDevices.cpp — device enumeration, loopback/input capture, and render.
//
// Everything here is plain WASAPI shared mode. Exclusive mode is deliberately
// absent: it would take the endpoint away from every other application and turn
// the sample rate into a property of this process instead of the audio engine.
//
// Threading model, because it decides the shape of every function below:
//   - listDevices() and open()/close() are control-thread operations.
//   - acquire()/release()/write() are the audio-thread operations. They call
//     into COM, allocate nothing, take no lock, and log nothing. The only string
//     that is ever built on a failure path is the caller's `error`.
//   - An apartment belongs to a thread, but MTA objects may be called from any
//     MTA thread. The engine relies on that: it activates the clients on the
//     control thread and calls them from the capture/render threads, each of
//     which initializes MTA for itself. So open()/close()/listDevices() only
//     have to guarantee COM for the duration of their own call, and undo the
//     initialization only when they were the ones who made it.

#define INITGUID
// INITGUID makes the SDK generate the PKEY_*/CLSID_* definitions in this
// translation unit instead of leaving them as unresolved externals. Linking
// uuid.lib is not an option here: it defines PKEY_Device_FriendlyName and
// PKEY_Device_ContainerId, but not PKEY_AudioEndpoint_FormFactor and not
// CLSID_MMDeviceEnumerator (checked against this SDK), and mmdevapi.lib is not
// on the link line. Defining them locally costs one read-only GUID blob each and
// keeps the object file self-contained.

#include "AudioEngine/Devices.h"
#include "AudioEngine/DspStage.h"  // maxBlockFrames bounds every internal buffer

#include <windows.h>

// Order matters: mmdeviceapi.h defines DEFINE_PROPERTYKEY (after clearing any
// earlier definition), and functiondiscoverykeys_devpkey.h needs that macro to
// declare PKEY_Device_FriendlyName and friends.
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propsys.h>

#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace lowend::win {
namespace {

// ─── COM lifetime ────────────────────────────────────────────────────
// RAII around CoInitializeEx. RPC_E_CHANGED_MODE means the calling thread
// already lives in another apartment, which is not a failure: the MTA objects
// used here are reachable from any apartment, so the call proceeds and this
// object simply does not own an initialization to undo.
class ComScope {
public:
    ComScope() {
        const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        // S_FALSE means "already initialized on this thread in this mode"; the
        // matching CoUninitialize is still this call's to make.
        owned_ = result == S_OK || result == S_FALSE;
        usable_ = owned_ || result == RPC_E_CHANGED_MODE;
    }

    ~ComScope() {
        if (owned_) {
            CoUninitialize();
        }
    }

    ComScope(const ComScope&) = delete;
    ComScope& operator=(const ComScope&) = delete;

    bool usable() const { return usable_; }

private:
    bool owned_ = false;
    bool usable_ = false;
};

// ─── UTF-8 conversion ────────────────────────────────────────────────
std::string utf8FromWide(const std::wstring& wide) {
    if (wide.empty()) {
        return std::string();
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                           static_cast<int>(wide.size()), nullptr, 0,
                                           nullptr, nullptr);
    if (needed <= 0) {
        return std::string();
    }
    std::string utf8(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), utf8.data(),
                        needed, nullptr, nullptr);
    return utf8;
}

std::wstring wideFromUtf8(const std::string& utf8) {
    if (utf8.empty()) {
        return std::wstring();
    }
    const int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                           static_cast<int>(utf8.size()), nullptr, 0);
    if (needed <= 0) {
        return std::wstring();
    }
    std::wstring wide(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), wide.data(),
                        needed);
    return wide;
}

// ─── Error reporting ─────────────────────────────────────────────────
// Every HRESULT failure carries the raw code plus, when Windows has one, its
// localized system message. The hex code is always present because FormatMessageW
// has no text for the AUDCLNT_* facility, and that code is what a user actually
// needs to look up.
std::string hresultMessage(long result, const char* what) {
    char code[16];
    std::snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(result));

    std::string message(what);
    message += " failed (HRESULT ";
    message += code;
    message += ')';

    LPWSTR systemText = nullptr;
    const DWORD length = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, static_cast<DWORD>(result), MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPWSTR>(&systemText), 0, nullptr);
    if (length != 0 && systemText != nullptr) {
        std::wstring wide(systemText, length);
        LocalFree(systemText);
        // System messages end with CR/LF and padding; trimming keeps a failure
        // on one line in the CLI.
        while (!wide.empty() &&
               (wide.back() == L'\r' || wide.back() == L'\n' || wide.back() == L' ')) {
            wide.pop_back();
        }
        if (!wide.empty()) {
            message += ": ";
            message += utf8FromWide(wide);
        }
    } else if (systemText != nullptr) {
        LocalFree(systemText);
    }
    return message;
}

// ─── Property helpers ────────────────────────────────────────────────
// A failed or unexpected-type property read leaves the output untouched.
// Enumeration continues either way: one unreadable property must not cost the
// user the whole device list.
void readStringProperty(IPropertyStore* store, REFPROPERTYKEY key, std::string& out) {
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(store->GetValue(key, &value))) {
        if (value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
            out = utf8FromWide(value.pwszVal);
        } else if (value.vt == VT_BSTR && value.bstrVal != nullptr) {
            // Defensive: these PKEYs are documented as VT_LPWSTR. wcslen is used
            // rather than SysStringLen so the object file does not add an
            // oleaut32 dependency the link line does not carry.
            out = utf8FromWide(std::wstring(value.bstrVal, std::wcslen(value.bstrVal)));
        }
    }
    PropVariantClear(&value);
}

void readUInt32Property(IPropertyStore* store, REFPROPERTYKEY key, uint32_t& out) {
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(store->GetValue(key, &value)) && value.vt == VT_UI4) {
        out = static_cast<uint32_t>(value.ulVal);
    }
    PropVariantClear(&value);
}

std::string guidToString(const GUID& guid) {
    wchar_t buffer[40] = {};
    if (StringFromGUID2(guid, buffer, 40) == 0) {
        return std::string();
    }
    return utf8FromWide(buffer);
}

std::string containerIdString(IPropertyStore* store) {
    PROPVARIANT value;
    PropVariantInit(&value);
    std::string result;
    if (SUCCEEDED(store->GetValue(PKEY_Device_ContainerId, &value)) && value.vt == VT_CLSID &&
        value.puuid != nullptr) {
        result = guidToString(*value.puuid);
    }
    PropVariantClear(&value);
    return result;
}

// PKEY_AudioEndpoint_FormFactor as a display string. Unknown values are reported
// as "Unknown" rather than dropped so the CLI keeps its columns aligned.
const char* formFactorName(uint32_t formFactor) {
    switch (static_cast<EndpointFormFactor>(formFactor)) {
        case RemoteNetworkDevice: return "Network";
        case Speakers: return "Speakers";
        case LineLevel: return "LineLevel";
        case Headphones: return "Headphones";
        case Microphone: return "Microphone";
        case Headset: return "Headset";
        case Handset: return "Handset";
        case UnknownDigitalPassthrough: return "DigitalPassthrough";
        case SPDIF: return "SPDIF";
        case DigitalAudioDisplayDevice: return "HDMI";
        default: return "Unknown";
    }
}

bool isBluetoothEnumerator(const std::string& enumerator) {
    // The Bluetooth audio stack registers its endpoints under BTHENUM, and the
    // hands-free profile under BTHHFENUM. Both mean a Bluetooth link, which the
    // CLI surfaces because those links change latency and availability whenever
    // the headset sleeps.
    return enumerator == "BTHENUM" || enumerator == "BTHHFENUM";
}

// Case-insensitive ordering for the device list. Written out rather than using
// _stricmp so the comparison is locale-independent: two endpoints must sort the
// same way on every machine.
bool nameLessNoCase(const std::string& a, const std::string& b) {
    const size_t shared = a.size() < b.size() ? a.size() : b.size();
    for (size_t i = 0; i < shared; ++i) {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z') {
            ca = static_cast<char>(ca - 'A' + 'a');
        }
        if (cb >= 'A' && cb <= 'Z') {
            cb = static_cast<char>(cb - 'A' + 'a');
        }
        if (ca != cb) {
            return ca < cb;
        }
    }
    return a.size() < b.size();
}

// ─── Mix format inspection ───────────────────────────────────────────
// The shared-mode mix format is what the audio engine will actually hand over,
// so every conversion decision comes from this structure and never from a
// request we made. WAVE_FORMAT_EXTENSIBLE is reinterpreted only when cbSize
// really covers the extension: GetMixFormat can return a plain WAVEFORMATEX,
// and reading past it would read someone else's memory.
struct MixFormat {
    uint32_t channels = 0;
    uint32_t sampleRate = 0;
    uint32_t bitsPerSample = 0;
    uint32_t validBitsPerSample = 0;
    uint32_t blockAlign = 0;
    bool isFloat = false;
    bool isExtensible = false;
};

MixFormat describeMixFormat(const WAVEFORMATEX* format) {
    MixFormat info;
    if (format == nullptr) {
        return info;
    }
    info.channels = format->nChannels;
    info.sampleRate = format->nSamplesPerSec;
    info.bitsPerSample = format->wBitsPerSample;
    info.blockAlign = format->nBlockAlign;
    info.validBitsPerSample = format->wBitsPerSample;

    const bool extensible = format->wFormatTag == WAVE_FORMAT_EXTENSIBLE;
    // cbSize counts the bytes after WAVEFORMATEX. WAVEFORMATEXTENSIBLE adds
    // Samples(2) + dwChannelMask(4) + SubFormat(16) = 22.
    if (extensible && format->cbSize >= 22) {
        const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        info.isExtensible = true;
        info.validBitsPerSample = extended->Samples.wValidBitsPerSample;
        // A subformat other than PCM/float is treated as PCM at the advertised
        // width. If that width is unusable too, the caller reports an
        // unsupported format instead of producing noise.
        info.isFloat = IsEqualGUID(extended->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    } else {
        info.isFloat = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    }

    if (info.validBitsPerSample == 0) {
        info.validBitsPerSample = info.bitsPerSample;
    }
    return info;
}

// Copies the audio engine's mix format and rewrites only the sample rate,
// leaving channel count, channel mask, valid bits and subformat untouched so the
// stream keeps the endpoint's bit layout and the engine's sample rate converter
// only has to change the rate.
//
// This is the format handed to IAudioClient::Initialize together with
// AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM. Microsoft documents that combination as
// "a channel matrixer and a sample rate converter are inserted as necessary to
// convert between the uncompressed format supplied to IAudioClient::Initialize
// and the audio engine mix format"
// (https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants),
// which is exactly the conversion needed here: the engine, not this code, owns
// resampling.
//
// nAvgBytesPerSec is recomputed from the new rate: it is the only field that is
// a function of the sample rate, and an unchanged value is exactly the kind of
// inconsistency Initialize reports as AUDCLNT_E_UNSUPPORTED_FORMAT.
//
// nBlockAlign is deliberately left exactly as GetMixFormat reported it. It is
// not rate-dependent, and write() derives its interleave stride from
// impl.mix.blockAlign, so recomputing it here could describe a stream the writer
// and the audio engine disagree about. Keeping the original bytes-per-frame
// guarantees the two stay in step for any layout, padded ones included.
// nAvgBytesPerSec = nBlockAlign * nSamplesPerSec holds by definition.
//
// The copy is sized from cbSize rather than from sizeof(WAVEFORMATEXTENSIBLE)
// because GetMixFormat may return a plain, shorter WAVEFORMATEX; reading it as an
// extension would read past the allocation.
std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> cloneFormatAtRate(
    const WAVEFORMATEX* mix, uint32_t sampleRate) {
    if (mix == nullptr || mix->nChannels == 0 || mix->nBlockAlign == 0) {
        return { nullptr, &CoTaskMemFree };
    }
    // An extensible tag whose cbSize does not cover the extension is malformed,
    // and trusting it would build a stream format out of a truncated struct.
    if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE && mix->cbSize < 22) {
        return { nullptr, &CoTaskMemFree };
    }

    const size_t bytes = sizeof(WAVEFORMATEX) + mix->cbSize;
    auto* copy = static_cast<WAVEFORMATEX*>(CoTaskMemAlloc(bytes));
    if (copy == nullptr) {
        return { nullptr, &CoTaskMemFree };
    }
    std::memcpy(copy, mix, bytes);

    copy->nSamplesPerSec = sampleRate;
    // At most 8 channels * 4 bytes * 192000 Hz = 6 MB/s, well inside the 32-bit
    // nAvgBytesPerSec the struct provides.
    copy->nAvgBytesPerSec = copy->nBlockAlign * sampleRate;
    return { copy, &CoTaskMemFree };
}

// Sample layout of the endpoint, decided once per stream rather than per sample.
enum class SampleKind {
    float32,
    pcm16,
    // 24 significant bits left-aligned in a 32-bit container: the layout WASAPI
    // shared mode uses for 24-bit audio.
    pcm24In32,
    pcm32,
    unsupported,
};

// Bytes one sample occupies in the container, derived from the block alignment
// rather than assumed, so a padded or interleaved layout is caught here.
uint32_t containerBytes(const MixFormat& info) {
    if (info.channels == 0) {
        return 0;
    }
    if (info.blockAlign % info.channels != 0) {
        return 0;
    }
    return info.blockAlign / info.channels;
}

SampleKind classifySampleKind(const MixFormat& info) {
    if (info.isFloat) {
        return info.bitsPerSample == 32 ? SampleKind::float32 : SampleKind::unsupported;
    }
    switch (info.bitsPerSample) {
        case 16:
            return containerBytes(info) == 2 ? SampleKind::pcm16 : SampleKind::unsupported;
        case 24:
            // 24-bit PCM is carried in a 32-bit container with the significant
            // bits at the top, so the container must be 4 bytes wide for the
            // shift below to mean anything.
            return info.validBitsPerSample == 24 && containerBytes(info) == 4
                       ? SampleKind::pcm24In32
                       : SampleKind::unsupported;
        case 32:
            // 32-bit PCM that advertises fewer valid bits is left-padded the
            // same way, but it is rare enough that only full-scale 32-bit ints
            // are accepted rather than adding a second shift path.
            return info.validBitsPerSample == 32 && containerBytes(info) == 4
                       ? SampleKind::pcm32
                       : SampleKind::unsupported;
        default:
            return SampleKind::unsupported;
    }
}

// ─── Sample decoding (endpoint -> float) ─────────────────────────────
// memcpy is used instead of a reinterpret_cast+dereference because the packet
// pointer WASAPI hands out is only byte-aligned for the stream, not for the
// element type.
float decodeFloat32(const BYTE* p) {
    float value = 0.0f;
    std::memcpy(&value, p, sizeof(value));
    return value;
}

float decodePcm16(const BYTE* p) {
    int16_t value = 0;
    std::memcpy(&value, p, sizeof(value));
    return static_cast<float>(value) / 32768.0f;
}

float decodePcm24In32(const BYTE* p) {
    int32_t value = 0;
    std::memcpy(&value, p, sizeof(value));
    // The 24 significant bits sit in the high end of the 32-bit container. The
    // low 8 bits are always zero for well-formed data, so an exact division
    // recovers the signed 24-bit value — and unlike a right shift of a negative
    // signed integer, division is fully defined by the standard.
    return static_cast<float>(value / 256) / 8388608.0f;
}

float decodePcm32(const BYTE* p) {
    int32_t value = 0;
    std::memcpy(&value, p, sizeof(value));
    return static_cast<float>(value) / 2147483648.0f;
}

float sanitizeSample(float value) {
    // A non-finite sample would propagate through the whole DSP chain and reach
    // the render side as a denormal storm or a NaN latch, so it is replaced at
    // the device boundary.
    return std::isfinite(value) ? value : 0.0f;
}

template <typename Decode>
void deinterleaveToStereo(const MixFormat& info, const BYTE* data, uint32_t frames,
                          const Decode& decode, float* left, float* right) {
    if (info.channels == 1) {
        // Mono endpoints feed both sides, which is what makes a mono microphone
        // usable as a stereo source without a separate upmix stage.
        for (uint32_t i = 0; i < frames; ++i) {
            const float value = sanitizeSample(decode(data + static_cast<size_t>(i) * info.blockAlign));
            left[i] = value;
            right[i] = value;
        }
        return;
    }
    const uint32_t sampleBytes = containerBytes(info);
    for (uint32_t i = 0; i < frames; ++i) {
        const BYTE* frame = data + static_cast<size_t>(i) * info.blockAlign;
        // Loopback and shared-mode multichannel both put the front L/R pair in
        // channels 0 and 1; anything beyond that is dropped.
        left[i] = sanitizeSample(decode(frame));
        right[i] = sanitizeSample(decode(frame + sampleBytes));
    }
}

void fillSilence(uint32_t frames, float* left, float* right) {
    if (frames == 0) {
        return;
    }
    std::memset(left, 0, sizeof(float) * frames);
    std::memset(right, 0, sizeof(float) * frames);
}

// ─── Sample encoding (float -> endpoint) ─────────────────────────────
void encodeFloat32(BYTE* p, float value) {
    std::memcpy(p, &value, sizeof(value));
}

void encodePcm16(BYTE* p, float value) {
    const int16_t sample = static_cast<int16_t>(value * 32767.0f);
    std::memcpy(p, &sample, sizeof(sample));
}

void encodePcm24In32(BYTE* p, float value) {
    // The input is clamped to [-1, 1] by the caller, so the product fits the
    // 24-bit range and the cast is defined. Multiplying by 256 rather than
    // left-shifting keeps the operation well-defined for negative values.
    const int32_t sample = static_cast<int32_t>(value * 8388607.0f) * 256;
    std::memcpy(p, &sample, sizeof(sample));
}

void encodePcm32(BYTE* p, float value) {
    // The scale is computed in double because 2147483647 is not representable as
    // a float: the nearest float is 2147483648, which would push value == 1.0
    // one past INT32_MAX and make the cast undefined.
    const double scaled = static_cast<double>(value) * 2147483647.0;
    const int32_t sample = static_cast<int32_t>(scaled);
    std::memcpy(p, &sample, sizeof(sample));
}

float clampUnit(float value) {
    // Clamping is required, not cosmetic: casting an out-of-range float to an
    // integer is undefined behaviour, and the DSP chain can overshoot 1.0.
    if (!std::isfinite(value)) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    if (value < -1.0f) {
        return -1.0f;
    }
    return value;
}

template <typename Encode>
void interleaveFromStereo(const MixFormat& info, const float* left, const float* right,
                          uint32_t frames, BYTE* data, const Encode& encode) {
    const uint32_t sampleBytes = containerBytes(info);
    if (info.channels == 1) {
        for (uint32_t i = 0; i < frames; ++i) {
            encode(data + static_cast<size_t>(i) * info.blockAlign,
                   clampUnit((left[i] + right[i]) * 0.5f));
        }
        return;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        BYTE* frame = data + static_cast<size_t>(i) * info.blockAlign;
        encode(frame, clampUnit(left[i]));
        encode(frame + sampleBytes, clampUnit(right[i]));
        // Surround endpoints get silence rather than a copy of the front pair:
        // duplicating it would be interpreted as a real centre/surround signal.
        if (info.channels > 2) {
            std::memset(frame + 2 * sampleBytes, 0,
                        static_cast<size_t>(info.channels - 2) * sampleBytes);
        }
    }
}

// ─── Wake signaling ──────────────────────────────────────────────────
// Manual-reset, owned here: WASAPI stores the handle handed to SetEventHandle
// and signals it from its own threads, but never closes it. Manual reset keeps a
// signal observable until this side decides to park, so a packet announced while
// the previous one was being converted is not lost.
class WakeEvent {
public:
    WakeEvent() = default;
    WakeEvent(const WakeEvent&) = delete;
    WakeEvent& operator=(const WakeEvent&) = delete;

    ~WakeEvent() {
        if (handle_ != nullptr) {
            CloseHandle(handle_);
        }
    }

    bool create() {
        handle_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        return handle_ != nullptr;
    }

    HANDLE handle() const { return handle_; }

    void signal() const {
        if (handle_ != nullptr) {
            SetEvent(handle_);
        }
    }

    void clear() const {
        if (handle_ != nullptr) {
            ResetEvent(handle_);
        }
    }

private:
    HANDLE handle_ = nullptr;
};

// Bounded, allocation-free wait for another thread to leave a section. close()
// uses it so it cannot free a COM client while the audio thread is inside it.
// Yielding rather than spinning hot: the section being waited out is a handful
// of instructions, so this finishes almost immediately even on a busy machine.
void waitForOtherThread(const std::atomic<bool>& flag) {
    while (flag.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }
}

// Timeout used for every event wait. The events are latency hints, not the
// source of truth — packet availability is always re-checked through WASAPI —
// so a missed signal costs at most this long instead of stalling the stream.
constexpr DWORD waitTimeoutMs = 200;

// ─── Failure classification ──────────────────────────────────────────
// The engine decides from this whether reopening the endpoint is worth a try,
// so the raw HRESULT is stored on the failing object and never parsed back out
// of the error string. Mapping it costs a switch over an existing scalar:
// nothing is allocated, no lock is taken and nothing is logged, which is what
// makes it legal in lastError() and on the audio-thread failure paths.
//
// Sources, code by code:
//   AUDCLNT_E_DEVICE_INVALIDATED — "The audio endpoint device has been
//     unplugged, or the audio hardware or associated hardware resources have
//     been reconfigured, disabled, removed, or otherwise made unavailable for
//     use"
//     (https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize).
//     Every IAudioClient / IAudioCaptureClient / IAudioRenderClient method
//     documents it as "the device was removed", and a removal is reversible:
//     replug, reconnect, or the user selecting the endpoint again.
//   AUDCLNT_E_RESOURCES_INVALIDATED — "The stream's resources have been
//     invalidated", documented as thrown when the audio device is removed or
//     the stream is invalidated (IAudioClient::GetService,
//     IAudioClient::IsFormatSupported, IAudioClient::GetStreamLatency). The
//     client object is dead, but the endpoint underneath it can return, so a
//     fresh client over a re-resolved endpoint is a real recovery.
//   AUDCLNT_E_ENDPOINT_CREATE_FAILED — "The method failed to create the audio
//     endpoint for the render or the capture device"
//     (IAudioClient::Initialize). Nothing could be built on the endpoint at
//     all, which is what a device that is disabled, absent, or being
//     reconfigured looks like; all of those states pass.
//   AUDCLNT_E_SERVICE_NOT_RUNNING — "The Windows audio service is not running"
//     (IAudioClient::GetService, GetMixFormat, Start, Stop, Reset, and the rest
//     of the interface). Audiosrv is demand-started, so the next attempt can
//     succeed once it is up again.
//   AUDCLNT_E_UNSUPPORTED_FORMAT, AUDCLNT_E_BUFFER_SIZE_ERROR, E_INVALIDARG,
//     E_POINTER, E_OUTOFMEMORY — the request, the format, or the environment is
//     wrong in a way that repeats identically on the same endpoint; reopening
//     changes none of them.
//   Anything else, including codes a future SDK adds, is fatal. A code this
//     build cannot reason about is not evidence that the device went away, and
//     calling it recoverable would put the engine in a reopen loop that spins a
//     core and holds a device busy forever. Stopping once with the code in the
//     error string is the failure a user can act on.
DeviceError classifyFailure(HRESULT result) {
    switch (result) {
        case S_OK:
            // Not a failure at all: this is the value the object stores after a
            // successful call and after close(), and the engine reads it as
            // "nothing went wrong here".
            return DeviceError::none;

        case AUDCLNT_E_DEVICE_INVALIDATED:
        case AUDCLNT_E_RESOURCES_INVALIDATED:
        case AUDCLNT_E_ENDPOINT_CREATE_FAILED:
        case AUDCLNT_E_SERVICE_NOT_RUNNING:
            return DeviceError::deviceLost;

        case AUDCLNT_E_UNSUPPORTED_FORMAT:
        case AUDCLNT_E_BUFFER_SIZE_ERROR:
        case E_INVALIDARG:
        case E_POINTER:
        case E_OUTOFMEMORY:
            return DeviceError::fatal;

        default:
            break;
    }

    // An endpoint that is absent right now is the case reopening exists for, so
    // it has to stay recoverable. That absence does not come back as an AUDCLNT_*
    // code: IMMDeviceEnumerator::GetDevice reports it as HRESULT_FROM_WIN32(
    // ERROR_NOT_FOUND) (0x80070490), which is what a reopen attempt sees while a
    // headset is unplugged. Measured on this workstation by opening a
    // well-formed id with no device behind it.
    if (result == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
        return DeviceError::deviceLost;
    }

    // Everything still unclassified is fatal. This is deliberately checked after
    // the specific codes rather than folded into them: a code this build cannot
    // reason about is not evidence that the device went away, and calling it
    // recoverable would put the engine in a reopen loop that spins a core and
    // holds a device busy forever.
    return DeviceError::fatal;
}

// ─── Stream latency ──────────────────────────────────────────────────
// Samples IAudioClient::GetStreamLatency() once per open(). The value is "the
// maximum latency of the stream, in 100-nanosecond units ... the latency of the
// stream is the sum of the latencies of the audio engine and the endpoint
// device"
// (https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getstreamlatency),
// which is a different quantity from the buffer period GetDevicePeriod()
// reports: a stream with a small period can still cross a large engine and
// device delay.
//
// GetStreamLatency() is only valid after Initialize() — the documented return for
// a client that has not been initialized is AUDCLNT_E_NOT_INITIALIZED — so every
// caller runs this from open(), after Initialize() has succeeded.
//
// Returning 0.0 is not an error path and stores no failure code. The engine
// reports a latency for the endpoint as a whole, and some virtual, Bluetooth,
// and loopback endpoints report zero or fail the call; none of that keeps the
// stream from carrying audio, so a missing latency must not turn into a refused
// open and must not be classified as a device loss. 0.0 is the documented
// "unknown" value at the accessor.
//
// REFERENCE_TIME is a LONGLONG count of 100 ns units, so the conversion is
// referenceTime / 10000.0 and is exact in double. The sign is checked rather
// than assumed: the accessor promises a duration, and a negative count would
// otherwise be published as a negative latency.
double readStreamLatencyMs(IAudioClient* client) {
    REFERENCE_TIME latency = 0;
    if (FAILED(client->GetStreamLatency(&latency)) || latency <= 0) {
        return 0.0;
    }
    return static_cast<double>(latency) / 10000.0;
}

} // namespace

// ─── Device enumeration ──────────────────────────────────────────────

std::vector<DeviceInfo> listDevices(DataFlow flow, std::string& error) {
    error.clear();
    std::vector<DeviceInfo> devices;

    ComScope com;
    if (!com.usable()) {
        error = "COM could not be initialized on this thread";
        return devices;
    }

    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                      IID_PPV_ARGS(&enumerator));
    if (FAILED(result)) {
        error = hresultMessage(result, "creating the device enumerator");
        return devices;
    }

    const EDataFlow dataFlow = flow == DataFlow::render ? eRender : eCapture;

    ComPtr<IMMDeviceCollection> collection;
    result = enumerator->EnumAudioEndpoints(dataFlow, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(result)) {
        error = hresultMessage(result, "enumerating audio endpoints");
        return devices;
    }

    // The default endpoint is resolved first so its id is known while the list
    // is built. A failure here only means nothing is flagged as default.
    std::string defaultId;
    {
        ComPtr<IMMDevice> defaultDevice;
        // eConsole is the role the engine opens by default, so that is the one
        // the CLI marks.
        if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(dataFlow, eConsole, &defaultDevice))) {
            LPWSTR id = nullptr;
            if (SUCCEEDED(defaultDevice->GetId(&id)) && id != nullptr) {
                defaultId = utf8FromWide(id);
                CoTaskMemFree(id);
            }
        }
    }

    UINT count = 0;
    if (FAILED(collection->GetCount(&count))) {
        error = "the endpoint collection reported no count";
        return devices;
    }

    devices.reserve(count);

    for (UINT index = 0; index < count; ++index) {
        ComPtr<IMMDevice> device;
        if (FAILED(collection->Item(index, &device)) || device == nullptr) {
            continue;
        }

        DeviceInfo info;
        info.loopbackCapable = flow == DataFlow::render;

        LPWSTR id = nullptr;
        if (SUCCEEDED(device->GetId(&id)) && id != nullptr) {
            info.id = utf8FromWide(id);
            CoTaskMemFree(id);
        }
        if (info.id.empty()) {
            // Without an id the endpoint cannot be selected by --device, so the
            // row would be one the user cannot act on.
            continue;
        }
        info.isDefault = !defaultId.empty() && info.id == defaultId;

        ComPtr<IPropertyStore> store;
        if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store))) {
            readStringProperty(store.Get(), PKEY_Device_FriendlyName, info.name);
            info.containerId = containerIdString(store.Get());

            std::string enumeratorName;
            readStringProperty(store.Get(), PKEY_Device_EnumeratorName, enumeratorName);
            // Kept as observed rather than only classified: the routing checks
            // compare it (a root-enumerated device is a software device, so its
            // two endpoints can be one signal path) and --list-devices prints it.
            info.enumeratorName = enumeratorName;
            if (isBluetoothEnumerator(enumeratorName)) {
                // Reported instead of the form factor: a Bluetooth headset and
                // its wired twin share a form factor but behave very
                // differently, and only the enumerator says which one this is.
                info.formFactor = "Bluetooth";
            } else {
                uint32_t formFactor = 0;
                readUInt32Property(store.Get(), PKEY_AudioEndpoint_FormFactor, formFactor);
                info.formFactor = formFactorName(formFactor);
            }
        }

        // The mix format is a per-device property. Failing to read it leaves
        // those fields at zero and keeps the endpoint listed: offering a device
        // whose format is unknown is still more useful than hiding it.
        ComPtr<IAudioClient> client;
        if (SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client))) {
            WAVEFORMATEX* mix = nullptr;
            if (SUCCEEDED(client->GetMixFormat(&mix)) && mix != nullptr) {
                info.mixChannels = mix->nChannels;
                info.mixSampleRate = mix->nSamplesPerSec;
                info.mixBitsPerSample = mix->wBitsPerSample;
                CoTaskMemFree(mix);
            }
        }

        devices.push_back(std::move(info));
    }

    // Default first, then case-insensitively by name, with the id as the final
    // tie-break so the order is stable when two endpoints share a friendly name
    // (common for two identical monitors).
    std::stable_sort(devices.begin(), devices.end(),
                     [](const DeviceInfo& a, const DeviceInfo& b) {
                         if (a.isDefault != b.isDefault) {
                             return a.isDefault;
                         }
                         if (nameLessNoCase(a.name, b.name)) {
                             return true;
                         }
                         if (nameLessNoCase(b.name, a.name)) {
                             return false;
                         }
                         return a.id < b.id;
                     });

    return devices;
}

// ─── Capture ─────────────────────────────────────────────────────────

struct WasapiCapture::Impl {
    // Declared first so it is destroyed LAST: an apartment must stay
    // initialized until every interface pointer obtained inside it has been
    // released. open() used to scope its own ComScope, which uninitialized the
    // apartment on return while these members still held references created
    // under it; releasing them later then called into a torn-down apartment and
    // faulted. It stayed hidden because both front ends initialize COM in their
    // own main(), which kept the count above zero — but a caller that follows
    // only the documented "COM must be initialized" note and never initializes
    // it would crash on teardown instead of failing cleanly.
    ComScope com;

    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> captureClient;

    WakeEvent wake;

    // Resolved endpoint identity, captured at open() so the engine can compare
    // it with the render endpoint even when both were requested as "default".
    // The container and the bus belong to it because two endpoints of one
    // virtual device are different ids on a single signal path.
    EndpointIdentity identity;
    std::string deviceName;

    WasapiFormat format;
    MixFormat mix;
    SampleKind sampleKind = SampleKind::unsupported;

    uint32_t bufferFrames = 0;
    bool loopback = false;
    bool started = false;

    // IAudioClient::GetStreamLatency(), in milliseconds, sampled once by open()
    // after Initialize and never touched by the audio thread. 0.0 means "not
    // known": either the stream is not open, or the engine refused to report a
    // latency. See readStreamLatencyMs() for why the refusal is not an error.
    double streamLatencyMs = 0.0;

    // The HRESULT behind the most recent failure, or S_OK when there is none.
    // open()/close() write it on the control thread and acquire()/release() on
    // the audio thread, where a single scalar store costs neither an allocation
    // nor a lock. lastError() maps it to DeviceError on demand rather than a
    // second field caching the enum, so the code and its classification cannot
    // drift apart. No success code is ever stored, and no failure code is S_OK,
    // so S_OK is unambiguous as the "no failure" value; it is also what
    // clearFailure() restores, which is why a closed object reports none.
    HRESULT failureCode = S_OK;

    // Called on every failure path with the code that caused it.
    void noteFailure(HRESULT result) { failureCode = result; }

    // Called by a successful open()/acquire()/write()/writeSilence() and by
    // close(), so no stale failure is left for the engine to act on.
    void clearFailure() { failureCode = S_OK; }

    // Audio-thread packet state. `acquired` is what keeps release() honest when
    // a caller pairs it with an acquire() that failed. `packetFrames` is the
    // size GetBuffer reported, which is what ReleaseBuffer requires back even
    // when frameCount() clamped the usable part.
    uint32_t frameCount = 0;
    uint32_t packetFrames = 0;
    bool acquired = false;
    bool discontinuity = false;

    // Guards the window between "GetBuffer returned a packet" and "ReleaseBuffer
    // has run" against a concurrent close(). Without it, close() could release
    // the capture client while the audio thread is still reading the buffer
    // WASAPI handed out.
    std::atomic<bool> inAcquire { false };
    std::atomic<bool> closing { false };

    // Preallocated deinterleaved output, sized once at construction; the audio
    // thread only ever writes into it.
    float left[maxBlockFrames] {};
    float right[maxBlockFrames] {};
};

WasapiCapture::WasapiCapture() : impl_(new Impl()) {}

WasapiCapture::~WasapiCapture() {
    close();
    delete impl_;
}

bool WasapiCapture::open(const Options& options, std::string& error) {
    error.clear();
    Impl& impl = *impl_;

    // open() is documented as control-thread only and must not overlap
    // acquire(), so re-opening an open capture is a caller bug rather than
    // something to support; refusing keeps the COM teardown unambiguous.
    if (impl.client != nullptr) {
        error = "capture is already open";
        // E_INVALIDARG stands for "this request is wrong": reopening the device
        // would fail here identically, so it must not be classified as lost.
        impl.noteFailure(E_INVALIDARG);
        return false;
    }

    // A render endpoint can only be captured through loopback: without the flag,
    // GetService(IAudioCaptureClient) fails with AUDCLNT_E_WRONG_ENDPOINT_TYPE.
    // Rejecting the combination here explains the problem instead of surfacing
    // it later as an opaque driver error.
    if (options.flow == DataFlow::render && !options.loopback) {
        error = "capturing a render endpoint requires loopback";
        // E_INVALIDARG for the same reason: the request is what is wrong.
        impl.noteFailure(E_INVALIDARG);
        return false;
    }

    const bool wantLoopback = options.flow == DataFlow::render;

    // The apartment lives in Impl, not in a local: see the member's comment for
    // why the interface pointers must not outlive it.
    if (!impl.com.usable()) {
        error = "COM could not be initialized on this thread";
        // Not an HRESULT failure at all, so E_FAIL stands in for "this thread
        // cannot use COM". It has no case of its own and therefore takes the
        // unknown-code rule: fatal, which is right, because no amount of
        // re-opening the endpoint would give this thread an apartment.
        impl.noteFailure(E_FAIL);
        return false;
    }

    impl.closing.store(false, std::memory_order_release);

    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                      IID_PPV_ARGS(&impl.enumerator));
    if (FAILED(result)) {
        error = hresultMessage(result, "creating the device enumerator");
        impl.noteFailure(result);
        return false;
    }

    const EDataFlow dataFlow = wantLoopback ? eRender : eCapture;

    if (options.deviceId.empty()) {
        result = impl.enumerator->GetDefaultAudioEndpoint(dataFlow, eConsole, &impl.device);
        if (FAILED(result)) {
            error = hresultMessage(result, "opening the default audio endpoint");
            impl.noteFailure(result);
            return false;
        }
    } else {
        const std::wstring wide = wideFromUtf8(options.deviceId);
        if (wide.empty()) {
            error = "the capture device id is not valid UTF-8";
            // A caller-supplied string, not a device state.
            impl.noteFailure(E_INVALIDARG);
            return false;
        }
        result = impl.enumerator->GetDevice(wide.c_str(), &impl.device);
        if (FAILED(result)) {
            error = hresultMessage(result, "opening the requested capture endpoint");
            impl.noteFailure(result);
            return false;
        }
    }

    if (!impl.wake.create()) {
        error = "creating the capture wake event failed";
        // CreateEventW reports through GetLastError(), not an HRESULT, so E_FAIL
        // stands in and takes the unknown-code rule: fatal. A handle this
        // process failed to create is not a device that went away.
        impl.noteFailure(E_FAIL);
        return false;
    }

    {
        LPWSTR id = nullptr;
        if (SUCCEEDED(impl.device->GetId(&id)) && id != nullptr) {
            impl.identity.id = utf8FromWide(id);
            CoTaskMemFree(id);
        }
        ComPtr<IPropertyStore> store;
        if (SUCCEEDED(impl.device->OpenPropertyStore(STGM_READ, &store))) {
            readStringProperty(store.Get(), PKEY_Device_FriendlyName, impl.deviceName);
            // Read while the store is already open: the feedback check runs on the
            // audio thread and must not start a property read of its own.
            impl.identity.containerId = containerIdString(store.Get());
            readStringProperty(store.Get(), PKEY_Device_EnumeratorName,
                               impl.identity.enumeratorName);
        }
    }

    result = impl.device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &impl.client);
    if (FAILED(result)) {
        error = hresultMessage(result, "activating the capture audio client");
        impl.noteFailure(result);
        return false;
    }

    WAVEFORMATEX* mix = nullptr;
    result = impl.client->GetMixFormat(&mix);
    if (FAILED(result) || mix == nullptr) {
        if (mix != nullptr) {
            CoTaskMemFree(mix);
        }
        error = hresultMessage(result, "reading the capture mix format");
        // A failure with no HRESULT of its own (SUCCEEDED but a null format)
        // is reported as E_POINTER, which classifies as fatal: the endpoint
        // answered, so this is not a device that went away.
        impl.noteFailure(FAILED(result) ? result : E_POINTER);
        return false;
    }

    impl.mix = describeMixFormat(mix);
    impl.sampleKind = classifySampleKind(impl.mix);
    impl.format.channels = impl.mix.channels;
    impl.format.sampleRate = impl.mix.sampleRate;
    impl.format.bitsPerSample = impl.mix.bitsPerSample;

    if (impl.sampleKind == SampleKind::unsupported) {
        CoTaskMemFree(mix);
        error = "the capture endpoint uses an unsupported sample format";
        // The endpoint is present and answered GetMixFormat, but its layout is
        // one this code cannot decode. Reopening would return the same format.
        impl.noteFailure(AUDCLNT_E_UNSUPPORTED_FORMAT);
        return false;
    }

    DWORD streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    if (wantLoopback) {
        // Loopback is legal only on a render endpoint (else
        // AUDCLNT_E_WRONG_ENDPOINT_TYPE) and only in shared mode (else
        // E_INVALIDARG). Event-driven loopback has been reliable since Windows
        // 10 1703, which is the oldest target of this port; earlier builds
        // needed a render stream to pump the capture events.
        streamFlags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
    }

    uint32_t bufferMs = options.bufferMs;
    if (bufferMs == 0) {
        bufferMs = 20;  // matches the engine's default period
    }
    // REFERENCE_TIME counts 100 ns units.
    const REFERENCE_TIME duration = static_cast<REFERENCE_TIME>(bufferMs) * 10000;

    // Shared mode: periodicity must be 0. A non-zero value here is exactly what
    // produces AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL. The format passed in is
    // the one GetMixFormat returned — handing back a synthesized copy, however
    // identical it looks, risks AUDCLNT_E_UNSUPPORTED_FORMAT.
    result = impl.client->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags, duration, 0, mix,
                                     nullptr);
    CoTaskMemFree(mix);
    mix = nullptr;
    if (FAILED(result)) {
        error = hresultMessage(result, "initializing the shared-mode capture stream");
        impl.noteFailure(result);
        return false;
    }

    // SetEventHandle is only legal after Initialize, so it comes here rather
    // than before the call.
    result = impl.client->SetEventHandle(impl.wake.handle());
    if (FAILED(result)) {
        error = hresultMessage(result, "registering the capture wake event");
        impl.noteFailure(result);
        return false;
    }

    result = impl.client->GetService(IID_PPV_ARGS(&impl.captureClient));
    if (FAILED(result)) {
        error = hresultMessage(result, "obtaining the capture client");
        impl.noteFailure(result);
        return false;
    }

    UINT32 frames = 0;
    result = impl.client->GetBufferSize(&frames);
    if (FAILED(result)) {
        error = "the capture client reported no buffer size";
        // The code is kept even though the message does not carry it: the
        // classification is what the engine acts on.
        impl.noteFailure(result);
        return false;
    }
    impl.bufferFrames = frames;
    impl.loopback = wantLoopback;
    impl.frameCount = 0;
    impl.packetFrames = 0;
    impl.acquired = false;
    impl.discontinuity = false;

    result = impl.client->Start();
    if (FAILED(result)) {
        error = hresultMessage(result, "starting the capture stream");
        impl.noteFailure(result);
        return false;
    }
    impl.started = true;

    // Sampled once here: GetStreamLatency() is only meaningful on an initialized
    // client, and by now both Initialize() and Start() have succeeded. It is read
    // on the control thread and only ever read by the control thread afterwards
    // (see streamLatencyMs()), so the audio path never sees this field. A 0.0
    // result is "the engine did not report a latency", not a failure.
    impl.streamLatencyMs = readStreamLatencyMs(impl.client.Get());

    // The stream is up, so nothing is left to report: this is what makes a
    // reopen after a deviceLost attempt start from a clean classification.
    impl.clearFailure();
    return true;
}

void WasapiCapture::close() {
    Impl& impl = *impl_;
    if (impl.client == nullptr) {
        // Also the path taken by a second close() and by the destructor of an
        // object that never opened. The classification is cleared here too: a
        // failed open() leaves the client null, and a closed object must not
        // keep reporting that failure through lastError().
        impl.clearFailure();
        return;
    }

    // Wake a thread parked in acquire() first, then wait for it to leave. The
    // order matters: acquire() may already hold a packet, and releasing the
    // capture client under it would be a use-after-free.
    impl.closing.store(true, std::memory_order_release);
    impl.wake.signal();
    waitForOtherThread(impl.inAcquire);

    if (impl.started) {
        // A failure is ignored deliberately: Stop() only fails for a stream that
        // was never started, which cannot happen here, and every object is about
        // to be released regardless.
        impl.client->Stop();
        impl.started = false;
    }
    // Drops any buffered data so a later open() cannot inherit it.
    impl.client->Reset();

    impl.captureClient.Reset();
    impl.client.Reset();
    impl.device.Reset();
    impl.enumerator.Reset();

    impl.identity = EndpointIdentity();
    impl.deviceName.clear();
    impl.bufferFrames = 0;
    impl.loopback = false;
    impl.frameCount = 0;
    impl.packetFrames = 0;
    impl.acquired = false;
    impl.discontinuity = false;
    impl.format = WasapiFormat();
    // The latency belonged to the stream that was just torn down. Keeping it
    // would report a property of a client that no longer exists.
    impl.streamLatencyMs = 0.0;

    // A closed stream has no failure to report. Leaving the last one set would
    // make the engine treat the next unrelated false return — an orderly stop,
    // for instance — as that stale device error.
    impl.clearFailure();
}

bool WasapiCapture::isOpen() const {
    return impl_->client != nullptr;
}

const WasapiFormat& WasapiCapture::format() const {
    return impl_->format;
}

uint32_t WasapiCapture::bufferFrames() const {
    return impl_->bufferFrames;
}

double WasapiCapture::streamLatencyMs() const {
    return impl_->streamLatencyMs;
}

bool WasapiCapture::isLoopback() const {
    return impl_->loopback;
}

const std::string& WasapiCapture::openedDeviceId() const {
    return impl_->identity.id;
}

const std::string& WasapiCapture::openedDeviceName() const {
    return impl_->deviceName;
}

const EndpointIdentity& WasapiCapture::openedIdentity() const {
    return impl_->identity;
}

DeviceError WasapiCapture::lastError() const {
    return classifyFailure(impl_->failureCode);
}

bool WasapiCapture::acquire(std::string* error) {
    Impl& impl = *impl_;

    // A packet from an earlier acquire() is dropped here. The contract pairs
    // acquire() with release(); tolerating a second acquire() without one would
    // leak a packet and desynchronize the stream.
    release();

    // Checked first: a close() that already released the client is an orderly
    // stop, not the caller using the object wrong. Testing the client first
    // would report that race as a broken request, which the engine would treat
    // as fatal.
    if (impl.closing.load(std::memory_order_acquire)) {
        // Deliberately unclassified: the engine decides between "device failed"
        // and "orderly stop" from exactly this distinction, so DeviceError::none
        // has to survive here. clearFailure() keeps an earlier failure from
        // being mistaken for this return.
        impl.clearFailure();
        return false;
    }
    if (impl.captureClient == nullptr) {
        if (error != nullptr) {
            *error = "capture is not open";
        }
        // The caller used the object wrong rather than losing a device.
        impl.noteFailure(E_INVALIDARG);
        return false;
    }

    impl.inAcquire.store(true, std::memory_order_release);

    // Clears the in-flight flag on every exit path, so close() is never left
    // waiting on a thread that has already moved on.
    struct InFlightGuard {
        std::atomic<bool>& flag;
        ~InFlightGuard() { flag.store(false, std::memory_order_release); }
    } guard { impl.inAcquire };

    for (;;) {
        if (impl.closing.load(std::memory_order_acquire)) {
            // close() ran on another thread. Reporting the stop through the
            // return value rather than `error` keeps an orderly shutdown out of
            // the engine's device-error accounting.
            impl.clearFailure();
            return false;
        }

        // Packet availability is polled from WASAPI and the event is only a
        // latency hint, so a lost signal costs one timeout instead of a stalled
        // stream. The poll is what makes AUDCLNT_S_BUFFER_EMPTY a normal outcome.
        UINT32 nextPacket = 0;
        const HRESULT nextResult = impl.captureClient->GetNextPacketSize(&nextPacket);
        if (FAILED(nextResult)) {
            if (error != nullptr) {
                *error = hresultMessage(nextResult, "querying the next capture packet");
            }
            impl.noteFailure(nextResult);
            return false;
        }
        if (nextPacket == 0) {
            impl.wake.clear();
            const DWORD waitResult = WaitForSingleObject(impl.wake.handle(), waitTimeoutMs);
            if (waitResult == WAIT_FAILED) {
                if (error != nullptr) {
                    *error = "waiting for the capture event failed";
                }
                // WaitForSingleObject reports through GetLastError(), not an
                // HRESULT. A failed wait on a handle this object created and
                // still owns is not a device that went away, so it is fatal.
                impl.noteFailure(E_FAIL);
                return false;
            }
            continue;
        }

        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        const HRESULT result =
            impl.captureClient->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (result == AUDCLNT_S_BUFFER_EMPTY) {
            // S_FALSE: the packet was consumed between the size query and here.
            // Normal, and the reason this is a loop.
            continue;
        }
        if (FAILED(result)) {
            if (error != nullptr) {
                *error = hresultMessage(result, "reading a capture packet");
            }
            impl.noteFailure(result);
            return false;
        }

        impl.discontinuity = (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0;

        // The whole packet is released, never part of it: ReleaseBuffer rejects
        // any NumFramesRead other than the packet size or 0 with
        // AUDCLNT_E_INVALID_SIZE. So the clamp below limits only what the caller
        // sees through frameCount(); the surplus is handed back to WASAPI here.
        impl.packetFrames = frames;
        const uint32_t usable = frames > maxBlockFrames ? maxBlockFrames : frames;

        if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
            // Windows announcing silence without data: the buffer must not be
            // read, and the packet's frames are still counted as delivered.
            fillSilence(usable, impl.left, impl.right);
        } else {
            switch (impl.sampleKind) {
                case SampleKind::float32:
                    deinterleaveToStereo(impl.mix, data, usable, decodeFloat32, impl.left,
                                         impl.right);
                    break;
                case SampleKind::pcm16:
                    deinterleaveToStereo(impl.mix, data, usable, decodePcm16, impl.left,
                                         impl.right);
                    break;
                case SampleKind::pcm24In32:
                    deinterleaveToStereo(impl.mix, data, usable, decodePcm24In32, impl.left,
                                         impl.right);
                    break;
                case SampleKind::pcm32:
                    deinterleaveToStereo(impl.mix, data, usable, decodePcm32, impl.left,
                                         impl.right);
                    break;
                case SampleKind::unsupported:
                default:
                    fillSilence(usable, impl.left, impl.right);
                    break;
            }
        }

        impl.frameCount = usable;
        impl.acquired = true;
        // close() may have arrived while the packet was being converted. The
        // packet is released here so WASAPI is not left holding it, and the
        // caller is told the stream stopped rather than handed a buffer that is
        // about to be torn down.
        if (impl.closing.load(std::memory_order_acquire)) {
            release();
            impl.clearFailure();
            return false;
        }

        // A delivered packet is the success this accessor describes: whatever
        // failed before has now been superseded by a working stream.
        impl.clearFailure();
        return true;
    }
}

void WasapiCapture::release() {
    Impl& impl = *impl_;
    if (!impl.acquired) {
        return;
    }
    impl.acquired = false;
    if (impl.captureClient != nullptr && impl.packetFrames != 0) {
        // The full packet size, not the clamped frameCount(): ReleaseBuffer
        // requires either the exact packet size or 0 and rejects anything else
        // with AUDCLNT_E_INVALID_SIZE. A packet larger than maxBlockFrames was
        // still consumed in full, so all of it goes back.
        const HRESULT result = impl.captureClient->ReleaseBuffer(impl.packetFrames);
        if (FAILED(result)) {
            // Classified like every other failure, but no message is built:
            // release() has nowhere to put one and the audio thread must not
            // allocate. The code and its classification are what the caller
            // reads through lastError().
            impl.noteFailure(result);
        }
    }
    impl.frameCount = 0;
    impl.packetFrames = 0;
}

uint32_t WasapiCapture::frameCount() const {
    return impl_->frameCount;
}

const float* WasapiCapture::left() const {
    return impl_->left;
}

const float* WasapiCapture::right() const {
    return impl_->right;
}

bool WasapiCapture::isDiscontinuity() const {
    return impl_->discontinuity;
}

// ─── Render ──────────────────────────────────────────────────────────

struct WasapiRender::Impl {
    // First, so it is destroyed last: the apartment has to outlive every
    // interface pointer created inside it. See WasapiCapture::Impl for the fault
    // this ordering prevents.
    ComScope com;

    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioRenderClient> renderClient;

    WakeEvent wake;

    // Resolved endpoint identity; see the capture Impl for why the container and
    // the enumerator bus are part of it rather than looked up later.
    EndpointIdentity identity;
    std::string deviceName;

    WasapiFormat format;
    MixFormat mix;
    SampleKind sampleKind = SampleKind::unsupported;

    uint32_t bufferFrames = 0;
    double periodMs = 0.0;
    bool started = false;

    // See the capture Impl: a control-thread value sampled once by open(), and
    // 0.0 whenever the stream is closed or the engine did not report a latency.
    double streamLatencyMs = 0.0;

    // Set by requestStop() from any thread and read by write() while it waits,
    // and read again by close() before the COM objects are released.
    std::atomic<bool> stopRequested { false };
    std::atomic<bool> writeInFlight { false };

    // The HRESULT behind the most recent failure, or S_OK when there is none;
    // see the capture Impl for why this is one scalar and why it is cleared.
    HRESULT failureCode = S_OK;

    // Called on every failure path with the code that caused it.
    void noteFailure(HRESULT result) { failureCode = result; }

    // Called by a successful open()/write()/writeSilence() and by close().
    void clearFailure() { failureCode = S_OK; }
};

WasapiRender::WasapiRender() : impl_(new Impl()) {}

WasapiRender::~WasapiRender() {
    close();
    delete impl_;
}

bool WasapiRender::open(const Options& options, std::string& error) {
    error.clear();
    Impl& impl = *impl_;

    if (impl.client != nullptr) {
        error = "render is already open";
        // E_INVALIDARG stands for "this request is wrong": reopening the device
        // would fail here identically, so it must not be classified as lost.
        impl.noteFailure(E_INVALIDARG);
        return false;
    }

    // See the capture path: the apartment lives in Impl so the interface
    // pointers it produced cannot outlive it.
    if (!impl.com.usable()) {
        error = "COM could not be initialized on this thread";
        // See the capture path: E_FAIL is not an HRESULT this call produced, and
        // the unknown-code rule is again the right answer.
        impl.noteFailure(E_FAIL);
        return false;
    }

    // A stop request belongs to one run of the engine, not to the object.
    // Clearing it here is what makes stop() followed by a later start() work:
    // otherwise the first write() of the new run would return immediately.
    impl.stopRequested.store(false, std::memory_order_release);

    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                      IID_PPV_ARGS(&impl.enumerator));
    if (FAILED(result)) {
        error = hresultMessage(result, "creating the device enumerator");
        impl.noteFailure(result);
        return false;
    }

    if (options.deviceId.empty()) {
        result = impl.enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &impl.device);
        if (FAILED(result)) {
            error = hresultMessage(result, "opening the default render endpoint");
            impl.noteFailure(result);
            return false;
        }
    } else {
        const std::wstring wide = wideFromUtf8(options.deviceId);
        if (wide.empty()) {
            error = "the render device id is not valid UTF-8";
            // A caller-supplied string, not a device state.
            impl.noteFailure(E_INVALIDARG);
            return false;
        }
        result = impl.enumerator->GetDevice(wide.c_str(), &impl.device);
        if (FAILED(result)) {
            error = hresultMessage(result, "opening the requested render endpoint");
            impl.noteFailure(result);
            return false;
        }
    }

    if (!impl.wake.create()) {
        error = "creating the render wake event failed";
        // See the capture path: CreateEventW reports through GetLastError(), so
        // E_FAIL stands in and takes the unknown-code rule.
        impl.noteFailure(E_FAIL);
        return false;
    }

    {
        LPWSTR id = nullptr;
        if (SUCCEEDED(impl.device->GetId(&id)) && id != nullptr) {
            impl.identity.id = utf8FromWide(id);
            CoTaskMemFree(id);
        }
        ComPtr<IPropertyStore> store;
        if (SUCCEEDED(impl.device->OpenPropertyStore(STGM_READ, &store))) {
            readStringProperty(store.Get(), PKEY_Device_FriendlyName, impl.deviceName);
            // Read while the store is already open: the feedback check runs on the
            // audio thread and must not start a property read of its own.
            impl.identity.containerId = containerIdString(store.Get());
            readStringProperty(store.Get(), PKEY_Device_EnumeratorName,
                               impl.identity.enumeratorName);
        }
    }

    result = impl.device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &impl.client);
    if (FAILED(result)) {
        error = hresultMessage(result, "activating the render audio client");
        impl.noteFailure(result);
        return false;
    }

    WAVEFORMATEX* mixRaw = nullptr;
    result = impl.client->GetMixFormat(&mixRaw);
    // GetMixFormat hands back a CoTaskMemAlloc'd block that the caller owns.
    // Wrapping it before the null check means every exit path below releases it,
    // including a failure that left a partially filled block behind.
    const std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> mix(mixRaw, &CoTaskMemFree);
    if (FAILED(result) || mix == nullptr) {
        error = hresultMessage(result, "reading the render mix format");
        // See the capture path: a null format with a success code is reported as
        // E_POINTER, which classifies as fatal because the endpoint answered.
        impl.noteFailure(FAILED(result) ? result : E_POINTER);
        return false;
    }

    impl.mix = describeMixFormat(mix.get());
    impl.sampleKind = classifySampleKind(impl.mix);

    if (impl.sampleKind == SampleKind::unsupported) {
        error = "the render endpoint uses an unsupported sample format";
        // The endpoint is present and answered; its layout is the problem.
        impl.noteFailure(AUDCLNT_E_UNSUPPORTED_FORMAT);
        return false;
    }

    uint32_t bufferMs = options.bufferMs;
    if (bufferMs == 0) {
        bufferMs = 20;
    }
    const REFERENCE_TIME duration = static_cast<REFERENCE_TIME>(bufferMs) * 10000;

    // Stream rate: the rate of the samples this client hands over, which is the
    // rate format() reports. It differs from the endpoint's mix rate only when a
    // conversion was requested, and in that case the audio engine performs it.
    //
    // Why this is done here instead of resampling in this process:
    //   - AUTOCONVERTPCM is Microsoft's documented converter, not a hand-rolled
    //     one: "a channel matrixer and a sample rate converter are inserted as
    //     necessary to convert between the uncompressed format supplied to
    //     IAudioClient::Initialize and the audio engine mix format"
    //     (https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants).
    //   - SRC_DEFAULT_QUALITY is requested on purpose. The same page documents it
    //     as "a sample rate converter with better quality than the default
    //     conversion but with a higher performance cost ... if the audio is
    //     ultimately intended to be heard by humans", which is what this engine
    //     produces. The default converter is for meter feeds and silence pumps.
    //   - Quality is not traded away elsewhere: the DSP chain still runs at the
    //     capture device's own rate and this engine converts nothing itself, so
    //     the render side is the only place a conversion happens and it happens
    //     once. Capture stays untouched, so what a loopback stream sees is the
    //     endpoint's original samples.
    //
    // The requested rate is deliberately not applied when it equals the mix rate:
    // the engine would insert a converter between two identical formats, paying
    // for a converter that cannot improve anything, and the plain mix-format
    // request is the combination WASAPI is best tested against.
    uint32_t streamRate = impl.mix.sampleRate;
    DWORD streamFlags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    const WAVEFORMATEX* streamFormat = mix.get();
    std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> converted(nullptr, &CoTaskMemFree);

    if (options.requestedSampleRate != 0 && options.requestedSampleRate != impl.mix.sampleRate) {
        converted = cloneFormatAtRate(mix.get(), options.requestedSampleRate);
        if (converted == nullptr) {
            error = "building the converted render stream format failed";
            // A CoTaskMemAlloc failure or a malformed mix format; both repeat on
            // the same endpoint.
            impl.noteFailure(E_OUTOFMEMORY);
            return false;
        }
        streamFormat = converted.get();
        streamRate = options.requestedSampleRate;
        streamFlags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    }

    // format() describes the stream this client accepts, so it is filled in once
    // the stream format is settled rather than twice. channels and bitsPerSample
    // come from the mix format because the rate is the only field a conversion
    // request changes.
    //
    // The rate reported is the stream rate, not the endpoint's mix rate. The
    // engine compares this against the capture format to decide whether it can
    // run, and what write() accepts is the stream format — reporting the mix rate
    // here would make a working combination look like a mismatch and prepare the
    // DSP at a rate its samples are not at.
    impl.format.channels = impl.mix.channels;
    impl.format.sampleRate = streamRate;
    impl.format.bitsPerSample = impl.mix.bitsPerSample;

    // Render never takes the loopback flag, and shared mode keeps periodicity at
    // zero for the same reason as the capture stream. hnsBufferDuration is
    // unchanged whether or not a conversion happens: it is a duration, and the
    // engine sizes the buffer from the stream format that was passed with it.
    result = impl.client->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags, duration, 0,
                                     streamFormat, nullptr);
    if (FAILED(result)) {
        error = hresultMessage(result, "initializing the shared-mode render stream");
        impl.noteFailure(result);
        return false;
    }

    // SetEventHandle is only legal after Initialize.
    result = impl.client->SetEventHandle(impl.wake.handle());
    if (FAILED(result)) {
        error = hresultMessage(result, "registering the render wake event");
        impl.noteFailure(result);
        return false;
    }

    result = impl.client->GetService(IID_PPV_ARGS(&impl.renderClient));
    if (FAILED(result)) {
        error = hresultMessage(result, "obtaining the render client");
        impl.noteFailure(result);
        return false;
    }

    UINT32 frames = 0;
    result = impl.client->GetBufferSize(&frames);
    if (FAILED(result)) {
        error = "the render client reported no buffer size";
        // See the capture path: the code is kept even though the message does
        // not carry it, because the classification is what the engine acts on.
        impl.noteFailure(result);
        return false;
    }
    impl.bufferFrames = frames;

    // GetDevicePeriod reports 100 ns units, so it is a duration and is unaffected
    // by which rate the stream runs at. The period actually in effect is the one
    // negotiated from the requested buffer duration, so that is the fallback when
    // the device period is unavailable or nonsensical.
    //
    // The fallback divides buffer frames by the stream rate, not the mix rate:
    // GetBufferSize counts frames in the format Initialize accepted, so pairing
    // those frames with the endpoint's mix rate would report a duration the
    // buffer does not have. With a 48 kHz stream on a 192 kHz endpoint the mix
    // rate would understate the period by a factor of four.
    REFERENCE_TIME devicePeriod = 0;
    if (SUCCEEDED(impl.client->GetDevicePeriod(&devicePeriod, nullptr)) && devicePeriod > 0) {
        impl.periodMs = static_cast<double>(devicePeriod) / 10000.0;
    }
    if (impl.periodMs <= 0.0 && impl.format.sampleRate != 0) {
        impl.periodMs = static_cast<double>(impl.bufferFrames) * 1000.0 /
                        static_cast<double>(impl.format.sampleRate);
    }

    // Prime the endpoint with silence before Start(). The audio engine plays
    // whatever the buffer holds as soon as the stream runs, so an unprimed start
    // is audible as a click at the head of the first block. The whole buffer is
    // filled, which is why this runs before any write() has happened.
    if (!writeSilence(impl.bufferFrames, nullptr)) {
        error = "priming the render endpoint with silence failed";
        // writeSilence() has already stored the HRESULT that failed, so the
        // classification is left exactly as it set it: a lost device during
        // priming has to stay reopenable, and a broken one has to stay fatal.
        return false;
    }

    result = impl.client->Start();
    if (FAILED(result)) {
        error = hresultMessage(result, "starting the render stream");
        impl.noteFailure(result);
        return false;
    }
    impl.started = true;

    // Sampled once here, after Initialize() and Start(): GetStreamLatency()
    // reports nothing useful on a client that has not been initialized, and the
    // stream is up by this point. Control-thread only, like the capture path; a
    // 0.0 result means the engine declined to report a latency and is not a
    // failure. This is deliberately not folded into periodMs(): the period is a
    // buffer cadence, while the latency is the delay through the engine and the
    // device.
    impl.streamLatencyMs = readStreamLatencyMs(impl.client.Get());

    // The stream is up, so nothing is left to report: this is what makes a
    // reopen after a deviceLost attempt start from a clean classification.
    impl.clearFailure();
    return true;
}

void WasapiRender::close() {
    Impl& impl = *impl_;
    if (impl.client == nullptr) {
        // Also the path taken by a second close() and by the destructor of an
        // object that never opened. The classification is cleared here too: a
        // failed open() leaves it set, and a closed object must not keep
        // reporting that failure through lastError().
        impl.clearFailure();
        return;
    }

    // Release any write() waiting for endpoint room before tearing down, then
    // wait for it to observe the stop flag. close() is a control-thread call that
    // races a running audio thread, so waiting is the only way to be sure the
    // render client is no longer in use.
    impl.stopRequested.store(true, std::memory_order_release);
    impl.wake.signal();
    waitForOtherThread(impl.writeInFlight);

    if (impl.started) {
        impl.client->Stop();
        impl.started = false;
    }
    impl.client->Reset();

    impl.renderClient.Reset();
    impl.client.Reset();
    impl.device.Reset();
    impl.enumerator.Reset();

    impl.identity = EndpointIdentity();
    impl.deviceName.clear();
    impl.bufferFrames = 0;
    impl.periodMs = 0.0;
    impl.format = WasapiFormat();
    // The latency belonged to the stream that was just torn down. Keeping it
    // would report a property of a client that no longer exists.
    impl.streamLatencyMs = 0.0;

    // Cleared after teardown so a reopened object starts clean; open() clears it
    // too, which covers a close() that never ran.
    impl.stopRequested.store(false, std::memory_order_release);

    // A closed stream has no failure to report. Leaving the last one set would
    // make the engine act on a stale device error after the stream is gone.
    impl.clearFailure();
}

bool WasapiRender::isOpen() const {
    return impl_->client != nullptr;
}

const WasapiFormat& WasapiRender::format() const {
    return impl_->format;
}

uint32_t WasapiRender::bufferFrames() const {
    return impl_->bufferFrames;
}

double WasapiRender::periodMs() const {
    return impl_->periodMs;
}

double WasapiRender::streamLatencyMs() const {
    return impl_->streamLatencyMs;
}

const std::string& WasapiRender::openedDeviceId() const {
    return impl_->identity.id;
}

const std::string& WasapiRender::openedDeviceName() const {
    return impl_->deviceName;
}

const EndpointIdentity& WasapiRender::openedIdentity() const {
    return impl_->identity;
}

DeviceError WasapiRender::lastError() const {
    return classifyFailure(impl_->failureCode);
}

bool WasapiRender::write(const float* left, const float* right, uint32_t frames,
                         std::string* error) {
    Impl& impl = *impl_;

    if (impl.renderClient == nullptr) {
        if (error != nullptr) {
            *error = "render is not open";
        }
        // The caller used the object wrong rather than losing a device.
        impl.noteFailure(E_INVALIDARG);
        return false;
    }
    if (frames == 0) {
        // Nothing was asked for, so nothing failed. Clearing keeps a zero-frame
        // call from leaving an older failure visible at the next check.
        impl.clearFailure();
        return true;
    }
    if (left == nullptr || right == nullptr) {
        if (error != nullptr) {
            *error = "render needs both channel pointers";
        }
        // Matches the E_POINTER that GetBuffer would return for a null argument:
        // a broken request, not a device that went away.
        impl.noteFailure(E_POINTER);
        return false;
    }

    impl.writeInFlight.store(true, std::memory_order_release);
    struct InFlightGuard {
        std::atomic<bool>& flag;
        ~InFlightGuard() { flag.store(false, std::memory_order_release); }
    } guard { impl.writeInFlight };

    uint32_t written = 0;
    while (written < frames) {
        if (impl.stopRequested.load(std::memory_order_acquire)) {
            // A stop request is not a device failure: the engine distinguishes
            // the two through exactly this classification, so it must read
            // DeviceError::none here.
            impl.clearFailure();
            return false;
        }

        UINT32 padding = 0;
        const HRESULT paddingResult = impl.client->GetCurrentPadding(&padding);
        if (FAILED(paddingResult)) {
            if (error != nullptr) {
                *error = "reading the render padding failed";
            }
            impl.noteFailure(paddingResult);
            return false;
        }
        const uint32_t available = impl.bufferFrames > padding ? impl.bufferFrames - padding : 0;
        if (available == 0) {
            // No room. Waiting on the endpoint's event keeps this off the CPU;
            // a busy loop here would burn a whole core for no latency gain. The
            // padding is polled again after every wake, so the event is a hint
            // and a missed one only costs the timeout.
            impl.wake.clear();
            const DWORD waitResult = WaitForSingleObject(impl.wake.handle(), waitTimeoutMs);
            if (waitResult == WAIT_FAILED) {
                if (error != nullptr) {
                    *error = "waiting for render space failed";
                }
                // WaitForSingleObject reports through GetLastError(), not an
                // HRESULT; see the capture path.
                impl.noteFailure(E_FAIL);
                return false;
            }
            continue;
        }

        const uint32_t chunk = std::min(available, frames - written);
        BYTE* data = nullptr;
        const HRESULT result = impl.renderClient->GetBuffer(chunk, &data);
        if (FAILED(result)) {
            if (error != nullptr) {
                *error = hresultMessage(result, "obtaining a render buffer");
            }
            impl.noteFailure(result);
            return false;
        }

        switch (impl.sampleKind) {
            case SampleKind::float32:
                interleaveFromStereo(impl.mix, left + written, right + written, chunk, data,
                                     encodeFloat32);
                break;
            case SampleKind::pcm16:
                interleaveFromStereo(impl.mix, left + written, right + written, chunk, data,
                                     encodePcm16);
                break;
            case SampleKind::pcm24In32:
                interleaveFromStereo(impl.mix, left + written, right + written, chunk, data,
                                     encodePcm24In32);
                break;
            case SampleKind::pcm32:
                interleaveFromStereo(impl.mix, left + written, right + written, chunk, data,
                                     encodePcm32);
                break;
            case SampleKind::unsupported:
            default:
                // open() rejects an unsupported format, so this is unreachable;
                // falling back to silence keeps a released packet well-defined
                // rather than shipping whatever the buffer held.
                std::memset(data, 0, static_cast<size_t>(chunk) * impl.mix.blockAlign);
                break;
        }

        // AUDCLNT_BUFFERFLAGS_SILENT is deliberately not passed: the buffer now
        // holds real samples and the endpoint has to play them.
        const HRESULT releaseResult = impl.renderClient->ReleaseBuffer(chunk, 0);
        if (FAILED(releaseResult)) {
            if (error != nullptr) {
                *error = hresultMessage(releaseResult, "releasing a render buffer");
            }
            impl.noteFailure(releaseResult);
            return false;
        }
        written += chunk;
    }

    // Every frame asked for reached the endpoint, so this call is a success and
    // an earlier failure must not be reported as the current one.
    impl.clearFailure();
    return true;
}

bool WasapiRender::writeSilence(uint32_t frames, std::string* error) {
    Impl& impl = *impl_;

    if (impl.renderClient == nullptr) {
        if (error != nullptr) {
            *error = "render is not open";
        }
        // Same classification as write(): a wrong request, not a lost device.
        impl.noteFailure(E_INVALIDARG);
        return false;
    }
    if (frames == 0) {
        impl.clearFailure();
        return true;
    }

    uint32_t written = 0;
    while (written < frames) {
        if (impl.stopRequested.load(std::memory_order_acquire)) {
            // A stop request, so no device failure is reported; see write().
            impl.clearFailure();
            return false;
        }

        UINT32 padding = 0;
        const HRESULT paddingResult = impl.client->GetCurrentPadding(&padding);
        if (FAILED(paddingResult)) {
            if (error != nullptr) {
                *error = "reading the render padding failed";
            }
            impl.noteFailure(paddingResult);
            return false;
        }
        const uint32_t available = impl.bufferFrames > padding ? impl.bufferFrames - padding : 0;
        if (available == 0) {
            impl.wake.clear();
            const DWORD waitResult = WaitForSingleObject(impl.wake.handle(), waitTimeoutMs);
            if (waitResult == WAIT_FAILED) {
                if (error != nullptr) {
                    *error = "waiting for render space failed";
                }
                // WaitForSingleObject reports through GetLastError(), not an
                // HRESULT; see the capture path.
                impl.noteFailure(E_FAIL);
                return false;
            }
            continue;
        }

        const uint32_t chunk = std::min(available, frames - written);
        BYTE* data = nullptr;
        const HRESULT result = impl.renderClient->GetBuffer(chunk, &data);
        if (FAILED(result)) {
            if (error != nullptr) {
                *error = hresultMessage(result, "obtaining a render buffer");
            }
            impl.noteFailure(result);
            return false;
        }

        // Asking the audio engine to treat the range as silence is cheaper than
        // writing zeros: it can skip the copy and, on some drivers, the transfer
        // entirely. The contract for this flag is that the buffer contents are
        // ignored, which is why nothing is written into `data`.
        const HRESULT releaseResult =
            impl.renderClient->ReleaseBuffer(chunk, AUDCLNT_BUFFERFLAGS_SILENT);
        if (FAILED(releaseResult)) {
            if (error != nullptr) {
                *error = hresultMessage(releaseResult, "releasing a silence buffer");
            }
            impl.noteFailure(releaseResult);
            return false;
        }
        written += chunk;
    }

    impl.clearFailure();
    return true;
}

void WasapiRender::requestStop() {
    // Only sets the flag and wakes the waiter. It must stay callable from any
    // thread and from a signal handler context, so it touches nothing else.
    impl_->stopRequested.store(true, std::memory_order_release);
    impl_->wake.signal();
}

} // namespace lowend::win
