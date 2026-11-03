// Explicit native SDK <-> engine channel-layout mapping; see sdk_layout.h for the rules.
#include "sdk_layout.h"

#include "caw_module_sdk.h"

namespace caw {

bool channelLayoutFromSdk(uint32_t sdkLayout, ChannelLayout& layout) noexcept {
    switch (sdkLayout) {
        case CAW_LAYOUT_NONE: layout = ChannelLayout::None; return true;
        case CAW_LAYOUT_MONO: layout = ChannelLayout::Mono; return true;
        case CAW_LAYOUT_STEREO: layout = ChannelLayout::Stereo; return true;
        default: return false;  // CAW_LAYOUT_DISCRETE carries no channel count in ABI v1
    }
}

bool channelLayoutToSdk(ChannelLayout layout, uint32_t& sdkLayout) noexcept {
    switch (layout) {
        case ChannelLayout::None: sdkLayout = CAW_LAYOUT_NONE; return true;
        case ChannelLayout::Mono: sdkLayout = CAW_LAYOUT_MONO; return true;
        case ChannelLayout::Stereo: sdkLayout = CAW_LAYOUT_STEREO; return true;
        default: return false;
    }
}

}  // namespace caw
