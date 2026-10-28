// Turns a module's source text (.caw header plus code) into a Program, or a one-line error with its position.
#pragma once

#include <memory>
#include <string>
#include <string_view>

#include "program.h"

namespace caw {

struct CompileResult {
    std::shared_ptr<const Program> program;  // null on error
    std::string error;                       // "line 3, col 7: unknown name 'foo'"
    int line = 0, col = 0;
};

CompileResult compileModule(std::string_view source);

}  // namespace caw
