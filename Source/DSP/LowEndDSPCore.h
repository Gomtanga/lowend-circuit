#pragma once

#include <juce_core/juce_core.h>
#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_dsp/juce_dsp.h>

namespace lowend
{

/**
 * LowEnd Circuit의 핵심 DSP 처리 클래스.
 * GUI에 의존하지 않는 순수 오디오 처리 로직만 포함한다.
 * PluginProcessor(플러그인)와 CLI 타겟 모두에서 사용된다.
 */
class LowEndDSPCore
{
public:
    LowEndDSPCore() = default;
    ~LowEndDSPCore() = default;

    struct Parameters
    {
        float intensity = 45.0f; // 0-100
        float body = 30.0f;      // 0-100
        float mix = 100.0f;      // 0-100
        float outputDb = -1.5f;  // -18..6
    };

    void prepare (double sampleRate, int samplesPerBlock, int numChannels);
    void process (juce::AudioBuffer<float>& buffer, const Parameters& params);
    void reset();

private:
    void updateFilters (float intensity01, double sampleRate);

    using Filter = juce::dsp::IIR::Filter<float>;
    using Coefficients = juce::dsp::IIR::Coefficients<float>;

    juce::AudioBuffer<float> dryBuffer;
    juce::AudioBuffer<float> subBuffer;
    juce::dsp::ProcessorDuplicator<Filter, Coefficients> lowShelf;
    juce::dsp::ProcessorDuplicator<Filter, Coefficients> lowPass;

    double currentSampleRate = 44100.0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LowEndDSPCore)
};

} // namespace lowend
