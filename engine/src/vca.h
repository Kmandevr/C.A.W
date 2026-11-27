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
// open every bus its members are heard through; its mute mutes the tracks of a member folder without a bus.
struct VcaTable {
    struct Group {
        std::string id;
        std::vector<AutomationPointSpec> lane;  // a volume lane (sorted); empty: the fader below
        // Live (the control thread writes them, caw_engine_set_vca; the audio thread reads them).
        std::atomic<uint64_t> volume{0};  // bits of a double, linear 0..kMaxMixGain
        std::atomic<bool> mute{false}, solo{false};
        // Audio thread: the gain at the end of the last chunk, and this chunk's gain at its start and end.
        double gain = 1.0, from = 1.0, to = 1.0;
    };
    std::unique_ptr<Group[]> groups;
    int count = 0;
    // Per slot index, bit g for group g (kMaxVcaGroups <= 32; past the end: none): the slot is a member (its level
    // follows the group), the group's mute reaches it, and the group's solo reaches it.
    struct SlotBits {
        uint32_t level = 0, mute = 0, solo = 0;
    };
    std::vector<SlotBits> slots;

    SlotBits bits(int slot) const noexcept {
        return slot >= 0 && static_cast<size_t>(slot) < slots.size() ? slots[static_cast<size_t>(slot)] : SlotBits{};
    }
    int find(std::string_view id) const noexcept;  // the group's index, or -1
    // Control thread: a group's live fader, mute and solo (volume clamped to 0..kMaxMixGain; NaN is 0).
    void set(int group, double volume, bool mute, bool solo) noexcept;
    // Audio thread, when this table replaces `was`: groups with the same id carry on from the gain they had.
    void takeHistory(const VcaTable& was) noexcept;
    // Audio thread, once a chunk: each group's gain at the chunk's start and end. A lane is read at the song steps
    // of the chunk's first frame and of the next chunk's; the fader is followed by the track faders' one-pole
    // smoothing over the chunk (`decay`: what is left of a step after the chunk's frames).
    void advance(double stepFrom, double stepTo, double decay) noexcept;
    // Audio thread: the slot's VCA gain for each of the chunk's m frames (the product of its groups' gains, ramped
    // across the chunk), and false (nothing written) when it is in no group.
    bool ramp(int slot, int m, double* out) const noexcept;
    // Audio thread: whether one of the slot's groups is muted, or soloed.
    void flags(int slot, bool& mute, bool& solo) const noexcept;
};

// Builds the table for a project's groups: `slotOf` maps a layer id to its slot (-1: none, left out). Null when the
// project has no groups.
std::unique_ptr<VcaTable> makeVcaTable(const ProjectSpec& p, const std::function<int(const std::string&)>& slotOf);

}  // namespace caw
