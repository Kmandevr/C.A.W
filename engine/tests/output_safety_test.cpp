// The live output's safety stage through the C API (API 35, #244): the flags start with the limiter on and read back as set.
#include "caw.h"
#include "test.h"

TEST(the_output_safety_flags_start_with_the_limiter_and_read_back) {
    CawEngine* e = caw_engine_create(48000);
    CHECK(e != nullptr);
    CHECK_EQ(caw_engine_output_safety(e), CAW_OUTPUT_LIMITER);
    caw_engine_set_output_safety(e, CAW_OUTPUT_LIMITER | CAW_OUTPUT_MONO | 8);  // unknown bits are dropped
    CHECK_EQ(caw_engine_output_safety(e), CAW_OUTPUT_LIMITER | CAW_OUTPUT_MONO);
    caw_engine_set_output_safety(e, 0);
    CHECK_EQ(caw_engine_output_safety(e), 0);
    caw_engine_destroy(e);
    CHECK_EQ(caw_engine_output_safety(nullptr), 0);
    caw_engine_set_output_safety(nullptr, 1);  // a null engine is ignored
}
