#include "CLICommands.h"

namespace lowend::cli
{

const std::vector<Preset>& getBuiltinPresets()
{
    static const std::vector<Preset> presets = {
        { "Gentle",  { 28.0f, 12.0f, 100.0f, -1.0f } },
        { "LowEnd",  { 55.0f, 30.0f, 100.0f, -1.5f } },
        { "Deep",    { 78.0f, 48.0f, 92.0f,  -3.0f } },
        { "Reset",   { 0.0f,  0.0f,  100.0f,  0.0f } },
    };
    return presets;
}

std::optional<LowEndDSPCore::Parameters> resolveParameters (const ProcessOptions& opts)
{
    LowEndDSPCore::Parameters params;

    // Start from preset if specified
    bool foundPreset = false;
    if (! opts.preset.empty())
    {
        for (const auto& p : getBuiltinPresets())
        {
            if (p.name == opts.preset)
            {
                params = p.params;
                foundPreset = true;
                break;
            }
        }

        if (! foundPreset)
            return std::nullopt;
    }
    else
    {
        // Default: LowEnd preset values
        params = { 45.0f, 30.0f, 100.0f, -1.5f };
    }

    // Override with explicit CLI args
    if (opts.intensity >= 0.0f)
        params.intensity = juce::jlimit (0.0f, 100.0f, opts.intensity);
    if (opts.body >= 0.0f)
        params.body = juce::jlimit (0.0f, 100.0f, opts.body);
    if (opts.mix >= 0.0f)
        params.mix = juce::jlimit (0.0f, 100.0f, opts.mix);
    if (opts.outputDb > -100.0f)
        params.outputDb = juce::jlimit (-18.0f, 6.0f, opts.outputDb);

    return params;
}

int runProcess (const ProcessOptions& opts)
{
    if (opts.inputFile.empty() || opts.outputFile.empty())
    {
        std::cerr << "Error: both --input and --output are required.\n";
        return 1;
    }

    auto maybeParams = resolveParameters (opts);
    if (! maybeParams)
    {
        std::cerr << "Error: unknown preset '" << opts.preset << "'.\n";
        return 1;
    }
    const auto& params = *maybeParams;

    // Read input audio file
    const juce::File inputFile (opts.inputFile);
    if (! inputFile.existsAsFile())
    {
        std::cerr << "Error: input file not found: " << opts.inputFile << "\n";
        return 1;
    }

    juce::AudioFormatManager formatManager;
    formatManager.registerBasicFormats();

    std::unique_ptr<juce::AudioFormatReader> reader (
        formatManager.createReaderFor (inputFile));

    if (! reader)
    {
        std::cerr << "Error: cannot read audio file: " << opts.inputFile << "\n";
        return 1;
    }

    const double sampleRate = reader->sampleRate;
    const int numChannels = static_cast<int> (reader->numChannels);
    const int totalSamples = static_cast<int> (reader->lengthInSamples);
    const int blockSize = 1024;

    // Load entire file into buffer
    juce::AudioBuffer<float> buffer (numChannels, totalSamples);
    reader->read (&buffer, 0, totalSamples, 0, true, true);

    // Prepare DSP
    LowEndDSPCore dsp;
    dsp.prepare (sampleRate, blockSize, numChannels);

    // Process in blocks (setNonRealtime equivalent: just process all blocks)
    int processed = 0;
    while (processed < totalSamples)
    {
        const int numToDo = juce::jmin (blockSize, totalSamples - processed);
        juce::AudioBuffer<float> subBuffer (buffer.getArrayOfWritePointers(),
                                             numChannels,
                                             processed,
                                             numToDo);
        dsp.process (subBuffer, params);
        processed += numToDo;
    }

    // Write output
    const juce::File outputFile (opts.outputFile);
    outputFile.deleteFile();

    juce::WavAudioFormat wavFormat;
    std::unique_ptr<juce::AudioFormatWriter> writer (
        wavFormat.createWriterFor (new juce::FileOutputStream (outputFile),
                                    sampleRate,
                                    static_cast<unsigned int> (numChannels),
                                    24,
                                    {},
                                    0));

    if (! writer)
    {
        std::cerr << "Error: cannot create output file: " << opts.outputFile << "\n";
        return 1;
    }

    writer->writeFromAudioSampleBuffer (buffer, 0, totalSamples);

    if (opts.jsonOutput)
    {
        auto* obj = new juce::DynamicObject();
        obj->setProperty ("status", "ok");
        obj->setProperty ("input", juce::String (opts.inputFile));
        obj->setProperty ("output", juce::String (opts.outputFile));
        obj->setProperty ("sampleRate", static_cast<int> (sampleRate));
        obj->setProperty ("channels", numChannels);
        obj->setProperty ("duration", juce::String (static_cast<double> (totalSamples) / sampleRate, 2) + "s");
        obj->setProperty ("intensity", params.intensity);
        obj->setProperty ("body", params.body);
        obj->setProperty ("mix", params.mix);
        obj->setProperty ("outputDb", params.outputDb);
        std::cout << juce::JSON::toString (juce::var (obj), true) << "\n";
    }
    else
    {
        std::cout << "Processed: " << opts.inputFile << " -> " << opts.outputFile << "\n";
        std::cout << "  Duration:   " << juce::String (static_cast<double> (totalSamples) / sampleRate, 2) << "s\n";
        std::cout << "  SampleRate: " << sampleRate << " Hz\n";
        std::cout << "  Channels:   " << numChannels << "\n";
        std::cout << "  LowEnd:     " << params.intensity << "\n";
        std::cout << "  Body:       " << params.body << "\n";
        std::cout << "  Mix:        " << params.mix << "\n";
        std::cout << "  Output:     " << params.outputDb << " dB\n";
    }

    return 0;
}

int runListPresets (bool jsonOutput)
{
    const auto& presets = getBuiltinPresets();

    if (jsonOutput)
    {
        std::cout << "[\n";
        for (size_t i = 0; i < presets.size(); ++i)
        {
            const auto& p = presets[i];
            std::cout << "  {\n";
            std::cout << "    \"name\": \"" << p.name << "\",\n";
            std::cout << "    \"intensity\": " << p.params.intensity << ",\n";
            std::cout << "    \"body\": " << p.params.body << ",\n";
            std::cout << "    \"mix\": " << p.params.mix << ",\n";
            std::cout << "    \"outputDb\": " << p.params.outputDb << "\n";
            std::cout << "  }" << (i + 1 < presets.size() ? "," : "") << "\n";
        }
        std::cout << "]\n";
    }
    else
    {
        std::cout << "Available presets:\n\n";
        for (const auto& p : presets)
        {
            std::cout << "  " << p.name << "\n";
            std::cout << "    LowEnd: " << p.params.intensity
                      << "  Body: " << p.params.body
                      << "  Mix: " << p.params.mix
                      << "  Output: " << p.params.outputDb << " dB\n\n";
        }
    }

    return 0;
}

int runInfo (bool jsonOutput)
{
    if (jsonOutput)
    {
        std::cout << "{\n";
        std::cout << "  \"name\": \"LowEnd Circuit\",\n";
        std::cout << "  \"version\": \"0.1.0\",\n";
        std::cout << "  \"description\": \"Desktop bass enhancer with harmonic coloration\",\n";
        std::cout << "  \"parameters\": [\n";
        std::cout << "    {\"id\": \"intensity\", \"name\": \"LowEnd\", \"range\": [0, 100], \"default\": 45.0},\n";
        std::cout << "    {\"id\": \"body\", \"name\": \"Body\", \"range\": [0, 100], \"default\": 30.0},\n";
        std::cout << "    {\"id\": \"mix\", \"name\": \"Mix\", \"range\": [0, 100], \"default\": 100.0},\n";
        std::cout << "    {\"id\": \"output\", \"name\": \"Output\", \"range\": [-18, 6], \"default\": -1.5}\n";
        std::cout << "  ]\n";
        std::cout << "}\n";
    }
    else
    {
        std::cout << "LowEnd Circuit v0.1.0\n";
        std::cout << "Desktop bass enhancer with harmonic coloration\n\n";
        std::cout << "Parameters:\n";
        std::cout << "  LowEnd (intensity)  0 - 100   default: 45.0\n";
        std::cout << "  Body                0 - 100   default: 30.0\n";
        std::cout << "  Mix                 0 - 100   default: 100.0\n";
        std::cout << "  Output             -18 - 6 dB default: -1.5\n";
    }

    return 0;
}

} // namespace lowend::cli
