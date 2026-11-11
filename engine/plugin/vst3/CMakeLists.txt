# VST3 export tests (CAW_VST3=ON): builds the example and the CLAP test bundle as .vst3 plug-ins and a test host that loads them.
include("${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/CAWComponent.cmake")

# The minimal example, through the same manifest and helper its own project uses (one caw_add_component per build:
# with CAW_CLAP on, the CLAP tests' copy serves both).
if(TARGET caw_clap_minimal_component)
  set(_caw_vst3_minimal caw_clap_minimal_component)
else()
  caw_add_component(MANIFEST "${CAW_ROOT}/examples/cpp/minimal/caw-component.json" TARGET caw_vst3_minimal_component)
  set(_caw_vst3_minimal caw_vst3_minimal_component)
endif()
caw_add_vst3_plugin(TARGET caw_vst3_minimal COMPONENT ${_caw_vst3_minimal}
  OUTPUT_NAME caw-minimal VENDOR "C.A.W examples" VERSION "1.0.0")

# The CLAP wrapper's test bundle (an effect, an instrument, a transport reader) serves both wrappers.
add_library(caw_vst3_fixture_component MODULE ../clap/tests/clap_fixture.cpp)
target_link_libraries(caw_vst3_fixture_component PRIVATE CAW::SDK)
target_compile_options(caw_vst3_fixture_component PRIVATE ${CAW_FLAGS})
set_target_properties(caw_vst3_fixture_component PROPERTIES PREFIX "" CXX_VISIBILITY_PRESET hidden
  OUTPUT_NAME caw_vst3_fixture_component
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/artifacts")
caw_add_vst3_plugin(TARGET caw_vst3_fixture COMPONENT caw_vst3_fixture_component
  OUTPUT_NAME caw-test-bundle VENDOR "C.A.W tests" URL "https://example.invalid/caw-tests")

add_executable(caw_vst3_tests ../../tests/test_main.cpp ../../tests/alloc_counter.cpp tests/vst3_host_test.cpp)
target_compile_options(caw_vst3_tests PRIVATE ${CAW_FLAGS})
target_include_directories(caw_vst3_tests PRIVATE ../../src ../../tests)
target_link_libraries(caw_vst3_tests PRIVATE caw_core caw_vst3_sdk ${CMAKE_DL_LIBS})
add_dependencies(caw_vst3_tests caw_vst3_minimal ${_caw_vst3_minimal} caw_vst3_fixture caw_vst3_fixture_component)
target_compile_definitions(caw_vst3_tests PRIVATE
  "CAW_VST3_MINIMAL=\"$<TARGET_FILE:caw_vst3_minimal>\""
  "CAW_VST3_MINIMAL_COMPONENT=\"$<TARGET_FILE:${_caw_vst3_minimal}>\""
  "CAW_VST3_FIXTURE=\"$<TARGET_FILE:caw_vst3_fixture>\""
  "CAW_VST3_FIXTURE_COMPONENT=\"$<TARGET_FILE:caw_vst3_fixture_component>\"")
add_test(NAME caw_vst3_tests COMMAND caw_vst3_tests)
