// The plug-in benchmark's section table: the host side of CAW_PROFILE_SCOPE (caw/profile.hpp), one per process.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "caw_component.h"

namespace caw::profile {

// CawHost.get_extension for every component the registry creates: the profile extension, else null.
const void* hostExtension(const CawHost* host, const char* id) noexcept;

struct Section {
    std::string name;
    uint64_t ns = 0, calls = 0;
};

// One benchmark at a time records (component_bench.cpp allows one at a time). start() clears the table and
// records the sections the calling thread enters until stop(); sections entered on any other thread are ignored.
// Each section's time is its own (exclusive): a nested section's time is taken off its parent's, so the shares
// add up to at most the whole.
void start() noexcept;
void stop() noexcept;
// start() for its life: stop() on any way out (a throw too), so the table never stays active.
struct Recording {
    Recording() noexcept { start(); }
    ~Recording() { stop(); }
    Recording(const Recording&) = delete;
    Recording& operator=(const Recording&) = delete;
};
// The sections recorded since start(), in first-entered order. Call after stop().
std::vector<Section> sections();

}  // namespace caw::profile
