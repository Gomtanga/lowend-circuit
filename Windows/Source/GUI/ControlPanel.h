// ControlPanel.h — the GUI's controls, and the only place it touches Settings.
//
// This file deliberately knows nothing about DSP or device I/O. It reads and
// writes the engine's own Settings / EngineOptions types and enumerates
// endpoints through the engine's listDevices(), so the GUI cannot drift from
// the CLI or acquire a settings model of its own.

#pragma once

#include "AudioEngine/Devices.h"
#include "AudioEngine/Engine.h"
#include "AudioEngine/Settings.h"

#include <windows.h>

#include <string>
#include <vector>

namespace lowend::win::gui {

// Control identifiers. Values are stable so a test or a future dialog
// procedure can address them.
//
// There is no separate capture-mode control: the capture combo lists system
// audio items followed by input items, and the selection itself is the mode.
enum ControlId : int {
    idCaptureDevice = 1000,
    idRenderDevice,
    idRefreshDevices,
    idModel,
    idExciterOversampling,
    idIntensity,
    idBody,
    idOutput,
    idSpatialEnable,
    idSpace,
    idStageWidth,
    idListenerX,
    idListenerZ,
    idStartStop,
    idStatus,
    idFirst = idCaptureDevice,
    idLast = idStatus,
    controlIdCount = idLast - idFirst + 1,
};

class ControlPanel {
public:
    // Creates every child control at fixed positions. The window is not
    // resizable, so the layout is computed once here rather than in WM_SIZE.
    bool create(HWND parent, HINSTANCE instance);

    // Fills the device lists from the engine's enumeration and keeps the
    // current selection when the endpoint is still present.
    void refreshDevices();

    // Control values as the engine's own types. The caller normalizes before
    // starting, exactly as the CLI does.
    Settings readSettings() const;
    EngineOptions readEngineOptions() const;

    // Pushes settings into the controls (used at startup).
    void writeSettings(const Settings& settings);

    // Enables/disables the run controls and flips the button label.
    void setRunning(bool running);

    // Status line: route summary, live statistics, or the last error.
    void setStatusText(const std::wstring& text);
    void setStatisticsText(const std::wstring& text);

    // Writes the current slider positions into the readouts beside them, so the
    // numeric value of a setting is visible without hovering anything. Called
    // after a control changes, and after writeSettings().
    void refreshValueLabels();

    HWND handle(ControlId id) const;
    HWND parent() const { return parent_; }

    // Window client size the controls are laid out for.
    //
    // The height is set by the status box, which is the tallest thing here. Its
    // longest content is a running loopback stream: the settings summary, the
    // route with its two loopback notes, the running model, the statistics line
    // and any recovery or error guidance. Measured in the real window that is
    // 256 px at this width, so a box smaller than that silently hides the tail -
    // and the tail is where the statistics and the error guidance live, which are
    // the parts a user reads when something is wrong. The status box is given a
    // fixed height below rather than "whatever is left", so the two cannot drift
    // apart again.
    static constexpr int clientWidth() { return 760; }
    static constexpr int clientHeight() { return 760; }
    // Height of the status box. It holds the settings summary, the route, the
    // running model, the statistics line and any error guidance, which measured
    // 256 px in the real window for a running loopback stream - the tallest
    // content there is. Sizing it by "whatever is left" is what hid the tail of
    // that text, and the tail is where the statistics and the error guidance are.
    static constexpr int statusHeight() { return 276; }

private:
    void createLabel(const wchar_t* text, int x, int y, int width);
    // The range comes from specFor(id), so callers pass only the geometry.
    void createTrackbar(ControlId id, int x, int y, int width);
    void createValueLabel(ControlId id, int x, int y, int width);

    // Control identifiers are absolute (1000+), so every array access goes
    // through these. Indexing the arrays by the identifier itself would write
    // far past their end.
    static constexpr int indexOf(ControlId id) {
        return static_cast<int>(id) - static_cast<int>(idFirst);
    }
    HWND& controlSlot(ControlId id) { return controls_[indexOf(id)]; }
    HWND controlHandle(ControlId id) const { return controls_[indexOf(id)]; }
    HWND& valueSlot(ControlId id) { return valueLabels_[indexOf(id)]; }

    HWND parent_ = nullptr;
    HINSTANCE instance_ = nullptr;
    HWND controls_[controlIdCount] {};
    // Readout next to each trackbar, indexed by the trackbar's ControlId.
    HWND valueLabels_[controlIdCount] {};

    // Device ids parallel to the combo box items, which hold only the display
    // string. Empty for a combo that has not been populated yet.
    std::vector<std::string> captureIds_;
    std::vector<std::string> renderIds_;
};

} // namespace lowend::win::gui
