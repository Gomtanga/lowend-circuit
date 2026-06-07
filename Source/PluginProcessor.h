#pragma once

#include <JuceHeader.h>

// ─── Shared DSP Core ────────────────────────────────────
#include <Core/CircuitBass.h>
#include <Core/Core.h>

class LowEndCircuitAudioProcessor final : public juce::AudioProcessor
{
public:
    LowEndCircuitAudioProcessor();
    ~LowEndCircuitAudioProcessor() override = default;

    void prepareToPlay (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override {}
    bool isBusesLayoutSupported (const BusesLayout& layouts) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor() const override { return true; }

    const juce::String getName() const override { return JucePlugin_Name; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    bool isMidiEffect() const override { return false; }
    double getTailLengthSeconds() const override { return 0.0; }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    juce::AudioProcessorValueTreeState apvts;

private:
    static juce::AudioProcessorValueTreeState::ParameterLayout createParameterLayout();
    void updateFilters();
    void updateCoreSettings();

    using Filter = juce::dsp::IIR::Filter<float>;
    using Coefficients = juce::dsp::IIR::Coefficients<float>;

    // ─── JUCE DSP (existing, will be replaced by Core) ───
    juce::AudioBuffer<float> dryBuffer;
    juce::AudioBuffer<float> subBuffer;
    juce::dsp::ProcessorDuplicator<Filter, Coefficients> lowShelf;
    juce::dsp::ProcessorDuplicator<Filter, Coefficients> lowPass;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> intensitySmoothed;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> bodySmoothed;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> mixSmoothed;

    // ─── Core DSP (shared cross-platform) ─────────────────
    lowend::CircuitBass circuitBass;
    LCDSPSettings currentCoreSettings_{};

    /// Set to true to use Core::CircuitBass for processing instead of JUCE IIR.
    /// Default: false (keeps existing JUCE sound for DAW session compatibility).
    static constexpr bool kUseSharedCoreCircuitBass = false;

    double currentSampleRate = 44100.0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LowEndCircuitAudioProcessor)
};
