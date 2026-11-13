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
option(CAW_TSAN "Build with ThreadSanitizer (Clang; the mix pool's stress test, engine.yml)" OFF)
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
# The engine's own targets (CAW_ENGINE_FP_FLAGS, set at the end of this file) skip these and use CAW_FP_FLAGS:
# an interface option comes after a target's own on the command line, so it would override them.
set(_caw_sdk_fp "$<NOT:$<BOOL:$<TARGET_PROPERTY:CAW_ENGINE_FP_FLAGS>>>")
target_compile_options(caw_sdk INTERFACE
  "$<$<AND:${_caw_sdk_fp},$<COMPILE_LANG_AND_ID:CXX,MSVC>>:/fp:precise>"
  "$<$<AND:${_caw_sdk_fp},$<COMPILE_LANG_AND_ID:CXX,GNU,AppleClang>>:-ffp-contract=off;-fno-fast-math;-fno-trapping-math>")
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    target_compile_options(caw_sdk INTERFACE "$<BUILD_INTERFACE:$<${_caw_sdk_fp}:/fp:precise;/clang:-ffp-contract=off>>")
  else()
    target_compile_options(caw_sdk INTERFACE "$<BUILD_INTERFACE:$<${_caw_sdk_fp}:-ffp-contract=off;-fno-fast-math;-fno-trapping-math>>")
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

# Floating point (speed phase 2, docs/engine.md "Determinism"): output must sound the same, not give the same bits
# (owner, 2026-11-12), so the engine's own code gets the fast-math subsets that measured faster and pass every
# reference render: fused multiply-adds (-ffp-contract=fast; Arm64 has FMA, the x86-64 baseline has none, so no
# change there), no errno from maths functions, no trapping, no signed zeros and reassociation (GCC reassociates only
# with those two). Never -ffinite-math-only: the mix's NaN/Inf guards (route_math.h, finiteOr0) must stay, and
# fp_mode_test.cpp checks them under these flags. Left out: -freciprocal-math (no gain). MSVC keeps /fp:precise
# (clang-cl also /clang:-ffp-contract=off): Windows isn't the speed target, and /fp:fast's NaN handling is unchecked.
# _caw_fp_strict is the SDK's strict set: components get it (CAW::SDK above), and so do tests of exact IEEE results.
if(MSVC)
  set(_caw_fp_strict /fp:precise)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    list(APPEND _caw_fp_strict /clang:-ffp-contract=off)
  endif()
  set(_caw_fp_default ${_caw_fp_strict})
else()
  # -fno-trapping-math changes no result (nothing reads floating-point exception flags; it is Clang's default).
  set(_caw_fp_strict -ffp-contract=off -fno-fast-math -fno-trapping-math)
  set(_caw_fp_default -ffp-contract=fast -fno-math-errno -fno-trapping-math -fno-signed-zeros -fassociative-math)
endif()
# -DCAW_FP_FLAGS=... (a ;-list) overrides them, to measure a flag or build strictly.
if(NOT DEFINED CAW_FP_FLAGS)
  set(CAW_FP_FLAGS ${_caw_fp_default})
endif()
if(MSVC)
  set(CAW_FLAGS /W4 ${CAW_FP_FLAGS} /utf-8 /EHsc)
else()
  set(CAW_FLAGS -Wall -Wextra ${CAW_FP_FLAGS})
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
if(CAW_TSAN)
  if(CAW_SANITIZE OR MSVC OR NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    message(FATAL_ERROR "CAW_TSAN needs Clang (not MSVC) and can't be combined with CAW_SANITIZE")
  endif()
  add_compile_options(-fsanitize=thread -fno-omit-frame-pointer -g)
  add_link_options(-fsanitize=thread)
endif()
# Link-time optimisation (speed phase 1, docs/engine-performance.md): every engine target in an optimised
# configuration (Release, RelWithDebInfo: Android Gradle's release, MinSizeRel), when the toolchain supports it.
# Debug and sanitizer builds stay without it. Set here, so it reaches only this directory's targets (the app's
# Windows build includes the engine as a subdirectory). On by default for Clang (the Android NDK's) and MSVC;
# off for GCC (and MinGW), where it measured slower (more instructions, a slower Linux x64 bench); CAW_LTO sets it.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  set(CAW_LTO_DEFAULT OFF)
else()
  set(CAW_LTO_DEFAULT ON)
endif()
option(CAW_LTO "Link-time optimisation for optimised (non-Debug) builds" ${CAW_LTO_DEFAULT})
if(CAW_LTO AND NOT CAW_SANITIZE AND NOT CAW_TSAN)
  include(CheckIPOSupported)
  check_ipo_supported(RESULT CAW_IPO_SUPPORTED OUTPUT CAW_IPO_OUTPUT LANGUAGES C CXX)
  if(CAW_IPO_SUPPORTED)
    foreach(config RELEASE RELWITHDEBINFO MINSIZEREL PROFILE)  # PROFILE: the Flutter Windows app's profile build
      set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_${config} ON)
    endforeach()
  else()
    message(STATUS "C.A.W: no link-time optimisation with this toolchain: ${CAW_IPO_OUTPUT}")
  endif()
endif()


add_library(caw_core STATIC
  src/pattern.cpp
  src/engine.cpp src/component_chain.cpp src/builtin_components.cpp src/builtin_instruments.cpp src/builtin_drums.cpp src/builtin_drums_params.cpp src/builtin_drums_sounds.cpp src/component_samples.cpp src/builtin_flagship.cpp src/builtin_test_signal.cpp src/presets.cpp src/builtin_effects.cpp src/builtin_effects_eq.cpp src/builtin_effects_dynamics.cpp src/builtin_effects_space.cpp src/builtin_effects_saturator.cpp src/builtin_effects_kit.cpp src/builtin_ducker.cpp src/builtin_fx_creative.cpp src/builtin_fx_creative_tapestop.cpp src/builtin_fx_creative_reverser.cpp src/builtin_fx_creative_trancegate.cpp src/builtin_fx_creative_stutter.cpp src/builtin_fx_creative_bitcrush.cpp src/builtin_fx_creative_pitchshift.cpp src/builtin_fx_creative_freqshift.cpp src/builtin_fx_creative_ringmod.cpp src/builtin_fx_creative_presets.cpp src/builtin_fx_space_mod.cpp src/builtin_fx_space_stereo.cpp src/builtin_fx_space_reverb.cpp src/builtin_fx_space_presets.cpp src/execution.cpp src/module.cpp src/module_registry.cpp src/midi2.cpp src/midi_device.cpp src/params.cpp src/graph.cpp src/scheduler.cpp src/dependency.cpp src/hardware.cpp src/json.cpp src/midifile.cpp src/project.cpp
  # fx-filters begin
  src/builtin_fx_filters.cpp src/builtin_fx_filters_comb.cpp src/builtin_fx_filters_formant.cpp src/builtin_fx_filters_eq.cpp src/builtin_fx_filters_presets.cpp
  # fx-filters end
  src/render.cpp src/render_stems.cpp src/wav.cpp)
# The Benchmark (stress test, beta plan C): its scenarios (shared with caw_bench) and its timed runs.
target_sources(caw_core PRIVATE src/stress_scenarios.cpp src/stress_run.cpp)
# fx-racks begin
target_sources(caw_core PRIVATE src/builtin_fx_racks.cpp src/builtin_fx_racks_fx.cpp src/builtin_fx_racks_multiband.cpp
  src/builtin_fx_racks_presets.cpp)
# fx-racks end
# modulators begin (#161: project modulation, its built-in modulators)
target_sources(caw_core PRIVATE src/modulation_links.cpp src/builtin_modulators.cpp)
# modulators end
target_sources(caw_core PRIVATE src/sample_time.cpp)  # sample positions of steps and seconds, built strict (below)
target_sources(caw_core PRIVATE src/mix_pool.cpp)  # speed phase 5c: the mix graph's real-time worker pool
# Speed phase 5d: thread priorities, affinity and hints for the pool and the callback, one platform file each.
if(WIN32)
  set(CAW_THREAD_TUNING platform/thread_tuning_win.cpp)
elseif(CMAKE_SYSTEM_NAME MATCHES "Linux|Android")
  set(CAW_THREAD_TUNING platform/thread_tuning_posix.cpp)
else()
  set(CAW_THREAD_TUNING platform/thread_tuning_none.cpp)
endif()
target_sources(caw_core PRIVATE src/thread_tuning.cpp ${CAW_THREAD_TUNING})
target_sources(caw_core PRIVATE src/note_fx_host.cpp)  # per-note FX (#127): slot racks, the voice-bus host, the manager
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
  add_library(caw_engine SHARED src/capi.cpp src/capi_audio.cpp src/capi_modulation.cpp src/execution_capi.cpp src/worker_api.cpp src/capi_stress.cpp platform/audio_miniaudio.cpp platform/miniaudio_impl.c)
  target_include_directories(caw_engine PRIVATE src third_party/miniaudio)
  target_compile_options(caw_engine PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${CAW_FLAGS}>)
  if(ANDROID)
    target_link_libraries(caw_engine PRIVATE log)
  endif()
  if(UNIX AND NOT APPLE AND NOT ANDROID)
    target_link_libraries(caw_engine PRIVATE dl m)
  endif()
else()
  add_library(caw_engine SHARED src/capi.cpp src/capi_audio.cpp src/capi_modulation.cpp src/execution_capi.cpp src/worker_api.cpp src/capi_stress.cpp platform/audio_none.cpp)
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
  add_executable(caw_tests tests/test_main.cpp tests/engine_test.cpp tests/export_test.cpp tests/pattern_test.cpp
    tests/midifile_test.cpp tests/midi2_test.cpp tests/module_registry_test.cpp tests/native_component_test.cpp tests/execution_test.cpp tests/execution_capi_test.cpp tests/module_test.cpp tests/graph_test.cpp tests/params_test.cpp tests/sdk_header_test.cpp tests/scheduler_test.cpp tests/dependency_test.cpp tests/hardware_test.cpp tests/worker_api_test.cpp tests/mix_reference_test.cpp tests/public_cpp_sdk_test.cpp tests/track_components_test.cpp tests/instrument_test.cpp tests/builtin_instruments_test.cpp
    src/capi.cpp src/capi_audio.cpp src/capi_modulation.cpp src/execution_capi.cpp src/worker_api.cpp src/capi_stress.cpp platform/audio_none.cpp)
  target_sources(caw_tests PRIVATE tests/tolerance.cpp tests/tolerance_test.cpp)  # reference renders, their comparators
  target_sources(caw_tests PRIVATE tests/component_test_test.cpp)  # the component testing suite (#163)
  target_sources(caw_tests PRIVATE tests/test_signal_test.cpp)  # org.caw.test.osc, the internal test signal
  target_sources(caw_tests PRIVATE tests/sample_pack_test.cpp)  # the sample-pack maker (#164)
  target_sources(caw_tests PRIVATE tests/flagship_test.cpp)  # the flagship synth (#171) and its kernels
  target_sources(caw_tests PRIVATE tests/flagship_tables_test.cpp)  # its warps' aliasing and its user wavetable
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
  target_sources(caw_tests PRIVATE tests/note_fx_test.cpp)  # per-note FX (#127): slots, overflow, tails, parity
  # fx-filters end
  target_sources(caw_tests PRIVATE tests/fx_racks_test.cpp)  # fx-racks: the FX and multiband racks
  target_sources(caw_tests PRIVATE tests/modulation_test.cpp)  # #161: project modulators and links
  target_sources(caw_tests PRIVATE tests/midi_device_test.cpp)  # MIDI from devices (API 15): edge conversion, timing, notes
  target_sources(caw_tests PRIVATE tests/graph_layout_test.cpp)  # #120 layout rules: mono to stereo, downmix, dual mono
  target_sources(caw_tests PRIVATE tests/voice_bus_test.cpp)  # #127 the voice bus; #120 built-in declarations, C 3.0/3.1
  target_sources(caw_tests PRIVATE tests/audio_assets_test.cpp)  # assets, audio clips, the sampler, SFZ, input (WP-J)
  target_sources(caw_tests PRIVATE tests/input_bridge_test.cpp)  # the input bridge: output unchanged when the input dies
  target_sources(caw_tests PRIVATE tests/speed_free_wins_test.cpp)  # speed phase 1: Eco oversampling, silent work skipped, master sleep
  target_sources(caw_tests PRIVATE tests/fp_mode_test.cpp)  # speed phase 2: the flush-to-zero guard, NaN/Inf guards under the build flags
  target_sources(caw_tests PRIVATE tests/sample_timing_test.cpp tests/timing_oracle.cpp)  # note timing exact to the sample
  target_sources(caw_tests PRIVATE tests/stress_test.cpp)  # the Benchmark (beta plan C): scenarios, ramps, cancel, profiles
  target_sources(caw_tests PRIVATE tests/mix_graph_test.cpp)  # speed phase 5a/5b: pulled routes, per-node scratch, graph levels
  target_sources(caw_tests PRIVATE tests/mix_pool_test.cpp)  # speed phase 5c: the mix pool, parallel levels, the serial lane
  add_library(caw_test_component MODULE tests/native_component_fixture.cpp)
  target_link_libraries(caw_test_component PRIVATE CAW::SDK)
  target_compile_options(caw_test_component PRIVATE ${CAW_FLAGS})
  set_target_properties(caw_test_component PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component")
  add_library(caw_test_component_no_entry MODULE tests/native_component_fixture.cpp)
  target_link_libraries(caw_test_component_no_entry PRIVATE CAW::SDK)
  target_compile_options(caw_test_component_no_entry PRIVATE ${CAW_FLAGS})
  target_compile_definitions(caw_test_component_no_entry PRIVATE CAW_TEST_OMIT_ENTRY)
  set_target_properties(caw_test_component_no_entry PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component_no_entry")
  # A component built against the 3.0 C interface (a descriptor without the 3.1 fields), in plain C.
  add_library(caw_test_component_v30 MODULE tests/native_component_v30_fixture.c)
  target_include_directories(caw_test_component_v30 PRIVATE include)
  set_target_properties(caw_test_component_v30 PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component_v30"
    C_STANDARD 99 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
  # The example modulator (examples/cpp/modulator, #161), loaded by modulation_test.cpp as a user's C++ modulator.
  add_library(caw_test_modulator MODULE ../examples/cpp/modulator/src/euclid_modulator.cpp)
  target_link_libraries(caw_test_modulator PRIVATE CAW::SDK)
  target_compile_options(caw_test_modulator PRIVATE ${CAW_FLAGS})
  set_target_properties(caw_test_modulator PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_modulator")
  add_dependencies(caw_tests caw_test_modulator)
  # The component C interface compiles as plain C.
  add_library(caw_component_c_check OBJECT tests/component_header_check.c)
  target_include_directories(caw_component_c_check PRIVATE include)
  set_target_properties(caw_component_c_check PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
  add_dependencies(caw_tests caw_test_component caw_test_component_no_entry caw_test_component_v30 caw_component_c_check)
  target_compile_options(caw_tests PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_tests PRIVATE src)
  target_compile_definitions(caw_tests PRIVATE CAW_ROOT="${CAW_ROOT}"
    "CAW_TEST_COMPONENT_PATH_DEFAULT=\"$<TARGET_FILE:caw_test_component>\""
    "CAW_TEST_NO_ENTRY_COMPONENT_PATH=\"$<TARGET_FILE:caw_test_component_no_entry>\""
    "CAW_TEST_V30_COMPONENT_PATH=\"$<TARGET_FILE:caw_test_component_v30>\""
    "CAW_TEST_MODULATOR_PATH=\"$<TARGET_FILE:caw_test_modulator>\"")
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
  # Each shard runs the mix graph on one thread and writes every reference render's raw-bit digest; the parallel
  # shards run the same tests with every Engine's mix graph on 3 workers (speed phase 5c), and
  # caw_parallel_identity checks that every render has the same bits both ways.
  set(CAW_DIGEST_DIR "${CMAKE_CURRENT_BINARY_DIR}/render_digests")
  foreach(shard RANGE 0 3)
    add_test(NAME caw_tests_shard_${shard}
      COMMAND ${CMAKE_COMMAND} -E env "CAW_TEST_COMPONENT_PATH=$<TARGET_FILE:caw_test_component>"
        "CAW_RENDER_DIGEST=${CAW_DIGEST_DIR}/serial_${shard}.txt"
        "$<TARGET_FILE:caw_tests>" --shard-index ${shard} --shard-count ${CAW_TEST_SHARDS} --mix-threads 0)
    add_test(NAME caw_tests_parallel_shard_${shard}
      COMMAND ${CMAKE_COMMAND} -E env "CAW_TEST_COMPONENT_PATH=$<TARGET_FILE:caw_test_component>"
        "CAW_RENDER_DIGEST=${CAW_DIGEST_DIR}/parallel_${shard}.txt"
        "$<TARGET_FILE:caw_tests>" --shard-index ${shard} --shard-count ${CAW_TEST_SHARDS} --mix-threads 3)
    set_tests_properties(caw_tests_shard_${shard} caw_tests_parallel_shard_${shard} PROPERTIES
      PROCESSORS 1 FIXTURES_SETUP caw_render_digests)
  endforeach()
  add_test(NAME caw_parallel_identity
    COMMAND ${CMAKE_COMMAND} -DDIGEST_DIR=${CAW_DIGEST_DIR} -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CompareDigests.cmake")
  set_tests_properties(caw_parallel_identity PROPERTIES FIXTURES_REQUIRED caw_render_digests)
  file(MAKE_DIRECTORY "${CAW_DIGEST_DIR}")
  # Real-time contract tests in their own binary: it replaces global operator new/delete to count
  # allocations, which would turn off AddressSanitizer's new/delete mismatch checks in caw_tests.
  add_executable(caw_rt_tests tests/test_main.cpp tests/graph_channels_test.cpp tests/engine_rt_test.cpp
                              tests/alloc_counter.cpp)
  target_sources(caw_rt_tests PRIVATE tests/fx_space_rt_test.cpp)  # fx-space effects: no allocation on the audio thread
  target_sources(caw_rt_tests PRIVATE tests/fx_racks_rt_test.cpp)  # fx-racks
  target_sources(caw_rt_tests PRIVATE tests/voice_bus_rt_test.cpp)  # #127: instruments rendering into voice-bus lanes
  target_sources(caw_rt_tests PRIVATE tests/audio_rt_test.cpp)  # audio clips, the sampler, monitoring and recording (WP-J)
  target_sources(caw_rt_tests PRIVATE tests/modulation_rt_test.cpp)  # #161: project modulation
  target_sources(caw_rt_tests PRIVATE tests/note_fx_rt_test.cpp)  # #127: per-note FX
  target_sources(caw_rt_tests PRIVATE tests/stress_rt_test.cpp)  # the Benchmark: its timed loop
  target_compile_options(caw_rt_tests PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_rt_tests PRIVATE src)
  add_dependencies(caw_rt_tests caw_test_component)
  target_compile_definitions(caw_rt_tests PRIVATE CAW_ROOT="${CAW_ROOT}"
    "CAW_TEST_COMPONENT_PATH_DEFAULT=\"$<TARGET_FILE:caw_test_component>\"")
  target_link_libraries(caw_rt_tests PRIVATE caw_core)
  add_test(NAME caw_rt_tests COMMAND caw_rt_tests)
  # The Library as components get it: built with CAW::SDK's strict floating point (this target takes no
  # CAW_FP_FLAGS), its exact bits and signed zeros checked. Header-only, so it links nothing of caw_core: caw_tests and
  # caw_rt_tests hold only code built with the engine's flags, and this only strict code (an inline function compiled
  # both ways in one program leaves the linker to pick one copy for every caller).
  add_executable(caw_exact_tests tests/test_main.cpp tests/library_kernels_test.cpp  # LFO, wavetable, reverb, smoothers
                                 tests/library_exact_test.cpp)  # oscillators, fast maths, filters, envelopes, drum voices
  target_link_libraries(caw_exact_tests PRIVATE CAW::SDK)
  if(MSVC)
    target_compile_options(caw_exact_tests PRIVATE /W4 /utf-8 /EHsc)
  else()
    target_compile_options(caw_exact_tests PRIVATE -Wall -Wextra)
  endif()
  add_test(NAME caw_exact_tests COMMAND caw_exact_tests)
  
  # Times the engine like an audio callback (see docs/performance.md); run it on a release build.
add_executable(caw_bench bench/caw_bench.cpp src/capi.cpp src/capi_modulation.cpp platform/audio_none.cpp)
  target_compile_options(caw_bench PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_bench PRIVATE src)
  target_link_libraries(caw_bench PRIVATE caw_core)
endif()

# The strict reference the timing tests compare with (an option on a source comes after the target's). It includes no
# engine or SDK header, so it shares no inline function with the code caw_tests runs.
if(CAW_TOOLS)
  set_source_files_properties(tests/timing_oracle.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")
endif()
# Sample positions (src/sample_time.h): note, clip, loop and automation timing is exact to the sample on every
# platform, so this file is strict in every build, the app's included: no fused multiply-add, no reassociation.
set_source_files_properties(src/sample_time.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")

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

# The engine's own targets take CAW_FP_FLAGS (in CAW_FLAGS) instead of the SDK's strict floating-point flags: every
# program that links caw_core, the CLAP and VST3 host tests included (set after their subdirectories define them), so
# no program mixes strict and fast copies of one inline function. Components and plug-ins stay strict (CAW::SDK).
foreach(_caw_target caw_core caw_engine caw_cli caw_tests caw_rt_tests caw_bench caw_clap_tests caw_vst3_tests)
  if(TARGET ${_caw_target})
    set_property(TARGET ${_caw_target} PROPERTY CAW_ENGINE_FP_FLAGS ON)
  endif()
endforeach()
