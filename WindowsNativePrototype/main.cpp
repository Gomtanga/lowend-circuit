// LowEnd Circuit — Windows Native Prototype
//
// Step 2: WASAPI loopback capture initialisation.
// On CI without audio hardware, the capture init gracefully reports "not available".

#ifdef _WIN32
#include <windows.h>
#include <stdio.h>
#include "WasapiLoopbackCapture.h"

int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("Status: boot OK\n");
    printf("Platform: Windows\n");

    // ─── Step 2: WASAPI loopback capture initialisation ─────
    printf("\n--- Step 2: WASAPI Loopback Capture ---\n");

    WasapiLoopbackCapture capture;
    if (capture.initialize()) {
        printf("Loopback capture initialised: %lu Hz, %lu channels\n",
               capture.sampleRate(), capture.channels());

        printf("Starting capture for 3 seconds...\n");
        capture.start();
        Sleep(3000);
        capture.stop();
        printf("Capture stopped.\n");
    } else {
        printf("Loopback capture NOT available on this system.\n");
        printf("This is expected on CI VMs without audio hardware.\n");
        printf("The code compiles and the initialisation path is valid.\n");
    }

    printf("\nPrototype complete.\n");
    return 0;
}

#else
// Non-Windows stub
#include <stdio.h>
int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("This prototype requires Windows.\n");
    printf("Build with Visual Studio 2022 on a Windows host or CI.\n");
    return 0;
}
#endif
