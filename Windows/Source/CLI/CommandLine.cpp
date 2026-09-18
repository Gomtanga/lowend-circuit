// CommandLine.cpp — argument parsing for the Windows CLI.
//
// The parser is pure: it reads argv, fills a CommandLine, and never opens a
// device or starts a thread. The option names, ranges and rejection messages
// follow the macOS CLI (SystemAudioProcessor/Sources/SystemAudioProcessor/
// main.swift, parseArguments) so a command line that works there means the same
// thing here.
//
// Every rejection is collected into CommandLine::rejectionReasons instead of
// aborting at the first problem. parseCommandLine() returns all of them and
// leaves command at Command::help, which is the contract Main.cpp relies on:
// print the reasons, print the usage, exit 1.

// Engine.h defines EngineOptions, which CommandLine.h holds by value.
#include "AudioEngine/Engine.h"

#include "CLI/CommandLine.h"

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace lowend::win {
namespace {

// The commands that must stand alone. macOS enforces the same rule for its
// diagnostics; --help is included here because the Windows CLI has no
// interactive fallback to return to, so a combined --help is a mistake rather
// than a request to print and continue.
//
// --monitor is deliberately absent: it takes a required value and is useful
// together with routing and DSP options ("monitor this endpoint for 5 s with
// HighExciter"), so treating it as a bare diagnostic would make it unusable.
constexpr const char* diagnosticArguments[] = {
    "--list-devices",
    "--dump-settings",
    "--self-test",
    "--help",
    "-h",
};

bool isDiagnosticArgument(const std::string& argument) {
    for (const char* candidate : diagnosticArguments) {
        if (argument == candidate) {
            return true;
        }
    }
    return false;
}

char asciiLower(char raw) {
    return static_cast<char>(std::tolower(static_cast<unsigned char>(raw)));
}

std::string lowercased(const std::string& text) {
    std::string result;
    result.reserve(text.size());
    for (const char raw : text) {
        result.push_back(asciiLower(raw));
    }
    return result;
}

// Parses a numeric option. strtof() accepts a valid prefix ("55abc" parses as
// 55), so the token must be consumed entirely; "inf" and "nan" are valid floats
// but not valid settings, so they are refused for the same reason macOS refuses
// them (isFinite).
bool parseNumber(const std::string& text, float& value) {
    if (text.empty()) {
        return false;
    }
    const char* const begin = text.c_str();
    char* end = nullptr;
    const float parsed = std::strtof(begin, &end);
    if (end == begin || end != begin + text.size()) {
        return false;
    }
    if (!isFinite(parsed)) {
        return false;
    }
    value = parsed;
    return true;
}

// on/true/1/yes and off/false/0/no, case-insensitive — the exact set the macOS
// --spatial switch accepts.
bool parseSwitch(const std::string& text, bool& value) {
    const std::string lowered = lowercased(text);
    if (lowered == "on" || lowered == "true" || lowered == "1" || lowered == "yes") {
        value = true;
        return true;
    }
    if (lowered == "off" || lowered == "false" || lowered == "0" || lowered == "no") {
        value = false;
        return true;
    }
    return false;
}

std::string formatDeviceLine(const DeviceInfo& device) {
    std::string line;
    line += device.isDefault ? "* " : "  ";
    line += device.name.empty() ? "(unnamed endpoint)" : device.name;

    // The bus the device arrived on. Printed because the routing rules depend on
    // it: root-enumerated devices are instantiated by a driver rather than
    // discovered on hardware, which is what makes a virtual audio cable's two
    // endpoints one signal path, and a user looking at a refusal needs to see
    // that this is what the machine reports.
    if (!device.enumeratorName.empty()) {
        line += "  bus=" + device.enumeratorName;
    }

    if (device.mixSampleRate == 0) {
        // GetMixFormat failed for this endpoint; the entry is still listed so
        // the id stays reachable.
        line += "  (mix format unavailable)";
    } else {
        char format[64];
        std::snprintf(format, sizeof(format), "  %u Hz / %u ch / %u-bit",
                      device.mixSampleRate, device.mixChannels, device.mixBitsPerSample);
        line += format;
    }

    // Bluetooth endpoints are the ones worth calling out: their negotiated
    // period is the least predictable and they are the usual cause of a route
    // that underruns. Devices.h reports the marker through formFactor, and it
    // may arrive as part of a longer description, so the match is a substring.
    if (lowercased(device.formFactor).find("bluetooth") != std::string::npos) {
        line += " [Bluetooth]";
    }

    // Printed last and verbatim: this is the string a user copies into
    // --device / --capture-device / --input-device.
    line += " id=" + device.id;
    line += "\n";
    return line;
}

void appendDeviceSection(std::string& text, const std::vector<DeviceInfo>& devices) {
    if (devices.empty()) {
        text += "  (none)\n";
        return;
    }
    for (const DeviceInfo& device : devices) {
        text += formatDeviceLine(device);
    }
}

// The virtual cables on the machine, as a section both --list-devices and
// --route-check print. Which cable exists is not visible from the two lists: a
// cable is one device instance whose playback and recording sides appear in
// different sections under different names, and the routing rules act on the
// pairing rather than on either name.
void appendVirtualCableSection(std::string& text,
                               const std::vector<DeviceInfo>& renderDevices,
                               const std::vector<DeviceInfo>& captureDevices) {
    const std::vector<VirtualCable> cables = findVirtualCables(renderDevices, captureDevices);
    if (cables.empty()) {
        text += "\nVirtual cables: none detected. A virtual cable is one software device\n"
                "offering a playback side (what applications play into) and a recording side\n"
                "(what carries that signal). The documented routing milestone needs one; VB-CABLE\n"
                "is an external driver, so installing it is a user decision, not something these\n"
                "tools do.\n";
        return;
    }
    text += "\nVirtual cables (playback side -> recording side):\n";
    for (const VirtualCable& cable : cables) {
        text += "  " + (cable.playback.name.empty() ? std::string("(unnamed)")
                                                    : cable.playback.name);
        text += "  ->  ";
        text += cable.recording.name.empty() ? std::string("(unnamed)") : cable.recording.name;
        text += "\n";
        text += "    playback  id=" + cable.playback.id + "\n";
        text += "    recording id=" + cable.recording.id + "\n";
    }
    text += "The milestone route captures the recording side (as an input device) and renders\n"
            "to a physical output, never to the same cable.\n";
}

// Software-bus endpoints that are not paired as one device.
//
// A cable whose driver exposed its two sides as separate devices would look like
// this, and it is the case the pairing above cannot see: the note says so rather
// than letting "not paired" read as "two unrelated devices".
void appendUnpairedSoftwareNote(std::string& text,
                                const std::vector<DeviceInfo>& renderDevices,
                                const std::vector<DeviceInfo>& captureDevices) {
    for (const DeviceInfo& render : renderDevices) {
        if (!isVirtualEnumerator(render.enumeratorName)) {
            continue;
        }
        for (const DeviceInfo& capture : captureDevices) {
            if (!isUnidentifiedSoftwarePair(capture, render)) {
                continue;
            }
            text += "\nSoftware-bus endpoints NOT paired as one device:\n";
            text += "  " + (render.name.empty() ? std::string("(unnamed)") : render.name);
            text += "  vs  ";
            text += capture.name.empty() ? std::string("(unnamed)") : capture.name;
            text += "\n  Windows reports them as different device instances, so they cannot be\n"
                    "  identified as the two sides of one virtual cable. If they are, capturing one\n"
                    "  while rendering to the other is a feedback loop the guard cannot prove, so it\n"
                    "  is not refused: do not do it.\n";
            return;  // one instance of the note makes the point
        }
    }
}

// One end of the route being checked, in the terms the decision used: the role,
// the capture mode, and the endpoint that was resolved.
std::string formatSelectedEndpoint(const char* role, const char* mode, const DeviceInfo& device) {
    std::string text = std::string("  ") + role + " (" + mode + "): ";
    text += device.name.empty() ? "(unnamed endpoint)" : device.name;
    if (!device.enumeratorName.empty()) {
        text += "  bus=" + device.enumeratorName;
    }
    if (device.mixSampleRate != 0) {
        char format[64];
        std::snprintf(format, sizeof(format), "  %u Hz / %u ch / %u-bit",
                      device.mixSampleRate, device.mixChannels, device.mixBitsPerSample);
        text += format;
    }
    text += "\n    id=" + device.id + "\n";
    return text;
}

} // namespace

CommandLine parseCommandLine(int argc, char** argv) {
    CommandLine result;

    if (argc <= 1 || argv == nullptr) {
        // No arguments: run with the documented defaults, exactly like the
        // macOS CLI does when it is launched without a bundle-id.
        return result;
    }

    std::vector<std::string> arguments;
    arguments.reserve(static_cast<std::size_t>(argc - 1));
    for (int index = 1; index < argc; ++index) {
        arguments.emplace_back(argv[index] != nullptr ? argv[index] : "");
    }

    // A diagnostic command describes a one-shot action, so combining it with a
    // running configuration is ambiguous. macOS refuses the combination for the
    // same reason.
    if (arguments.size() > 1) {
        for (const std::string& argument : arguments) {
            if (isDiagnosticArgument(argument)) {
                result.rejectionReasons.emplace_back(
                    "Diagnostic commands must be used on their own.");
                break;
            }
        }
    }

    std::size_t index = 0;
    std::string argument;
    std::string value;

    // The capture source is named by --input-device and settled by --loopback,
    // and the two can contradict each other. Both write the capture flow, so
    // without recording the flags separately the meaning of a command line
    // would depend on argument order: `--loopback on --input-device X` silently
    // ignored the loopback request, while `--input-device X --loopback on` built
    // a render-flow loopback pointed at an input device and failed with a
    // confusing endpoint error. Recording them here lets the combination be
    // judged after the loop, so the same flags behave the same way in any order.
    bool loopbackGiven = false;
    bool loopbackEnabled = false;
    bool inputDeviceGiven = false;
    std::string inputDeviceId;
    bool captureDeviceGiven = false;
    std::string captureDeviceId;
    bool toneChannelGiven = false;

    // Reads the value that follows the current argument.
    //
    // The caller passes the message to use when the value is missing, and it is
    // the same one it uses for a value that fails to parse. That mirrors the
    // macOS CLI, where each option handles both cases in a single `guard let
    // value = iterator.next(), <parse> else { throw ... }`: a numeric option
    // answers "needs a number" whether the token is absent or is not a number,
    // and the enum options do the same with their accepted list. Reporting the
    // generic "needs a value" here instead made every shared option's message
    // differ from macOS for the missing-value case.
    const auto takeValue = [&](const std::string& missingMessage) {
        if (index + 1 >= arguments.size()) {
            result.rejectionReasons.push_back(missingMessage);
            return false;
        }
        value = arguments[++index];
        return true;
    };

    // Numeric option. The token must be a complete number: strtof() would accept
    // "55abc" as 55 and "inf"/"nan" as floats, and macOS rejects both
    // (`Float(value)` plus `isFinite`). Range clamping is deliberately not done
    // here — normalized() owns it, exactly as on macOS, so a merely
    // out-of-range value is accepted and folded into its documented window.
    const auto numberOption = [&](const char* name, float& target) {
        const std::string needs = std::string(name) + " needs a number";
        if (!takeValue(needs)) {
            return;
        }
        float number = 0.0f;
        if (!parseNumber(value, number)) {
            result.rejectionReasons.push_back(needs);
            return;
        }
        target = number;
    };

    // Device id option. An explicitly empty value is refused instead of being
    // treated as "the default endpoint": an unset shell variable (`--device
    // "$OUT"`) would otherwise silently process a route the user did not name,
    // which is exactly the mistake a selection flag exists to prevent. Omitting
    // the flag still selects the default endpoint, which is what an empty id
    // means internally — the two cases are not the same, so they are not
    // treated the same here. A missing value reports the same thing, since both
    // mean "this option has no id".
    //
    // Returns whether the id was accepted, so a caller that also changes state
    // on the flag (--input-device switches the capture flow) only does so for a
    // value that survived validation.
    const auto deviceOption = [&](const char* name, std::string& target) {
        const std::string needs = std::string(name) + " needs a device id";
        if (!takeValue(needs)) {
            return false;
        }
        if (value.empty()) {
            result.rejectionReasons.push_back(needs);
            return false;
        }
        target = value;
        return true;
    };

    for (index = 0; index < arguments.size(); ++index) {
        argument = arguments[index];

        if (argument == "--help" || argument == "-h") {
            result.command = Command::help;
        } else if (argument == "--list-devices") {
            result.command = Command::listDevices;
        } else if (argument == "--dump-settings") {
            result.command = Command::dumpSettings;
        } else if (argument == "--self-test") {
            result.command = Command::selfTest;
        } else if (argument == "--route-check") {
            // Judgement only: nothing is opened, so unlike the bare diagnostic
            // commands this one is useful with routing options ("is this pair
            // usable?"), and it is therefore not in diagnosticArguments.
            result.command = Command::routeCheck;
        } else if (argument == "--play-tone") {
            // Sends a known signal to the endpoint named by --device (or the
            // default output) and exits. It exists so a verification run can put
            // a controlled tone into a *specific* endpoint instead of whatever
            // the machine's default output happens to be, which is exactly what
            // the cable route has to be measured with: the point of that route
            // is that the OS default output is the cable.
            result.command = Command::playTone;
            if (takeValue("--play-tone needs a number")) {
                float seconds = 0.0f;
                if (!parseNumber(value, seconds)) {
                    result.rejectionReasons.emplace_back("--play-tone needs a number");
                } else if (seconds < static_cast<float>(toneMinSeconds)
                           || seconds > static_cast<float>(toneMaxSeconds)) {
                    result.rejectionReasons.emplace_back(
                        "--play-tone needs a number of seconds between "
                        + std::to_string(toneMinSeconds) + " and "
                        + std::to_string(toneMaxSeconds));
                } else {
                    result.toneSeconds = static_cast<int>(seconds);
                }
            }
        } else if (argument == "--tone-channel") {
            // Selects which channel the tone source drives. Single-channel
            // tones are what a route check needs to tell left from right; the
            // cross-option rule below keeps it tied to --play-tone.
            if (takeValue("--tone-channel needs both, left, or right")) {
                toneChannelGiven = true;
                if (value == "both") {
                    result.toneChannel = ToneChannel::both;
                } else if (value == "left") {
                    result.toneChannel = ToneChannel::left;
                } else if (value == "right") {
                    result.toneChannel = ToneChannel::right;
                } else {
                    result.rejectionReasons.emplace_back(
                        "--tone-channel needs both, left, or right");
                }
            }
        } else if (argument == "--monitor") {
            // Capture-only diagnostic: no render endpoint is opened, so this is
            // usable on a machine whose only output endpoint is the one being
            // captured. The value is the observation window in seconds.
            result.command = Command::monitor;
            if (takeValue("--monitor needs a number")) {
                float seconds = 0.0f;
                if (!parseNumber(value, seconds)) {
                    result.rejectionReasons.emplace_back("--monitor needs a number");
                } else if (seconds < static_cast<float>(monitorMinSeconds)
                           || seconds > static_cast<float>(monitorMaxSeconds)) {
                    result.rejectionReasons.emplace_back(
                        "--monitor needs a number of seconds between "
                        + std::to_string(monitorMinSeconds) + " and "
                        + std::to_string(monitorMaxSeconds));
                } else {
                    result.monitorSeconds = static_cast<int>(seconds);
                }
            }
        } else if (argument == "--verbose") {
            // Not a command: --verbose only adds diagnostics, so unlike the
            // diagnostic commands it may be combined with a run configuration.
            result.verbose = true;
        } else if (argument == "--dump-wav") {
            // Writes the captured signal itself. Exists for verification: level
            // and frequency at the far end of a route cannot be measured from a
            // peak summary, and a script that claims to have checked a pitch has
            // to have had the samples. Only meaningful with --monitor, which is
            // the command that captures without rendering.
            if (takeValue("--dump-wav needs a file path")) {
                if (value.empty()) {
                    result.rejectionReasons.emplace_back("--dump-wav needs a file path");
                } else {
                    result.monitorDumpPath = value;
                }
            }
        } else if (argument == "--device") {
            deviceOption("--device", result.engine.renderDeviceId);
        } else if (argument == "--capture-device") {
            // Names the endpoint of the selected capture flow. The default
            // flow is the system-audio loopback, so this flag alone does not
            // change the flow; --input-device is what selects a real input.
            if (deviceOption("--capture-device", captureDeviceId)) {
                captureDeviceGiven = true;
            }
        } else if (argument == "--input-device") {
            if (deviceOption("--input-device", inputDeviceId)) {
                inputDeviceGiven = true;
            }
        } else if (argument == "--loopback") {
            bool enabled = false;
            if (takeValue("--loopback needs on or off")) {
                if (!parseSwitch(value, enabled)) {
                    result.rejectionReasons.emplace_back("--loopback needs on or off");
                } else {
                    // Loopback exists only for a render endpoint, so the switch
                    // and the capture flow are one decision: "off" means a real
                    // input endpoint is captured instead. Resolved after the
                    // loop, so a contradicting --input-device is reported rather
                    // than decided by argument order.
                    loopbackGiven = true;
                    loopbackEnabled = enabled;
                }
            }
        } else if (argument == "--intensity") {
            numberOption("--intensity", result.settings.intensity);
        } else if (argument == "--body") {
            numberOption("--body", result.settings.body);
        } else if (argument == "--output") {
            numberOption("--output", result.settings.outputDb);
        } else if (argument == "--model") {
            if (takeValue("--model needs clean, circuit, or highexciter")) {
                uint32_t model = 0;
                if (!parseDSPModel(value, model)) {
                    result.rejectionReasons.emplace_back(
                        "--model needs clean, circuit, or highexciter");
                } else {
                    result.settings.dspModel = model;
                }
            }
        } else if (argument == "--exciter-os") {
            if (takeValue("--exciter-os needs auto, 1x, 2x, or 4x")) {
                uint32_t mode = 0;
                if (!parseOversamplingMode(value, mode)) {
                    result.rejectionReasons.emplace_back(
                        "--exciter-os needs auto, 1x, 2x, or 4x");
                } else {
                    result.settings.exciterOversamplingMode = mode;
                }
            }
        } else if (argument == "--spatial") {
            bool enabled = false;
            if (takeValue("--spatial needs on or off")) {
                if (!parseSwitch(value, enabled)) {
                    result.rejectionReasons.emplace_back("--spatial needs on or off");
                } else {
                    result.settings.spatialEnabled = enabled;
                }
            }
        } else if (argument == "--listener-x") {
            numberOption("--listener-x", result.settings.listenerX);
        } else if (argument == "--listener-z") {
            numberOption("--listener-z", result.settings.listenerZ);
        } else if (argument == "--stage-width") {
            numberOption("--stage-width", result.settings.speakerWidth);
        } else if (argument == "--space") {
            numberOption("--space", result.settings.space);
        } else if (argument == "--buffer-ms") {
            if (takeValue("--buffer-ms needs a number")) {
                float number = 0.0f;
                if (!parseNumber(value, number)) {
                    result.rejectionReasons.emplace_back("--buffer-ms needs a number");
                } else {
                    // A period is a count of milliseconds, so the token has to
                    // land somewhere a uint32 can express before the conversion:
                    // converting a negative or out-of-range float to an unsigned
                    // type is undefined. The bound only makes the cast defined —
                    // normalized() still owns the accepted window and folds an
                    // out-of-range value back to the documented default.
                    if (!(number > 0.0f)) {
                        number = 0.0f;
                    } else if (number > 1000.0f) {
                        number = 1000.0f;
                    }
                    const uint32_t milliseconds = static_cast<uint32_t>(number);
                    result.settings.bufferMs = milliseconds;
                    // Mirrored onto the engine options so a caller reading
                    // either field sees the period that was asked for.
                    result.engine.bufferMs = milliseconds;
                }
            }
        } else {
            result.rejectionReasons.push_back("Unknown argument: " + argument);
        }
    }

    // Resolve the capture source now that every flag has been seen, so the same
    // flags mean the same thing regardless of their order on the command line.
    //
    // --input-device names a real input endpoint, which is the opposite of
    // capturing an output endpoint's own audio. Asking for both is a
    // contradiction rather than a preference, so it is reported instead of
    // being resolved by whichever flag happened to come last.
    if (inputDeviceGiven && loopbackGiven && loopbackEnabled) {
        result.rejectionReasons.emplace_back(
            "--input-device captures a real input endpoint, which cannot be combined"
            " with --loopback on; drop one of them (omit --loopback to capture the"
            " input device, or omit --input-device to capture the system output)");
    } else if (inputDeviceGiven) {
        result.engine.captureDeviceId = inputDeviceId;
        result.engine.captureFlow = DataFlow::capture;
        result.engine.loopback = false;
    } else if (loopbackGiven) {
        result.engine.captureFlow = loopbackEnabled ? DataFlow::render : DataFlow::capture;
        result.engine.loopback = loopbackEnabled;
    }
    // --capture-device names the endpoint of whichever flow was selected, so it
    // is applied after the flow is known and does not change it.
    if (captureDeviceGiven) {
        result.engine.captureDeviceId = captureDeviceId;
    }

    // The dump belongs to the capture-only diagnostic: it is a path that only
    // --monitor fills. Accepting it on a run would either do nothing (and look
    // like a silent failure) or start writing audio the user did not ask to keep.
    if (!result.monitorDumpPath.empty() && result.command != Command::monitor) {
        result.rejectionReasons.emplace_back(
            "--dump-wav writes what --monitor captured, so it needs --monitor");
    }

    // The channel selection belongs to the tone source. On any other command it
    // would silently do nothing, which reads as "the check ran" when it did not.
    if (toneChannelGiven && result.command != Command::playTone) {
        result.rejectionReasons.emplace_back(
            "--tone-channel selects which channel --play-tone drives, so it needs"
            " --play-tone");
    }

    // The header contract: an invalid command line never selects a runnable
    // command, so Main.cpp prints the reasons, then the usage, and exits 1.
    if (!result.rejectionReasons.empty()) {
        result.command = Command::help;
    }
    return result;
}

std::string usageText() {
    return
        "LowEnd Circuit for Windows — WASAPI shared-mode system audio processing\n"
        "\n"
        "Usage:\n"
        "  lowend_windows --device <output-id> [options]\n"
        "  lowend_windows --input-device <input-id> [options]\n"
        "  lowend_windows --list-devices\n"
        "  lowend_windows --dump-settings\n"
        "  lowend_windows --self-test\n"
        "  lowend_windows --route-check [routing options]\n"
        "  lowend_windows --play-tone <seconds> [--tone-channel both|left|right]\n"
        "                             [--device <id>]\n"
        "  lowend_windows --monitor <seconds> [--capture-device <id>]\n"
        "  lowend_windows --help\n"
        "\n"
        "The engine captures one endpoint, processes it, and plays the result to a\n"
        "different one. Two endpoints are required: WASAPI loopback copies what the\n"
        "capture endpoint is playing instead of replacing it, so playing back to the\n"
        "same endpoint would feed the processed signal into its own capture. Run\n"
        "--list-devices first and pass a distinct id to --device (or --input-device\n"
        "to process a real input endpoint instead of the system output).\n"
        "\n"
        "Loopback also taps the output before volume and mute is applied, and the\n"
        "original audio keeps playing to its own endpoint. That is what the capture\n"
        "is: an extra processed copy, not a replacement for system audio.\n"
        "\n"
        "Press Ctrl-C to stop. The diagnostic commands (--list-devices,\n"
        "--dump-settings, --self-test, --help) do not start audio and must be used\n"
        "on their own.\n"
        "\n"
        "Routing:\n"
        "  --device <id>           Render endpoint; must differ from the capture side\n"
        "  --capture-device <id>   Endpoint of the selected capture flow\n"
        "  --input-device <id>     Capture a real input endpoint instead of loopback\n"
        "  --loopback on|off       Capture the output endpoint's own audio (default: on)\n"
        "                          --input-device and --loopback on are opposites;\n"
        "                          passing both is rejected\n"
        "  --buffer-ms 1...1000    Shared-mode period in milliseconds (default: 20)\n"
        "\n"
        "DSP:\n"
        "  --intensity 0...100           Low-end amount (default: 55)\n"
        "  --body 0...100                Body/warmth amount (default: 30)\n"
        "  --output -18...6              Output gain in dB (default: -1.5). Applied\n"
        "                          by the Circuit model: Clean runs no tone DSP and\n"
        "                          the exciter keeps its dry signal, so neither\n"
        "                          uses it\n"
        "  --model clean|circuit|highexciter   Processing model (default: circuit)\n"
        "  --exciter-os auto|1x|2x|4x    Exciter oversampling (default: auto)\n"
        "\n"
        "Spatial:\n"
        "  --spatial on|off              Enable the spatial stage (default: off)\n"
        "  --listener-x -3...3           Listener x in meters (default: 0)\n"
        "  --listener-z -2.8...2.8       Listener z in meters (default: 0)\n"
        "  --stage-width 0.6...3         Speaker width in meters (default: 1.65)\n"
        "  --space 0...100               Spatial amount (default: 35)\n"
        "\n"
        "Diagnostics:\n"
        "  --list-devices          List output and input endpoints, then exit\n"
        "  --dump-settings         Print the resolved settings and DSP plans, then exit\n"
        "  --self-test             Run the offline checks (no audio device), then exit\n"
        "  --route-check           Judge the selected capture/render pair without opening a\n"
        "                          stream, then exit. Takes routing options, so it answers\n"
        "                          \"is this pair usable?\" before anything is played\n"
        "  --monitor 1...600       Capture only for N seconds and report statistics,\n"
        "                          then exit. Opens no render endpoint, so it works\n"
        "                          when the captured endpoint is the only output\n"
        "  --dump-wav <path>       Write what --monitor captured to a 16-bit PCM WAV\n"
        "                          file. Needs --monitor. Exists so a verification run\n"
        "                          can measure the signal at the end of a route (level,\n"
        "                          channels, frequency) instead of trusting a summary\n"
        "  --play-tone 1...600     Play a known 440 Hz tone at amplitude 0.40 to the\n"
        "                          --device endpoint (default output when absent), then\n"
        "                          exit. The target, its period, the channel(s) and the\n"
        "                          level are printed before anything is written, and no\n"
        "                          volume is changed. Not processed by the DSP: this is a\n"
        "                          signal source for measuring a route, and DSP options do\n"
        "                          not apply to it\n"
        "  --tone-channel both|left|right\n"
        "                          Which channel(s) --play-tone drives (default: both).\n"
        "                          One channel at a time is how a check tells left from\n"
        "                          right at the far end of a route: two identical channels\n"
        "                          can only show a missing or duplicated side, never a swap\n"
        "  --verbose               Print the negotiated route and running statistics\n"
        "  --help, -h              Print this text\n"
        "\n"
        "A virtual audio cable (VB-CABLE, for example) is one software device with a\n"
        "playback side applications play into and a recording side that carries that\n"
        "signal. Capturing its recording side as a normal input (--input-device) and\n"
        "rendering to a physical output is the documented route for processing all\n"
        "system audio. Capturing one side and rendering to the other is refused: the\n"
        "two ids differ, but the two endpoints are one signal path, so the engine\n"
        "would process its own output forever.\n"
        "\n"
        "Values outside a documented range are clamped; non-finite values are\n"
        "rejected. Pass the ids printed by --list-devices to change routing.\n";
}

std::string formatDeviceList(const std::vector<DeviceInfo>& renderDevices,
                             const std::vector<DeviceInfo>& captureDevices) {
    std::string text;
    text += "Output devices (loopback-capable):\n";
    appendDeviceSection(text, renderDevices);
    text += "\nInput devices:\n";
    appendDeviceSection(text, captureDevices);

    // Which virtual cables exist is not visible from the two lists: a cable is
    // one device instance whose playback and recording sides appear in different
    // sections under different names. The pairing is what the routing rules act
    // on, so it is printed rather than left for the user to infer.
    appendVirtualCableSection(text, renderDevices, captureDevices);
    appendUnpairedSoftwareNote(text, renderDevices, captureDevices);

    text += "\n* marks the default endpoint. Use the id= value with --device,\n"
            "--capture-device, or --input-device.\n";
    return text;
}

std::string formatRouteCheck(const RouteSelection& selection,
                             const RouteDiagnosis& diagnosis) {
    const bool captureIsLoopback = selection.captureFlow == DataFlow::render;

    std::string text;
    text += "Route check: this command opens no stream and changes no setting.\n";

    // Both ends are reported the way the decision saw them. When an id did not
    // resolve, the id that was asked for is printed instead of a device, because
    // "which id failed" is the part that tells a user their endpoint was
    // reinstalled or is unplugged.
    if (diagnosis.haveCapture) {
        text += formatSelectedEndpoint("capture", captureIsLoopback ? "system audio loopback"
                                                                   : "input device",
                                       diagnosis.capture);
    } else {
        text += "  capture (";
        text += captureIsLoopback ? "system audio loopback" : "input device";
        text += "): ";
        text += selection.captureId.empty() ? "(no default endpoint resolved)"
                                            : selection.captureId;
        text += "\n";
    }
    if (diagnosis.haveRender) {
        text += formatSelectedEndpoint("render", "output device", diagnosis.render);
    } else {
        text += "  render (output device): ";
        text += selection.renderId.empty() ? "(no default endpoint resolved)"
                                           : selection.renderId;
        text += "\n";
    }

    if (diagnosis.virtualCables.empty()) {
        text += "\nVirtual cables: none detected on this machine.\n";
    } else {
        text += "\nVirtual cables found (playback side -> recording side):\n";
        for (const std::string& cable : diagnosis.virtualCables) {
            text += "  " + cable + "\n";
        }
    }

    if (diagnosis.ok()) {
        text += "\nResult: READY\n";
    } else {
        text += "\nResult: REFUSED (";
        text += routeIssueName(diagnosis.issue);
        text += ")\n";
        text += "  cause: " + diagnosis.cause + "\n";
        text += "  next:  " + diagnosis.nextAction + "\n";
    }
    for (const std::string& note : diagnosis.notes) {
        text += "  note:  " + note + "\n";
    }
    return text;
}

} // namespace lowend::win
