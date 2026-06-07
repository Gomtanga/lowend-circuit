// LowEnd Circuit — Windows Native Prototype
//
// Step 1: Minimal console app to verify build environment.
// No WASAPI or DSP yet — just validate that CMake + MSVC + Windows SDK
// are set up correctly.

#ifdef _WIN32
#include <windows.h>
#include <stdio.h>

int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("Status: boot OK\n");
    printf("Platform: Windows\n");

    // Print Windows version info
    OSVERSIONINFOW osvi = { sizeof(osvi) };
    #pragma warning(suppress : 4996)
    GetVersionExW(&osvi);
    printf("Windows version: %lu.%lu.%lu\n",
           (unsigned long)osvi.dwMajorVersion,
           (unsigned long)osvi.dwMinorVersion,
           (unsigned long)osvi.dwBuildNumber);

    // Validate that required DLLs are available (load without starting)
    HMODULE ole32 = LoadLibraryW(L"ole32.dll");
    HMODULE avrt  = LoadLibraryW(L"avrt.dll");
    printf("ole32.dll: %s\n", ole32 ? "available" : "NOT FOUND");
    printf("avrt.dll:  %s\n", avrt  ? "available" : "NOT FOUND");
    if (ole32) FreeLibrary(ole32);
    if (avrt)  FreeLibrary(avrt);

    printf("\nBuild environment verified. Ready for Step 2.\n");
    return 0;
}

#else
// Non-Windows stub — just a placeholder
#include <stdio.h>
int main() {
    printf("LowEnd Circuit — Windows Native Prototype\n");
    printf("=========================================\n");
    printf("This prototype requires Windows.\n");
    printf("Build with Visual Studio 2022 on a Windows host or CI.\n");
    return 0;
}
#endif
