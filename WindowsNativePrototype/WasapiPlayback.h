// WasapiPlayback.h — Windows WASAPI audio output (polling-based)
//
// Renders processed audio to the default output device.
// Uses a polling-based render thread for cross-system reliability.
// Submit data from the capture thread via submitInterleaved().
// Internal buffer is mutex-protected (prototype; use lock-free ring buffer later).

#pragma once

#ifdef _WIN32

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <cstdint>
#include <cstdio>

class WasapiPlayback {
public:
    WasapiPlayback();
    ~WasapiPlayback();

    bool initialize();
    bool start();
    void stop();
    void submitInterleaved(const float* data, uint32_t frameCount);

    uint32_t sampleRate() const { return sampleRate_; }
    uint32_t channels() const { return channels_; }

private:
    bool initialized_ = false;
    bool comInitialized_ = false;

    IMMDeviceEnumerator* enumerator_ = nullptr;
    IMMDevice* device_ = nullptr;
    IAudioClient* audioClient_ = nullptr;
    IAudioRenderClient* renderClient_ = nullptr;

    uint32_t sampleRate_ = 0;
    uint32_t channels_ = 0;
    uint32_t bufferFrameCount_ = 0;

    HANDLE renderThread_ = nullptr;
    volatile bool running_ = false;

    static constexpr uint32_t kBufferFrames = 32768;
    float* ringBuffer_ = nullptr;
    volatile uint32_t writePos_ = 0;
    volatile uint32_t readPos_ = 0;
    CRITICAL_SECTION bufferLock_;

    static DWORD WINAPI renderThreadProc(LPVOID param);
    void renderLoop();
};

#endif
