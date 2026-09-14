// Devices.h — WASAPI device enumeration, loopback capture, and render.
//
// All entry points are control-thread operations except the ones marked as
// audio-thread. Audio-thread calls allocate nothing and take no locks beyond
// what WASAPI's own audio client requires internally.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace lowend::win {

enum class DataFlow {
    render,   // output endpoint; can be captured with loopback
    capture,  // input endpoint (microphone, line-in, virtual cable)
};

struct DeviceInfo {
    std::string id;        // UTF-8 endpoint id string, used by --device
    std::string name;      // UTF-8 friendly name from PKEY_Device_FriendlyName
    bool isDefault = false;
    bool loopbackCapable = false;  // render endpoint usable with loopback flag
    uint32_t mixChannels = 0;      // shared-mode mix format
    uint32_t mixSampleRate = 0;
    uint32_t mixBitsPerSample = 0;
    std::string formFactor;        // "Speakers", "Headphones", "Bluetooth", ...
    std::string containerId;       // stable id shared by one physical device
};

// Enumeration needs COM initialized on the calling thread. Enumerators return
// an empty vector and set `error` on failure.
std::vector<DeviceInfo> listDevices(DataFlow flow, std::string& error);

struct WasapiFormat {
    uint32_t channels = 0;
    uint32_t sampleRate = 0;
    uint32_t bitsPerSample = 0;
};

// How the most recent failure should be treated. Recovery only makes sense for
// a device that went away: reopening it can succeed once it returns. Every
// other failure (bad format, unsupported mode, allocation) would repeat, so a
// caller must not retry it.
enum class DeviceError {
    none,        // no failure since the last successful call
    deviceLost,  // the endpoint was removed, disabled, or reconfigured
    fatal,       // the request itself is wrong; reopening cannot help
};

// ─── Loopback / input capture ────────────────────────────────────────
// One packet at a time. acquire() blocks until WASAPI delivers a packet;
// callers must pair every successful acquire() with release().
class WasapiCapture {
public:
    struct Options {
        std::string deviceId;   // empty selects the default endpoint
        DataFlow flow = DataFlow::render;
        bool loopback = false;  // only meaningful when flow == render
        uint32_t bufferMs = 20;
    };

    WasapiCapture();
    ~WasapiCapture();
    WasapiCapture(const WasapiCapture&) = delete;
    WasapiCapture& operator=(const WasapiCapture&) = delete;

    // Control thread. Must not run concurrently with acquire().
    bool open(const Options& options, std::string& error);
    void close();
    bool isOpen() const;

    const WasapiFormat& format() const;
    // Actual shared-mode buffer the audio engine negotiated, in frames.
    uint32_t bufferFrames() const;
    // Latency the audio engine reports for this stream, in milliseconds. This is
    // what WASAPI's IAudioClient::GetStreamLatency() returns: the delay through the
    // audio engine and the device for this stream, NOT the total path latency a
    // caller observes. 0 when unknown.
    //
    // GetStreamLatency is documented as returning "the maximum latency of the
    // stream, in 100-nanosecond units ... the latency of the stream is the sum of
    // the latencies of the audio engine and the endpoint device"
    // (https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getstreamlatency).
    //
    // A control-thread read of a value sampled once by open(): it is a property
    // of the stream, not a live measurement, so it cannot change while the stream
    // is open.
    double streamLatencyMs() const;
    // True when the endpoint had to be captured through loopback because the
    // request named a render endpoint without a capture counterpart.
    bool isLoopback() const;

    // Identity of the endpoint open() actually resolved. Empty before open() and
    // after a failed one. An empty Options::deviceId means "the default
    // endpoint", so these report which device that turned out to be — the only
    // way a caller can tell that two default requests landed on the same
    // hardware.
    const std::string& openedDeviceId() const;
    const std::string& openedDeviceName() const;

    // Audio thread. Blocks for the next packet. Returns false on a device
    // error or when stop() was requested; `error` is control-thread readable.
    bool acquire(std::string* error);

    // Audio thread. Frames in the current packet, already converted to
    // deinterleaved stereo float at format().sampleRate.
    uint32_t frameCount() const;
    const float* left() const;
    const float* right() const;

    // Audio thread. Releases the current packet. Safe when not acquired.
    void release();

    // The packet is a discontinuity: the device repositioned or the stream was
    // reset. Consumers should reset filter state instead of bridging the gap.
    bool isDiscontinuity() const;

    // Classification of the most recent failure. Reset to DeviceError::none by a
    // successful open()/acquire()/write(). Control-thread readable after an audio
    // thread failure.
    DeviceError lastError() const;

private:
    struct Impl;
    Impl* impl_;
};

// ─── Render ──────────────────────────────────────────────────────────
class WasapiRender {
public:
    struct Options {
        std::string deviceId;   // empty selects the default endpoint
        uint32_t bufferMs = 20;
        // 0 = use the endpoint's shared-mode mix format. Non-zero asks the audio
        // engine to accept a stream at this rate instead, converting to the mix
        // rate internally (AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM).
        uint32_t requestedSampleRate = 0;
    };

    WasapiRender();
    ~WasapiRender();
    WasapiRender(const WasapiRender&) = delete;
    WasapiRender& operator=(const WasapiRender&) = delete;

    bool open(const Options& options, std::string& error);
    void close();
    bool isOpen() const;

    // The format of the samples write() accepts. When Options::requestedSampleRate
    // is nonzero this is the requested rate, not the endpoint's mix rate: the audio
    // engine converts between the two, so the stream rate is the one callers must
    // use to size blocks and prepare DSP.
    const WasapiFormat& format() const;
    uint32_t bufferFrames() const;
    // Negotiated shared-mode period in milliseconds. Compare with the requested
    // bufferMs to report what the device actually accepted. This is a buffer
    // period, not the stream latency; streamLatencyMs() reports the latter.
    double periodMs() const;

    // Latency the audio engine reports for this stream, in milliseconds. This is
    // what WASAPI's IAudioClient::GetStreamLatency() returns: the delay through the
    // audio engine and the device for this stream, NOT the total path latency a
    // caller observes. 0 when unknown.
    //
    // GetStreamLatency is documented as returning "the maximum latency of the
    // stream, in 100-nanosecond units ... the latency of the stream is the sum of
    // the latencies of the audio engine and the endpoint device"
    // (https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-getstreamlatency).
    //
    // A control-thread read of a value sampled once by open(): it is a property
    // of the stream, not a live measurement, so it cannot change while the stream
    // is open.
    double streamLatencyMs() const;

    // Identity of the endpoint open() actually resolved; see the capture class
    // for why the default case has to be observable.
    const std::string& openedDeviceId() const;
    const std::string& openedDeviceName() const;

    // Audio thread. Writes exactly `frames` stereo frames, converting to the
    // endpoint's channel layout and sample format. Blocks while the endpoint
    // has no room. Returns false on a device error or stop request.
    bool write(const float* left, const float* right, uint32_t frames, std::string* error);

    // Audio thread. Writes `frames` of silence to re-prime the endpoint.
    bool writeSilence(uint32_t frames, std::string* error);

    // Requests that a blocked write() return false. Safe from any thread.
    void requestStop();

    // Classification of the most recent failure. Reset to DeviceError::none by a
    // successful open()/acquire()/write(). Control-thread readable after an audio
    // thread failure.
    DeviceError lastError() const;

private:
    struct Impl;
    Impl* impl_;
};

} // namespace lowend::win
