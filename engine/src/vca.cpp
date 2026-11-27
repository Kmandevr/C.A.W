// VCA groups: the table's build (control thread) and its per-chunk gains and flags (audio thread).
#include "vca.h"

#include "params.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <map>
#include <set>

namespace caw {

int VcaTable::find(std::string_view id) const noexcept {
    for (int g = 0; g < count; ++g)
        if (groups[g].id == id) return g;
    return -1;
}

void VcaTable::set(int group, double volume, bool mute, bool solo) noexcept {
    if (group < 0 || group >= count) return;
    Group& g = groups[group];
    const double v = std::isfinite(volume) ? std::clamp(volume, 0.0, kMaxMixGain) : 0.0;
    g.volume.store(std::bit_cast<uint64_t>(v), std::memory_order_relaxed);
    g.mute.store(mute, std::memory_order_relaxed);
    g.solo.store(solo, std::memory_order_relaxed);
}

void VcaTable::takeHistory(const VcaTable& was) noexcept {
    if (&was != replaces) return;  // not the table it was built from: its groups start at their levels
    for (int g = 0; g < count; ++g) {
        const int old = groups[g].prev;
        if (old >= 0 && old < was.count) groups[g].gain = was.groups[old].gain;
    }
}

void VcaTable::advance(const double* steps, int m, double coef) noexcept {
    for (int k = 0; k < count; ++k) {
        Group& g = groups[k];
        if (!g.lane.empty() && steps) {
            // The lane replaces the fader (as a track's volume lane does), read at every frame.
            for (int i = 0; i < m; ++i) g.frame[i] = automationLaneValue(g.lane.data(), g.lane.size(), steps[i], 1.0);
            if (m > 0) g.gain = g.frame[m - 1];  // a lane taken away later continues from here
            continue;
        }
        // The fader, smoothed as a track's is (Engine::runTrackNode).
        const double target = std::bit_cast<double>(g.volume.load(std::memory_order_relaxed));
        double gain = g.gain;
        for (int i = 0; i < m; ++i) {
            if (gain != target) {
                gain += (target - gain) * coef;
                if (std::fabs(target - gain) < 1e-6) gain = target;
            }
            g.frame[i] = gain;
        }
        g.gain = gain;
    }
}

bool VcaTable::product(int slot, int m, double* out) const noexcept {
    uint32_t bits = this->bits(slot).level;
    if (bits == 0) return false;
    const int first = std::countr_zero(bits);
    bits &= bits - 1;
    std::copy_n(groups[first].frame, m, out);
    while (bits != 0) {
        const int g = std::countr_zero(bits);
        bits &= bits - 1;
        for (int i = 0; i < m; ++i) out[i] *= groups[g].frame[i];
    }
    for (int i = 0; i < m; ++i) out[i] = std::min(out[i], kMaxMixGain);  // 32 groups at +12 dB: still +12 dB
    return true;
}

void VcaTable::flags(int slot, bool& mute, bool& solo) const noexcept {
    const SlotBits b = bits(slot);
    mute = solo = false;
    for (uint32_t m = b.mute; m != 0 && !mute; m &= m - 1)
        mute = groups[std::countr_zero(m)].mute.load(std::memory_order_relaxed);
    for (uint32_t m = b.solo; m != 0 && !solo; m &= m - 1)
        solo = groups[std::countr_zero(m)].solo.load(std::memory_order_relaxed);
}

namespace {

// What a group's mute and solo reach, by layer id, by the rules a layer's own follow (engine_project.cpp).
struct Reach {
    std::set<std::string> level, mute, solo;
};

Reach reachOf(const ProjectSpec& p, const std::map<std::string, const LayerSpec*>& byId, const VcaGroupSpec& g) {
    Reach r;
    const std::set<std::string> members(g.members.begin(), g.members.end());
    const int maxDepth = static_cast<int>(p.layers.size());
    for (const LayerSpec& l : p.layers) {
        if (members.count(l.id)) {
            r.level.insert(l.id);
            r.mute.insert(l.id);
            r.solo.insert(l.id);
            continue;
        }
        // A member folder's descendants: soloed with it, and muted with it when it has no bus. A member folder
        // without a bus has no fader in the mix, so its level reaches what is in it, down to the first bus (which
        // takes it, and passes it on in its sum: a track below it is not scaled twice).
        std::string ancestor = l.parentId;
        bool belowBus = false;
        for (int depth = 0; !ancestor.empty() && depth < maxDepth; ++depth) {
            auto it = byId.find(ancestor);
            if (it == byId.end()) break;
            const bool bus = it->second->folder && it->second->busEnabled;
            if (members.count(ancestor)) {
                r.solo.insert(l.id);
                if (!bus) {
                    r.mute.insert(l.id);
                    if (!belowBus) r.level.insert(l.id);
                }
            }
            belowBus = belowBus || bus;
            ancestor = it->second->parentId;
        }
    }
    // A soloed layer keeps open every bus above it, the bus it plays into and its sends' buses, and theirs.
    std::vector<std::string> open(r.solo.begin(), r.solo.end());
    while (!open.empty()) {
        const std::string id = open.back();
        open.pop_back();
        auto it = byId.find(id);
        if (it == byId.end()) continue;
        const LayerSpec& l = *it->second;
        auto add = [&](const std::string& to) {
            if (!to.empty() && byId.count(to) && r.solo.insert(to).second) open.push_back(to);
        };
        std::string ancestor = l.parentId;
        for (int depth = 0; !ancestor.empty() && depth < maxDepth; ++depth) {
            auto a = byId.find(ancestor);
            if (a == byId.end()) break;
            if (a->second->folder && a->second->busEnabled) add(ancestor);
            ancestor = a->second->parentId;
        }
        add(routeTarget(p, l));
        for (const SendSpec& send : l.sends) add(send.to);
    }
    return r;
}

}  // namespace

std::unique_ptr<VcaTable> makeVcaTable(const ProjectSpec& p, const std::function<int(const std::string&)>& slotOf,
                                       const VcaTable* replaces) {
    const std::vector<VcaGroupSpec>& groups = p.vcaGroups;
    if (groups.empty()) return nullptr;
    std::map<std::string, const LayerSpec*> byId;
    for (const LayerSpec& l : p.layers) byId.emplace(l.id, &l);
    auto t = std::make_unique<VcaTable>();
    const int n = static_cast<int>(std::min<size_t>(groups.size(), static_cast<size_t>(kMaxVcaGroups)));
    t->groups.reset(new VcaTable::Group[static_cast<size_t>(n)]);
    t->count = n;
    t->replaces = replaces;
    auto at = [&](const std::string& id) -> VcaTable::SlotBits* {
        const int slot = slotOf(id);
        if (slot < 0) return nullptr;
        if (static_cast<size_t>(slot) >= t->slots.size()) t->slots.resize(static_cast<size_t>(slot) + 1);
        return &t->slots[static_cast<size_t>(slot)];
    };
    for (int g = 0; g < n; ++g) {
        const VcaGroupSpec& spec = groups[static_cast<size_t>(g)];
        VcaTable::Group& out = t->groups[g];
        out.id = spec.id;
        out.lane = spec.volumeLane;
        t->hasLane = t->hasLane || !out.lane.empty();
        out.prev = replaces ? replaces->find(spec.id) : -1;  // the audio thread carries its gain by this index
        t->set(g, spec.volume, spec.mute, spec.solo);
        // A new group starts at its level (a member slot's own ramp smooths the change: Engine::runVca).
        out.gain = out.lane.empty() ? std::bit_cast<double>(out.volume.load()) : out.lane.front().value;
        const uint32_t bit = 1u << g;
        const Reach reach = reachOf(p, byId, spec);
        for (const std::string& id : reach.level)
            if (VcaTable::SlotBits* b = at(id)) b->level |= bit;
        for (const std::string& id : reach.mute)
            if (VcaTable::SlotBits* b = at(id)) b->mute |= bit;
        for (const std::string& id : reach.solo)
            if (VcaTable::SlotBits* b = at(id)) b->solo |= bit;
    }
    return t;
}

}  // namespace caw
