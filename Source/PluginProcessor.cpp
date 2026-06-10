#include "PluginProcessor.h"
#include "PluginEditor.h"

#include <cmath>

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
    publishCoreSettings();
    startTimer (30);
}

LowEndCircuitAudioProcessor::~LowEndCircuitAudioProcessor()
{
    stopTimer();
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
    stopTimer();
    dspCore.prepare (sampleRate, samplesPerBlock, getTotalNumOutputChannels());
    sharedCoreSampleRate.store (sampleRate, std::memory_order_release);
    sharedCoreDryBuffer.setSize (getTotalNumOutputChannels(), samplesPerBlock, false, false, true);
    sharedCoreCircuit.reset();
    publishCoreSettings();
    startTimer (30);
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

#if LOWEND_JUCE_SHARED_CORE
    const auto publishedSlot = publishedCoreSettingsSlot.load (std::memory_order_acquire);
    if (publishedSlot != consumedCoreSettingsSlot.load (std::memory_order_relaxed))
    {
        sharedCoreCircuit.update (sharedCoreSettings[publishedSlot]);
        consumedCoreSettingsSlot.store (publishedSlot, std::memory_order_release);
    }

    const auto numChannels = buffer.getNumChannels();
    const auto numSamples = buffer.getNumSamples();
    jassert (numSamples <= sharedCoreDryBuffer.getNumSamples());
    for (int channel = 0; channel < numChannels; ++channel)
        sharedCoreDryBuffer.copyFrom (channel, 0, buffer, channel, 0, numSamples);

    if (numChannels == 1)
    {
        auto* mono = buffer.getWritePointer (0);
        for (int sample = 0; sample < numSamples; ++sample)
        {
            float ignored = 0.0f;
            sharedCoreCircuit.process (mono[sample], mono[sample], mono[sample], ignored);
        }
    }
    else
    {
        auto* left = buffer.getWritePointer (0);
        auto* right = buffer.getWritePointer (1);
        for (int sample = 0; sample < numSamples; ++sample)
            sharedCoreCircuit.process (left[sample], right[sample], left[sample], right[sample]);
    }

    const auto mix = juce::jlimit (0.0f, 1.0f, params.mix / 100.0f);
    for (int channel = 0; channel < numChannels; ++channel)
    {
        auto* wet = buffer.getWritePointer (channel);
        const auto* dry = sharedCoreDryBuffer.getReadPointer (channel);
        for (int sample = 0; sample < numSamples; ++sample)
            wet[sample] = dry[sample] + (wet[sample] - dry[sample]) * mix;
    }
#else
    dspCore.process (buffer, params);
#endif
}

void LowEndCircuitAudioProcessor::hiResTimerCallback()
{
    publishCoreSettings();
}

void LowEndCircuitAudioProcessor::publishCoreSettings()
{
    const auto sampleRate = sharedCoreSampleRate.load (std::memory_order_acquire);
    const auto intensity = apvts.getRawParameterValue (intensityId)->load();
    const auto body = apvts.getRawParameterValue (bodyId)->load();
    const auto outputDb = apvts.getRawParameterValue (outputId)->load();
    if (std::abs (sampleRate - lastPublishedSampleRate) < 0.01
        && std::abs (intensity - lastPublishedIntensity) < 0.0001f
        && std::abs (body - lastPublishedBody) < 0.0001f
        && std::abs (outputDb - lastPublishedOutputDb) < 0.0001f)
        return;

    const auto currentSlot = publishedCoreSettingsSlot.load (std::memory_order_relaxed);
    const auto consumedSlot = consumedCoreSettingsSlot.load (std::memory_order_acquire);
    uint32_t pendingSlot = 0;
    while (pendingSlot == currentSlot || pendingSlot == consumedSlot)
        ++pendingSlot;
    sharedCoreSettings[pendingSlot] = lowend::DSPPrecompute::makeDSPSettings (
        static_cast<float> (sampleRate),
        intensity,
        body,
        outputDb,
        static_cast<uint32_t> (lowend::DSPModel::circuit));
    lastPublishedSampleRate = sampleRate;
    lastPublishedIntensity = intensity;
    lastPublishedBody = body;
    lastPublishedOutputDb = outputDb;
    publishedCoreSettingsSlot.store (pendingSlot, std::memory_order_release);
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
