# Builds the example C.A.W. modulator (a Euclidean gate with a swung ramp, #161) against the installed public SDK.
cmake_minimum_required(VERSION 3.22)
project(caw_euclid_modulator LANGUAGES CXX)

find_package(CAW 1.0 CONFIG REQUIRED)

caw_add_component(
  MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/caw-component.json"
  TARGET caw_euclid_modulator
)

include(CTest)
if(BUILD_TESTING AND NOT ANDROID)
  add_executable(caw_euclid_modulator_contract_test
    tests/modulator_contract_test.cpp
    src/euclid_modulator.cpp
  )
  target_link_libraries(caw_euclid_modulator_contract_test PRIVATE CAW::SDK)
  target_compile_features(caw_euclid_modulator_contract_test PRIVATE cxx_std_20)
  add_test(NAME caw_euclid_modulator_contract_test COMMAND caw_euclid_modulator_contract_test)
endif()
