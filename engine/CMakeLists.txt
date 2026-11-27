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
# fp_mode_test.cpp checks them under these flags. Left out: -freciprocal-math (no gain).
# clang-cl (the shipped Windows engine since 2026-11-13, docs/decisions.md) gets the same set and -O3 through /clang:,
# which clang-cl appends after its own options, so a strict file's /clang: negations still come last. MSVC's cl keeps
# /fp:precise: /fp:fast's NaN handling is unchecked.
# _caw_fp_strict is the SDK's strict set: components get it (CAW::SDK above), and so do tests of exact IEEE results.
if(MSVC AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  # /fp:precise alone does not undo /clang:-fno-signed-zeros or reassociation, so the strict set negates each one.
  set(_caw_fp_strict /fp:precise /clang:-ffp-contract=off /clang:-fno-fast-math /clang:-fno-trapping-math
    /clang:-fsigned-zeros /clang:-fno-associative-math)
  set(_caw_fp_default /clang:-ffp-contract=fast /clang:-fno-math-errno /clang:-fno-trapping-math
    /clang:-fno-signed-zeros /clang:-fassociative-math)
  # Linux and Android build Release at -O3; clang-cl's /O2 is -O2.
  add_compile_options("$<$<CONFIG:Release,RelWithDebInfo,Profile>:/clang:-O3>")
elseif(MSVC)
  set(_caw_fp_strict /fp:precise)
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
# A sanitizer build of the engine's test components links the sanitizer runtime: let the pre-load scan allow it
# as a dependency, so the sanitizer and TSan CI jobs can scan those components (never set in a shipped build).
if(CAW_SANITIZE OR CAW_TSAN)
  add_compile_definitions(CAW_SCAN_ALLOW_SANITIZER)
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
  src/engine.cpp src/engine_pool.cpp src/engine_project.cpp src/engine_control.cpp src/component_chain.cpp src/auto_gain.cpp src/builtin_components.cpp src/builtin_instruments.cpp src/builtin_drums.cpp src/builtin_drums_params.cpp src/builtin_drums_sounds.cpp src/drums_acoustic.cpp src/drums_kits.cpp src/component_samples.cpp src/builtin_flagship.cpp src/flagship_banks.cpp src/builtin_flagship_presets.cpp src/builtin_test_signal.cpp src/presets.cpp src/builtin_effects.cpp src/builtin_effects_eq.cpp src/builtin_effects_dynamics.cpp src/builtin_effects_space.cpp src/builtin_effects_saturator.cpp src/builtin_effects_kit.cpp src/builtin_ducker.cpp src/builtin_fx_creative.cpp src/builtin_fx_creative_tapestop.cpp src/builtin_fx_creative_reverser.cpp src/builtin_fx_creative_trancegate.cpp src/builtin_fx_creative_stutter.cpp src/builtin_fx_creative_bitcrush.cpp src/builtin_fx_creative_pitchshift.cpp src/builtin_fx_creative_freqshift.cpp src/builtin_fx_creative_ringmod.cpp src/builtin_fx_creative_presets.cpp src/builtin_fx_space_mod.cpp src/builtin_fx_space_stereo.cpp src/builtin_fx_space_reverb.cpp src/builtin_fx_space_presets.cpp src/execution.cpp src/module.cpp src/module_registry.cpp src/midi2.cpp src/midi_device.cpp src/params.cpp src/graph.cpp src/scheduler.cpp src/dependency.cpp src/hardware.cpp src/json.cpp src/midifile.cpp src/project.cpp src/vca.cpp
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
# FX consolidation (1.0.8): merged devices and the migration of the ids they replace; one file pair per family part.
target_sources(caw_core PRIVATE src/fx_merged.cpp src/fx_migrate.cpp
  src/builtin_fx_merged_dynamics.cpp src/fx_migrate_dynamics.cpp src/builtin_fx_duck.cpp
  src/builtin_fx_talon.cpp src/builtin_fx_hatch.cpp src/builtin_fx_duck_level_carve.cpp src/builtin_fx_dynsplit_presets.cpp  # 1.1.0: the Talon/Hatch/Duck split
  src/builtin_more_presets.cpp  # 1.1.0: presets for the devices that had fewer than 8
  src/builtin_fx_merged_drive.cpp src/fx_migrate_drive.cpp
  src/builtin_fx_merged_eqfilter.cpp src/fx_migrate_eqfilter.cpp
  src/builtin_fx_eq_plume.cpp src/eq_design.cpp src/builtin_fx_filters_wah.cpp  # 1.1.0: the EQ's Linear and Match, the Filter's Wah
  src/builtin_fx_merged_stereomod.cpp src/fx_migrate_stereomod.cpp
  src/builtin_fx_merged_space.cpp src/fx_migrate_space.cpp)
# 1.1.0: new modes of merged devices (Delay, Reverb, Drive, Bit distortion, Convolver).
target_sources(caw_core PRIVATE src/builtin_fx_delay_modes.cpp src/builtin_fx_reverb_modes.cpp
  src/builtin_fx_drive_modes.cpp src/builtin_fx_bits_bitwise.cpp src/builtin_fx_cab.cpp)
# modulators begin (#161: project modulation, its built-in modulators)
target_sources(caw_core PRIVATE src/modulation_links.cpp src/builtin_modulators.cpp)
# modulators end
target_sources(caw_core PRIVATE src/sample_time.cpp)  # sample positions of steps and seconds, built strict (below)
target_sources(caw_core PRIVATE src/tempo_map.cpp)  # the tempo map and time signatures (1.0.3), built strict (below)
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
# Library warming after a native load: the loaded segments (dl_iterate_phdr) or PE sections, one platform file each.
if(WIN32)
  set(CAW_LIBRARY_WARM platform/library_warm_win.cpp)
elseif(CMAKE_SYSTEM_NAME MATCHES "Linux|Android")
  set(CAW_LIBRARY_WARM platform/library_warm_posix.cpp)
else()
  set(CAW_LIBRARY_WARM platform/library_warm_none.cpp)
endif()
target_sources(caw_core PRIVATE ${CAW_LIBRARY_WARM})
target_sources(caw_core PRIVATE src/note_fx_host.cpp)  # per-note FX (#127): slot racks, the voice-bus host, the manager
target_sources(caw_core PRIVATE src/patch.cpp src/patch_nodes.cpp)  # the patch model (routing plan step 3; not yet used)
target_include_directories(caw_core PRIVATE src)
target_compile_options(caw_core PRIVATE ${CAW_FLAGS})
find_package(Threads REQUIRED)
target_link_libraries(caw_core PUBLIC CAW::SDK Threads::Threads ${CMAKE_DL_LIBS})
set_target_properties(caw_core PROPERTIES CXX_VISIBILITY_PRESET hidden C_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
# The component testing suite (#163): offline measurements of C++ effects.
target_sources(caw_core PRIVATE src/analysis.cpp src/component_test.cpp)
target_sources(caw_core PRIVATE src/component_profile.cpp src/component_bench.cpp)  # the plug-in benchmark (#197)
target_sources(caw_core PRIVATE src/sample_pack.cpp)  # the sample-pack maker (#164)
target_sources(caw_core PRIVATE src/midi_fx.cpp src/midi_fx_effects.cpp)  # 1.1.0: MIDI effects before an instrument
target_sources(caw_core PRIVATE src/builtin_fx_meters.cpp src/builtin_fx_lofi.cpp src/builtin_fx_phasealign.cpp)  # 1.1.0: Meters, Lo-fi, Phase align
target_sources(caw_core PRIVATE src/builtin_fx_voice.cpp src/builtin_fx_exciter.cpp src/builtin_fx_shift_voices.cpp src/builtin_fx_vocoder.cpp)  # 1.1.0: Glint, Mimic, Soar's Harmonizer and Octaver
target_sources(caw_core PRIVATE src/builtin_fx_lark.cpp src/lark_editor.cpp)  # 1.1.0: Lark (org.caw.pitchfix) and the clip pitch editor's engine
target_sources(caw_core PRIVATE src/builtin_fx_preen.cpp src/builtin_fx_preen_denoise.cpp src/builtin_fx_hush.cpp)  # 1.1.0: Preen and Hush (clean-up)
target_sources(caw_core PRIVATE src/builtin_pack.cpp src/builtin_pack_murmur.cpp src/builtin_pack_peck.cpp src/builtin_pack_bend.cpp src/builtin_pack_iris.cpp)  # 1.1.0: the AutoStacc beta pack
target_sources(caw_core PRIVATE src/timber_migrate.cpp)  # Timber's load-time alias (Timber removed in 1.1.3; its model library, timber_*.h, is what Starling, Nightingale, Curlew, Woodpecker and Bittern build on)
target_sources(caw_core PRIVATE src/starling_piano_tables.cpp src/starling_piano_sim.cpp)  # the piano model (Starling's; Timber's Simulated piano, 1.1.2): its tables (generated: tools/starling_piano_gen.cpp) and per-sample code
# 1.1.3: Starling (org.caw.starling) and the recorded parts built into the engine (engine/assets/, embedded by
# cmake/EmbedFile.cmake; decoded on first use by recorded_bank.cpp).
set(_caw_assets_out "${CMAKE_CURRENT_BINARY_DIR}/assets")
set(_caw_embed_piano "${_caw_assets_out}/starling_piano_flac.cpp")
add_custom_command(OUTPUT "${_caw_embed_piano}"
  COMMAND ${CMAKE_COMMAND} -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/assets/starling/piano.flac -DOUTPUT=${_caw_embed_piano}
    -DSYMBOL=starling_piano_flac -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/assets/starling/piano.flac ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  COMMENT "Embedding Starling's recorded piano parts" VERBATIM)
target_sources(caw_core PRIVATE src/builtin_starling.cpp src/recorded_bank.cpp "${_caw_embed_piano}")
# 1.1.3: Starling's plucked strings, the classical guitar (FreePats, CC0) and the concert harp (VCSL, CC0).
foreach(_caw_inst guitar harp)
  set(_caw_embed_strings "${_caw_assets_out}/starling_${_caw_inst}_flac.cpp")
  add_custom_command(OUTPUT "${_caw_embed_strings}"
    COMMAND ${CMAKE_COMMAND} -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/assets/starling/${_caw_inst}.flac -DOUTPUT=${_caw_embed_strings}
      -DSYMBOL=starling_${_caw_inst}_flac -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/assets/starling/${_caw_inst}.flac ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
    COMMENT "Embedding Starling's recorded ${_caw_inst} plucks" VERBATIM)
  target_sources(caw_core PRIVATE "${_caw_embed_strings}")
endforeach()
target_sources(caw_core PRIVATE src/starling_strings.cpp)
target_sources(caw_core PRIVATE src/builtin_nightingale.cpp src/nightingale_bodies.cpp)  # 1.1.3: Nightingale (org.caw.nightingale), the bowed strings
target_sources(caw_core PRIVATE src/builtin_curlew.cpp src/curlew_bodies.cpp)  # 1.1.3: Curlew (org.caw.curlew), the winds
# Bittern's recorded speech (engine/assets/bittern/, from tools/bittern_assets.py).
set(_caw_embed_speech "${_caw_assets_out}/bittern_speech_flac.cpp")
add_custom_command(OUTPUT ${_caw_embed_speech}
  COMMAND ${CMAKE_COMMAND} -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/assets/bittern/speech.flac -DOUTPUT=${_caw_embed_speech}
    -DSYMBOL=bittern_speech_flac -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/assets/bittern/speech.flac ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  COMMENT "Embedding Bittern's recorded pipe speech" VERBATIM)
target_sources(caw_core PRIVATE src/builtin_bittern.cpp src/bittern_tables.cpp src/bittern_render.cpp "${_caw_embed_speech}")  # 1.1.3: Bittern (org.caw.bittern), the pipe organ
# 1.1.3: Woodpecker (org.caw.woodpecker), the tuned percussion, and its recorded mallet attacks (VCSL, CC0).
set(_caw_embed_mallets "${_caw_assets_out}/woodpecker_mallets_flac.cpp")
add_custom_command(OUTPUT "${_caw_embed_mallets}"
  COMMAND ${CMAKE_COMMAND} -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/assets/woodpecker/mallets.flac -DOUTPUT=${_caw_embed_mallets}
    -DSYMBOL=woodpecker_mallets_flac -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/assets/woodpecker/mallets.flac ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  COMMENT "Embedding Woodpecker's recorded mallet attacks" VERBATIM)
target_sources(caw_core PRIVATE src/builtin_woodpecker.cpp "${_caw_embed_mallets}")
# 1.1.3: Rook's recorded kit parts (Karoryfer's Unruly and Big Rusty Drums, CC0): transients, wires, hats, cymbals.
set(_caw_embed_rook "${_caw_assets_out}/rook_kit_flac.cpp")
add_custom_command(OUTPUT "${_caw_embed_rook}"
  COMMAND ${CMAKE_COMMAND} -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/assets/rook/kit.flac -DOUTPUT=${_caw_embed_rook}
    -DSYMBOL=rook_kit_flac -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/assets/rook/kit.flac ${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedFile.cmake
  COMMENT "Embedding Rook's recorded kit parts" VERBATIM)
target_sources(caw_core PRIVATE "${_caw_embed_rook}")
target_sources(caw_core PRIVATE src/builtin_flock.cpp src/builtin_flock_presets.cpp src/flock_source.cpp)  # 1.1.0: Flock (org.caw.flock), the granular instrument
target_sources(caw_core PRIVATE src/meters.cpp)  # live loudness, true peak and correlation meters (roadmap 2.6)
# The pre-load scan (1.0.7): ELF64/PE32+ reader, findings, capability declarations, policy, SHA-256, verdict cache.
target_sources(caw_core PRIVATE src/scan/analyze.cpp src/scan/parse_elf.cpp src/scan/parse_pe.cpp
  src/scan/declarations.cpp src/scan/policy.cpp src/scan/sha256.cpp src/scan/scan_file.cpp src/scan/syscall_sites.cpp)
# fx-dynamics begin: the Dynamics and Drive effects
# Audio assets, clips, the sampler and audio input (WP-J); miniaudio's decoders compiled privately (static).
target_sources(caw_core PRIVATE src/asset_store.cpp src/time_stretch.cpp src/audio_clips.cpp src/audio_input.cpp
  src/builtin_sampler.cpp src/builtin_sampler_sfz.cpp src/sampler_tools.cpp platform/decode_miniaudio.c)
set_source_files_properties(platform/decode_miniaudio.c PROPERTIES COMPILE_OPTIONS "-w"
  INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/third_party/miniaudio")
# Clip stretching (1.0.4, #208): Signalsmith Stretch and Signalsmith Linear, header-only, MIT (third_party/, decisions.md);
# only clip_stretch.cpp includes them. Tempo detection and transients for Slice to MIDI.
target_sources(caw_core PRIVATE src/clip_stretch.cpp src/audio_analysis.cpp src/sample_preview.cpp)  # + the sample preview (API 33)
set_source_files_properties(src/clip_stretch.cpp PROPERTIES
  INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
# The stretch tests pin the vendored library's random draws (a source property: caw_tests is defined below).
set_source_files_properties(tests/audio_stretch_test.cpp PROPERTIES
  INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
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
target_sources(caw_engine PRIVATE src/capi_pitch_clip.cpp)  # API 42: the clip pitch editor (Lark)

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
  add_executable(caw_tests tests/test_main.cpp tests/engine_test.cpp tests/clip_playback_test.cpp tests/export_test.cpp tests/pattern_test.cpp
    tests/midifile_test.cpp tests/midi2_test.cpp tests/module_registry_test.cpp tests/native_component_test.cpp tests/execution_test.cpp tests/execution_capi_test.cpp tests/module_test.cpp tests/graph_test.cpp tests/params_test.cpp tests/sdk_header_test.cpp tests/scheduler_test.cpp tests/dependency_test.cpp tests/hardware_test.cpp tests/worker_api_test.cpp tests/mix_reference_test.cpp tests/public_cpp_sdk_test.cpp tests/track_components_test.cpp tests/instrument_test.cpp tests/builtin_instruments_test.cpp
    src/capi.cpp src/capi_audio.cpp src/capi_modulation.cpp src/execution_capi.cpp src/worker_api.cpp src/capi_stress.cpp platform/audio_none.cpp)
  target_sources(caw_tests PRIVATE tests/engine_transport_test.cpp tests/engine_overload_test.cpp
    tests/engine_arrangement_test.cpp tests/engine_capacity_test.cpp)  # the mixer tests beside engine_test.cpp
  target_sources(caw_tests PRIVATE tests/vca_test.cpp)  # VCA groups (vca.h)
  target_sources(caw_tests PRIVATE tests/tolerance.cpp tests/tolerance_test.cpp)  # reference renders, their comparators
  target_sources(caw_tests PRIVATE tests/component_test_test.cpp)  # the component testing suite (#163)
  target_sources(caw_tests PRIVATE tests/test_signal_test.cpp)  # org.caw.test.osc, the internal test signal
  target_sources(caw_tests PRIVATE tests/sample_pack_test.cpp)  # the sample-pack maker (#164)
  target_sources(caw_tests PRIVATE tests/flagship_test.cpp)  # the flagship synth (#171) and its kernels
  target_sources(caw_tests PRIVATE tests/flagship_tables_test.cpp)  # its warps' aliasing and its user wavetable
  target_sources(caw_tests PRIVATE tests/flagship_raven_test.cpp)  # its 1.1.0 synthesis (Raven) and old presets unchanged
  target_sources(caw_tests PRIVATE tests/quality_test.cpp)  # the quality setting (Eco, Normal, High) and the buffer mode
  target_sources(caw_tests PRIVATE tests/output_safety_test.cpp)  # #244: the live output's safety flags through the C API
  target_sources(caw_tests PRIVATE tests/display_test.cpp)  # live display data, engine to UI (#173)
  target_sources(caw_tests PRIVATE tests/effects_test.cpp)  # the built-in effects suite (#173)
  target_sources(caw_tests PRIVATE tests/routing_test.cpp)  # sends, buses, keys and routing loops (#175)
  target_sources(caw_tests PRIVATE tests/mixer_routing_test.cpp)  # outputs, sends into tracks, returns, feedback sends
  target_sources(caw_tests PRIVATE tests/drums_test.cpp)  # org.caw.drums: 64 pads, layers, presets, samples, migration
  target_sources(caw_tests PRIVATE tests/drums_audit_test.cpp)  # org.caw.drums: every setting moves the sound; 1.1.0's groove
  target_sources(caw_tests PRIVATE tests/drums_compat_test.cpp)  # org.caw.drums: old presets bit-identical after 1.1.0
  target_sources(caw_tests PRIVATE tests/drums_acoustic_test.cpp)  # Rook 1.1.2: the Acoustic engine's realism, kits and builders
  target_sources(caw_tests PRIVATE tests/rook_test.cpp)  # Rook 1.1.3: recorded parts, the kinds apart, every control, Randomize, the glitch scan
  target_sources(caw_tests PRIVATE tests/ducker_test.cpp)  # the ducker driven directly (#175 audio review)
  target_sources(caw_tests PRIVATE tests/stereo_path_test.cpp)  # stereo end to end: buses and WAV export (#17, #121)
  target_sources(caw_tests PRIVATE tests/meters_test.cpp)  # loudness (BS.1770-5, EBU Tech 3341), true peak, correlation
  target_sources(caw_tests PRIVATE tests/sample_library_test.cpp)  # the sample browser: key estimate, preview (#229)
  target_sources(caw_tests PRIVATE tests/render_stems_test.cpp)  # song renders: stems, bounds, tail, normalise, dither, parity
  target_sources(caw_tests PRIVATE tests/fx_dynamics_test.cpp)  # fx-dynamics: the Dynamics and Drive effects
  target_sources(caw_tests PRIVATE tests/fx_creative_test.cpp)  # fx-creative: the Creative and Pitch & Time effects
  target_sources(caw_tests PRIVATE tests/fx_space_test.cpp)  # fx-space: Space, Modulation and Utility effects
  # fx-filters begin
  target_sources(caw_tests PRIVATE tests/fx_filters_test.cpp)  # the EQ & Filter group
  target_sources(caw_tests PRIVATE tests/note_fx_test.cpp)  # per-note FX (#127): slots, overflow, tails, parity
  target_sources(caw_tests PRIVATE tests/midi_fx_test.cpp)  # 1.1.0: MIDI effects before the instrument
  target_sources(caw_tests PRIVATE tests/fx_tools_test.cpp)  # 1.1.0: Meters, Lo-fi, Phase align
  target_sources(caw_tests PRIVATE tests/fx_voice_test.cpp)  # 1.1.0: Glint, Soar's Harmonizer and Octaver, Mimic
  target_sources(caw_tests PRIVATE tests/lark_test.cpp src/capi_pitch_clip.cpp)  # 1.1.0: Lark (live correction, the clip pitch editor, API 42)
  target_sources(caw_tests PRIVATE tests/fx_clean_test.cpp)  # 1.1.0: Preen and Hush
  target_sources(caw_tests PRIVATE tests/pack_test.cpp)  # 1.1.0: the AutoStacc beta pack (grain engine, Murmur, Peck, Bend, Iris)
  target_sources(caw_tests PRIVATE tests/starling_piano_test.cpp)
  target_sources(caw_tests PRIVATE tests/starling_model_test.cpp)  # 1.1.3: the piano model's physics (Timber's Simulated piano tests, ported)
  target_sources(caw_tests PRIVATE tests/timber_migrate_test.cpp)  # 1.1.3: Timber's projects load as the new instruments
  target_sources(caw_tests PRIVATE tests/nightingale_test.cpp)  # 1.1.3: Nightingale, the bowed strings
  target_sources(caw_tests PRIVATE tests/curlew_test.cpp)  # 1.1.3: Curlew, the winds
  target_sources(caw_tests PRIVATE tests/bittern_test.cpp)  # 1.1.3: Bittern, the pipe organ
  target_sources(caw_tests PRIVATE tests/woodpecker_test.cpp)  # 1.1.3: Woodpecker, the tuned percussion
  target_sources(caw_tests PRIVATE tests/instrument_knobs_test.cpp)  # 1.1.3: every instrument knob is audible
  target_sources(caw_tests PRIVATE tests/instrument_glitch_test.cpp)  # 1.1.3: no glitches, noises only at their moment
  target_sources(caw_tests PRIVATE tests/starling_strings_test.cpp)  # 1.1.3: Starling's guitar and harp
  # The Simulated piano's tables are generated (tools/starling_piano_gen.cpp, run during development): this test
  # regenerates them and fails if the committed file differs (beyond the last rounding step).
  add_executable(starling_piano_gen tools/starling_piano_gen.cpp)
  target_include_directories(starling_piano_gen PRIVATE src include)
  target_compile_options(starling_piano_gen PRIVATE ${_caw_fp_strict})
  add_test(NAME starling_piano_tables_current COMMAND starling_piano_gen --check ${CMAKE_CURRENT_SOURCE_DIR}/src/starling_piano_tables.inc)
  target_sources(caw_tests PRIVATE tests/flock_test.cpp)  # 1.1.0: Flock (the granular instrument)
  # fx-filters end
  target_sources(caw_tests PRIVATE tests/fx_racks_test.cpp)  # fx-racks: the FX and multiband racks
  target_sources(caw_tests PRIVATE tests/fx_merged_test.cpp)  # FX consolidation: merged devices, migration, optional ports
  target_sources(caw_tests PRIVATE tests/fx_merged_drive_test.cpp)  # FX consolidation part B: Drive and Bit distortion
  target_sources(caw_tests PRIVATE tests/fx_merged_space_test.cpp)  # FX consolidation part E: Delay and Reverb
  target_sources(caw_tests PRIVATE tests/fx_delay_modes_test.cpp)  # 1.1.0: the Delay's Tape, Reverse and Multi-tap
  target_sources(caw_tests PRIVATE tests/fx_reverb_modes_test.cpp)  # 1.1.0: the Reverb's Room, Plate, Spring, Gated and Reverse
  target_sources(caw_tests PRIVATE tests/fx_drive_modes_test.cpp)  # 1.1.0: the Drive's Amp, Pedal and Bands
  target_sources(caw_tests PRIVATE tests/fx_bits_bitwise_test.cpp)  # 1.1.0: Bit distortion's Bitwise
  target_sources(caw_tests PRIVATE tests/fx_bits_glitch_test.cpp)  # 1.1.1: Bitwise glitch ops
  target_sources(caw_tests PRIVATE tests/fx_cab_test.cpp)  # 1.1.0: the Convolver merged, its Cab variant
  target_sources(caw_tests PRIVATE tests/fx_merged_eqfilter_test.cpp)  # FX consolidation part C: EQ, Filter
  target_sources(caw_tests PRIVATE tests/fx_eq_plume_test.cpp)  # 1.1.0: the EQ's dynamics, solo, Linear and Match; the Wah
  target_sources(caw_tests PRIVATE tests/fx_merged_dynamics_test.cpp)  # FX consolidation part A: Compressor, Limiter, Transient
  target_sources(caw_tests PRIVATE tests/fx_duck_test.cpp tests/slot_tools_test.cpp)  # 1.0.8: the Duck variant; per-slot auto gain and meters
  target_sources(caw_tests PRIVATE tests/fx_dynsplit_test.cpp)  # 1.1.0: the Talon/Hatch/Duck split and its migration
  target_sources(caw_tests PRIVATE tests/fx_extras_test.cpp)  # 1.1.0: armed versions, sidechain filter, LUFS target, slot cost
  target_sources(caw_tests PRIVATE tests/fx_merged_stereomod_test.cpp)  # FX consolidation D: Utility/Stereo, Chorus/Flanger, Phaser, Tremolo/Pan
  target_sources(caw_tests PRIVATE tests/modulation_test.cpp)  # #161: project modulators and links
  target_sources(caw_tests PRIVATE tests/midi_device_test.cpp)  # MIDI from devices (API 15): edge conversion, timing, notes
  target_sources(caw_tests PRIVATE tests/graph_layout_test.cpp)  # #120 layout rules: mono to stereo, downmix, dual mono
  target_sources(caw_tests PRIVATE tests/voice_bus_test.cpp)  # #127 the voice bus; #120 built-in declarations, C 3.0/3.1
  target_sources(caw_tests PRIVATE tests/audio_assets_test.cpp)  # assets, audio clips, the sampler, SFZ, input (WP-J)
  target_sources(caw_tests PRIVATE tests/sampler_tools_test.cpp)  # 1.1.0: drop and play, slicing, takes, stretched zones
  target_sources(caw_tests PRIVATE tests/audio_stretch_test.cpp)  # 1.0.4: stretch, pitch, clip fields, tempo, slices
  target_sources(caw_tests PRIVATE tests/input_bridge_test.cpp)  # the input bridge: output unchanged when the input dies
  target_sources(caw_tests PRIVATE tests/device_drift_test.cpp)  # #241: tracks in time through the device path with the input on
  target_sources(caw_tests PRIVATE tests/speed_free_wins_test.cpp)  # speed phase 1: Eco oversampling, silent work skipped, master sleep
  target_sources(caw_tests PRIVATE tests/fp_mode_test.cpp)  # speed phase 2: the flush-to-zero guard, NaN/Inf guards under the build flags
  target_sources(caw_tests PRIVATE tests/sample_timing_test.cpp tests/timing_oracle.cpp)  # note timing exact to the sample
  target_sources(caw_tests PRIVATE tests/tempo_map_test.cpp)  # the tempo map and time signatures (1.0.3, #207)
  target_sources(caw_tests PRIVATE tests/stress_test.cpp)  # the Benchmark (beta plan C): scenarios, ramps, cancel, profiles
  target_sources(caw_tests PRIVATE tests/load_stabilizer_test.cpp)  # the callback's load stabilizer (Android, no hint session)
  target_sources(caw_tests PRIVATE tests/mix_graph_test.cpp)  # speed phase 5a/5b: pulled routes, per-node scratch, graph levels
  target_sources(caw_tests PRIVATE tests/mix_pool_test.cpp)  # speed phase 5c: the mix pool, parallel levels, the serial lane
  target_sources(caw_tests PRIVATE tests/component_bench_test.cpp)  # #197: the plug-in benchmark
  target_sources(caw_tests PRIVATE tests/patch_test.cpp)  # the patch model: nulls, block sizes, feedback, latency, limits
  add_library(caw_test_component MODULE tests/native_component_fixture.cpp)
  target_link_libraries(caw_test_component PRIVATE CAW::SDK)
  target_compile_options(caw_test_component PRIVATE ${CAW_FLAGS})
  set_target_properties(caw_test_component PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component")
  add_library(caw_test_component_no_entry MODULE tests/native_component_fixture.cpp)
  target_link_libraries(caw_test_component_no_entry PRIVATE CAW::SDK)
  target_compile_options(caw_test_component_no_entry PRIVATE ${CAW_FLAGS})
  target_compile_definitions(caw_test_component_no_entry PRIVATE CAW_TEST_OMIT_ENTRY)
  set_target_properties(caw_test_component_no_entry PROPERTIES PREFIX "" OUTPUT_NAME "caw_test_component_no_entry")
  # The plug-in benchmark's bad component (#197): allocates in process() and runs on subnormals at silence.
  add_library(caw_bench_fixture MODULE tests/bench_fixture_component.cpp)
  target_link_libraries(caw_bench_fixture PRIVATE CAW::SDK)
  target_compile_options(caw_bench_fixture PRIVATE ${CAW_FLAGS})
  set_target_properties(caw_bench_fixture PROPERTIES PREFIX "" OUTPUT_NAME "caw_bench_fixture")
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
  # The pre-load scan's built components (1.0.7): a starter built as the app builds it (caw_add_component, so it
  # carries an empty declaration section) and a fixture that declares capabilities, whose section the tests
  # compare with engine/tests/references/capabilities.canonical.
  include(cmake/CAWComponent.cmake)
  caw_add_component(MANIFEST ../examples/cpp/starters/bass/caw-component.json TARGET caw_test_starter_bass)
  caw_add_component(MANIFEST tests/fixtures/declared/caw-component.json TARGET caw_test_declared)
  # The component C interface compiles as plain C.
  add_library(caw_component_c_check OBJECT tests/component_header_check.c)
  target_include_directories(caw_component_c_check PRIVATE include)
  set_target_properties(caw_component_c_check PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
  add_dependencies(caw_tests caw_test_component caw_test_component_no_entry caw_test_component_v30 caw_component_c_check
                   caw_bench_fixture caw_test_starter_bass caw_test_declared caw_engine)
  target_compile_options(caw_tests PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_tests PRIVATE src)
  target_compile_definitions(caw_tests PRIVATE CAW_ROOT="${CAW_ROOT}"
    "CAW_TEST_COMPONENT_PATH_DEFAULT=\"$<TARGET_FILE:caw_test_component>\""
    "CAW_TEST_NO_ENTRY_COMPONENT_PATH=\"$<TARGET_FILE:caw_test_component_no_entry>\""
    "CAW_TEST_V30_COMPONENT_PATH=\"$<TARGET_FILE:caw_test_component_v30>\""
    "CAW_TEST_MODULATOR_PATH=\"$<TARGET_FILE:caw_test_modulator>\""
    "CAW_TEST_BENCH_COMPONENT_PATH=\"$<TARGET_FILE:caw_bench_fixture>\""
    "CAW_TEST_STARTER_PATH=\"$<TARGET_FILE:caw_test_starter_bass>\""
    "CAW_TEST_DECLARED_PATH=\"$<TARGET_FILE:caw_test_declared>\""
    "CAW_TEST_LIBCAW_PATH=\"$<TARGET_FILE:caw_engine>\"")
  target_sources(caw_tests PRIVATE tests/scan_test.cpp tests/scan_load_test.cpp tests/scan_bypass_test.cpp tests/scan_syscall_test.cpp)  # the pre-load scan (1.0.7)
  target_link_libraries(caw_tests PRIVATE caw_core)
  # Compile the consumer test with only CAW::SDK's public include path; no engine/src access.
  add_library(caw_sdk_public_compile OBJECT tests/public_cpp_sdk_test.cpp)
  target_link_libraries(caw_sdk_public_compile PRIVATE CAW::SDK)
  target_compile_options(caw_sdk_public_compile PRIVATE ${CAW_FLAGS})
  add_dependencies(caw_tests caw_sdk_public_compile)
  enable_testing()
  # Split the suite into independent processes so CTest can run shards concurrently.
  # Process isolation avoids sharing test state while keeping every case enabled.
  # The shard count changes only how the cases are split, never which run: CI's sanitizer jobs set more shards and run
  # one shard (both kinds) per job (.github/workflows/engine.yml).
  set(CAW_TEST_SHARDS 4 CACHE STRING "Number of caw_tests shards CTest registers (each case runs in exactly one)")
  if(NOT CAW_TEST_SHARDS MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "CAW_TEST_SHARDS must be a positive whole number, not '${CAW_TEST_SHARDS}'")
  endif()
  math(EXPR CAW_TEST_LAST_SHARD "${CAW_TEST_SHARDS} - 1")
  # Each shard runs the mix graph on one thread and writes every reference render's raw-bit digest; the parallel
  # shards run the same tests with every Engine's mix graph on 3 workers (speed phase 5c), and
  # caw_parallel_identity checks that every render has the same bits both ways.
  set(CAW_DIGEST_DIR "${CMAKE_CURRENT_BINARY_DIR}/render_digests")
  foreach(shard RANGE 0 ${CAW_TEST_LAST_SHARD})
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
    COMMAND ${CMAKE_COMMAND} -DDIGEST_DIR=${CAW_DIGEST_DIR} -DSHARD_COUNT=${CAW_TEST_SHARDS}
      -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/CompareDigests.cmake")
  set_tests_properties(caw_parallel_identity PROPERTIES FIXTURES_REQUIRED caw_render_digests)
  file(MAKE_DIRECTORY "${CAW_DIGEST_DIR}")
  # Real-time contract tests in their own binary: it replaces global operator new/delete to count
  # allocations, which would turn off AddressSanitizer's new/delete mismatch checks in caw_tests.
  add_executable(caw_rt_tests tests/test_main.cpp tests/graph_channels_test.cpp tests/engine_rt_test.cpp
                              tests/alloc_counter.cpp)
  target_sources(caw_rt_tests PRIVATE tests/graph_routing_test.cpp tests/graph_typed_ports_test.cpp
    tests/graph_parameters_test.cpp)  # the graph executor tests beside graph_channels_test.cpp
  target_sources(caw_rt_tests PRIVATE tests/fx_space_rt_test.cpp)  # fx-space effects: no allocation on the audio thread
  target_sources(caw_rt_tests PRIVATE tests/drums_acoustic_rt_test.cpp)  # Rook 1.1.2: Acoustic kits, no allocation
  target_sources(caw_rt_tests PRIVATE tests/flagship_raven_rt_test.cpp)  # Flagship's 1.1.0 synthesis (Raven)
  target_sources(caw_rt_tests PRIVATE tests/fx_racks_rt_test.cpp)  # fx-racks
  target_sources(caw_rt_tests PRIVATE tests/fx_merged_rt_test.cpp)  # FX consolidation: a variant change while playing
  target_sources(caw_rt_tests PRIVATE tests/fx_merged_drive_rt_test.cpp)  # part B: a Drive variant change while playing
  target_sources(caw_rt_tests PRIVATE tests/fx_merged_space_rt_test.cpp)  # part E: Delay and Reverb variant changes
  target_sources(caw_rt_tests PRIVATE tests/fx_merged_eqfilter_rt_test.cpp)  # FX consolidation part C: EQ, Filter
  target_sources(caw_rt_tests PRIVATE tests/fx_eq_plume_rt_test.cpp)  # 1.1.0: the EQ's and Filter's new modes
  target_sources(caw_rt_tests PRIVATE tests/fx_clean_rt_test.cpp)  # 1.1.0: Preen and Hush
  target_sources(caw_rt_tests PRIVATE tests/fx_extras_rt_test.cpp)  # 1.1.0: around the effects
  target_sources(caw_rt_tests PRIVATE tests/pack_rt_test.cpp)  # 1.1.0: the AutoStacc beta pack while playing
  target_sources(caw_rt_tests PRIVATE tests/flock_rt_test.cpp)  # 1.1.0: Flock while playing
  target_sources(caw_rt_tests PRIVATE tests/fx_merged_dynamics_rt_test.cpp)  # FX consolidation part A: Compressor variants while playing
  target_sources(caw_rt_tests PRIVATE tests/slot_tools_rt_test.cpp)  # 1.0.8: auto gain, slot meters and the Duck while playing
  target_sources(caw_rt_tests PRIVATE tests/fx_modes_rt_test.cpp)  # 1.1.0: the new effect modes while playing
  target_sources(caw_rt_tests PRIVATE tests/fx_voice_rt_test.cpp)  # 1.1.0: Glint, Harmonizer, Octaver, Mimic while playing
  target_sources(caw_rt_tests PRIVATE tests/lark_rt_test.cpp)  # 1.1.0: Lark while playing
  target_sources(caw_rt_tests PRIVATE tests/fx_merged_stereomod_rt_test.cpp)  # FX consolidation D: variant changes while playing
  target_sources(caw_rt_tests PRIVATE tests/voice_bus_rt_test.cpp)  # #127: instruments rendering into voice-bus lanes
  target_sources(caw_rt_tests PRIVATE tests/audio_rt_test.cpp)  # audio clips, the sampler, monitoring and recording (WP-J)
  target_sources(caw_rt_tests PRIVATE tests/modulation_rt_test.cpp)  # #161: project modulation
  target_sources(caw_rt_tests PRIVATE tests/note_fx_rt_test.cpp)  # #127: per-note FX
  target_sources(caw_rt_tests PRIVATE tests/midi_fx_rt_test.cpp)  # 1.1.0: MIDI effects
  target_sources(caw_rt_tests PRIVATE tests/sample_preview_rt_test.cpp)  # #229: the sample preview
  target_sources(caw_rt_tests PRIVATE tests/stress_rt_test.cpp)  # the Benchmark: its timed loop
  target_sources(caw_rt_tests PRIVATE tests/first_callback_rt_test.cpp)
  target_sources(caw_rt_tests PRIVATE tests/component_bench_rt_test.cpp)  # #197: the plug-in benchmark's allocation check
  target_sources(caw_rt_tests PRIVATE tests/output_safety_rt_test.cpp)  # #244: the live output's mono check and safety limiter
  target_sources(caw_rt_tests PRIVATE tests/mixer_routing_rt_test.cpp)  # outputs, sends into tracks, feedback sends
  target_sources(caw_rt_tests PRIVATE tests/vca_rt_test.cpp)  # VCA groups: lanes, live moves and project updates
  target_sources(caw_rt_tests PRIVATE tests/patch_rt_test.cpp)  # the patch model: a swap allocates nothing
  target_sources(caw_rt_tests PRIVATE tests/starling_piano_rt_test.cpp)  # 1.1.3: Starling's piano
  target_sources(caw_rt_tests PRIVATE tests/nightingale_rt_test.cpp)  # 1.1.3: Nightingale
  target_sources(caw_rt_tests PRIVATE tests/curlew_rt_test.cpp)  # 1.1.3: Curlew
  target_sources(caw_rt_tests PRIVATE tests/bittern_rt_test.cpp)  # 1.1.3: Bittern
  target_sources(caw_rt_tests PRIVATE tests/woodpecker_rt_test.cpp)  # 1.1.3: Woodpecker
  target_sources(caw_rt_tests PRIVATE tests/starling_strings_rt_test.cpp)  # 1.1.3: Starling's guitar and harp
  target_compile_options(caw_rt_tests PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_rt_tests PRIVATE src)
  add_dependencies(caw_rt_tests caw_test_component caw_bench_fixture)
  target_compile_definitions(caw_rt_tests PRIVATE CAW_ROOT="${CAW_ROOT}"
    "CAW_TEST_COMPONENT_PATH_DEFAULT=\"$<TARGET_FILE:caw_test_component>\""
    "CAW_TEST_BENCH_COMPONENT_PATH=\"$<TARGET_FILE:caw_bench_fixture>\"")
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
add_executable(caw_bench bench/caw_bench.cpp bench/tools_cost.cpp bench/dynsplit_cost.cpp bench/voice_cost.cpp bench/clean_cost.cpp bench/pack_cost.cpp bench/raven_cost.cpp bench/rook_cost.cpp src/capi.cpp src/capi_modulation.cpp platform/audio_none.cpp)
  target_sources(caw_bench PRIVATE bench/lark_cost.cpp)  # 1.1.0: Lark's cost ceilings
  target_sources(caw_bench PRIVATE bench/sampler_cost.cpp)  # 1.1.0: the sampler's plain and stretched zones
  target_sources(caw_bench PRIVATE bench/flock_cost.cpp)  # 1.1.0: Flock's cost ceilings
  target_sources(caw_bench PRIVATE bench/instrument_cost.cpp)  # the modelled instruments' cost ceilings (Starling, Nightingale, Curlew, Bittern, Woodpecker)
  target_compile_options(caw_bench PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_bench PRIVATE src)
  target_link_libraries(caw_bench PRIVATE caw_core)
  # The patch model's cost against today's chain (routing plan step 3); run it on a release build.
  add_executable(caw_patch_bench bench/patch_bench.cpp)
  target_compile_options(caw_patch_bench PRIVATE ${CAW_FLAGS})
  target_include_directories(caw_patch_bench PRIVATE src)
  target_link_libraries(caw_patch_bench PRIVATE caw_core)
  # The cost ceilings (each device family's `caw_bench 0.5 3xx`) and the spike check (602: no Benchmark scenario has a
  # callback whose work, its fastest of 3 runs, is over 3 times the median's), made from the rows of
  # bench/bench_modes.h that name a ctest, so a mode's number is written once. A Release build only (a Debug or
  # sanitized one is slower by design).
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/bench/bench_modes.h)
  if(CMAKE_BUILD_TYPE STREQUAL "Release")
    file(STRINGS bench/bench_modes.h _caw_bench_rows REGEX "^ *\\{-?[0-9]+, \"[a-z0-9_]+\", \"caw_[a-z_]+\",")
    set(_caw_bench_ctests)
    foreach(_row IN LISTS _caw_bench_rows)
      if(NOT _row MATCHES "^ *\\{(-?[0-9]+), \"[a-z0-9_]+\", \"(caw_[a-z_]+)\", \"([^\"]+)\"")
        message(FATAL_ERROR "bench/bench_modes.h: a ctest row this file can't read: ${_row}")
      endif()
      set(_number ${CMAKE_MATCH_1})
      set(_name ${CMAKE_MATCH_2})
      separate_arguments(_args UNIX_COMMAND "${CMAKE_MATCH_3}")
      list(POP_FRONT _args _seconds)
      add_test(NAME ${_name} COMMAND caw_bench ${_seconds} ${_number} ${_args})
      list(APPEND _caw_bench_ctests ${_name})
    endforeach()
    # Each alone: under `ctest --parallel` the test shards beside them share the cores' caches and clocks, and CI's
    # x64 runner then measured cases 10-20 % over their usual figure (an organ case 8,002 against 8,000 on PR #258).
    set_tests_properties(${_caw_bench_ctests} PROPERTIES RUN_SERIAL TRUE)
  endif()
endif()

# The strict reference the timing tests compare with (an option on a source comes after the target's). It includes no
# engine or SDK header, so it shares no inline function with the code caw_tests runs.
if(CAW_TOOLS)
  set_source_files_properties(tests/timing_oracle.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")
endif()
# Sample positions (src/sample_time.h): note, clip, loop and automation timing is exact to the sample on every
# platform, so this file is strict in every build, the app's included: no fused multiply-add, no reassociation.
set_source_files_properties(src/sample_time.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")
# The tempo map (src/tempo_map.h) feeds the same positions, so it is strict too.
set_source_files_properties(src/tempo_map.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")
# Clip stretching (1.0.4): Signalsmith Stretch (clip_stretch.cpp, the only file that includes the library) and the clip
# readers (time_stretch.cpp: WSOLA, the bridge's lag) are strict too, so a stretched clip renders the same bits on
# x86-64, Arm64 (where the fast flags fuse multiply-adds) and with clang-cl; their complex exponentials come from the
# engine's deterministic sine, not libm.
set_source_files_properties(src/clip_stretch.cpp src/time_stretch.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")
set_source_files_properties(src/builtin_fx_duck_level_carve.cpp src/builtin_fx_vocoder.cpp src/builtin_flagship.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")  # strict: Arm64 fuses multiply-adds under CAW_FP_FLAGS, and these devices' high-Q filter banks and Carve's band detectors grew that rounding past the -120 dB stable null (PR #258 CI, 2026-11-19)
set_source_files_properties(src/starling_piano_sim.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")  # strict: Timber's Simulated piano is block-size independent only without reassociation (its contacts and banks, 2026-11-20)
set_source_files_properties(src/bittern_render.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")  # strict: Bittern's voices give the same bits at any block size
set_source_files_properties(src/builtin_woodpecker.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")  # strict: Woodpecker (its model and frame) renders the same bits on every build
set_source_files_properties(src/starling_strings.cpp src/builtin_starling.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")  # strict: Starling's guitar and harp render the same bits on every build; builtin_starling.cpp too, where their frame (instrument_core.h) is instantiated (with the fast flags, clang-cl's linker kept that copy: 2026-11-25)
set_source_files_properties(src/builtin_curlew.cpp PROPERTIES COMPILE_OPTIONS "${_caw_fp_strict}")  # strict: Curlew's winds (their lips and reeds self-oscillate) render the same bits on every build (2026-11-26: the brass read 0.17 dB apart on Arm64)

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
foreach(_caw_target caw_core caw_engine caw_cli caw_tests caw_rt_tests caw_bench caw_patch_bench caw_clap_tests caw_vst3_tests)
  if(TARGET ${_caw_target})
    set_property(TARGET ${_caw_target} PROPERTY CAW_ENGINE_FP_FLAGS ON)
  endif()
endforeach()
