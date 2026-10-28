// Module compiler: header parser, lexer and a one-pass recursive-descent parser that emits register bytecode with constant folding.
#include "compile.h"

#include <bit>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <stdexcept>
#include <unordered_map>

#include "builtins.h"
#include "json.h"
#include "ops.h"

namespace caw {

namespace {

struct CompileError : std::runtime_error {
    int line, col;
    CompileError(int l, int c, const std::string& m) : std::runtime_error(m), line(l), col(c) {}
};

enum class Tok { Num, Ident, Str, Op, Newline, End };

struct Token {
    Tok kind;
    std::string text;
    double num = 0.0;
    int line = 1, col = 1;
};

const char* const kOps[] = {">>>", "===", "!==", "**", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "..",
                            "+",   "-",   "*",   "/",  "%",  "&",  "|",  "^",  "~",  "!",  "<",  ">",  "?",
                            ":",   "(",   ")",   ",",  "=",  ";",  "[",  "]"};

// A `//` comment and the line it sits on; doc comments (`///`) and headers (`// --- Tone ---`) come from these.
struct Comment {
    int line;
    std::string text;  // after the leading "//"
};

class Lexer {
public:
    Lexer(std::string_view src, int firstLine) : s_(src), line_(firstLine) {}

    const std::vector<Comment>& comments() const { return comments_; }

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
                // '#' only appears inside note names such as C#4. A '.' followed by a letter joins dotted names
                // such as kick.env or wave.square.
                while (i_ < s_.size() &&
                       (std::isalnum(static_cast<unsigned char>(s_[i_])) || s_[i_] == '_' ||
                        (s_[i_] == '#' && i_ > start) ||
                        (s_[i_] == '.' && i_ > start && i_ + 1 < s_.size() &&
                         (std::isalpha(static_cast<unsigned char>(s_[i_ + 1])) || s_[i_ + 1] == '_'))))
                    advance();
                if (i_ == start) throw CompileError(t.line, t.col, "unexpected '#'");
                t.text = std::string(s_.substr(start, i_ - start));
            } else if (ch == '"') {
                t.kind = Tok::Str;
                advance();
                while (i_ < s_.size() && s_[i_] != '"' && s_[i_] != '\n') {
                    if (s_[i_] == '\\' && i_ + 1 < s_.size() && (s_[i_ + 1] == '"' || s_[i_ + 1] == '\\')) advance();
                    t.text += s_[i_];
                    advance();
                }
                if (i_ >= s_.size() || s_[i_] != '"') throw CompileError(t.line, t.col, "text in quotes is never closed");
                advance();
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
                Comment c{line_, {}};
                advance();
                advance();
                while (i_ < s_.size() && s_[i_] != '\n') {
                    c.text += s_[i_];
                    advance();
                }
                comments_.push_back(std::move(c));
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
    std::vector<Comment> comments_;
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

std::string trimmed(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return s.substr(a, b - a);
}

constexpr int kMaxFnDepth = 32;

class Compiler {
public:
    Compiler(const std::vector<Token>& toks, const std::vector<Comment>& comments, Program& p)
        : t_(&toks), comments_(&comments), p_(p) {}

    // Loads a library's functions under its namespace (`drum` makes `fn kick` callable as drum.kick).
    void loadLibrary(const std::string& ns, const std::vector<Token>& toks, const std::vector<Comment>& comments) {
        const std::vector<Token>* savedT = t_;
        const std::vector<Comment>* savedC = comments_;
        const size_t savedPos = pos_;
        std::map<std::string, Val> savedNames = std::move(names_);
        names_.clear();
        t_ = &toks;
        comments_ = &comments;
        pos_ = 0;
        prefix_ = ns + ".";
        while (true) {
            skipNewlines();
            if (peek().kind == Tok::End) break;
            if (!(peek().kind == Tok::Ident && peek().text == "fn")) fail(peek(), "a library holds only fn functions");
            next();
            fnStatement();
            endStatement();
        }
        prefix_.clear();
        t_ = savedT;
        comments_ = savedC;
        pos_ = savedPos;
        names_ = std::move(savedNames);
    }

    // A library module on its own: only functions, named ns.fn as other modules call them; no output.
    void runLibrary() {
        prefix_ = p_.ns + ".";
        ownLibrary_ = true;
        while (true) {
            skipNewlines();
            if (peek().kind == Tok::End) break;
            if (!(peek().kind == Tok::Ident && peek().text == "fn")) fail(peek(), "a library holds only fn functions");
            next();
            fnStatement();
            endStatement();
        }
    }

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
            const bool word = head.kind == Tok::Ident;
            if (word && head.text == "let") {
                next();
                letStatement(false);
            } else if (word && head.text == "export") {
                next();
                if (!(peek().kind == Tok::Ident && peek().text == "let")) fail(peek(), "write 'export let name = ...'");
                next();
                letStatement(true);
            } else if (word && head.text == "param") {
                next();
                paramStatement(false);
            } else if (word && head.text == "global") {
                next();
                paramStatement(true);
            } else if (word && head.text == "fn") {
                next();
                fnStatement();
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
    const Token& peek() const { return (*t_)[pos_]; }
    const Token& next() { return (*t_)[pos_ < t_->size() - 1 ? pos_++ : pos_]; }
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

    static bool reserved(const std::string& name) {
        static const char* const words[] = {"let", "param", "global", "export", "fn", "pi", "on", "off"};
        for (const char* w : words)
            if (name == w) return true;
        return false;
    }

    std::string newName() {
        const Token& tok = peek();
        if (tok.kind != Tok::Ident) fail(tok, "expected a name");
        std::string name = tok.text;
        Var v;
        double note;
        if (name.find('.') != std::string::npos) fail(tok, "names can't contain '.'");
        if (reserved(name) || findVar(name, v) || findBuiltin(name.c_str()) >= 0 || noteNumber(name, note))
            fail(tok, "'" + name + "' is a built-in name; pick another");
        if (names_.count(name) || fns_.count(name)) fail(tok, "'" + name + "' is already defined");
        next();
        return name;
    }

    // `///` lines directly above a declaration are its documentation.
    std::vector<std::string> docLines(int line) const {
        std::vector<std::string> lines;
        for (int l = line - 1;; --l) {
            const Comment* c = commentAt(l);
            if (!c || c->text.empty() || c->text[0] != '/') break;
            lines.insert(lines.begin(), trimmed(c->text.substr(1)));
        }
        return lines;
    }

    std::string docFor(int line) const {
        std::string doc;
        for (const std::string& l : docLines(line)) doc += (doc.empty() ? "" : " ") + l;
        return doc;
    }

    // A function's doc: summary lines, then `arg: meaning` lines and an `example: code` line.
    FnDoc fnDoc(const std::string& name, const std::vector<std::string>& args, int line) const {
        FnDoc d;
        d.name = name;
        d.args = args;
        d.argDocs.assign(args.size(), "");
        for (const std::string& l : docLines(line)) {
            const size_t colon = l.find(':');
            const std::string key = colon == std::string::npos ? "" : trimmed(l.substr(0, colon));
            const std::string rest = colon == std::string::npos ? "" : trimmed(l.substr(colon + 1));
            bool used = false;
            if (key == "example") {
                d.example = rest;
                used = true;
            }
            for (size_t i = 0; i < args.size() && !used; ++i)
                if (key == args[i]) {
                    d.argDocs[i] = rest;
                    used = true;
                }
            if (!used) d.doc += (d.doc.empty() ? "" : " ") + l;
        }
        return d;
    }

    // The last `// --- Name ---` comment above a line groups the controls that follow it.
    std::string headerFor(int line) const {
        std::string header;
        for (const Comment& c : *comments_) {
            if (c.line >= line) break;
            const std::string t = trimmed(c.text);
            if (t.size() >= 3 && t.compare(0, 3, "---") == 0) {
                size_t a = 0, b = t.size();
                while (a < b && (t[a] == '-' || t[a] == ' ')) ++a;
                while (b > a && (t[b - 1] == '-' || t[b - 1] == ' ')) --b;
                header = t.substr(a, b - a);
            }
        }
        return header;
    }

    const Comment* commentAt(int line) const {
        for (const Comment& c : *comments_)
            if (c.line == line) return &c;
        return nullptr;
    }

    void letStatement(bool exported) {
        const Token at = peek();
        const std::string name = newName();
        expectOp("=");
        Val v = expression(0);
        names_[name] = v;
        if (exported) {
            if (p_.exports.size() >= static_cast<size_t>(kMaxExports)) fail(at, "too many exports");
            ExportDef e;
            e.name = name;
            e.doc = docFor(at.line);
            e.reg = static_cast<uint16_t>(toReg(v, at.line, at.col));
            p_.exports.push_back(e);
        }
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

    void paramStatement(bool global) {
        const Token at = peek();
        const std::string name = newName();
        expectOp("=");
        ParamDef d;
        d.name = name;
        d.global = global;
        d.doc = docFor(at.line);
        d.header = headerFor(at.line);
        std::string defLabel;
        bool haveRange = false;
        if (peek().kind == Tok::Ident) {
            defLabel = next().text;
            if (defLabel == "on" || defLabel == "off") {
                d.kind = ParamKind::Toggle;
                d.def = defLabel == "on" ? 1.0 : 0.0;
                d.min = 0;
                d.max = 1;
                d.step = 1;
                defLabel.clear();
            }
        } else {
            d.def = signedNumber();
        }
        // Options in any order: `in low..high` or `in [a, b, c]`, `step s`, "tooltip".
        while (true) {
            if (peek().kind == Tok::Ident && peek().text == "in") {
                next();
                if (isOp("[")) {
                    next();
                    while (true) {
                        skipLineBreaks();
                        if (peek().kind != Tok::Ident || peek().text.find('.') != std::string::npos)
                            fail(peek(), "dropdown choices are plain names, e.g. [saw, square, tri]");
                        const std::string label = next().text;
                        for (const std::string& c : d.choices)
                            if (c == label) fail(at, "'" + label + "' is listed twice");
                        d.choices.push_back(label);
                        skipLineBreaks();
                        if (isOp(",")) {
                            next();
                            continue;
                        }
                        break;
                    }
                    expectOp("]");
                    if (d.choices.size() > 64) fail(at, "a dropdown holds at most 64 choices");
                    d.kind = ParamKind::Choice;
                } else {
                    d.min = signedNumber();
                    expectOp("..");
                    d.max = signedNumber();
                    if (!(d.min < d.max)) fail(at, "param range must go from low to high");
                    haveRange = true;
                }
            } else if (peek().kind == Tok::Ident && peek().text == "step") {
                next();
                d.step = signedNumber();
                if (!(d.step > 0)) fail(at, "step must be above 0");
            } else if (peek().kind == Tok::Str) {
                d.tip = next().text;
            } else {
                break;
            }
        }
        if (d.kind == ParamKind::Choice) {
            int idx = -1;
            for (size_t i = 0; i < d.choices.size(); ++i)
                if (d.choices[i] == defLabel) idx = static_cast<int>(i);
            if (idx < 0) fail(at, "a dropdown's default must be one of its choices");
            d.def = idx;
            d.min = 0;
            d.max = static_cast<double>(d.choices.size() - 1);
            d.step = 1;
            for (size_t i = 0; i < d.choices.size(); ++i) {
                Val c;
                c.isConst = true;
                c.k = static_cast<double>(i);
                names_[name + "." + d.choices[i]] = c;
            }
        } else if (!defLabel.empty()) {
            fail(at, "'" + defLabel + "' isn't a number; for a dropdown add in [" + defLabel + ", ...]");
        } else if (d.kind == ParamKind::Number && !haveRange) {
            if (d.def >= 0.0 && d.def <= 1.0) {
                d.min = 0.0;
                d.max = 1.0;
            } else {
                d.min = std::fmin(0.0, d.def * 2.0);
                d.max = std::fmax(1.0, d.def * 2.0);
            }
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

    // fn name(a, b) = expression. Each call expands the body in place, so oscillators and filters inside a function
    // get their own state per call. The body is compiled once here to report its errors, then rolled back.
    struct FnDef {
        const std::vector<Token>* toks = nullptr;  // the module's or a library's tokens
        std::vector<std::string> args;
        std::vector<std::string> argDocs;
        size_t bodyStart = 0, bodyEnd = 0;
        std::map<std::string, Val> scope;  // names visible where the function was defined
    };

    struct Snapshot {
        size_t ops, constOps, stateInit, imports;
        int numRegs, stateSize;
        uint32_t usedVars, sites;
        std::unordered_map<uint64_t, int> consts;
        std::map<std::string, int> importRegs;
        int varRegs[static_cast<int>(Var::Count)];
    };

    Snapshot save() const {
        Snapshot sn{p_.ops.size(), p_.constOps.size(), p_.stateInit.size(), p_.imports.size(), p_.numRegs,
                    p_.stateSize, p_.usedVars, sites_, consts_, importRegs_, {}};
        std::copy(std::begin(varRegs_), std::end(varRegs_), sn.varRegs);
        return sn;
    }

    void restore(const Snapshot& sn) {
        p_.ops.resize(sn.ops);
        p_.constOps.resize(sn.constOps);
        p_.stateInit.resize(sn.stateInit);
        p_.imports.resize(sn.imports);
        p_.numRegs = sn.numRegs;
        p_.stateSize = sn.stateSize;
        p_.usedVars = sn.usedVars;
        sites_ = sn.sites;
        consts_ = sn.consts;
        importRegs_ = sn.importRegs;
        std::copy(std::begin(sn.varRegs), std::end(sn.varRegs), varRegs_);
    }

    void fnStatement() {
        const Token at = peek();
        const std::string name = prefix_ + newName();
        // A library function must not hide a built-in or another library's function.
        double constant;
        if (!prefix_.empty()) {
            if (findBuiltin(name.c_str()) >= 0 || findConstant(name.c_str(), constant))
                fail(at, "'" + name + "' is a built-in name; pick another");
            if (fns_.count(name)) fail(at, "'" + name + "' is already defined");
        }
        FnDef f;
        f.toks = t_;
        expectOp("(");
        if (!isOp(")")) {
            while (true) {
                const Token argTok = peek();
                const std::string arg = newName();
                for (const std::string& a : f.args)
                    if (a == arg) fail(argTok, "'" + arg + "' is listed twice");
                f.args.push_back(arg);
                if (isOp(",")) {
                    next();
                    continue;
                }
                break;
            }
        }
        expectOp(")");
        expectOp("=");
        f.scope = names_;
        f.bodyStart = pos_;
        // Compile once with stand-in arguments to find the body's end and report errors now.
        const Snapshot sn = save();
        std::map<std::string, Val> saved = names_;
        names_ = f.scope;
        for (const std::string& a : f.args) {
            Val v;
            v.reg = newReg(at);
            names_[a] = v;
        }
        expanding_.push_back(name);
        expression(0);
        expanding_.pop_back();
        f.bodyEnd = pos_;
        names_ = std::move(saved);
        restore(sn);
        FnDoc doc = fnDoc(name, f.args, at.line);
        f.argDocs = doc.argDocs;
        fns_[name] = std::move(f);
        if (prefix_.empty() || ownLibrary_) p_.functions.push_back(std::move(doc));
        else libDocs_.push_back(std::move(doc));
    }

    Val callUser(const Token& nameTok, const FnDef& f, const std::vector<Val>& args) {
        if (args.size() != f.args.size())
            fail(nameTok, nameTok.text + "() takes " + std::to_string(f.args.size()) + " argument" +
                              (f.args.size() == 1 ? "" : "s"));
        for (const std::string& e : expanding_)
            if (e == nameTok.text) fail(nameTok, "functions can't call themselves");
        if (static_cast<int>(expanding_.size()) >= kMaxFnDepth) fail(nameTok, "functions are nested too deeply");
        for (size_t i = 0; i < args.size() && i < f.argDocs.size(); ++i) inheritTip(args[i], f.argDocs[i]);
        std::map<std::string, Val> saved = std::move(names_);
        names_ = f.scope;
        for (size_t i = 0; i < args.size(); ++i) names_[f.args[i]] = args[i];
        const size_t savedPos = pos_;
        const std::vector<Token>* savedT = t_;
        t_ = f.toks;
        pos_ = f.bodyStart;
        expanding_.push_back(nameTok.text);
        Val v = expression(0);
        expanding_.pop_back();
        t_ = savedT;
        pos_ = savedPos;
        names_ = std::move(saved);
        return v;
    }

    // A param passed straight into a documented argument, without a tip of its own, shows that argument's doc.
    void inheritTip(const Val& v, const std::string& doc) {
        if (v.isConst || doc.empty()) return;
        for (const Op& op : p_.ops)
            if (op.code == OpCode::Param && op.dst == v.reg) {
                ParamDef& d = p_.params[op.index];
                if (d.tip.empty() && d.doc.empty()) d.tip = doc;
                return;
            }
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
        if (fns_.count(tok.text)) fail(tok, "'" + tok.text + "' is a function; call it like " + tok.text + "(...)");
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
        if (findConstant(tok.text.c_str(), v.k)) {
            v.isConst = true;
            return v;
        }
        const size_t dot = tok.text.find('.');
        if (dot != std::string::npos && dot > 0 && tok.text.find('.', dot + 1) == std::string::npos)
            return importVal(tok);
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

    // module.name: a value another module exports. The engine connects it when the project is set.
    Val importVal(const Token& tok) {
        auto it = importRegs_.find(tok.text);
        if (it == importRegs_.end()) {
            if (p_.imports.size() >= static_cast<size_t>(kMaxImports)) fail(tok, "too many shared values read");
            Op op{};
            op.code = OpCode::Import;
            op.index = static_cast<uint32_t>(p_.imports.size());
            op.dst = static_cast<uint16_t>(newReg(tok));
            p_.ops.push_back(op);
            p_.imports.push_back(tok.text);
            it = importRegs_.emplace(tok.text, op.dst).first;
        }
        Val v;
        v.reg = it->second;
        return v;
    }

    Val call(const Token& name) {
        for (const std::string& e : expanding_)
            if (e == name.text) fail(name, "functions can't call themselves");
        auto user = fns_.find(name.text);
        const int id = user == fns_.end() ? findBuiltin(name.text.c_str()) : -1;
        if (user == fns_.end() && id < 0) fail(name, "unknown function '" + name.text + "'");
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
        if (user != fns_.end()) return callUser(name, user->second, args);
        const Builtin& b = builtin(id);
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
        for (int i = 0; i < given; ++i) {
            const char* doc = b.args[i] ? std::strchr(b.args[i], ':') : nullptr;
            if (doc) inheritTip(args[static_cast<size_t>(i)], trimmed(doc + 1));
        }
        Op op{};
        op.code = OpCode::Call;
        op.sub = static_cast<uint8_t>(args.size());
        op.index = static_cast<uint32_t>(id);
        for (size_t i = 0; i < args.size(); ++i) op.args[i] = static_cast<uint16_t>(toReg(args[i], name.line, name.col));
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

public:
    std::vector<FnDoc> libDocs_;  // functions loaded from libraries, for the reference

private:
    const std::vector<Token>* t_;
    const std::vector<Comment>* comments_;
    std::string prefix_;  // namespace while loading a library
    bool ownLibrary_ = false;  // compiling a library module itself: its functions go in p_.functions
    size_t pos_ = 0;
    Program& p_;
    std::map<std::string, FnDef> fns_;
    std::vector<std::string> expanding_;
    std::map<std::string, int> importRegs_;
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
            else if (value == "library") p.kind = ModuleKind::Library;
            else throw CompileError(lineNo, 1, "kind must be 'generator', 'effect' or 'library'");
        } else if (key == "name") {
            p.name = value;
        } else if (key == "summary") {
            p.summary = value;
        } else if (key == "namespace") {
            p.ns = value;
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

std::string describeProgram(const Program& p) {
    auto str = [](const std::string& v) { return "\"" + jsonEscape(v) + "\""; };
    auto num = [](double v) {
        char buf[40];
        std::snprintf(buf, sizeof buf, "%.17g", v);
        return std::string(buf);
    };
    std::string o = "\"kind\":" +
                    str(p.kind == ModuleKind::Effect ? "effect" : p.kind == ModuleKind::Library ? "library" : "generator") +
                    ",\"namespace\":" + str(p.ns) +
                    ",\"mode\":" + str(p.mode == OutputMode::Byte ? "byte" : "float") + ",\"name\":" + str(p.name) +
                    ",\"summary\":" + str(p.summary) + ",\"params\":[";
    for (size_t i = 0; i < p.params.size(); ++i) {
        const ParamDef& d = p.params[i];
        o += std::string(i ? "," : "") + "{\"name\":" + str(d.name) + ",\"default\":" + num(d.def) +
             ",\"min\":" + num(d.min) + ",\"max\":" + num(d.max) + ",\"step\":" + num(d.step) + ",\"kind\":" +
             str(d.kind == ParamKind::Toggle ? "toggle" : d.kind == ParamKind::Choice ? "choice" : "number") +
             ",\"choices\":[";
        for (size_t c = 0; c < d.choices.size(); ++c) o += (c ? "," : "") + str(d.choices[c]);
        o += "],\"tip\":" + str(d.tip) + ",\"header\":" + str(d.header) + ",\"doc\":" + str(d.doc) +
             ",\"global\":" + (d.global ? "true" : "false") + "}";
    }
    o += "],\"exports\":[";
    for (size_t i = 0; i < p.exports.size(); ++i)
        o += std::string(i ? "," : "") + "{\"name\":" + str(p.exports[i].name) + ",\"doc\":" + str(p.exports[i].doc) + "}";
    o += "],\"imports\":[";
    for (size_t i = 0; i < p.imports.size(); ++i) o += (i ? "," : "") + str(p.imports[i]);
    o += "],\"functions\":[";
    for (size_t i = 0; i < p.functions.size(); ++i) {
        const FnDoc& f = p.functions[i];
        o += std::string(i ? "," : "") + "{\"name\":" + str(f.name) + ",\"doc\":" + str(f.doc) +
             ",\"example\":" + str(f.example) + ",\"args\":[";
        for (size_t a = 0; a < f.args.size(); ++a)
            o += std::string(a ? "," : "") + "{\"name\":" + str(f.args[a]) + ",\"doc\":" +
                 str(a < f.argDocs.size() ? f.argDocs[a] : std::string()) + "}";
        o += "]}";
    }
    return o + "]";
}

namespace {

struct LoadedLibrary {
    std::string ns;
    std::vector<Token> toks;
    std::vector<Comment> comments;
};

// Lexes a library's code (after its header); its namespace comes from `namespace:` unless given.
LoadedLibrary lexLibrary(const LibrarySource& lib) {
    Program hdr;
    int codeLine = 1;
    const size_t start = parseHeader(lib.source, hdr, codeLine);
    LoadedLibrary out;
    out.ns = !lib.ns.empty() ? lib.ns : hdr.ns;
    Lexer lex(std::string_view(lib.source).substr(start), codeLine);
    out.toks = lex.run();
    out.comments = lex.comments();
    return out;
}

void validNamespace(const std::string& ns) {
    bool ok = !ns.empty() && std::isalpha(static_cast<unsigned char>(ns[0]));
    for (const char ch : ns) ok = ok && (std::isalnum(static_cast<unsigned char>(ch)) || ch == '_');
    if (!ok) throw CompileError(1, 1, "a library needs a 'namespace:' made of letters, digits and _");
}

}  // namespace

CompileResult compileModule(std::string_view source, const std::vector<LibrarySource>& libs) {
    CompileResult r;
    std::string where;
    try {
        if (source.size() > kMaxSourceBytes) throw CompileError(1, 1, "module is longer than 64 KB");
        auto prog = std::make_shared<Program>();
        int codeLine = 1;
        const size_t start = parseHeader(source, *prog, codeLine);
        if (prog->kind == ModuleKind::Library) validNamespace(prog->ns);
        Lexer lex(source.substr(start), codeLine);
        std::vector<Token> toks = lex.run();
        Compiler c(toks, lex.comments(), *prog);
        // Libraries: the built-in ones, then the project's. Their tokens must outlive the compile.
        std::vector<std::unique_ptr<LoadedLibrary>> loaded;
        auto load = [&](const LibrarySource& l) {
            loaded.push_back(std::make_unique<LoadedLibrary>(lexLibrary(l)));
            where = "library '" + loaded.back()->ns + "', ";
            c.loadLibrary(loaded.back()->ns, loaded.back()->toks, loaded.back()->comments);
            where.clear();
        };
        // A library compiling on its own doesn't load itself.
        const bool self = prog->kind == ModuleKind::Library;
        for (const LibrarySource& l : standardLibraries())
            if (!self || l.source != source) load(l);
        for (const LibrarySource& l : libs)
            if (!self || l.ns != prog->ns) load(l);
        if (prog->kind == ModuleKind::Library) c.runLibrary();
        else c.run();
        r.program = std::move(prog);
    } catch (const CompileError& e) {
        r.line = e.line;
        r.col = e.col;
        r.error = where + "line " + std::to_string(e.line) + ", col " + std::to_string(e.col) + ": " + e.what();
    }
    return r;
}

ModuleKind moduleKindOf(std::string_view source) {
    Program p;
    int line = 1;
    try {
        parseHeader(source, p, line);
    } catch (const CompileError&) {
    }
    return p.kind;
}

std::vector<FnDoc> libraryDocs(const LibrarySource& lib) {
    Program p;
    LoadedLibrary l = lexLibrary(lib);
    std::vector<Token> none{Token{Tok::End, {}, 0, 1, 1}};
    std::vector<Comment> noComments;
    Compiler c(none, noComments, p);
    try {
        c.loadLibrary(l.ns, l.toks, l.comments);
    } catch (const CompileError&) {
        return {};
    }
    return c.libDocs_;
}

}  // namespace caw
