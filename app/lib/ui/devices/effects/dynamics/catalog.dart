// fx-dynamics: the effect browser's entries for the Dynamics and Drive effects (category, one-line description, icon), and their editors.
import 'package:flutter/material.dart';

import '../../device_registry.dart';
import '../../kit/device_style.dart';
import '../effect_page.dart';
import 'clipper_page.dart';
import 'deesser_page.dart';
import 'dynamics_page.dart';
import 'multiband_page.dart';
import 'phasedist_page.dart';

/// One effect in the browser: its [category] tab (Dynamics, EQ & Filter, Drive, Modulation, Space, Pitch & Time,
/// Creative, Utility, Racks), a one-line [description] and an [icon] for its tile.
class FxCatalogEntry {
  const FxCatalogEntry(this.id, this.name, this.category, this.description, this.icon);
  final String id, name, category, description;
  final IconData icon;
}

/// The Dynamics and Drive groups' entries, the existing effects of those categories included (for the browser that
/// the coordinator merges; owner's brief 2026-11-11).
const fxDynamicsCatalog = <FxCatalogEntry>[
  FxCatalogEntry('org.caw.compressor', 'Compressor', 'Dynamics', 'Evens out the level: soft knee, look-ahead, sidechain', Icons.compress),
  FxCatalogEntry('org.caw.limiter', 'Limiter', 'Dynamics', 'Holds peaks under a ceiling, with true-peak look-ahead', Icons.vertical_align_top),
  FxCatalogEntry('org.caw.gate', 'Gate', 'Dynamics', 'Shuts out sound below a threshold, or expands it', Icons.door_sliding_outlined),
  FxCatalogEntry('org.caw.transient', 'Transient shaper', 'Dynamics', 'More or less attack and sustain on every hit', Icons.show_chart),
  FxCatalogEntry('org.caw.ducker', 'Ducker', 'Dynamics', 'Dips under another track, its notes or the beat', Icons.call_received),
  FxCatalogEntry('org.caw.dynamics', 'Dynamics', 'Dynamics', 'Upward and downward compression and expansion on one curve', Icons.stacked_line_chart),
  FxCatalogEntry('org.caw.multiband', 'Multiband dynamics', 'Dynamics', 'Three-band upward and downward compression, with an OTT mode', Icons.view_week_outlined),
  FxCatalogEntry('org.caw.deesser', 'De-esser', 'Dynamics', 'Turns down harsh esses and sizzle above a frequency', Icons.hearing_disabled_outlined),
  FxCatalogEntry('org.caw.saturator', 'Saturator', 'Drive', 'Tape, tube, fuzz, folds, rectify, bit shape and fat: 11 curves', Icons.whatshot_outlined),
  FxCatalogEntry('org.caw.distortion', 'Distortion', 'Drive', 'Four quick shapes: drive, clip, fold and crush', Icons.whatshot_outlined),
  FxCatalogEntry('org.caw.clipper', 'Clipper', 'Drive', 'Hard, soft or analog clipping, oversampled, with clip to 0 dB', Icons.content_cut),
  FxCatalogEntry('org.caw.phasedist', 'Phase distortion', 'Drive', 'The sound bends its own phase: feedback-FM grit', Icons.waves_outlined),
];

/// The new effects' plugin UIs by id (effect_editors.dart merges these into its table).
final Map<String, DeviceEditorEntry> fxDynamicsEditors = {
  'org.caw.dynamics': singlePage('dynamics', 'DYN', Icons.stacked_line_chart, DeviceFamily.dynamics, () => const DynamicsPage()),
  'org.caw.multiband': singlePage('multiband', 'MULTI', Icons.view_week_outlined, DeviceFamily.dynamics, () => const MultibandPage()),
  'org.caw.deesser': singlePage('deesser', 'DE-ESS', Icons.hearing_disabled_outlined, DeviceFamily.dynamics, () => const DeesserPage()),
  'org.caw.clipper': singlePage('clipper', 'CLIP', Icons.content_cut, DeviceFamily.drive, () => const ClipperPage()),
  'org.caw.phasedist': singlePage('phasedist', 'PHASE', Icons.waves_outlined, DeviceFamily.drive, () => const PhaseDistPage()),
};
