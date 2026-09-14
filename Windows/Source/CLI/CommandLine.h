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
    help,
};

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

} // namespace lowend::win
