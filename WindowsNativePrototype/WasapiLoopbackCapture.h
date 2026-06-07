// WasapiLoopbackCapture.h — Windows WASAPI loopback capture
//
// Captures the audio stream from the default render endpoint
// (what the user hears from speakers/headphones).
//
// Usage:
//   WasapiLoopbackCapture capture;
//   if (capture.initialize()) {
//       capture.start();
//       // ... process audio ...
//       capture.stop();
//   }
//
// Reference: https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording

#pragma once

#ifdef _WIN32

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <stdio.h>

class WasapiLoopbackCapture {
public:
    WasapiLoopbackCapture();
    ~WasapiLoopbackCapture();

    // Initialise COM + device enumerator + IAudioClient in loopback mode.
    // Returns false if no default render device is available (expected on CI).
    bool initialize();

    // Start capturing (pulls audio from the loopback endpoint).
    bool start();

    // Stop capture and release resources.
    void stop();

    // Access the capture client (null if not initialised).
    IAudioCaptureClient* captureClient() const { return captureClient_; }

    // Audio format details (valid after initialize() succeeds).
    uint32_t sampleRate() const { return sampleRate_; }
    uint32_t channels() const { return channels_; }

private:
    // COM
    bool initialized_ = false;
    bool comInitialized_ = false;

    // Device
    IMMDeviceEnumerator* enumerator_ = nullptr;
    IMMDevice* device_ = nullptr;

    // Audio client (loopback mode)
    IAudioClient* audioClient_ = nullptr;
    IAudioCaptureClient* captureClient_ = nullptr;

    // Format
    uint32_t sampleRate_ = 0;
    uint32_t channels_ = 0;

    // Event for buffer readiness
    HANDLE captureEvent_ = nullptr;

    // Callback thread handle
    HANDLE captureThread_ = nullptr;
    volatile bool running_ = false;

    static DWORD WINAPI captureThreadProc(LPVOID param);
    void processCapturedData();
};

#endif // _WIN32
