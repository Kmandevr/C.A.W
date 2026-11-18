// Reads and writes a component's capability declarations in their one canonical form (declarations.h).
#include "declarations.h"

#include <set>

namespace caw::scan {
namespace {

constexpr size_t kMaxReasonChars = 200;
constexpr size_t kMaxSites = 8;
constexpr size_t kMaxHostBytes = 253;

// Valid UTF-8 of 1..200 code points with no control characters (C0, DEL, C1).
bool validReason(const std::string& s) {
    size_t chars = 0;
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        uint32_t cp = 0;
        size_t n = 0;
        if (c < 0x80) { cp = c; n = 1; }
        else if ((c & 0xE0) == 0xC0) { cp = c & 0x1F; n = 2; }
        else if ((c & 0xF0) == 0xE0) { cp = c & 0x0F; n = 3; }
        else if ((c & 0xF8) == 0xF0) { cp = c & 0x07; n = 4; }
        else return false;
        if (i + n > s.size()) return false;
        for (size_t k = 1; k < n; ++k) {
            const unsigned char d = static_cast<unsigned char>(s[i + k]);
            if ((d & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (d & 0x3F);
        }
        if ((n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF)) ||
            (cp >= 0xD800 && cp <= 0xDFFF))
            return false;
        if (cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp <= 0x9F)) return false;
        i += n;
        ++chars;
    }
    return chars >= 1 && chars <= kMaxReasonChars;
}

// A lowercase DNS name: labels of a-z, 0-9 and '-', not starting or ending with '-', joined by single dots.
bool validHost(const std::string& h) {
    if (h.empty() || h.size() > kMaxHostBytes) return false;
    size_t label = 0;
    for (size_t i = 0; i < h.size(); ++i) {
        const char c = h[i];
        if (c == '.') {
            if (label == 0 || h[i - 1] == '-') return false;
            label = 0;
            continue;
        }
        const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c == '-' && label > 0);
        if (!ok || ++label > 63) return false;
    }
    return label > 0 && h.back() != '-';
}

bool readList(const Json& list, uint32_t maxEntries, std::vector<Declaration>& out, std::string& error) {
    if (list.type != Json::Type::Array) return error = "\"capabilities\" is not a list", false;
    if (list.arr.size() > maxEntries) return error = "more than 16 capabilities are declared", false;
    std::set<Capability> seen;
    for (const Json& entry : list.arr) {
        if (entry.type != Json::Type::Object) return error = "a capability is not an object", false;
        for (const auto& [key, value] : entry.obj)
            if (key != "id" && key != "reason" && key != "sites")
                return error = "a capability has the unknown key \"" + key + "\"", false;
        const Json* id = entry.get("id");
        const Json* reason = entry.get("reason");
        const Json* sites = entry.get("sites");
        Declaration d;
        if (!id || id->type != Json::Type::String || !capabilityFromId(id->str, d.capability))
            return error = "a capability has a missing or unknown id", false;
        if (!seen.insert(d.capability).second)
            return error = std::string("the capability ") + capabilityId(d.capability) + " is declared twice", false;
        if (!reason || reason->type != Json::Type::String || !validReason(reason->str))
            return error = std::string("the capability ") + capabilityId(d.capability) +
                           " needs a reason of 1 to 200 characters with no control characters", false;
        d.reason = reason->str;
        if (sites) {
            if (d.capability != Capability::Internet)
                return error = "only the internet capability lists sites", false;
            if (sites->type != Json::Type::Array || sites->arr.empty() || sites->arr.size() > kMaxSites)
                return error = "internet's sites must list 1 to 8 host names", false;
            for (const Json& site : sites->arr) {
                if (site.type != Json::Type::String || !validHost(site.str))
                    return error = "a site is not a lowercase host name", false;
                d.sites.push_back(site.str);
            }
        }
        out.push_back(std::move(d));
    }
    return true;
}

}  // namespace

std::string canonicalDeclarations(const std::vector<Declaration>& list) {
    std::string s = R"({"format":"caw.capabilities","version":1,"capabilities":[)";
    for (size_t i = 0; i < list.size(); ++i) {
        const Declaration& d = list[i];
        if (i) s += ',';
        s += R"({"id":")";
        s += capabilityId(d.capability);
        s += R"(","reason":")" + jsonEscape(d.reason) + '"';
        if (!d.sites.empty()) {
            s += R"(,"sites":[)";
            for (size_t k = 0; k < d.sites.size(); ++k) s += (k ? ",\"" : "\"") + jsonEscape(d.sites[k]) + '"';
            s += ']';
        }
        s += '}';
    }
    return s + "]}";
}

bool parseDeclarationSection(std::string_view bytes, uint32_t maxBytes, uint32_t maxEntries,
                             std::vector<Declaration>& out, std::string& error) {
    out.clear();
    if (bytes.size() > maxBytes) return error = "the declaration section is larger than 16 KiB", false;
    while (!bytes.empty() && bytes.back() == '\0') bytes.remove_suffix(1);
    if (bytes.find('\0') != std::string_view::npos)
        return error = "the declaration section holds more than one declaration", false;
    Json root;
    std::string parseError;
    if (!parseJson(bytes, root, parseError)) return error = "the declaration section is not JSON: " + parseError, false;
    if (root.type != Json::Type::Object) return error = "the declaration section is not a JSON object", false;
    const Json* format = root.get("format");
    const Json* version = root.get("version");
    const Json* list = root.get("capabilities");
    if (!format || format->type != Json::Type::String || format->str != "caw.capabilities")
        return error = "the declaration section's format is not caw.capabilities", false;
    if (!version || version->type != Json::Type::Number || version->num != 1)
        return error = "the declaration section's version is not 1", false;
    if (!list) return error = "the declaration section has no capabilities list", false;
    if (!readList(*list, maxEntries, out, error)) return false;
    if (canonicalDeclarations(out) != bytes) {
        out.clear();
        return error = "the declaration section is not in the canonical form", false;
    }
    return true;
}

bool declarationsFromManifest(const Json& manifest, uint32_t maxEntries, std::vector<Declaration>& out,
                              std::string& error) {
    out.clear();
    const Json* list = manifest.get("capabilities");
    if (!list) return true;
    return readList(*list, maxEntries, out, error);
}

}  // namespace caw::scan
