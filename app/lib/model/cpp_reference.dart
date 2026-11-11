// The C.A.W SDK and caw::lib names the C++ Builder knows offline: the Library sheet, snippets and instant completion.

/// One SDK name. [name] is what completion matches (the last part of [qualified]); [insert] is what Insert types.
class CppRefEntry {
  const CppRefEntry(this.qualified, this.detail, this.doc,
      {this.insertText, this.member = false, this.group = 'SDK', this.example = ''});

  final String qualified;
  final String detail; // a type, a signature or a range, shown dim
  final String doc;
  final String? insertText;
  /// A field or method reached with `.` (completion offers it after a dot).
  final bool member;
  final String group;
  /// A few lines showing it in use (the Library's Insert example); empty for none.
  final String example;

  String get name => qualified.split('::').last;
  String get insert => insertText ?? (member ? name : qualified);
}

/// Hand-kept from `engine/include/caw/` (module.hpp, component.hpp, instrument.hpp, detmath.hpp, library/*.hpp); a
/// test checks every name is still declared there. The groups are the Library's headings, in this order.
const cppReference = <CppRefEntry>[
  // Describing an effect.
  CppRefEntry('caw::ModuleDescriptor', 'struct', 'What the effect is: id, ports, parameters, name, role, latency, tail.',
      group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::id', 'std::string_view', 'Stable reverse-DNS id ("local.my-delay").', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::ports', 'const PortDescriptor*', 'The ports array.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::portCount', 'uint32_t', 'How many ports.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::parameters', 'const ParameterDescriptor*', 'The knobs.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::parameterCount', 'uint32_t', 'How many knobs.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::name', 'std::string_view', 'Display name.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::role', 'ModuleRole', 'Effect, Instrument, Utility...', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::latencyFrames', 'uint32_t', 'Processing delay the host compensates.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::tailFrames', 'uint32_t', 'Frames of output after the input stops (kInfiniteTail).',
      member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleDescriptor::maxStateBytes', 'uint32_t', 'Most bytes saveState writes.', member: true, group: 'Describe'),
  CppRefEntry('caw::ModuleRole::Effect', 'ModuleRole', 'An insert effect.', group: 'Describe'),
  CppRefEntry('caw::stereoInput', 'PortDescriptor(std::string_view id)', 'A stereo audio input port.', insertText: 'caw::stereoInput("in")',
      group: 'Describe'),
  CppRefEntry('caw::stereoOutput', 'PortDescriptor(std::string_view id)', 'A stereo audio output port.',
      insertText: 'caw::stereoOutput("out")', group: 'Describe'),
  CppRefEntry('caw::kInfiniteTail', 'uint32_t', 'tailFrames of an effect that may never fall silent.', group: 'Describe'),
  CppRefEntry('CAW_EXPORT_COMPONENT', 'macro (Type, descriptor)', 'Exports the effect; once per component.',
      insertText: 'CAW_EXPORT_COMPONENT(Effect, kDescriptor)', group: 'Describe'),
  // Knobs.
  CppRefEntry('caw::ParameterDescriptor', 'struct', 'One knob: id, range, default, unit, curve, smoothing.', group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::id', 'std::string_view', 'Stable id; automation and presets use it.', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::defaultValue', 'double', 'Where the knob starts.', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::minimum', 'double', 'Lowest value (default 0).', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::maximum', 'double', 'Highest value (default 1).', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::unit', 'std::string_view', 'Shown after the value ("Hz", "dB", "ms").', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::name', 'std::string_view', 'Display name; empty shows the id.', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::step', 'double', '> 0 snaps to minimum + k * step.', member: true, group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::curve', 'ParameterCurve', 'Linear or Exponential (frequencies, times).', member: true,
      group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::smoothingFrames', 'uint32_t', 'A change ramps over this many frames.', member: true,
      group: 'Knobs'),
  CppRefEntry('caw::ParameterDescriptor::automatable', 'bool', 'May have an automation lane (default true).', member: true,
      group: 'Knobs'),
  CppRefEntry('caw::ParameterCurve::Exponential', 'ParameterCurve', 'Needs minimum > 0.', group: 'Knobs'),
  // Processing.
  CppRefEntry('caw::ModuleProcessor', 'class', 'Derive the effect from it; override process().', group: 'Process'),
  CppRefEntry('caw::ModuleProcessor::process', 'bool (const AudioProcessBlock&) noexcept', 'Called per block on the audio thread.',
      member: true, group: 'Process'),
  CppRefEntry('caw::ModuleProcessor::activate', 'bool (double sampleRate, uint32_t maxFrames) noexcept',
      'Allocate here, never in process().', member: true, group: 'Process'),
  CppRefEntry('caw::ModuleProcessor::reset', 'void () noexcept', 'Clear delay lines and filters.', member: true, group: 'Process'),
  CppRefEntry('caw::ModuleProcessor::saveState', 'bool (uint8_t*, uint32_t capacity, uint32_t& written) const noexcept',
      'Write state into the project; may run while processing.', member: true, group: 'Process'),
  CppRefEntry('caw::ModuleProcessor::loadState', 'bool (const uint8_t*, uint32_t size, uint32_t version) noexcept',
      'Read what saveState wrote.', member: true, group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock', 'struct', 'input, output, frames, sampleRate, parameters, transport.', group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::input', 'ConstChannelBufferView', 'input.channels[c][i].', member: true, group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::output', 'ChannelBufferView', 'output.channels[c][i].', member: true, group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::frames', 'uint32_t', 'Frames in this block.', member: true, group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::sampleRate', 'double', 'Samples per second.', member: true, group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::parameters', 'const ParameterValue*', 'Knob values in descriptor order: parameters[k].value.',
      member: true, group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::parameterCount', 'uint32_t', 'How many knob values the host passed.', member: true,
      group: 'Process'),
  CppRefEntry('caw::AudioProcessBlock::transport', 'const Transport*', 'Tempo and song position; null while stopped.', member: true,
      group: 'Process'),
  CppRefEntry('caw::ParameterValue::value', 'double', "The block's value.", member: true, group: 'Process'),
  CppRefEntry('caw::ParameterValue::samples', 'const double*', 'Per-frame values, or null.', member: true, group: 'Process'),
  CppRefEntry('caw::Transport::tempo', 'double', 'Beats per minute.', member: true, group: 'Process'),
  CppRefEntry('caw::Transport::beat', 'double', "Song position of the block's first frame, in beats.", member: true, group: 'Process'),
  CppRefEntry('caw::Transport::beatsPerBar', 'uint32_t', 'Beats per bar.', member: true, group: 'Process'),
  CppRefEntry('caw::Transport::playing', 'bool', 'Whether the song plays.', member: true, group: 'Process'),
  CppRefEntry('caw::StereoProcessBlock', 'struct', 'inputLeft/Right, outputLeft/Right, frames, sampleRate.', group: 'Process'),
  CppRefEntry('caw::StereoProcessBlock::inputLeft', 'const float*', 'Left input samples.', member: true, group: 'Process'),
  CppRefEntry('caw::StereoProcessBlock::inputRight', 'const float*', 'Right input samples.', member: true, group: 'Process'),
  CppRefEntry('caw::StereoProcessBlock::outputLeft', 'float*', 'Left output samples.', member: true, group: 'Process'),
  CppRefEntry('caw::StereoProcessBlock::outputRight', 'float*', 'Right output samples.', member: true, group: 'Process'),
  // Deterministic maths (detmath.hpp).
  CppRefEntry('caw::detSin', 'double (double x)', 'Sine, the same on every device.', insertText: 'caw::detSin()', group: 'Maths'),
  CppRefEntry('caw::detCos', 'double (double x)', 'Cosine, the same on every device.', insertText: 'caw::detCos()', group: 'Maths'),
  CppRefEntry('caw::detTanh', 'double (double x)', 'Tanh, the same on every device.', insertText: 'caw::detTanh()', group: 'Maths'),
  CppRefEntry('caw::detExp', 'double (double x)', 'e^x, the same on every device.', insertText: 'caw::detExp()', group: 'Maths'),
  CppRefEntry('caw::detPow', 'double (double x, double y)', 'x^y, the same on every device.', insertText: 'caw::detPow()', group: 'Maths'),
  CppRefEntry('caw::finiteOr0', 'double (double d)', 'NaN and infinity become 0.', insertText: 'caw::finiteOr0()', group: 'Maths'),
  CppRefEntry('caw::kPi', 'constexpr double', 'Pi.', group: 'Maths'),
  // Instruments (instrument.hpp).
  CppRefEntry('caw::InstrumentProcessor', 'class', 'Derive an instrument from it: one note input, stereo out. Override onNote() and render(); '
      'the base splits each block at its notes, so a note starts on its exact frame.',
      group: 'Instrument', example: """class Synth final : public caw::InstrumentProcessor {
protected:
    void onNote(const caw::NoteMessage& m) noexcept override { /* start or stop a voice */ }
    void render(float* l, float* r, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {}
};"""),
  CppRefEntry('caw::InstrumentProcessor::onNote', 'void (const NoteMessage&) noexcept', 'A note on, off, pitch, pressure or timbre change, on the frame render() continues from.',
      member: true, group: 'Instrument'),
  CppRefEntry('caw::InstrumentProcessor::render', 'void (float* l, float* r, uint32_t frames, uint32_t offset, const ProcessBlock&) noexcept',
      'Write frames samples to l and r; they start at frame offset of the block.', member: true, group: 'Instrument'),
  CppRefEntry('caw::InstrumentProcessor::onEvent', 'void (const Event&) noexcept', 'Any other event (a controller); ignored unless overridden.',
      member: true, group: 'Instrument'),
  CppRefEntry('caw::ModuleRole::Instrument', 'ModuleRole', 'Plays the track\'s notes.', group: 'Instrument'),
  CppRefEntry('caw::NoteMessage', 'struct', 'A decoded note event: type, frame, noteId, key, velocity, pitch, value.', group: 'Instrument'),
  CppRefEntry('caw::NoteMessage::type', 'NoteMessageType', 'On, Off, Pitch, Pressure, Timbre or Other.', member: true, group: 'Instrument'),
  CppRefEntry('caw::NoteMessage::noteId', 'uint32_t', "The host's id for the note; an off names the same id as its on.", member: true,
      group: 'Instrument'),
  CppRefEntry('caw::NoteMessage::pitch', 'double', 'MIDI note number with fraction (60.5: a quarter tone above middle C).', member: true,
      group: 'Instrument'),
  CppRefEntry('caw::NoteMessage::velocity', 'double', 'On, Off: 0..1.', member: true, group: 'Instrument'),
  CppRefEntry('caw::NoteMessage::value', 'double', 'Pressure, Timbre: 0..1.', member: true, group: 'Instrument'),
  CppRefEntry('caw::NoteMessage::key', 'uint8_t', 'The nearest semitone, 0..127.', member: true, group: 'Instrument'),
  CppRefEntry('caw::NoteMessageType::On', 'NoteMessageType', 'A note starts.', group: 'Instrument'),
  CppRefEntry('caw::NoteMessageType::Off', 'NoteMessageType', 'A note is released.', group: 'Instrument'),
  CppRefEntry('caw::NoteMessageType::Pitch', 'NoteMessageType', "The note's pitch now (glide, bend, vibrato).", group: 'Instrument'),
  CppRefEntry('caw::NoteMessageType::Pressure', 'NoteMessageType', "The note's pressure now.", group: 'Instrument'),
  CppRefEntry('caw::NoteMessageType::Timbre', 'NoteMessageType', "The note's timbre now.", group: 'Instrument'),
  CppRefEntry('caw::VoicePool', 'template <class Voice, uint32_t N>', 'N voices assigned by note id: a free one, else the oldest released, '
      'else the oldest held. Voice needs bool active, bool held, uint32_t noteId, uint64_t age.',
      insertText: 'caw::VoicePool<Voice, 8> voices_;', group: 'Instrument', example: """if (m.type == caw::NoteMessageType::On) {
    Voice& v = voices_.start(m.noteId);
} else if (Voice* v = voices_.find(m.noteId)) {
    if (m.type == caw::NoteMessageType::Off) v->held = false;
}"""),
  CppRefEntry('caw::VoicePool::start', 'Voice& (uint32_t noteId) noexcept', 'A voice for a new note (steals one when all are busy).', member: true,
      group: 'Instrument'),
  CppRefEntry('caw::VoicePool::find', 'Voice* (uint32_t noteId) noexcept', 'The voice playing that note, or null.', member: true, group: 'Instrument'),
  CppRefEntry('caw::VoicePool::clear', 'void () noexcept', 'Silences every voice.', member: true, group: 'Instrument'),
  CppRefEntry('caw::readNote', 'bool (const Event&, NoteMessage& out) noexcept', 'Decodes a note event (onNote gets them decoded already).',
      insertText: 'caw::readNote(event, message)', group: 'Instrument'),
  CppRefEntry('caw::parameterAt', 'double (const ProcessBlock&, uint32_t index, uint32_t frame, double fallback) noexcept',
      'A knob at one frame of the block (per frame while it ramps).', insertText: 'caw::parameterAt(b, 0, offset + i, 0.5)', group: 'Instrument'),
  // Oscillators (library/oscillator.hpp, wavetable.hpp).
  CppRefEntry('caw::lib::noteHz', 'double (double pitch)', 'A MIDI note number with fraction to Hz (69 = A4 = 440 Hz).',
      insertText: 'caw::lib::noteHz(m.pitch)', group: 'Oscillators'),
  CppRefEntry('caw::lib::wrap01', 'double (double phase)', 'The phase wrapped into 0..1.', insertText: 'caw::lib::wrap01(phase + dt)',
      group: 'Oscillators'),
  CppRefEntry('caw::lib::sineWave', 'double (double t)', 'Sine at phase t (0..1), rising from 0.', insertText: 'caw::lib::sineWave(phase)',
      group: 'Oscillators'),
  CppRefEntry('caw::lib::triangleWave', 'double (double t)', 'Triangle at phase t, rising from 0.', insertText: 'caw::lib::triangleWave(phase)',
      group: 'Oscillators'),
  CppRefEntry('caw::lib::sawWave', 'double (double t, double dt)', 'Band-limited saw (PolyBLEP); dt is cycles per sample (hz / rate).',
      insertText: 'caw::lib::sawWave(phase, dt)', group: 'Oscillators', example: """const double dt = caw::lib::noteHz(pitch) / rate;
const double y = caw::lib::sawWave(phase, dt);
phase = caw::lib::wrap01(phase + dt);"""),
  CppRefEntry('caw::lib::squareWave', 'double (double t, double dt)', 'Band-limited square.', insertText: 'caw::lib::squareWave(phase, dt)',
      group: 'Oscillators'),
  CppRefEntry('caw::lib::pulseWave', 'double (double t, double dt, double width = 0.5)', 'Band-limited pulse, +1 for the first width of the cycle.',
      insertText: 'caw::lib::pulseWave(phase, dt, 0.25)', group: 'Oscillators'),
  CppRefEntry('caw::lib::morphWave', 'double (double t, double dt, double shape)', 'Crossfades sine (0), triangle, saw and square (1).',
      insertText: 'caw::lib::morphWave(phase, dt, 0.5)', group: 'Oscillators'),
  CppRefEntry('caw::lib::polyBlep', 'double (double t, double dt)', 'The residual that smooths a step at phase 0 over one sample.',
      insertText: 'caw::lib::polyBlep(t, dt)', group: 'Oscillators'),
  CppRefEntry('caw::lib::Noise', 'class (uint32_t seed = 1)', 'White noise -1..1; the same seed gives the same sequence on every device.',
      insertText: 'caw::lib::Noise noise_{1};', group: 'Oscillators'),
  CppRefEntry('caw::lib::Noise::next', 'double () noexcept', 'The next sample.', member: true, group: 'Oscillators'),
  CppRefEntry('caw::lib::Wavetable', 'class', 'Band-limited, mipmapped frames you fill (harmonics or a function); morph across them. '
      'prepare() allocates and the builders are slow: call them off the audio thread.', group: 'Oscillators',
      example: """caw::lib::Wavetable table_;
table_.prepare(2);  // in activate()
table_.setFrameFunction(0, [](double p) { return 2 * p - 1; });"""),
  CppRefEntry('caw::lib::Wavetable::prepare', 'void (int maxFrames, int frameSize = 2048)', 'Allocates room for the frames.', member: true,
      group: 'Oscillators'),
  CppRefEntry('caw::lib::Wavetable::setFrameHarmonics', 'bool (int frame, const double* amplitudes, int count, const double* phases = nullptr)',
      'Builds a frame from harmonic amplitudes.', member: true, group: 'Oscillators'),
  CppRefEntry('caw::lib::Wavetable::setFrameFunction', 'bool (int frame, Fn fn)', 'Builds a frame from one cycle of fn(phase).', member: true,
      group: 'Oscillators'),
  CppRefEntry('caw::lib::WavetableOscillator', 'class', 'Plays a Wavetable without aliasing: setTable, setFrequency, setPosition, next().',
      insertText: 'caw::lib::WavetableOscillator osc_;', group: 'Oscillators'),
  CppRefEntry('caw::lib::WavetableOscillator::setFrequency', 'void (double hz, double sampleRate) noexcept', 'Picks the mip level for the note.',
      member: true, group: 'Oscillators'),
  CppRefEntry('caw::lib::WavetableOscillator::setPosition', 'void (double position) noexcept', 'Morph position 0..1 across the frames.',
      member: true, group: 'Oscillators'),
  CppRefEntry('caw::lib::sawHarmonics', 'void (double* out, int count)', 'Harmonic amplitudes of a saw, for setFrameHarmonics.',
      insertText: 'caw::lib::sawHarmonics(amps, 64)', group: 'Oscillators'),
  CppRefEntry('caw::lib::Wavetable::levelData', 'const float* (int frame, int level) const noexcept',
      'One mip level\'s samples (levelSize + 1, the last repeats the first), for a renderer reading many copies at once.',
      member: true, group: 'Oscillators'),
  // Unison (library/unison.hpp).
  CppRefEntry('caw::lib::unisonLayout', 'int (const UnisonSettings& s, UnisonVoice* out) noexcept',
      'Lays out up to 16 unison copies: detune with a power curve, stereo spread, centre blend, stack intervals.',
      group: 'Oscillators', example: """caw::lib::UnisonSettings s;
s.voices = 7;
s.detune = 0.25;  // semitones of the outer copies
s.spread = 0.8;
caw::lib::UnisonVoice copies[16];
const int n = caw::lib::unisonLayout(s, copies);  // each: semitones, pan, gain"""),
  // Filters (library/filter.hpp).
  CppRefEntry('caw::lib::Svf', 'class', 'State-variable filter, 12 dB/octave: low, band, high and notch at once.',
      insertText: 'caw::lib::Svf filter_;', group: 'Filters', example: """filter_.set(cutoff, caw::lib::resonanceQ(0.5), rate);  // every 16 frames is plenty
const double y = filter_.lowpass(x);"""),
  CppRefEntry('caw::lib::Svf::set', 'void (double cutoff, double q, double sampleRate) noexcept', 'Costs a tan: call it when the cutoff or q changes.',
      member: true, group: 'Filters'),
  CppRefEntry('caw::lib::Svf::lowpass', 'double (double x) noexcept', 'One sample through, low-pass.', member: true, group: 'Filters'),
  CppRefEntry('caw::lib::Svf::highpass', 'double (double x) noexcept', 'One sample through, high-pass.', member: true, group: 'Filters'),
  CppRefEntry('caw::lib::Svf::bandpass', 'double (double x) noexcept', 'One sample through, band-pass.', member: true, group: 'Filters'),
  CppRefEntry('caw::lib::Ladder', 'class', '4-pole (24 dB/octave) ladder low-pass with a soft-clipped input: the acid squelch. resonance 0..1.',
      insertText: 'caw::lib::Ladder ladder_;', group: 'Filters', example: """ladder_.set(cutoff, 0.7, rate);
const double y = ladder_.process(x);"""),
  CppRefEntry('caw::lib::MultiLadder', 'class', 'The 4-pole ladder with low-, high- and band-pass outputs (pole mixing); a block call keeps its state in registers.',
      insertText: 'caw::lib::MultiLadder ladder_;', group: 'Filters', example: """ladder_.set(cutoff, 0.4, rate);
ladder_.process<caw::lib::LadderMode::HighPass>(block, frames);  // in place"""),
  CppRefEntry('caw::lib::CombFilter', 'class', 'A tuned feedback comb: resonates at a frequency and its multiples. prepare() allocates.',
      insertText: 'caw::lib::CombFilter comb_;', group: 'Filters', example: """comb_.prepare(rate, 20.0);  // in activate()
comb_.set(220.0, 0.9, 0.3);  // Hz, feedback, damping
const double y = comb_.process(x);"""),
  CppRefEntry('caw::lib::FormantFilter', 'class', 'Three band-passes at a vowel\'s formants; vowel 0..1 morphs A, E, I, O, U.',
      insertText: 'caw::lib::FormantFilter vowel_;', group: 'Filters', example: """vowel_.set(0.25, 1.0, 10.0, rate);  // E, natural size, q
const double y = vowel_.process(x);"""),
  CppRefEntry('caw::lib::ThreeBandEq', 'class', 'Low shelf, mid bell and high shelf in series; gains in dB. One per channel.',
      insertText: 'caw::lib::ThreeBandEq eq_;', group: 'Filters', example: """eq_.set(3.0, -2.0, 1.5, 1000.0, rate);  // low, mid, high dB; mid Hz
const double y = eq_.process(x);"""),
  CppRefEntry('caw::lib::OnePole', 'class', 'One-pole low-pass (6 dB/octave); high() is the input minus it.', insertText: 'caw::lib::OnePole tone_;',
      group: 'Filters'),
  CppRefEntry('caw::lib::resonanceQ', 'double (double resonance)', 'Resonance 0..1 to a filter Q (0: 0.707, 1: about 20).',
      insertText: 'caw::lib::resonanceQ(0.5)', group: 'Filters'),
  CppRefEntry('caw::lib::shiftCutoff', 'double (double cutoff, double octaves, double sampleRate)', 'A cutoff moved by octaves, kept in range.',
      insertText: 'caw::lib::shiftCutoff(cutoff, env * 4.0, rate)', group: 'Filters'),
  // Envelopes (library/envelope.hpp).
  CppRefEntry('caw::lib::Adsr', 'class', 'ADSR: gateOn() attacks from where it is, gateOff() releases; times in seconds.',
      insertText: 'caw::lib::Adsr env_;', group: 'Envelopes', example: """env_.set(0.005, 0.3, 0.7, 0.25, rate);  // attack, decay, sustain, release
env_.gateOn();  // on the note on; gateOff() on its off
const double y = osc * env_.next();"""),
  CppRefEntry('caw::lib::Adsr::gateOn', 'void () noexcept', 'Starts the attack.', member: true, group: 'Envelopes'),
  CppRefEntry('caw::lib::Adsr::gateOff', 'void () noexcept', 'Starts the release.', member: true, group: 'Envelopes'),
  CppRefEntry('caw::lib::Adsr::active', 'bool () const noexcept', 'False once the release has finished (free the voice).', member: true,
      group: 'Envelopes'),
  CppRefEntry('caw::lib::AdEnvelope', 'class', 'Attack-decay: trigger() then it falls 60 dB in decay seconds. Drums and plucks.',
      insertText: 'caw::lib::AdEnvelope env_;', group: 'Envelopes'),
  CppRefEntry('caw::lib::AdEnvelope::trigger', 'void () noexcept', 'Starts it (from its current level: no click).', member: true, group: 'Envelopes'),
  CppRefEntry('caw::lib::Glide', 'class', 'Portamento: glideTo(target, seconds, rate), next() each sample.', insertText: 'caw::lib::Glide glide_;',
      group: 'Envelopes'),
  CppRefEntry('caw::lib::Glide::glideTo', 'void (double target, double seconds, double sampleRate) noexcept', 'About 99 % of the way in seconds.',
      member: true, group: 'Envelopes'),
  CppRefEntry('caw::lib::decayCoefficient', 'double (double seconds, double sampleRate)', 'Per-sample factor that falls 60 dB in seconds.',
      insertText: 'caw::lib::decayCoefficient(0.5, rate)', group: 'Envelopes'),
  // Modulation (library/lfo.hpp, smoothing.hpp).
  CppRefEntry('caw::lib::Lfo', 'class', 'LFO: seven shapes, Hz or tempo-synced, -1..1 or 0..1. block(frames) once per block is the cheap way.',
      insertText: 'caw::lib::Lfo lfo_;', group: 'Modulation', example: """lfo_.prepare(rate);
lfo_.setShape(caw::lib::LfoShape::Triangle);
lfo_.setRateBeats(1.0, tempo);  // one cycle per beat
const double m = lfo_.block(static_cast<int>(frames));"""),
  CppRefEntry('caw::lib::Lfo::setRateHz', 'void (double hz) noexcept', 'Free-running rate.', member: true, group: 'Modulation'),
  CppRefEntry('caw::lib::Lfo::setRateBeats', 'void (double beats, double tempoBpm) noexcept', 'One cycle every beats beats.', member: true,
      group: 'Modulation'),
  CppRefEntry('caw::lib::Lfo::syncToBeat', 'void (double beatPosition, double beats) noexcept', 'Locks the phase to the song position.',
      member: true, group: 'Modulation'),
  CppRefEntry('caw::lib::Lfo::block', 'double (int frames) noexcept', 'The value at the block start, then frames forward.', member: true,
      group: 'Modulation'),
  CppRefEntry('caw::lib::LfoShape', 'enum class', 'Sine, Triangle, SawUp, SawDown, Square, SampleHold, SmoothRandom.',
      insertText: 'caw::lib::LfoShape::Sine', group: 'Modulation'),
  CppRefEntry('caw::lib::OnePoleSmoother', 'class', 'Smooths a knob (no zipper noise): setTime once, setTarget any time, next() each sample.',
      insertText: 'caw::lib::OnePoleSmoother gain_;', group: 'Modulation', example: """gain_.setTime(0.01, rate);  // in activate()
gain_.setTarget(b.parameters[0].value);  // per block
const double g = gain_.next();  // per sample"""),
  CppRefEntry('caw::lib::OnePoleSmoother::setTarget', 'void (double target) noexcept', 'Where it glides to (free).', member: true,
      group: 'Modulation'),
  CppRefEntry('caw::lib::LinearSmoother', 'class', 'A straight ramp that reaches the target in exactly the set time (gains, crossfades).',
      insertText: 'caw::lib::LinearSmoother mix_;', group: 'Modulation'),
  CppRefEntry('caw::lib::CurveShape', 'class', 'A drawn LFO: up to 32 points joined by lines and looped; valueAt(phase) reads it.',
      insertText: 'caw::lib::CurveShape curve_;', group: 'Modulation', example: """const double points[] = {0.0, 1.0, -0.5, -1.0};
curve_.setEven(points, 4);  // in activate()
const double m = curve_.valueAt(lfo_.phase());  // or b.transport->beat / 16"""),
  CppRefEntry('caw::lib::CurveShape::setPoints', 'void (const double* xs, const double* levels, int count) noexcept',
      'Points at their own places (x 0..1, levels -1..1).', member: true, group: 'Modulation'),
  CppRefEntry('caw::lib::beatPhase', 'double (double seconds, double bpm, double beats, double offset = 0)',
      'Cycles of a tempo-synced LFO at a song position.', insertText: 'caw::lib::beatPhase(seconds, tempo, 4.0)', group: 'Modulation'),
  CppRefEntry('caw::lib::tremoloGain', 'double (double lfo, double depth)', 'A tremolo\'s gain from a -1..1 LFO: 1 down to 1 - depth.',
      insertText: 'caw::lib::tremoloGain(lfo_.next(), 0.5)', group: 'Modulation'),
  // Music (library/music.hpp).
  CppRefEntry('caw::lib::scaleNote', 'double (double degree, Scale scale, double root)', 'The MIDI note of a scale degree; past the end climbs octaves.',
      insertText: 'caw::lib::scaleNote(step % 8, caw::lib::Scale::Minor, 57)', group: 'Music', example: """// A random walk in A minor, the same on every render:
const double note = caw::lib::scaleNote(caw::lib::randomIndex(step, 8, seed), caw::lib::Scale::Minor, 57);"""),
  CppRefEntry('caw::lib::quantizeNote', 'double (double note, Scale scale, double root)', 'The nearest note of the scale (a tie goes down).',
      insertText: 'caw::lib::quantizeNote(pitch, caw::lib::Scale::Major, 60)', group: 'Music'),
  CppRefEntry('caw::lib::chordNote', 'double (Chord chord, double index, double root)', 'The index-th note of a chord; past the end climbs octaves.',
      insertText: 'caw::lib::chordNote(caw::lib::Chord::Min7, i, 57)', group: 'Music'),
  CppRefEntry('caw::lib::arpNote', 'double (Chord chord, double step, ArpMode mode, double root, int octaves = 1, uint32_t seed = 0)',
      'The note an arpeggio plays on a step: up, down, up and down, or seeded random.',
      insertText: 'caw::lib::arpNote(caw::lib::Chord::Min, step, caw::lib::ArpMode::UpDown, 57, 2)', group: 'Music'),
  CppRefEntry('caw::lib::euclid', 'bool (double hits, double steps, double pos, double rotate = 0)', 'A Euclidean rhythm: hits spread evenly over steps.',
      insertText: 'caw::lib::euclid(5, 16, step)', group: 'Music'),
  CppRefEntry('caw::lib::Scale', 'enum class', 'Major, Minor, the modes, HarmonicMinor, MelodicMinor, the pentatonics, Blues, Chromatic, WholeTone.',
      insertText: 'caw::lib::Scale::Minor', group: 'Music'),
  CppRefEntry('caw::lib::Chord', 'enum class', 'Maj, Min, Dim, Aug, Sus2, Sus4, Maj7, Min7, Dom7, Maj9, Min9, Power.', insertText: 'caw::lib::Chord::Min7',
      group: 'Music'),
  CppRefEntry('caw::lib::randomUnit', 'double (double x, uint32_t seed = 0)', 'A repeatable 0..1 for x (a step number). Also randomIndex and chance.',
      insertText: 'caw::lib::randomUnit(step, seed)', group: 'Music'),
  CppRefEntry('caw::lib::chance', 'bool (double x, double p, uint32_t seed = 0)', 'True with probability p for x, repeatably.',
      insertText: 'caw::lib::chance(step, 0.6, seed)', group: 'Music'),
  // Drums (library/drums.hpp).
  CppRefEntry('caw::lib::KickVoice', 'class', 'Kick: set(KickSettings, rate), trigger(velocity), next(), choke().',
      insertText: 'caw::lib::KickVoice kick_;', group: 'Drums', example: """caw::lib::KickSettings k;
k.tune = 48.0;
k.decay = 0.35;
kick_.set(k, rate);
kick_.trigger(m.velocity);  // on a note on
const double y = kick_.next();"""),
  CppRefEntry('caw::lib::KickSettings', 'struct', 'tune (Hz), punch, decay (s), click, tone, drive.', group: 'Drums'),
  CppRefEntry('caw::lib::SnareVoice', 'class', 'Snare: a two-mode body and high-passed noise (SnareSettings: tune, body, snappy, tone, mix).',
      insertText: 'caw::lib::SnareVoice snare_;', group: 'Drums'),
  CppRefEntry('caw::lib::ClapVoice', 'class', 'Clap: three noise bursts and a tail (ClapSettings: tone, decay).', insertText: 'caw::lib::ClapVoice clap_;',
      group: 'Drums'),
  CppRefEntry('caw::lib::HatVoice', 'class', 'Hi-hat: six square waves and noise (HatSettings: tone, decay, metal). Short decays sound closed.',
      insertText: 'caw::lib::HatVoice hat_;', group: 'Drums'),
  CppRefEntry('caw::lib::KickVoice::trigger', 'void (double velocity) noexcept', 'A hit, velocity 0..1.', member: true, group: 'Drums'),
  CppRefEntry('caw::lib::KickVoice::choke', 'void () noexcept', 'Fades it out over 5 ms.', member: true, group: 'Drums'),
  // Effects (library/delay.hpp, reverb.hpp, distortion.hpp, stereo.hpp).
  CppRefEntry('caw::lib::SampleHold', 'class', 'Sample and hold: process(x, rate, sampleRate) picks up a new value rate times a second.',
      insertText: 'caw::lib::SampleHold hold_;', group: 'Effects'),
  CppRefEntry('caw::lib::bitMask', 'double (double x, uint32_t mask)', 'Flips bits of the sound read as 16 bits (a glitch).',
      insertText: 'caw::lib::bitMask(x, 0x0F00)', group: 'Effects'),
  CppRefEntry('caw::lib::wrapAround', 'double (double x, double amount)', 'Pushes the sound past full scale and wraps it round (an overflow).',
      insertText: 'caw::lib::wrapAround(x, 3.0)', group: 'Effects'),
  CppRefEntry('caw::lib::PingPongDelay', 'class', 'Stereo ping-pong delay: prepare(sr, maxSeconds), process(...).', group: 'Effects',
      insertText: 'caw::lib::PingPongDelay delay_;', example: """delay_.prepare(rate, 2.0);  // in activate()
delay_.process(caw::lib::noteSeconds(tempo, 0.25), 0.4, 0.5, 0.3, l, r);"""),
  CppRefEntry('caw::lib::Chorus', 'class', 'Stereo chorus: prepare(sr), process(rate, depth, mix, l, r).', insertText: 'caw::lib::Chorus chorus_;',
      group: 'Effects'),
  CppRefEntry('caw::lib::Reverb', 'class', 'Stereo reverb (an 8-line feedback delay network). prepare() allocates; set(ReverbSettings), process(l, r).',
      insertText: 'caw::lib::Reverb reverb_;', group: 'Effects', example: """reverb_.prepare(rate, static_cast<int>(maxFrames));  // in activate()
caw::lib::ReverbSettings s;
s.decay = 2.5;
s.mix = 0.3;
reverb_.set(s);
reverb_.process(left, right, static_cast<int>(frames));"""),
  CppRefEntry('caw::lib::ReverbSettings', 'struct', 'size, decay (s), damping, preDelay (s), width, mix.', group: 'Effects'),
  CppRefEntry('caw::lib::noteSeconds', 'double (double tempo, double wholeNotes)', 'A note length in seconds (0.25: a quarter).',
      insertText: 'caw::lib::noteSeconds(tempo, 0.25)', group: 'Effects'),
  CppRefEntry('caw::lib::drive', 'double (double x, double amount)', 'Warm tanh saturation, level-matched (1..10).',
      insertText: 'caw::lib::drive(x, 2.0)', group: 'Effects'),
  CppRefEntry('caw::lib::hardClip', 'double (double x, double amount)', 'Hard clip after gain.', insertText: 'caw::lib::hardClip(x, 2.0)',
      group: 'Effects'),
  CppRefEntry('caw::lib::fold', 'double (double x, double drive)', 'Wavefolder (1..12).', insertText: 'caw::lib::fold(x, 2.0)', group: 'Effects'),
  CppRefEntry('caw::lib::crush', 'double (double x, double bits)', 'Bit crusher (1..24 bits).', insertText: 'caw::lib::crush(x, 8.0)',
      group: 'Effects'),
  CppRefEntry('caw::lib::constantPowerPan', 'PanGains (double pan)', 'Pan -1..1: left/right gains, -3 dB centre.',
      insertText: 'caw::lib::constantPowerPan(0.0)', group: 'Effects'),
  CppRefEntry('caw::lib::balanceGains', 'PanGains (double pan)', 'Stereo balance gains.', insertText: 'caw::lib::balanceGains(0.0)',
      group: 'Effects'),
  CppRefEntry('caw::lib::applyWidth', 'void (double width, double& l, double& r)', 'Mid/side width: 0 mono, 1 as is, 2 wide.',
      insertText: 'caw::lib::applyWidth(1.0, l, r)', group: 'Effects'),
];

/// A component that ships in every engine (org.caw.*): put on a track from Files or "+ effect"; its id names it in
/// code and project files. Hand-kept from `engine/src/builtin_components.cpp`, `builtin_instruments.cpp`,
/// `builtin_flagship.cpp` and `builtin_effects_*.cpp` (a test checks the ids and knobs are still there; the flagship lists only the knobs it
/// names whole, not the per-section ones it builds from a prefix).
class CppBuiltin {
  const CppBuiltin(this.id, this.name, this.instrument, this.doc, this.knobs);
  final String id, name, doc;
  final bool instrument;
  final List<String> knobs; // parameter ids, in order
}

const cppBuiltins = <CppBuiltin>[
  CppBuiltin('org.caw.synth.flagship', 'Flagship', true,
      'Three wavetable oscillators with unison (up to 16 copies), two filters, a 16-slot mod matrix and effects; poly, '
      'mono or legato with glide. Its 212 knobs are grouped by prefix: osc1_..osc3_, flt1_, flt2_, flt_routing, env1_..env3_, '
      'lfo1_..lfo3_, rnd_, mod1_..mod16_ and fx_. Presets: Init, Morph pad, Mono bass, Acid 303, Basic, Pluck and FM bell.',
      ['voice_mode', 'glide', 'flt_routing', 'rnd_rate', 'rnd_mode', 'volume', 'velocity', 'bend_range', 'fx_dist_on', 'fx_dist_type', 'fx_dist_drive',
       'fx_dist_mix', 'fx_eq_on', 'fx_eq_low', 'fx_eq_mid', 'fx_eq_mid_freq', 'fx_eq_high', 'fx_eq_mix', 'fx_chorus_on',
       'fx_chorus_rate', 'fx_chorus_depth', 'fx_chorus_mix', 'fx_delay_on', 'fx_delay_sync', 'fx_delay_time', 'fx_delay_feedback',
       'fx_delay_mix', 'fx_reverb_on', 'fx_reverb_size', 'fx_reverb_decay', 'fx_reverb_damping', 'fx_reverb_mix']),
  CppBuiltin('org.caw.drum.kit', 'Drum kit', true, 'Kick, snare, clap and hi-hats on General MIDI keys (C2 kick, D2 snare, F#2 hat).',
      ['kick_tune', 'kick_decay', 'kick_punch', 'snare_tune', 'snare_snappy', 'clap_decay', 'hat_closed', 'hat_open', 'hat_tone', 'kick',
       'snare', 'clap', 'hats', 'volume']),
  CppBuiltin('org.caw.drum.kick', 'Kick', true, 'Every note plays the kick; velocity sets the level.',
      ['tune', 'punch', 'decay', 'click', 'tone', 'drive', 'volume']),
  CppBuiltin('org.caw.drum.snare', 'Snare', true, 'A two-mode body and noise.', ['tune', 'body', 'snappy', 'tone', 'mix', 'volume']),
  CppBuiltin('org.caw.drum.hats', 'Hi-hats', true, 'Closed on every key but A#2 (open), unless mode says otherwise.',
      ['mode', 'closed', 'open', 'tone', 'metal', 'volume']),
  // The effects suite (#173, engine/src/builtin_effects_*.cpp); the EQ lists only its output, its bands are b1_..b8_.
  CppBuiltin('org.caw.eq', 'EQ', false,
      '8 bands (bell, shelves, cuts at 12/24/48 dB, notch, band-pass, tilt), each stereo, mid, side, left or right; '
      'knobs b1_..b8_ on, type, freq, gain, q, channel; a live spectrum.',
      ['output']),
  CppBuiltin('org.caw.compressor', 'Compressor', false, 'Soft knee, auto release and makeup, RMS or peak, link, sidechain filter.',
      ['threshold', 'ratio', 'knee', 'attack', 'release', 'auto_release', 'makeup', 'auto_makeup', 'mix', 'lookahead', 'detect',
       'link', 'sc_hpf', 'sc_listen', 'sidechain']),
  CppBuiltin('org.caw.limiter', 'Limiter', false, 'A look-ahead limiter with a true-peak estimate.',
      ['gain', 'ceiling', 'release', 'lookahead', 'true_peak']),
  CppBuiltin('org.caw.reverb.pro', 'Reverb', false, 'A modulated hall with pre-delay sync, filters, freeze and ducking.',
      ['size', 'decay', 'predelay', 'predelay_sync', 'damping', 'low_cut', 'high_cut', 'width', 'mod', 'mod_rate', 'freeze', 'duck',
       'mix']),
  CppBuiltin('org.caw.delay.pro', 'Delay', false, 'Stereo, ping-pong or dual; synced (dotted, triplet) or free; a filtered, driven loop.',
      ['mode', 'sync', 'time', 'sync_r', 'time_r', 'offset', 'feedback', 'low_cut', 'high_cut', 'drive', 'mod_depth', 'mod_rate',
       'duck', 'freeze', 'mix']),
  CppBuiltin('org.caw.saturator', 'Saturator', false, 'Tape, tube, soft and hard clip, fold and crush, 2x oversampled (4x at High quality).',
      ['mode', 'drive', 'bias', 'tone', 'bits', 'rate', 'oversample', 'auto_gain', 'output', 'mix']),
  CppBuiltin('org.caw.gate', 'Gate', false, 'A gate or expander with hold and a sidechain filter.',
      ['threshold', 'range', 'ratio', 'attack', 'hold', 'release', 'knee', 'sc_hpf', 'sidechain']),
  CppBuiltin('org.caw.ducker', 'Ducker', false,
      'Sidechain ducking from another track\'s audio, its notes or the tempo: a drawn shape, look-ahead, lows-only.',
      ['mode', 'depth', 'attack', 'hold', 'release', 'tension', 'mix', 'rate', 'offset', 'threshold', 'response', 'key_hpf',
       'key_lpf', 'lookahead', 'bands', 'crossover', 'link', 'velocity', 'listen']),
  CppBuiltin('org.caw.transient', 'Transient shaper', false, 'More or less attack and sustain.', ['attack', 'sustain', 'output', 'mix']),
  CppBuiltin('org.caw.filter', 'Filter', false, 'SVF and ladder filters swept by an LFO and an envelope follower.',
      ['type', 'cutoff', 'resonance', 'drive', 'lfo_amount', 'lfo_rate', 'lfo_sync', 'lfo_shape', 'lfo_stereo', 'env_amount',
       'env_attack', 'env_release', 'mix']),
  CppBuiltin('org.caw.phaser', 'Phaser', false, '2 to 12 all-pass stages with feedback.',
      ['stages', 'rate', 'sync', 'depth', 'center', 'feedback', 'stereo', 'mix']),
  CppBuiltin('org.caw.flanger', 'Flanger', false, 'A swept short delay with feedback.', ['delay', 'depth', 'rate', 'sync', 'feedback', 'stereo', 'mix']),
  CppBuiltin('org.caw.utility', 'Utility', false, 'Gain, phase, mono, width, pan, bass mono and DC block.',
      ['gain', 'invert_l', 'invert_r', 'channels', 'width', 'pan', 'bass_mono', 'bass_freq', 'dc_block']),
  CppBuiltin('org.caw.distortion', 'Distortion', false, 'Four shapes, a dry/wet mix and an output level.',
      ['shape', 'drive', 'bits', 'mix', 'output']),
  CppBuiltin('org.caw.delay.pingpong', 'Ping-pong delay', false, 'A stereo delay that bounces between the sides.',
      ['time', 'feedback', 'cross', 'mix']),
  CppBuiltin('org.caw.chorus', 'Chorus', false, 'A stereo chorus.', ['rate', 'depth', 'mix']),
  CppBuiltin('org.caw.stereo.width', 'Width', false, 'Mid/side width: 0 mono, 1 as is, 2 wide.', ['width']),
  CppBuiltin('org.caw.stereo.balance', 'Balance', false, 'Stereo balance.', ['pan']),
];

/// One of C.A.W's own text formats, for the Library's last groups.
class TextFormatRef {
  const TextFormatRef(this.title, this.detail, this.doc, this.example, {this.fields = const []});
  final String title, detail, doc, example;
  final List<(String, String)> fields; // a key or column, and what it means
}

const textFormats = <TextFormatRef>[
  TextFormatRef('Pattern', 'notes as text',
      "A clip's notes, one line each. Name and length are fields above the notes; the text holds only the note lines.",
      '// at  note(s)   len  vel  extras\n'
      '0      A1        2    1\n'
      '3      A1        1    0.8  slide\n'
      '13/3   E2        1    0.6  prob 0.5\n'
      '4.5    C3,E3,G3  1/2  0.9  ratchet 2',
      fields: [
        ('at', 'start in 16ths; decimals or fractions (13/3 lands on a triplet)'),
        ('note(s)', 'names (A1, F#3) or MIDI numbers, fractions for microtones; commas make a chord'),
        ('len', 'length in 16ths'),
        ('vel', 'velocity 0..1 (default 1)'),
        ('prob P', 'plays with chance P, the same on every loop and in exports'),
        ('ratchet N', 'N equal repeats (2..8)'),
        ('slide', 'the next note starting where this one ends glides from it'),
        ('bend, vib, press, timbre', 'per-note expression curves (the piano roll writes them)'),
        ('// text', 'a comment'),
      ]),
  TextFormatRef('caw-component.json', 'JSON', "A C++ component's manifest: its id, name and the sources to compile.",
      '{\n'
      '  "format": "caw.component",\n'
      '  "version": 1,\n'
      '  "component": {"id": "local.my-delay.cpp1", "name": "My delay"},\n'
      '  "sources": ["src/effect.cpp"]\n'
      '}',
      fields: [
        ('component.id', 'stable reverse-DNS id; tracks and saved projects name the component by it'),
        ('sources', 'project-relative .cpp files to compile'),
        ('includeDirectories', 'optional: project-relative folders for #include'),
        ('compileDefinitions', 'optional: NAME or NAME=value'),
      ]),
];

/// C++ keywords and common standard-library names for the instant completion list.
const cppKeywords = [
  'alignas', 'alignof', 'auto', 'bool', 'break', 'case', 'catch', 'char', 'class', 'const', 'constexpr', 'consteval',
  'continue', 'default', 'delete', 'do', 'double', 'else', 'enum', 'explicit', 'extern', 'false', 'final', 'float',
  'for', 'if', 'inline', 'int', 'long', 'namespace', 'new', 'noexcept', 'nullptr', 'operator', 'override', 'private',
  'protected', 'public', 'return', 'short', 'signed', 'sizeof', 'static', 'static_assert', 'static_cast', 'struct',
  'switch', 'template', 'this', 'true', 'try', 'typename', 'uint32_t', 'uint8_t', 'int32_t', 'size_t', 'unsigned',
  'using', 'virtual', 'void', 'volatile', 'while', 'std::vector', 'std::array', 'std::min', 'std::max', 'std::clamp',
  'std::abs', 'std::floor', 'std::sqrt', 'std::memcpy', '#include',
];
