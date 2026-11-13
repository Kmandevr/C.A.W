# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(caw LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "caw")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# The C.A.W engine (engine/CMakeLists.txt), bundled next to the app so dart:ffi can load it.
# It is built with clang-cl (owner, 2026-11-13, docs/decisions.md): Visual Studio's ClangCL toolset, MSVC ABI, so the
# DLL's plain C API loads beside this MSVC-built runner. A Visual Studio build has one toolset for all its targets, so
# the engine is its own CMake build (ExternalProject) with that toolset; the app and plug-ins stay on MSVC.
# CAW_ENGINE_CLANG_CL=OFF builds it with MSVC as part of this build instead (a Visual Studio without the
# "C++ Clang tools for Windows" component).
option(CAW_ENGINE_CLANG_CL "Build the engine DLL with clang-cl (Visual Studio's ClangCL toolset)" ON)
set(CAW_ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../engine")
if(CAW_ENGINE_CLANG_CL)
  include(ExternalProject)
  set(CAW_ENGINE_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/caw_engine_clang_cl")
  # The engine has no Profile configuration; Flutter's Profile build takes its Release engine.
  set(CAW_ENGINE_CONFIG "$<IF:$<CONFIG:Debug>,Debug,Release>")
  ExternalProject_Add(caw_engine_clang_cl
    SOURCE_DIR "${CAW_ENGINE_DIR}"
    BINARY_DIR "${CAW_ENGINE_BUILD_DIR}"
    CMAKE_GENERATOR "${CMAKE_GENERATOR}"
    CMAKE_GENERATOR_PLATFORM "${CMAKE_GENERATOR_PLATFORM}"
    CMAKE_GENERATOR_TOOLSET ClangCL
    CMAKE_ARGS -DCAW_TOOLS=OFF -DCAW_INSTALL_SDK=OFF
    BUILD_COMMAND "${CMAKE_COMMAND}" --build "${CAW_ENGINE_BUILD_DIR}" --config "${CAW_ENGINE_CONFIG}" --target caw_engine
    BUILD_ALWAYS ON  # its own build decides what changed in engine/
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS "${CAW_ENGINE_BUILD_DIR}/Release/caw.dll" "${CAW_ENGINE_BUILD_DIR}/Debug/caw.dll"
  )
  add_dependencies(${BINARY_NAME} caw_engine_clang_cl)
  install(FILES "${CAW_ENGINE_BUILD_DIR}/${CAW_ENGINE_CONFIG}/caw.dll"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
else()
  set(CAW_TOOLS OFF CACHE BOOL "" FORCE)
  add_subdirectory("${CAW_ENGINE_DIR}" caw_engine)
  install(TARGETS caw_engine RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
