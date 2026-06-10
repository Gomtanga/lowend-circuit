#include "../include/Core/Processor.h"

#include <cmath>

namespace lowend {

void Processor::prepare(double sampleRate, uint32_t maxChannels) {
    sampleRate_ = std::isfinite(sampleRate) && sampleRate >= 8000.0
        ? sampleRate
        : 48000.0;
    channelCount_ = maxChannels < 1u
        ? 1u
        : maxChannels > maxSupportedChannels ? maxSupportedChannels : maxChannels;
    reset();
}

void Processor::update(const DSPSettings& settings) {
    model_ = settings.dspModel == static_cast<uint32_t>(DSPModel::circuit)
        ? DSPModel::circuit
        : settings.dspModel == static_cast<uint32_t>(DSPModel::highExciter)
            ? DSPModel::highExciter
            : DSPModel::clean;
    circuit_.update(settings);
    exciter_.update(settings);
}

void Processor::process(float** channels, uint32_t frames) {
    if (channels == nullptr || channels[0] == nullptr || frames == 0) {
        return;
    }

    float* left = channels[0];
    float* right = channelCount_ > 1 && channels[1] != nullptr ? channels[1] : nullptr;

    for (uint32_t frame = 0; frame < frames; ++frame) {
        float leftIn = std::isfinite(left[frame]) ? left[frame] : 0.0f;
        float rightIn = right != nullptr && std::isfinite(right[frame]) ? right[frame] : leftIn;
        float leftOut = leftIn;
        float rightOut = rightIn;

        if (model_ == DSPModel::circuit) {
            circuit_.process(leftIn, rightIn, leftOut, rightOut);
        } else if (model_ == DSPModel::highExciter) {
            exciter_.process(leftIn, rightIn, leftOut, rightOut);
        }

        left[frame] = leftOut;
        if (right != nullptr) {
            right[frame] = rightOut;
        }
    }
}

void Processor::reset() {
    circuit_.reset();
    exciter_.reset();
}

} // namespace lowend
