// WasapiPlayback.cpp — WASAPI audio output implementation

#ifdef _WIN32

#include "WasapiPlayback.h"
#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")

// ─── Constructor / Destructor ───────────────────────────────────

WasapiPlayback::WasapiPlayback() {
    ringBuffer_ = new float[kBufferFrames];
    ZeroMemory(ringBuffer_, kBufferFrames * sizeof(float));
    InitializeCriticalSection(&bufferLock_);
    dataReadyEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
}

WasapiPlayback::~WasapiPlayback() {
    stop();
    if (dataReadyEvent_) CloseHandle(dataReadyEvent_);
    DeleteCriticalSection(&bufferLock_);
    delete[] ringBuffer_;
}

// ─── initialize ─────────────────────────────────────────────────

bool WasapiPlayback::initialize() {
    if (initialized_) return true;

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        fprintf(stderr, "CoInitializeEx failed: 0x%08lx\n", hr);
        return false;
    }
    comInitialized_ = (hr != RPC_E_CHANGED_MODE);

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                          CLSCTX_ALL, IID_PPV_ARGS(&enumerator_));
    if (FAILED(hr)) { fprintf(stderr, "MMDeviceEnumerator failed: 0x%08lx\n", hr); return false; }

    hr = enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
    if (hr == E_NOTFOUND) { fprintf(stderr, "No render device found.\n"); return false; }
    if (FAILED(hr)) { fprintf(stderr, "GetDefaultAudioEndpoint failed: 0x%08lx\n", hr); return false; }

    hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audioClient_);
    if (FAILED(hr)) { fprintf(stderr, "IAudioClient activation failed: 0x%08lx\n", hr); return false; }

    // Use shared mode with the mix format
    WAVEFORMATEX* mixFormat = nullptr;
    hr = audioClient_->GetMixFormat(&mixFormat);
    if (FAILED(hr)) { fprintf(stderr, "GetMixFormat failed: 0x%08lx\n", hr); return false; }

    sampleRate_ = mixFormat->nSamplesPerSec;
    channels_ = mixFormat->nChannels;
    fprintf(stderr, "[playback] Mix format: %lu Hz, %lu channels, %hu bits\n",
            sampleRate_, channels_, mixFormat->wBitsPerSample);

    // Event-driven shared mode, 100 ms buffer
    REFERENCE_TIME bufferDuration = 100 * 10000;
    hr = audioClient_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                  bufferDuration, 0, mixFormat, nullptr);
    CoTaskMemFree(mixFormat);

    if (FAILED(hr)) { fprintf(stderr, "IAudioClient Init (render) failed: 0x%08lx\n", hr); return false; }

    // Get the buffer size
    hr = audioClient_->GetBufferSize(&bufferFrameCount_);
    if (FAILED(hr)) { fprintf(stderr, "GetBufferSize failed: 0x%08lx\n", hr); return false; }

    hr = audioClient_->GetService(IID_PPV_ARGS(&renderClient_));
    if (FAILED(hr)) { fprintf(stderr, "GetService(IAudioRenderClient) failed: 0x%08lx\n", hr); return false; }

    hr = audioClient_->SetEventHandle(renderEvent_);
    if (FAILED(hr)) { fprintf(stderr, "SetEventHandle failed: 0x%08lx\n", hr); return false; }

    initialized_ = true;
    fprintf(stderr, "[playback] Initialised: %lu Hz, %lu ch, buffer=%lu frames\n",
            sampleRate_, channels_, bufferFrameCount_);
    return true;
}

// ─── start / stop ────────────────────────────────────────────────

bool WasapiPlayback::start() {
    if (!initialized_ || running_) return false;

    // Reset the ring buffer
    writePos_ = 0;
    readPos_ = 0;
    ZeroMemory(ringBuffer_, kBufferFrames * sizeof(float));

    HRESULT hr = audioClient_->Start();
    if (FAILED(hr)) { fprintf(stderr, "IAudioClient Start failed: 0x%08lx\n", hr); return false; }

    running_ = true;
    renderThread_ = CreateThread(nullptr, 0, renderThreadProc, this, 0, nullptr);
    if (!renderThread_) {
        fprintf(stderr, "CreateThread for render failed\n");
        running_ = false;
        audioClient_->Stop();
        return false;
    }

    fprintf(stderr, "[playback] Started.\n");
    return true;
}

void WasapiPlayback::stop() {
    if (running_) {
        running_ = false;
        SetEvent(dataReadyEvent_);
        if (renderThread_) {
            WaitForSingleObject(renderThread_, 3000);
            CloseHandle(renderThread_);
            renderThread_ = nullptr;
        }
    }
    if (audioClient_) audioClient_->Stop();
    if (renderClient_) { renderClient_->Release(); renderClient_ = nullptr; }
    if (audioClient_)  { audioClient_->Release();  audioClient_ = nullptr; }
    if (device_)       { device_->Release();       device_ = nullptr; }
    if (enumerator_)   { enumerator_->Release();   enumerator_ = nullptr; }
    if (comInitialized_) { CoUninitialize(); comInitialized_ = false; }
    initialized_ = false;
    fprintf(stderr, "[playback] Stopped.\n");
}

// ─── submitInterleaved ──────────────────────────────────────────

void WasapiPlayback::submitInterleaved(const float* data, uint32_t frameCount) {
    if (!initialized_ || !running_ || !data || frameCount == 0) return;

    EnterCriticalSection(&bufferLock_);
    for (uint32_t i = 0; i < frameCount * channels_; ++i) {
        uint32_t nextWrite = (writePos_ + 1) % kBufferFrames;
        if (nextWrite == readPos_) break; // buffer full
        ringBuffer_[writePos_] = data[i];
        writePos_ = nextWrite;
    }
    LeaveCriticalSection(&bufferLock_);
    SetEvent(dataReadyEvent_); // wake render thread
}

// ─── Render thread ──────────────────────────────────────────────

DWORD WINAPI WasapiPlayback::renderThreadProc(LPVOID param) {
    WasapiPlayback* self = static_cast<WasapiPlayback*>(param);

    DWORD mmcssIndex = 0;
    HANDLE mmcssHandle = AvSetMmThreadCharacteristicsW(L"Audio", &mmcssIndex);

    self->renderLoop();

    if (mmcssHandle) AvRevertMmThreadCharacteristics(mmcssHandle);
    return 0;
}

void WasapiPlayback::renderLoop() {
    HANDLE waitHandles[] = { renderEvent_, dataReadyEvent_ };

    while (running_) {
        // Wait for either the render event (buffer ready) or data event
        DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, 100);
        if (!running_) break;

        // How many frames can we write?
        UINT32 padding = 0;
        if (FAILED(audioClient_->GetCurrentPadding(&padding))) continue;
        UINT32 framesToWrite = bufferFrameCount_ - padding;
        if (framesToWrite == 0) continue;

        // Get the render buffer
        BYTE* renderData = nullptr;
        HRESULT hr = renderClient_->GetBuffer(framesToWrite, &renderData);
        if (FAILED(hr) || !renderData) continue;

        float* dest = reinterpret_cast<float*>(renderData);

        // Read from ring buffer
        uint32_t written = 0;
        EnterCriticalSection(&bufferLock_);
        while (written < framesToWrite) {
            uint32_t samplesNeeded = (framesToWrite - written) * channels_;
            uint32_t samplesAvail = 0;
            if (writePos_ >= readPos_) {
                samplesAvail = writePos_ - readPos_;
            } else {
                samplesAvail = (kBufferFrames - readPos_) + writePos_;
            }
            uint32_t samplesToCopy = (samplesNeeded < samplesAvail) ? samplesNeeded : samplesAvail;
            if (samplesToCopy == 0) break;

            // Copy from ring to render buffer (interleaved)
            for (uint32_t i = 0; i < samplesToCopy; ++i) {
                dest[written * channels_ + i] = ringBuffer_[readPos_];
                readPos_ = (readPos_ + 1) % kBufferFrames;
            }
            written += samplesToCopy / channels_;
        }
        LeaveCriticalSection(&bufferLock_);

        // Fill remaining with silence
        if (written < framesToWrite) {
            uint32_t remainingSamples = (framesToWrite - written) * channels_;
            ZeroMemory(dest + written * channels_, remainingSamples * sizeof(float));
        }

        renderClient_->ReleaseBuffer(framesToWrite, 0);
    }
}

uint32_t WasapiPlayback::ringAvailable() const {
    if (writePos_ >= readPos_) return writePos_ - readPos_;
    return (kBufferFrames - readPos_) + writePos_;
}

#endif // _WIN32
