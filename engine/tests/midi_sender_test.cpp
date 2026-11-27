// The MIDI-out sender (API 48) on a fake clock and send: its schedule's order, the Windows counter conversion, the
// wait it picks, attach and detach (CC 123 on the channels used) and a port's notes-off; the C API per platform.
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "caw.h"
#include "engine.h"
#include "midi_sender.h"
#include "test.h"

using namespace caw;

namespace {

MidiOutMessage msg(int64_t t, uint8_t port, uint8_t s, uint8_t d1 = 0, uint8_t d2 = 0, uint8_t size = 3) {
    MidiOutMessage m;
    m.timeNs = t;
    m.port = port;
    m.size = size;
    m.data[0] = s;
    m.data[1] = d1;
    m.data[2] = d2;
    return m;
}

struct Sent {
    std::vector<MidiOutMessage> got;
    static void fn(void* ctx, const MidiOutMessage& m) { static_cast<Sent*>(ctx)->got.push_back(m); }
};

constexpr int64_t kT0 = 5'000'000'000;
constexpr int kCb = 480;  // 10 ms at 48 kHz

const std::string kProject =
    "{\"bpm\":120,\"beats_per_bar\":4,\"loop_bars\":1,\"modules\":[{\"id\":\"p\",\"source\":\"---\\nkind: pattern\\n"
    "name: p\\nlength: 16\\n---\\n0 C4 2 1\\n4 E4 8 0.5\\n\"}],\"layers\":[{\"id\":\"m\",\"pattern\":\"p\","
    "\"midiOut\":{\"port\":2,\"channel\":3}}]}";

}  // namespace

TEST(midi_send_schedule_orders_by_time_then_arrival) {
    MidiSendSchedule s(8);
    CHECK_EQ(s.nextTime(), std::numeric_limits<int64_t>::max());
    CHECK(s.push(msg(300, 0, 0x90, 1)));
    CHECK(s.push(msg(100, 0, 0x80, 60)));  // a retrigger at 100: the off came first, it goes first
    CHECK(s.push(msg(100, 0, 0x90, 60)));
    CHECK(s.push(msg(200, 1, 0xF8, 0, 0, 1)));
    CHECK(s.push(msg(100, 0, 0xB0, 7)));
    CHECK_EQ(s.nextTime(), 100);
    MidiOutMessage m;
    CHECK(!s.popDue(99, m));  // nothing is due before its time
    std::vector<MidiOutMessage> out;
    while (s.popDue(250, m)) out.push_back(m);
    CHECK_EQ(out.size(), 4u);
    if (out.size() == 4) {
        CHECK_EQ(out[0].data[0], 0x80);
        CHECK_EQ(out[1].data[0], 0x90);
        CHECK_EQ(out[2].data[0], 0xB0);
        CHECK_EQ(out[3].data[0], 0xF8);
    }
    CHECK_EQ(s.size(), 1u);
    CHECK_EQ(s.nextTime(), 300);
    // Full: the ninth is refused, the eight kept.
    MidiSendSchedule small(2);
    CHECK(small.push(msg(1, 0, 0x90)));
    CHECK(small.push(msg(2, 0, 0x90)));
    CHECK(!small.push(msg(3, 0, 0x90)));
    CHECK_EQ(small.size(), 2u);
    // Many with ties, in random order of time: out in (time, arrival) order.
    MidiSendSchedule big(1000);
    uint32_t r = 7;
    for (int k = 0; k < 1000; ++k) {
        r = r * 1664525u + 1013904223u;
        MidiOutMessage x = msg((r >> 20) % 50, 0, 0x90);
        std::memcpy(x.reserved, &k, 2);  // its arrival, to check the ties' order
        CHECK(big.push(x));
    }
    int64_t lastT = -1;
    int lastK = -1;
    for (int k = 0; k < 1000; ++k) {
        CHECK(big.popDue(1000, m));
        int arrival = 0;
        std::memcpy(&arrival, m.reserved, 2);
        CHECK(m.timeNs >= lastT);
        if (m.timeNs == lastT) CHECK(arrival > lastK);
        lastT = m.timeNs;
        lastK = arrival;
    }
    CHECK(big.empty());
}

TEST(midi_sender_qpc_conversion_matches_msvc_steady_clock) {
    // MSVC's steady_clock: whole seconds plus the remainder (10 MHz is ticks * 100 there, 24 MHz its own path).
    CHECK_EQ(qpcTicksToNs(12'345'678'901, 10'000'000), 12'345'678'901LL * 100);
    CHECK_EQ(qpcTicksToNs(24'000'000 * 3 + 7, 24'000'000), 3'000'000'000LL + 7'000 / 24);  // 291 ns: 7 / 24 MHz
    CHECK_EQ(qpcTicksToNs(3'579'545, 3'579'545), 1'000'000'000);
    const int64_t freqs[] = {10'000'000, 24'000'000, 3'579'545, 14'318'180, 2'500'000'000LL, 1'000'000'000, 1'000};
    uint64_t r = 99;
    for (int64_t f : freqs) {
        for (int k = 0; k < 2000; ++k) {
            r = r * 6364136223846793005ULL + 1442695040888963407ULL;
            const int64_t ns = static_cast<int64_t>(r >> 12) % (400LL * 24 * 3600 * 1'000'000'000);  // up to 400 days
            const int64_t t = nsToQpcTicks(ns, f);
            CHECK(qpcTicksToNs(t, f) >= ns);                // never early
            if (t > 0) CHECK(qpcTicksToNs(t - 1, f) < ns);  // and the first such tick
        }
        CHECK_EQ(nsToQpcTicks(0, f), 0);
    }
    CHECK_EQ(nsToQpcTicks(1'000'000'000, 10'000'000), 10'000'000);
    CHECK_EQ(nsToQpcTicks(1, 10'000'000), 1);  // 100 ns ticks: 1 ns waits for the first
}

TEST(midi_sender_waits_precisely_only_for_a_message) {
    const int64_t none = std::numeric_limits<int64_t>::max();
    MidiSendWait w = midiSendWait(1000, none, 1'000'000);
    CHECK_EQ(w.untilNs, 1'001'000);
    CHECK(!w.precise);
    w = midiSendWait(1000, 501'000, 1'000'000);
    CHECK_EQ(w.untilNs, 501'000);
    CHECK(w.precise);
    w = midiSendWait(1000, 5'000'000, 1'000'000);  // far off: poll again first
    CHECK_EQ(w.untilNs, 1'001'000);
    CHECK(!w.precise);
    w = midiSendWait(1000, 10, 1'000'000);  // late: at once
    CHECK_EQ(w.untilNs, 1000);
    CHECK(w.precise);
}

TEST(midi_sender_sends_each_message_at_its_time_and_ends_notes_on_detach) {
    Engine e{48000}, other{48000};
    MidiSender s;  // a sender of its own (the process's one is the C API's)
    CHECK(!s.attach(nullptr, kT0));
    CHECK(s.attach(&e, kT0));
    CHECK(s.attach(&e, kT0));  // again: still attached
    CHECK(s.attachedTo(&e));
    CHECK(e.midiOutActive());
    CHECK(e.setProjectJson(kProject).find("\"ok\":true") != std::string::npos);
    e.setOutputLatencyNs(5'000'000);
    CHECK(e.play());
    std::vector<float> l(kCb), r(kCb);
    Sent sent;
    // Callbacks 10 ms apart; the sender pumps every 1 ms of the fake clock between them.
    for (int cb = 0; cb < 60; ++cb) {
        const int64_t t = kT0 + static_cast<int64_t>(cb) * 10'000'000;
        e.setMidiClockForTest(t);
        e.process(l.data(), r.data(), kCb);
        for (int64_t now = t; now < t + 10'000'000; now += 1'000'000) {
            const size_t before = sent.got.size();
            const int64_t next = s.pump(now, 0, Sent::fn, &sent);
            CHECK(next != MidiSender::kStopped);
            for (size_t k = before; k < sent.got.size(); ++k) {
                CHECK(sent.got[k].timeNs <= now);                  // never before its time
                CHECK(sent.got[k].timeNs > now - 1'000'000);       // within a pump of it
            }
            CHECK(next > now);  // what is left is in the future
        }
    }
    std::vector<MidiOutMessage> ons;
    for (const MidiOutMessage& m : sent.got)
        if (m.data[0] == 0x92) ons.push_back(m);
    CHECK_EQ(ons.size(), 2u);
    if (ons.size() == 2) {
        CHECK_EQ(ons[0].timeNs, kT0 + 5'000'000);
        CHECK_EQ(ons[1].timeNs, kT0 + 500'000'000 + 5'000'000);
    }
    // The lead hands a message out that much early (Android passes its time as the timestamp).
    e.setMidiClockForTest(kT0 + 600'000'000);
    e.process(l.data(), r.data(), kCb);
    // Detach: nothing more from the engine, held messages dropped, CC 123 on channel 3 of port 2 (the one used).
    s.detach(kT0 + 600'000'000);
    CHECK(!e.midiOutActive());
    CHECK(!s.attached());
    Sent offs;
    CHECK_EQ(s.pump(kT0 + 601'000'000, 0, Sent::fn, &offs), MidiSender::kStopped);
    CHECK_EQ(offs.got.size(), 1u);
    if (offs.got.size() == 1) {
        CHECK_EQ(offs.got[0].port, 2);
        CHECK_EQ(offs.got[0].data[0], 0xB2);
        CHECK_EQ(offs.got[0].data[1], 123);
        CHECK_EQ(offs.got[0].data[2], 0);
        CHECK(offs.got[0].timeNs > kT0 + 600'000'000);  // after the detach's now, so after all it handed out
    }
    CHECK_EQ(s.pump(kT0 + 602'000'000, 0, Sent::fn, &offs), MidiSender::kStopped);  // and nothing again
    CHECK_EQ(offs.got.size(), 1u);
    CHECK_EQ(s.dropped(), 0u);
    // Another engine may attach now; detachIf leaves a sender alone that has another engine.
    CHECK(s.attach(&other, kT0));
    s.detachIf(&e, kT0);
    CHECK(s.attachedTo(&other));
    s.detachIf(&other, kT0);
    CHECK(!s.attached());
    CHECK(!other.midiOutActive());
}

TEST(midi_sender_lead_and_a_port_notes_off) {
    Engine e{48000};
    MidiSender s;
    CHECK(s.attach(&e, kT0));
    CHECK(e.setProjectJson(kProject).find("\"ok\":true") != std::string::npos);
    CHECK(e.play());
    std::vector<float> l(kCb), r(kCb);
    e.setMidiClockForTest(kT0);
    e.process(l.data(), r.data(), kCb);  // the note-on at kT0 (no output latency set)
    Sent sent;
    CHECK(s.pump(kT0 - 2'000'000, 1'000'000, Sent::fn, &sent) <= kT0);  // 2 ms early: not with a 1 ms lead
    CHECK(sent.got.empty());
    s.pump(kT0 - 1'000'000, 1'000'000, Sent::fn, &sent);  // 1 ms early: handed out
    CHECK_EQ(sent.got.size(), 1u);
    // The port moves to another device: its CC 123s for the old one, once, timed after the note-on it was handed
    // (kT0, ahead of now by the lead): a receiver holding that note-on until kT0 plays the CC 123 after it.
    MidiOutMessage off[16];
    CHECK_EQ(s.takeNotesOff(2, 42, off), 1);
    CHECK_EQ(off[0].data[0], 0xB2);
    CHECK_EQ(off[0].timeNs, kT0 + 1);
    CHECK_EQ(s.endTime(2, kT0 + 5'000'000), kT0 + 6'000'001);  // later: now + the 1 ms lead
    CHECK_EQ(s.takeNotesOff(2, 42, off), 0);
    CHECK_EQ(s.takeNotesOff(3, 42, off), 0);
    CHECK_EQ(s.takeNotesOff(16, 42, off), 0);
    // Every channel used: sixteen CC 123s; the clock is no channel.
    MidiChannelsUsed used;
    for (int ch = 0; ch < 16; ++ch) used.note(msg(0, 5, static_cast<uint8_t>(0x90 | ch)));
    used.note(msg(0, 5, 0xF8, 0, 0, 1));  // the clock is no channel
    CHECK_EQ(used.mask(5), 0xFFFF);
    CHECK_EQ(used.takeNotesOff(5, 0, off), 16);
    CHECK_EQ(off[15].data[0], 0xBF);
    s.detach(kT0);
}

TEST(midi_sender_attach_takes_over_and_ends_the_old_engines_notes) {
    Engine e{48000}, other{48000};
    MidiSender s;
    CHECK(s.attach(&e, kT0));
    CHECK(e.setProjectJson(kProject).find("\"ok\":true") != std::string::npos);
    CHECK(e.play());
    std::vector<float> l(kCb), r(kCb);
    e.setMidiClockForTest(kT0);
    e.process(l.data(), r.data(), kCb);
    Sent sent;
    s.pump(kT0 + 1'000'000, -5'000'000'000, Sent::fn, &sent);  // a negative lead counts as none
    CHECK_EQ(sent.got.size(), 1u);
    CHECK_EQ(s.endTime(2, kT0 + 1'000'000), kT0 + 1'000'001);
    // An Android activity made again: the new engine takes over, the old one stops queueing and its notes end.
    CHECK(s.attach(&other, kT0 + 2'000'000));
    CHECK(!e.midiOutActive());
    CHECK(other.midiOutActive());
    CHECK(s.attachedTo(&other));
    Sent offs;
    CHECK(s.pump(kT0 + 3'000'000, 0, Sent::fn, &offs) != MidiSender::kStopped);
    CHECK_EQ(offs.got.size(), 1u);
    if (offs.got.size() == 1) {
        CHECK_EQ(offs.got[0].data[0], 0xB2);
        CHECK_EQ(offs.got[0].data[1], 123);
        CHECK_EQ(offs.got[0].timeNs, kT0 + 2'000'001);
    }
    s.detachIf(&other, kT0);
    CHECK(!s.attached());
}

TEST(midi_sender_c_api_per_platform) {
    char* d = caw_midi_out_devices();
    CHECK(d != nullptr);
    if (d) {
        CHECK_EQ(d[0], '[');
        CHECK_EQ(d[std::strlen(d) - 1], ']');
    }
    caw_free(d);
    CawEngine* e = caw_engine_create(48000);
#if defined(_WIN32)
    CHECK_EQ(caw_midi_out_start(e), 1);  // the WinMM sender's thread
    CHECK_EQ(caw_midi_out_start(e), 1);
    caw_midi_out_stop();
    CHECK_EQ(caw_midi_out_open(0, 100000), 0);  // no such device
    CHECK_EQ(caw_midi_out_start(e), 1);
    caw_engine_destroy(e);  // detaches it
    e = nullptr;
    caw_midi_out_stop();
#else
    CHECK_EQ(caw_midi_out_start(e), 0);  // no sender on this platform
    CHECK_EQ(caw_midi_out_open(0, 0), 0);
    caw_midi_out_close(0);
    caw_midi_out_stop();
    caw_engine_destroy(e);
#endif
    CHECK_EQ(caw_midi_out_dropped(), 0);
    CHECK_EQ(caw_midi_out_start(nullptr), 0);
}
