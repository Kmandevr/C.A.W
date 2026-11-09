#pragma once

#include <cstdlib>

// The test runner may invoke caw_tests directly, bypassing CTest's test environment.
// Prefer the CTest override when present, but keep direct filtered runs self-contained.
namespace caw::test {
inline const char* nativeComponentPath() noexcept {
    const char* configured = std::getenv("CAW_TEST_COMPONENT_PATH");
    if (configured && configured[0] != '\0') return configured;
#ifdef CAW_TEST_COMPONENT_PATH_DEFAULT
    return CAW_TEST_COMPONENT_PATH_DEFAULT;
#else
    return nullptr;
#endif
}
}  // namespace caw::test
