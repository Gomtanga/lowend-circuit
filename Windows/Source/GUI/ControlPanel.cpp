// ControlPanel.cpp — control creation, device lists, and Settings read/write.
//
// Everything the GUI shows or edits goes through the engine's own types and the
// engine's own device enumeration. There is no second settings model here, which
// is what keeps the GUI from diverging from the CLI.

#include "GUI/ControlPanel.h"

#include "AudioEngine/RouteDiagnosis.h"

#include <commctrl.h>
#include <shlobj.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>

namespace lowend::win::gui {
namespace {

// Layout constants. One column of labels, one of controls; the window is fixed
// size, so these are absolute.
constexpr int marginX = 16;
constexpr int labelWidth = 130;
constexpr int controlX = marginX + labelWidth;
constexpr int controlWidth = 420;
constexpr int rowHeight = 30;
constexpr int comboHeight = 220;
constexpr int trackbarHeight = 26;

// Slider precision. A trackbar is integer-only, so each control declares the
// number of divisions per unit it needs. The 0..100 amounts are fine at 0.1
// steps, but the metre-valued controls must be able to express their documented
// defaults exactly — speaker width defaults to 1.65 m, which a 0.1 step would
// silently round to 1.6 and hand the engine a different value than the CLI's.
constexpr int coarseScale = 10;   // 0.1 per step
constexpr int fineScale = 100;    // 0.01 per step

struct SliderSpec {
    int minimum;   // in units, scaled by `scale`
    int maximum;
    int scale;
};

// Returns the spec for a trackbar. `minimum`/`maximum` are in *scaled* units,
// the same units a trackbar position uses, so the range and the position/value
// conversion always agree.
SliderSpec specFor(ControlId id) {
    switch (id) {
        // Amounts are 0..100 and need 0.1 steps.
        case idIntensity: return { 0, 100 * coarseScale, coarseScale };
        case idBody: return { 0, 100 * coarseScale, coarseScale };
        case idSpace: return { 0, 100 * coarseScale, coarseScale };
        // Output is -18..+6 dB.
        case idOutput: return { -18 * coarseScale, 6 * coarseScale, coarseScale };
        // Metre values need 0.01 steps so their defaults survive exactly.
        case idStageWidth: return { 60, 300, fineScale };      // 0.60 .. 3.00 m
        case idListenerX: return { -300, 300, fineScale };     // -3.00 .. 3.00 m
        case idListenerZ: return { -280, 280, fineScale };     // -2.80 .. 2.80 m
        default: return { 0, 100 * coarseScale, coarseScale };
    }
}

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
    if (size <= 1) return {};
    std::wstring out(static_cast<size_t>(size - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
    return out;
}

// Bluetooth endpoints negotiate the least predictable period and are the usual
// cause of an underrun, so they are called out in both lists.
bool isBluetooth(const DeviceInfo& device) {
    std::string factor = device.formFactor;
    std::transform(factor.begin(), factor.end(), factor.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return factor.find("bluetooth") != std::string::npos;
}

std::wstring formatValue(const wchar_t* format, double value) {
    wchar_t buffer[64];
    std::swprintf(buffer, sizeof(buffer) / sizeof(buffer[0]), format, value);
    return std::wstring(buffer);
}

// Slider position to value. The position is in scaled units, so the scale
// divides it back out.
double fromSlider(int position, const SliderSpec& spec) {
    return static_cast<double>(spec.minimum + position) / static_cast<double>(spec.scale);
}

int toSlider(double value, const SliderSpec& spec) {
    const double scaled = value * static_cast<double>(spec.scale);
    const int raw = static_cast<int>(scaled + (scaled < 0.0 ? -0.5 : 0.5));
    const int position = raw - spec.minimum;
    return position < 0 ? 0 : position;
}

// Where the GUI remembers the endpoints the user chose.
//
// The user's own profile, never the repository or the program directory: the file
// names two endpoints of this machine, so it is user state, not project state,
// and it must not be shipped or committed. Nothing else is stored — no settings,
// no paths, no keys.
std::wstring deviceSelectionPath() {
    PWSTR localAppData = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &localAppData))
        || localAppData == nullptr) {
        return std::wstring();
    }
    std::wstring path = localAppData;
    CoTaskMemFree(localAppData);
    path += L"\\LowEndCircuit";
    CreateDirectoryW(path.c_str(), nullptr);  // already existing is not an error
    path += L"\\device-selection.txt";
    return path;
}

// Reads `key=value` lines. Anything else is ignored, so a hand-edited file with a
// comment or a stale key cannot break startup.
std::string readSelectionValue(const std::wstring& path, const char* key) {
    if (path.empty()) return {};
    std::ifstream file(path);
    if (!file) return {};
    const std::string prefix = std::string(key) + "=";
    std::string line;
    while (std::getline(file, line)) {
        if (line.compare(0, prefix.size(), prefix) != 0) continue;
        std::string value = line.substr(prefix.size());
        while (!value.empty() && (value.back() == '\r' || value.back() == '\n' || value.back() == ' ')) {
            value.pop_back();
        }
        return value;
    }
    return {};
}

} // namespace

bool ControlPanel::create(HWND parent, HINSTANCE instance) {
    parent_ = parent;
    instance_ = instance;

    // Controls are created in tab order; WS_TABSTOP gives keyboard navigation
    // without any custom handling.
    int y = marginX;

    createLabel(L"Capture", marginX, y + 5, labelWidth);
    controlSlot(idCaptureDevice) = CreateWindowExW(
        0, L"COMBOBOX", L"",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST,
        controlX, y, controlWidth, comboHeight, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idCaptureDevice)), instance, nullptr);
    y += rowHeight;

    createLabel(L"Output", marginX, y + 5, labelWidth);
    controlSlot(idRenderDevice) = CreateWindowExW(
        0, L"COMBOBOX", L"",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST,
        controlX, y, controlWidth, comboHeight, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idRenderDevice)), instance, nullptr);
    y += rowHeight + 6;

    controlSlot(idRefreshDevices) = CreateWindowExW(
        0, L"BUTTON", L"Refresh devices",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        controlX, y, 150, 26, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idRefreshDevices)), instance, nullptr);
    y += rowHeight + 10;

    createLabel(L"Model", marginX, y + 5, labelWidth);
    controlSlot(idModel) = CreateWindowExW(
        0, L"COMBOBOX", L"",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST,
        controlX, y, 180, 160, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idModel)), instance, nullptr);
    SendMessageW(controlSlot(idModel), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Clean"));
    SendMessageW(controlSlot(idModel), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Circuit"));
    SendMessageW(controlSlot(idModel), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"HighExciter"));

    createLabel(L"Harmonic quality", controlX + 200, y + 5, 120);
    controlSlot(idExciterOversampling) = CreateWindowExW(
        0, L"COMBOBOX", L"",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST,
        controlX + 200 + 120, y, 100, 160, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idExciterOversampling)), instance, nullptr);
    SendMessageW(controlSlot(idExciterOversampling), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"Auto"));
    SendMessageW(controlSlot(idExciterOversampling), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"1x"));
    SendMessageW(controlSlot(idExciterOversampling), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"2x"));
    SendMessageW(controlSlot(idExciterOversampling), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(L"4x"));
    y += rowHeight + 6;

    createTrackbar(idIntensity, controlX, y, controlWidth);
    createLabel(L"LowEnd", marginX, y + 6, labelWidth);
    createValueLabel(idIntensity, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight;

    createTrackbar(idBody, controlX, y, controlWidth);
    createLabel(L"Body", marginX, y + 6, labelWidth);
    createValueLabel(idBody, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight;

    createTrackbar(idOutput, controlX, y, controlWidth);
    createLabel(L"Output", marginX, y + 6, labelWidth);
    createValueLabel(idOutput, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight + 10;

    controlSlot(idSpatialEnable) = CreateWindowExW(
        0, L"BUTTON", L"Enable spatial processing",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
        marginX, y, 220, 22, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idSpatialEnable)), instance, nullptr);
    y += rowHeight;

    createTrackbar(idSpace, controlX, y, controlWidth);
    createLabel(L"Space", marginX, y + 6, labelWidth);
    createValueLabel(idSpace, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight;

    createTrackbar(idStageWidth, controlX, y, controlWidth);
    createLabel(L"Speaker width", marginX, y + 6, labelWidth);
    createValueLabel(idStageWidth, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight;

    createTrackbar(idListenerX, controlX, y, controlWidth);
    createLabel(L"Listener X", marginX, y + 6, labelWidth);
    createValueLabel(idListenerX, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight;

    createTrackbar(idListenerZ, controlX, y, controlWidth);
    createLabel(L"Listener Z", marginX, y + 6, labelWidth);
    createValueLabel(idListenerZ, controlX + controlWidth + 8, y + 6, 60);
    y += rowHeight + 10;

    controlSlot(idStartStop) = CreateWindowExW(
        0, L"BUTTON", L"Start",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        marginX, y, 150, 32, parent,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(idStartStop)), instance, nullptr);
    y += 42;

    controlSlot(idStatus) = CreateWindowExW(
        0, L"STATIC", L"",
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        marginX, y, clientWidth() - 2 * marginX, statusHeight(),
        parent, reinterpret_cast<HMENU>(static_cast<INT_PTR>(idStatus)), instance, nullptr);

    // The status box is the last control, so the client area has to hold it plus
    // the bottom margin. Checking the layout's own y rather than a hard-coded
    // figure means adding a row above makes this fail instead of silently
    // pushing the status text out of the window - which is exactly the defect
    // this replaces, where the box was sized as "whatever is left" and the tail
    // of the running status never appeared.
    if (y + statusHeight() + marginX > clientHeight()) {
        return false;
    }

    for (int index = 0; index < controlIdCount; ++index) {
        if (controls_[index] == nullptr) {
            return false;
        }
    }
    return true;
}

void ControlPanel::createLabel(const wchar_t* text, int x, int y, int width) {
    CreateWindowExW(0, L"STATIC", text, WS_CHILD | WS_VISIBLE | SS_LEFT,
                    x, y, width, 20, parent_, nullptr, instance_, nullptr);
}

void ControlPanel::createValueLabel(ControlId id, int x, int y, int width) {
    valueSlot(id) = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE | SS_LEFT,
                                    x, y, width, 20, parent_, nullptr, instance_, nullptr);
}

void ControlPanel::createTrackbar(ControlId id, int x, int y, int width) {
    // The range is always the scaled span of this control's spec, so the
    // position/value conversion and the draggable range cannot disagree.
    const SliderSpec spec = specFor(id);
    HWND& trackbar = controlSlot(id);
    trackbar = CreateWindowExW(
        0, TRACKBAR_CLASSW, L"",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | TBS_HORZ | TBS_NOTICKS,
        x, y, width, trackbarHeight, parent_,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), instance_, nullptr);
    SendMessageW(trackbar, TBM_SETRANGE, TRUE, MAKELPARAM(0, spec.maximum - spec.minimum));
    SendMessageW(trackbar, TBM_SETPAGESIZE, 0, spec.scale);
}

void ControlPanel::refreshDevices() {
    std::string error;

    // Outputs first: they are the render side and, for system-audio capture,
    // the capture side too.
    const std::vector<DeviceInfo> outputs = listDevices(DataFlow::render, error);
    const std::wstring previousRender = [&] {
        const int selection = static_cast<int>(SendMessageW(controlSlot(idRenderDevice), CB_GETCURSEL, 0, 0));
        const int index = selection < 0 ? 0 : selection;
        return index < static_cast<int>(renderIds_.size()) ? widen(renderIds_[index]) : std::wstring();
    }();
    // The capture selection needs the same treatment as the render one. It was
    // missing here, which meant every refresh silently reset the capture source
    // to the first entry: a user capturing a real input device was moved back to
    // the default output's system audio - the same endpoint the default render
    // selection points at. The next Start was then refused by the self-capture
    // guard, so a working configuration turned into a failed start for a reason
    // the user never chose.
    const std::wstring previousCapture = [&] {
        const int selection = static_cast<int>(SendMessageW(controlSlot(idCaptureDevice), CB_GETCURSEL, 0, 0));
        const int index = selection < 0 ? 0 : selection;
        return index < static_cast<int>(captureIds_.size()) ? widen(captureIds_[index]) : std::wstring();
    }();

    SendMessageW(controlSlot(idRenderDevice), CB_RESETCONTENT, 0, 0);
    renderIds_.clear();
    // The virtual-cable pairing is computed before the labels are built, because
    // it is what makes the milestone route visible in the lists: a cable's two
    // endpoints appear under different names in different lists, and choosing
    // "Input: CABLE Output" as the capture source is the whole configuration.
    // The pairing comes from the engine's own rule, so the GUI cannot disagree
    // with the CLI about which endpoints form one cable.
    const std::vector<DeviceInfo> inputs = listDevices(DataFlow::capture, error);
    const std::vector<VirtualCable> cables = findVirtualCables(outputs, inputs);
    const auto isCableSide = [&](const std::string& id, bool playback) {
        for (const VirtualCable& cable : cables) {
            if ((playback ? cable.playback.id : cable.recording.id) == id) {
                return true;
            }
        }
        return false;
    };

    for (const DeviceInfo& device : outputs) {
        const std::wstring label = widen(device.name.empty() ? device.id : device.name)
            + (device.isDefault ? L"  (default)" : L"")
            + (isBluetooth(device) ? L"  [Bluetooth]" : L"")
            + (isCableSide(device.id, true) ? L"  [virtual cable: play into it]" : L"");
        SendMessageW(controlSlot(idRenderDevice), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        renderIds_.push_back(device.id);
    }

    // The capture list mirrors the CLI's two modes: every output endpoint is a
    // loopback candidate, and every input endpoint is a direct capture.
    SendMessageW(controlSlot(idCaptureDevice), CB_RESETCONTENT, 0, 0);
    captureIds_.clear();
    for (const DeviceInfo& device : outputs) {
        const std::wstring label = std::wstring(L"System audio: ") + widen(device.name)
            + (device.isDefault ? L"  (default)" : L"")
            + (isCableSide(device.id, true) ? L"  [virtual cable: play into it]" : L"");
        SendMessageW(controlSlot(idCaptureDevice), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        captureIds_.push_back(device.id);
    }
    for (const DeviceInfo& device : inputs) {
        const std::wstring label = std::wstring(L"Input: ") + widen(device.name)
            + (isCableSide(device.id, false) ? L"  [virtual cable: recording side]" : L"");
        SendMessageW(controlSlot(idCaptureDevice), CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(label.c_str()));
        captureIds_.push_back(device.id);
    }

    // What this machine offers, in one sentence, for the idle status line.
    if (cables.empty()) {
        virtualCableNote_ = L"No virtual cable endpoint detected, so Windows audio cannot be "
                            L"routed through LowEnd yet. The documented route needs one (for "
                            L"example VB-CABLE: play into 'CABLE Input', capture 'CABLE Output'); "
                            L"installing a virtual audio driver is an external change LowEnd does "
                            L"not make. A real input device works without one.";
    } else {
        const VirtualCable& cable = cables.front();
        // The Output the note suggests must be a physical device: the cable's own
        // playback side is the one endpoint the routing rule refuses, so naming it
        // here would read as an instruction to route the audio back into the cable.
        std::string physicalOutput;
        for (const DeviceInfo& device : outputs) {
            if (isCableSide(device.id, true)) {
                continue;
            }
            if (physicalOutput.empty() || device.isDefault) {
                physicalOutput = device.name.empty() ? device.id : device.name;
            }
            if (device.isDefault) {
                break;
            }
        }
        virtualCableNote_ = L"Virtual cable detected: choose Capture \"Input: "
            + widen(cable.recording.name) + L"\" and Output \""
            + widen(physicalOutput.empty() ? std::string("your physical output device")
                                           : physicalOutput)
            + L"\", then set Windows' default output to the cable's "
              L"playback side. LowEnd renders to the endpoint chosen above, never to the cable.";
    }

    // Restore each selection when its endpoint is still listed.
    //
    // A saved id that is gone is *not* replaced with the first entry: that would
    // start the engine on the default endpoint, a device the user never chose, and
    // the mistake would look like a working route. The combo is left empty
    // instead, and the window refuses to start until something is selected. Only
    // a first run, which has no saved id at all, selects the first entry.
    const auto restore = [](HWND combo, const std::wstring& wanted,
                            const std::vector<std::string>& ids) {
        if (!wanted.empty()) {
            for (size_t i = 0; i < ids.size(); ++i) {
                if (widen(ids[i]) == wanted) {
                    SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(i), 0);
                    return true;
                }
            }
            SendMessageW(combo, CB_SETCURSEL, static_cast<WPARAM>(-1), 0);
            return false;
        }
        if (SendMessageW(combo, CB_GETCURSEL, 0, 0) == CB_ERR && !ids.empty()) {
            SendMessageW(combo, CB_SETCURSEL, 0, 0);
        }
        return true;
    };

    const std::wstring savedPath = deviceSelectionPath();
    // What the user chose in this session wins over what was saved; on the first
    // refresh there is no in-session choice yet, so the saved id is used.
    const std::wstring wantedRender = previousRender.empty()
        ? widen(readSelectionValue(savedPath, "render")) : previousRender;
    const std::wstring wantedCapture = previousCapture.empty()
        ? widen(readSelectionValue(savedPath, "capture")) : previousCapture;
    restore(controlSlot(idRenderDevice), wantedRender, renderIds_);
    restore(controlSlot(idCaptureDevice), wantedCapture, captureIds_);
}

bool ControlPanel::hasDeviceSelection() const {
    return SendMessageW(controlHandle(idCaptureDevice), CB_GETCURSEL, 0, 0) >= 0
        && SendMessageW(controlHandle(idRenderDevice), CB_GETCURSEL, 0, 0) >= 0;
}

void ControlPanel::saveDeviceSelection() const {
    const std::wstring path = deviceSelectionPath();
    if (path.empty()) {
        return;
    }
    const EngineOptions options = readEngineOptions();

    // A side with no selection is a side whose *saved* endpoint has vanished (the
    // combo is deliberately left empty in that case). Writing an empty value there
    // would erase the id the user chose and turn the next launch into a silent
    // fallback to the first list entry, which is exactly the substitution the
    // empty combo exists to prevent. The previous value is kept instead, so the
    // endpoint stays "saved but missing" until the user selects one.
    const std::string previousCapture = readSelectionValue(path, "capture");
    const std::string previousRender = readSelectionValue(path, "render");
    const std::string capture =
        options.captureDeviceId.empty() ? previousCapture : options.captureDeviceId;
    const std::string render =
        options.renderDeviceId.empty() ? previousRender : options.renderDeviceId;
    if (capture.empty() && render.empty()) {
        return;  // nothing selected yet; keeping the previous file is more useful
    }

    std::ofstream file(path, std::ios::trunc);
    if (!file) {
        return;  // a read-only profile must not break the app
    }
    file << "# Endpoints chosen in the LowEnd Circuit GUI. Written by the app, safe to delete.\n";
    file << "capture=" << capture << "\n";
    file << "render=" << render << "\n";
}

Settings ControlPanel::readSettings() const {
    Settings settings;

    const int model = static_cast<int>(SendMessageW(controlHandle(idModel), CB_GETCURSEL, 0, 0));
    settings.dspModel = model <= 0 ? dsp_model::clean
        : model == 1 ? dsp_model::circuit
                     : dsp_model::high_exciter;

    const int oversampling = static_cast<int>(
        SendMessageW(controlHandle(idExciterOversampling), CB_GETCURSEL, 0, 0));
    settings.exciterOversamplingMode = oversampling <= 0 ? oversampling_mode::automatic
        : oversampling == 1 ? oversampling_mode::one_x
        : oversampling == 2 ? oversampling_mode::two_x
                            : oversampling_mode::four_x;

    settings.intensity = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idIntensity), TBM_GETPOS, 0, 0)), specFor(idIntensity)));
    settings.body = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idBody), TBM_GETPOS, 0, 0)), specFor(idBody)));
    settings.outputDb = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idOutput), TBM_GETPOS, 0, 0)), specFor(idOutput)));

    settings.spatialEnabled = SendMessageW(controlHandle(idSpatialEnable), BM_GETCHECK, 0, 0) == BST_CHECKED;
    settings.space = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idSpace), TBM_GETPOS, 0, 0)), specFor(idSpace)));
    settings.speakerWidth = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idStageWidth), TBM_GETPOS, 0, 0)), specFor(idStageWidth)));
    settings.listenerX = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idListenerX), TBM_GETPOS, 0, 0)), specFor(idListenerX)));
    settings.listenerZ = static_cast<float>(fromSlider(static_cast<int>(SendMessageW(controlHandle(idListenerZ), TBM_GETPOS, 0, 0)), specFor(idListenerZ)));

    return normalized(settings);
}

EngineOptions ControlPanel::readEngineOptions() const {
    EngineOptions options;

    const int captureSelection = static_cast<int>(
        SendMessageW(controlHandle(idCaptureDevice), CB_GETCURSEL, 0, 0));
    const int renderSelection = static_cast<int>(
        SendMessageW(controlHandle(idRenderDevice), CB_GETCURSEL, 0, 0));

    if (captureSelection >= 0 && captureSelection < static_cast<int>(captureIds_.size())) {
        options.captureDeviceId = captureIds_[captureSelection];
        // Items added from the output list come first and are loopback captures;
        // the rest are input endpoints.
        const size_t outputCount = renderIds_.size();
        options.captureFlow = static_cast<size_t>(captureSelection) < outputCount
            ? DataFlow::render : DataFlow::capture;
        options.loopback = options.captureFlow == DataFlow::render;
    }
    if (renderSelection >= 0 && renderSelection < static_cast<int>(renderIds_.size())) {
        options.renderDeviceId = renderIds_[renderSelection];
    }
    return options;
}

void ControlPanel::writeSettings(const Settings& settings) {
    const int model = settings.dspModel == dsp_model::clean ? 0
        : settings.dspModel == dsp_model::circuit ? 1 : 2;
    SendMessageW(controlSlot(idModel), CB_SETCURSEL, model, 0);

    const int oversampling = settings.exciterOversamplingMode == oversampling_mode::one_x ? 1
        : settings.exciterOversamplingMode == oversampling_mode::two_x ? 2
        : settings.exciterOversamplingMode == oversampling_mode::four_x ? 3
                                                                       : 0;
    SendMessageW(controlSlot(idExciterOversampling), CB_SETCURSEL, oversampling, 0);

    SendMessageW(controlSlot(idIntensity), TBM_SETPOS, TRUE,
                 toSlider(settings.intensity, specFor(idIntensity)));
    SendMessageW(controlSlot(idBody), TBM_SETPOS, TRUE, toSlider(settings.body, specFor(idBody)));
    SendMessageW(controlSlot(idOutput), TBM_SETPOS, TRUE, toSlider(settings.outputDb, specFor(idOutput)));
    SendMessageW(controlSlot(idSpatialEnable), BM_SETCHECK,
                 settings.spatialEnabled ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(controlSlot(idSpace), TBM_SETPOS, TRUE, toSlider(settings.space, specFor(idSpace)));
    SendMessageW(controlSlot(idStageWidth), TBM_SETPOS, TRUE,
                 toSlider(settings.speakerWidth, specFor(idStageWidth)));
    SendMessageW(controlSlot(idListenerX), TBM_SETPOS, TRUE,
                 toSlider(settings.listenerX, specFor(idListenerX)));
    SendMessageW(controlSlot(idListenerZ), TBM_SETPOS, TRUE,
                 toSlider(settings.listenerZ, specFor(idListenerZ)));

    refreshValueLabels();
}

void ControlPanel::setRunning(bool running) {
    SetWindowTextW(controlSlot(idStartStop), running ? L"Stop" : L"Start");
}

void ControlPanel::setStatusText(const std::wstring& text) {
    SetWindowTextW(controlSlot(idStatus), text.c_str());
}

void ControlPanel::setStatisticsText(const std::wstring& text) {
    // Appended to the status line by the window, which owns both strings.
    SetWindowTextW(controlSlot(idStatus), text.c_str());
}

void ControlPanel::refreshValueLabels() {
    // Each readout shows the same number readSettings() will produce, so the
    // label and the value handed to the engine cannot disagree.
    const Settings settings = readSettings();

    SetWindowTextW(valueSlot(idIntensity), formatValue(L"%.1f", settings.intensity).c_str());
    SetWindowTextW(valueSlot(idBody), formatValue(L"%.1f", settings.body).c_str());
    SetWindowTextW(valueSlot(idOutput), formatValue(L"%.1f dB", settings.outputDb).c_str());
    SetWindowTextW(valueSlot(idSpace), formatValue(L"%.1f", settings.space).c_str());
    SetWindowTextW(valueSlot(idStageWidth), formatValue(L"%.2f m", settings.speakerWidth).c_str());
    SetWindowTextW(valueSlot(idListenerX), formatValue(L"%.2f m", settings.listenerX).c_str());
    SetWindowTextW(valueSlot(idListenerZ), formatValue(L"%.2f m", settings.listenerZ).c_str());
}

HWND ControlPanel::handle(ControlId id) const {
    return controlHandle(id);
}

} // namespace lowend::win::gui
