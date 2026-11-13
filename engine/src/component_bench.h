// The plug-in benchmark (#197): one built component timed offline, with automatic checks, sections and curves, as JSON.
#pragma once

#include <cstdint>
#include <string>

#include "module_registry.h"

namespace caw::bench {

// What to bench: a built-in by id (library empty), or a built library's component, loaded only when the user's own
// choice for that library is Trusted (never Blocked or Isolated: no other value opens it).
struct Request {
    std::string id;
    std::string library;
    NativeModuleTrust trust = NativeModuleTrust::Blocked;
    double seconds = 1.0;  // audio per measurement (0.1..10); the curves' points take half each
};

// The calling thread's allocations and frees so far, from a host that can count them (caw_rt_tests' counter of the
// global operator new and delete). Unset (the app), the allocation check says it could not count ("measured":
// false) instead of passing.
using AllocationCounter = uint64_t (*)() noexcept;
void setAllocationCounter(AllocationCounter counter) noexcept;

// The checks' thresholds (Claude's choices, docs/decisions.md 2026-11-13; docs/engine.md "The plug-in benchmark").
// A check whose costs are all under kFloorPct of a block passes as too cheap to matter (except allocations and
// subnormal output, which fail or warn at any cost).
struct Thresholds {
    static constexpr double kFloorPct = 0.5;            // % of a 64-frame block at 48 kHz
    static constexpr double kDenormalWarnPct = 15, kDenormalFailPct = 50;          // slower at silence, unflushed
    static constexpr double kVoiceWarnPct = 1.5, kVoiceFailPct = 6;                 // % of a block per voice
    static constexpr double kBlockWarnPct = 50, kBlockFailPct = 150;                // more per frame at 32 than 512
    static constexpr double kRateWarnRatio = 2.4, kRateFailRatio = 3.2;            // 96 kHz cost / 48 kHz (2 linear)
    static constexpr double kParamWarnPct = 2, kParamFailPct = 10;  // extra, % of a block, every parameter moving
    static constexpr double kSilenceWarnPct = 25;                                    // % of its cost while silent
};

// Runs the bench on the calling thread (a worker; never the audio or UI thread). `progress` (0..1000) and `cancel`
// (non-zero stops it) may be null. Returns the result JSON: {"ok": true, "tool": "caw_component_bench", ...} or
// {"ok": false, "error": ...}. One bench runs at a time (a second waits). Never throws.
std::string run(const Request& request, int32_t* progress, const int32_t* cancel);

}  // namespace caw::bench
