// WasapiPlayback.h — Windows WASAPI audio output
//
// Renders processed audio to the default audio output device.
// Uses a separate render thread with event-driven scheduling.
// Data is submitted from the capture thread via submitInterleaved()
// and buffered internally with a mutex-protected circular buffer.
//
// Real-time note: the mutex in submitInterleaved() is acceptable for
// this prototype but should be replaced with a lock-free ring buffer
// for production use (Core already has AudioRingBufferC for this).

#pragma once

#ifdef _WIN32

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <cstdint>
#include <cstdio>

class WasapiPlayback {
public:
    WasapiPlayback();
    ~WasapiPlayback();

    /// Initialize render client for the default output device.
    /// Uses the mix format (shared mode) — same format as capture by default.
    bool initialize();

    /// Start the render thread.
    bool start();

    /// Stop the render thread and release resources.
    void stop();

    /// Submit interleaved float samples for playback (capture thread).
    /// May briefly block on a mutex. frameCount is per-channel frames.
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

    HANDLE renderEvent_ = nullptr;
    HANDLE renderThread_ = nullptr;
    volatile bool running_ = false;

    // Simple circular buffer (mutex-protected for prototype simplicity)
    static constexpr uint32_t kBufferFrames = 32768;
    float* ringBuffer_ = nullptr;
    volatile uint32_t writePos_ = 0;
    volatile uint32_t readPos_ = 0;
    CRITICAL_SECTION bufferLock_;
    HANDLE dataReadyEvent_ = nullptr;

    static DWORD WINAPI renderThreadProc(LPVOID param);
    void renderLoop();

    uint32_t ringAvailable() const;
    uint32_t ringCapacity() const { return kBufferFrames; }
};

#endif // _WIN32
