# Builds the kick starter (one of the Build page's C++ examples) against the installed SDK, with its contract test.
cmake_minimum_required(VERSION 3.22)
project(caw_starter_kick LANGUAGES CXX)

find_package(CAW 1.0 CONFIG REQUIRED)

caw_add_component(MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/caw-component.json" TARGET caw_starter_kick)

include(CTest)
if(BUILD_TESTING AND NOT ANDROID)
  add_executable(caw_starter_kick_test ../tests/starter_contract_test.cpp src/kick.cpp)
  target_compile_definitions(caw_starter_kick_test PRIVATE STARTER_ID="org.caw.starter.kick")
  target_link_libraries(caw_starter_kick_test PRIVATE CAW::SDK)
  target_compile_features(caw_starter_kick_test PRIVATE cxx_std_20)
  add_test(NAME caw_starter_kick_test COMMAND caw_starter_kick_test)
endif()
