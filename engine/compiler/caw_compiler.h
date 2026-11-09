/* C.A.W on-device compiler: Clang and LLD in one library, run in-process (no executables).
 *
 * Android forbids executing files from app storage, so the compiler is a native library the app
 * loads in a dedicated process (":compiler"); a crash or exit only fails that build. Desktop
 * hosts may use the same library or the ordinary clang executable. */
#ifndef CAW_COMPILER_H
#define CAW_COMPILER_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define CAW_COMPILER_API __declspec(dllexport)
#else
#define CAW_COMPILER_API __attribute__((visibility("default")))
#endif

/* Runs one clang driver command line. argv[0] is the driver's path as if it were an executable
 * ("<toolchain>/bin/clang++", so it links the C++ library); the default resource directory is found from it, and -resource-dir
 * overrides it. Compile jobs run through Clang's cc1 in this process; link jobs (ld.lld) run
 * through LLD in this process; any other job fails the run. Temporary files go to $TMPDIR.
 * Returns the exit code (0 success). *output, when output is not NULL, receives every diagnostic
 * the driver, compiler and linker wrote, as UTF-8 text in Clang's usual format; free it with
 * caw_compiler_free. Not reentrant: run one build at a time per process. */
CAW_COMPILER_API int caw_compiler_run(int argc, const char* const* argv, char** output);
CAW_COMPILER_API void caw_compiler_free(char* text);
/* The LLVM version the library was built from, e.g. "23.1.5". */
CAW_COMPILER_API const char* caw_compiler_version(void);

#ifdef __cplusplus
}
#endif
#endif
