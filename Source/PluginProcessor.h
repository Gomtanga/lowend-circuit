#pragma once

#include <JuceHeader.h>

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

    using Filter = juce::dsp::IIR::Filter<float>;
    using Coefficients = juce::dsp::IIR::Coefficients<float>;

    juce::AudioBuffer<float> dryBuffer;
    juce::AudioBuffer<float> subBuffer;
    juce::dsp::ProcessorDuplicator<Filter, Coefficients> lowShelf;
    juce::dsp::ProcessorDuplicator<Filter, Coefficients> lowPass;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> intensitySmoothed;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> bodySmoothed;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> mixSmoothed;

    double currentSampleRate = 44100.0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LowEndCircuitAudioProcessor)
};
