// The Benchmark's engine-part breakdown: process() time split by part (mix, routing, sends, ...), exclusive, no allocation.
#pragma once

#include <cstdint>

namespace caw {

// The parts of Engine::process a profile run splits its time into (the result JSON's "parts", in this order).
enum class Part : uint8_t {
    Mix = 0,     // summing (the mix graph's edges into buses and the master) and each track's gain and pan
    Routing,     // folder buses (their own work outside effects, sends and meters) and latency compensation
    Sends,       // sends and sidechain keys: the source's route gains and delay, the destination's sum
    Automation,  // automation lanes and parameter changes resolved for components, project modulators and links
    Voices,      // notes into instruments: pattern events, device MIDI, motion, per-note FX slots (start, steal, release)
    Samples,     // audio-clip tracks' players (streaming, stretching, resampling) and the sampler
    Metering,    // meters, scopes, correlation and loudness
    DeviceIo,    // the device callback's FIFO and input bridge (live runs only; outside process())
    MixPool,     // the mix pool's overhead: parking, waking and waiting for workers
    Master,      // the master stage: gain, DC block, the master chain, the metronome and the safety limiter
    Devices,     // instrument and effect processing (the per-device costs break it down)
    Other,       // the remainder: commands, planning, transport
    Count
};

inline const char* partName(Part p) noexcept {
    switch (p) {
        case Part::Mix: return "mix";
        case Part::Routing: return "routing";
        case Part::Sends: return "sends";
        case Part::Automation: return "automation";
        case Part::Voices: return "voices";
        case Part::Samples: return "samples";
        case Part::Metering: return "metering";
        case Part::DeviceIo: return "device_io";
        case Part::MixPool: return "mix_pool";
        case Part::Master: return "master";
        case Part::Devices: return "devices";
        case Part::Other: return "other";
        case Part::Count: break;
    }
    return "other";
}

inline constexpr int kPartCount = static_cast<int>(Part::Count);

// Exclusive time per part: one part is current at a time, and a switch adds the time since the last switch to the
// part that was current. A scope (PartScope) switches in and back out, so nested scopes give each part only its
// own time and the parts of one process() call add up to the call exactly (what no scope claims is Other). Filled
// by one thread at a time (a profiling engine's mix is serial); fixed storage, so the audio thread never allocates.
struct PartProfile {
    uint64_t ns[kPartCount] = {};
    Part current = Part::Other;
    uint64_t last = 0;
    uint64_t mark = 0;  // when the mix graph last finished a node (or started): what it did since is for the next

    static uint64_t now() noexcept;  // steady clock, ns (component_chain.cpp: <chrono> stays out of this header)
    // process() begins: Other is current from here.
    void begin() noexcept {
        current = Part::Other;
        last = now();
    }
    // Makes `next` current and returns the part that was.
    Part switchTo(Part next) noexcept {
        const uint64_t t = now();
        ns[static_cast<int>(current)] += t - last;
        last = t;
        const Part was = current;
        current = next;
        return was;
    }
    // Makes `next` current, and the mix graph's time since `mark` (summing the next node's inputs, dispatch), spent
    // in Mix, becomes next's: a folder bus's children summed into its input are the folder's routing.
    Part claimSinceMark(Part next) noexcept {
        const uint64_t t = now();
        ns[static_cast<int>(current)] += t - last;
        // Only when Mix was current all along since the mark (the graph between two nodes).
        if (current == Part::Mix && mark >= last && mark <= t) {
            ns[static_cast<int>(Part::Mix)] -= t - mark;
            ns[static_cast<int>(next)] += t - mark;
        }
        last = t;
        const Part was = current;
        current = next;
        return was;
    }
    // process() ends: the time since the last switch goes to the current part.
    void end() noexcept { switchTo(Part::Other); }
    uint64_t total() const noexcept {
        uint64_t s = 0;
        for (uint64_t v : ns) s += v;
        return s;
    }
};

// A part for the scope's life (null profile: nothing, one predictable branch each way). `claim`: the mix graph's
// work for this node since its last node ended is this part's too (PartProfile::claimSinceMark).
class PartScope {
public:
    PartScope(PartProfile* p, Part part, bool claim = false) noexcept : p_(p) {
        if (p_) [[unlikely]] was_ = claim ? p_->claimSinceMark(part) : p_->switchTo(part);
    }
    ~PartScope() {
        if (p_) [[unlikely]] p_->switchTo(was_);
    }
    PartScope(const PartScope&) = delete;
    PartScope& operator=(const PartScope&) = delete;

private:
    PartProfile* p_;
    Part was_ = Part::Other;
};

// Marks where a mix graph node ends (declare it first in the node, so it ends last): what the graph does next is
// for the next node.
class NodeMark {
public:
    explicit NodeMark(PartProfile* p) noexcept : p_(p) {}
    ~NodeMark() {
        if (p_) [[unlikely]] p_->mark = PartProfile::now();
    }
    NodeMark(const NodeMark&) = delete;
    NodeMark& operator=(const NodeMark&) = delete;

private:
    PartProfile* p_;
};

}  // namespace caw
