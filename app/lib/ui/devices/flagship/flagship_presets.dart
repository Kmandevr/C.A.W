// Starter presets for the flagship synth, written in Dart over its real parameters until the engine's preset list
// (Morph, Bass, Acid and Basic as Flagship presets) reaches the browser; values a preset leaves out are the defaults.
import '../kit/presets.dart';

const _starter = 'Starter';

/// The starter list (category "Starter"); [DevicePresets.engine] adds the engine's own when it has them.
const List<DevicePreset> flagshipStarterPresets = [
  DevicePreset('Supersaw lead', category: _starter, {
    'flt1_cutoff': 5200, 'flt1_resonance': 0.2, 'osc1_detune': 32, 'fx_delay_on': 1, 'fx_reverb_on': 1, 'fx_reverb_mix': 0.15,
  }),
  DevicePreset('Sub bass', category: _starter, {
    'osc1_frame': 0, 'osc1_unison': 1, 'osc1_octave': -1, 'osc1_spread': 0, 'flt1_cutoff': 420, 'flt1_resonance': 0.05,
    'env1_attack': 0.002, 'env1_decay': 0.3, 'env1_sustain': 0.85, 'env1_release': 0.08, 'mod1_amt': 0,
  }),
  DevicePreset('Acid line', category: _starter, {
    'osc1_unison': 1, 'osc1_spread': 0, 'flt1_cutoff': 520, 'flt1_resonance': 0.78, 'flt1_drive': 2.5,
    'env2_decay': 0.22, 'env2_sustain': 0, 'mod1_amt': 0.45, 'env1_sustain': 0.6, 'env1_release': 0.06,
    'fx_dist_on': 1, 'fx_dist_drive': 4, 'fx_dist_mix': 0.6, 'fx_delay_on': 1, 'fx_delay_mix': 0.18,
  }),
  DevicePreset('Soft pad', category: _starter, {
    'osc1_detune': 18, 'osc1_spread': 1, 'osc2_on': 1, 'osc2_table': 1, 'osc2_octave': 1, 'osc2_level': 0.35,
    'flt1_cutoff': 1800, 'env1_attack': 0.8, 'env1_release': 1.6, 'env2_attack': 1.2, 'env2_sustain': 0.6,
    'fx_chorus_on': 1, 'fx_reverb_on': 1, 'fx_reverb_mix': 0.35, 'fx_reverb_decay': 4,
  }),
  DevicePreset('Pluck', category: _starter, {
    'osc1_unison': 3, 'osc1_detune': 12, 'flt1_cutoff': 900, 'flt1_resonance': 0.3, 'env1_attack': 0.001, 'env1_decay': 0.28,
    'env1_sustain': 0, 'env1_release': 0.22, 'env2_decay': 0.16, 'env2_sustain': 0, 'mod1_amt': 0.35, 'fx_delay_on': 1,
    'fx_delay_mix': 0.3,
  }),
  DevicePreset('Vowel keys', category: _starter, {
    'osc1_table': 2, 'osc1_frame': 0.25, 'osc1_unison': 2, 'osc1_detune': 8, 'flt1_type': 8, 'flt1_cutoff': 1000,
    'flt1_morph': 0.3, 'flt1_resonance': 0.4, 'env1_decay': 0.9, 'env1_sustain': 0.4, 'fx_chorus_on': 1,
  }),
];
