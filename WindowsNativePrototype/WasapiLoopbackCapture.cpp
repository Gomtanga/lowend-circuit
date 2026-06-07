// WasapiLoopbackCapture.cpp — WASAPI loopback capture implementation

#ifdef _WIN32

#include "WasapiLoopbackCapture.h"
#include <functiondiscoverykeys_devpkey.h>
#include <avrt.h>
#include <cstdio>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")

// ─── Constructor / Destructor ───────────────────────────────────

WasapiLoopbackCapture::WasapiLoopbackCapture() = default;

WasapiLoopbackCapture::~WasapiLoopbackCapture() {
    stop();
}

// ─── initialize ─────────────────────────────────────────────────

bool WasapiLoopbackCapture::initialize() {
    if (initialized_) return true;

    // 1. Initialise COM
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        fprintf(stderr, "CoInitializeEx failed: 0x%08lx\n", hr);
        return false;
    }
    comInitialized_ = (hr != RPC_E_CHANGED_MODE);

    // 2. Create device enumerator
    hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        IID_PPV_ARGS(&enumerator_));
    if (FAILED(hr)) {
        fprintf(stderr, "MMDeviceEnumerator creation failed: 0x%08lx\n", hr);
        return false;
    }

    // 3. Get default audio render endpoint
    hr = enumerator_->GetDefaultAudioEndpoint(
        eRender, eConsole, &device_);
    if (hr == E_NOTFOUND) {
        fprintf(stderr, "No default render device found (expected on CI VMs).\n");
        return false;
    }
    if (FAILED(hr)) {
        fprintf(stderr, "GetDefaultAudioEndpoint failed: 0x%08lx\n", hr);
        return false;
    }

    // 4. Activate IAudioClient
    hr = device_->Activate(
        __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
        (void**)&audioClient_);
    if (FAILED(hr)) {
        fprintf(stderr, "IAudioClient activation failed: 0x%08lx\n", hr);
        return false;
    }

    // 5. Get the mix format
    WAVEFORMATEX* mixFormat = nullptr;
    hr = audioClient_->GetMixFormat(&mixFormat);
    if (FAILED(hr)) {
        fprintf(stderr, "GetMixFormat failed: 0x%08lx\n", hr);
        return false;
    }

    sampleRate_ = mixFormat->nSamplesPerSec;
    channels_ = mixFormat->nChannels;
    fprintf(stderr, "Mix format: %lu Hz, %lu channels, %hu bits\n",
            sampleRate_, channels_, mixFormat->wBitsPerSample);

    // 6. Open the audio client in loopback mode
    // Use a buffer duration of 100 ms.
    REFERENCE_TIME bufferDuration = 100 * 10000;  // 100 ms in 100-ns units
    hr = audioClient_->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK,
        bufferDuration, 0, mixFormat, nullptr);
    CoTaskMemFree(mixFormat);
    mixFormat = nullptr;

    if (FAILED(hr)) {
        fprintf(stderr, "IAudioClient Initialize (loopback) failed: 0x%08lx\n", hr);
        return false;
    }

    // 7. Get the capture client
    hr = audioClient_->GetService(
        IID_PPV_ARGS(&captureClient_));
    if (FAILED(hr)) {
        fprintf(stderr, "GetService(IAudioCaptureClient) failed: 0x%08lx\n", hr);
        return false;
    }

    // 8. Create the capture-ready event
    captureEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!captureEvent_) {
        fprintf(stderr, "CreateEvent failed\n");
        return false;
    }

    hr = audioClient_->SetEventHandle(captureEvent_);
    if (FAILED(hr)) {
        fprintf(stderr, "SetEventHandle failed: 0x%08lx\n", hr);
        return false;
    }

    initialized_ = true;
    fprintf(stderr, "WASAPI loopback capture initialised successfully.\n");
    return true;
}

// ─── start / stop ────────────────────────────────────────────────

bool WasapiLoopbackCapture::start() {
    if (!initialized_ || running_) return false;

    // Start the audio client
    HRESULT hr = audioClient_->Start();
    if (FAILED(hr)) {
        fprintf(stderr, "IAudioClient Start failed: 0x%08lx\n", hr);
        return false;
    }

    running_ = true;

    // Create the capture thread
    captureThread_ = CreateThread(
        nullptr, 0, captureThreadProc, this, 0, nullptr);
    if (!captureThread_) {
        fprintf(stderr, "CreateThread for capture failed\n");
        running_ = false;
        audioClient_->Stop();
        return false;
    }

    fprintf(stderr, "WASAPI loopback capture started.\n");
    return true;
}

void WasapiLoopbackCapture::stop() {
    if (running_) {
        running_ = false;
        if (captureEvent_) SetEvent(captureEvent_);  // wake up thread to exit
        if (captureThread_) {
            WaitForSingleObject(captureThread_, 3000);
            CloseHandle(captureThread_);
            captureThread_ = nullptr;
        }
    }

    if (audioClient_) audioClient_->Stop();

    if (captureEvent_) { CloseHandle(captureEvent_); captureEvent_ = nullptr; }
    if (captureClient_) { captureClient_->Release(); captureClient_ = nullptr; }
    if (audioClient_)  { audioClient_->Release();  audioClient_ = nullptr; }
    if (device_)       { device_->Release();       device_ = nullptr; }
    if (enumerator_)   { enumerator_->Release();   enumerator_ = nullptr; }
    if (comInitialized_) { CoUninitialize(); comInitialized_ = false; }

    initialized_ = false;
    fprintf(stderr, "WASAPI loopback capture stopped.\n");
}

// ─── Capture thread ──────────────────────────────────────────────

DWORD WINAPI WasapiLoopbackCapture::captureThreadProc(LPVOID param) {
    WasapiLoopbackCapture* self = static_cast<WasapiLoopbackCapture*>(param);

    // Use MMCSS to reduce glitching on the capture thread
    DWORD mmcssTaskIndex = 0;
    HANDLE mmcssHandle = AvSetMmThreadCharacteristicsW(L"Audio", &mmcssTaskIndex);

    uint64_t totalFrames = 0;

    while (self->running_) {
        // Wait for buffer ready (100 ms timeout for graceful exit)
        DWORD waitResult = WaitForSingleObject(self->captureEvent_, 100);
        if (!self->running_) break;
        if (waitResult != WAIT_OBJECT_0) continue;

        // Process all available packets
        self->processCapturedData(totalFrames);
    }

    if (mmcssHandle) AvRevertMmThreadCharacteristics(mmcssHandle);
    return 0;
}

void WasapiLoopbackCapture::processCapturedData(uint64_t& totalFrames) {
    if (!captureClient_) return;

    BYTE* data = nullptr;
    UINT32 framesAvailable = 0;
    DWORD flags = 0;

    while (true) {
        HRESULT hr = captureClient_->GetBuffer(&data, &framesAvailable, &flags, nullptr, nullptr);
        if (hr == AUDCLNT_S_BUFFER_EMPTY) break;
        if (FAILED(hr)) break;

        // Count frames (actual DSP will be added in Step 3+)
        totalFrames += framesAvailable;

        // For now, just log the first few buffers
        static int logCount = 0;
        if (logCount < 5) {
            fprintf(stderr, "[capture] %lu frames, flags=0x%08lx\n",
                    framesAvailable, flags);
            logCount++;
        }

        // Release the buffer
        captureClient_->ReleaseBuffer(framesAvailable);
    }
}

#endif // _WIN32
