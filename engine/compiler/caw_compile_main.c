/* Command-line wrapper around the compiler library, for tests: caw-compile <clang arguments...>.
   argv[1] plays the driver's own path (e.g. <toolchain>/bin/clang). */
#include <stdio.h>

#include "caw_compiler.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: caw-compile <toolchain>/bin/clang [clang arguments...]\n");
        return 2;
    }
    char* output = NULL;
    const int code = caw_compiler_run(argc - 1, (const char* const*)(argv + 1), &output);
    if (output) {
        fputs(output, stderr);
        caw_compiler_free(output);
    }
    return code;
}
