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
    CHECK_NEAR(event.value, 0.5, 1e-8);
    CHECK(decodeMidi2ChannelVoice(0x40E00000u, 0x80000000u, event));
    CHECK(event.type == Midi2EventType::PitchBend);
    CHECK_NEAR(event.value, -1.0, 1e-12);
}

TEST(midi2_rejects_other_ump_types_and_unknown_statuses) {
    Midi2Event event;
    CHECK(!decodeMidi2ChannelVoice(0x20903C00u, 0xFFFF0000u, event));
    CHECK(!decodeMidi2ChannelVoice(0x40F03C00u, 0xFFFFFFFFu, event));
}
