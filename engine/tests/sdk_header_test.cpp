// The component C interface (caw_component.h): versioned, with the layout the C++ SDK relies on.
#include "test.h"

#include <cstddef>

#include "caw_component.h"
#include "module.h"

TEST(component_c_interface_is_versioned_and_matches_the_cpp_contract) {
    CHECK_EQ(CAW_COMPONENT_ABI_VERSION, 3u);
    CHECK_EQ(CAW_LAYOUT_STEREO, static_cast<int>(caw::ChannelLayout::Stereo));
    CHECK_EQ(CAW_LAYOUT_DISCRETE, static_cast<int>(caw::ChannelLayout::Discrete));
    CHECK_EQ(CAW_PORT_MODULATION, static_cast<int>(caw::PortType::Modulation));
    CHECK_EQ(sizeof(CawEvent), sizeof(caw::Event));
    // Growth fields lead each top-level struct, so a reader can check them before anything else.
    CHECK_EQ(offsetof(CawComponentV3, struct_size), 0u);
    CHECK_EQ(offsetof(CawComponentDescriptor, struct_size), 0u);
    CHECK_EQ(offsetof(CawProcessBlock, struct_size), 0u);
    CHECK_EQ(offsetof(CawHost, struct_size), 0u);
}
