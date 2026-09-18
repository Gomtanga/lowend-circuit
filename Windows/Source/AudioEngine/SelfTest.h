// SelfTest.h — offline checks that need no audio device.
//
// `lowend_windows --self-test` runs these. They exercise the same DSP path the
// live engine uses and the same routing rules the live engine applies to a
// capture/render pair, so a passing run is evidence about the processing chain
// and about which routes are refused, not about a specific device. Device
// negotiation, latency and Bluetooth behaviour are explicitly outside this
// scope.

#pragma once

namespace lowend::win {

// Runs every offline check. Returns 0 when all pass; a non-zero count of
// failures otherwise, with details printed to stdout.
int runSelfTest();

} // namespace lowend::win
