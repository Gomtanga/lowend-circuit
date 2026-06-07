// LowEnd Circuit — Windows Native Prototype
//
// Step 3: Core CircuitBass DSP integration.
// Captures loopback audio → processes through Core::CircuitBass → (playback later).

#ifdef _WIN32
#include <windows.h>
#include <stdio.h>
#include "WasapiLoopbackCapture.h"

// ─── Core DSP ─────────────────────────────────────────────────
#include <Core/CircuitBass.h>
#include <Core/Core.h>

// Persistent DSP state (initialised in main, used from callback)
static lowend::CircuitBass* g_circuitBass = nullptr;
static float g_outputGain = 1.0f;

// Audio processing callback — called from capture thread (realtime-safe)
static void processAudio(float* samples, uint32_t frames, uint32_t channels,
                         uint32_t sampleRate, void* /*userData*/) {
    if (!g_circuitBass || channels < 1) return;

    for (uint32_t s = 0; s < frames; ++s) {
        if (channels >= 2) {
            float l = samples[s * 2];
            float r = samples[s * 2 + 1];
            g_circuitBass->process(l, r, l, r);
            samples[s * 2]     = l * g_outputGain;
            samples[s * 2 + 1] = r * g_outputGain;
        } else {
            float m = samples[s];
            float _unused;
            g_circuitBass->process(m, m, m, _unused);
            samples[s] = m * g_outputGain;
        }
    }
}

int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("Status: boot OK\n");
    printf("Platform: Windows\n");
    printf("Step 3: Core CircuitBass DSP\n");

    // ─── Initialise Core DSP ──────────────────────────────
    printf("\n--- Initialising Core::CircuitBass ---\n");

    lowend::CircuitBass circuitBass;
    g_circuitBass = &circuitBass;

    // Configure with moderate Circuit model settings
    auto dspConfig = lowend::DSPPrecompute::makeDSPSettings(
        48000.0f,   // sample rate (will be updated when capture starts)
        55.0f,      // intensity
        30.0f,      // body
        -1.5f,      // output dB
        1           // dspModel: Circuit
    );
    circuitBass.update(dspConfig);
    printf("CircuitBass initialised: intensity=55, body=30, output=-1.5 dB\n");

    // ─── WASAPI Loopback Capture ──────────────────────────
    printf("\n--- WASAPI Loopback Capture ---\n");

    WasapiLoopbackCapture capture;
    if (capture.initialize()) {
        printf("Capture format: %lu Hz, %lu channels\n",
               capture.sampleRate(), capture.channels());

        // Update Core DSP to match actual sample rate
        if (capture.sampleRate() != 48000) {
            auto actualConfig = lowend::DSPPrecompute::makeDSPSettings(
                static_cast<float>(capture.sampleRate()),
                55.0f, 30.0f, -1.5f, 1);
            circuitBass.update(actualConfig);
            printf("DSP reconfigured for %lu Hz\n", capture.sampleRate());
        }

        // Wire up the processing callback
        capture.setProcessCallback(processAudio, nullptr);
        printf("Processing callback set: Core::CircuitBass\n");

        printf("Starting capture + DSP for 3 seconds...\n");
        capture.start();

        // Run for 3 seconds
        Sleep(3000);

        capture.stop();
        printf("Capture + DSP stopped.\n");
    } else {
        printf("Loopback capture not available (expected on CI without audio HW).\n");
        printf("Core::CircuitBass initialisation confirmed.\n");
    }

    g_circuitBass = nullptr;
    printf("\nPrototype complete.\n");
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
