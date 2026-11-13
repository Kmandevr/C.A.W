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

// One benchmark at a time records (component_bench.cpp holds a lock around it). start() clears the table and
// records the sections the calling thread enters until stop(); sections entered on any other thread are ignored.
void start() noexcept;
void stop() noexcept;
// The sections recorded since start(), in first-entered order. Call after stop().
std::vector<Section> sections();

}  // namespace caw::profile
