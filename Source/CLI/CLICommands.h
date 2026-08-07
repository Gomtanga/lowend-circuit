#pragma once

#include <juce_core/juce_core.h>
#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_audio_formats/juce_audio_formats.h>
#include <juce_audio_utils/juce_audio_utils.h>
#include <CLI/CLI.hpp>
#include "DSP/LowEndDSPCore.h"

namespace lowend::cli
{

struct ProcessOptions
{
    std::string inputFile;
    std::string outputFile;
    std::string preset;
    float intensity = -1.0f; // -1 = use default/preset
    float body = -1.0f;
    float mix = -1.0f;
    float outputDb = -100.0f; // sentinel for "not set"
    bool jsonOutput = false;
};

struct Preset
{
    std::string name;
    LowEndDSPCore::Parameters params;
};

const std::vector<Preset>& getBuiltinPresets();
std::optional<LowEndDSPCore::Parameters> resolveParameters (const ProcessOptions& opts);
int runProcess (const ProcessOptions& opts);
int runListPresets (bool jsonOutput);
int runInfo (bool jsonOutput);

} // namespace lowend::cli
