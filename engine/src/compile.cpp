// Module compiler: header parser, lexer and a one-pass recursive-descent parser that emits register bytecode with constant folding.
#include "compile.h"

#include <bit>
#include <cctype>
#include <cmath>
#include <cstring>
#include <map>
#include <stdexcept>
#include <unordered_map>

#include "builtins.h"
#include "ops.h"

namespace caw {

namespace {

struct CompileError : std::runtime_error {
    int line, col;
    CompileError(int l, int c, const std::string& m) : std::runtime_error(m), line(l), col(c) {}
};

enum class Tok { Num, Ident, Op, Newline, End };

struct Token {
    Tok kind;
    std::string text;
    double num = 0.0;
    int line = 1, col = 1;
};

const char* const kOps[] = {">>>", "===", "!==", "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "..",
                            "+",   "-",   "*",   "/",  "%",  "&",  "|",  "^",  "~",  "!",  "<",  ">",  "?",
                            ":",   "(",   ")",   ",",  "=",  ";"};

class Lexer {
public:
    Lexer(std::string_view src, int firstLine) : s_(src), line_(firstLine) {}

    std::vector<Token> run() {
        std::vector<Token> out;
        int depth = 0;
        while (true) {
            skipSpaceAndComments(out, depth);
            Token t;
            t.line = line_;
            t.col = col_;
            if (i_ >= s_.size()) {
                t.kind = Tok::End;
                out.push_back(t);
                return out;
            }
            const char ch = s_[i_];
            if (std::isdigit(static_cast<unsigned char>(ch)) ||
                (ch == '.' && i_ + 1 < s_.size() && std::isdigit(static_cast<unsigned char>(s_[i_ + 1])))) {
                t.kind = Tok::Num;
                t.num = number();
            } else if (std::isalpha(static_cast<unsigned char>(ch)) || ch == '_' || ch == '#') {
                t.kind = Tok::Ident;
                size_t start = i_;
                // '#' only appears inside note names such as C#4.
                while (i_ < s_.size() && (std::isalnum(static_cast<unsigned char>(s_[i_])) || s_[i_] == '_' ||
                                          (s_[i_] == '#' && i_ > start)))
                    advance();
                if (i_ == start) throw CompileError(t.line, t.col, "unexpected '#'");
                t.text = std::string(s_.substr(start, i_ - start));
            } else {
                t.kind = Tok::Op;
                for (const char* op : kOps) {
                    const size_t len = std::strlen(op);
                    if (s_.substr(i_, len) == op) {
                        t.text = op;
                        break;
                    }
                }
                if (t.text.empty()) throw CompileError(t.line, t.col, std::string("unexpected character '") + ch + "'");
                for (size_t k = 0; k < t.text.size(); ++k) advance();
                if (t.text == "===") t.text = "==";
                if (t.text == "!==") t.text = "!=";
                if (t.text == "(") ++depth;
                if (t.text == ")" && depth > 0) --depth;
            }
            out.push_back(t);
        }
    }

private:
    void advance() {
        if (s_[i_] == '\n') {
            ++line_;
            col_ = 1;
        } else {
            ++col_;
        }
        ++i_;
    }

    void skipSpaceAndComments(std::vector<Token>& out, int depth) {
        while (i_ < s_.size()) {
            const char ch = s_[i_];
            if (ch == '\n') {
                if (depth == 0 && (out.empty() || out.back().kind != Tok::Newline)) {
                    Token t;
                    t.kind = Tok::Newline;
                    t.line = line_;
                    t.col = col_;
                    out.push_back(t);
                }
                advance();
            } else if (ch == ' ' || ch == '\t' || ch == '\r') {
                advance();
            } else if (ch == '/' && i_ + 1 < s_.size() && s_[i_ + 1] == '/') {
                while (i_ < s_.size() && s_[i_] != '\n') advance();
            } else if (ch == '/' && i_ + 1 < s_.size() && s_[i_ + 1] == '*') {
                const int l = line_, c = col_;
                advance();
                advance();
                while (i_ + 1 < s_.size() && !(s_[i_] == '*' && s_[i_ + 1] == '/')) advance();
                if (i_ + 1 >= s_.size()) throw CompileError(l, c, "comment is never closed");
                advance();
                advance();
            } else {
                break;
            }
        }
    }

    double number() {
        const int l = line_, c = col_;
        if (s_[i_] == '0' && i_ + 1 < s_.size() && (s_[i_ + 1] == 'x' || s_[i_ + 1] == 'X' || s_[i_ + 1] == 'b' ||
                                                    s_[i_ + 1] == 'B')) {
            const int base = (s_[i_ + 1] == 'x' || s_[i_ + 1] == 'X') ? 16 : 2;
            advance();
            advance();
            double v = 0.0;
            int digits = 0;
            while (i_ < s_.size()) {
                const char ch = static_cast<char>(std::tolower(static_cast<unsigned char>(s_[i_])));
                int d = -1;
                if (ch >= '0' && ch <= '9') d = ch - '0';
                else if (ch >= 'a' && ch <= 'f') d = 10 + ch - 'a';
                if (d < 0 || d >= base) break;
                v = v * base + d;
                ++digits;
                advance();
            }
            if (digits == 0) throw CompileError(l, c, "number has no digits");
            return v;
        }
        // Decimal: digits, an optional fraction (but not the '..' range operator) and an optional exponent.
        std::string text;
        while (i_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[i_]))) {
            text += s_[i_];
            advance();
        }
        if (i_ < s_.size() && s_[i_] == '.' && !(i_ + 1 < s_.size() && s_[i_ + 1] == '.')) {
            text += '.';
            advance();
            while (i_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[i_]))) {
                text += s_[i_];
                advance();
            }
        }
        if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
            size_t j = i_ + 1;
            if (j < s_.size() && (s_[j] == '+' || s_[j] == '-')) ++j;
            if (j < s_.size() && std::isdigit(static_cast<unsigned char>(s_[j]))) {
                while (i_ < j) {
                    text += s_[i_];
                    advance();
                }
                while (i_ < s_.size() && std::isdigit(static_cast<unsigned char>(s_[i_]))) {
                    text += s_[i_];
                    advance();
                }
            }
        }
        if (i_ < s_.size() && (std::isalpha(static_cast<unsigned char>(s_[i_])) || s_[i_] == '_'))
            throw CompileError(line_, col_, "letters straight after a number");
        return std::strtod(text.c_str(), nullptr);
    }

    std::string_view s_;
    size_t i_ = 0;
    int line_, col_ = 1;
};

// A note name such as C4, F#2 or Bb0 gives its MIDI note number (C4 = 60).
bool noteNumber(const std::string& s, double& out) {
    if (s.size() < 2 || s[0] < 'A' || s[0] > 'G') return false;
    static const int base[] = {9, 11, 0, 2, 4, 5, 7};  // A..G
    int n = base[s[0] - 'A'];
    size_t i = 1;
    if (s[i] == '#') {
        ++n;
        ++i;
    } else if (s[i] == 'b') {
        --n;
        ++i;
    }
    if (i + 1 != s.size() || !std::isdigit(static_cast<unsigned char>(s[i]))) return false;
    const int oct = s[i] - '0';
    out = (oct + 1) * 12 + n;
    return true;
}

const std::pair<const char*, Var> kVars[] = {
    {"t", Var::T},       {"sr", Var::Sr},     {"rate", Var::Rate}, {"bpm", Var::Bpm},
    {"beat", Var::Beat}, {"bar", Var::Bar},   {"step", Var::Step}, {"pos", Var::Pos},
    {"phase", Var::Phase}, {"time", Var::Time}, {"in", Var::In},   {"seed", Var::Seed},
};

bool findVar(const std::string& name, Var& out) {
    for (const auto& [n, v] : kVars)
        if (name == n) {
            out = v;
            return true;
        }
    return false;
}

struct Val {
    bool isConst = false;
    double k = 0.0;
    int reg = -1;
};

class Compiler {
public:
    Compiler(std::vector<Token> toks, Program& p) : t_(std::move(toks)), p_(p) {}

    void run() {
        bool haveOutput = false;
        Val out;
        int outLine = 0, outCol = 0;
        while (true) {
            skipNewlines();
            if (peek().kind == Tok::End) break;
            if (haveOutput)
                throw CompileError(outLine, outCol, "only the last line can be the output; use 'let' to name a value");
            const Token& head = peek();
            if (head.kind == Tok::Ident && head.text == "let") {
                next();
                letStatement();
            } else if (head.kind == Tok::Ident && head.text == "param") {
                next();
                paramStatement();
            } else {
                outLine = head.line;
                outCol = head.col;
                out = expression(0);
                haveOutput = true;
            }
            endStatement();
        }
        if (!haveOutput) {
            const Token& e = peek();
            throw CompileError(e.line, e.col, "no output: the last line must be an expression, e.g. t*(t>>5|t>>8)");
        }
        p_.outReg = toReg(out, outLine, outCol);
    }

private:
    const Token& peek() const { return t_[pos_]; }
    const Token& next() { return t_[pos_ < t_.size() - 1 ? pos_++ : pos_]; }
    bool isOp(const char* op) const { return peek().kind == Tok::Op && peek().text == op; }

    void skipNewlines() {
        while (peek().kind == Tok::Newline || isOp(";")) next();
    }

    void endStatement() {
        if (peek().kind == Tok::Newline || peek().kind == Tok::End || isOp(";")) return;
        fail(peek(), "expected the end of the line here");
    }

    [[noreturn]] void fail(const Token& at, const std::string& msg) { throw CompileError(at.line, at.col, msg); }

    void expectOp(const char* op) {
        if (!isOp(op)) fail(peek(), std::string("expected '") + op + "'");
        next();
    }

    std::string newName() {
        const Token& tok = peek();
        if (tok.kind != Tok::Ident) fail(tok, "expected a name");
        std::string name = tok.text;
        Var v;
        double note;
        if (name == "let" || name == "param" || name == "pi" || findVar(name, v) || findBuiltin(name.c_str()) >= 0 ||
            noteNumber(name, note))
            fail(tok, "'" + name + "' is a built-in name; pick another");
        if (names_.count(name)) fail(tok, "'" + name + "' is already defined");
        next();
        return name;
    }

    void letStatement() {
        const Token at = peek();
        const std::string name = newName();
        expectOp("=");
        Val v = expression(0);
        names_[name] = v;
        (void)at;
    }

    double signedNumber() {
        bool neg = false;
        if (isOp("-")) {
            neg = true;
            next();
        }
        if (peek().kind != Tok::Num) fail(peek(), "expected a number");
        const double v = next().num;
        return neg ? -v : v;
    }

    void paramStatement() {
        const Token at = peek();
        const std::string name = newName();
        expectOp("=");
        ParamDef d;
        d.name = name;
        d.def = signedNumber();
        if (peek().kind == Tok::Ident && peek().text == "in") {
            next();
            d.min = signedNumber();
            expectOp("..");
            d.max = signedNumber();
            if (!(d.min < d.max)) fail(at, "param range must go from low to high");
        } else if (d.def >= 0.0 && d.def <= 1.0) {
            d.min = 0.0;
            d.max = 1.0;
        } else {
            d.min = std::fmin(0.0, d.def * 2.0);
            d.max = std::fmax(1.0, d.def * 2.0);
        }
        if (d.def < d.min || d.def > d.max) fail(at, "param default is outside its range");
        if (p_.params.size() >= static_cast<size_t>(kMaxParams)) fail(at, "too many params");
        Op op{};
        op.code = OpCode::Param;
        op.index = static_cast<uint32_t>(p_.params.size());
        op.dst = static_cast<uint16_t>(newReg(at));
        p_.ops.push_back(op);
        p_.params.push_back(d);
        Val v;
        v.reg = op.dst;
        names_[name] = v;
    }

    int newReg(const Token& at) {
        if (p_.numRegs >= kMaxRegisters) fail(at, "module is too big");
        return p_.numRegs++;
    }

    int toReg(const Val& v, int line, int col) {
        if (!v.isConst) return v.reg;
        const uint64_t key = std::bit_cast<uint64_t>(v.k);
        auto it = consts_.find(key);
        if (it != consts_.end()) return it->second;
        if (p_.numRegs >= kMaxRegisters) throw CompileError(line, col, "module is too big");
        Op op{};
        op.code = OpCode::Const;
        op.dst = static_cast<uint16_t>(p_.numRegs++);
        op.k = v.k;
        p_.constOps.push_back(op);
        consts_[key] = op.dst;
        return op.dst;
    }

    struct Level {
        const char* ops[4];
        BinOp codes[4];
    };

    // Binary operator levels from loosest to tightest (C and JavaScript precedence).
    static const std::vector<Level>& levels() {
        static const std::vector<Level> l = {
            {{"||"}, {BinOp::LogOr}},
            {{"&&"}, {BinOp::LogAnd}},
            {{"|"}, {BinOp::Or}},
            {{"^"}, {BinOp::Xor}},
            {{"&"}, {BinOp::And}},
            {{"==", "!="}, {BinOp::Eq, BinOp::Ne}},
            {{"<", "<=", ">", ">="}, {BinOp::Lt, BinOp::Le, BinOp::Gt, BinOp::Ge}},
            {{"<<", ">>", ">>>"}, {BinOp::Shl, BinOp::Shr, BinOp::Ushr}},
            {{"+", "-"}, {BinOp::Add, BinOp::Sub}},
            {{"*", "/", "%"}, {BinOp::Mul, BinOp::Div, BinOp::Mod}},
        };
        return l;
    }

    struct DepthGuard {
        Compiler& c;
        DepthGuard(Compiler& cc, const Token& at) : c(cc) {
            if (++c.depth_ > kMaxDepth) c.fail(at, "expression is nested too deeply");
        }
        ~DepthGuard() { --c.depth_; }
    };

    // expression := ternary
    Val expression(int) {
        DepthGuard g(*this, peek());
        Val cond = binary(0);
        if (!isOp("?")) return cond;
        const Token at = next();
        skipLineBreaks();
        Val a = expression(0);
        skipLineBreaks();
        expectOp(":");
        skipLineBreaks();
        Val b = expression(0);
        if (cond.isConst) return truthy(cond.k) ? a : b;
        Op op{};
        op.code = OpCode::Select;
        op.a = static_cast<uint16_t>(toReg(cond, at.line, at.col));
        op.b = static_cast<uint16_t>(toReg(a, at.line, at.col));
        op.c = static_cast<uint16_t>(toReg(b, at.line, at.col));
        op.dst = static_cast<uint16_t>(newReg(at));
        p_.ops.push_back(op);
        Val r;
        r.reg = op.dst;
        return r;
    }

    // A line break right after an operator continues the expression.
    void skipLineBreaks() {
        while (peek().kind == Tok::Newline) next();
    }

    Val binary(size_t level) {
        if (level >= levels().size()) return power();
        Val left = binary(level + 1);
        const Level& lv = levels()[level];
        while (peek().kind == Tok::Op) {
            int found = -1;
            for (int i = 0; i < 4 && lv.ops[i]; ++i)
                if (peek().text == lv.ops[i]) found = i;
            if (found < 0) break;
            const Token at = next();
            skipLineBreaks();
            Val right = binary(level + 1);
            left = emitBin(lv.codes[found], left, right, at);
        }
        return left;
    }

    // power := unary ('**' power)?   (right-associative)
    Val power() {
        Val base = unary();
        if (!isOp("**")) return base;
        const Token at = next();
        skipLineBreaks();
        DepthGuard g(*this, at);
        Val exp = power();
        return emitBin(BinOp::Pow, base, exp, at);
    }

    Val emitBin(BinOp code, const Val& a, const Val& b, const Token& at) {
        if (a.isConst && b.isConst) {
            Val r;
            r.isConst = true;
            r.k = evalBin(code, a.k, b.k);
            return r;
        }
        Op op{};
        op.code = OpCode::Bin;
        op.sub = static_cast<uint8_t>(code);
        op.a = static_cast<uint16_t>(toReg(a, at.line, at.col));
        op.b = static_cast<uint16_t>(toReg(b, at.line, at.col));
        op.dst = static_cast<uint16_t>(newReg(at));
        p_.ops.push_back(op);
        Val r;
        r.reg = op.dst;
        return r;
    }

    Val unary() {
        const Token& tok = peek();
        if (tok.kind == Tok::Op && (tok.text == "-" || tok.text == "+" || tok.text == "!" || tok.text == "~")) {
            const Token at = next();
            DepthGuard g(*this, at);
            const UnOp code = at.text == "-"   ? UnOp::Neg
                              : at.text == "+" ? UnOp::Plus
                              : at.text == "!" ? UnOp::Not
                                               : UnOp::BitNot;
            Val v = unary();
            if (v.isConst) {
                Val r;
                r.isConst = true;
                r.k = evalUn(code, v.k);
                return r;
            }
            Op op{};
            op.code = OpCode::Un;
            op.sub = static_cast<uint8_t>(code);
            op.a = static_cast<uint16_t>(v.reg);
            op.dst = static_cast<uint16_t>(newReg(at));
            p_.ops.push_back(op);
            Val r;
            r.reg = op.dst;
            return r;
        }
        return primary();
    }

    Val primary() {
        const Token tok = peek();
        if (tok.kind == Tok::Num) {
            next();
            Val v;
            v.isConst = true;
            v.k = tok.num;
            return v;
        }
        if (isOp("(")) {
            next();
            Val v = expression(0);
            expectOp(")");
            return v;
        }
        if (tok.kind != Tok::Ident) {
            if (tok.kind == Tok::End || tok.kind == Tok::Newline) fail(tok, "the line ends too early");
            fail(tok, "unexpected '" + tok.text + "'");
        }
        next();
        if (isOp("(")) return call(tok);
        auto it = names_.find(tok.text);
        if (it != names_.end()) return it->second;
        Var var;
        if (findVar(tok.text, var)) return varVal(var, tok);
        Val v;
        if (tok.text == "pi") {
            v.isConst = true;
            v.k = kPi;
            return v;
        }
        if (noteNumber(tok.text, v.k)) {
            v.isConst = true;
            return v;
        }
        if (findBuiltin(tok.text.c_str()) >= 0) fail(tok, "'" + tok.text + "' is a function; call it like " + tok.text + "(x)");
        fail(tok, "unknown name '" + tok.text + "'");
    }

    Val varVal(Var var, const Token& at) {
        const int idx = static_cast<int>(var);
        p_.usedVars |= 1u << idx;
        if (varRegs_[idx] < 0) {
            Op op{};
            op.code = OpCode::Var;
            op.sub = static_cast<uint8_t>(var);
            op.dst = static_cast<uint16_t>(newReg(at));
            p_.ops.push_back(op);
            varRegs_[idx] = op.dst;
        }
        Val v;
        v.reg = varRegs_[idx];
        return v;
    }

    Val call(const Token& name) {
        const int id = findBuiltin(name.text.c_str());
        if (id < 0) fail(name, "unknown function '" + name.text + "'");
        const Builtin& b = builtin(id);
        expectOp("(");
        std::vector<Val> args;
        skipLineBreaks();
        if (!isOp(")")) {
            while (true) {
                args.push_back(expression(0));
                skipLineBreaks();
                if (isOp(",")) {
                    next();
                    skipLineBreaks();
                    continue;
                }
                break;
            }
        }
        expectOp(")");
        const int given = static_cast<int>(args.size());
        if (given < b.minArgs || given > b.maxArgs) {
            const std::string want = b.minArgs == b.maxArgs ? std::to_string(b.minArgs)
                                                            : std::to_string(b.minArgs) + " to " + std::to_string(b.maxArgs);
            fail(name, name.text + "() takes " + want + " argument" + (b.maxArgs == 1 ? "" : "s"));
        }
        // Optional arguments take their defaults, except for functions whose arguments are all optional.
        if (b.minArgs > 0)
            for (int i = given; i < b.maxArgs; ++i) {
                Val d;
                d.isConst = true;
                d.k = b.defaults[i];
                args.push_back(d);
            }
        Op op{};
        op.code = OpCode::Call;
        op.sub = static_cast<uint8_t>(args.size());
        op.index = static_cast<uint32_t>(id);
        uint16_t* slots[3] = {&op.a, &op.b, &op.c};
        for (size_t i = 0; i < args.size(); ++i) *slots[i] = static_cast<uint16_t>(toReg(args[i], name.line, name.col));
        if (b.needs != Var::Count) varVal(b.needs, name);
        if (b.stateSize > 0) {
            if (p_.stateSize + b.stateSize > kMaxStateDoubles) fail(name, "too many oscillators, envelopes and filters");
            op.state = static_cast<uint32_t>(p_.stateSize);
            p_.stateSize += b.stateSize;
            // Record the initial state so a reset is a plain copy.
            std::vector<double> init(static_cast<size_t>(b.stateSize), 0.0);
            b.init(init.data(), ++sites_);
            for (int i = 0; i < b.stateSize; ++i)
                if (init[i] != 0.0) p_.stateInit.push_back({op.state + static_cast<uint32_t>(i), init[i]});
        }
        op.dst = static_cast<uint16_t>(newReg(name));
        p_.ops.push_back(op);
        Val r;
        r.reg = op.dst;
        return r;
    }

    std::vector<Token> t_;
    size_t pos_ = 0;
    Program& p_;
    std::map<std::string, Val> names_;
    std::unordered_map<uint64_t, int> consts_;
    int varRegs_[static_cast<int>(Var::Count)] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
    int depth_ = 0;
    uint32_t sites_ = 0;
};

std::string trim(std::string_view s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return std::string(s.substr(a, b - a));
}

// Reads the optional '---' header. Returns the offset where code starts and the line it starts on.
size_t parseHeader(std::string_view src, Program& p, int& codeLine) {
    codeLine = 1;
    bool modeSet = false;
    size_t i = 0;
    auto readLine = [&](std::string_view& line) {
        if (i >= src.size()) return false;
        size_t e = src.find('\n', i);
        if (e == std::string_view::npos) e = src.size();
        line = src.substr(i, e - i);
        i = e < src.size() ? e + 1 : e;
        return true;
    };
    std::string_view line;
    size_t save = i;
    if (!readLine(line) || trim(line) != "---") {
        p.mode = OutputMode::Byte;
        return save;
    }
    int lineNo = 1;
    while (true) {
        if (!readLine(line)) throw CompileError(1, 1, "header starts with '---' but never ends with '---'");
        ++lineNo;
        std::string l = trim(line);
        if (l == "---") break;
        const size_t hashPos = l.find('#');
        if (hashPos != std::string::npos) l = trim(l.substr(0, hashPos));
        if (l.empty()) continue;
        const size_t colon = l.find(':');
        if (colon == std::string::npos) throw CompileError(lineNo, 1, "header lines look like 'key: value'");
        const std::string key = trim(l.substr(0, colon));
        const std::string value = trim(l.substr(colon + 1));
        if (key == "caw") {
            if (value != "1") throw CompileError(lineNo, 1, "this app reads module format 1, the file says " + value);
        } else if (key == "kind") {
            if (value == "generator") p.kind = ModuleKind::Generator;
            else if (value == "effect") p.kind = ModuleKind::Effect;
            else throw CompileError(lineNo, 1, "kind must be 'generator' or 'effect'");
        } else if (key == "name") {
            p.name = value;
        } else if (key == "summary") {
            p.summary = value;
        } else if (key == "mode") {
            if (value == "byte") p.mode = OutputMode::Byte;
            else if (value == "float") p.mode = OutputMode::Float;
            else throw CompileError(lineNo, 1, "mode must be 'byte' or 'float'");
            modeSet = true;
        } else if (key == "rate") {
            const double r = std::strtod(value.c_str(), nullptr);
            if (!(r >= 1000.0 && r <= 192000.0)) throw CompileError(lineNo, 1, "rate must be 1000 to 192000");
            p.rate = r;
        }
        // Other keys are ignored so newer files still load.
    }
    if (!modeSet) p.mode = p.kind == ModuleKind::Effect ? OutputMode::Float : OutputMode::Byte;
    codeLine = lineNo + 1;
    return i;
}

}  // namespace

CompileResult compileModule(std::string_view source) {
    CompileResult r;
    try {
        if (source.size() > kMaxSourceBytes) throw CompileError(1, 1, "module is longer than 64 KB");
        auto prog = std::make_shared<Program>();
        int codeLine = 1;
        const size_t start = parseHeader(source, *prog, codeLine);
        Lexer lex(source.substr(start), codeLine);
        Compiler c(lex.run(), *prog);
        c.run();
        r.program = std::move(prog);
    } catch (const CompileError& e) {
        r.line = e.line;
        r.col = e.col;
        r.error = "line " + std::to_string(e.line) + ", col " + std::to_string(e.col) + ": " + e.what();
    }
    return r;
}

}  // namespace caw
