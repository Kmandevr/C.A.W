// The MIDI-out sender on Windows (caw.h API 48): WinMM output ports (midiOutOpen, midiOutShortMsg) and a native thread
// that waits on QueryPerformanceCounter for each message's time.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <mmsystem.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "capi_internal.h"
#include "caw.h"
#include "midi_sender.h"

#pragma comment(lib, "winmm.lib")

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

namespace {

constexpr int64_t kPollNs = 1'000'000;   // a wait with nothing due: new messages come at each audio callback
constexpr int64_t kSpinNs = 300'000;     // the last part of a wait for a message, yielding on the counter

std::mutex g_ports;                        // the handles; taken after the sender's own lock, never before it
HMIDIOUT g_out[caw::kMidiOutPorts] = {};

std::mutex g_thread;                       // starting and stopping the thread
std::thread& g_sender = *new std::thread();  // never destroyed: one still running at exit must not terminate

void sendShort(void*, const caw::MidiOutMessage& m) {
    std::lock_guard<std::mutex> g(g_ports);
    HMIDIOUT h = m.port < caw::kMidiOutPorts ? g_out[m.port] : nullptr;
    if (!h || m.size < 1) return;  // no device on that port
    DWORD msg = m.data[0];
    if (m.size > 1) msg |= static_cast<DWORD>(m.data[1]) << 8;
    if (m.size > 2) msg |= static_cast<DWORD>(m.data[2]) << 16;
    midiOutShortMsg(h, msg);
}

int64_t qpcNow() {
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return c.QuadPart;
}

void run() {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    const int64_t freq = f.QuadPart;
    // caw_midi_clock_ns against the counter: 0 with MSVC's STL, measured anyway.
    const int64_t offset = caw_midi_clock_ns() - caw::qpcTicksToNs(qpcNow(), freq);
    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    bool coarse = false;
    if (!timer) {  // before Windows 10 1803: an ordinary timer at 1 ms resolution
        timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
        coarse = timeBeginPeriod(1) == TIMERR_NOERROR;
    }
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    for (;;) {
        const int64_t now = caw_midi_clock_ns();
        const int64_t next = caw::midiSender().pump(now, 0, sendShort, nullptr);
        if (next == caw::MidiSender::kStopped) break;
        const caw::MidiSendWait w = caw::midiSendWait(now, next, kPollNs);
        const int64_t sleepNs = w.untilNs - now - (w.precise ? kSpinNs : 0);
        if (sleepNs > 0) {
            if (timer) {
                LARGE_INTEGER due;
                due.QuadPart = -std::max<int64_t>(1, sleepNs / 100);  // relative, in 100 ns
                if (SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE))
                    WaitForSingleObject(timer, INFINITE);
            } else {
                Sleep(1);
            }
        }
        if (w.precise) {
            const int64_t target = caw::nsToQpcTicks(std::max<int64_t>(0, w.untilNs - offset), freq);
            while (qpcNow() < target) SwitchToThread();
        }
    }
    if (timer) CloseHandle(timer);
    if (coarse) timeEndPeriod(1);
}

char* copyOut(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

std::string utf8(const wchar_t* w) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string s(static_cast<size_t>(n - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
    return s;
}

std::string jsonString(const std::string& s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') {
            o += '\\';
            o += static_cast<char>(c);
        } else if (c < 0x20) {
            char b[8];
            std::snprintf(b, sizeof b, "\\u%04x", c);
            o += b;
        } else {
            o += static_cast<char>(c);
        }
    }
    return o + "\"";
}

// Takes the port's handle out (the sender thread sends nothing more to it: a send in progress holds g_ports, so it
// finishes first), then sends its CC 123s, resets and closes it outside every lock, so a slow device stalls neither
// the other ports nor the caller's other work.
void closePort(int port) {
    HMIDIOUT h = nullptr;
    {
        std::lock_guard<std::mutex> g(g_ports);
        h = g_out[port];
        g_out[port] = nullptr;
    }
    caw::MidiOutMessage off[16];
    const int n = caw::midiSender().takeNotesOff(port, caw_midi_clock_ns(), off);
    if (!h) return;
    for (int k = 0; k < n; ++k)
        midiOutShortMsg(h, off[k].data[0] | static_cast<DWORD>(off[k].data[1]) << 8);
    midiOutReset(h);
    midiOutClose(h);
}

}  // namespace

extern "C" int32_t caw_midi_out_start(CawEngine* e) {
    if (!e || !e->engine) return 0;
    std::lock_guard<std::mutex> g(g_thread);
    if (g_sender.joinable()) {
        if (caw::midiSender().attachedTo(e->engine.get())) return 1;
        caw::midiSender().detach(caw_midi_clock_ns());  // another engine's: its notes end, the new one takes over
        g_sender.join();  // it ends once the CC 123s are sent
    }
    if (!caw::midiSender().attach(e->engine.get(), caw_midi_clock_ns())) return 0;
    try {
        g_sender = std::thread(run);
    } catch (...) {
        caw::midiSender().detach(caw_midi_clock_ns());
        return 0;
    }
    return 1;
}

extern "C" void caw_midi_out_stop(void) {
    std::lock_guard<std::mutex> g(g_thread);
    caw::midiSender().detach(caw_midi_clock_ns());
    if (g_sender.joinable()) g_sender.join();  // it sends the CC 123s, then ends
}

extern "C" char* caw_midi_out_devices(void) try {
    std::vector<std::string> names;
    const UINT n = midiOutGetNumDevs();
    for (UINT i = 0; i < n; ++i) {
        MIDIOUTCAPSW caps{};
        std::string name = midiOutGetDevCapsW(i, &caps, sizeof caps) == MMSYSERR_NOERROR ? utf8(caps.szPname) : "";
        if (name.empty()) name = "MIDI output " + std::to_string(i + 1);
        std::string unique = name;
        for (int k = 2; std::find(names.begin(), names.end(), unique) != names.end(); ++k)
            unique = name + " " + std::to_string(k);
        names.push_back(unique);
    }
    std::string out = "[";
    for (size_t i = 0; i < names.size(); ++i) out += (i ? "," : "") + jsonString(names[i]);
    return copyOut(out + "]");
} catch (...) {
    return nullptr;
}

extern "C" int32_t caw_midi_out_open(int32_t port, int32_t device_index) {
    if (port < 0 || port >= caw::kMidiOutPorts || device_index < 0 ||
        static_cast<UINT>(device_index) >= midiOutGetNumDevs())
        return 0;
    closePort(port);
    HMIDIOUT h = nullptr;
    if (midiOutOpen(&h, static_cast<UINT>(device_index), 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR || !h) return 0;
    std::lock_guard<std::mutex> g(g_ports);
    g_out[port] = h;
    return 1;
}

extern "C" void caw_midi_out_close(int32_t port) {
    if (port >= 0 && port < caw::kMidiOutPorts) closePort(port);
}

extern "C" int64_t caw_midi_out_dropped(void) { return static_cast<int64_t>(caw::midiSender().dropped()); }
