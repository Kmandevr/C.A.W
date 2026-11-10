# CLAP export tests (CAW_CLAP=ON): builds the example and a test bundle as .clap plug-ins and a test host that loads them.
include("${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/CAWComponent.cmake")

# The minimal example, through the same manifest and helper its own project uses.
caw_add_component(MANIFEST "${CAW_ROOT}/examples/cpp/minimal/caw-component.json" TARGET caw_clap_minimal_component)
caw_add_clap_plugin(TARGET caw_clap_minimal COMPONENT caw_clap_minimal_component
  OUTPUT_NAME caw-minimal VENDOR "C.A.W examples" VERSION "1.0.0" DESCRIPTION "Minimal stereo pass-through")

# The test bundle as a plain component library (loaded by the registry) and as a plug-in.
add_library(caw_clap_fixture_component MODULE tests/clap_fixture.cpp)
target_link_libraries(caw_clap_fixture_component PRIVATE CAW::SDK)
target_compile_options(caw_clap_fixture_component PRIVATE ${CAW_FLAGS})
set_target_properties(caw_clap_fixture_component PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts")
caw_add_clap_plugin(TARGET caw_clap_fixture COMPONENT caw_clap_fixture_component
  OUTPUT_NAME caw-test-bundle VENDOR "C.A.W tests" URL "https://example.invalid/caw-tests")

# alloc_counter replaces the global allocation functions, so process can be checked for allocations.
add_executable(caw_clap_tests ../../tests/test_main.cpp ../../tests/alloc_counter.cpp tests/clap_host_test.cpp)
target_compile_options(caw_clap_tests PRIVATE ${CAW_FLAGS})
target_include_directories(caw_clap_tests PRIVATE ../../src ../../tests)
target_link_libraries(caw_clap_tests PRIVATE caw_core caw_clap_headers)
add_dependencies(caw_clap_tests caw_clap_minimal caw_clap_minimal_component caw_clap_fixture caw_clap_fixture_component)
target_compile_definitions(caw_clap_tests PRIVATE
  "CAW_CLAP_MINIMAL=\"$<TARGET_FILE:caw_clap_minimal>\""
  "CAW_CLAP_MINIMAL_COMPONENT=\"$<TARGET_FILE:caw_clap_minimal_component>\""
  "CAW_CLAP_FIXTURE=\"$<TARGET_FILE:caw_clap_fixture>\""
  "CAW_CLAP_FIXTURE_COMPONENT=\"$<TARGET_FILE:caw_clap_fixture_component>\"")
add_test(NAME caw_clap_tests COMMAND caw_clap_tests)
