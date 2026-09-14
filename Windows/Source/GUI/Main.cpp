// Main.cpp — GUI entry point.
//
// Deliberately tiny: initialize COM and the common controls, create the window,
// run the message loop. Every audio decision lives in the engine the CLI also
// uses, and every control lives in ControlPanel.

#include "GUI/MainWindow.h"
#include "AudioEngine/Settings.h"

#include <commctrl.h>
#include <objbase.h>
#include <windows.h>

#pragma comment(linker, "\"/manifestdependency:type='win32' \
name='Microsoft.Windows.Common-Controls' version='6.0.0.0' \
processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    // COM is required to enumerate and open audio endpoints. The engine's own
    // threads join the MTA themselves, so this only covers the UI thread.
    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    // The slider and list controls come from the version 6 common controls;
    // without this the panel still works but looks like Windows 95.
    INITCOMMONCONTROLSEX controls {};
    controls.dwSize = sizeof(controls);
    controls.dwICC = ICC_BAR_CLASSES | ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&controls);

    lowend::win::gui::MainWindow window;
    if (!window.registerClass(instance)) {
        MessageBoxW(nullptr, L"Failed to register the window class.", L"LowEnd Circuit",
                    MB_ICONERROR | MB_OK);
        return 1;
    }
    if (!window.create(instance, showCommand)) {
        MessageBoxW(nullptr, L"Failed to create the window.", L"LowEnd Circuit",
                    MB_ICONERROR | MB_OK);
        return 1;
    }

    MSG message {};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        // The panel has no child that wants keys, so no IsDialogMessage.
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    if (SUCCEEDED(comResult)) {
        CoUninitialize();
    }
    return static_cast<int>(message.wParam);
}
