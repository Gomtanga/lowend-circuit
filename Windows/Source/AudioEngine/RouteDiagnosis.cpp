// RouteDiagnosis.cpp — the routing rules, with no device access.
//
// Every function here is a pure function of the endpoints it is handed, which is
// what lets `--self-test` cover the refusals (missing endpoint, same endpoint,
// one virtual cable used on both sides, capture mode mismatch) without a sound
// card in the machine, and what keeps the CLI and the GUI on one model.

#include "AudioEngine/RouteDiagnosis.h"

#include <algorithm>

namespace lowend::win {
namespace {

char asciiLower(char raw) {
    return (raw >= 'A' && raw <= 'Z') ? static_cast<char>(raw - 'A' + 'a') : raw;
}

bool equalsNoCase(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) {
        return false;
    }
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (asciiLower(a[i]) != asciiLower(b[i])) {
            return false;
        }
    }
    return true;
}

const DeviceInfo* findById(const std::vector<DeviceInfo>& devices, const std::string& id) {
    for (const DeviceInfo& device : devices) {
        if (device.id == id) {
            return &device;
        }
    }
    return nullptr;
}

const DeviceInfo* findDefault(const std::vector<DeviceInfo>& devices) {
    for (const DeviceInfo& device : devices) {
        if (device.isDefault) {
            return &device;
        }
    }
    return nullptr;
}

EndpointIdentity identityOf(const DeviceInfo& device) {
    EndpointIdentity identity;
    identity.id = device.id;
    identity.containerId = device.containerId;
    identity.deviceInstance = device.deviceInstance;
    identity.enumeratorName = device.enumeratorName;
    return identity;
}

// Windows gives every root-enumerated (software) device the same zero container
// ({00000000-0000-0000-FFFF-FFFFFFFFFFFF}), so a container can be present and
// still carry no information. Treated as missing rather than as a value that
// matches every other software device.
bool isZeroContainerId(const std::string& containerId) {
    return containerId.empty() ||
           equalsNoCase(containerId, "{00000000-0000-0000-0000-000000000000}") ||
           equalsNoCase(containerId, "{00000000-0000-0000-FFFF-FFFFFFFFFFFF}");
}

bool isSameDeviceInstance(const DeviceInfo& a, const DeviceInfo& b) {
    // The PnP instance is what identifies the device: one instance can offer
    // several endpoints (VB-CABLE's 2-channel and 16-channel inputs share one),
    // and two instances never share a path.
    if (!a.deviceInstance.empty() && a.deviceInstance == b.deviceInstance) {
        return true;
    }
    // The container groups the functions of one physical device (a USB headset's
    // microphone and speakers), which is why it is only read when it is a real
    // value. Without an instance on either side it is all an older driver offers.
    return !isZeroContainerId(a.containerId) && a.containerId == b.containerId;
}

// A device instance is a pass-through when both of its sides are on a software
// bus. Hardware endpoints that share a container (a USB headset's microphone and
// speakers, a sound card's line-in and line-out) carry independent signals, so
// they are deliberately not treated as one signal path.
bool isPassThroughPair(const DeviceInfo& playback, const DeviceInfo& recording) {
    return isSameDeviceInstance(playback, recording) &&
           isVirtualEnumerator(playback.enumeratorName) &&
           isVirtualEnumerator(recording.enumeratorName);
}

std::string describeDevice(const DeviceInfo& device) {
    std::string text = device.name.empty() ? std::string("(unnamed endpoint)") : device.name;
    if (!device.formFactor.empty()) {
        text += " [";
        text += device.formFactor;
        text += "]";
    }
    return text;
}

} // namespace

bool isVirtualEnumerator(const std::string& enumeratorName) {
    // Root enumeration means the driver instantiated the device itself; there is
    // no bus hardware behind it. Every virtual audio device (audio cable, virtual
    // sink, network audio bridge) arrives this way, and no physical endpoint
    // does: a Bluetooth headset is BTHENUM, a USB DAC is USB, an onboard codec is
    // HDAUDIO, an HDMI sink is HDAUDIO or PCI. Listing the hardware buses instead
    // would silently start treating an unfamiliar bus as a loop, so the test is
    // the single value that is documented to mean "software device".
    return equalsNoCase(enumeratorName, "ROOT");
}

uint64_t virtualPassThroughKey(const EndpointIdentity& identity) {
    // The device instance identifies the software device; the container is the
    // fallback for a driver whose instance property is not readable, and only
    // when it is a real value rather than the zero container.
    const std::string& deviceKey =
        !identity.deviceInstance.empty()
            ? identity.deviceInstance
            : (isZeroContainerId(identity.containerId) ? std::string() : identity.containerId);
    if (deviceKey.empty() || !isVirtualEnumerator(identity.enumeratorName)) {
        return 0;
    }
    // FNV-1a over the device identity, domain-separated from the endpoint-id hash
    // in RecoveryPolicy.h so the two key spaces cannot be confused. The same
    // reasoning as there applies to a false positive: the safe direction is
    // refusing the route, never running a loop.
    constexpr uint64_t offsetBasis = 14695981039346656037ull;
    constexpr uint64_t prime = 1099511628211ull;
    uint64_t hash = offsetBasis;
    for (unsigned char byte : deviceKey) {
        hash ^= static_cast<uint64_t>(byte);
        hash *= prime;
    }
    hash ^= 0x1full;  // separator: device identity, then enumerator
    hash *= prime;
    for (unsigned char byte : identity.enumeratorName) {
        hash ^= static_cast<uint64_t>(byte);
        hash *= prime;
    }
    return hash;
}

const char* routeIssueName(RouteIssue issue) {
    switch (issue) {
        case RouteIssue::ok: return "ok";
        case RouteIssue::captureEndpointMissing: return "capture endpoint missing";
        case RouteIssue::renderEndpointMissing: return "render endpoint missing";
        case RouteIssue::sameEndpoint: return "same endpoint";
        case RouteIssue::virtualPassThroughPair: return "virtual pass-through pair";
        case RouteIssue::captureModeMismatch: return "capture mode mismatch";
    }
    return "unknown";
}

bool isUnidentifiedSoftwarePair(const DeviceInfo& capture, const DeviceInfo& render) {
    return isVirtualEnumerator(capture.enumeratorName) &&
           isVirtualEnumerator(render.enumeratorName) &&
           !isSameDeviceInstance(capture, render);
}

std::vector<VirtualCable> findVirtualCables(const std::vector<DeviceInfo>& renderEndpoints,
                                            const std::vector<DeviceInfo>& captureEndpoints) {
    std::vector<VirtualCable> cables;
    for (const DeviceInfo& playback : renderEndpoints) {
        for (const DeviceInfo& recording : captureEndpoints) {
            if (isPassThroughPair(playback, recording)) {
                cables.push_back(VirtualCable { playback, recording });
            }
        }
    }
    return cables;
}

RouteDiagnosis diagnoseRoute(const RouteSelection& selection,
                             const std::vector<DeviceInfo>& renderEndpoints,
                             const std::vector<DeviceInfo>& captureEndpoints) {
    RouteDiagnosis diagnosis;

    const bool captureIsLoopback = selection.captureFlow == DataFlow::render;

    // The two flows differ in which list an endpoint comes from: a loopback
    // capture names an output endpoint, a real input capture names an input
    // endpoint. An endpoint that is found in the other flow's list is reported as
    // a mode mismatch rather than silently opened in the wrong mode.
    const std::vector<DeviceInfo>& captureSideList =
        captureIsLoopback ? renderEndpoints : captureEndpoints;
    bool foundOnWrongSide = false;

    const DeviceInfo* capture = nullptr;
    if (selection.captureId.empty()) {
        capture = findDefault(captureSideList);
    } else {
        capture = findById(captureSideList, selection.captureId);
        if (capture == nullptr) {
            foundOnWrongSide = findById(captureIsLoopback ? captureEndpoints : renderEndpoints,
                                       selection.captureId) != nullptr;
        }
    }

    const DeviceInfo* render = nullptr;
    if (selection.renderId.empty()) {
        render = findDefault(renderEndpoints);
    } else {
        render = findById(renderEndpoints, selection.renderId);
    }

    // Reported for every route, usable or not: which virtual cables exist is a
    // property of the machine, and it is what tells a user that the documented
    // cable route is available at all.
    const std::vector<VirtualCable> cables = findVirtualCables(renderEndpoints, captureEndpoints);
    for (const VirtualCable& cable : cables) {
        diagnosis.virtualCables.push_back(
            describeDevice(cable.playback) + "  ->  " + describeDevice(cable.recording));
    }

    // Published as soon as each side resolves, for every outcome: a refused route
    // is where a caller most needs to see which endpoints the decision was made
    // about, and the refusal itself is stated separately.
    if (capture != nullptr) {
        diagnosis.haveCapture = true;
        diagnosis.capture = *capture;
    }
    if (render != nullptr) {
        diagnosis.haveRender = true;
        diagnosis.render = *render;
    }

    if (selection.captureId.empty() && capture == nullptr) {
        diagnosis.issue = RouteIssue::captureEndpointMissing;
        diagnosis.cause = captureIsLoopback
            ? "the machine has no usable default output endpoint to capture as system audio"
            : "the machine has no usable default input endpoint";
        diagnosis.nextAction =
            "run --list-devices and pass the id of an endpoint that is present";
    } else if (!selection.captureId.empty() && capture == nullptr) {
        // An id that exists but belongs to the other flow is a mode problem, not
        // a missing device: the user has the endpoint, they selected it for the
        // wrong mode. Reported separately so the advice can be specific.
        diagnosis.issue = foundOnWrongSide ? RouteIssue::captureModeMismatch
                                           : RouteIssue::captureEndpointMissing;
        diagnosis.cause = foundOnWrongSide
            ? "the requested capture endpoint (" + selection.captureId +
                  ") is an endpoint of the other flow than the selected capture mode"
            : "no endpoint with the requested capture id is present";
        diagnosis.nextAction = foundOnWrongSide
            ? (captureIsLoopback
                   ? "that id is an input endpoint: pass it to --input-device to record it, or "
                     "name an output endpoint with --capture-device and leave --loopback on"
                   : "that id is an output endpoint: capture it as system audio with "
                     "--capture-device and --loopback on, or name an input endpoint with "
                     "--input-device")
            : "run --list-devices and pass an id from that list; an endpoint that was "
              "reinstalled or re-added gets a new id, and nothing falls back to another device";
    } else if (selection.renderId.empty() && render == nullptr) {
        diagnosis.issue = RouteIssue::renderEndpointMissing;
        diagnosis.cause = "the machine has no usable default output endpoint to play to";
        diagnosis.nextAction =
            "connect the output device (the milestone route uses the Fosi Audio ZH3) and pass "
            "its id with --device after --list-devices shows it";
    } else if (!selection.renderId.empty() && render == nullptr) {
        diagnosis.issue = RouteIssue::renderEndpointMissing;
        diagnosis.cause = "no endpoint with the requested render id is present";
        diagnosis.nextAction =
            "run --list-devices and pass an id from that list; a disconnected output device "
            "(USB DAC, HDMI sink) must be reconnected, and a reinstalled one gets a new id";
    } else if (capture->id == render->id) {
        diagnosis.issue = RouteIssue::sameEndpoint;
        diagnosis.cause = "capture and render are the same endpoint (" + describeDevice(*render) +
            "); loopback copies the output stream instead of replacing it, so the processed"
            " result would be captured again as input";
        diagnosis.nextAction =
            "name a different output endpoint with --device (or capture a real input endpoint "
            "with --input-device)";
    } else if (passThroughKeysCollide(virtualPassThroughKey(identityOf(*capture)),
                                      virtualPassThroughKey(identityOf(*render)))) {
        diagnosis.issue = RouteIssue::virtualPassThroughPair;
        const std::string& deviceIdentity = !capture->deviceInstance.empty()
                                                ? capture->deviceInstance
                                                : capture->containerId;
        diagnosis.cause = "capture (" + describeDevice(*capture) + ") and render (" +
            describeDevice(*render) + ") are the two sides of one virtual device (" +
            deviceIdentity + ", bus " + capture->enumeratorName +
            "); everything rendered to its playback side comes back on its recording side, so the"
            " engine would process its own output forever";
        diagnosis.nextAction =
            "use one side of the cable and a physical device on the other: capture the cable's"
            " recording side as an input (--input-device) and render to the output device (--device),"
            " or the reverse";
    }

    if (diagnosis.issue == RouteIssue::ok) {
        // Capture side facts that do not make the route wrong but change what it
        // means, so they are stated instead of left implicit.
        const bool captureIsCablePlayback =
            std::any_of(cables.begin(), cables.end(), [&](const VirtualCable& cable) {
                return cable.playback.id == capture->id;
            });
        if (captureIsCablePlayback && captureIsLoopback) {
            diagnosis.notes.push_back(
                "the capture endpoint is a virtual cable's playback side, so this route processes"
                " what applications play into that cable. The milestone route instead captures the"
                " cable's recording side as a real input endpoint (--input-device).");
        }

        if (cables.empty()) {
            diagnosis.notes.push_back(
                "no virtual cable endpoints were detected (one device instance offering a playback"
                " and a recording side). The documented route Windows audio -> CABLE Input ->"
                " CABLE Output -> LowEnd -> output device needs one, such as VB-CABLE; installing a"
                " virtual audio driver is an external change that needs the user's consent. A real"
                " input endpoint (--input-device) works without one.");
        }

        // The identification the guard rests on is container equality, and it is
        // the one property Windows might report differently for a cable whose two
        // sides are separate devices. Saying so is the difference between "no loop
        // was found" and "no loop could be ruled out", which is what a user needs
        // to know before trusting the route.
        if (isUnidentifiedSoftwarePair(*capture, *render)) {
            diagnosis.notes.push_back(
                "capture (" + describeDevice(*capture) + ") and render (" + describeDevice(*render)
                + ") are both software-bus devices, but Windows reports them as different device"
                  " instances, so they cannot be identified as the two sides of one virtual cable."
                  " If they are two sides of one cable, this route is a feedback loop - everything"
                  " rendered comes straight back as input - and the guard cannot prove it, so it is"
                  " not refused. Do not capture one side of a cable while rendering to the other.");
        }
    }

    // Remote endpoints report an independent clock, so a route built on them can
    // drift where a local one does not. Said once, with the observed evidence.
    const bool anyLocalCapture = std::any_of(
        captureEndpoints.begin(), captureEndpoints.end(),
        [](const DeviceInfo& device) { return device.formFactor != "Network"; });
    if (!captureEndpoints.empty() && !anyLocalCapture) {
        diagnosis.notes.push_back(
            "every input endpoint on this machine is a remote/network device [Network], so the"
            " capture clock is not the local audio clock; measure a long run with --verbose"
            " before treating a route through one as stable.");
    }

    return diagnosis;
}

} // namespace lowend::win
