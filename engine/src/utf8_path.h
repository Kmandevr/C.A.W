// UTF-8 file names on every platform: paths from UTF-8 text and back, and fopen through the path (wide on Windows).
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

namespace caw {

// The engine's strings are UTF-8; std::filesystem::path(std::string) reads them in the ANSI code page on Windows.
inline std::filesystem::path utf8Path(const std::string& s) {
    return std::filesystem::path(std::u8string(s.begin(), s.end()));
}
inline std::string pathText(const std::filesystem::path& p) {
    const auto u = p.generic_u8string();
    return std::string(u.begin(), u.end());
}
// fopen for a path: _wfopen on Windows (a narrow fopen cannot open non-ASCII names there).
inline std::FILE* openFile(const std::filesystem::path& p, const char* mode) {
#ifdef _WIN32
    wchar_t m[8] = {};
    for (size_t i = 0; i < 7 && mode[i]; ++i) m[i] = static_cast<wchar_t>(mode[i]);
    return _wfopen(p.c_str(), m);
#else
    return std::fopen(p.c_str(), mode);
#endif
}
// Deletes a file named by UTF-8 text; never throws for a file system error (false then, or when there was none).
inline bool removeFile(const std::string& path) {
    std::error_code ec;
    return std::filesystem::remove(utf8Path(path), ec);
}
// Renames a file named by UTF-8 text (remove `to` first to replace it on every platform); never throws for a
// file system error.
inline bool renameFile(const std::string& from, const std::string& to) {
    std::error_code ec;
    std::filesystem::rename(utf8Path(from), utf8Path(to), ec);
    return !ec;
}
// 64-bit positions (long is 32-bit on Windows, so ftell fails past 2 GB there).
inline int64_t tellFile(std::FILE* f) {
#ifdef _WIN32
    return _ftelli64(f);
#else
    return static_cast<int64_t>(ftello(f));
#endif
}
inline bool seekFile(std::FILE* f, int64_t at, int whence) {
#ifdef _WIN32
    return _fseeki64(f, at, whence) == 0;
#else
    return fseeko(f, static_cast<off_t>(at), whence) == 0;
#endif
}

}  // namespace caw
