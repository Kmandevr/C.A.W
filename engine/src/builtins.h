// Table of built-in functions and named constants (maths, bits, oscillators, envelopes, filters, effects, glitch, music), with their docs.
#pragma once

#include <cstdint>

#include "program.h"

namespace caw {

struct CallArgs {
    const double* a[kMaxCallArgs];
    double* out;
    int n;
    double* state;       // this call site's state, or nullptr
    const BlockCtx* ctx;
};

struct Builtin {
    const char* name;
    int minArgs, maxArgs;
    double defaults[kMaxCallArgs];  // used for missing optional arguments
    int stateSize;
    Var needs;                      // variable the built-in reads (Var::Count for none)
    void (*init)(double* state, uint32_t site);
    void (*run)(const CallArgs&);
    const char* category;           // groups the reference: Maths, Bits, Oscillators, ...
    const char* doc;                // what it does, one or two sentences
    const char* args[kMaxCallArgs]; // "name: meaning (unit, range)"; optional ones say their default
    const char* example;            // a whole module body that makes sound with it
};

// Returns the built-in's id, or -1 if there is none with this name.
int findBuiltin(const char* name);
const Builtin& builtin(int id);
int builtinCount();

// Named constants such as scale.minor or chord.min7. Returns false if there is none.
bool findConstant(const char* name, double& value);

struct ConstantGroup {
    const char* prefix;  // "scale"
    const char* doc;
    const char* const* names;
    int count;
};
const ConstantGroup* constantGroups(int& count);

}  // namespace caw
