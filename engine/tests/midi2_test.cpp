#include "test.h"

#include "midi2.h"

using namespace caw;

TEST(midi2_decodes_note_on_with_group_channel_and_velocity) {
    Midi2Event event;
    const uint32_t w0 = 0x42903C00u; // group 2, channel 0, note-on, C4
    const uint32_t w1 = 0xFFFF0000u;
    CHECK(decodeMidi2ChannelVoice(w0, w1, event));
    CHECK(event.type == Midi2EventType::NoteOn);
    CHECK_EQ(event.group, 2);
    CHECK_EQ(event.channel, 0);
    CHECK_EQ(event.note, 60);
    CHECK_NEAR(event.value, 1.0, 1e-12);
}

TEST(midi2_decodes_per_note_pitch_and_signed_bend) {
    Midi2Event event;
    CHECK(decodeMidi2ChannelVoice(0x40603C00u, 0x40000000u, event));
    CHECK(event.type == Midi2EventType::PerNotePitch);
    CHECK_EQ(event.note, 60);
    CHECK_NEAR(event.value, -0.5, 1e-8);
    CHECK(decodeMidi2ChannelVoice(0x40E00000u, 0x00000000u, event));
    CHECK(event.type == Midi2EventType::PitchBend);
    CHECK_NEAR(event.value, -1.0, 1e-12);
    CHECK(decodeMidi2ChannelVoice(0x40E00000u, 0x80000000u, event));
    CHECK_NEAR(event.value, 0.0, 1e-12);
    CHECK(decodeMidi2ChannelVoice(0x40E00000u, 0xFFFFFFFFu, event));
    CHECK_NEAR(event.value, 1.0, 1e-8);
}

TEST(midi2_rejects_other_ump_types_and_unknown_statuses) {
    Midi2Event event;
    CHECK(!decodeMidi2ChannelVoice(0x20903C00u, 0xFFFF0000u, event));
    CHECK(!decodeMidi2ChannelVoice(0x40F03C00u, 0xFFFFFFFFu, event));
}


namespace {
Midi2Event midiEvent(Midi2EventType type, uint8_t channel, uint8_t note, uint8_t index, double value, int32_t target = 0) {
    Midi2Event e;
    e.type = type;
    e.channel = channel;
    e.note = note;
    e.index = index;
    e.value = value;
    e.target = target;
    return e;
}
constexpr uint32_t kNormalSlots = Midi2InputQueue::kCapacity - Midi2InputQueue::kReserved;
}  // namespace

TEST(midi2_input_queue_preserves_order_and_bounds_overflow) {
    Midi2InputQueue queue;
    Midi2Event input;
    input.type = Midi2EventType::NoteOn;
    for (uint32_t i = 0; i < kNormalSlots; ++i) {
        input.note = static_cast<uint8_t>(i & 0x7F);
        CHECK(queue.push(input));
    }
    CHECK(!queue.push(input));  // a note on never takes the reserve
    CHECK_EQ(queue.dropped(), 1u);
    Midi2Event output;
    for (uint32_t i = 0; i < kNormalSlots; ++i) {
        CHECK(queue.pop(output));
        CHECK_EQ(output.note, static_cast<uint8_t>(i & 0x7F));
        CHECK_EQ(output.seq, i);  // the producer's sequence, in push order
    }
    CHECK(!queue.pop(output));
}

TEST(midi2_input_queue_flood_keeps_every_release) {
    // A flood of note ons fills the shared slots; the note offs, a sustain off, All Sound Off and All Notes Off
    // still all go in, in the reserve.
    Midi2InputQueue queue;
    for (uint32_t i = 0; i < 2 * Midi2InputQueue::kCapacity; ++i)
        queue.push(midiEvent(Midi2EventType::NoteOn, 0, static_cast<uint8_t>(i & 0x7F), 0, 0.8));
    CHECK_EQ(queue.dropped(), 2 * Midi2InputQueue::kCapacity - kNormalSlots);
    const uint32_t offs = Midi2InputQueue::kReserved - 3;
    for (uint32_t n = 0; n < offs; ++n)
        CHECK(queue.push(midiEvent(Midi2EventType::NoteOff, 0, static_cast<uint8_t>(n & 0x7F), 0, 0)));
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 64, 0.0)));   // sustain off
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 120, 0.0)));  // All Sound Off
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 123, 0.0)));  // All Notes Off
    CHECK(!queue.push(midiEvent(Midi2EventType::NoteOff, 0, 1, 0, 0)));  // every slot taken
    Midi2Event out;
    uint32_t got = 0, offsSeen = 0, releasesSeen = 0, lastSeq = 0;
    while (queue.pop(out)) {
        if (got > 0) CHECK(out.seq > lastSeq);  // pushed straight in: ring order is sequence order
        lastSeq = out.seq;
        ++got;
        if (out.type == Midi2EventType::NoteOff) ++offsSeen;
        if (out.type == Midi2EventType::ControlChange) ++releasesSeen;
    }
    CHECK_EQ(got, Midi2InputQueue::kCapacity);
    CHECK_EQ(offsSeen, offs);
    CHECK_EQ(releasesSeen, 3u);
    CHECK(Midi2InputQueue::releases(midiEvent(Midi2EventType::AllOff, 0, 0, 0, 0)));
    CHECK(Midi2InputQueue::releases(midiEvent(Midi2EventType::ControlChange, 0, 0, 64, 63.0 / 127.0)));
    CHECK(!Midi2InputQueue::releases(midiEvent(Midi2EventType::ControlChange, 0, 0, 64, 64.0 / 127.0)));
}

TEST(midi2_input_queue_merges_continuous_values_under_pressure_by_key) {
    Midi2InputQueue queue;
    for (uint32_t i = 0; i < kNormalSlots; ++i) CHECK(queue.push(midiEvent(Midi2EventType::NoteOn, 0, 60, 0, 0.5)));
    // Under pressure: each key keeps its latest value. MPE member channels, notes, kinds, controllers, groups and
    // targets are separate keys.
    double last = 0.0;  // the last round's value as pushed (fast-math may round round/49.0 below 1)
    for (int round = 0; round < 50; ++round) {
        const double v = round / 49.0;
        last = v;
        CHECK(queue.push(midiEvent(Midi2EventType::PitchBend, 1, 0, 0, v)));
        CHECK(queue.push(midiEvent(Midi2EventType::PitchBend, 2, 0, 0, -v)));
        CHECK(queue.push(midiEvent(Midi2EventType::PolyPressure, 0, 60, 0, v)));
        CHECK(queue.push(midiEvent(Midi2EventType::PolyPressure, 0, 61, 0, v / 2)));
        CHECK(queue.push(midiEvent(Midi2EventType::PerNotePitch, 0, 60, 0, v / 4)));
        CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 1, v)));
        CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 74, v / 3)));
        CHECK(queue.push(midiEvent(Midi2EventType::ChannelPressure, 3, 0, 0, v)));
        CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 1, v, 1)));  // another track
        Midi2Event grouped = midiEvent(Midi2EventType::ControlChange, 0, 0, 1, v / 5);
        grouped.group = 2;
        CHECK(queue.push(grouped));
    }
    CHECK_EQ(queue.mergedCount(), 10u);
    CHECK_EQ(queue.dropped(), 0u);
    // Never merged: program change and RPN/NRPN (and bank select) are dropped under pressure, not merged.
    CHECK(!queue.push(midiEvent(Midi2EventType::ProgramChange, 0, 0, 5, 5 / 127.0)));
    for (uint8_t cc : {0, 6, 32, 38, 98, 99, 100, 101})
        CHECK(!queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, cc, 0.5)));
    CHECK_EQ(queue.dropped(), 9u);
    // A sustain off supersedes a sustain on still waiting, so the pedal can't stick.
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 64, 1.0)));
    CHECK_EQ(queue.mergedCount(), 11u);
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 64, 0.0)));
    CHECK_EQ(queue.mergedCount(), 10u);
    Midi2Event out;
    uint32_t n = 0;
    while (queue.pop(out)) ++n;
    CHECK_EQ(n, kNormalSlots + 1);  // the note ons and the sustain off
    queue.flush();  // space again: the merged values go in, oldest first, each with its latest sequence
    CHECK_EQ(queue.mergedCount(), 0u);
    uint32_t count = 0, lastSeq = 0;
    while (queue.pop(out)) {
        if (count > 0) CHECK(out.seq > lastSeq);
        lastSeq = out.seq;
        ++count;
        if (out.type == Midi2EventType::PitchBend && out.channel == 1) CHECK_EQ(out.value, last);
        if (out.type == Midi2EventType::PitchBend && out.channel == 2) CHECK_EQ(out.value, -last);
        if (out.type == Midi2EventType::PolyPressure) CHECK_EQ(out.value, out.note == 60 ? last : last / 2);
        if (out.type == Midi2EventType::PerNotePitch) CHECK_EQ(out.value, last / 4);
        if (out.type == Midi2EventType::ControlChange && out.index == 1)
            CHECK_EQ(out.value, out.group == 2 ? last / 5 : last);
        if (out.type == Midi2EventType::ControlChange && out.index == 74) CHECK_EQ(out.value, last / 3);
        CHECK(!(out.type == Midi2EventType::ControlChange && out.index == 64));
    }
    CHECK_EQ(count, 10u);
    // No pressure: nothing merges.
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 1, 0.1)));
    CHECK(queue.push(midiEvent(Midi2EventType::ControlChange, 0, 0, 1, 0.2)));
    CHECK_EQ(queue.mergedCount(), 0u);
    CHECK(queue.pop(out) && queue.pop(out) && !queue.pop(out));
}

TEST(midi2_control_change_index_is_byte_three) {
    // Microsoft's UMP primer: 40B00700 C9249249 is controller 7 on group 0, channel 0.
    Midi2Event event;
    CHECK(decodeMidi2ChannelVoice(0x40B00700u, 0xC9249249u, event));
    CHECK(event.type == Midi2EventType::ControlChange);
    CHECK_EQ(event.index, 7);
    CHECK_NEAR(event.value, 0xC9249249u / 4294967295.0, 1e-15);
}

TEST(control_change_decodes_midi1_and_midi2_ump) {
    UmpControlChange cc;
    const uint32_t midi1[4] = {0x23B5077Fu, 0, 0, 0};  // MIDI 1.0 in UMP: group 3, channel 5, CC 7 = 127
    CHECK(decodeControlChange(midi1, cc));
    CHECK_EQ(cc.group, 3);
    CHECK_EQ(cc.channel, 5);
    CHECK_EQ(cc.controller, 7);
    CHECK_EQ(cc.value, 1.0);
    const uint32_t midi1Low[4] = {0x20B00140u, 0, 0, 0};  // CC 1 = 64
    CHECK(decodeControlChange(midi1Low, cc));
    CHECK_EQ(cc.controller, 1);
    CHECK_EQ(cc.value, 64.0 / 127.0);
    const uint32_t midi2[4] = {0x41BA4A00u, 0xFFFFFFFFu, 0, 0};  // group 1, channel 10, CC 74 = max
    CHECK(decodeControlChange(midi2, cc));
    CHECK_EQ(cc.group, 1);
    CHECK_EQ(cc.channel, 10);
    CHECK_EQ(cc.controller, 74);
    CHECK_EQ(cc.value, 1.0);
    const uint32_t noteOn[4] = {0x40903C00u, 0xFFFF0000u, 0, 0};
    const uint32_t pitch[4] = {0x20E00000u, 0, 0, 0};
    const uint32_t sysex[4] = {0x30B00700u, 0, 0, 0};
    CHECK(!decodeControlChange(noteOn, cc));
    CHECK(!decodeControlChange(pitch, cc));
    CHECK(!decodeControlChange(sysex, cc));
}
