// When each drums setting is heard (caw_drums_info's "needs", 1.1.0 and 1.1.2's Acoustic kit): the conditions a setting needs, so the editor dims one that does nothing now and says what turns it on.
import 'device_target.dart';
import 'drums.dart';

/// One condition: [param] (a pad suffix, or a kit-wide id when [kit]) non-zero, or one of [only].
class DrumNeed {
  const DrumNeed(this.param, {this.kit = false, this.only});
  final String param;
  final bool kit;
  final Set<int>? only;
}

/// Every setting heard only in some context, by pad suffix or kit-wide id: all of its conditions must hold. The same
/// table as the engine's `drums::needs()` (the CAW_LIB test checks they agree).
final Map<String, List<DrumNeed>> drumNeeds = {..._needs, ..._acousticNeeds()};

/// 1.1.2: each Acoustic piece's settings, heard on the kinds they belong to (`pc<n>_kind`: 1 Kick, 2 Snare, 3 Tom,
/// 4 Hi-hat, 5 Crash, 6 Ride, 7 Splash, 8 China), as the engine builds them.
Map<String, List<DrumNeed>> _acousticNeeds() {
  const played = {1, 2, 3, 4, 5, 6, 7, 8}, drums = {1, 2, 3}, cymbals = {4, 5, 6, 7, 8};
  const kinds = <String, Set<int>>{
    'size': played, 'depth': drums, 'tune': played, 'reso': drums, 'head': drums, 'shell': drums, 'damp': played,
    'decay': played, 'glide': drums, 'wires': {2}, 'wire_level': {2}, 'beater': {1}, 'port': {1}, 'air': drums,
    'alloy': cymbals, 'swell': {5, 6, 7, 8}, 'level': played, 'pan': played, 'dist': played, 'shell_level': drums,
  };
  return {
    for (var p = 1; p <= 16; p++)
      for (final e in kinds.entries)
        'pc${p}_${e.key}': [
          DrumNeed('pc${p}_kind', kit: true, only: e.value),
          if (e.key == 'wire_level') DrumNeed('pc${p}_wires', kit: true),
        ],
  };
}

const Map<String, List<DrumNeed>> _needs = {
  'body_wave': [DrumNeed('body_on', only: {1})],
  'body_shape': [DrumNeed('body_on', only: {1})],
  'body_fold': [DrumNeed('body_on', only: {1})],
  'body_pitch': [DrumNeed('body_on', only: {1})],
  'body_ptime': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {0})],
  'body_pcurve': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {0})],
  'body_attack': [DrumNeed('body_on', only: {1})],
  'body_hold': [DrumNeed('body_on', only: {1})],
  'body_decay': [DrumNeed('body_on', only: {1})],
  'body_dcurve': [DrumNeed('body_on', only: {1})],
  'body_p2_ratio': [DrumNeed('body_on', only: {1}), DrumNeed('body_p2_level')],
  'body_p2_level': [DrumNeed('body_on', only: {1})],
  'body_phase': [DrumNeed('body_on', only: {1})],
  'body_level': [DrumNeed('body_on', only: {1})],
  'penv_mode': [DrumNeed('body_on', only: {1})],
  'penv_t1': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_p1': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_c1': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_t2': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_p2': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_c2': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_t3': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_p3': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_c3': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_t4': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_p4': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'penv_c4': [DrumNeed('body_on', only: {1}), DrumNeed('penv_mode', only: {1})],
  'sub_wave': [DrumNeed('sub_on', only: {1})],
  'sub_oct': [DrumNeed('sub_on', only: {1})],
  'sub_fine': [DrumNeed('sub_on', only: {1})],
  'sub_follow': [DrumNeed('sub_on', only: {1}), DrumNeed('body_on', only: {1})],
  'sub_attack': [DrumNeed('sub_on', only: {1})],
  'sub_hold': [DrumNeed('sub_on', only: {1})],
  'sub_decay': [DrumNeed('sub_on', only: {1})],
  'sub_dcurve': [DrumNeed('sub_on', only: {1})],
  'sub_drive': [DrumNeed('sub_on', only: {1})],
  'sub_lp': [DrumNeed('sub_on', only: {1})],
  'sub_route': [DrumNeed('sub_on', only: {1})],
  'sub_level': [DrumNeed('sub_on', only: {1})],
  'click_type': [DrumNeed('click_on', only: {1})],
  'click_level': [DrumNeed('click_on', only: {1})],
  'click_tone': [DrumNeed('click_on', only: {1})],
  'click_length': [DrumNeed('click_on', only: {1})],
  'noise_mode': [DrumNeed('noise_on', only: {1})],
  'noise_color': [DrumNeed('noise_on', only: {1})],
  'noise_filter': [DrumNeed('noise_on', only: {1})],
  'noise_freq': [DrumNeed('noise_on', only: {1})],
  'noise_res': [DrumNeed('noise_on', only: {1}), DrumNeed('noise_filter', only: {1, 2, 3})],
  'noise_sweep': [DrumNeed('noise_on', only: {1})],
  'noise_attack': [DrumNeed('noise_on', only: {1})],
  'noise_decay': [DrumNeed('noise_on', only: {1})],
  'noise_dcurve': [DrumNeed('noise_on', only: {1})],
  'noise_bursts': [DrumNeed('noise_on', only: {1}), DrumNeed('noise_mode', only: {2})],
  'noise_spacing': [DrumNeed('noise_on', only: {1}), DrumNeed('noise_mode', only: {2})],
  'noise_level': [DrumNeed('noise_on', only: {1})],
  'metal_mode': [DrumNeed('metal_on', only: {1})],
  'metal_set': [DrumNeed('metal_on', only: {1})],
  'metal_freq': [DrumNeed('metal_on', only: {1})],
  'metal_spread': [DrumNeed('metal_on', only: {1})],
  'metal_fm': [DrumNeed('metal_on', only: {1}), DrumNeed('metal_mode', only: {1})],
  'metal_tone': [DrumNeed('metal_on', only: {1})],
  'metal_color': [DrumNeed('metal_on', only: {1}), DrumNeed('metal_band')],
  'metal_band': [DrumNeed('metal_on', only: {1})],
  'metal_res': [DrumNeed('metal_on', only: {1})],
  'metal_attack': [DrumNeed('metal_on', only: {1})],
  'metal_decay': [DrumNeed('metal_on', only: {1})],
  'metal_dcurve': [DrumNeed('metal_on', only: {1})],
  'metal_open': [DrumNeed('metal_on', only: {1})],
  'metal_noise': [DrumNeed('metal_on', only: {1})],
  'metal_level': [DrumNeed('metal_on', only: {1})],
  'res_model': [DrumNeed('res_on', only: {1})],
  'res_freq': [DrumNeed('res_on', only: {1})],
  'res_decay': [DrumNeed('res_on', only: {1})],
  'res_damp': [DrumNeed('res_on', only: {1})],
  'res_bright': [DrumNeed('res_on', only: {1})],
  'res_inharm': [DrumNeed('res_on', only: {1})],
  'res_pos': [DrumNeed('res_on', only: {1})],
  'res_exciter': [DrumNeed('res_on', only: {1})],
  'res_input': [DrumNeed('res_on', only: {1})],
  'res_level': [DrumNeed('res_on', only: {1})],
  'smp_start': [DrumNeed('smp_on', only: {1})],
  'smp_end': [DrumNeed('smp_on', only: {1})],
  'smp_tune': [DrumNeed('smp_on', only: {1})],
  'smp_reverse': [DrumNeed('smp_on', only: {1})],
  'smp_attack': [DrumNeed('smp_on', only: {1})],
  'smp_decay': [DrumNeed('smp_on', only: {1})],
  'smp_level': [DrumNeed('smp_on', only: {1})],
  'fm_freq': [DrumNeed('fm_on', only: {1})],
  'fm_ratio': [DrumNeed('fm_on', only: {1})],
  'fm_index': [DrumNeed('fm_on', only: {1})],
  'fm_idecay': [DrumNeed('fm_on', only: {1})],
  'fm_feedback': [DrumNeed('fm_on', only: {1})],
  'fm_pitch': [DrumNeed('fm_on', only: {1})],
  'fm_ptime': [DrumNeed('fm_on', only: {1})],
  'fm_attack': [DrumNeed('fm_on', only: {1})],
  'fm_decay': [DrumNeed('fm_on', only: {1})],
  'fm_dcurve': [DrumNeed('fm_on', only: {1})],
  'fm_level': [DrumNeed('fm_on', only: {1})],
  'phys_model': [DrumNeed('phys_on', only: {1})],
  'phys_freq': [DrumNeed('phys_on', only: {1})],
  'phys_decay': [DrumNeed('phys_on', only: {1})],
  'phys_damp': [DrumNeed('phys_on', only: {1})],
  'phys_pick': [DrumNeed('phys_on', only: {1})],
  'phys_exciter': [DrumNeed('phys_on', only: {1})],
  'phys_input': [DrumNeed('phys_on', only: {1}), DrumNeed('phys_exciter', only: {2})],
  'phys_level': [DrumNeed('phys_on', only: {1})],
  'tex_mode': [DrumNeed('tex_on', only: {1})],
  'tex_freq': [DrumNeed('tex_on', only: {1})],
  'tex_spread': [DrumNeed('tex_on', only: {1}), DrumNeed('tex_mode', only: {0})],
  'tex_res': [DrumNeed('tex_on', only: {1})],
  'tex_tilt': [DrumNeed('tex_on', only: {1}), DrumNeed('tex_mode', only: {0})],
  'tex_density': [DrumNeed('tex_on', only: {1}), DrumNeed('tex_mode', only: {1, 2})],
  'tex_attack': [DrumNeed('tex_on', only: {1})],
  'tex_decay': [DrumNeed('tex_on', only: {1})],
  'tex_dcurve': [DrumNeed('tex_on', only: {1})],
  'tex_level': [DrumNeed('tex_on', only: {1})],
  'smp_pitch': [DrumNeed('smp_on', only: {1})],
  'smp_ptime': [DrumNeed('smp_on', only: {1}), DrumNeed('smp_pitch')],
  'smp_hold': [DrumNeed('smp_on', only: {1})],
  'smp_dcurve': [DrumNeed('smp_on', only: {1})],
  'smp_vel_start': [DrumNeed('smp_on', only: {1})],
  'smp_rnd_start': [DrumNeed('smp_on', only: {1})],
  'drive': [DrumNeed('drive_type', only: {1, 2, 3, 4, 5, 6, 7, 8})],
  'drive_lo': [DrumNeed('drive_type', only: {1, 2, 3, 4, 5, 6, 7, 8})],
  'drive_hi': [DrumNeed('drive_type', only: {1, 2, 3, 4, 5, 6, 7, 8})],
  'drive_mix': [DrumNeed('drive_type', only: {1, 2, 3, 4, 5, 6, 7, 8})],
  'press_drive': [DrumNeed('drive_type', only: {1, 2, 3, 4, 5, 6, 7, 8})],
  'drive_pos': [DrumNeed('drive_type', only: {1, 2, 3, 4, 5, 6, 7, 8}), DrumNeed('flt', only: {1, 2, 3, 4})],
  'cutoff': [DrumNeed('flt', only: {1, 2, 3, 4})],
  'flt_env': [DrumNeed('flt', only: {1, 2, 3, 4})],
  'flt_res': [DrumNeed('flt', only: {2, 3, 4})],
  'flt_decay': [DrumNeed('flt', only: {1, 2, 3, 4}), DrumNeed('flt_env')],
  'eq_low_freq': [DrumNeed('eq_low')],
  'eq_freq': [DrumNeed('eq_mid')],
  'eq_q': [DrumNeed('eq_mid')],
  'eq_high_freq': [DrumNeed('eq_high')],
  'comp_attack': [DrumNeed('comp')],
  'comp_release': [DrumNeed('comp')],
  'clip_gain': [DrumNeed('clip', only: {1, 2})],
  'width_hz': [DrumNeed('width')],
  'room_send': [DrumNeed('room', kit: true)],
  'echo_send': [DrumNeed('echo', kit: true)],
  'ring_freq': [DrumNeed('ring_mix')],
  'glide': [DrumNeed('mono', only: {1}), DrumNeed('track', only: {1})],
  'root': [DrumNeed('track', only: {1})],
  'release': [DrumNeed('trig', only: {1})],
  'vel_punch': [DrumNeed('body_on', only: {1})],
  'vel_click': [DrumNeed('click_on', only: {1})],
  'rnd_pos': [DrumNeed('res_on', only: {1})],
  'swing_grid': [DrumNeed('swing')],
  'accent_on': [DrumNeed('accent')],
  'flam_time': [DrumNeed('flam')],
  'groove_amt': [DrumNeed('groove', only: {1, 2, 3, 4, 5})],
  'acou_piece': [DrumNeed('engine', only: {1})],
  'acou_artic': [DrumNeed('engine', only: {1})],
  'acou_layer': [DrumNeed('engine', only: {0})],
  'glue_threshold': [DrumNeed('glue', kit: true)],
  'glue_ratio': [DrumNeed('glue', kit: true)],
  'glue_attack': [DrumNeed('glue', kit: true)],
  'glue_release': [DrumNeed('glue', kit: true)],
  'glue_makeup': [DrumNeed('glue', kit: true)],
  'kit_drive': [DrumNeed('kit_drive_type', kit: true, only: {1, 2, 3, 4})],
  'kit_drive_mix': [DrumNeed('kit_drive_type', kit: true, only: {1, 2, 3, 4})],
  'room_size': [DrumNeed('room', kit: true)],
  'room_decay': [DrumNeed('room', kit: true)],
  'room_damping': [DrumNeed('room', kit: true)],
  'room_predelay': [DrumNeed('room', kit: true)],
  'kit_clip_gain': [DrumNeed('kit_clip', kit: true, only: {1, 2})],
  'echo_sync': [DrumNeed('echo', kit: true)],
  'echo_feedback': [DrumNeed('echo', kit: true)],
  'echo_tone': [DrumNeed('echo', kit: true)],
  'echo_spread': [DrumNeed('echo', kit: true)],
  'echo_time': [DrumNeed('echo', kit: true), DrumNeed('echo_sync', kit: true, only: {0})],
};

/// The first condition of [suffix] (a pad setting of [pad], or a kit-wide id with [pad] null) that fails now, or null
/// when the setting is heard.
DrumNeed? drumUnmetNeed(DeviceTarget t, DrumsLayout layout, int? pad, String suffix) {
  for (final n in drumNeeds[suffix] ?? const <DrumNeed>[]) {
    final v = n.kit || pad == null ? t.value(n.param) : t.value(layout.id(pad, n.param));
    final ok = n.only == null ? v.abs() > 1e-9 : n.only!.contains(v.round());
    if (!ok) return n;
  }
  return null;
}

/// What a failing condition asks for, in words: "Turn Body on", "Noise mode: Clap", "Turn on the kit's Room".
String drumNeedText(DeviceTarget t, DrumsLayout layout, int? pad, DrumNeed n) {
  final id = n.kit || pad == null ? n.param : layout.id(pad, n.param);
  final p = t.param(id);
  final name = (p?.label ?? n.param).replaceFirst(RegExp(r'^[A-D]\d+ '), '');
  if (p != null && p.isChoice && n.only != null) {
    if (p.choices.length == 2 && p.choices.first == 'Off') return 'Turn $name on';
    final names = [for (final c in n.only!) if (c >= 0 && c < p.choices.length) p.choices[c]];
    return '$name: ${names.length > 3 ? 'not ${p.choices.first}' : names.join(' or ')}';
  }
  return n.kit ? 'Turn up the kit\'s $name' : 'Turn up $name';
}
