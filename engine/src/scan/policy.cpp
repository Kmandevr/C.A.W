// The pre-load scan's policy (policy.h): findings and declarations in, a verdict and its reason out.
#include "policy.h"

#include <map>

namespace caw::scan {

const char* verdictId(Verdict v) noexcept {
    switch (v) {
        case Verdict::Clean: return "clean";
        case Verdict::Notice: return "notice";
        case Verdict::Warning: return "warning";
        case Verdict::Blocked: return "blocked";
    }
    return "blocked";
}

Decision decide(const Report& report, const PolicyInput& input) {
    Decision d;
    uint32_t declared = 0;
    if (report.declarationState == Report::DeclarationState::Valid)
        for (const Declaration& x : report.declarations) declared |= capabilityBit(x.capability);
    const bool graceAllowed = input.legacyGrace && report.declarationState == Report::DeclarationState::Absent;
    std::string structural;                                  // the first malformed/unsupported/declarations reason
    std::map<Capability, std::string> undeclared;            // capability -> first evidence
    for (const Finding& f : report.findings) {
        Weighed w{f, f.severity, (declared & capabilityBit(f.capability)) != 0, false};
        if (input.host == Host::Component) {
            const bool fatal = f.kind == FindingKind::Malformed || f.kind == FindingKind::Unsupported ||
                               f.kind == FindingKind::Declarations;
            if (fatal) {
                w.severity = Severity::Warning;
                w.blocks = true;
                if (structural.empty()) structural = f.evidence;
            } else if (f.kind == FindingKind::LoadTime) {
                w.severity = Severity::Notice;
            } else if (f.strength == Strength::Certain) {
                if (w.declared) {
                    w.severity = Severity::Notice;
                } else {
                    w.severity = Severity::Warning;
                    if (graceAllowed) {
                        d.graceApplied = true;
                    } else {
                        w.blocks = true;
                        d.blockedBy |= capabilityBit(f.capability);
                        undeclared.emplace(f.capability, f.evidence);
                    }
                }
            }
        }
        if (w.blocks) d.verdict = Verdict::Blocked;
        else if (d.verdict != Verdict::Blocked && w.severity == Severity::Warning) d.verdict = Verdict::Warning;
        else if (d.verdict == Verdict::Clean) d.verdict = Verdict::Notice;
        d.findings.push_back(std::move(w));
    }
    if (d.verdict == Verdict::Blocked) {
        d.reason = "The pre-load scan blocked this component: ";
        if (!structural.empty()) {
            d.reason += structural;
            if (!undeclared.empty()) d.reason += "; and ";
        }
        if (!undeclared.empty()) {
            d.reason += "it uses ";
            size_t i = 0;
            for (const auto& [capability, evidence] : undeclared) {
                if (i++) d.reason += i == undeclared.size() ? " and " : ", ";
                d.reason += std::string(capabilityTitle(capability)) + " (" + capabilityId(capability) + ": " + evidence + ")";
            }
            d.reason += " without declaring it. A C.A.W component declares each capability it needs, with a reason, "
                        "in its caw-component.json.";
        } else {
            d.reason += ".";
        }
    }
    return d;
}

}  // namespace caw::scan
