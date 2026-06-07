// LowEnd Circuit — Windows Native Prototype
//
// Step 4: End-to-end pipeline.
//   WASAPI loopback capture → Core CircuitBass DSP → WASAPI render playback
//
// Build & run (Windows):
//   cmake -S WindowsNativePrototype -B build/win-proto -G "Visual Studio 17 2022" -A x64
//   cmake --build build/win-proto --config Release
//   build/win-proto/Release/LowEndWinPrototype.exe

#ifdef _WIN32
#include <windows.h>
#include <stdio.h>
#include "WasapiLoopbackCapture.h"
#include "WasapiPlayback.h"

// ─── Core DSP ─────────────────────────────────────────────────
#include <Core/CircuitBass.h>
#include <Core/Core.h>

// Shared DSP + playback state (set up in main, used from capture callback)
static lowend::CircuitBass* g_circuitBass = nullptr;
static WasapiPlayback* g_playback = nullptr;

// Audio processing callback — capture thread, realtime-sensitive
static void processAudio(float* samples, uint32_t frames, uint32_t channels,
                         uint32_t sampleRate, void* /*userData*/) {
    if (!g_circuitBass || channels < 1) return;

    // Process through Core CircuitBass (in-place)
    for (uint32_t s = 0; s < frames; ++s) {
        if (channels >= 2) {
            float l = samples[s * 2];
            float r = samples[s * 2 + 1];
            g_circuitBass->process(l, r, l, r);
            samples[s * 2]     = l;
            samples[s * 2 + 1] = r;
        } else {
            float m = samples[s];
            float _unused;
            g_circuitBass->process(m, m, m, _unused);
            samples[s] = m;
        }
    }

    // Forward processed audio to playback
    if (g_playback) {
        g_playback->submitInterleaved(samples, frames);
    }
}

int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("Version: Step 4 — End-to-End Pipeline\n");
    printf("Pipeline: Loopback Capture → Core CircuitBass → Playback\n\n");

    // ─── 1. Initialise Core DSP ───────────────────────────
    printf("[dsp] Initialising Core::CircuitBass...\n");

    lowend::CircuitBass circuitBass;
    g_circuitBass = &circuitBass;

    auto dspConfig = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f, 55.0f, 30.0f, -1.5f, 1);
    circuitBass.update(dspConfig);
    printf("[dsp] CircuitBass ready: intensity=55, body=30, output=-1.5 dB\n");

    // ─── 2. Initialise WASAPI Playback ────────────────────
    printf("\n[playback] Initialising WASAPI render...\n");

    WasapiPlayback playback;
    if (!playback.initialize()) {
        printf("[playback] FAILED — cannot continue without render device.\n");
        printf("  Expected on CI VMs. Run on a Windows PC with audio hardware.\n");
        g_circuitBass = nullptr;
        printf("\nPrototype incomplete (no playback device).\n");
        return 0;
    }
    g_playback = &playback;
    printf("[playback] Ready: %lu Hz, %lu channels\n",
           playback.sampleRate(), playback.channels());

    // Reconfigure DSP to match render format
    if (playback.sampleRate() != 48000) {
        auto actualConfig = lowend::DSPPrecompute::makeDSPSettings(
            static_cast<float>(playback.sampleRate()),
            55.0f, 30.0f, -1.5f, 1);
        circuitBass.update(actualConfig);
        printf("[dsp] Reconfigured for %lu Hz\n", playback.sampleRate());
    }

    // ─── 3. Initialise WASAPI Capture ────────────────────
    printf("\n[capture] Initialising WASAPI loopback capture...\n");

    WasapiLoopbackCapture capture;
    if (!capture.initialize()) {
        printf("[capture] FAILED — loopback not available on this system.\n");
        g_playback = nullptr;
        g_circuitBass = nullptr;
        playback.stop();
        printf("\nPrototype incomplete (no capture device).\n");
        return 0;
    }

    printf("[capture] Format: %lu Hz, %lu channels\n",
           capture.sampleRate(), capture.channels());

    // Wire DSP callback
    capture.setProcessCallback(processAudio, nullptr);
    printf("[capture] Processing callback set.\n");

    // ─── 4. Start Pipeline ────────────────────────────────
    printf("\n=== Starting pipeline ===\n");
    printf("  Capture → Core CircuitBass → Playback\n");
    printf("  Running for 5 seconds...\n\n");

    if (!playback.start()) {
        printf("[playback] Start failed.\n");
        g_playback = nullptr;
        g_circuitBass = nullptr;
        return 1;
    }

    if (!capture.start()) {
        printf("[capture] Start failed.\n");
        g_playback = nullptr;
        g_circuitBass = nullptr;
        playback.stop();
        return 1;
    }

    printf("[pipeline] ACTIVE — listening and processing...\n");

    // Run pipeline for 5 seconds
    Sleep(5000);

    // ─── 5. Stop Pipeline ─────────────────────────────────
    printf("\n=== Stopping pipeline ===\n");
    capture.stop();
    playback.stop();
    g_playback = nullptr;
    g_circuitBass = nullptr;

    printf("\n✅ Prototype complete.\n");
    printf("   Pipeline ran for 5 seconds.\n");
    printf("   If you heard processed audio, Core CircuitBass is working.\n");
    return 0;
}

#else
#include <stdio.h>
int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("This prototype requires Windows.\n");
    printf("Build with Visual Studio 2022 on a Windows host or CI.\n");
    return 0;
}
#endif
