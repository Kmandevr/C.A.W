// Extra starter presets for the flagship synth, in Dart over its real parameters; the engine's list (Morph pad, Mono
// bass, Acid 303, Basic) comes first in the browser and is the source of truth. Values a preset leaves out are defaults.
import '../kit/presets.dart';

const _starter = 'Starter';

/// The starter list (category "Starter"), after the engine's own ([DevicePresets.engine]); its bass and acid ones
/// went: the engine's Mono bass and Acid 303 are those sounds.
const List<DevicePreset> flagshipStarterPresets = [
  DevicePreset('Supersaw lead', category: _starter, {
    'flt1_cutoff': 5200, 'flt1_resonance': 0.2, 'osc1_detune': 32, 'fx_delay_on': 1, 'fx_reverb_on': 1, 'fx_reverb_mix': 0.15,
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
