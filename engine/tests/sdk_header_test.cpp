// Ensure the public native-module SDK remains usable as a plain C header.
#include "test.h"

#include "caw_module_sdk.h"
#include "sdk_layout.h"

TEST(native_module_sdk_exposes_versioned_c_abi) {
    CHECK_EQ(CAW_MODULE_ABI_VERSION, 1u);
    CHECK_EQ(CAW_PORT_AUDIO, 0);
    CHECK_EQ(CAW_LAYOUT_STEREO, 2);
}

TEST(native_sdk_layouts_map_explicitly_to_engine_layouts) {
    using caw::ChannelLayout;
    ChannelLayout layout = ChannelLayout::Quad;
    CHECK(caw::channelLayoutFromSdk(CAW_LAYOUT_NONE, layout) && layout == ChannelLayout::None);
    CHECK(caw::channelLayoutFromSdk(CAW_LAYOUT_MONO, layout) && layout == ChannelLayout::Mono);
    CHECK(caw::channelLayoutFromSdk(CAW_LAYOUT_STEREO, layout) && layout == ChannelLayout::Stereo);
    // The v1 ABI has no channel-count field, so SDK Discrete cannot be resolved yet.
    // Its value (3) is not the engine's Quad (also 3): never cast between the enums.
    layout = ChannelLayout::Stereo;
    CHECK(!caw::channelLayoutFromSdk(CAW_LAYOUT_DISCRETE, layout));
    CHECK(layout == ChannelLayout::Stereo);
    CHECK(!caw::channelLayoutFromSdk(4u, layout));
    CHECK(!caw::channelLayoutFromSdk(0xffffffffu, layout));

    uint32_t sdk = 99;
    CHECK(caw::channelLayoutToSdk(ChannelLayout::None, sdk) && sdk == CAW_LAYOUT_NONE);
    CHECK(caw::channelLayoutToSdk(ChannelLayout::Mono, sdk) && sdk == CAW_LAYOUT_MONO);
    CHECK(caw::channelLayoutToSdk(ChannelLayout::Stereo, sdk) && sdk == CAW_LAYOUT_STEREO);
    sdk = 99;
    CHECK(!caw::channelLayoutToSdk(ChannelLayout::Quad, sdk));
    CHECK(!caw::channelLayoutToSdk(ChannelLayout::Surround51, sdk));
    CHECK(!caw::channelLayoutToSdk(ChannelLayout::Surround71, sdk));
    CHECK(!caw::channelLayoutToSdk(ChannelLayout::Discrete, sdk));
    CHECK_EQ(sdk, 99u);
}
