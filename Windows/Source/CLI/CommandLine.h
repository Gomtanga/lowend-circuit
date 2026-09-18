// CommandLine.h — argument parsing for the Windows CLI.
//
// The option names, value ranges and rejection behaviour match the macOS
// native CLI so the same invocations work on both platforms.

#pragma once

// CommandLine holds EngineOptions by value, so the complete type must be
// visible here rather than depending on the include order of each translation
// unit that parses arguments.
#include "AudioEngine/Engine.h"

#include "AudioEngine/Devices.h"
#include "AudioEngine/RouteDiagnosis.h"
#include "AudioEngine/Settings.h"

#include <string>
#include <vector>

namespace lowend::win {

enum class Command {
    run,          // capture → DSP → render until stopped
    listDevices,  // enumerate endpoints and exit
    dumpSettings, // print resolved settings/plan and exit
    selfTest,     // run offline checks and exit
    monitor,      // capture only, report statistics, and exit
    routeCheck,   // judge the selected route without opening a stream, and exit
    playTone,     // send a known tone to a named endpoint, and exit
    help,
};

// Longest and shortest tone the CLI plays. The same window as --monitor: a
// verification signal has to outlast a device's startup and stay a diagnostic
// rather than a playback session.
inline constexpr int toneMinSeconds = 1;
inline constexpr int toneMaxSeconds = 600;

// Frequency and peak amplitude of the --play-tone signal.
//
// Fixed and documented rather than configurable: a verification run compares the
// level measured at the far end of a route against this number, so the number
// has to be a property of the tool, not of the invocation. A caller-chosen level
// would make "the processed output is 0.65x of the source" unverifiable, and a
// silent tone would make it meaningless.
inline constexpr double toneFrequencyHz = 440.0;
inline constexpr double toneAmplitude = 0.4;

// Which channel(s) --play-tone drives.
//
// "both" is the default and what a level comparison needs. A single-channel tone
// is what makes a left/right swap observable at the far end of a route: two
// identical channels can only show that a side is missing or duplicated, never
// that the sides were exchanged.
enum class ToneChannel { both, left, right };

inline const char* toneChannelName(ToneChannel channel) {
    switch (channel) {
        case ToneChannel::left: return "left";
        case ToneChannel::right: return "right";
        case ToneChannel::both: break;
    }
    return "both";
}

// Longest and shortest capture-only monitoring window the CLI accepts. The
// monitor exists to answer "is this endpoint actually delivering audio?", which
// needs long enough to span a device's startup and short enough to stay a
// diagnostic rather than a session.
inline constexpr int monitorMinSeconds = 1;
inline constexpr int monitorMaxSeconds = 600;

struct CommandLine {
    Command command = Command::run;
    Settings settings;
    EngineOptions engine;

    // Diagnostics that need no device.
    bool verbose = false;

    // Seconds to observe for Command::monitor; 0 when the flag was not given.
    int monitorSeconds = 0;

    // Seconds to play for Command::playTone; 0 when the flag was not given.
    int toneSeconds = 0;

    // Which channel(s) Command::playTone drives.
    ToneChannel toneChannel = ToneChannel::both;

    // File --monitor writes the captured signal to; empty when not requested.
    std::string monitorDumpPath;

    // A diagnostic/dry-run command that must not start audio capture.
    // Mirrors the macOS "Diagnostic commands must be used on their own." rule.
    std::vector<std::string> rejectionReasons;
};

// Parse argv[1..]. Never starts audio. On an unknown or malformed argument the
// returned CommandLine has a non-empty rejectionReasons and command == help,
// mirroring the macOS behaviour of refusing invalid input with exit code 1.
CommandLine parseCommandLine(int argc, char** argv);

// Usage text printed by --help.
std::string usageText();

// Formats `--list-devices` output. Kept separate so checks can assert on it.
std::string formatDeviceList(const std::vector<DeviceInfo>& renderDevices,
                             const std::vector<DeviceInfo>& captureDevices);

// Formats `--route-check` output. Kept separate for the same reason: the checks
// assert on the reason a route was refused, and on the wording of the advice.
std::string formatRouteCheck(const RouteSelection& selection,
                             const RouteDiagnosis& diagnosis);

} // namespace lowend::win
