// The pre-load scan of a file on disk: read with a size cap, hashed (SHA-256), scanned once per hash (an
// in-memory cache), checked against a caw-component.json beside it, and written as JSON for hosts.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

#include "policy.h"
#include "scan.h"

namespace caw::scan {

struct FileScan {
    bool ok = false;
    std::string error;          // why the file could not be read
    std::string sha256;         // of the whole file
    uint64_t size = 0;
    bool cached = false;        // the report came from the cache (the same bytes were scanned before)
    // The report, with a Declarations finding added when the manifest beside the file disagrees with it.
    std::shared_ptr<const Report> report;
    bool manifestChecked = false;  // a caw-component.json for this component lay beside the file
    bool tampered = false;
};

// Reads and scans `path` (UTF-8). With `expectedId`, a caw-component.json in the same folder whose component
// id is that id must declare exactly what the binary embeds (otherwise: tampering, which blocks).
// Off the audio thread only: it reads the whole file.
FileScan scanFile(const std::string& path, std::string_view expectedId = {});

// The cache: forget every report (tests), and how many files were actually parsed so far.
void clearScanCache();
uint64_t scansRun();

// {"ok","sha256","size","format","arch","host","verdict","reason","grace_applied","cached","manifest_checked",
//  "declarations":"absent"|"valid"|"invalid","declared":[{"id","title","reason","sites"}],"blocked_by":[ids],
//  "summary":{"imports","constructors","tls_callbacks","component_entry"},
//  "findings":[{"capability","title","kind","evidence","strength","severity","declared","blocks"}]}
std::string scanJson(const FileScan& scan, const Decision& decision, const PolicyInput& input);
// {"ok":false,"error":...} for a file that could not be read.
std::string scanErrorJson(const std::string& error);

}  // namespace caw::scan
