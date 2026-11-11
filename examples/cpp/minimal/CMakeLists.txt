# Builds the minimal C.A.W. component against the installed public SDK.
cmake_minimum_required(VERSION 3.22)
project(caw_minimal_component LANGUAGES CXX)

find_package(CAW 1.0 CONFIG REQUIRED)

caw_add_component(
  MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/caw-component.json"
  TARGET caw_minimal_component
)

# The same component as a CLAP plug-in (caw-minimal.clap next to the library); fetches the CLAP headers.
option(CAW_BUILD_CLAP "Also build the component as a CLAP plug-in" OFF)
if(CAW_BUILD_CLAP)
  caw_add_clap_plugin(TARGET caw_minimal_clap COMPONENT caw_minimal_component
    OUTPUT_NAME caw-minimal VENDOR "C.A.W examples" VERSION "1.0.0")
endif()

# And as a VST3 plug-in (the caw-minimal.vst3 bundle next to the library); fetches the VST3 interface headers.
option(CAW_BUILD_VST3 "Also build the component as a VST3 plug-in" OFF)
if(CAW_BUILD_VST3)
  caw_add_vst3_plugin(TARGET caw_minimal_vst3 COMPONENT caw_minimal_component
    OUTPUT_NAME caw-minimal VENDOR "C.A.W examples" VERSION "1.0.0")
endif()

include(CTest)
if(BUILD_TESTING AND NOT ANDROID)
  add_executable(caw_component_contract_test
    tests/component_contract_test.cpp
    src/minimal_component.cpp
  )
  target_link_libraries(caw_component_contract_test PRIVATE CAW::SDK)
  target_compile_features(caw_component_contract_test PRIVATE cxx_std_20)
  add_test(NAME caw_component_contract_test COMMAND caw_component_contract_test)
endif()
