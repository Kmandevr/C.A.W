# Builds the minimal C.A.W. component against the installed public SDK.
cmake_minimum_required(VERSION 3.22)
project(caw_minimal_component LANGUAGES CXX)

find_package(CAW 1.0 CONFIG REQUIRED)

caw_add_component(
  MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/caw-component.json"
  TARGET caw_minimal_component
)

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
