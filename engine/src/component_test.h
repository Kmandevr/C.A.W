// Offline testing suite for C++ components: test signals in, a component rendered off the audio thread, measurements as JSON.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "module_registry.h"

namespace caw {

// What the component's main audio input is fed (a component without an audio input, an instrument, is fed
// `notes` instead; any other audio input gets its own signal from `inputs`).
enum class TestSignalKind { Impulse, Sine, Sweep, WhiteNoise, PinkNoise, Silence, Dc, Wav, Buffer };

struct TestSignal {
    TestSignalKind kind = TestSignalKind::Sine;
    double seconds = 1.0;          // length of the signal (an impulse is one frame, whatever this says)
    double level = -6.0;           // dBFS: peak for impulse, sine, sweep and DC; RMS for noise
    bool levelSet = false;         // false: the kind's default (impulse 0 dBFS, the rest -6)
    double frequency = 1000.0;     // sine
    double startFrequency = 20.0;  // sweep, exponential
    double endFrequency = 20000.0; // sweep; held below 0.95 * Nyquist
    uint32_t seed = 1;             // noise
    bool decorrelated = false;     // noise: independent left and right (default: the same on both)
    std::string path;              // Wav: a 16/24/32-bit PCM or 32-bit float file, mono or stereo
    std::vector<float> left, right;  // Buffer (the C++ API), and Wav once read
};

// A component by registry id: a built-in (org.caw.*) or one from a built library, which needs an
// explicit trust choice (there is no default, as everywhere else).
struct TestComponent {
    std::string id;
    std::string library;
    bool trustSet = false;
    NativeModuleTrust trust = NativeModuleTrust::Blocked;
    std::vector<std::pair<std::string, double>> params;  // unnamed parameters keep their defaults
};

enum class NullAlign { None, Declared, Measured };

// One note of the sequence an event input gets (an instrument's notes, a keyed effect's key notes).
struct TestNote {
    double pitch = 60;     // MIDI note number (fractions allowed: 60.5 is a quarter tone above C4)
    double velocity = 100; // 1..127
    double start = 0;      // seconds
    double length = 0.5;   // seconds held before the note off
};

// A pass/fail threshold on one value of the result: `path` names it by dotted keys and array indices
// ("output.channels.0.peak_db", "bypass.depth_db", "sweep.points.2.thd.left.thd_percent"). A number must lie in
// [min, max] (either may be left out); `equals` compares a boolean or a number exactly.
struct TestCheck {
    std::string path;
    bool hasMin = false, hasMax = false, hasEquals = false;
    double min = 0, max = 0;
    bool equalsBool = false, equalsIsBool = false;
    double equalsNumber = 0;
};

struct ComponentTestRequest {
    TestComponent component;
    double sampleRate = 48000;
    bool sampleRateSet = false;  // false: 48000, or a WAV signal's own rate
    uint32_t blockSize = 64;
    TestSignal signal;
    double tailSeconds = -1;  // silence after the signal; < 0: from the declared tail and latency
    double tempo = 120;       // the transport the component sees (playing, from beat 0)
    bool cpu = true;          // time every block (the only part of the result that varies run to run)
    uint32_t fftSize = 8192;
    double bandsPerOctave = 6;
    bool hasCompare = false;
    TestComponent compare;  // null test against another component, or another build of the same id
    NullAlign align = NullAlign::Declared;
    bool bypass = false;    // A/B against bypass: a null test against the dry input
    bool hasSweep = false;
    std::string sweepParam;
    uint32_t sweepSteps = 5;
    bool sweepFromSet = false, sweepToSet = false;
    double sweepFrom = 0, sweepTo = 0;  // default: the parameter's range
    std::string writeWav;       // the output as 32-bit float stereo WAV, for listening
    std::string writeInputWav;  // the test signal itself
    std::vector<TestNote> notes;  // the first event input's notes (an instrument with none plays one C4 for 1 s)
    std::vector<std::pair<std::string, TestSignal>> inputs;  // audio inputs after the first, by port id (else silence)
    std::vector<TestCheck> checks;  // thresholds: the result gains "checks" and "passed"
};

// Parses the JSON request (keys in docs/engine.md, "Component testing"). False and `error` on a
// malformed request.
bool parseComponentTestRequest(std::string_view json, ComponentTestRequest& out, std::string& error);

// Generates the signal at `sampleRate`: both channels, `frames` long (reads a Wav file). False and
// `error` if it can't.
bool generateTestSignal(const TestSignal& signal, double sampleRate, std::vector<float>& left,
                        std::vector<float>& right, std::string& error);

// One offline render of a component over a stereo input, in blocks of `blockSize`. Any ports: the first audio
// input takes inLeft/inRight, later audio inputs take `extraInputs` (by order; missing ones are silent), the first
// event input takes `notes`; the first audio output is measured and every later one is kept in `extraOutputs`. A
// mono port gets the mid of its stereo signal; a mono output is copied to both sides.
struct ComponentRender {
    std::vector<float> left, right;  // raw output: NaN, Inf and denormals left in
    std::vector<std::pair<std::string, std::vector<float>>> extraOutputs;  // later audio outputs, per channel, by port id
    uint64_t failedBlocks = 0;       // process returned false: the input passes through, as in the app
    std::vector<double> blockMicros; // with timing
    uint32_t latencyFrames = 0, tailFrames = 0;  // declared
    uint64_t eventsOut = 0;  // events the component emitted on its event outputs
};
struct StereoBuffer {
    std::vector<float> left, right;
};
bool renderComponent(const ModuleRegistry& registry, const TestComponent& component, double sampleRate,
                     uint32_t blockSize, double tempo, const std::vector<float>& inLeft,
                     const std::vector<float>& inRight, bool timing, ComponentRender& out, std::string& error,
                     const std::vector<TestNote>& notes = {}, const std::vector<StereoBuffer>& extraInputs = {});

// Loads what `component` names into `registry` (which should hold the built-ins): nothing for a
// registered id, the library with its trust choice otherwise.
bool prepareRegistry(ModuleRegistry& registry, const TestComponent& component, std::string& error);

// Runs the whole test and returns the result JSON ({"ok":false,"error":...} on failure). Never throws.
std::string runComponentTest(const ComponentTestRequest& request);
std::string componentTestJson(std::string_view requestJson);

// How a host (the C API) runs a request it may have been handed by untrusted data: the trust for a component
// library comes from the host (the user's own choice), never from the request, which may not name one; files are
// written only as plain names inside [outputDir] (empty: no files at all); a test WAV is read only from inside
// [inputDir] (empty: none).
struct ComponentTestHost {
    NativeModuleTrust trust = NativeModuleTrust::Blocked;
    std::string outputDir, inputDir;
};
std::string componentTestJson(std::string_view requestJson, const ComponentTestHost& host);

}  // namespace caw
