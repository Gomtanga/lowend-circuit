#pragma once

#include "CircuitBass.h"
#include "HighExciter.h"

namespace lowend {

class Processor {
public:
    static constexpr uint32_t maxSupportedChannels = 2;

    void prepare(double sampleRate, uint32_t maxChannels);
    void update(const DSPSettings& settings);
    void process(float** channels, uint32_t frames);
    void reset();

    double sampleRate() const { return sampleRate_; }
    uint32_t channelCount() const { return channelCount_; }
    DSPModel model() const { return model_; }

private:
    CircuitBass circuit_;
    HighExciter exciter_;
    double sampleRate_ = 48000.0;
    uint32_t channelCount_ = 2;
    DSPModel model_ = DSPModel::clean;
};

} // namespace lowend
