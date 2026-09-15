// RouteDiagnosis.h — decides whether a capture → DSP → render route is usable.
//
// This is the part of routing that can be judged without opening a device: given
// the endpoint ids a caller selected and the endpoints the machine actually has,
// it says whether the route can run, and when it cannot, what is wrong and what
// to do about it.
//
// It exists because the interesting failures are not "the id was wrong". A
// virtual audio cable is one device with two endpoints — a playback side apps
// play into and a recording side that carries that signal — so capturing one
// side while rendering to the other forms a loop that WASAPI does not break,
// even though the two endpoint ids differ. The same class of mistake is asking
// for loopback on an input endpoint, or capturing a cable's playback side while
// believing it is its recording side.
//
// The CLI and the GUI both go through here, so a route that the CLI refuses is
// refused in the GUI with the same reason, and neither front end grows a routing
// model of its own.
//
// Everything here is pure: no COM, no device open, no allocation beyond the
// strings it returns. `--self-test` drives it with synthetic endpoints.

#pragma once

#include "AudioEngine/Devices.h"
#include "AudioEngine/RecoveryPolicy.h"

#include <cstdint>
#include <string>
#include <vector>

namespace lowend::win {

// EndpointIdentity (the endpoint's id, its device container, and the bus its
// device arrived on) is defined in Devices.h alongside DeviceInfo: it is what the
// device layer resolves, and these rules only read it.

// Whether an enumerator names a software bus.
//
// Root-enumerated devices have no hardware behind them: the driver creates the
// device object itself, so the endpoints exist only while that driver runs. That
// is the shape of every virtual audio device, and it is also the shape of a
// pass-through cable, whose recording side is generated from its playback side.
//
// Hardware buses (USB, HDAUDIO, PCI, BTHENUM) are never pass-throughs: a USB
// headset's microphone and its speakers share one device instance and one
// container id, but they carry two independent signals, which is why this
// predicate — and not container equality alone — gates the feedback check.
bool isVirtualEnumerator(const std::string& enumeratorName);

// Key identifying the loop a virtual pass-through device can form.
//
// Non-zero only when the endpoint is one side of an identifiable virtual device
// (a readable container id on a software bus). Two non-zero keys that are equal
// mean capture and render are the two sides of one such device, which is a
// feedback loop: everything the engine renders comes back as its own input.
//
// 0 means "not identifiable as such a side", so a closed side, an unreadable
// property, or a real hardware endpoint can never be mistaken for a collision —
// the check errs towards allowing a route rather than refusing a valid one, and
// the exact-endpoint check in RecoveryPolicy.h still catches the same-endpoint
// case on its own.
uint64_t virtualPassThroughKey(const EndpointIdentity& identity);

constexpr bool passThroughKeysCollide(uint64_t captureKey, uint64_t renderKey) {
    return captureKey != 0 && captureKey == renderKey;
}

// Two endpoints that both sit on a software bus but that Windows reports as
// different device instances.
//
// This is the shape a virtual cable would have if the driver exposed its two
// sides as separate devices, and it is the one case the feedback guard cannot
// decide: the pair might be one signal path (so capturing one side while
// rendering to the other is a loop) or two unrelated software devices. The guard
// does not refuse an unproven loop, so the honest thing is to say that it could
// not identify the pair instead of letting "different ids" read as "safe".
bool isUnidentifiedSoftwarePair(const DeviceInfo& capture, const DeviceInfo& render);

// The complete feedback rule, as the engine applies it: capture and render must
// be neither the same endpoint nor the two sides of one virtual pass-through
// device.
//
// It is one predicate rather than two conditions per call site because three
// call sites have to agree on it — the start, and each side's reopen — and
// because a check that only exists at start is the defect this rule already had
// once: an empty requested id means "the default endpoint" and is re-resolved on
// every open, so a default-device change during recovery can point both sides at
// one endpoint, or at two sides of one cable, which the start-time check could
// not have seen. `--self-test` asserts this predicate directly.
constexpr bool routeFormsFeedbackLoop(uint64_t captureEndpointHash,
                                      uint64_t renderEndpointHash,
                                      uint64_t capturePassThroughKey,
                                      uint64_t renderPassThroughKey) {
    return endpointsCollide(captureEndpointHash, renderEndpointHash) ||
           passThroughKeysCollide(capturePassThroughKey, renderPassThroughKey);
}

// What a caller selected, in the terms the engine opens endpoints with.
struct RouteSelection {
    // Empty means "the default endpoint of that flow".
    std::string captureId;
    std::string renderId;
    // DataFlow::render + loopback captures an output endpoint's own audio;
    // DataFlow::capture records a real input endpoint.
    DataFlow captureFlow = DataFlow::render;
    bool loopback = true;
};

// Why a route cannot run. Every value except `ok` is a refusal.
enum class RouteIssue {
    ok,
    // No endpoint with the requested id is present. Reinstalling an endpoint
    // gives it a new id, so this is the case a fallback would silently paper
    // over; it is reported instead.
    captureEndpointMissing,
    renderEndpointMissing,
    // Capture and render resolved to one endpoint.
    sameEndpoint,
    // Capture and render are the two sides of one virtual pass-through device.
    virtualPassThroughPair,
    // The requested capture endpoint is an input endpoint but the selected
    // capture mode is a render endpoint's loopback (or the reverse).
    captureModeMismatch,
};

const char* routeIssueName(RouteIssue issue);

// One virtual cable found on the machine: a playback endpoint and the recording
// endpoint that carries what is played into it.
struct VirtualCable {
    DeviceInfo playback;
    DeviceInfo recording;
};

// Virtual cables the machine exposes, matched by device instance rather than by
// name: one container id, one software (root-enumerated) bus, one endpoint on
// each flow.
std::vector<VirtualCable> findVirtualCables(const std::vector<DeviceInfo>& renderEndpoints,
                                            const std::vector<DeviceInfo>& captureEndpoints);

struct RouteDiagnosis {
    RouteIssue issue = RouteIssue::ok;
    // What is wrong, in terms of the endpoints that were actually observed.
    std::string cause;
    // What the user should do next. Empty when the route is usable.
    std::string nextAction;

    // Facts worth reporting even for a usable route, and the reason they are
    // here rather than in `cause`: they do not make the route wrong. A machine
    // without a virtual cable can still run LowEnd on a real input endpoint, and
    // capturing a cable's playback side is a valid route — it is just not the
    // route this milestone documents, so it is stated rather than silently
    // accepted.
    std::vector<std::string> notes;

    // The endpoints the selection resolved to. False when the id did not resolve
    // (that is what the matching issue reports).
    bool haveCapture = false;
    bool haveRender = false;
    DeviceInfo capture;
    DeviceInfo render;

    // Human-readable descriptions of the virtual cables found, so a caller can
    // print them without re-deriving the pairing.
    std::vector<std::string> virtualCables;

    bool ok() const { return issue == RouteIssue::ok; }
};

// Judges one selection against the endpoints the machine has.
//
// Resolution follows the engine's own rule: an empty id selects the default
// endpoint of its flow, and a non-empty id must match an enumerated endpoint
// exactly — nothing falls back to "the first device" when the id is unknown.
RouteDiagnosis diagnoseRoute(const RouteSelection& selection,
                             const std::vector<DeviceInfo>& renderEndpoints,
                             const std::vector<DeviceInfo>& captureEndpoints);

} // namespace lowend::win
