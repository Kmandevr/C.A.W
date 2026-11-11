// Test fixture: the flagship synth's descriptor built in Dart the way engine/src/builtin_flagship.cpp builds it
// (device_editor_test checks it against the real engine when CAW_LIB is set).
import 'package:caw/engine/component_info.dart';

NativeComponentInfo flagshipFixture() {
  final ps = <ComponentParameterInfo>[];
  void num(String id, String name, double def, double lo, double hi, [String unit = '']) =>
      ps.add(ComponentParameterInfo(id: id, name: name, unit: unit, defaultValue: def, min: lo, max: hi, smoothingFrames: 480));
  void expo(String id, String name, double def, double lo, double hi, [String unit = '']) => ps.add(ComponentParameterInfo(
      id: id, name: name, unit: unit, defaultValue: def, min: lo, max: hi, exponential: true, smoothingFrames: 480));
  void whole(String id, String name, double def, double lo, double hi, [String unit = '']) =>
      ps.add(ComponentParameterInfo(id: id, name: name, unit: unit, defaultValue: def, min: lo, max: hi, step: 1));
  void pick(String id, String name, double def, List<String> choices) => ps.add(ComponentParameterInfo(
      id: id, name: name, defaultValue: def, min: 0, max: choices.length - 1.0, step: 1, choices: choices));
  const offOn = ['Off', 'On'];
  for (var o = 1; o <= 3; o++) {
    final p = 'osc${o}_', n = 'Osc $o ';
    pick('${p}on', '${n}on', o == 1 ? 1 : 0, offOn);
    pick('${p}table', '${n}table', 0, const ['Basic', 'Analog', 'Vocal', 'Harmonic', 'Classic', 'User']);
    num('${p}frame', '${n}frame', 1 / 3, 0, 1);
    num('${p}level', '${n}level', 0.7, 0, 1);
    num('${p}pan', '${n}pan', 0, -1, 1);
    whole('${p}octave', '${n}octave', 0, -4, 4);
    whole('${p}semi', '${n}semitones', 0, -12, 12, 'st');
    num('${p}fine', '${n}fine', 0, -100, 100, 'ct');
    num('${p}phase', '${n}phase', 0, 0, 1);
    num('${p}phase_rand', '${n}phase randomness', 1, 0, 1);
    pick('${p}warp', '${n}warp', 0, const ['None', 'Bend', 'Sync', 'Mirror', 'Quantize', 'FM', 'Fold', 'Osc FM']);
    num('${p}warp_amt', '${n}warp amount', 0, 0, 1);
    whole('${p}unison', '${n}unison', o == 1 ? 7 : 1, 1, 16);
    num('${p}detune', '${n}detune', 25, 0, 100, 'ct');
    num('${p}detune_power', '${n}detune power', 0, -1, 1);
    num('${p}spread', '${n}stereo spread', 0.8, 0, 1);
    num('${p}blend', '${n}blend', 0.5, 0, 1);
    pick('${p}stack', '${n}stack', 0, const ['Off', 'Octave', '2 octaves', 'Fifth', 'Major chord', 'Minor chord', 'Harmonics']);
    pick('${p}dest', '${n}filter', 0, const ['Filter 1', 'Filter 2', 'Both', 'Bypass']);
  }
  for (var f = 1; f <= 2; f++) {
    final p = 'flt${f}_', n = 'Filter $f ';
    pick('${p}on', '${n}on', f == 1 ? 1 : 0, offOn);
    pick('${p}type', '${n}type', f == 1 ? 0 : 3,
        const ['Ladder LP', 'Ladder HP', 'Ladder BP', 'SVF LP', 'SVF HP', 'SVF BP', 'SVF notch', 'Comb', 'Formant']);
    expo('${p}cutoff', '${n}cutoff', f == 1 ? 2400 : 1200, 20, 20000, 'Hz');
    num('${p}resonance', '${n}resonance', 0.15, 0, 1);
    expo('${p}drive', '${n}drive', 1, 1, 10);
    num('${p}keytrack', '${n}key tracking', 0, 0, 1);
    num('${p}morph', '${n}vowel / damping', 0, 0, 1);
    num('${p}mix', '${n}mix', 1, 0, 1);
  }
  pick('flt_routing', 'Filter routing', 0, const ['Series', 'Parallel']);
  const env = [[0.01, 0.6, 0.75, 0.35], [0.001, 0.5, 0.25, 0.4], [0.001, 0.3, 0.0, 0.3]];
  for (var e = 1; e <= 3; e++) {
    final p = 'env${e}_', n = 'Env $e ';
    expo('${p}attack', '${n}attack', env[e - 1][0], 0.001, 10, 's');
    expo('${p}decay', '${n}decay', env[e - 1][1], 0.001, 10, 's');
    num('${p}sustain', '${n}sustain', env[e - 1][2], 0, 1);
    expo('${p}release', '${n}release', env[e - 1][3], 0.001, 10, 's');
  }
  for (var l = 1; l <= 3; l++) {
    final p = 'lfo${l}_', n = 'LFO $l ';
    pick('${p}shape', '${n}shape', 0, const ['Sine', 'Triangle', 'Saw up', 'Saw down', 'Square', 'Sample & hold', 'Smooth random']);
    expo('${p}rate', '${n}rate', 2, 0.01, 40, 'Hz');
    pick('${p}sync', '${n}sync', 0, const ['Off', '1/32', '1/16', '1/8', '1/4', '1/2', '1 bar', '2 bars', '4 bars', '8 bars']);
    pick('${p}mode', '${n}mode', 0, const ['Free', 'Retrigger', 'Running']);
  }
  expo('rnd_rate', 'Random rate', 4, 0.01, 40, 'Hz');
  pick('rnd_mode', 'Random mode', 0, const ['Sample & hold', 'Smooth']);
  num('volume', 'Volume', 0.7, 0, 1);
  num('velocity', 'Velocity to level', 0.5, 0, 1);
  whole('bend_range', 'Pitch bend range', 2, 1, 48, 'st');
  pick('fx_dist_on', 'Distortion', 0, offOn);
  pick('fx_dist_type', 'Distortion type', 0, const ['Drive', 'Hard clip', 'Fold', 'Crush']);
  expo('fx_dist_drive', 'Distortion drive', 2, 1, 20);
  num('fx_dist_mix', 'Distortion mix', 1, 0, 1);
  pick('fx_eq_on', 'EQ', 0, offOn);
  num('fx_eq_low', 'EQ low', 0, -18, 18, 'dB');
  num('fx_eq_mid', 'EQ mid', 0, -18, 18, 'dB');
  expo('fx_eq_mid_freq', 'EQ mid frequency', 1000, 100, 8000, 'Hz');
  num('fx_eq_high', 'EQ high', 0, -18, 18, 'dB');
  num('fx_eq_mix', 'EQ mix', 1, 0, 1);
  pick('fx_chorus_on', 'Chorus', 0, offOn);
  expo('fx_chorus_rate', 'Chorus rate', 0.6, 0.05, 5, 'Hz');
  num('fx_chorus_depth', 'Chorus depth', 0.5, 0, 1);
  num('fx_chorus_mix', 'Chorus mix', 0.35, 0, 1);
  pick('fx_delay_on', 'Delay', 0, offOn);
  pick('fx_delay_sync', 'Delay sync', 3, const ['Off', '1/16', '1/8', '1/8 dotted', '1/4', '1/4 dotted', '1/2', '1 bar']);
  expo('fx_delay_time', 'Delay time', 0.3, 0.01, 4, 's');
  num('fx_delay_feedback', 'Delay feedback', 0.35, 0, 0.95);
  num('fx_delay_mix', 'Delay mix', 0.25, 0, 1);
  pick('fx_reverb_on', 'Reverb', 0, offOn);
  num('fx_reverb_size', 'Reverb size', 0.6, 0, 1);
  expo('fx_reverb_decay', 'Reverb decay', 2.2, 0.1, 20, 's');
  num('fx_reverb_damping', 'Reverb damping', 0.45, 0, 1);
  num('fx_reverb_mix', 'Reverb mix', 0.18, 0, 1);
  final targets = ['None', for (final p in ps) p.label];
  const sources = ['None', 'Env 1', 'Env 2', 'Env 3', 'LFO 1', 'LFO 2', 'LFO 3', 'Random', 'Velocity', 'Note', 'Pitch bend',
    'Pressure', 'Timbre', 'Mod wheel', 'Accent'];
  final cutoff1 = ps.indexWhere((p) => p.id == 'flt1_cutoff');
  for (var s = 1; s <= 16; s++) {
    final p = 'mod${s}_', n = 'Mod $s ';
    pick('${p}src', '${n}source', s == 1 ? 2 : 0, sources);
    pick('${p}dst', '${n}destination', s == 1 ? cutoff1 + 1.0 : 0, targets);
    num('${p}amt', '${n}amount', s == 1 ? 0.15 : 0, -1, 1);
    pick('${p}bipolar', '${n}polarity', 0, const ['Unipolar', 'Bipolar']);
  }
  // After the slots (one synth, 2026-11-10), so the slots' destination numbers stay put.
  pick('voice_mode', 'Voice mode', 0, const ['Poly', 'Mono', 'Legato']);
  expo('glide', 'Glide', 0.05, 0.001, 2, 's');
  for (var s = 1; s <= 16; s++) {
    pick('mod${s}_via', 'Mod $s scaled by', 0, sources);
  }
  // After the via sources (#171 FM warp, 2026-11-11): each oscillator's FM ratio.
  for (var o = 1; o <= 3; o++) {
    whole('osc${o}_fm_ratio', 'Osc $o FM ratio', 1, 1, 16);
  }
  return NativeComponentInfo(id: 'org.caw.synth.flagship', name: 'Flagship', role: 'instrument', builtin: true,
      ports: const [
        ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
        ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
      ],
      parameters: ps, domains: const ['whole', 'per_note'], cpuClass: 'heavy');
}
