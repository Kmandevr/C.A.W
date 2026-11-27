// The MIDI-out sender on Android (caw.h API 48): the app's Kotlin thread (MidiOutput.kt) takes the due messages
// through JNI (com.kmandevr.caw.MidiOutNative) and sends each with MidiInputPort.send and its time as the timestamp.
#include <jni.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "capi_internal.h"
#include "caw.h"
#include "engine.h"
#include "midi_sender.h"

namespace {

// One message as the Kotlin side reads it, 16 bytes: port, size, data[3], 3 zero bytes, time (little-endian int64,
// System.nanoTime's clock: caw_midi_clock_ns is CLOCK_MONOTONIC there).
constexpr int kRecord = 16;
constexpr int kMaxRecords = 64;
constexpr int64_t kPollNs = 1'000'000;  // a wait with nothing due: new messages come at each audio callback

struct Pack {
    jbyte bytes[kRecord * kMaxRecords];
    int n = 0;
};

void packOne(Pack& p, const caw::MidiOutMessage& m) {
    jbyte* o = p.bytes + p.n * kRecord;
    std::memset(o, 0, kRecord);
    o[0] = static_cast<jbyte>(m.port);
    o[1] = static_cast<jbyte>(m.size);
    for (int k = 0; k < 3; ++k) o[2 + k] = static_cast<jbyte>(m.data[k]);
    const uint64_t t = static_cast<uint64_t>(m.timeNs);
    for (int k = 0; k < 8; ++k) o[8 + k] = static_cast<jbyte>((t >> (8 * k)) & 0xFF);
    ++p.n;
}

void send(void* ctx, const caw::MidiOutMessage& m) { packOne(*static_cast<Pack*>(ctx), m); }

}  // namespace

extern "C" int32_t caw_midi_out_start(CawEngine* e) {
    return e && e->engine && caw::midiSender().attach(e->engine.get()) ? 1 : 0;
}
extern "C" void caw_midi_out_stop(void) { caw::midiSender().detach(); }
extern "C" char* caw_midi_out_devices(void) {
    char* s = static_cast<char*>(std::malloc(3));
    if (s) std::memcpy(s, "[]", 3);
    return s;
}
extern "C" int32_t caw_midi_out_open(int32_t, int32_t) { return 0; }  // MidiOutput.kt opens the devices
extern "C" void caw_midi_out_close(int32_t) {}
extern "C" int64_t caw_midi_out_dropped(void) { return static_cast<int64_t>(caw::midiSender().dropped()); }

// MidiOutNative.poll(buf, leadNs): the messages due by now + leadNs as records in buf (room for at most 64); 0 after
// a wait of at most 1 ms (to the next message's time less the lead) when none is due; -1 once the sender is detached
// with nothing left to send (the thread ends).
extern "C" JNIEXPORT jint JNICALL Java_com_kmandevr_caw_MidiOutNative_poll(JNIEnv* env, jclass, jbyteArray buf,
                                                                           jlong leadNs) {
    if (!buf) return -1;
    const int cap = std::min<int>(kMaxRecords, env->GetArrayLength(buf) / kRecord);
    if (cap <= 0) return -1;
    Pack p;
    const int64_t now = caw_midi_clock_ns();
    const int64_t next = caw::midiSender().pump(now, leadNs, send, &p, cap);
    if (p.n > 0) {
        env->SetByteArrayRegion(buf, 0, p.n * kRecord, p.bytes);
        return p.n;
    }
    if (next == caw::MidiSender::kStopped) return -1;
    const caw::MidiSendWait w = caw::midiSendWait(now, next - leadNs, kPollNs);
    if (w.untilNs > now) std::this_thread::sleep_for(std::chrono::nanoseconds(w.untilNs - now));
    return 0;
}

// MidiOutNative.notesOff(port, buf): CC 123 for each channel [port] used, as records in buf (room for 16), to send
// to the old device before the port closes or moves. Returns the count.
extern "C" JNIEXPORT jint JNICALL Java_com_kmandevr_caw_MidiOutNative_notesOff(JNIEnv* env, jclass, jint port,
                                                                               jbyteArray buf) {
    if (!buf || env->GetArrayLength(buf) < kRecord * 16) return 0;
    caw::MidiOutMessage off[16];
    const int n = caw::midiSender().takeNotesOff(port, caw_midi_clock_ns(), off);
    Pack p;
    for (int k = 0; k < n; ++k) packOne(p, off[k]);
    if (p.n > 0) env->SetByteArrayRegion(buf, 0, p.n * kRecord, p.bytes);
    return p.n;
}
