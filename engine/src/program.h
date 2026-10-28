// Compiled module: bytecode ops over block registers, parameter and state layout, and the per-block context the VM reads.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace caw {

constexpr int kBlock = 64;  // samples per VM block

// Limits that keep untrusted code bounded (the sandbox).
constexpr size_t kMaxSourceBytes = 64 * 1024;
constexpr int kMaxDepth = 128;
constexpr int kMaxRegisters = 1024;
constexpr int kMaxStateDoubles = 1 << 20;  // 8 MB: room for a few delay lines and reverbs
// All playing modules together (each also has a seam copy, so twice this in memory). Layers past it stay silent.
constexpr int64_t kMaxProjectStateDoubles = int64_t{1} << 23;  // 64 MB
constexpr int kMaxCallArgs = 6;
constexpr int kMaxParams = 32;

// Built-in variables a module can read.
// Trig and after are the note variables a pattern drives. They are "soft": a `let` or argument of the same name
// hides them, so code written before patterns existed keeps working.
enum class Var : uint8_t { T, Sr, Rate, Bpm, Beat, Bar, Step, Pos, Phase, Time, In, Seed, Trig, Gate, Note, Freq, Vel, Rel, Bend, Count };

enum class OpCode : uint8_t { Const, Var, Param, Bin, Un, Select, Call, Import };

enum class BinOp : uint8_t {
    Add, Sub, Mul, Div, Mod, Pow,
    And, Or, Xor, Shl, Shr, Ushr,
    Eq, Ne, Lt, Le, Gt, Ge,
    LogAnd, LogOr,
};

enum class UnOp : uint8_t { Neg, Plus, Not, BitNot };

struct Op {
    OpCode code;
    uint8_t sub;     // BinOp, UnOp, Var, or argument count for Call
    uint16_t dst;
    uint16_t a, b, c;
    uint16_t args[kMaxCallArgs];  // Call arguments
    uint32_t index;  // param index, built-in id or import index
    uint32_t state;  // state offset for stateful built-ins
    double k;        // constant value
};

enum class ModuleKind : uint8_t { Generator, Effect, Library, Pattern };
enum class OutputMode : uint8_t { Byte, Float };

constexpr int kMaxExports = 16;  // per layer, across its chain
constexpr int kMaxImports = 32;

enum class ParamKind : uint8_t { Number, Toggle, Choice };

// A slider, toggle or dropdown the app shows for a module (param) or once per project (global).
struct ParamDef {
    std::string name;
    double def = 0, min = 0, max = 1;
    double step = 0;  // 0 = continuous
    ParamKind kind = ParamKind::Number;
    std::vector<std::string> choices;  // Choice: labels, value is the index
    std::string tip, header, doc;
    bool global = false;
};

// A value this module shares with others as `module.name`.
struct ExportDef {
    std::string name, doc;
    uint16_t reg = 0;
};

struct FnDoc {
    std::string name, doc;               // doc: the summary line(s)
    std::vector<std::string> args;
    std::vector<std::string> argDocs;    // one per argument ("" when undocumented)
    std::string example;
};

struct StateInit {
    uint32_t offset;
    double value;
};

// One stateful call's state, named so a new version of the code can take it over when the call is unchanged:
// "fn/fn2:sine#1" is the second sine inside fn2 called from fn.
struct StateSite {
    std::string key;
    uint32_t offset = 0, size = 0;
};

struct Program {
    ModuleKind kind = ModuleKind::Generator;
    OutputMode mode = OutputMode::Byte;
    double rate = 8000.0;  // formula rate of t in byte mode
    std::string name, summary;
    std::string ns;  // libraries: the namespace their functions are called under
    std::vector<ParamDef> params;      // params and globals, in declaration order
    std::vector<ExportDef> exports;
    std::vector<std::string> imports;  // "module.name" values read from other modules
    std::vector<FnDoc> functions;
    std::vector<Op> constOps;  // run once when an instance is created
    std::vector<Op> ops;       // run every block
    int numRegs = 0;
    int outReg = 0;
    int stateSize = 0;
    std::vector<StateInit> stateInit;  // values that are not 0 after reset
    std::vector<StateSite> stateSites; // every stateful call, in code order
    std::vector<std::pair<uint32_t, uint32_t>> resetRanges;  // (offset, count) of state a reset clears
    uint32_t usedVars = 0;             // bit per Var
};

// Per-block values the host fills in for one module instance.
struct BlockCtx {
    int n = 0;                     // samples in this block (<= kBlock)
    double sr = 48000.0;
    double bpm = 120.0;
    uint32_t seed = 0;
    int keyRoot = 9;   // project key: 0 = C … 11 = B (A by default)
    int keyScale = 1;  // scale id (scale.minor by default)
    const double* vars[static_cast<int>(Var::Count)] = {};
    const double* const* imports = nullptr;  // one pointer per Program::imports entry (null reads 0)
    int importOffset = 0;                     // where this block starts inside those buffers
};

}  // namespace caw
