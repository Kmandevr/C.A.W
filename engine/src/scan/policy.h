// The pre-load scan's verdict: a pure function of a scan report and who is asking (no parsing, no I/O).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "scan.h"

namespace caw::scan {

enum class Verdict : uint8_t { Clean, Notice, Warning, Blocked };
const char* verdictId(Verdict v) noexcept;

// A C.A.W component declares what it needs and is held to it; a CLAP/VST3 plug-in cannot, so its findings
// at most warn.
enum class Host : uint8_t { Component, Plugin };

struct PolicyInput {
    Host host = Host::Component;
    // The app's grace for a component the user trusted before 1.0.7 (CAW_LOAD_LEGACY_GRACE): a binary with no
    // declaration section loads with its undeclared capabilities as warnings. Never for a malformed file,
    // invalid or tampered declarations, or a binary that has a section.
    bool legacyGrace = false;
};

struct Weighed {
    Finding finding;
    Severity severity = Severity::Notice;  // as this host weighs it
    bool declared = false;                 // the component declares its capability
    bool blocks = false;
};

struct Decision {
    Verdict verdict = Verdict::Clean;
    std::vector<Weighed> findings;
    uint32_t blockedBy = 0;  // capability bits whose undeclared use blocks
    bool graceApplied = false;
    std::string reason;      // for a block: one sentence naming what blocked it
};

// For a component: a certain use (import, library, export, system call, writable code, packer section) of a
// capability it does not declare blocks; so does a malformed or unsupported file and invalid or tampered
// declarations. A declared use is a notice; hints keep their own weight and never block; load-time code is a
// notice. For a plug-in every finding keeps its own weight and nothing blocks.
Decision decide(const Report& report, const PolicyInput& input);

}  // namespace caw::scan
