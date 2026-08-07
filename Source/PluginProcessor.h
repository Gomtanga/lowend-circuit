#pragma once

#include <JuceHeader.h>
#include <Core/CircuitBass.h>
#include "DSP/LowEndDSPCore.h"

#include <array>
#include <atomic>

class LowEndCircuitAudioProcessor final : public juce::AudioProcessor,
                                          private juce::HighResolutionTimer
{
public:
    LowEndCircuitAudioProcessor();
    ~LowEndCircuitAudioProcessor() override;

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
    void hiResTimerCallback() override;
    void publishCoreSettings();

    lowend::LowEndDSPCore dspCore;
    lowend::CircuitBass sharedCoreCircuit;
    juce::AudioBuffer<float> sharedCoreDryBuffer;
    std::array<LCDSPSettings, 3> sharedCoreSettings {};
    std::atomic<uint32_t> publishedCoreSettingsSlot { 0 };
    std::atomic<uint32_t> consumedCoreSettingsSlot { 3 };
    std::atomic<double> sharedCoreSampleRate { 44100.0 };
    double lastPublishedSampleRate = 0.0;
    float lastPublishedIntensity = -1.0f;
    float lastPublishedBody = -1.0f;
    float lastPublishedOutputDb = 1000.0f;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> intensitySmoothed;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> bodySmoothed;
    juce::SmoothedValue<float, juce::ValueSmoothingTypes::Linear> mixSmoothed;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LowEndCircuitAudioProcessor)
};
