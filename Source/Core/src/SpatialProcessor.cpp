// SpatialProcessor.cpp — stereo spatial stage.
//
// Port of the macOS Spatializer
// (SystemAudioProcessor/Sources/SystemAudioProcessor/SpatialDSP.swift). The
// order of writes, taps, crossfade bookkeeping and the final activation blend is
// kept identical so both platforms produce the same samples for the same
// settings; only the storage differs (a raw array here, UnsafeMutablePointer
// there, and a UInt32 delay index instead of a signed Int).
//
// The delay/gain geometry itself is not here: SpatialGeometry.cpp owns it and a
// control thread delivers the result as LCSpatialSettings.
//
// Realtime contract: process() performs no allocation, takes no lock, logs
// nothing, and computes no coefficients.

#include "../include/Core/SpatialProcessor.h"

#include <algorithm>
#include <cmath>

namespace lowend {
namespace {

// A delay is an index into the line, so the upper bound is what matters. The
// macOS reference also guards the lower end, but its argument is a signed Int
// while this one is unsigned and cannot go negative.
uint32_t clampDelay(uint32_t delaySamples) {
    return std::min(delaySamples, DelayLine::capacity - 1u);
}

float sanitizedGain(float gain) {
    // A non-finite gain would poison the accumulator for the rest of the
    // stream; silence is the safe stand-in.
    return std::isfinite(gain) ? gain : 0.0f;
}

} // namespace

// ─── DelayLine ───────────────────────────────────────────────────────

DelayLine::DelayLine()
    : buffer_(new float[capacity]) {
    reset();
}

DelayLine::~DelayLine() {
    delete[] buffer_;
}

void DelayLine::write(float input) {
    buffer_[writeIndex_] = input;
}

float DelayLine::read(uint32_t delaySamples) const {
    const uint32_t delay = clampDelay(delaySamples);
    // The write index is the slot just written, so a delay of 0 reads it back
    // and a delay of d steps back through the history. Both operands are below
    // capacity, so the unsigned sum stays well below 2^32 and the modulo is a
    // plain wrap rather than a guard against overflow.
    return buffer_[(writeIndex_ - delay + capacity) % capacity];
}

void DelayLine::advance() {
    writeIndex_ = (writeIndex_ + 1u) % capacity;
}

float DelayLine::process(float input, uint32_t delaySamples) {
    write(input);
    const float output = read(delaySamples);
    advance();
    return output;
}

void DelayLine::reset() {
    std::fill(buffer_, buffer_ + capacity, 0.0f);
    writeIndex_ = 0;
}

// ─── SpatialProcessor ────────────────────────────────────────────────

SpatialProcessor::SpatialProcessor() = default;
SpatialProcessor::~SpatialProcessor() = default;

void SpatialProcessor::prepare(float sampleRate) {
    // Nothing to store: every delay in a plan is already expressed in samples
    // by the geometry, so the stage never converts a time to a sample index and
    // has no use for the rate. The entry point stays so a caller has one place
    // to initialize the stage, and this definition exists so that call is well
    // defined.
    (void)sampleRate;
}

void SpatialProcessor::update(const LCSpatialSettings& settings) {
    const Paths paths = pathsFromSettings(settings);
    const float nextAmount = std::isfinite(settings.amount)
        ? std::min(std::max(settings.amount, 0.0f), 1.0f)
        : 0.0f;
    // Below the 0.001 threshold the wet signal cannot be heard, so the stage
    // stays bypassed rather than paying for an inaudible mix.
    const float nextActivation = (settings.enabled != 0 && nextAmount > 0.001f) ? 1.0f : 0.0f;

    targetAmount_ = nextAmount;
    targetActivation_ = nextActivation;

    if (!initialized_) {
        // First plan: adopt it outright. Starting a fade from an empty stage
        // would ramp from silence, which is not what the caller asked for.
        current_ = paths;
        target_ = paths;
        amount_ = nextAmount;
        activation_ = nextActivation;
        initialized_ = true;
        return;
    }

    // Finish the current two-tap fade before starting the latest target, and
    // keep only one pending snapshot: a burst of retargets must not queue up an
    // arbitrary amount of future work on the audio thread.
    if (transitionRemaining_ > 0) {
        pending_ = paths;
        hasPending_ = true;
    } else {
        target_ = paths;
        transitionRemaining_ = transitionFrames;
    }
    // The amount/activation ramp always restarts, so a level change is audible
    // immediately even while a delay crossfade is still running.
    mixRemaining_ = transitionFrames;
}

void SpatialProcessor::reset() {
    leftHistory_.reset();
    rightHistory_.reset();
    if (hasPending_) {
        // A pending plan was already accepted from the control thread, so it is
        // the intent for the stream that continues; dropping it here would
        // silently lose the last edit.
        target_ = pending_;
    }
    current_ = target_;
    hasPending_ = false;
    transitionRemaining_ = 0;
    // Snap the ramps to their targets: after a discontinuity there is no
    // continuous signal to fade from.
    amount_ = targetAmount_;
    activation_ = targetActivation_;
    mixRemaining_ = 0;
}

void SpatialProcessor::process(float& left, float& right) {
    // Bypass advances history too. Re-enabling reads this line, and a line that
    // stopped advancing would replay a tail from whenever the stage was last
    // active instead of the audio that just went past.
    leftHistory_.write(left);
    rightHistory_.write(right);

    if (mixRemaining_ > 0) {
        // Linear ramp over the remaining frames: dividing by what is left means
        // the final step lands exactly on the target, so the snap below is a
        // formality rather than a discontinuity.
        amount_ += (targetAmount_ - amount_) / static_cast<float>(mixRemaining_);
        activation_ += (targetActivation_ - activation_) / static_cast<float>(mixRemaining_);
        mixRemaining_ -= 1u;
        if (mixRemaining_ == 0) {
            amount_ = targetAmount_;
            activation_ = targetActivation_;
        }
    }

    const float progress = transitionRemaining_ > 0
        ? static_cast<float>(transitionFrames - transitionRemaining_ + 1u)
            / static_cast<float>(transitionFrames)
        : 1.0f;

    // read() is const and never moves the write index, so the old and new taps
    // for one path cannot influence each other regardless of evaluation order.
    // They also cannot be collapsed into one read: current_ and target_ address
    // different delays except when a plan retargets a path to the delay it
    // already had, and branching on that equality would cost more than the one
    // extra indexed load it saves.
    const auto tap = [progress](const DelayLine& history, const Path& old, const Path& newPath) {
        const float oldDelay = history.read(old.delay);
        const float newDelay = history.read(newPath.delay);
        const float a = oldDelay * old.gain;
        const float b = newDelay * newPath.gain;
        return a + (b - a) * progress;
    };

    const float wetLeft = tap(leftHistory_, current_.ll, target_.ll)
        + tap(rightHistory_, current_.rl, target_.rl);
    const float wetRight = tap(rightHistory_, current_.rr, target_.rr)
        + tap(leftHistory_, current_.lr, target_.lr);

    if (transitionRemaining_ > 0) {
        transitionRemaining_ -= 1u;
        if (transitionRemaining_ == 0) {
            current_ = target_;
            if (hasPending_) {
                // Promote the queued plan into the next fade instead of
                // restarting one that has already finished.
                target_ = pending_;
                hasPending_ = false;
                transitionRemaining_ = transitionFrames;
            }
        }
    }

    // Matches the macOS `defer`: both lines advance once the frame's taps have
    // been read, including on the bypass path below.
    leftHistory_.advance();
    rightHistory_.advance();

    if (!(activation_ > 0.0f)) {
        // Bit-exact bypass. The caller sees the untouched input.
        return;
    }

    const float outLeft = left * (1.0f - amount_) + wetLeft * 0.82f * amount_;
    const float outRight = right * (1.0f - amount_) + wetRight * 0.82f * amount_;
    // tanh(x * 1.02) / 1.02 is the macOS soft ceiling: almost transparent below
    // unity, folding anything above it into +/-0.98. The 0.82 on the wet path is
    // what keeps that fold rare, since the crossfeed taps sum with the direct
    // signal before the ceiling sees them.
    const float processedLeft = std::tanh(outLeft * 1.02f) / 1.02f;
    const float processedRight = std::tanh(outRight * 1.02f) / 1.02f;
    left = left + activation_ * (processedLeft - left);
    right = right + activation_ * (processedRight - right);
}

SpatialProcessor::Paths SpatialProcessor::pathsFromSettings(const LCSpatialSettings& settings) const {
    Paths paths;
    // LCSpatialSettings already carries the four paths the stage consumes; the
    // only translation is clamping the delay into the line and rejecting a
    // non-finite gain.
    paths.ll = { clampDelay(settings.ll.delaySamples), sanitizedGain(settings.ll.gain) };
    paths.lr = { clampDelay(settings.lr.delaySamples), sanitizedGain(settings.lr.gain) };
    paths.rl = { clampDelay(settings.rl.delaySamples), sanitizedGain(settings.rl.gain) };
    paths.rr = { clampDelay(settings.rr.delaySamples), sanitizedGain(settings.rr.gain) };
    return paths;
}

} // namespace lowend
