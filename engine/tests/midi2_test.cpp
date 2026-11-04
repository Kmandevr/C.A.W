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


TEST(midi2_input_queue_preserves_order_and_bounds_overflow) {
    Midi2InputQueue queue;
    Midi2Event input;
    input.type = Midi2EventType::NoteOn;
    input.note = 60;
    for (uint32_t i = 0; i < Midi2InputQueue::kCapacity; ++i) {
        input.note = static_cast<uint8_t>(i & 0x7F);
        CHECK(queue.push(input));
    }
    CHECK(!queue.push(input));
    CHECK_EQ(queue.dropped(), 1u);
    Midi2Event output;
    for (uint32_t i = 0; i < Midi2InputQueue::kCapacity; ++i) {
        CHECK(queue.pop(output));
        CHECK_EQ(output.note, static_cast<uint8_t>(i & 0x7F));
    }
    CHECK(!queue.pop(output));
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
