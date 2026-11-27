// The MIDI-out sender's C API (caw.h API 48) where there is no platform sender (Linux, macOS, iOS, WebAssembly).
#include <cstdlib>
#include <cstring>

#include "caw.h"

extern "C" int32_t caw_midi_out_start(CawEngine*) { return 0; }
extern "C" void caw_midi_out_stop(void) {}
extern "C" char* caw_midi_out_devices(void) {
    char* s = static_cast<char*>(std::malloc(3));
    if (s) std::memcpy(s, "[]", 3);
    return s;
}
extern "C" int32_t caw_midi_out_open(int32_t, int32_t) { return 0; }
extern "C" void caw_midi_out_close(int32_t) {}
extern "C" int64_t caw_midi_out_dropped(void) { return 0; }
