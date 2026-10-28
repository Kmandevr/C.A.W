// Turns a module's source text (.caw header plus code) into a Program, or a one-line error with its position.
#pragma once

#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "program.h"

namespace caw {

struct CompileResult {
    std::shared_ptr<const Program> program;  // null on error
    std::string error;                       // "line 3, col 7: unknown name 'foo'"
    int line = 0, col = 0;
};

// A library of fn functions: built in (engine/lib) or a project module of kind library.
struct LibrarySource {
    std::string ns;      // namespace; empty takes the header's `namespace:`
    std::string source;
};

// The built-in libraries (engine/lib/*.caw), always available to every module.
const std::vector<LibrarySource>& standardLibraries();

// Compiles a module. The built-in libraries and `libs` are loaded first, so their functions can be called.
CompileResult compileModule(std::string_view source, const std::vector<LibrarySource>& libs = {});

// The project's library modules that compile, in order. Each is checked against the ones before it, so a
// library whose function names clash is left out (and shows its own error) instead of breaking every module.
std::vector<LibrarySource> projectLibraries(const std::vector<std::string_view>& sources);

// The module's kind from its header alone (no compile), so libraries can be found before other modules.
ModuleKind moduleKindOf(std::string_view source);

// The documented functions of one library, with their full names (drum.kick), for the reference.
std::vector<FnDoc> libraryDocs(const LibrarySource& lib);

// JSON fields (without braces) describing a compiled module for the app: kind, mode, name, summary, params (with
// step, kind, choices, tip, header, doc, global), exports, imports and functions.
std::string describeProgram(const Program& p);

}  // namespace caw
