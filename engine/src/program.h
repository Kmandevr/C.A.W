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
    uint32_t index;  // param index, built-in id or import index
    uint32_t state;  // state offset for stateful built-ins
    double k;        // constant value
};

enum class ModuleKind : uint8_t { Generator, Effect };
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
    std::string name, doc;
    std::vector<std::string> args;
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
    uint32_t usedVars = 0;             // bit per Var
};

// Per-block values the host fills in for one module instance.
struct BlockCtx {
    int n = 0;                     // samples in this block (<= kBlock)
    double sr = 48000.0;
    double bpm = 120.0;
    uint32_t seed = 0;
    const double* vars[static_cast<int>(Var::Count)] = {};
    const double* const* imports = nullptr;  // one pointer per Program::imports entry (null reads 0)
    int importOffset = 0;                     // where this block starts inside those buffers
};

}  // namespace caw
