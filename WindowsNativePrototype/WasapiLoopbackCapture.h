// WasapiLoopbackCapture.h — Windows WASAPI loopback capture

#pragma once

#ifdef _WIN32

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <cstdint>
#include <cstdio>

class WasapiLoopbackCapture {
public:
    WasapiLoopbackCapture();
    ~WasapiLoopbackCapture();

    bool initialize();
    bool start();
    void stop();

    IAudioCaptureClient* captureClient() const { return captureClient_; }
    uint32_t sampleRate() const { return sampleRate_; }
    uint32_t channels() const { return channels_; }

private:
    bool initialized_ = false;
    bool comInitialized_ = false;

    IMMDeviceEnumerator* enumerator_ = nullptr;
    IMMDevice* device_ = nullptr;
    IAudioClient* audioClient_ = nullptr;
    IAudioCaptureClient* captureClient_ = nullptr;

    uint32_t sampleRate_ = 0;
    uint32_t channels_ = 0;

    HANDLE captureEvent_ = nullptr;
    HANDLE captureThread_ = nullptr;
    volatile bool running_ = false;

    static DWORD WINAPI captureThreadProc(LPVOID param);
    void processCapturedData(uint64_t& totalFrames);
};

#endif // _WIN32
