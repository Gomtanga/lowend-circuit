// test_spatial_processor.cpp — checks for the portable spatial stage.
//
// Expected values come from an independent reference model built from the
// documented contract, not from the implementation:
//   wet   = sum of the path taps that carry the impulse
//   out   = dry * (1 - amount) + wet * 0.82 * amount
//   final = tanh(out * 1.02) / 1.02
// An impulse written at frame 0 is read back at exactly the frame equal to a
// path's delay, so every response sample has a closed-form expected value. A
// wrong delay, a swapped channel, a missing crossfeed or a changed blend moves
// a specific sample and fails a specific check.
//
// The stage is shared with the macOS app, so these checks guard both platforms.

#include <Core/Core.h>
#include <Core/SpatialProcessor.h>

#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

void checkClose(float actual, float expected, float tolerance, const char* message) {
    if (!(std::fabs(actual - expected) <= tolerance)) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s (actual %.9g, expected %.9g)\n",
                     message, static_cast<double>(actual), static_cast<double>(expected));
    }
}

// Documented constants of the stereo spatial stage.
constexpr float wetScale = 0.82f;
constexpr float ceilingDrive = 1.02f;

// Expected output for one impulse delivered to both input channels at frame 0,
// for a fully activated plan (amount above the audibility threshold).
float referenceSample(const LCSpatialSettings& settings, uint32_t frame, bool leftChannel) {
    const LCSpatialPathSettings direct = leftChannel ? settings.ll : settings.rr;
    const LCSpatialPathSettings cross = leftChannel ? settings.rl : settings.lr;

    float out = 0.0f;
    // The dry impulse survives in proportion to how much of it the wet mix
    // does not replace.
    if (frame == 0) {
        out += (1.0f - settings.amount);
    }
    if (frame == direct.delaySamples) {
        out += wetScale * settings.amount * direct.gain;
    }
    if (frame == cross.delaySamples) {
        out += wetScale * settings.amount * cross.gain;
    }
    return std::tanh(out * ceilingDrive) / ceilingDrive;
}

LCSpatialPathSettings path(uint32_t delay, float gain) {
    return LCSpatialPathSettings { delay, gain };
}

// Full activation: the dry signal is entirely replaced, so every response
// sample is attributable to a named path. Four distinct delays catch a swap of
// any two paths.
LCSpatialSettings impulsePlan() {
    LCSpatialSettings settings {};
    settings.enabled = 1;
    settings.amount = 1.0f;
    settings.ll = path(2, 1.0f);
    settings.rr = path(3, 0.5f);
    settings.lr = path(5, 0.3f);
    settings.rl = path(4, 0.25f);
    return settings;
}

// A transparent plan: bypass, so the stage must pass input through untouched.
LCSpatialSettings bypassPlan() {
    LCSpatialSettings settings {};
    settings.enabled = 0;
    settings.amount = 0.0f;
    return settings;
}

void runImpulse(lowend::SpatialProcessor& spatial, const LCSpatialSettings& plan,
                float* left, float* right, uint32_t frames) {
    for (uint32_t frame = 0; frame < frames; ++frame) {
        float l = frame == 0 ? 1.0f : 0.0f;
        float r = frame == 0 ? 1.0f : 0.0f;
        spatial.process(l, r);
        left[frame] = l;
        right[frame] = r;
    }
    (void)plan;
}

// Empties the delay lines by running silence for a full capacity. An impulse
// response is only meaningful against an empty history: without this, a tap
// would read audio from before the measurement instead of the impulse. The
// active plan is left untouched, so a plan that had not finished fading in
// still shows up as the wrong routing afterwards.
void flushHistory(lowend::SpatialProcessor& spatial) {
    for (uint32_t frame = 0; frame < lowend::SpatialProcessor::delayCapacity + 1; ++frame) {
        float l = 0.0f;
        float r = 0.0f;
        spatial.process(l, r);
    }
}

// ─── Tests ───────────────────────────────────────────────────────────

void testImpulseResponseMatchesReference() {
    constexpr uint32_t frames = 16;
    const LCSpatialSettings plan = impulsePlan();

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(plan);

    float left[frames] {};
    float right[frames] {};
    runImpulse(spatial, plan, left, right, frames);

    for (uint32_t frame = 0; frame < frames; ++frame) {
        checkClose(left[frame], referenceSample(plan, frame, true), 1.0e-5f,
                   "left impulse response matches the reference model");
        checkClose(right[frame], referenceSample(plan, frame, false), 1.0e-5f,
                   "right impulse response matches the reference model");
        if (failures > 0) return;
    }

    // The four paths must actually be distinguishable, otherwise the checks
    // above would pass on a stage that ignored the delays entirely.
    check(left[2] != 0.0f && right[3] != 0.0f && left[4] != 0.0f && right[5] != 0.0f,
          "each of the four paths produces its own tap");
}

void testFirstPlanAppliesWithoutAFade() {
    // A plan supplied before any audio must be live immediately: starting from
    // silence would swallow the first 256 frames of a session.
    constexpr uint32_t frames = 8;
    const LCSpatialSettings plan = impulsePlan();

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(plan);

    float left[frames] {};
    float right[frames] {};
    runImpulse(spatial, plan, left, right, frames);

    for (uint32_t frame = 0; frame < frames; ++frame) {
        checkClose(left[frame], referenceSample(plan, frame, true), 1.0e-5f,
                   "the first plan is live on the first frame");
        if (failures > 0) return;
    }
}

void testCrossfeedRouting() {
    const LCSpatialSettings plan = impulsePlan();

    // Each crossfeed path must carry the opposite channel at its own delay.
    // Driving only the left channel isolates lr and rl from ll and rr.
    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(plan);

    constexpr uint32_t frames = 8;
    float left[frames] {};
    float right[frames] {};
    for (uint32_t frame = 0; frame < frames; ++frame) {
        float l = frame == 0 ? 1.0f : 0.0f;
        float r = 0.0f;
        spatial.process(l, r);
        left[frame] = l;
        right[frame] = r;
    }

    // Left input reaches the left output directly at ll.delay (2) and the right
    // output through lr at delay 5. It must not appear at rl's delay in the
    // left output, which would mean the two crossfeeds were swapped.
    checkClose(left[4], 0.0f, 1.0e-6f, "a left-only input does not use the right crossfeed path");
    check(right[5] != 0.0f, "a left-only input reaches the right output through lr");
    check(left[2] != 0.0f, "a left-only input reaches the left output through ll");

    // Right-only input mirrors it.
    lowend::SpatialProcessor mirrored;
    mirrored.prepare(48000.0f);
    mirrored.update(plan);
    float rightOnlyLeft[frames] {};
    float rightOnlyRight[frames] {};
    for (uint32_t frame = 0; frame < frames; ++frame) {
        float l = 0.0f;
        float r = frame == 0 ? 1.0f : 0.0f;
        mirrored.process(l, r);
        rightOnlyLeft[frame] = l;
        rightOnlyRight[frame] = r;
    }
    checkClose(rightOnlyRight[5], 0.0f, 1.0e-6f, "a right-only input does not use the left crossfeed path");
    check(rightOnlyLeft[4] != 0.0f, "a right-only input reaches the left output through rl");
    check(rightOnlyRight[3] != 0.0f, "a right-only input reaches the right output through rr");
}

void testBypassIsBitExact() {
    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(bypassPlan());

    for (int frame = 0; frame < 1024; ++frame) {
        float l = 0.25f;
        float r = -0.75f;
        spatial.process(l, r);
        if (l != 0.25f || r != -0.75f) {
            check(false, "a disabled plan leaves samples untouched");
            return;
        }
    }
    check(true, "a disabled plan leaves samples untouched");

    // An amount at or below the audibility threshold is also bypass, because a
    // mix that quiet cannot be heard and should not cost a crossfade.
    LCSpatialSettings inaudible {};
    inaudible.enabled = 1;
    inaudible.amount = 0.0005f;
    inaudible.ll = path(2, 1.0f);
    inaudible.rr = path(2, 1.0f);
    spatial.update(inaudible);

    for (int frame = 0; frame < 1024; ++frame) {
        float l = 0.25f;
        float r = -0.75f;
        spatial.process(l, r);
        if (l != 0.25f || r != -0.75f) {
            check(false, "a sub-threshold amount stays bypassed");
            return;
        }
    }
    check(true, "a sub-threshold amount stays bypassed");

    // The delay lines still advanced while bypassed, so enabling the plan must
    // not replay a tail from before the bypass.
    spatial.update(impulsePlan());
    for (uint32_t frame = 0; frame < lowend::SpatialProcessor::transitionFrames; ++frame) {
        float l = 0.0f;
        float r = 0.0f;
        spatial.process(l, r);
    }
    float l = 0.0f;
    float r = 0.0f;
    spatial.process(l, r);
    checkClose(l, 0.0f, 1.0e-9f, "re-enabling does not replay audio captured while bypassed");
    checkClose(r, 0.0f, 1.0e-9f, "re-enabling does not replay audio captured while bypassed");
}

void testFullAmountRemovesTheDrySignal() {
    // With amount at 1 and every path silent, nothing may remain. This isolates
    // the dry/wet mix from the path levels.
    LCSpatialSettings settings {};
    settings.enabled = 1;
    settings.amount = 1.0f;
    settings.ll = path(2, 0.0f);
    settings.rr = path(2, 0.0f);
    settings.lr = path(2, 0.0f);
    settings.rl = path(2, 0.0f);

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(settings);

    for (int frame = 0; frame < 256; ++frame) {
        float l = 0.5f;
        float r = -0.5f;
        spatial.process(l, r);
        checkClose(l, 0.0f, 1.0e-6f, "a full wet mix with silent paths removes the dry signal");
        checkClose(r, 0.0f, 1.0e-6f, "a full wet mix with silent paths removes the dry signal");
        if (failures > 0) return;
    }
}

void testTransitionSettlesOnTheNewPlan() {
    const LCSpatialSettings start = bypassPlan();
    const LCSpatialSettings target = impulsePlan();

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(start);

    for (uint32_t frame = 0; frame < 64; ++frame) {
        float l = 0.1f;
        float r = 0.1f;
        spatial.process(l, r);
        checkClose(l, 0.1f, 1.0e-6f, "the bypass start plan is transparent");
        if (failures > 0) return;
    }

    spatial.update(target);

    // Through the fade the output must stay finite and must move away from the
    // bypass response.
    bool observedChange = false;
    float previous = 0.1f;
    for (uint32_t frame = 0; frame < lowend::SpatialProcessor::transitionFrames; ++frame) {
        float l = 0.3f;
        float r = -0.3f;
        spatial.process(l, r);
        if (!std::isfinite(l) || !std::isfinite(r)) {
            check(false, "transition output stays finite");
            return;
        }
        if (std::fabs(l - previous) > 1.0e-6f) observedChange = true;
        previous = l;
    }
    check(observedChange, "the fade moves the signal toward the new plan");

    // Once the fade has elapsed the response must match the reference exactly.
    // The history is emptied first so the taps read the impulse rather than the
    // tone that was running during the fade.
    flushHistory(spatial);
    constexpr uint32_t frames = 16;
    float left[frames] {};
    float right[frames] {};
    runImpulse(spatial, target, left, right, frames);
    for (uint32_t frame = 0; frame < frames; ++frame) {
        checkClose(left[frame], referenceSample(target, frame, true), 1.0e-5f,
                   "the new plan is fully applied after one fade length");
        checkClose(right[frame], referenceSample(target, frame, false), 1.0e-5f,
                   "the new plan is fully applied after one fade length");
        if (failures > 0) return;
    }
}

void testBurstOfRetargetsKeepsOnlyTheLast() {
    // Contract: a request arriving during a fade does not retarget the running
    // fade; it replaces the single pending plan. The observable consequences
    // are (a) the running fade still completes against the plan it started
    // with, and (b) when several requests arrive during one fade, only the last
    // of them ever becomes active — an intermediate one is discarded, not
    // queued behind the others.
    //
    // Frame positions make this visible: an impulse injected mid-fade comes
    // back at the delay of whichever plan is actually routing it, so the delays
    // of four distinct plans separate the possible behaviours.

    LCSpatialSettings base {};
    base.enabled = 1;
    base.amount = 1.0f;
    base.ll = path(2, 1.0f);
    base.rr = path(2, 1.0f);
    base.lr = path(2, 1.0f);
    base.rl = path(2, 1.0f);

    const auto withDelay = [&base](uint32_t delay) {
        LCSpatialSettings plan = base;
        plan.ll = path(delay, 1.0f);
        plan.rr = path(delay, 1.0f);
        plan.lr = path(delay, 1.0f);
        plan.rl = path(delay, 1.0f);
        return plan;
    };
    const LCSpatialSettings running = withDelay(40);   // owns the in-progress fade
    const LCSpatialSettings replaced = withDelay(11);  // superseded while pending
    const LCSpatialSettings lastRequest = withDelay(5); // must end up active

    // Frames, counted from the moment the fade to `running` starts.
    constexpr uint32_t fadeFrames = lowend::SpatialProcessor::transitionFrames;
    constexpr uint32_t pendingAt = 10;         // `replaced` becomes pending
    constexpr uint32_t replacePendingAt = 20;  // `lastRequest` supersedes it
    constexpr uint32_t impulseAt = 30;         // still inside the first fade
    constexpr uint32_t totalFrames = fadeFrames * 3;

    std::vector<float> response(totalFrames, 0.0f);

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(base);
    flushHistory(spatial);

    // Start the fade to `running`, then deliver two more requests while it is
    // in flight.
    spatial.update(running);

    for (uint32_t frame = 0; frame < totalFrames; ++frame) {
        if (frame == pendingAt) {
            spatial.update(replaced);
        }
        if (frame == replacePendingAt) {
            spatial.update(lastRequest);
        }
        float l = frame == impulseAt ? 1.0f : 0.0f;
        float r = frame == impulseAt ? 1.0f : 0.0f;
        spatial.process(l, r);
        response[frame] = l;
        if (!std::isfinite(l)) {
            check(false, "a retarget burst stays finite");
            return;
        }
    }

    // During the first fade the base plan is still the current one and the
    // `running` plan is its target, so both of their taps must appear.
    check(response[impulseAt + 2] != 0.0f,
          "the plan that owns the fade is still routing during the fade");
    check(response[impulseAt + 40] != 0.0f,
          "the fade target is being blended in");

    // Neither the superseded request nor the last request may be routing yet:
    // both are pending, and only the final one survives.
    checkClose(response[impulseAt + 11], 0.0f, 1.0e-9f,
               "a superseded pending request never becomes active");
    checkClose(response[impulseAt + 5], 0.0f, 1.0e-9f,
               "a request during a fade does not retarget the running fade");

    // Once both fades have elapsed the last request must own the stream. If the
    // superseded request had been queued rather than replaced, its delay would
    // still be the settled routing here.
    std::vector<float> settled(totalFrames, 0.0f);
    flushHistory(spatial);
    for (uint32_t frame = 0; frame < totalFrames; ++frame) {
        float l = frame == 0 ? 1.0f : 0.0f;
        float r = frame == 0 ? 1.0f : 0.0f;
        spatial.process(l, r);
        settled[frame] = l;
        if (!std::isfinite(l)) {
            check(false, "a retarget burst settles finite");
            return;
        }
    }

    check(settled[5] != 0.0f, "the last request becomes the active plan");
    checkClose(settled[11], 0.0f, 1.0e-9f, "the superseded request is discarded");
    checkClose(settled[40], 0.0f, 1.0e-9f, "the fade target does not remain active");
    checkClose(settled[2], 0.0f, 1.0e-9f, "the base plan does not remain active");
    checkClose(settled[5], referenceSample(lastRequest, 5, true), 1.0e-5f,
               "the settled routing matches the last request exactly");
}

void testResetCollapsesState() {
    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(impulsePlan());

    for (int frame = 0; frame < 256; ++frame) {
        float l = 0.5f;
        float r = 0.5f;
        spatial.process(l, r);
    }

    spatial.reset();

    // A discontinuity has no continuous signal to fade from, so the delay lines
    // must be empty: silence in has to give silence out immediately.
    for (int frame = 0; frame < 64; ++frame) {
        float l = 0.0f;
        float r = 0.0f;
        spatial.process(l, r);
        checkClose(l, 0.0f, 1.0e-9f, "reset clears the delay history");
        checkClose(r, 0.0f, 1.0e-9f, "reset clears the delay history");
        if (failures > 0) return;
    }

    // And the active plan must still be live afterwards.
    constexpr uint32_t frames = 8;
    float left[frames] {};
    float right[frames] {};
    runImpulse(spatial, impulsePlan(), left, right, frames);
    checkClose(left[2], referenceSample(impulsePlan(), 2, true), 1.0e-4f,
               "the plan survives a reset");
}

void testOutOfRangeDelayIsClamped() {
    // The geometry never requests more than the capacity, but a malformed or
    // future setting must not read outside the delay line's history. An
    // out-of-range delay must behave exactly like the largest valid delay.
    //
    // The probe uses a delay of exactly `capacity` rather than a huge value:
    // with `UINT32_MAX` the unclamped read index happens to wrap back onto the
    // same slot arithmetic the clamp produces, so it would pass either way. At
    // exactly `capacity` the unclamped index lands on the sample just written,
    // which is a different observable position.
    const uint32_t maxDelay = lowend::SpatialProcessor::delayCapacity - 1u;
    const uint32_t onePast = lowend::SpatialProcessor::delayCapacity;
    const uint32_t wellPast = lowend::SpatialProcessor::delayCapacity + 5u;

    const auto planWithDelay = [](uint32_t delay) {
        LCSpatialSettings plan {};
        plan.enabled = 1;
        plan.amount = 1.0f;
        plan.ll = path(delay, 1.0f);
        plan.rr = path(delay, 1.0f);
        plan.lr = path(delay, 1.0f);
        plan.rl = path(delay, 1.0f);
        return plan;
    };

    const uint32_t frames = lowend::SpatialProcessor::delayCapacity + 8;
    std::vector<float> referenceLeft(frames, 0.0f), referenceRight(frames, 0.0f);

    const LCSpatialSettings explicitMax = planWithDelay(maxDelay);
    lowend::SpatialProcessor reference;
    reference.prepare(48000.0f);
    reference.update(explicitMax);
    runImpulse(reference, explicitMax, referenceLeft.data(), referenceRight.data(), frames);

    // The reference itself must place its tap at the maximum valid delay,
    // otherwise comparing against it would prove nothing.
    check(referenceLeft[maxDelay] != 0.0f, "the maximum valid delay carries its tap");
    checkClose(referenceLeft[0], 0.0f, 1.0e-9f,
               "a full wet mix leaves no tap at the dry position");

    for (const uint32_t outOfRange : { onePast, wellPast }) {
        const LCSpatialSettings plan = planWithDelay(outOfRange);
        lowend::SpatialProcessor subject;
        subject.prepare(48000.0f);
        subject.update(plan);

        std::vector<float> left(frames, 0.0f), right(frames, 0.0f);
        runImpulse(subject, plan, left.data(), right.data(), frames);

        for (uint32_t frame = 0; frame < frames; ++frame) {
            checkClose(left[frame], referenceLeft[frame], 1.0e-9f,
                       "an out-of-range delay is clamped to the largest valid delay");
            checkClose(right[frame], referenceRight[frame], 1.0e-9f,
                       "an out-of-range delay is clamped to the largest valid delay");
            if (failures > 0) return;
        }
    }
}

void testInProgressFadeDoesNotJumpToProcessed() {
    // The activation blend is what makes a fade a fade. During an in-progress
    // ramp the output must be a mix of the dry signal and the processed one, not
    // the processed signal outright — otherwise enabling spatial would switch
    // instantly and click.
    //
    // A bypass plan is already active, so switching to a plan whose paths are
    // silent isolates the blend: with amount ramping from 0 towards 1, the dry
    // signal must still be most of the output on the first frames.
    LCSpatialSettings silentWet {};
    silentWet.enabled = 1;
    silentWet.amount = 1.0f;
    silentWet.ll = path(4000, 0.0f);
    silentWet.rr = path(4000, 0.0f);
    silentWet.lr = path(4000, 0.0f);
    silentWet.rl = path(4000, 0.0f);

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(bypassPlan());

    // One frame in bypass, to establish the dry path.
    {
        float l = 0.5f;
        float r = 0.5f;
        spatial.process(l, r);
        checkClose(l, 0.5f, 1.0e-9f, "the bypass plan passes the input through");
    }

    spatial.update(silentWet);

    // On the first frame of the ramp the wet mix has advanced by 1/256, so the
    // output must be almost entirely dry. Jumping to the processed value would
    // land near tanh(0.51)/1.02 instead.
    float l = 0.5f;
    float r = 0.5f;
    spatial.process(l, r);

    const float fullyProcessed = std::tanh(0.5f * 1.02f) / 1.02f;
    check(std::fabs(l - 0.5f) < 5.0e-3f,
          "the first frame of a fade stays close to the dry signal");
    check(std::fabs(l - fullyProcessed) > 1.0e-3f,
          "a fade does not jump straight to the fully processed signal");
    check(std::fabs(r - fullyProcessed) > 1.0e-3f,
          "a fade does not jump straight to the fully processed signal");

    // Once the fade has elapsed the processed signal is the correct output:
    // with amount 1 and silent paths, everything is removed.
    for (uint32_t frame = 0; frame < lowend::SpatialProcessor::transitionFrames; ++frame) {
        float dl = 0.5f;
        float dr = 0.5f;
        spatial.process(dl, dr);
        if (!std::isfinite(dl) || !std::isfinite(dr)) {
            check(false, "the fade stays finite");
            return;
        }
    }
    float endLeft = 0.5f;
    float endRight = 0.5f;
    spatial.process(endLeft, endRight);
    checkClose(endLeft, 0.0f, 1.0e-5f, "a completed fade reaches the target mix");
    checkClose(endRight, 0.0f, 1.0e-5f, "a completed fade reaches the target mix");
}

void testMixRampAdvancesGradually() {
    // The wet mix and the activation both ramp linearly over
    // transitionFrames. A mix that jumped straight to its target would instead
    // switch abruptly, which is the click the fade exists to prevent.
    //
    // The first frame of a fade is the sharpest test of this, and the wet path
    // is arranged to contribute nothing yet: the active plan's taps are delayed,
    // so at that frame they still read the pre-impulse zeros. That leaves the
    // dry/wet mix as the only thing moving, so the expected output has a closed
    // form:
    //     a    = 1 / transitionFrames          (ramped from 0)
    //     wet  = 0
    //     out  = dry * (1 - a)
    //     result = dry + activation * (ceiling(out) - dry),
    //     activation = 1 / transitionFrames
    LCSpatialSettings active {};
    active.enabled = 1;
    active.amount = 1.0f;
    active.ll = path(2, 1.0f);
    active.rr = path(2, 1.0f);
    active.lr = path(2, 1.0f);
    active.rl = path(2, 1.0f);

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(bypassPlan());

    // One frame of bypass establishes the dry path and the previous mix (zero).
    {
        float l = 0.0f;
        float r = 0.0f;
        spatial.process(l, r);
    }

    spatial.update(active);

    // The impulse arrives on the first frame of the fade, so the dry signal is
    // 1.0 while the delayed taps still read zero.
    float left = 1.0f;
    float right = 1.0f;
    spatial.process(left, right);

    const float ramp = 1.0f / static_cast<float>(lowend::SpatialProcessor::transitionFrames);
    const float mixedWet = 0.0f;
    const float internal = 1.0f * (1.0f - ramp) + mixedWet * wetScale * ramp;
    const float processed = std::tanh(internal * ceilingDrive) / ceilingDrive;
    const float expected = 1.0f + ramp * (processed - 1.0f);

    checkClose(left, expected, 1.0e-4f, "the wet mix advances by one ramp step per frame");
    checkClose(right, expected, 1.0e-4f, "the wet mix advances by one ramp step per frame");

    // A jumped mix would produce a visibly different first frame; asserting the
    // two are distinguishable keeps this check from passing on an abrupt switch.
    const float jumpedInternal = 1.0f * (1.0f - 1.0f);
    const float jumpedProcessed = std::tanh(jumpedInternal * ceilingDrive) / ceilingDrive;
    const float jumped = 1.0f + ramp * (jumpedProcessed - 1.0f);
    check(std::fabs(expected - jumped) > 1.0e-3f,
          "an abrupt mix change is distinguishable from the ramped one");
}

void testNonFiniteSettingsNeverReachTheOutput() {
    LCSpatialSettings settings {};
    settings.enabled = 1;
    settings.amount = std::nanf("");
    settings.ll = path(2, std::nanf(""));
    settings.rr = path(2, std::numeric_limits<float>::infinity());
    settings.lr = path(2, 1.0f);
    settings.rl = path(2, 1.0f);

    lowend::SpatialProcessor spatial;
    spatial.prepare(48000.0f);
    spatial.update(settings);

    // A non-finite amount falls back to 0, which is bypass, so the output must
    // be the input rather than NaN.
    for (int frame = 0; frame < 512; ++frame) {
        float l = 0.25f;
        float r = 0.25f;
        spatial.process(l, r);
        if (!std::isfinite(l) || !std::isfinite(r)) {
            check(false, "non-finite settings never reach the output");
            return;
        }
        if (l != 0.25f || r != 0.25f) {
            check(false, "a non-finite amount falls back to bypass");
            return;
        }
    }
    check(true, "non-finite settings never reach the output");

    // A finite amount with a non-finite gain must silence that path rather than
    // poison the accumulator.
    LCSpatialSettings badGain {};
    badGain.enabled = 1;
    badGain.amount = 1.0f;
    badGain.ll = path(2, std::numeric_limits<float>::infinity());
    badGain.rr = path(2, std::numeric_limits<float>::quiet_NaN());
    badGain.lr = path(2, 0.0f);
    badGain.rl = path(2, 0.0f);
    spatial.reset();
    spatial.update(badGain);

    for (int frame = 0; frame < 512; ++frame) {
        float l = 0.25f;
        float r = 0.25f;
        spatial.process(l, r);
        if (!std::isfinite(l) || !std::isfinite(r)) {
            check(false, "a non-finite path gain never reaches the output");
            return;
        }
    }
    check(true, "a non-finite path gain never reaches the output");
}

} // namespace

int main() {
    testImpulseResponseMatchesReference();
    testFirstPlanAppliesWithoutAFade();
    testCrossfeedRouting();
    testBypassIsBitExact();
    testFullAmountRemovesTheDrySignal();
    testTransitionSettlesOnTheNewPlan();
    testInProgressFadeDoesNotJumpToProcessed();
    testMixRampAdvancesGradually();
    testBurstOfRetargetsKeepsOnlyTheLast();
    testResetCollapsesState();
    testOutOfRangeDelayIsClamped();
    testNonFiniteSettingsNeverReachTheOutput();

    if (failures == 0) {
        std::printf("test_spatial_processor: all checks passed\n");
    }
    return failures == 0 ? 0 : 1;
}
