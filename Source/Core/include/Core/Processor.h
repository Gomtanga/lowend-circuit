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
    struct Bank {
        CircuitBass circuit;
        HighExciter exciter;
        DSPModel model = DSPModel::clean;
        void update(const DSPSettings& settings, bool clearState);
        void process(float left, float right, float& leftOut, float& rightOut);
        void reset();
    };
    static constexpr uint32_t transitionFrames = 256;
    Bank banks_[2];
    uint32_t active_ = 0;
    uint32_t target_ = 1;
    uint32_t transitionRemaining_ = 0;
    bool initialized_ = false;
    bool hasPending_ = false;
    DSPSettings pending_{};
    double sampleRate_ = 48000.0;
    uint32_t channelCount_ = 2;
    DSPModel model_ = DSPModel::clean;
};

} // namespace lowend
