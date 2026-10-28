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
constexpr int kMaxStateDoubles = 8192;
constexpr int kMaxParams = 32;

// Built-in variables a module can read.
enum class Var : uint8_t { T, Sr, Rate, Bpm, Beat, Bar, Step, Pos, Phase, Time, In, Seed, Count };

enum class OpCode : uint8_t { Const, Var, Param, Bin, Un, Select, Call };

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
    uint32_t index;  // param index or built-in id
    uint32_t state;  // state offset for stateful built-ins
    double k;        // constant value
};

enum class ModuleKind : uint8_t { Generator, Effect };
enum class OutputMode : uint8_t { Byte, Float };

struct ParamDef {
    std::string name;
    double def, min, max;
};

struct StateInit {
    uint32_t offset;
    double value;
};

struct Program {
    ModuleKind kind = ModuleKind::Generator;
    OutputMode mode = OutputMode::Byte;
    double rate = 8000.0;  // formula rate of t in byte mode
    std::string name, summary;
    std::vector<ParamDef> params;
    std::vector<Op> constOps;  // run once when an instance is created
    std::vector<Op> ops;       // run every block
    int numRegs = 0;
    int outReg = 0;
    int stateSize = 0;
    std::vector<StateInit> stateInit;  // values that are not 0 after reset
    uint32_t usedVars = 0;             // bit per Var
};

// Per-block values the host fills in for one module instance.
struct BlockCtx {
    int n = 0;                     // samples in this block (<= kBlock)
    double sr = 48000.0;
    double bpm = 120.0;
    uint32_t seed = 0;
    const double* vars[static_cast<int>(Var::Count)] = {};
};

}  // namespace caw
