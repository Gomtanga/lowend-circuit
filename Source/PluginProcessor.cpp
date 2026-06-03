#include "PluginProcessor.h"
#include "PluginEditor.h"

namespace
{
constexpr auto intensityId = "intensity";
constexpr auto bodyId = "body";
constexpr auto mixId = "mix";
constexpr auto outputId = "output";

float dbToLinear (float db)
{
    return juce::Decibels::decibelsToGain (db);
}
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
    currentSampleRate = sampleRate;
    const juce::dsp::ProcessSpec spec { sampleRate, static_cast<juce::uint32> (samplesPerBlock),
                                        static_cast<juce::uint32> (getTotalNumOutputChannels()) };

    lowShelf.prepare (spec);
    lowPass.prepare (spec);
    dryBuffer.setSize (getTotalNumOutputChannels(), samplesPerBlock);
    subBuffer.setSize (getTotalNumOutputChannels(), samplesPerBlock);

    intensitySmoothed.reset (sampleRate, 0.025);
    bodySmoothed.reset (sampleRate, 0.025);
    mixSmoothed.reset (sampleRate, 0.025);

    updateFilters();
}

void LowEndCircuitAudioProcessor::updateFilters()
{
    const auto intensity = apvts.getRawParameterValue (intensityId)->load() / 100.0f;
    const auto shelfDb = juce::jmap (intensity, 0.0f, 1.0f, 0.0f, 8.5f);
    const auto shelfFreq = juce::jmap (intensity, 0.0f, 1.0f, 72.0f, 105.0f);

    *lowShelf.state = *juce::dsp::IIR::Coefficients<float>::makeLowShelf (
        currentSampleRate, shelfFreq, 0.72f, dbToLinear (shelfDb));
    *lowPass.state = *juce::dsp::IIR::Coefficients<float>::makeLowPass (currentSampleRate, 135.0f, 0.68f);
}

void LowEndCircuitAudioProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;
    const auto numChannels = buffer.getNumChannels();
    const auto numSamples = buffer.getNumSamples();

    dryBuffer.makeCopyOf (buffer, true);

    updateFilters();
    intensitySmoothed.setTargetValue (apvts.getRawParameterValue (intensityId)->load() / 100.0f);
    bodySmoothed.setTargetValue (apvts.getRawParameterValue (bodyId)->load() / 100.0f);
    mixSmoothed.setTargetValue (apvts.getRawParameterValue (mixId)->load() / 100.0f);

    juce::dsp::AudioBlock<float> block (buffer);
    juce::dsp::ProcessContextReplacing<float> context (block);
    lowShelf.process (context);

    subBuffer.makeCopyOf (dryBuffer, true);
    juce::dsp::AudioBlock<float> subBlock (subBuffer);
    juce::dsp::ProcessContextReplacing<float> subContext (subBlock);
    lowPass.process (subContext);

    const auto outputGain = dbToLinear (apvts.getRawParameterValue (outputId)->load());

    for (int sample = 0; sample < numSamples; ++sample)
    {
        const auto intensity = intensitySmoothed.getNextValue();
        const auto body = bodySmoothed.getNextValue();
        const auto mix = mixSmoothed.getNextValue();
        const auto headroom = dbToLinear (juce::jmap (intensity, 0.0f, 1.0f, 0.0f, -3.0f));

        for (int channel = 0; channel < numChannels; ++channel)
        {
            auto* wet = buffer.getWritePointer (channel);
            const auto* dry = dryBuffer.getReadPointer (channel);
            const auto* sub = subBuffer.getReadPointer (channel);

            const auto subHarmonic = std::tanh (sub[sample] * 2.4f) * 0.18f * body;
            const auto enhanced = (wet[sample] + subHarmonic) * headroom;
            const auto blended = dry[sample] + (enhanced - dry[sample]) * mix;

            wet[sample] = std::tanh (blended * outputGain * 1.05f) / 1.05f;
        }
    }
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
