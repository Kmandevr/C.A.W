// Function documentation output: the reference note, the agent guide, in-app help JSON and the docs check.
#pragma once

#include <string>
#include <vector>

namespace caw {

// docs/library.md: every built-in function, constant and library function with arguments and examples.
std::string libraryReference(const std::string& updated);
// docs/agent-guide.md: the language in brief and every function on one line, for AI agents.
std::string agentGuide(const std::string& updated);
// The same functions as JSON for the app's help and autocomplete.
std::string libraryJson();
// Problems that fail CI: undocumented functions or arguments, and examples that don't compile or are silent.
std::vector<std::string> checkLibrary();

}  // namespace caw
