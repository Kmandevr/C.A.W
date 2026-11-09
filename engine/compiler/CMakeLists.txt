# The on-device compiler library (Clang and LLD in-process) and a command-line wrapper for tests.
# Configure with -DCMAKE_PREFIX_PATH=<install dir from build-llvm.sh>.
cmake_minimum_required(VERSION 3.20)
project(caw_compiler LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(LLVM REQUIRED CONFIG)
find_package(Clang REQUIRED CONFIG)
find_package(LLD REQUIRED CONFIG)
message(STATUS "C.A.W compiler: LLVM ${LLVM_PACKAGE_VERSION} from ${LLVM_DIR}")

llvm_map_components_to_libnames(caw_llvm_libs AArch64CodeGen AArch64AsmParser AArch64Desc AArch64Info Option Support)
add_library(caw_compiler SHARED caw_compiler.cpp)
if(ANDROID)
  target_sources(caw_compiler PRIVATE caw_compiler_jni.cpp)  # CompilerService.nativeRun
endif()
target_include_directories(caw_compiler PRIVATE ${LLVM_INCLUDE_DIRS} ${CLANG_INCLUDE_DIRS} ${LLD_INCLUDE_DIRS})
separate_arguments(caw_llvm_definitions NATIVE_COMMAND "${LLVM_DEFINITIONS}")
target_compile_definitions(caw_compiler PRIVATE ${caw_llvm_definitions})
if(NOT LLVM_ENABLE_RTTI)
  target_compile_options(caw_compiler PRIVATE -fno-rtti)
endif()
target_link_libraries(caw_compiler PRIVATE
  clangFrontendTool clangFrontend clangCodeGen clangDriver clangSerialization clangOptions
  lldELF lldCommon ${caw_llvm_libs})
set_target_properties(caw_compiler PROPERTIES C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
if(NOT WIN32 AND NOT APPLE)
  # Only the three caw_compiler_* functions are exported; unused code is dropped.
  target_link_options(caw_compiler PRIVATE -Wl,--gc-sections -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map)
endif()

add_executable(caw-compile caw_compile_main.c)
target_link_libraries(caw-compile PRIVATE caw_compiler)
# Installed next to the library (bin/ and lib/): find it there, wherever the install lands.
set_target_properties(caw-compile PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")
install(TARGETS caw_compiler caw-compile)
