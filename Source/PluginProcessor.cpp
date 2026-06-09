#include "PluginProcessor.h"
#include "PluginEditor.h"

namespace
{
constexpr auto intensityId = "intensity";
constexpr auto bodyId = "body";
constexpr auto mixId = "mix";
constexpr auto outputId = "output";
}

LowEndCircuitAudioProcessor::LowEndCircuitAudioProcessor()
    : AudioProcessor (BusesProperties()
          .withInput ("Input", juce::AudioChannelSet::stereo(), true)
          .withOutput ("Output", juce::AudioChannelSet::stereo(), true)),
      apvts (*this, nullptr, "Parameters", createParameterLayout())
{
}

juce::AudioProcessorValueTreeState::ParameterLayout LowEndCircuitAudioProcessor::createParameterLayout()
{
    std::vector<std::unique_ptr<juce::RangedAudioParameter>> params;

    params.push_back (std::make_unique<juce::AudioParameterFloat> (
        intensityId, "LowEnd", juce::NormalisableRange<float> (0.0f, 100.0f, 0.1f), 45.0f));
    params.push_back (std::make_unique<juce::AudioParameterFloat> (
        bodyId, "Body", juce::NormalisableRange<float> (0.0f, 100.0f, 0.1f), 30.0f));
    params.push_back (std::make_unique<juce::AudioParameterFloat> (
        mixId, "Mix", juce::NormalisableRange<float> (0.0f, 100.0f, 0.1f), 100.0f));
    params.push_back (std::make_unique<juce::AudioParameterFloat> (
        outputId, "Output", juce::NormalisableRange<float> (-18.0f, 6.0f, 0.1f), -1.5f));

    return { params.begin(), params.end() };
}

bool LowEndCircuitAudioProcessor::isBusesLayoutSupported (const BusesLayout& layouts) const
{
    const auto mainIn = layouts.getMainInputChannelSet();
    const auto mainOut = layouts.getMainOutputChannelSet();
    return mainIn == mainOut && (mainIn == juce::AudioChannelSet::mono()
                                 || mainIn == juce::AudioChannelSet::stereo());
}

void LowEndCircuitAudioProcessor::prepareToPlay (double sampleRate, int samplesPerBlock)
{
    dspCore.prepare (sampleRate, samplesPerBlock, getTotalNumOutputChannels());
    intensitySmoothed.reset (sampleRate, 0.025);
    bodySmoothed.reset (sampleRate, 0.025);
    mixSmoothed.reset (sampleRate, 0.025);
}

void LowEndCircuitAudioProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    intensitySmoothed.setTargetValue (apvts.getRawParameterValue (intensityId)->load());
    bodySmoothed.setTargetValue (apvts.getRawParameterValue (bodyId)->load());
    mixSmoothed.setTargetValue (apvts.getRawParameterValue (mixId)->load());

    lowend::LowEndDSPCore::Parameters params;
    params.intensity = intensitySmoothed.getCurrentValue();
    params.body = bodySmoothed.getCurrentValue();
    params.mix = mixSmoothed.getCurrentValue();
    params.outputDb = apvts.getRawParameterValue (outputId)->load();

    // SmoothedValue는 process 내부에서 sample-by-sample로 처리되지 않으므로
    // 현재 블록의 타겟 값을 직접 전달
    params.intensity = apvts.getRawParameterValue (intensityId)->load();
    params.body = apvts.getRawParameterValue (bodyId)->load();
    params.mix = apvts.getRawParameterValue (mixId)->load();

    dspCore.process (buffer, params);
}

void LowEndCircuitAudioProcessor::getStateInformation (juce::MemoryBlock& destData)
{
    auto state = apvts.copyState();
    std::unique_ptr<juce::XmlElement> xml (state.createXml());
    copyXmlToBinary (*xml, destData);
}

void LowEndCircuitAudioProcessor::setStateInformation (const void* data, int sizeInBytes)
{
    std::unique_ptr<juce::XmlElement> xmlState (getXmlFromBinary (data, sizeInBytes));

    if (xmlState != nullptr && xmlState->hasTagName (apvts.state.getType()))
        apvts.replaceState (juce::ValueTree::fromXml (*xmlState));
}

juce::AudioProcessorEditor* LowEndCircuitAudioProcessor::createEditor()
{
    return new LowEndCircuitAudioProcessorEditor (*this);
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new LowEndCircuitAudioProcessor();
}
