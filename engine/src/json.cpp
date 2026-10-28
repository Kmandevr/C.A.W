// Minimal recursive JSON parser with depth and size limits, plus string escaping for output.
#include "json.h"

#include <cstdio>
#include <cstdlib>

namespace caw {

const Json* Json::get(const std::string& key) const {
    if (type != Type::Object) return nullptr;
    auto it = obj.find(key);
    return it == obj.end() ? nullptr : &it->second;
}

double Json::number(const std::string& key, double fallback) const {
    const Json* j = get(key);
    if (!j) return fallback;
    if (j->type == Type::Number) return j->num;
    if (j->type == Type::Bool) return j->b ? 1.0 : 0.0;
    return fallback;
}

std::string Json::string(const std::string& key, const std::string& fallback) const {
    const Json* j = get(key);
    return j && j->type == Type::String ? j->str : fallback;
}

bool Json::boolean(const std::string& key, bool fallback) const {
    const Json* j = get(key);
    if (!j) return fallback;
    if (j->type == Type::Bool) return j->b;
    if (j->type == Type::Number) return j->num != 0.0;
    return fallback;
}

namespace {

constexpr size_t kMaxJsonBytes = 16 * 1024 * 1024;
constexpr int kMaxJsonDepth = 64;

class Parser {
public:
    explicit Parser(std::string_view s) : s_(s) {}

    bool parse(Json& out, std::string& err) {
        if (s_.size() > kMaxJsonBytes) {
            err = "project is too large";
            return false;
        }
        if (!value(out, 0)) {
            err = err_.empty() ? "malformed JSON" : err_;
            err += " at byte " + std::to_string(i_);
            return false;
        }
        ws();
        if (i_ != s_.size()) {
            err = "extra text after JSON at byte " + std::to_string(i_);
            return false;
        }
        return true;
    }

private:
    void ws() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\n' || s_[i_] == '\r' || s_[i_] == '\t')) ++i_;
    }

    bool lit(const char* w) {
        size_t n = 0;
        while (w[n]) ++n;
        if (s_.substr(i_, n) != w) return false;
        i_ += n;
        return true;
    }

    static void utf8(std::string& o, unsigned cp) {
        if (cp < 0x80) {
            o += static_cast<char>(cp);
        } else if (cp < 0x800) {
            o += static_cast<char>(0xC0 | (cp >> 6));
            o += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            o += static_cast<char>(0xE0 | (cp >> 12));
            o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            o += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            o += static_cast<char>(0xF0 | (cp >> 18));
            o += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            o += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            o += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool hex4(unsigned& v) {
        if (i_ + 4 > s_.size()) return false;
        v = 0;
        for (int k = 0; k < 4; ++k) {
            const char c = s_[i_++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= static_cast<unsigned>(c - '0');
            else if (c >= 'a' && c <= 'f') v |= static_cast<unsigned>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= static_cast<unsigned>(c - 'A' + 10);
            else return false;
        }
        return true;
    }

    bool string(std::string& o) {
        if (i_ >= s_.size() || s_[i_] != '"') return false;
        ++i_;
        while (i_ < s_.size()) {
            const char c = s_[i_++];
            if (c == '"') return true;
            if (c != '\\') {
                o += c;
                continue;
            }
            if (i_ >= s_.size()) return false;
            const char e = s_[i_++];
            switch (e) {
                case '"': o += '"'; break;
                case '\\': o += '\\'; break;
                case '/': o += '/'; break;
                case 'b': o += '\b'; break;
                case 'f': o += '\f'; break;
                case 'n': o += '\n'; break;
                case 'r': o += '\r'; break;
                case 't': o += '\t'; break;
                case 'u': {
                    unsigned cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp < 0xDC00 && s_.substr(i_, 2) == "\\u") {
                        i_ += 2;
                        unsigned lo;
                        if (!hex4(lo)) return false;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    utf8(o, cp);
                    break;
                }
                default: return false;
            }
        }
        return false;
    }

    bool value(Json& out, int depth) {
        if (depth > kMaxJsonDepth) {
            err_ = "JSON is nested too deeply";
            return false;
        }
        ws();
        if (i_ >= s_.size()) return false;
        const char c = s_[i_];
        if (c == '{') {
            ++i_;
            out.type = Json::Type::Object;
            ws();
            if (i_ < s_.size() && s_[i_] == '}') {
                ++i_;
                return true;
            }
            while (true) {
                ws();
                std::string key;
                if (!string(key)) return false;
                ws();
                if (i_ >= s_.size() || s_[i_] != ':') return false;
                ++i_;
                Json v;
                if (!value(v, depth + 1)) return false;
                out.obj[key] = std::move(v);
                ws();
                if (i_ < s_.size() && s_[i_] == ',') {
                    ++i_;
                    continue;
                }
                if (i_ < s_.size() && s_[i_] == '}') {
                    ++i_;
                    return true;
                }
                return false;
            }
        }
        if (c == '[') {
            ++i_;
            out.type = Json::Type::Array;
            ws();
            if (i_ < s_.size() && s_[i_] == ']') {
                ++i_;
                return true;
            }
            while (true) {
                Json v;
                if (!value(v, depth + 1)) return false;
                out.arr.push_back(std::move(v));
                ws();
                if (i_ < s_.size() && s_[i_] == ',') {
                    ++i_;
                    continue;
                }
                if (i_ < s_.size() && s_[i_] == ']') {
                    ++i_;
                    return true;
                }
                return false;
            }
        }
        if (c == '"') {
            out.type = Json::Type::String;
            return string(out.str);
        }
        if (lit("true")) {
            out.type = Json::Type::Bool;
            out.b = true;
            return true;
        }
        if (lit("false")) {
            out.type = Json::Type::Bool;
            return true;
        }
        if (lit("null")) return true;
        if (c == '-' || (c >= '0' && c <= '9')) {
            const size_t start = i_;
            ++i_;
            while (i_ < s_.size() && ((s_[i_] >= '0' && s_[i_] <= '9') || s_[i_] == '.' || s_[i_] == 'e' ||
                                      s_[i_] == 'E' || s_[i_] == '+' || s_[i_] == '-'))
                ++i_;
            const std::string t(s_.substr(start, i_ - start));
            char* end = nullptr;
            out.type = Json::Type::Number;
            out.num = std::strtod(t.c_str(), &end);
            return end && *end == '\0';
        }
        return false;
    }

    std::string_view s_;
    size_t i_ = 0;
    std::string err_;
};

}  // namespace

bool parseJson(std::string_view text, Json& out, std::string& error) {
    out = Json{};
    return Parser(text).parse(out, error);
}

std::string jsonEscape(std::string_view s) {
    std::string o;
    o.reserve(s.size() + 8);
    for (const char ch : s) {
        const unsigned char c = static_cast<unsigned char>(ch);
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    o += buf;
                } else {
                    o += ch;
                }
        }
    }
    return o;
}

}  // namespace caw
