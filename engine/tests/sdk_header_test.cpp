// Ensure the public native-module SDK remains usable as a plain C header.
#include "test.h"

#include "caw_module_sdk.h"

TEST(native_module_sdk_exposes_versioned_c_abi) {
    CHECK_EQ(CAW_MODULE_ABI_VERSION, 1u);
    CHECK_EQ(CAW_PORT_AUDIO, 0);
    CHECK_EQ(CAW_LAYOUT_STEREO, 2);
}
