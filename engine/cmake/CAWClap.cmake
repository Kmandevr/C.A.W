# Builds a C.A.W component library as a CLAP plug-in (.clap) with the SDK's wrapper (caw_add_clap_plugin).
include_guard(GLOBAL)

# The CLAP headers (MIT): free-audio/clap 1.2.9 (2026-06-18), pinned by commit. Offline builds can
# point FETCHCONTENT_SOURCE_DIR_CAW_CLAP at a checkout, or define a `clap` target before calling.
set(CAW_CLAP_GIT_REPOSITORY "https://github.com/free-audio/clap.git" CACHE STRING "CLAP headers repository")
set(CAW_CLAP_GIT_TAG "cd94482ba5941ae410809b6fbaed3bc851044270" CACHE STRING "CLAP commit (tag 1.2.9)")

# The wrapper source: next to this file when installed (clap/), in engine/plugin/clap/ in the source tree.
set(_CAW_CLAP_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(caw_fetch_clap)
  if(TARGET caw_clap_headers)
    return()
  endif()
  add_library(caw_clap_headers INTERFACE)
  if(TARGET clap)
    target_link_libraries(caw_clap_headers INTERFACE clap)
    return()
  endif()
  include(FetchContent)
  # SOURCE_SUBDIR names a folder without a CMakeLists.txt, so only the headers are fetched: CLAP's
  # own install rules stay out of the component's build.
  FetchContent_Declare(caw_clap
    GIT_REPOSITORY "${CAW_CLAP_GIT_REPOSITORY}"
    GIT_TAG "${CAW_CLAP_GIT_TAG}"
    SOURCE_SUBDIR caw-headers-only)
  FetchContent_MakeAvailable(caw_clap)
  file(READ "${caw_clap_SOURCE_DIR}/LICENSE" _license LIMIT 64)
  if(NOT _license MATCHES "^MIT License")
    message(FATAL_ERROR "The fetched CLAP headers are not under the MIT licence (${caw_clap_SOURCE_DIR}/LICENSE); refusing to build")
  endif()
  target_include_directories(caw_clap_headers SYSTEM INTERFACE "${caw_clap_SOURCE_DIR}/include")
endfunction()

# caw_add_clap_plugin(TARGET <name> COMPONENT <component target>
#                     [OUTPUT_NAME <file name without .clap>] [VENDOR <text>] [URL <text>]
#                     [VERSION <text>] [DESCRIPTION <text>])
# Builds <name>.clap from the component target's sources, include directories, definitions and
# libraries (the component code is compiled into the plug-in), into the component's output folder.
# Every component the library exports (a bundle) becomes one plug-in in the .clap.
function(caw_add_clap_plugin)
  cmake_parse_arguments(CAW "" "TARGET;COMPONENT;OUTPUT_NAME;VENDOR;URL;VERSION;DESCRIPTION" "" ${ARGN})
  if(CAW_UNPARSED_ARGUMENTS OR NOT CAW_TARGET OR NOT CAW_COMPONENT)
    message(FATAL_ERROR "caw_add_clap_plugin requires TARGET and COMPONENT")
  endif()
  if(NOT TARGET ${CAW_COMPONENT})
    message(FATAL_ERROR "caw_add_clap_plugin: no component target ${CAW_COMPONENT}")
  endif()
  if(TARGET ${CAW_TARGET})
    message(FATAL_ERROR "caw_add_clap_plugin: target already exists: ${CAW_TARGET}")
  endif()
  foreach(_field VENDOR URL VERSION DESCRIPTION)
    if(CAW_${_field} MATCHES "[\"\\\\;\n]")
      message(FATAL_ERROR "caw_add_clap_plugin: ${_field} may not contain quotes, backslashes, semicolons or newlines")
    endif()
  endforeach()

  set(_wrapper "${_CAW_CLAP_MODULE_DIR}/clap/caw_clap_entry.cpp")
  if(NOT EXISTS "${_wrapper}")
    set(_wrapper "${_CAW_CLAP_MODULE_DIR}/../plugin/clap/caw_clap_entry.cpp")
  endif()
  if(NOT EXISTS "${_wrapper}")
    message(FATAL_ERROR "caw_add_clap_plugin: the CLAP wrapper source is missing from the SDK")
  endif()
  caw_fetch_clap()

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
  target_link_libraries(${CAW_TARGET} PRIVATE CAW::SDK caw_clap_headers)
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
    "CAW_CLAP_VENDOR=\"${CAW_VENDOR}\"" "CAW_CLAP_URL=\"${CAW_URL}\""
    "CAW_CLAP_VERSION=\"${CAW_VERSION}\"" "CAW_CLAP_DESCRIPTION=\"${CAW_DESCRIPTION}\"")

  if(CAW_OUTPUT_NAME)
    set(_name "${CAW_OUTPUT_NAME}")
  else()
    set(_name "${CAW_TARGET}")
  endif()
  get_target_property(_out ${CAW_COMPONENT} LIBRARY_OUTPUT_DIRECTORY)
  if(NOT _out)
    set(_out "${CMAKE_BINARY_DIR}/artifacts")
  endif()
  # A .clap on Linux and Windows is the shared library itself, renamed (macOS bundles are not built).
  set_target_properties(${CAW_TARGET} PROPERTIES
    PREFIX ""
    SUFFIX ".clap"
    OUTPUT_NAME "${_name}"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    LIBRARY_OUTPUT_DIRECTORY "${_out}"
    RUNTIME_OUTPUT_DIRECTORY "${_out}"
  )
  # Bind the wrapper's call to caw_get_component_v3 inside the plug-in: a host that loads several
  # C.A.W plug-ins with global symbols must not route one plug-in's wrapper to another's components.
  if(UNIX AND NOT APPLE)
    target_link_options(${CAW_TARGET} PRIVATE "LINKER:-Bsymbolic")
  endif()
  set_property(TARGET ${CAW_TARGET} PROPERTY CAW_CLAP_PLUGIN ON)
endfunction()
