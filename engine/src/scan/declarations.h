// A C.A.W component's capability declarations: the canonical JSON its build embeds (section caw_caps on ELF,
// .cawcap on PE) and the "capabilities" list of its caw-component.json, read with limits and failing closed.
#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "json.h"
#include "scan.h"

namespace caw::scan {

// The canonical bytes for a list (docs/native-module-sdk.md, "Declaring capabilities"):
// {"format":"caw.capabilities","version":1,"capabilities":[{"id":"…","reason":"…"[,"sites":["…"]]},…]}
// with no whitespace, entries in manifest order, and only `"` and `\` escaped (as \" and \\).
std::string canonicalDeclarations(const std::vector<Declaration>& list);

// Reads a section's bytes (trailing NUL padding allowed). False with a reason for anything but the canonical
// form of a valid list: bad JSON, a key out of place, an unknown or repeated id, a reason that is empty, longer
// than 200 characters or holds a control character, sites on anything but internet, more than 8 sites or a
// malformed host name, more than `maxEntries` entries or `maxBytes` bytes.
bool parseDeclarationSection(std::string_view bytes, uint32_t maxBytes, uint32_t maxEntries,
                             std::vector<Declaration>& out, std::string& error);

// The same rules for a manifest's "capabilities" array (absent: an empty list).
bool declarationsFromManifest(const Json& manifest, uint32_t maxEntries, std::vector<Declaration>& out,
                              std::string& error);

}  // namespace caw::scan
