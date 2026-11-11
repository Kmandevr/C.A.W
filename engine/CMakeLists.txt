# Builds the C.A.W engine: core library, shared library for the app (with audio output), the caw CLI and tests.
cmake_minimum_required(VERSION 3.22)
project(caw_engine LANGUAGES C CXX)
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
option(CAW_AUDIO "Build the shared library with device audio output (miniaudio)" ON)
option(CAW_TOOLS "Build the caw CLI and the tests" ON)
option(CAW_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)
option(CAW_CLAP "Build the CLAP export tests: example plug-ins and a test host (fetches the CLAP headers)" OFF)
option(CAW_VST3 "Build the VST3 export tests: example plug-ins and a test host (fetches the VST3 interface headers)" OFF)
get_filename_component(CAW_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

# Public source-level C++ SDK. Internal engine headers stay private to engine targets.
add_library(caw_sdk INTERFACE)
add_library(CAW::SDK ALIAS caw_sdk)
target_include_directories(caw_sdk INTERFACE
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
target_compile_features(caw_sdk INTERFACE cxx_std_20)
# The SDK's deterministic maths (caw/detmath.hpp, caw/library/) gives the same bits on every
# platform only without fused multiply-add contraction or fast-math, so every component built
# against the SDK gets the engine's floating-point flags too.
# Clang is either clang or clang-cl (MSVC-style flags, which ignore -ffp-contract and still fuse
# multiply-adds under /fp:precise), so its flags are chosen from the consuming build's frontend:
# here for the build tree, and in CAWConfig.cmake for installed consumers.
target_compile_options(caw_sdk INTERFACE
  "$<$<COMPILE_LANG_AND_ID:CXX,MSVC>:/fp:precise>"
  "$<$<COMPILE_LANG_AND_ID:CXX,GNU,AppleClang>:-ffp-contract=off;-fno-fast-math;-fno-trapping-math>")
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    target_compile_options(caw_sdk INTERFACE "$<BUILD_INTERFACE:/fp:precise;/clang:-ffp-contract=off>")
  else()
    target_compile_options(caw_sdk INTERFACE "$<BUILD_INTERFACE:-ffp-contract=off;-fno-fast-math;-fno-trapping-math>")
  endif()
endif()
set_target_properties(caw_sdk PROPERTIES EXPORT_NAME SDK)

# Install the SDK package only when engine is configured as the top-level project.
# The app embeds engine as a subdirectory and has a generator-expression install prefix;
# it needs the runtime library, not a development SDK package beside the application.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(_caw_install_sdk_default ON)
else()
  set(_caw_install_sdk_default OFF)
endif()
option(CAW_INSTALL_SDK "Install the public C++ SDK CMake package" ${_caw_install_sdk_default})
if(CAW_INSTALL_SDK)
  set(CAW_SDK_VERSION 1.0.0)
  set(CAW_SDK_CMAKE_DIR "${CMAKE_INSTALL_LIBDIR}/cmake/CAW")
  configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CAWConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/CAWConfig.cmake"
    INSTALL_DESTINATION "${CAW_SDK_CMAKE_DIR}"
  )
  write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/CAWConfigVersion.cmake"
    VERSION "${CAW_SDK_VERSION}"
    COMPATIBILITY SameMajorVersion
  )
  install(TARGETS caw_sdk EXPORT CAWSDKTargets)
  install(EXPORT CAWSDKTargets NAMESPACE CAW:: DESTINATION "${CAW_SDK_CMAKE_DIR}")
  install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CAWComponent.cmake"
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CAWClap.cmake"
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CAWVst3.cmake"
    DESTINATION "${CAW_SDK_CMAKE_DIR}")
  install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/plugin/clap/caw_clap_entry.cpp"
    DESTINATION "${CAW_SDK_CMAKE_DIR}/clap")
  install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/plugin/vst3/caw_vst3_entry.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/plugin/vst3/caw_vst3_iids.cpp"
    DESTINATION "${CAW_SDK_CMAKE_DIR}/vst3")
  install(DIRECTORY include/caw/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/caw")
  install(FILES include/caw_component.h DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
  install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/CAWConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/CAWConfigVersion.cmake"
    DESTINATION "${CAW_SDK_CMAKE_DIR}"
  )
endif()

# Determinism: no fast-math and no fused multiply-add contraction, so every platform rounds alike.
# -fno-trapping-math changes no result (the engine never reads floating-point exception flags; it is
# Clang's default): it lets GCC vectorize loops with selects, such as the mixer's saturating sums.
# MSVC's /fp:precise never contracts; clang-cl's does, so it also gets /clang:-ffp-contract=off.
if(MSVC)
  set(CAW_FLAGS /W4 /fp:precise /utf-8 /EHsc)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    list(APPEND CAW_FLAGS /clang:-ffp-contract=off)
  endif()
else()
  set(CAW_FLAGS -Wall -Wextra -ffp-contract=off -fno-fast-math -fno-trapping-math)
endif()
# Build speed only (the output is the same): Visual Studio builds compile one file at a time per target
# unless asked; /MP compiles a target's files in parallel.
if(MSVC AND CMAKE_CXX_COMPILER_ID STREQUAL "MSVC" AND CMAKE_GENERATOR MATCHES "Visual Studio")
  add_compile_options(/MP)
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
  src/builtins.cpp src/compile.cpp src/docs.cpp src/pattern.cpp
  src/engine.cpp src/component_chain.cpp src/builtin_components.cpp src/builtin_instruments.cpp src/builtin_drums.cpp src/builtin_drums_params.cpp src/builtin_drums_sounds.cpp src/component_samples.cpp src/builtin_flagship.cpp src/builtin_test_signal.cpp src/presets.cpp src/builtin_effects.cpp src/builtin_effects_eq.cpp src/builtin_effects_dynamics.cpp src/builtin_effects_space.cpp src/builtin_effects_saturator.cpp src/builtin_effects_kit.cpp src/builtin_ducker.cpp src/builtin_fx_creative.cpp src/builtin_fx_creative_tapestop.cpp src/builtin_fx_creative_reverser.cpp src/builtin_fx_creative_trancegate.cpp src/builtin_fx_creative_stutter.cpp src/builtin_fx_creative_bitcrush.cpp src/builtin_fx_creative_pitchshift.cpp src/builtin_fx_creative_freqshift.cpp src/builtin_fx_creative_ringmod.cpp src/builtin_fx_creative_presets.cpp src/builtin_fx_space_mod.cpp src/builtin_fx_space_stereo.cpp src/builtin_fx_space_reverb.cpp src/builtin_fx_space_presets.cpp src/execution.cpp src/module.cpp src/module_registry.cpp src/midi2.cpp src/midi_device.cpp src/params.cpp src/graph.cpp src/scheduler.cpp src/dependency.cpp src/hardware.cpp src/json.cpp src/midifile.cpp src/project.cpp
  # fx-filters begin
  src/builtin_fx_filters.cpp src/builtin_fx_filters_comb.cpp src/builtin_fx_filters_formant.cpp src/builtin_fx_filters_eq.cpp src/builtin_fx_filters_presets.cpp
  # fx-filters end
  src/render.cpp src/render_stems.cpp src/synth.cpp src/tables.cpp src/vm.cpp src/wav.cpp
  "${CAW_TEMPLATES_CPP}" "${CAW_STDLIB_CPP}")
# fx-racks begin
target_sources(caw_core PRIVATE src/builtin_fx_racks.cpp src/builtin_fx_racks_fx.cpp src/builtin_fx_racks_multiband.cpp
  src/builtin_fx_racks_presets.cpp)
# fx-racks end
target_include_directories(caw_core PRIVATE src)
target_compile_options(caw_core PRIVATE ${CAW_FLAGS})
find_package(Threads REQUIRED)
target_link_libraries(caw_core PUBLIC CAW::SDK Threads::Threads ${CMAKE_DL_LIBS})
set_target_properties(caw_core PROPERTIES CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
# The component testing suite (#163): offline measurements of C++ effects.
target_sources(caw_core PRIVATE src/analysis.cpp src/component_test.cpp)
target_sources(caw_core PRIVATE src/sample_pack.cpp)  # the sample-pack maker (#164)
target_sources(caw_core PRIVATE src/meters.cpp)  # live loudness, true peak and correlation meters (roadmap 2.6)
# fx-dynamics begin: the Dynamics and Drive effects
# Audio assets, clips, the sampler and audio input (WP-J); miniaudio's decoders compiled privately (static).
target_sources(caw_core PRIVATE src/asset_store.cpp src/time_stretch.cpp src/audio_clips.cpp src/audio_input.cpp
  src/builtin_sampler.cpp src/builtin_sampler_sfz.cpp platform/decode_miniaudio.c)
set_source_files_properties(platform/decode_miniaudio.c PROPERTIES COMPILE_OPTIONS "-w"
  INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio")
target_sources(caw_core PRIVATE src/builtin_fx_dynamics.cpp src/builtin_fx_drive.cpp src/builtin_fx_dynamics_presets.cpp)
# fx-dynamics end


# The library the app loads through dart:ffi.
if(CAW_AUDIO)
  add_library(caw_engine SHARED src/capi.cpp src/capi_audio.cpp src/execution_capi.cpp src/worker_api.cpp platform/audio_miniaudio.cpp platform/miniaudio_impl.c)
  target_include_directories(caw_engine PRIVATE src third_party/miniaudio)
  target_compile_options(caw_engine PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${CAW_FLAGS}>)
  if(ANDROID)
    target_link_libraries(caw_engine PRIVATE log)
  endif()
  if(UNIX AND NOT APPLE AND NOT ANDROID)
    target_link_libraries(caw_engine PRIVATE dl m)
  endif()
else()
  add_library(caw_engine SHARED src/capi.cpp src/capi_audio.cpp src/execution_capi.cpp src/worker_api.cpp platform/audio_none.cpp)
  target_compile_options(caw_engine PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_engine PRIVATE src)
endif()
target_link_libraries(caw_engine PRIVATE caw_core)

# The file is libcaw.so / caw.dll; only the C API (marked CAW_API) is exported.
set_target_properties(caw_engine PROPERTIES OUTPUT_NAME caw CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden)

if(CAW_TOOLS)
  add_executable(caw_cli cli/main.cpp platform/audio_none.cpp)
  # The CLI and the engine DLL are both named caw; on Windows the CLI exports the C API too, so its import library
  # (caw.lib/caw.exp) would collide with the DLL's in a parallel build. Give the CLI's import library its own name.
  set_target_properties(caw_cli PROPERTIES OUTPUT_NAME caw ARCHIVE_OUTPUT_NAME caw_cli)
  target_compile_options(caw_cli PRIVATE ${CAW_FLAGS})
target_include_directories(caw_cli PRIVATE src)
  target_link_libraries(caw_cli PRIVATE caw_core)
  add_executable(caw_tests tests/test_main.cpp tests/language_test.cpp tests/engine_test.cpp tests/export_test.cpp
    tests/golden_test.cpp tests/variables_test.cpp tests/library_test.cpp tests/pattern_test.cpp
    tests/midifile_test.cpp tests/midi2_test.cpp tests/module_registry_test.cpp tests/native_component_test.cpp tests/synth_test.cpp tests/execution_test.cpp tests/execution_capi_test.cpp tests/module_test.cpp tests/graph_test.cpp tests/params_test.cpp tests/sdk_header_test.cpp tests/scheduler_test.cpp tests/dependency_test.cpp tests/hardware_test.cpp tests/worker_api_test.cpp tests/mix_golden_test.cpp tests/public_cpp_sdk_test.cpp tests/track_components_test.cpp tests/instrument_test.cpp tests/builtin_instruments_test.cpp
    src/capi.cpp src/capi_audio.cpp src/execution_capi.cpp src/worker_api.cpp platform/audio_none.cpp)
  target_sources(caw_tests PRIVATE tests/component_test_test.cpp)  # the component testing suite (#163)
  target_sources(caw_tests PRIVATE tests/test_signal_test.cpp)  # org.caw.test.osc, the internal test signal
  target_sources(caw_tests PRIVATE tests/sample_pack_test.cpp)  # the sample-pack maker (#164)
  target_sources(caw_tests PRIVATE tests/library_kernels_test.cpp)  # Library LFO, wavetable, reverb, smoothers
  target_sources(caw_tests PRIVATE tests/flagship_test.cpp)  # the flagship synth (#171) and its kernels
  target_sources(caw_tests PRIVATE tests/quality_test.cpp)  # the quality setting (Eco, Normal, High) and the buffer mode
  target_sources(caw_tests PRIVATE tests/display_test.cpp)  # live display data, engine to UI (#173)
  target_sources(caw_tests PRIVATE tests/effects_test.cpp)  # the built-in effects suite (#173)
  target_sources(caw_tests PRIVATE tests/routing_test.cpp)  # sends, buses, keys and routing loops (#175)
  target_sources(caw_tests PRIVATE tests/drums_test.cpp)  # org.caw.drums: 64 pads, layers, presets, samples, migration
  target_sources(caw_tests PRIVATE tests/ducker_test.cpp)  # the ducker driven directly (#175 audio review)
  target_sources(caw_tests PRIVATE tests/stereo_path_test.cpp)  # stereo end to end: buses and WAV export (#17, #121)
  target_sources(caw_tests PRIVATE tests/meters_test.cpp)  # loudness (BS.1770-5, EBU Tech 3341), true peak, correlation
  target_sources(caw_tests PRIVATE tests/render_stems_test.cpp)  # song renders: stems, bounds, tail, normalise, dither, parity
  target_sources(caw_tests PRIVATE tests/fx_dynamics_test.cpp)  # fx-dynamics: the Dynamics and Drive effects
  target_sources(caw_tests PRIVATE tests/fx_creative_test.cpp)  # fx-creative: the Creative and Pitch & Time effects
  target_sources(caw_tests PRIVATE tests/fx_space_test.cpp)  # fx-space: Space, Modulation and Utility effects
  # fx-filters begin
  target_sources(caw_tests PRIVATE tests/fx_filters_test.cpp)  # the EQ & Filter group
  # fx-filters end
  target_sources(caw_tests PRIVATE tests/fx_racks_test.cpp)  # fx-racks: the FX and multiband racks
  target_sources(caw_tests PRIVATE tests/midi_device_test.cpp)
  target_sources(caw_tests PRIVATE tests/audio_assets_test.cpp)  # assets, audio clips, the sampler, SFZ, input (WP-J)  # MIDI from devices (API 15): edge conversion, timing, notes
  add_library(caw_test_component MODULE tests/native_component_fixture.cpp)
  target_link_libraries(caw_test_component PRIVATE CAW::SDK)
  target_compile_options(caw_test_component PRIVATE ${CAW_FLAGS})
  set_target_properties(caw_test_component PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component")
  add_library(caw_test_component_no_entry MODULE tests/native_component_fixture.cpp)
  target_link_libraries(caw_test_component_no_entry PRIVATE CAW::SDK)
  target_compile_options(caw_test_component_no_entry PRIVATE ${CAW_FLAGS})
  target_compile_definitions(caw_test_component_no_entry PRIVATE CAW_TEST_OMIT_ENTRY)
  set_target_properties(caw_test_component_no_entry PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component_no_entry")
  # The component C interface compiles as plain C.
  add_library(caw_component_c_check OBJECT tests/component_header_check.c)
  target_include_directories(caw_component_c_check PRIVATE include)
  set_target_properties(caw_component_c_check PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
  add_dependencies(caw_tests caw_test_component caw_test_component_no_entry caw_component_c_check)
  target_compile_options(caw_tests PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_tests PRIVATE src)
  target_compile_definitions(caw_tests PRIVATE CAW_ROOT="${CAW_ROOT}"
    "CAW_TEST_COMPONENT_PATH_DEFAULT=\"$<TARGET_FILE:caw_test_component>\""
    "CAW_TEST_NO_ENTRY_COMPONENT_PATH=\"$<TARGET_FILE:caw_test_component_no_entry>\"")
  target_link_libraries(caw_tests PRIVATE caw_core)
  # Compile the consumer test with only CAW::SDK's public include path; no engine/src access.
  add_library(caw_sdk_public_compile OBJECT tests/public_cpp_sdk_test.cpp)
  target_link_libraries(caw_sdk_public_compile PRIVATE CAW::SDK)
  target_compile_options(caw_sdk_public_compile PRIVATE ${CAW_FLAGS})
  add_dependencies(caw_tests caw_sdk_public_compile)
  enable_testing()
  # Split the suite into independent processes so CTest can run shards concurrently.
  # Process isolation avoids sharing test state while keeping every case enabled.
  set(CAW_TEST_SHARDS 4)
  foreach(shard RANGE 0 3)
    add_test(NAME caw_tests_shard_${shard}
      COMMAND ${CMAKE_COMMAND} -E env "CAW_TEST_COMPONENT_PATH=$<TARGET_FILE:caw_test_component>"
        "$<TARGET_FILE:caw_tests>" --shard-index ${shard} --shard-count ${CAW_TEST_SHARDS})
  endforeach()
  set_tests_properties(caw_tests_shard_0 caw_tests_shard_1 caw_tests_shard_2 caw_tests_shard_3
    PROPERTIES PROCESSORS 1)
  # Real-time contract tests in their own binary: it replaces global operator new/delete to count
  # allocations, which would turn off AddressSanitizer's new/delete mismatch checks in caw_tests.
  add_executable(caw_rt_tests tests/test_main.cpp tests/graph_channels_test.cpp tests/engine_rt_test.cpp
                              tests/alloc_counter.cpp)
  target_sources(caw_rt_tests PRIVATE tests/fx_space_rt_test.cpp)  # fx-space effects: no allocation on the audio thread
  target_sources(caw_rt_tests PRIVATE tests/fx_racks_rt_test.cpp)
  target_sources(caw_rt_tests PRIVATE tests/audio_rt_test.cpp)  # audio clips, the sampler, monitoring and recording (WP-J)  # fx-racks
  target_compile_options(caw_rt_tests PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_rt_tests PRIVATE src)
  add_dependencies(caw_rt_tests caw_test_component)
  target_compile_definitions(caw_rt_tests PRIVATE CAW_ROOT="${CAW_ROOT}"
    "CAW_TEST_COMPONENT_PATH_DEFAULT=\"$<TARGET_FILE:caw_test_component>\"")
  target_link_libraries(caw_rt_tests PRIVATE caw_core)
  add_test(NAME caw_rt_tests COMMAND caw_rt_tests)
  
  # Times the engine like an audio callback (see docs/performance.md); run it on a release build.
add_executable(caw_bench bench/caw_bench.cpp src/capi.cpp platform/audio_none.cpp)
  target_compile_options(caw_bench PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_bench PRIVATE src)
  target_link_libraries(caw_bench PRIVATE caw_core)
endif()

# CLAP export (docs/native-module-sdk.md): plug-ins of the example and a test bundle, and a host test.
if(CAW_CLAP AND CAW_TOOLS)
  include(cmake/CAWClap.cmake)
  add_subdirectory(plugin/clap)
endif()
# VST3 export (docs/native-module-sdk.md): the same plug-ins as .vst3 bundles, and a host test.
if(CAW_VST3 AND CAW_TOOLS)
  include(cmake/CAWVst3.cmake)
  add_subdirectory(plugin/vst3)
endif()
