# Builds a C.A.W component library as a VST3 plug-in (a .vst3 bundle) with the SDK's wrapper (caw_add_vst3_plugin).
include_guard(GLOBAL)

# The VST3 interface headers (MIT since VST 3.8.0): steinbergmedia/vst3_pluginterfaces v3.8.1_build_84
# (2026-08-11), pinned by commit. Only these headers and two of their .cpp files are used, not the rest of the
# SDK. Offline builds can point FETCHCONTENT_SOURCE_DIR_CAW_VST3 at a checkout of that repository (the folder must
# be named `pluginterfaces`, since the headers include each other as <pluginterfaces/...>).
set(CAW_VST3_GIT_REPOSITORY "https://github.com/steinbergmedia/vst3_pluginterfaces.git" CACHE STRING
  "VST3 interface headers repository")
set(CAW_VST3_GIT_TAG "4f547e8e102b47de4a8b8aaf343c73b700786372" CACHE STRING "vst3_pluginterfaces commit (tag v3.8.1_build_84)")

# The wrapper sources: next to this file when installed (vst3/), in engine/plugin/vst3/ in the source tree.
set(_CAW_VST3_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(_caw_vst3_source _out _name)
  set(_path "${_CAW_VST3_MODULE_DIR}/vst3/${_name}")
  if(NOT EXISTS "${_path}")
    set(_path "${_CAW_VST3_MODULE_DIR}/../plugin/vst3/${_name}")
  endif()
  if(NOT EXISTS "${_path}")
    message(FATAL_ERROR "caw_add_vst3_plugin: ${_name} is missing from the SDK")
  endif()
  set(${_out} "${_path}" PARENT_SCOPE)
endfunction()

# caw_vst3_sdk: the interface headers plus the ids and FUID code they need (a static library, so the
# component's own compile options never apply to Steinberg's files).
function(caw_fetch_vst3)
  if(TARGET caw_vst3_sdk)
    return()
  endif()
  include(FetchContent)
  # SOURCE_SUBDIR names a folder without a CMakeLists.txt: nothing of the repository is configured.
  FetchContent_Declare(caw_vst3
    GIT_REPOSITORY "${CAW_VST3_GIT_REPOSITORY}"
    GIT_TAG "${CAW_VST3_GIT_TAG}"
    SOURCE_DIR "${CMAKE_BINARY_DIR}/_deps/caw_vst3/pluginterfaces"
    SOURCE_SUBDIR caw-headers-only)
  FetchContent_MakeAvailable(caw_vst3)
  file(READ "${caw_vst3_SOURCE_DIR}/LICENSE.txt" _license LIMIT 400)
  if(NOT _license MATCHES "MIT License" OR _license MATCHES "GPL")
    message(FATAL_ERROR "The fetched VST3 interface headers are not under the MIT licence (${caw_vst3_SOURCE_DIR}/LICENSE.txt); refusing to build")
  endif()
  get_filename_component(_root "${caw_vst3_SOURCE_DIR}" DIRECTORY)
  get_filename_component(_leaf "${caw_vst3_SOURCE_DIR}" NAME)
  if(NOT _leaf STREQUAL "pluginterfaces")
    message(FATAL_ERROR "The VST3 interface checkout must be a folder named pluginterfaces (${caw_vst3_SOURCE_DIR})")
  endif()
  _caw_vst3_source(_iids caw_vst3_iids.cpp)
  add_library(caw_vst3_sdk STATIC
    "${caw_vst3_SOURCE_DIR}/base/funknown.cpp"
    "${caw_vst3_SOURCE_DIR}/base/coreiids.cpp"
    "${_iids}")
  target_include_directories(caw_vst3_sdk SYSTEM PUBLIC "${_root}")
  target_compile_features(caw_vst3_sdk PUBLIC cxx_std_17)
  set_target_properties(caw_vst3_sdk PROPERTIES POSITION_INDEPENDENT_CODE ON CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON)
  if(WIN32)
    target_link_libraries(caw_vst3_sdk PUBLIC ole32)  # FUID::generate (CoCreateGuid)
  endif()
endfunction()

# caw_add_vst3_plugin(TARGET <name> COMPONENT <component target>
#                     [OUTPUT_NAME <bundle name without .vst3>] [VENDOR <text>] [URL <text>] [EMAIL <text>]
#                     [VERSION <text>])
# Builds <name>.vst3 (a VST3 bundle: <name>.vst3/Contents/<arch>-linux/<name>.so, or
# <name>.vst3/Contents/<arch>-win/<name>.vst3) from the component target's sources, include directories,
# definitions and libraries, into the component's output folder. Every component the library exports (a bundle)
# becomes one class in the plug-in's factory.
function(caw_add_vst3_plugin)
  cmake_parse_arguments(CAW "" "TARGET;COMPONENT;OUTPUT_NAME;VENDOR;URL;EMAIL;VERSION" "" ${ARGN})
  if(CAW_UNPARSED_ARGUMENTS OR NOT CAW_TARGET OR NOT CAW_COMPONENT)
    message(FATAL_ERROR "caw_add_vst3_plugin requires TARGET and COMPONENT")
  endif()
  if(NOT TARGET ${CAW_COMPONENT})
    message(FATAL_ERROR "caw_add_vst3_plugin: no component target ${CAW_COMPONENT}")
  endif()
  if(TARGET ${CAW_TARGET})
    message(FATAL_ERROR "caw_add_vst3_plugin: target already exists: ${CAW_TARGET}")
  endif()
  if(APPLE)
    message(FATAL_ERROR "caw_add_vst3_plugin: macOS bundles are not built yet")
  endif()
  foreach(_field VENDOR URL EMAIL VERSION)
    if(CAW_${_field} MATCHES "[\"\\\\;\n]")
      message(FATAL_ERROR "caw_add_vst3_plugin: ${_field} may not contain quotes, backslashes, semicolons or newlines")
    endif()
  endforeach()
  _caw_vst3_source(_wrapper caw_vst3_entry.cpp)
  caw_fetch_vst3()

  get_target_property(_component_dir ${CAW_COMPONENT} SOURCE_DIR)
  get_target_property(_sources ${CAW_COMPONENT} SOURCES)
  set(_absolute)
  foreach(_source IN LISTS _sources)
    if(_source MATCHES "^\\$<")
      list(APPEND _absolute "${_source}")
    else()
      get_filename_component(_path "${_source}" ABSOLUTE BASE_DIR "${_component_dir}")
      list(APPEND _absolute "${_path}")
    endif()
  endforeach()

  add_library(${CAW_TARGET} MODULE "${_wrapper}" ${_absolute})
  target_link_libraries(${CAW_TARGET} PRIVATE CAW::SDK caw_vst3_sdk)
  get_target_property(_libraries ${CAW_COMPONENT} LINK_LIBRARIES)
  if(_libraries)
    target_link_libraries(${CAW_TARGET} PRIVATE ${_libraries})
  endif()
  foreach(_property INCLUDE_DIRECTORIES COMPILE_DEFINITIONS COMPILE_OPTIONS)
    get_target_property(_value ${CAW_COMPONENT} ${_property})
    if(_value)
      set_property(TARGET ${CAW_TARGET} APPEND PROPERTY ${_property} ${_value})
    endif()
  endforeach()
  target_compile_features(${CAW_TARGET} PRIVATE cxx_std_20)
  target_compile_definitions(${CAW_TARGET} PRIVATE
    "CAW_VST3_VENDOR=\"${CAW_VENDOR}\"" "CAW_VST3_URL=\"${CAW_URL}\"" "CAW_VST3_EMAIL=\"${CAW_EMAIL}\""
    "CAW_VST3_VERSION=\"${CAW_VERSION}\"")

  if(CAW_OUTPUT_NAME)
    set(_name "${CAW_OUTPUT_NAME}")
  else()
    set(_name "${CAW_TARGET}")
  endif()
  get_target_property(_out ${CAW_COMPONENT} LIBRARY_OUTPUT_DIRECTORY)
  if(NOT _out)
    set(_out "${CMAKE_BINARY_DIR}/artifacts")
  endif()
  # The bundle's architecture folder (VST3 "Plug-in Format Structure").
  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _cpu)
  if(_cpu MATCHES "^(x86_64|amd64)$")
    set(_arch "x86_64")
  elseif(_cpu MATCHES "^(aarch64|arm64)$")
    if(WIN32)
      set(_arch "arm64")
    else()
      set(_arch "aarch64")
    endif()
  else()
    set(_arch "${_cpu}")
  endif()
  if(WIN32)
    set(_contents "${_out}/${_name}.vst3/Contents/${_arch}-win")
    set(_suffix ".vst3")
  else()
    set(_contents "${_out}/${_name}.vst3/Contents/${_arch}-linux")
    set(_suffix ".so")
  endif()
  set_target_properties(${CAW_TARGET} PROPERTIES
    PREFIX ""
    SUFFIX "${_suffix}"
    OUTPUT_NAME "${_name}"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    LIBRARY_OUTPUT_DIRECTORY "${_contents}"
    RUNTIME_OUTPUT_DIRECTORY "${_contents}"
  )
  # Multi-config generators would add a Debug/Release folder inside Contents; keep the bundle's layout.
  foreach(_config ${CMAKE_CONFIGURATION_TYPES})
    string(TOUPPER "${_config}" _upper)
    set_target_properties(${CAW_TARGET} PROPERTIES LIBRARY_OUTPUT_DIRECTORY_${_upper} "${_contents}"
      RUNTIME_OUTPUT_DIRECTORY_${_upper} "${_contents}")
  endforeach()
  # Bind the wrapper's call to caw_get_component_v3 inside the plug-in (see CAWClap.cmake).
  if(UNIX AND NOT APPLE)
    target_link_options(${CAW_TARGET} PRIVATE "LINKER:-Bsymbolic")
  endif()
  set_property(TARGET ${CAW_TARGET} PROPERTY CAW_VST3_PLUGIN ON)
  set_property(TARGET ${CAW_TARGET} PROPERTY CAW_VST3_BUNDLE "${_out}/${_name}.vst3")
endfunction()
