// MainWindow.cpp — window creation, engine lifecycle, and status reporting.
//
// The GUI is a thin front end over the same Engine the CLI uses. It normalizes
// settings (the engine's own normalized()), starts or stops the engine, pushes
// live control changes as settings requests, and polls stats() on a timer. No
// DSP and no device handling happens here.

#include "GUI/MainWindow.h"

#include <commctrl.h>

#include <cstdio>
#include <string>

namespace lowend::win::gui {
namespace {

// Window procedure trampoline: the GWLP_USERDATA slot holds the MainWindow.
LRESULT CALLBACK windowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    MainWindow* self = reinterpret_cast<MainWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));

    switch (message) {
        case WM_NCCREATE: {
            auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
            SetWindowLongPtrW(window, GWLP_USERDATA,
                              reinterpret_cast<LONG_PTR>(create->lpCreateParams));
            return DefWindowProcW(window, message, wParam, lParam);
        }
        case WM_CREATE:
            if (self != nullptr) {
                // The controls are created here so the window is already valid.
                // The panel is created by MainWindow::create after this returns.
            }
            return 0;
        case WM_COMMAND:
            if (self != nullptr) {
                self->onCommand(LOWORD(wParam), HIWORD(wParam));
            }
            return 0;
        case WM_HSCROLL:
            // A trackbar reports every user drag and click through WM_HSCROLL to
            // its parent, not WM_COMMAND. Without this case the thumb moved and
            // the audio thread could pick the new value up on its next poll, but
            // the number beside the slider and the status line kept showing the
            // value from before the drag — the readout disagreed with what was
            // actually being applied.
            if (self != nullptr && lParam != 0) {
                self->onSliderMoved(static_cast<int>(GetDlgCtrlID(
                    reinterpret_cast<HWND>(lParam))));
            }
            return 0;
        case WM_TIMER:
            if (self != nullptr && wParam == MainWindow::statusTimerId) {
                self->onTimer();
            }
            return 0;
        case WM_CLOSE:
            // Stop the engine before the window goes away: destroy() would
            // otherwise tear down the UI while audio threads are still running.
            if (self != nullptr) {
                self->stopEngine();
            }
            DestroyWindow(window);
            return 0;
        case WM_DESTROY:
            if (self != nullptr) {
                self->onDestroy();
            }
            PostQuitMessage(0);
            return 0;
        default:
            break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    if (size <= 1) return {};
    std::wstring out(static_cast<size_t>(size - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
    return out;
}

// Slider position to display value, matching ControlPanel's scale.
constexpr int sliderScale = 10;

std::wstring describe(const Settings& settings) {
    wchar_t buffer[512];
    std::swprintf(buffer, sizeof(buffer) / sizeof(buffer[0]),
                  L"model %hs   LowEnd %.1f   Body %.1f   Output %.1f dB   "
                  L"harmonics %hs   spatial %hs   space %.0f",
                  dspModelName(settings.dspModel),
                  static_cast<double>(settings.intensity),
                  static_cast<double>(settings.body),
                  static_cast<double>(settings.outputDb),
                  oversamplingModeName(settings.exciterOversamplingMode),
                  settings.spatialEnabled ? "on" : "off",
                  static_cast<double>(settings.space));
    return std::wstring(buffer);
}

} // namespace

bool MainWindow::registerClass(HINSTANCE instance) {
    instance_ = instance;

    WNDCLASSEXW windowClass {};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = windowProcedure;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
    windowClass.lpszClassName = className;
    windowClass.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    windowClass.hIconSm = LoadIconW(nullptr, IDI_APPLICATION);

    return RegisterClassExW(&windowClass) != 0;
}

bool MainWindow::create(HINSTANCE instance, int showCommand) {
    // A fixed client area: the layout is absolute, so the window is not
    // resizable and the style omits WS_THICKFRAME.
    RECT desired { 0, 0, ControlPanel::clientWidth(), ControlPanel::clientHeight() };
    AdjustWindowRectEx(&desired, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
                       FALSE, 0);

    window_ = CreateWindowExW(
        0, className, L"LowEnd Circuit",
        // Deliberately without WS_VISIBLE. The controls do not exist yet, so a
        // visible window here is an empty frame the user watches while the panel
        // builds its controls and the device lists are enumerated - measured at
        // 70-130 ms on this machine. ShowWindow() below reveals the window once
        // every control has been created and laid out, so the user only ever sees
        // the finished window.
        (WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX),
        CW_USEDEFAULT, CW_USEDEFAULT,
        desired.right - desired.left, desired.bottom - desired.top,
        nullptr, nullptr, instance, this);

    if (window_ == nullptr) {
        return false;
    }

    if (!panel_.create(window_, instance)) {
        DestroyWindow(window_);
        window_ = nullptr;
        return false;
    }

    refreshDeviceLists();

    Settings defaults;
    panel_.writeSettings(defaults);
    // The status line is composed by updateStatusText(), not set to a bare
    // "Idle." here: the routing guidance (what this machine offers for the
    // virtual-cable route, and how to get sound back if Windows' default output
    // is still the cable) belongs on screen when the window opens, not only
    // after the user has already touched a control.
    panel_.setRunning(false);
    updateStatusText();

    ShowWindow(window_, showCommand);
    UpdateWindow(window_);
    return true;
}

void MainWindow::refreshDeviceLists() {
    panel_.refreshDevices();
}

void MainWindow::onCommand(int controlId, int notification) {
    // A device selection is remembered in the user's own profile as soon as it
    // changes, so a restart comes back to the endpoints the user chose rather
    // than to whatever is first in the list.
    if ((controlId == idCaptureDevice || controlId == idRenderDevice)
        && notification == CBN_SELCHANGE) {
        panel_.saveDeviceSelection();
        updateStatusText();
        return;
    }

    // A control the user is dragging changes the settings of a running engine
    // immediately; the engine queues it for the audio thread, so a drag never
    // blocks the UI and never restarts the stream.
    const bool isSlider = controlId >= idIntensity && controlId <= idListenerZ;
    if (isSlider && notification == 0 /* trackbar */) {
        applySliderChange();
        return;
    }

    switch (controlId) {
        case idStartStop:
            toggleEngine();
            return;
        case idRefreshDevices:
            refreshDeviceLists();
            return;
        case idModel:
        case idExciterOversampling:
        case idSpatialEnable:
            if (running_ && engine_ != nullptr) {
                engine_->requestSettings(panel_.readSettings());
            }
            updateStatusText();
            return;
        default:
            return;
    }
}

void MainWindow::onSliderMoved(int controlId) {
    if (controlId < idIntensity || controlId > idListenerZ) {
        // Another control sent the scroll notification; nothing to do. Reporting
        // a value for a control that is not a slider would read the wrong
        // handle out of the panel.
        return;
    }
    applySliderChange();
}

void MainWindow::applySliderChange() {
    // The readout and any live engine update both come from one read of the
    // controls, so the displayed number is the value that was sent.
    panel_.refreshValueLabels();
    updateStatusText();
    if (running_ && engine_ != nullptr) {
        engine_->requestSettings(panel_.readSettings());
    }
}

void MainWindow::onTimer() {
    updateStatusText();
}

bool MainWindow::toggleEngine() {
    if (running_) {
        stopEngine();
        return true;
    }
    return startEngine();
}

bool MainWindow::startEngine() {
    // A combo with no selection means the *saved* endpoint is gone. Refusing here
    // is the point: starting anyway would open whichever endpoint happens to be
    // default, which is a route the user never chose and cannot see.
    if (!panel_.hasDeviceSelection()) {
        panel_.setStatusText(
            L"Cannot start: an endpoint saved from the last run is no longer present.\n\n"
            L"There is no selection for it in the list above, and picking a device on the\n"
            L"user's behalf would process a route they did not choose. Choose the capture\n"
            L"source and the output endpoint again, then Start.");
        return false;
    }

    const Settings settings = panel_.readSettings();
    EngineOptions options = panel_.readEngineOptions();

    // The engine opens one capture endpoint and a different render endpoint and
    // refuses the combination that would feed its own output back into its own
    // capture. Surface that here rather than letting it look like a silent
    // failure, since the two combo boxes make it easy to pick the same device.
    if (options.captureFlow == DataFlow::render
        && !options.captureDeviceId.empty()
        && options.captureDeviceId == options.renderDeviceId) {
        panel_.setStatusText(
            L"Cannot start: the capture and output endpoints are the same device.\n\n"
            L"WASAPI loopback copies what the endpoint plays instead of replacing it, so\n"
            L"playing the processed result back into the same endpoint would capture it\n"
            L"again as input. Choose a different output endpoint.");
        return false;
    }

    engine_ = std::make_unique<Engine>(options);
    std::string error;
    if (!engine_->start(settings, error)) {
        panel_.setStatusText(L"Failed to start: " + widen(error));
        engine_.reset();
        return false;
    }

    running_ = true;
    panel_.setRunning(true);
    SetTimer(window_, statusTimerId, statusIntervalMs, nullptr);
    updateStatusText();
    return true;
}

void MainWindow::stopEngine() {
    if (!running_) {
        return;
    }
    KillTimer(window_, statusTimerId);
    if (engine_ != nullptr) {
        engine_->stop();
    }
    running_ = false;
    panel_.setRunning(false);
    updateStatusText();
}

void MainWindow::onDestroy() {
    KillTimer(window_, statusTimerId);
    if (engine_ != nullptr) {
        engine_->stop();
        engine_.reset();
    }
    running_ = false;
    window_ = nullptr;
}

void MainWindow::updateStatusText() {
    const Settings settings = panel_.readSettings();
    std::wstring text = describe(settings);

    if (!running_ || engine_ == nullptr) {
        // What this machine offers for routing, and what stopping means: the
        // engine renders to the endpoint selected above and never touches
        // Windows' default output, so a user who set the default output to a
        // virtual cable hears nothing while LowEnd is stopped. Stated here
        // rather than fixed automatically - changing the default output behind
        // the user's back is exactly what this build does not do.
        std::wstring idle = text + L"\n\nIdle.\n\n" + panel_.virtualCableNote();
        idle += L"\n\nLowEnd renders to the endpoint chosen above and never changes Windows'\n"
                L"default output. If you set the default output to a virtual cable, sound\n"
                L"stops reaching your device whenever LowEnd is stopped: set it back in\n"
                L"Settings > System > Sound > Output.";
        panel_.setStatusText(idle);
        return;
    }

    const EngineStats stats = engine_->stats();
    const EngineOptions options = panel_.readEngineOptions();

    // The panel shows what was selected; this shows what the audio thread is
    // actually running. They differ briefly after a change, because a settings
    // edit is queued and applied at a block boundary, and they differ
    // permanently if a queued edit could not be accepted. Reporting both is what
    // makes the difference visible instead of leaving the user to assume the
    // control took effect.
    wchar_t route[640];
    std::swprintf(route, sizeof(route) / sizeof(route[0]),
                  L"\nrunning model: %hs (selected %hs)\n"
                  L"\ncapture %hs @ %u Hz  ->  output @ %u Hz (%u frames, %.1f ms period)\n"
                  L"engine latency %.1f / %.1f ms   frames %llu   dropped %llu   "
                  L"underrun %llu   resyncs %u   errors %u/%u",
                  dspModelName(stats.activeDSPModel),
                  dspModelName(settings.dspModel),
                  stats.captureIsLoopback ? "loopback" : "input",
                  stats.captureSampleRate,
                  stats.renderSampleRate,
                  stats.renderBufferFrames,
                  stats.renderPeriodMs,
                  stats.captureStreamLatencyMs,
                  stats.renderStreamLatencyMs,
                  static_cast<unsigned long long>(stats.totalReadSamples / 2),
                  static_cast<unsigned long long>(stats.droppedSamples),
                  static_cast<unsigned long long>(stats.underrunSamples),
                  stats.resyncCount,
                  stats.captureErrors,
                  stats.renderErrors);

    // `text` ends without a newline and the route starts with "capture:", so the
    // separator has to be added here. Without it the settings and the route ran
    // together on one line ("... space 35capture: input ..."), which reads as a
    // single broken value rather than two blocks of information. `route` already
    // begins with its own newline, which is why there is not one added after it.
    std::wstring full = text + L"\n" + widen(describeRoute(stats, options)) + route;

    // A recovered endpoint is worth showing: the stream continued, and the user
    // should be able to tell that from a stream that never had a problem.
    if (stats.recoveredStreams != 0) {
        wchar_t recovered[128];
        std::swprintf(recovered, sizeof(recovered) / sizeof(recovered[0]),
                      L"\nreopened the device %u time(s) after a failure",
                      stats.recoveredStreams);
        full += recovered;
    }

    if (stats.givingUp) {
        full += L"\n\nThe device failed and could not be recovered by reopening it. "
                L"Press Stop, then Start.";
    } else if (stats.captureErrors != 0 || stats.renderErrors != 0) {
        full += L"\n\nThe stream ended with a device error. Press Stop, then Start.";
    }
    panel_.setStatusText(full);
}

} // namespace lowend::win::gui
