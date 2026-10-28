// Minimal JSON reader and writer for project files and the C API's results (no third-party dependency).
#pragma once

#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace caw {

struct Json {
    enum class Type { Null, Bool, Number, String, Array, Object } type = Type::Null;
    bool b = false;
    double num = 0.0;
    std::string str;
    std::vector<Json> arr;
    std::map<std::string, Json> obj;

    const Json* get(const std::string& key) const;
    double number(const std::string& key, double fallback) const;
    std::string string(const std::string& key, const std::string& fallback = "") const;
    bool boolean(const std::string& key, bool fallback) const;
};

// Parses text into out; returns false and sets error on malformed input. Depth and size are bounded.
bool parseJson(std::string_view text, Json& out, std::string& error);

// Escapes a string for writing inside JSON quotes.
std::string jsonEscape(std::string_view s);

}  // namespace caw
