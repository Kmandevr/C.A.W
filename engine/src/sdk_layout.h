// Explicit mapping between the native SDK's C channel-layout values and the engine's ChannelLayout.
#pragma once

#include <cstdint>

#include "module.h"

namespace caw {

// The SDK enum (CAW_LAYOUT_*) and ChannelLayout have different numeric values (SDK Discrete is 3,
// engine Quad is 3), so never cast between them; use these. Both return false and leave the output
// unchanged for a value with no exact equivalent. SDK v1 has no channel-count field, so its
// Discrete layout cannot be resolved, and Quad, 5.1, 7.1 and Discrete have no SDK value.
bool channelLayoutFromSdk(uint32_t sdkLayout, ChannelLayout& layout) noexcept;
bool channelLayoutToSdk(ChannelLayout layout, uint32_t& sdkLayout) noexcept;

}  // namespace caw
