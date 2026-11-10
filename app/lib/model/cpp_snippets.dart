// Code snippets the C++ Builder inserts: a knob, a delay line, a tempo-synced time and a state save.

class CppSnippet {
  const CppSnippet(this.title, this.summary, this.code);
  final String title, summary, code;
}

const cppSnippets = <CppSnippet>[
  CppSnippet('Knob', 'A parameter: list it in the descriptor (parameters, parameterCount), read it in process().', '''
caw::ParameterDescriptor gainKnob() {
    caw::ParameterDescriptor p;
    p.id = "gain";
    p.name = "Gain";
    p.defaultValue = 1.0;
    p.minimum = 0.0;
    p.maximum = 2.0;
    p.smoothingFrames = 480;  // 10 ms at 48 kHz: no zipper noise
    return p;
}
const caw::ParameterDescriptor kParameters[] = {gainKnob()};
// In describe(): d.parameters = kParameters; d.parameterCount = 1;
// In process(const caw::AudioProcessBlock& b): const double gain = b.parameterCount > 0 ? b.parameters[0].value : 1.0;
'''),
  CppSnippet('Delay line', 'A ring buffer, allocated in activate() (never in process()).', '''
std::vector<float> line_;  // #include <vector>
size_t pos_ = 0;

bool activate(double sampleRate, uint32_t) noexcept override {
    line_.assign(static_cast<size_t>(sampleRate * 2.0) + 1, 0.0f);  // up to 2 s
    pos_ = 0;
    return true;
}

// One sample in, the sample from `delay` samples ago out.
float delayed(float in, size_t delay) noexcept {
    const size_t n = line_.size();
    const float out = line_[(pos_ + n - (delay % n)) % n];
    line_[pos_] = in;
    pos_ = pos_ + 1 == n ? 0 : pos_ + 1;
    return out;
}
'''),
  CppSnippet('Tempo-synced time', "A note length from the song's tempo (needs caw/library/delay.hpp).", '''
// #include <caw/library/delay.hpp>
const double tempo = b.transport ? b.transport->tempo : 120.0;
const double seconds = caw::lib::noteSeconds(tempo, 0.375);  // a dotted eighth
const size_t delaySamples = static_cast<size_t>(seconds * b.sampleRate);
'''),
  CppSnippet('State save', 'Keep running state in the project (saveState may run while processing).', '''
uint32_t stateVersion() const noexcept override { return 1; }

bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
    const float value = stored_;  // copy first: process() may be writing it
    if (capacity < sizeof value) return false;
    std::memcpy(destination, &value, sizeof value);  // #include <cstring>
    written = sizeof value;
    return true;
}

bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override {
    if (version != 1 || size != sizeof stored_) return size == 0;
    std::memcpy(&stored_, source, sizeof stored_);
    return true;
}
// In describe(): d.maxStateBytes = sizeof(float);
'''),
];
