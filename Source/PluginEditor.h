#pragma once

#include <JuceHeader.h>
#include "PluginProcessor.h"

class LowEndCircuitAudioProcessorEditor final : public juce::AudioProcessorEditor
{
public:
    explicit LowEndCircuitAudioProcessorEditor (LowEndCircuitAudioProcessor&);
    ~LowEndCircuitAudioProcessorEditor() override = default;

    void paint (juce::Graphics&) override;
    void resized() override;

private:
    using SliderAttachment = juce::AudioProcessorValueTreeState::SliderAttachment;

    static void styleKnob (juce::Slider& slider, const juce::String& suffix);
    void styleLabel (juce::Label& label);
    void styleButton (juce::TextButton& button);
    void applyPreset (float intensity, float body, float mix, float outputDb);
    void setParameterValue (const juce::String& parameterId, float value);

    LowEndCircuitAudioProcessor& audioProcessor;

    juce::Slider intensitySlider;
    juce::Slider bodySlider;
    juce::Slider mixSlider;
    juce::Slider outputSlider;

    juce::Label intensityLabel;
    juce::Label bodyLabel;
    juce::Label mixLabel;
    juce::Label outputLabel;
    juce::Label statusLabel;

    juce::TextButton gentleButton { "Gentle" };
    juce::TextButton lowendButton { "LowEnd" };
    juce::TextButton deepButton { "Deep" };
    juce::TextButton resetButton { "Reset" };

    std::unique_ptr<SliderAttachment> intensityAttachment;
    std::unique_ptr<SliderAttachment> bodyAttachment;
    std::unique_ptr<SliderAttachment> mixAttachment;
    std::unique_ptr<SliderAttachment> outputAttachment;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LowEndCircuitAudioProcessorEditor)
};
