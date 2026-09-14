// RecoveryPolicy.h — decides how the engine reacts to a device failure.
//
// This is the half of device recovery that can be tested without hardware: given
// a failure classification and the attempts already made, it says whether to
// reopen the endpoint or stop. The engine's threads call into it; the offline
// checks assert on it directly.
//
// Keeping the decision here rather than inline in the audio threads also keeps
// the threads themselves free of policy: they only ask, act, and report.

#pragma once

#include "AudioEngine/Devices.h"

#include <cstdint>
#include <string>

namespace lowend::win {

// Consecutive reopen attempts allowed for one lost device before the engine
// gives up. A device that is unplugged stays gone; retrying forever would spin
// the audio thread against a dead endpoint, so the budget is bounded. At the
// backoff used here this spans about 4.9 seconds of trying (100 + 250 + 400 +
// 550 + 700 + 850 + 1000 + 1000 ms), which covers a brief glitch or a device
// that is re-enumerating. `--self-test` computes this sum and asserts it stays
// in the documented band, so the figure here cannot drift from the code.
inline constexpr uint32_t maxDeviceReopenAttempts = 8;

// Delay before reopen attempt N (1-based), in milliseconds. Grows linearly so a
// device that needs a moment to re-enumerate is not hammered, while the first
// retry is fast enough to be invisible when a transient glitch caused the loss.
inline constexpr uint32_t reopenDelayMs(uint32_t attempt) {
    constexpr uint32_t baseMs = 100;
    constexpr uint32_t stepMs = 150;
    constexpr uint32_t capMs = 1000;
    if (attempt == 0) return 0;
    const uint32_t delay = baseMs + (attempt - 1) * stepMs;
    return delay > capMs ? capMs : delay;
}

enum class RecoveryAction {
    // Nothing to do; the caller should keep running.
    none,
    // Close and reopen the endpoint, then continue.
    reopen,
    // Stop the stream. The failure cannot be retried.
    giveUp,
};

// Whether two endpoint ids name the same endpoint.
//
// Capture and render must never be the same endpoint: WASAPI loopback copies the
// output stream into the capture buffer *in addition to* sending it to the
// render pin, so playing the processed result back into the endpoint being
// captured feeds the engine's own output into its own capture. Nothing in WASAPI
// breaks that loop, so it grows without bound instead of settling.
//
// The engine checks this when it starts. It also has to check it after every
// reopen, because an empty requested id means "the default endpoint" and that is
// re-resolved on each open: a default-device change while a stream is recovering
// can resolve both sides to the same endpoint, which the start-time check could
// not have seen.
//
// The comparison is over a hash rather than the strings because the two sides are
// owned by different audio threads. Each thread publishes the hash of its own
// endpoint into an atomic right after it opens or closes, so the check never
// reads a string another thread may be rewriting. A hash of 0 means "no endpoint
// claimed", so a side that is closed or reporting no id can never be mistaken for
// a collision. A 64-bit FNV-1a over a GUID string makes a false positive
// vanishingly unlikely, and the safe direction if one ever happened is stopping
// the stream, not running a feedback loop.
inline uint64_t endpointHash(const std::string& id) {
    if (id.empty()) {
        return 0;
    }
    constexpr uint64_t offsetBasis = 14695981039346656037ull;
    constexpr uint64_t prime = 1099511628211ull;
    uint64_t hash = offsetBasis;
    for (unsigned char byte : id) {
        hash ^= static_cast<uint64_t>(byte);
        hash *= prime;
    }
    return hash;
}

constexpr bool endpointsCollide(uint64_t captureHash, uint64_t renderHash) {
    return captureHash != 0 && captureHash == renderHash;
}

// What one pass of an audio loop should do. The engine's capture and render
// threads are built around this: decide first, then act, so the decision can be
// exercised without a device.
enum class LoopStep {
    // The endpoint is open; do the normal per-block work.
    run,
    // The endpoint is closed and the budget allows another attempt. Wait the
    // backoff, then open it.
    attemptOpen,
    // Stop the stream.
    stop,
};

// One pass of the loop's decision, given the endpoint's current state and the
// outcome of the last operation on it.
//
// `lost` is the failure that just ended an operation on an open endpoint, or
// DeviceError::none when the endpoint is healthy or was already closed.
//
// The order of these cases is the whole point, and it is what the engine used to
// get wrong in two ways:
//   * A closed endpoint is reopened before anything else. Calling into a closed
//     endpoint is a caller bug, not a device state, so a loop that fell through
//     to it would end the stream on the first failed retry instead of using the
//     budget.
//   * A failure is consumed before the state is acted on, so a reopen that fails
//     while the device is still absent comes back here as `attemptOpen` again
//     rather than being reported as a healthy endpoint.
constexpr LoopStep nextLoopStep(bool open, DeviceError lost, uint32_t attempted) {
    // A failure that cannot be retried stops the stream whether or not the
    // endpoint happens to be open: a fatal reopen failure leaves it closed, and
    // treating "closed" as "retry" would spend the whole budget on a request
    // that repeats identically.
    if (lost == DeviceError::fatal) {
        return LoopStep::stop;
    }
    if (!open) {
        // The endpoint is not open and the last outcome was either nothing or a
        // lost device. Retry while the budget allows; stop when it is spent.
        return attempted >= maxDeviceReopenAttempts ? LoopStep::stop : LoopStep::attemptOpen;
    }
    if (lost == DeviceError::none) {
        return LoopStep::run;
    }
    // A lost device on an open endpoint: reopen it while the budget allows.
    return attempted >= maxDeviceReopenAttempts ? LoopStep::stop : LoopStep::attemptOpen;
}

class RecoveryPolicy {
public:
    // Resets the attempt budget. Called on a successful start and after a
    // successful reopen, so a later failure gets a fresh budget instead of
    // inheriting an old one.
    void reset() { attempts_ = 0; }

    // Decides what to do about `failure` with `attempted` reopens already spent
    // on this failure sequence.
    //
    // `attempted` is passed in rather than tracked here so the caller's counter
    // and the reported statistics cannot drift from the decision.
    static RecoveryAction decide(DeviceError failure, uint32_t attempted) {
        switch (failure) {
            case DeviceError::none:
                // A false return with no classified failure is an orderly stop
                // request, not a device problem.
                return RecoveryAction::none;
            case DeviceError::fatal:
                // The request itself is wrong; reopening would fail the same way.
                return RecoveryAction::giveUp;
            case DeviceError::deviceLost:
                return attempted >= maxDeviceReopenAttempts ? RecoveryAction::giveUp
                                                            : RecoveryAction::reopen;
        }
        // An unknown classification is treated as unrecoverable, matching the
        // device layer's rule of not retrying what it cannot identify.
        return RecoveryAction::giveUp;
    }

    // Convenience for callers that do track the budget here.
    RecoveryAction decide(DeviceError failure) const { return decide(failure, attempts_); }
    uint32_t attempts() const { return attempts_; }
    void noteAttempt() { ++attempts_; }

private:
    uint32_t attempts_ = 0;
};

} // namespace lowend::win
