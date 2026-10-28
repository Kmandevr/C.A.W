# Builds the C.A.W engine: core library, shared library for the app (with audio output), the caw CLI and tests.
cmake_minimum_required(VERSION 3.22)
project(caw_engine LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(CAW_AUDIO "Build the shared library with device audio output (miniaudio)" ON)
option(CAW_TOOLS "Build the caw CLI and the tests" ON)
option(CAW_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

get_filename_component(CAW_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

# Determinism: no fast-math and no fused multiply-add contraction (MSVC /fp:precise never contracts), so every platform rounds alike.
if(MSVC)
  set(CAW_FLAGS /W4 /fp:precise /utf-8 /EHsc)
else()
  set(CAW_FLAGS -Wall -Wextra -ffp-contract=off -fno-fast-math)
endif()
if(CAW_SANITIZE AND NOT MSVC)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined)
  add_link_options(-fsanitize=address,undefined)
endif()

# Starter templates: examples/*.caw become string constants inside the engine.
file(GLOB CAW_TEMPLATES CONFIGURE_DEPENDS "${CAW_ROOT}/examples/*.caw")
list(SORT CAW_TEMPLATES)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${CAW_TEMPLATES})
set(CAW_TEMPLATES_CPP "${CMAKE_CURRENT_BINARY_DIR}/caw_templates.cpp")
set(_tpl "// Generated from examples/*.caw by engine/CMakeLists.txt; do not edit.\n#include \"capi_internal.h\"\nnamespace caw {\n")
set(_files "")
set(_srcs "")
list(LENGTH CAW_TEMPLATES _count)
foreach(f IN LISTS CAW_TEMPLATES)
  get_filename_component(_name "${f}" NAME)
  file(READ "${f}" _body)
  string(APPEND _files "\"${_name}\",\n")
  string(APPEND _srcs "R\"caw_tpl(${_body})caw_tpl\",\n")
endforeach()
if(_count EQUAL 0)
  set(_files "nullptr,\n")
  set(_srcs "nullptr,\n")
endif()
string(APPEND _tpl "const int kTemplateCount = ${_count};\nconst char* const kTemplateFiles[] = {\n${_files}};\nconst char* const kTemplateSources[] = {\n${_srcs}};\n}  // namespace caw\n")
file(WRITE "${CAW_TEMPLATES_CPP}.tmp" "${_tpl}")
file(COPY_FILE "${CAW_TEMPLATES_CPP}.tmp" "${CAW_TEMPLATES_CPP}" ONLY_IF_DIFFERENT)

add_library(caw_core STATIC
  src/builtins.cpp
  src/compile.cpp
  src/detmath.cpp
  src/engine.cpp
  src/json.cpp
  src/project.cpp
  src/render.cpp
  src/vm.cpp
  src/wav.cpp
  "${CAW_TEMPLATES_CPP}")
target_include_directories(caw_core PUBLIC include src)
target_compile_options(caw_core PRIVATE ${CAW_FLAGS})
find_package(Threads REQUIRED)
target_link_libraries(caw_core PUBLIC Threads::Threads)
set_target_properties(caw_core PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)

# The library the app loads through dart:ffi.
if(CAW_AUDIO)
  add_library(caw_engine SHARED src/capi.cpp platform/audio_miniaudio.cpp platform/miniaudio_impl.c)
  target_include_directories(caw_engine PRIVATE third_party/miniaudio)
  target_compile_options(caw_engine PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${CAW_FLAGS}>)
  if(ANDROID)
    target_link_libraries(caw_engine PRIVATE log)
  endif()
  if(UNIX AND NOT APPLE AND NOT ANDROID)
    target_link_libraries(caw_engine PRIVATE dl m)
  endif()
else()
  add_library(caw_engine SHARED src/capi.cpp platform/audio_none.cpp)
  target_compile_options(caw_engine PRIVATE ${CAW_FLAGS})
endif()
target_link_libraries(caw_engine PRIVATE caw_core)
# The file is libcaw.so / caw.dll; only the C API (marked CAW_API) is exported.
set_target_properties(caw_engine PROPERTIES OUTPUT_NAME caw CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden)

if(CAW_TOOLS)
  add_executable(caw_cli cli/main.cpp platform/audio_none.cpp)
  set_target_properties(caw_cli PROPERTIES OUTPUT_NAME caw)
  target_compile_options(caw_cli PRIVATE ${CAW_FLAGS})
  target_link_libraries(caw_cli PRIVATE caw_core)

  add_executable(caw_tests tests/test_main.cpp tests/language_test.cpp tests/engine_test.cpp tests/export_test.cpp
                           tests/golden_test.cpp src/capi.cpp platform/audio_none.cpp)
  target_compile_options(caw_tests PRIVATE ${CAW_FLAGS})
  target_compile_definitions(caw_tests PRIVATE CAW_ROOT="${CAW_ROOT}")
  target_link_libraries(caw_tests PRIVATE caw_core)
  enable_testing()
  add_test(NAME caw_tests COMMAND caw_tests)
endif()
