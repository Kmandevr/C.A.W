// The Creative and Pitch & Time effects (fx-creative) for the effect browser (category, one-line description, icon) and their plugin UIs by id.
import 'package:flutter/material.dart';

import '../../device_registry.dart';
import '../../kit/device_style.dart';
import '../effect_page.dart';
import 'gate_crush_editors.dart';
import 'pitch_editors.dart';
import 'time_editors.dart';

/// One built-in effect as the browser lists it: [category] is one of the browser's tabs (Dynamics, EQ & Filter,
/// Drive, Modulation, Space, Pitch & Time, Creative, Utility, Racks).
class FxCatalogEntry {
  const FxCatalogEntry(this.id, this.name, this.category, this.description, this.icon);
  final String id, name, category, description;
  final IconData icon;
}

/// This group's effects, in the browser's order.
const creativeCatalog = <FxCatalogEntry>[
  FxCatalogEntry('org.caw.tapestop', 'Tape stop', 'Pitch & Time',
      'Slows the tape to a halt and spins it back up, free or in time with the song.', Icons.album_outlined),
  FxCatalogEntry('org.caw.reverser', 'Reverser', 'Pitch & Time',
      'Plays each chunk backwards one chunk later, crossfaded, synced or free.', Icons.fast_rewind_outlined),
  FxCatalogEntry('org.caw.stutter', 'Stutter', 'Pitch & Time',
      'Beat repeat: by seeded chance, repeats a slice, each repeat quieter and re-pitched.', Icons.repeat),
  FxCatalogEntry('org.caw.pitchshift', 'Pitch shifter', 'Pitch & Time',
      'Shifts pitch by semitones and cents with crossfaded grains; half a grain of latency.', Icons.height),
  FxCatalogEntry('org.caw.freqshift', 'Frequency shifter', 'Pitch & Time',
      'Moves every partial by the same hertz, up, down or both, with a feedback swirl.', Icons.swap_horiz),
  FxCatalogEntry('org.caw.trancegate', 'Trance gate', 'Creative',
      'A drawn 8, 16 or 32-step gate with an envelope on every step, and swing.', Icons.view_week_outlined),
  FxCatalogEntry('org.caw.bitcrush', 'Bitcrush', 'Creative',
      'Fewer bits and a lower rate with jitter, dither and converter filters.', Icons.grain),
  FxCatalogEntry('org.caw.ringmod', 'Ring mod', 'Creative',
      'Multiplies the sound by a sine, triangle, square, saw, noise or a sidechain key.', Icons.all_inclusive),
];

/// The plugin UIs, merged into the built-in effects' registry (effect_editors.dart).
final Map<String, DeviceEditorEntry> creativeEditors = {
  'org.caw.tapestop': singlePage('tapestop', 'TAPE', Icons.album_outlined, DeviceFamily.creative, () => const TapeStopPage()),
  'org.caw.reverser': singlePage('reverser', 'REVERSE', Icons.fast_rewind_outlined, DeviceFamily.creative, () => const ReverserPage()),
  'org.caw.stutter': singlePage('stutter', 'STUTTER', Icons.repeat, DeviceFamily.creative, () => const StutterPage()),
  'org.caw.pitchshift': singlePage('pitchshift', 'PITCH', Icons.height, DeviceFamily.creative, () => const PitchShiftPage()),
  'org.caw.freqshift': singlePage('freqshift', 'FREQ', Icons.swap_horiz, DeviceFamily.creative, () => const FreqShiftPage()),
  'org.caw.trancegate': singlePage('trancegate', 'GATE', Icons.view_week_outlined, DeviceFamily.creative, () => const TranceGatePage()),
  'org.caw.bitcrush': singlePage('bitcrush', 'CRUSH', Icons.grain, DeviceFamily.creative, () => const BitcrushPage()),
  'org.caw.ringmod': singlePage('ringmod', 'RING', Icons.all_inclusive, DeviceFamily.creative, () => const RingModPage()),
};
