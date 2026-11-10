// The C.A.W SDK and caw::lib names the C++ Builder knows offline: the Ref sheet, snippets and instant completion.

/// One SDK name. [name] is what completion matches (the last part of [qualified]); [insert] is what Ref inserts.
class CppRefEntry {
  const CppRefEntry(this.qualified, this.detail, this.doc, {this.insertText, this.member = false, this.group = 'SDK'});

  final String qualified;
  final String detail; // a type, a signature or a range, shown dim
  final String doc;
  final String? insertText;
  /// A field or method reached with `.` (completion offers it after a dot).
  final bool member;
  final String group;

  String get name => qualified.split('::').last;
  String get insert => insertText ?? (member ? name : qualified);
}

/// Hand-kept from `engine/include/caw/` (module.hpp, component.hpp, library/*.hpp); a test checks every name is
/// still declared there.
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
  // The Library.
  CppRefEntry('caw::lib::PingPongDelay', 'class', 'Stereo ping-pong delay: prepare(sr, maxSeconds), process(...).', group: 'Library'),
  CppRefEntry('caw::lib::Chorus', 'class', 'Stereo chorus: prepare(sr), process(rate, depth, mix, l, r).', group: 'Library'),
  CppRefEntry('caw::lib::noteSeconds', 'double (double tempo, double wholeNotes)', 'A note length in seconds (0.25: a quarter).',
      insertText: 'caw::lib::noteSeconds(tempo, 0.25)', group: 'Library'),
  CppRefEntry('caw::lib::drive', 'double (double x, double amount)', 'Warm tanh saturation, level-matched (1..10).',
      insertText: 'caw::lib::drive(x, 2.0)', group: 'Library'),
  CppRefEntry('caw::lib::hardClip', 'double (double x, double amount)', 'Hard clip after gain.', insertText: 'caw::lib::hardClip(x, 2.0)',
      group: 'Library'),
  CppRefEntry('caw::lib::fold', 'double (double x, double drive)', 'Wavefolder (1..12).', insertText: 'caw::lib::fold(x, 2.0)', group: 'Library'),
  CppRefEntry('caw::lib::crush', 'double (double x, double bits)', 'Bit crusher (1..24 bits).', insertText: 'caw::lib::crush(x, 8.0)',
      group: 'Library'),
  CppRefEntry('caw::lib::constantPowerPan', 'PanGains (double pan)', 'Pan -1..1: left/right gains, -3 dB centre.',
      insertText: 'caw::lib::constantPowerPan(0.0)', group: 'Library'),
  CppRefEntry('caw::lib::balanceGains', 'PanGains (double pan)', 'Stereo balance gains.', insertText: 'caw::lib::balanceGains(0.0)',
      group: 'Library'),
  CppRefEntry('caw::lib::applyWidth', 'void (double width, double& l, double& r)', 'Mid/side width: 0 mono, 1 as is, 2 wide.',
      insertText: 'caw::lib::applyWidth(1.0, l, r)', group: 'Library'),
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
