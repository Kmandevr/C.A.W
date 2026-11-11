// Which plugin UI each built-in effect opens: by id, or (for a built-in whose id isn't listed) by the shape of its parameters.
import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../device_registry.dart';
import '../kit/device_style.dart';
import 'drive_editors.dart';
import 'dynamics/catalog.dart' show fxDynamicsEditors; // fx-dynamics
import 'ducker_editor.dart';
import 'dynamics_editors.dart';
import 'effect_page.dart';
import 'eq_editor.dart';
// fx-filters begin
import 'filters/filters_editors.dart';
// fx-filters end
import 'filter_editor.dart';
import 'mod_editors.dart';
import 'racks/rack_editors.dart';  // fx-racks
import 'space_editors.dart';
import 'space/space_fx.dart'; // fx-space
import 'utility_editors.dart';
// fx-creative begin
import 'creative/creative_catalog.dart';
// fx-creative end

// An EQ band's knobs: `bandN_` or the built-in EQ's `bN_` (org.caw.eq).
final _band = RegExp(r'^(band|b)(\d+)_(freq|gain|q|type|on|channel)$');

bool _has(NativeComponentInfo i, String id) => i.parameters.any((p) => p.id == id);

/// The editor for a built-in effect whose parameters look like an EQ (`bandN_freq` and `bandN_gain`), a compressor
/// (`threshold`, `ratio`), a delay (`feedback` with `time` or `sync`), a reverb (`decay` with `size`) or a
/// saturation (`drive` with `type` or `shape`); null for anything else (the fallback page).
DeviceEditorEntry? effectEditorFor(NativeComponentInfo info) {
  if (info.isInstrument) return null;
  if (_byId[info.id] case final e?) return e;
  if (info.parameters.any((p) => _band.hasMatch(p.id)) &&
      ((_has(info, 'band1_freq') && _has(info, 'band1_gain')) || (_has(info, 'b1_freq') && _has(info, 'b1_gain')))) {
    return singlePage('eq', 'EQ', Icons.graphic_eq, DeviceFamily.eq, () => const EqEditorPage());
  }
  if (_has(info, 'threshold') && _has(info, 'ratio')) {
    return singlePage('comp', 'COMP', Icons.compress, DeviceFamily.dynamics, () => const CompressorPage());
  }
  if (_has(info, 'feedback') && (_has(info, 'time') || _has(info, 'sync'))) {
    return singlePage('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayPage());
  }
  if (_has(info, 'decay') && _has(info, 'size')) {
    return singlePage('reverb', 'REVERB', Icons.blur_on, DeviceFamily.space, () => const ReverbPage());
  }
  if (_has(info, 'drive') && (_has(info, 'type') || _has(info, 'shape') || _has(info, 'mode'))) {
    return singlePage('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DrivePage());
  }
  return null;
}

/// Every built-in effect's plugin UI, by id.
final Map<String, DeviceEditorEntry> _byId = {
  'org.caw.eq': singlePage('eq', 'EQ', Icons.graphic_eq, DeviceFamily.eq, () => const EqEditorPage()),
  'org.caw.compressor': singlePage('comp', 'COMP', Icons.compress, DeviceFamily.dynamics, () => const CompressorPage()),
  'org.caw.reverb.pro': singlePage('reverb', 'REVERB', Icons.blur_on, DeviceFamily.space, () => const ReverbPage()),
  'org.caw.delay.pro': singlePage('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayPage()),
  'org.caw.delay.pingpong': singlePage('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayPage()),
  'org.caw.saturator': singlePage('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DrivePage()),
  'org.caw.distortion': singlePage('drive', 'DRIVE', Icons.whatshot_outlined, DeviceFamily.drive, () => const DrivePage()),
  'org.caw.limiter': singlePage('limit', 'LIMIT', Icons.vertical_align_top, DeviceFamily.dynamics, () => const LimiterPage()),
  'org.caw.ducker': singlePage('ducker', 'DUCK', Icons.call_received, DeviceFamily.dynamics, () => const DuckerPage()),
  'org.caw.gate': singlePage('gate', 'GATE', Icons.door_sliding_outlined, DeviceFamily.dynamics, () => const GatePage()),
  'org.caw.transient': singlePage('transient', 'SHAPE', Icons.show_chart, DeviceFamily.dynamics, () => const TransientPage()),
  'org.caw.filter': singlePage('filter', 'FILTER', Icons.filter_alt_outlined, DeviceFamily.filter, () => const FilterPage()),
  'org.caw.phaser': singlePage('phaser', 'PHASER', Icons.waves, DeviceFamily.modulation, () => const CombPage(flanger: false)),
  'org.caw.flanger': singlePage('flanger', 'FLANGER', Icons.waves, DeviceFamily.modulation, () => const CombPage(flanger: true)),
  'org.caw.chorus': singlePage('chorus', 'CHORUS', Icons.waves, DeviceFamily.modulation, () => const ChorusPage()),
  'org.caw.utility': singlePage('utility', 'UTILITY', Icons.tune, DeviceFamily.utility, () => const StereoPage()),
  'org.caw.stereo.width': singlePage('width', 'WIDTH', Icons.tune, DeviceFamily.utility, () => const StereoPage()),
  'org.caw.stereo.balance': singlePage('balance', 'BALANCE', Icons.tune, DeviceFamily.utility, () => const StereoPage()),
  ...fxDynamicsEditors, // fx-dynamics: dynamics, multiband, de-esser, clipper, phase distortion
  ...creativeEditors,  // fx-creative
  // fx-space begin
  ...fxSpaceEditors,
  // fx-space end
  // fx-filters begin
  ...filtersEditors,
  // fx-filters end
  // fx-racks begin
  ...rackEditors,
  // fx-racks end
};

