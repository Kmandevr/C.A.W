// VCA groups (REAPER-style): an immutable table of groups, each a fader, mute and solo over its members' levels.
#pragma once
#include "project.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace caw {

// A project's VCA groups as the audio thread reads them (docs/engine.md, "VCA groups"). Built on the control thread
// (makeVcaTable) and handed over by a command; replaced and freed like the slots' automation, never on the audio
// thread. Nothing is summed: a member slot's own gain is multiplied by the product of its groups' gains, and a
// group's mute or solo acts on its members beside (never instead of) their own. A folder bus may be a member (its
// fader is scaled); a bus and one of its children in the same group scale that child twice, as REAPER does. Mute and
// solo reach as a layer's own do (engine_project.cpp): a group's solo solos its member folders' descendants and keeps
// open every bus its members are heard through; its fader and mute reach the tracks of a member folder without a bus (which has no fader of its own in
// the mix). The product of a slot's groups is held to +12 dB (kMaxMixGain), as one fader is.
struct VcaTable {
    static constexpr int kFrames = 64;  // a chunk's frames at most (Engine's kBlock; checked in engine_impl.h)
    struct Group {
        std::string id;
        std::vector<AutomationPointSpec> lane;  // a volume lane (sorted); empty: the fader below
        int prev = -1;  // its index in the table this one replaces (`replaces`), -1: a new group
        // Live (the control thread writes them, caw_engine_set_vca; the audio thread reads them).
        std::atomic<uint64_t> volume{0};  // bits of a double, linear 0..kMaxMixGain
        std::atomic<bool> mute{false}, solo{false};
        // Audio thread: the gain after the last frame run, and this chunk's gain per frame.
        double gain = 1.0;
        double frame[kFrames] = {};
    };
    std::unique_ptr<Group[]> groups;
    int count = 0;
    bool hasLane = false;               // some group has a lane: advance needs each frame's song step
    const VcaTable* replaces = nullptr;  // the table this one was built to replace (compared, never read)
    // Per slot index, bit g for group g (kMaxVcaGroups <= 32; past the end: none): the slot's level follows the
    // group (a member, or a track in a member folder without a bus), the group's mute reaches it, its solo reaches it.
    struct SlotBits {
        uint32_t level = 0, mute = 0, solo = 0;
    };
    std::vector<SlotBits> slots;

    SlotBits bits(int slot) const noexcept {
        return slot >= 0 && static_cast<size_t>(slot) < slots.size() ? slots[static_cast<size_t>(slot)] : SlotBits{};
    }
    int find(std::string_view id) const noexcept;  // control thread: the group's index, or -1
    // Control thread: a group's live fader, mute and solo (volume clamped to 0..kMaxMixGain; NaN is 0).
    void set(int group, double volume, bool mute, bool solo) noexcept;
    // Audio thread, when this table replaces `was`: each group that stays carries on from its gain (by the index
    // map makeVcaTable made; nothing when `was` is not the table it was built to replace).
    void takeHistory(const VcaTable& was) noexcept;
    // Audio thread, once a chunk of m frames: each group's gain per frame. A lane is read at every frame's song step
    // (`steps`, needed when hasLane), as a track's volume lane is; a fader is followed by the track faders' one-pole
    // (`coef` a frame), so neither depends on how the frames are split into chunks.
    void advance(const double* steps, int m, double coef) noexcept;
    // Audio thread: the slot's product of its groups' gains per frame into out (held to kMaxMixGain, +12 dB), and
    // false (nothing written) when no group's level reaches it.
    bool product(int slot, int m, double* out) const noexcept;
    // Audio thread: whether one of the slot's groups is muted, or soloed.
    void flags(int slot, bool& mute, bool& solo) const noexcept;
};

// Builds the table for a project's groups: `slotOf` maps a layer id to its slot (-1: none, left out); `replaces` is
// the table last sent (null: none), whose groups' gains the new one carries on by id. Null when there are no groups.
std::unique_ptr<VcaTable> makeVcaTable(const ProjectSpec& p, const std::function<int(const std::string&)>& slotOf,
                                       const VcaTable* replaces);

}  // namespace caw
