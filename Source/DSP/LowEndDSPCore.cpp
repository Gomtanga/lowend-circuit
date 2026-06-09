#include "LowEndDSPCore.h"

namespace lowend
{

void LowEndDSPCore::prepare (double sampleRate, int samplesPerBlock, int numChannels)
{
    currentSampleRate = sampleRate;
    const juce::dsp::ProcessSpec spec { sampleRate,
                                        static_cast<juce::uint32> (samplesPerBlock),
                                        static_cast<juce::uint32> (numChannels) };

    lowShelf.prepare (spec);
    lowPass.prepare (spec);
    dryBuffer.setSize (numChannels, samplesPerBlock);
    subBuffer.setSize (numChannels, samplesPerBlock);
}

void LowEndDSPCore::reset()
{
    lowShelf.reset();
    lowPass.reset();
    dryBuffer.clear();
    subBuffer.clear();
}

void LowEndDSPCore::updateFilters (float intensity01, double sampleRate)
{
    const auto shelfDb = juce::jmap (intensity01, 0.0f, 1.0f, 0.0f, 8.5f);
    const auto shelfFreq = juce::jmap (intensity01, 0.0f, 1.0f, 72.0f, 105.0f);

    *lowShelf.state = *juce::dsp::IIR::Coefficients<float>::makeLowShelf (
        sampleRate, shelfFreq, 0.72f, juce::Decibels::decibelsToGain (shelfDb));

    *lowPass.state = *juce::dsp::IIR::Coefficients<float>::makeLowPass (sampleRate, 135.0f, 0.68f);
}

void LowEndDSPCore::process (juce::AudioBuffer<float>& buffer, const Parameters& params)
{
    juce::ScopedNoDenormals noDenormals;
    const auto numChannels = buffer.getNumChannels();
    const auto numSamples = buffer.getNumSamples();

    const auto intensity01 = params.intensity / 100.0f;
    const auto body01 = params.body / 100.0f;
    const auto mix01 = params.mix / 100.0f;
    const auto outputGain = juce::Decibels::decibelsToGain (params.outputDb);

    dryBuffer.makeCopyOf (buffer, true);

    updateFilters (intensity01, currentSampleRate);

    // Low-shelf enhancement
    juce::dsp::AudioBlock<float> block (buffer);
    juce::dsp::ProcessContextReplacing<float> context (block);
    lowShelf.process (context);

    // Sub-bass extraction
    subBuffer.makeCopyOf (dryBuffer, true);
    juce::dsp::AudioBlock<float> subBlock (subBuffer);
    juce::dsp::ProcessContextReplacing<float> subContext (subBlock);
    lowPass.process (subContext);

    // Per-sample blend with harmonic saturation
    const auto headroom = juce::Decibels::decibelsToGain (
        juce::jmap (intensity01, 0.0f, 1.0f, 0.0f, -3.0f));

    for (int sample = 0; sample < numSamples; ++sample)
    {
        for (int channel = 0; channel < numChannels; ++channel)
        {
            auto* wet = buffer.getWritePointer (channel);
            const auto* dry = dryBuffer.getReadPointer (channel);
            const auto* sub = subBuffer.getReadPointer (channel);

            const auto subHarmonic = std::tanh (sub[sample] * 2.4f) * 0.18f * body01;
            const auto enhanced = (wet[sample] + subHarmonic) * headroom;
            const auto blended = dry[sample] + (enhanced - dry[sample]) * mix01;

            wet[sample] = std::tanh (blended * outputGain * 1.05f) / 1.05f;
        }
    }
}

} // namespace lowend
