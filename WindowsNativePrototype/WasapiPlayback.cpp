// WasapiPlayback.cpp — WASAPI audio output implementation (polling-based)

#ifdef _WIN32

#include "WasapiPlayback.h"
#include <avrt.h>
#include <functiondiscoverykeys_devpkey.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")

WasapiPlayback::WasapiPlayback() {
    ringBuffer_ = new float[kBufferFrames];
    ZeroMemory(ringBuffer_, kBufferFrames * sizeof(float));
    InitializeCriticalSection(&bufferLock_);
}

WasapiPlayback::~WasapiPlayback() {
    stop();
    DeleteCriticalSection(&bufferLock_);
    delete[] ringBuffer_;
}

bool WasapiPlayback::initialize() {
    if (initialized_) return true;

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        fprintf(stderr, "[playback] CoInitializeEx failed: 0x%08lx\n", hr);
        return false;
    }
    comInitialized_ = (hr != RPC_E_CHANGED_MODE);

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                          CLSCTX_ALL, IID_PPV_ARGS(&enumerator_));
    if (FAILED(hr)) { fprintf(stderr, "[playback] MMDeviceEnumerator failed: 0x%08lx\n", hr); return false; }

    hr = enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
    if (hr == E_NOTFOUND) { fprintf(stderr, "[playback] No render device found.\n"); return false; }
    if (FAILED(hr)) { fprintf(stderr, "[playback] GetDefaultAudioEndpoint failed: 0x%08lx\n", hr); return false; }

    hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audioClient_);
    if (FAILED(hr)) { fprintf(stderr, "[playback] IAudioClient activation failed: 0x%08lx\n", hr); return false; }

    WAVEFORMATEX* mixFormat = nullptr;
    hr = audioClient_->GetMixFormat(&mixFormat);
    if (FAILED(hr)) { fprintf(stderr, "[playback] GetMixFormat failed: 0x%08lx\n", hr); return false; }

    sampleRate_ = mixFormat->nSamplesPerSec;
    channels_ = mixFormat->nChannels;
    fprintf(stderr, "[playback] Mix format: %lu Hz, %lu channels, %hu bits\n",
            sampleRate_, channels_, mixFormat->wBitsPerSample);

    // Shared mode, polling-based — use device's default period
    REFERENCE_TIME defaultPeriod = 0;
    if (FAILED(audioClient_->GetDevicePeriod(&defaultPeriod, nullptr))) {
        defaultPeriod = 100000; // fallback: 10ms
    }
    hr = audioClient_->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, defaultPeriod, 0, mixFormat, nullptr);
    CoTaskMemFree(mixFormat);

    if (FAILED(hr)) { fprintf(stderr, "[playback] IAudioClient Init failed: 0x%08lx\n", hr); return false; }

    hr = audioClient_->GetBufferSize(&bufferFrameCount_);
    if (FAILED(hr)) { fprintf(stderr, "[playback] GetBufferSize failed: 0x%08lx\n", hr); return false; }

    hr = audioClient_->GetService(IID_PPV_ARGS(&renderClient_));
    if (FAILED(hr)) { fprintf(stderr, "[playback] GetService(IAudioRenderClient) failed: 0x%08lx\n", hr); return false; }

    initialized_ = true;
    fprintf(stderr, "[playback] Initialised: %lu Hz, %lu ch, buffer=%lu frames (polling)\n",
            sampleRate_, channels_, bufferFrameCount_);
    return true;
}

bool WasapiPlayback::start() {
    if (!initialized_ || running_) return false;

    writePos_ = 0;
    readPos_ = 0;
    ZeroMemory(ringBuffer_, kBufferFrames * sizeof(float));

    HRESULT hr = audioClient_->Start();
    if (FAILED(hr)) { fprintf(stderr, "[playback] Start failed: 0x%08lx\n", hr); return false; }

    running_ = true;
    renderThread_ = CreateThread(nullptr, 0, renderThreadProc, this, 0, nullptr);
    if (!renderThread_) {
        fprintf(stderr, "[playback] CreateThread failed\n");
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

void WasapiPlayback::submitInterleaved(const float* data, uint32_t frameCount) {
    if (!initialized_ || !running_ || !data || frameCount == 0) return;

    EnterCriticalSection(&bufferLock_);
    for (uint32_t i = 0; i < frameCount * channels_; ++i) {
        uint32_t nextWrite = (writePos_ + 1) % kBufferFrames;
        if (nextWrite == readPos_) break;
        ringBuffer_[writePos_] = data[i];
        writePos_ = nextWrite;
    }
    LeaveCriticalSection(&bufferLock_);
}

DWORD WINAPI WasapiPlayback::renderThreadProc(LPVOID param) {
    WasapiPlayback* self = static_cast<WasapiPlayback*>(param);
    DWORD mmcssIndex = 0;
    HANDLE mmcssHandle = AvSetMmThreadCharacteristicsW(L"Audio", &mmcssIndex);
    self->renderLoop();
    if (mmcssHandle) AvRevertMmThreadCharacteristics(mmcssHandle);
    return 0;
}

void WasapiPlayback::renderLoop() {
    while (running_) {
        UINT32 padding = 0;
        if (FAILED(audioClient_->GetCurrentPadding(&padding))) { Sleep(10); continue; }
        UINT32 framesToWrite = bufferFrameCount_ - padding;
        if (framesToWrite == 0) { Sleep(5); continue; }

        BYTE* renderData = nullptr;
        HRESULT hr = renderClient_->GetBuffer(framesToWrite, &renderData);
        if (FAILED(hr) || !renderData) { Sleep(10); continue; }

        float* dest = reinterpret_cast<float*>(renderData);

        uint32_t written = 0;
        EnterCriticalSection(&bufferLock_);
        while (written < framesToWrite) {
            uint32_t samplesNeeded = (framesToWrite - written) * channels_;
            uint32_t samplesAvail = 0;
            if (writePos_ >= readPos_)
                samplesAvail = writePos_ - readPos_;
            else
                samplesAvail = (kBufferFrames - readPos_) + writePos_;
            uint32_t samplesToCopy = (samplesNeeded < samplesAvail) ? samplesNeeded : samplesAvail;
            if (samplesToCopy == 0) break;

            for (uint32_t i = 0; i < samplesToCopy; ++i) {
                dest[written * channels_ + i] = ringBuffer_[readPos_];
                readPos_ = (readPos_ + 1) % kBufferFrames;
            }
            written += samplesToCopy / channels_;
        }
        LeaveCriticalSection(&bufferLock_);

        if (written < framesToWrite) {
            uint32_t remaining = (framesToWrite - written) * channels_;
            ZeroMemory(dest + written * channels_, remaining * sizeof(float));
        }

        renderClient_->ReleaseBuffer(framesToWrite, 0);
        Sleep(5);
    }
}

#endif
