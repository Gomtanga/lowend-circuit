#include "../include/Core/Processor.h"

#include <cmath>

namespace lowend {
namespace {
DSPModel selectedModel(const DSPSettings& settings) {
    return settings.dspModel == static_cast<uint32_t>(DSPModel::circuit) ? DSPModel::circuit
        : settings.dspModel == static_cast<uint32_t>(DSPModel::highExciter) ? DSPModel::highExciter
        : DSPModel::clean;
}
}

void Processor::Bank::update(const DSPSettings& settings, bool clearState) {
    model = selectedModel(settings);
    circuit.update(settings);
    exciter.update(settings);
    if (clearState) reset();
}

void Processor::Bank::process(float left, float right, float& leftOut, float& rightOut) {
    leftOut = left;
    rightOut = right;
    if (model == DSPModel::circuit) circuit.process(left, right, leftOut, rightOut);
    else if (model == DSPModel::highExciter) exciter.process(left, right, leftOut, rightOut);
}

void Processor::Bank::reset() {
    circuit.reset();
    exciter.reset();
}

void Processor::prepare(double sampleRate, uint32_t maxChannels) {
    sampleRate_ = std::isfinite(sampleRate) && sampleRate >= 8000.0 ? sampleRate : 48000.0;
    channelCount_ = maxChannels < 1u ? 1u
        : maxChannels > maxSupportedChannels ? maxSupportedChannels : maxChannels;
    initialized_ = false;
    active_ = 0;
    target_ = 1;
    transitionRemaining_ = 0;
    hasPending_ = false;
    reset();
}

void Processor::update(const DSPSettings& settings) {
    model_ = selectedModel(settings);
    if (transitionRemaining_ > 0) {
        pending_ = settings;
        hasPending_ = true;
        return;
    }
    if (!initialized_) {
        banks_[active_].update(settings, true);
        initialized_ = true;
    } else if (banks_[active_].model == model_) {
        banks_[active_].update(settings, false);
    } else {
        target_ = 1u - active_;
        banks_[target_].update(settings, true);
        transitionRemaining_ = transitionFrames;
    }
}

void Processor::process(float** channels, uint32_t frames) {
    if (channels == nullptr || channels[0] == nullptr || frames == 0) return;
    float* left = channels[0];
    float* right = channelCount_ > 1 && channels[1] != nullptr ? channels[1] : nullptr;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const float leftIn = std::isfinite(left[frame]) ? left[frame] : 0;
        const float rightIn = right != nullptr && std::isfinite(right[frame]) ? right[frame] : leftIn;
        float leftOut, rightOut;
        banks_[active_].process(leftIn, rightIn, leftOut, rightOut);
        if (transitionRemaining_ > 0) {
            float targetLeft, targetRight;
            banks_[target_].process(leftIn, rightIn, targetLeft, targetRight);
            const float mix = static_cast<float>(transitionFrames - transitionRemaining_ + 1u)
                / static_cast<float>(transitionFrames);
            leftOut += (targetLeft - leftOut) * mix;
            rightOut += (targetRight - rightOut) * mix;
            if (--transitionRemaining_ == 0) {
                active_ = target_;
                if (hasPending_) {
                    const DSPSettings next = pending_;
                    hasPending_ = false;
                    update(next);
                }
            }
        }
        left[frame] = leftOut;
        if (right != nullptr) right[frame] = rightOut;
    }
}

void Processor::reset() {
    if (transitionRemaining_ > 0) active_ = target_;
    transitionRemaining_ = 0;
    if (hasPending_) {
        banks_[active_].update(pending_, true);
        model_ = selectedModel(pending_);
        hasPending_ = false;
    }
    banks_[0].reset();
    banks_[1].reset();
}

} // namespace lowend
