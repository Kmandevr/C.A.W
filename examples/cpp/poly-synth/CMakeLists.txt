# Builds the example C.A.W. instrument (a small polyphonic synth) against the installed public SDK.
cmake_minimum_required(VERSION 3.22)
project(caw_poly_synth LANGUAGES CXX)

find_package(CAW 1.0 CONFIG REQUIRED)

caw_add_component(
  MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/caw-component.json"
  TARGET caw_poly_synth
)

include(CTest)
if(BUILD_TESTING AND NOT ANDROID)
  add_executable(caw_poly_synth_contract_test
    tests/instrument_contract_test.cpp
    src/poly_synth.cpp
  )
  target_link_libraries(caw_poly_synth_contract_test PRIVATE CAW::SDK)
  target_compile_features(caw_poly_synth_contract_test PRIVATE cxx_std_20)
  add_test(NAME caw_poly_synth_contract_test COMMAND caw_poly_synth_contract_test)
endif()
