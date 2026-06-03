#include "PluginEditor.h"

namespace
{
constexpr auto intensityId = "intensity";
constexpr auto bodyId = "body";
constexpr auto mixId = "mix";
constexpr auto outputId = "output";
}

LowEndCircuitAudioProcessorEditor::LowEndCircuitAudioProcessorEditor (LowEndCircuitAudioProcessor& p)
    : AudioProcessorEditor (&p), audioProcessor (p)
{
    setResizable (true, true);
    setResizeLimits (620, 420, 960, 680);
    setSize (720, 480);

    styleKnob (intensitySlider, "%");
    styleKnob (bodySlider, "%");
    styleKnob (mixSlider, "%");
    styleKnob (outputSlider, " dB");

    for (auto* slider : { &intensitySlider, &bodySlider, &mixSlider, &outputSlider })
        addAndMakeVisible (*slider);

    intensityLabel.setText ("LowEnd", juce::dontSendNotification);
    bodyLabel.setText ("Body", juce::dontSendNotification);
    mixLabel.setText ("Mix", juce::dontSendNotification);
    outputLabel.setText ("Output", juce::dontSendNotification);

    for (auto* label : { &intensityLabel, &bodyLabel, &mixLabel, &outputLabel })
        styleLabel (*label);

    statusLabel.setText ("Standalone mode: choose input and output devices from the app audio settings.",
                         juce::dontSendNotification);
    statusLabel.setJustificationType (juce::Justification::centred);
    statusLabel.setColour (juce::Label::textColourId, juce::Colour (0xffb9c1cc));
    statusLabel.setMinimumHorizontalScale (0.72f);
    addAndMakeVisible (statusLabel);

    for (auto* button : { &gentleButton, &lowendButton, &deepButton, &resetButton })
        styleButton (*button);

    gentleButton.onClick = [this] { applyPreset (28.0f, 12.0f, 100.0f, -1.0f); };
    lowendButton.onClick = [this] { applyPreset (55.0f, 30.0f, 100.0f, -1.5f); };
    deepButton.onClick = [this] { applyPreset (78.0f, 48.0f, 92.0f, -3.0f); };
    resetButton.onClick = [this] { applyPreset (0.0f, 0.0f, 100.0f, 0.0f); };

    intensityAttachment = std::make_unique<SliderAttachment> (audioProcessor.apvts, intensityId, intensitySlider);
    bodyAttachment = std::make_unique<SliderAttachment> (audioProcessor.apvts, bodyId, bodySlider);
    mixAttachment = std::make_unique<SliderAttachment> (audioProcessor.apvts, mixId, mixSlider);
    outputAttachment = std::make_unique<SliderAttachment> (audioProcessor.apvts, outputId, outputSlider);
}

void LowEndCircuitAudioProcessorEditor::styleKnob (juce::Slider& slider, const juce::String& suffix)
{
    slider.setSliderStyle (juce::Slider::RotaryHorizontalVerticalDrag);
    slider.setTextBoxStyle (juce::Slider::TextBoxBelow, false, 82, 24);
    slider.setTextValueSuffix (suffix);
    slider.setColour (juce::Slider::rotarySliderFillColourId, juce::Colour (0xfff6c04f));
    slider.setColour (juce::Slider::rotarySliderOutlineColourId, juce::Colour (0xff31343a));
    slider.setColour (juce::Slider::thumbColourId, juce::Colour (0xfff8e7b0));
    slider.setColour (juce::Slider::textBoxTextColourId, juce::Colours::whitesmoke);
    slider.setColour (juce::Slider::textBoxOutlineColourId, juce::Colours::transparentBlack);
}

void LowEndCircuitAudioProcessorEditor::styleLabel (juce::Label& label)
{
    label.setJustificationType (juce::Justification::centred);
    label.setColour (juce::Label::textColourId, juce::Colours::whitesmoke);
    label.setFont (juce::FontOptions (14.0f, juce::Font::bold));
    addAndMakeVisible (label);
}

void LowEndCircuitAudioProcessorEditor::styleButton (juce::TextButton& button)
{
    button.setColour (juce::TextButton::buttonColourId, juce::Colour (0xff2a2f38));
    button.setColour (juce::TextButton::buttonOnColourId, juce::Colour (0xff3c4655));
    button.setColour (juce::TextButton::textColourOffId, juce::Colour (0xfff2f4f7));
    button.setColour (juce::TextButton::textColourOnId, juce::Colours::white);
    addAndMakeVisible (button);
}

void LowEndCircuitAudioProcessorEditor::applyPreset (float intensity, float body, float mix, float outputDb)
{
    setParameterValue (intensityId, intensity);
    setParameterValue (bodyId, body);
    setParameterValue (mixId, mix);
    setParameterValue (outputId, outputDb);
}

void LowEndCircuitAudioProcessorEditor::setParameterValue (const juce::String& parameterId, float value)
{
    if (auto* parameter = audioProcessor.apvts.getParameter (parameterId))
    {
        const auto normalised = parameter->convertTo0to1 (value);
        parameter->beginChangeGesture();
        parameter->setValueNotifyingHost (normalised);
        parameter->endChangeGesture();
    }
}

void LowEndCircuitAudioProcessorEditor::paint (juce::Graphics& g)
{
    g.fillAll (juce::Colour (0xff15171b));

    auto bounds = getLocalBounds().toFloat();
    juce::ColourGradient gradient (juce::Colour (0xff24272d), bounds.getTopLeft(),
                                   juce::Colour (0xff111317), bounds.getBottomRight(), false);
    g.setGradientFill (gradient);
    g.fillRoundedRectangle (bounds.reduced (12.0f), 8.0f);

    auto header = getLocalBounds().reduced (28, 22).removeFromTop (92);
    g.setColour (juce::Colour (0xff0f1013));
    g.fillRoundedRectangle (header.toFloat(), 8.0f);

    g.setColour (juce::Colour (0xff303641));
    g.drawRoundedRectangle (header.toFloat(), 8.0f, 1.0f);

    g.setColour (juce::Colour (0xfff6c04f));
    g.setFont (juce::FontOptions (31.0f, juce::Font::bold));
    g.drawFittedText ("LowEnd Circuit", header.reduced (18, 10).removeFromTop (38),
                      juce::Justification::centredLeft, 1);

    g.setColour (juce::Colour (0xffaeb4bd));
    g.setFont (juce::FontOptions (14.0f));
    g.drawFittedText ("Desktop bass enhancer with plugin and standalone builds",
                      header.reduced (18, 10).withTrimmedTop (42), juce::Justification::centredLeft, 1);

    auto statusBadge = getLocalBounds().reduced (46, 42).removeFromTop (34).removeFromRight (190).toFloat();
    g.setColour (juce::Colour (0xff1f252d));
    g.fillRoundedRectangle (statusBadge, 6.0f);
    g.setColour (juce::Colour (0xffeef1f5));
    g.setFont (juce::FontOptions (13.0f, juce::Font::bold));
    g.drawFittedText ("READY", statusBadge.toNearestInt(), juce::Justification::centred, 1);
}

void LowEndCircuitAudioProcessorEditor::resized()
{
    auto area = getLocalBounds().reduced (30, 22);
    area.removeFromTop (112);

    auto presetRow = area.removeFromTop (38);
    const auto presetGap = 10;
    const auto presetWidth = (presetRow.getWidth() - presetGap * 3) / 4;
    gentleButton.setBounds (presetRow.removeFromLeft (presetWidth));
    presetRow.removeFromLeft (presetGap);
    lowendButton.setBounds (presetRow.removeFromLeft (presetWidth));
    presetRow.removeFromLeft (presetGap);
    deepButton.setBounds (presetRow.removeFromLeft (presetWidth));
    presetRow.removeFromLeft (presetGap);
    resetButton.setBounds (presetRow.removeFromLeft (presetWidth));

    area.removeFromTop (22);

    const auto columnWidth = area.getWidth() / 4;
    auto place = [&area, columnWidth] (juce::Slider& slider, juce::Label& label, int index)
    {
        auto column = area.withX (area.getX() + index * columnWidth).withWidth (columnWidth).reduced (8, 0);
        label.setBounds (column.removeFromTop (24));
        slider.setBounds (column.removeFromTop (170));
    };

    place (intensitySlider, intensityLabel, 0);
    place (bodySlider, bodyLabel, 1);
    place (mixSlider, mixLabel, 2);
    place (outputSlider, outputLabel, 3);

    statusLabel.setBounds (getLocalBounds().reduced (36, 20).removeFromBottom (34));
}
