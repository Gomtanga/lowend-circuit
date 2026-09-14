// MainWindow.h — the GUI's window and its timer-driven status updates.
//
// The window owns an Engine and drives it the same way the CLI does: start with
// a normalized Settings snapshot, request updates while running, poll stats()
// on a timer, and stop before destroying. It never calls the DSP or the device
// layer directly.

#pragma once

#include "AudioEngine/Engine.h"
#include "GUI/ControlPanel.h"

#include <windows.h>

#include <memory>
#include <string>

namespace lowend::win::gui {

class MainWindow {
public:
    static constexpr const wchar_t* className = L"LowEndCircuitWindow";
    static constexpr UINT_PTR statusTimerId = 1;
    // Statistics refresh cadence. Fast enough to see dropouts, slow enough that
    // the UI never becomes the bottleneck.
    static constexpr UINT statusIntervalMs = 500;

    bool registerClass(HINSTANCE instance);
    bool create(HINSTANCE instance, int showCommand);

    HWND handle() const { return window_; }

    // Message handlers, invoked from the window procedure.
    void onCommand(int controlId, int notification);
    // A trackbar reports drags and clicks through WM_HSCROLL, which is a
    // different notification from WM_COMMAND.
    void onSliderMoved(int controlId);
    void onTimer();
    void onDestroy();

    // Starts or stops the engine. Returns false and shows the error on failure.
    bool toggleEngine();
    bool startEngine();
    void stopEngine();

private:
    void layoutChildren();
    void refreshDeviceLists();
    void updateStatusText();
    // Repaints the readouts and forwards the new settings to the engine.
    void applySliderChange();

    HINSTANCE instance_ = nullptr;
    HWND window_ = nullptr;
    ControlPanel panel_;
    std::unique_ptr<Engine> engine_;
    std::string startError_;
    bool running_ = false;
};

} // namespace lowend::win::gui
