// Table of built-in functions (pure maths, bit tools, oscillators, envelope, filter) that modules can call.
#pragma once

#include <cstdint>

#include "program.h"

namespace caw {

struct CallArgs {
    const double* a[3];
    double* out;
    int n;
    double* state;       // this call site's state, or nullptr
    const BlockCtx* ctx;
};

struct Builtin {
    const char* name;
    int minArgs, maxArgs;
    double defaults[3];  // used for missing optional arguments
    int stateSize;
    Var needs;           // variable the built-in reads (Var::Count for none)
    void (*init)(double* state, uint32_t site);
    void (*run)(const CallArgs&);
};

// Returns the built-in's id, or -1 if there is none with this name.
int findBuiltin(const char* name);
const Builtin& builtin(int id);

}  // namespace caw
