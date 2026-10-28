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

# Embedded .caw files: starter templates (examples/*.caw) and the built-in libraries (engine/lib/*.caw) become
# string constants inside the engine.
function(caw_read_dir dir out_files out_srcs out_count)
  file(GLOB _list CONFIGURE_DEPENDS "${dir}/*.caw")
  list(SORT _list)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${_list})
  set(_files "")
  set(_srcs "")
  foreach(f IN LISTS _list)
    get_filename_component(_name "${f}" NAME)
    file(READ "${f}" _body)
    string(APPEND _files "\"${_name}\",\n")
    string(APPEND _srcs "R\"caw_tpl(${_body})caw_tpl\",\n")
  endforeach()
  list(LENGTH _list _count)
  set(${out_files} "${_files}" PARENT_SCOPE)
  set(${out_srcs} "${_srcs}" PARENT_SCOPE)
  set(${out_count} ${_count} PARENT_SCOPE)
endfunction()

function(caw_write_if_changed path content)
  file(WRITE "${path}.tmp" "${content}")
  file(COPY_FILE "${path}.tmp" "${path}" ONLY_IF_DIFFERENT)
endfunction()

caw_read_dir("${CAW_ROOT}/examples" _tfiles _tsrcs _tcount)
if(_tcount EQUAL 0)
  set(_tfiles "nullptr,\n")
  set(_tsrcs "nullptr,\n")
endif()
set(CAW_TEMPLATES_CPP "${CMAKE_CURRENT_BINARY_DIR}/caw_templates.cpp")
caw_write_if_changed("${CAW_TEMPLATES_CPP}" "// Generated from examples/*.caw by engine/CMakeLists.txt; do not edit.
#include \"capi_internal.h\"
namespace caw {
const int kTemplateCount = ${_tcount};
const char* const kTemplateFiles[] = {
${_tfiles}};
const char* const kTemplateSources[] = {
${_tsrcs}};
}  // namespace caw
")

caw_read_dir("${CMAKE_CURRENT_SOURCE_DIR}/lib" _lfiles _lsrcs _lcount)
set(CAW_STDLIB_CPP "${CMAKE_CURRENT_BINARY_DIR}/caw_stdlib.cpp")
caw_write_if_changed("${CAW_STDLIB_CPP}" "// Generated from engine/lib/*.caw by engine/CMakeLists.txt; do not edit.
#include \"compile.h\"
namespace caw {
const std::vector<LibrarySource>& standardLibraries() {
    static const char* const sources[] = {
${_lsrcs}nullptr};
    static const std::vector<LibrarySource> libs = [] {
        std::vector<LibrarySource> v;
        for (const char* const* s = sources; *s; ++s) v.push_back({std::string(), std::string(*s)});
        return v;
    }();
    return libs;
}
}  // namespace caw
")

add_library(caw_core STATIC
  src/builtins.cpp
  src/compile.cpp
  src/detmath.cpp
  src/docs.cpp
  src/pattern.cpp
  src/engine.cpp
  src/json.cpp
  src/midifile.cpp
  src/project.cpp
  src/render.cpp
  src/vm.cpp
  src/wav.cpp
  "${CAW_TEMPLATES_CPP}"
  "${CAW_STDLIB_CPP}")
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
                           tests/golden_test.cpp tests/variables_test.cpp tests/library_test.cpp tests/pattern_test.cpp
                           tests/midifile_test.cpp src/capi.cpp platform/audio_none.cpp)
  target_compile_options(caw_tests PRIVATE ${CAW_FLAGS})
  target_compile_definitions(caw_tests PRIVATE CAW_ROOT="${CAW_ROOT}")
  target_link_libraries(caw_tests PRIVATE caw_core)
  enable_testing()
  add_test(NAME caw_tests COMMAND caw_tests)
endif()
