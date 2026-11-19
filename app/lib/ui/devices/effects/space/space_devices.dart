// The Space, Modulation, Utility and Pitch merged devices (FX consolidation, 1.0.8): one page each, by merged id, with
// the variant as mode cards over the centrepiece (docs/ui.md, "Merged devices' pages").
import 'package:flutter/material.dart';

import '../../../../model/merged_devices.dart';
import '../../../theme.dart';
import '../../device_registry.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart';
import '../effect_page.dart';
export '../eqfilter/variant_cards.dart' show VariantCards, variantOf;
import 'space_delay_reverb.dart';
import 'space_mod_devices.dart';
import 'space_pitch_device.dart';
import 'space_utility_device.dart';

/// The plan's family colours (device UI plan, 2026-11-18): Modulation cyan, Pitch pink; Space keeps its violet. Theme
/// slots, so a user theme recolours them.
const Color modulationAccent = Neon.blue;
const Color pitchAccent = Neon.pink;

DeviceEditorEntry _entry(String key, String label, IconData icon, DeviceFamily family, Widget Function() page,
        {Color? accent}) =>
    DeviceEditorEntry((_) => [DeviceSection(key, label, icon, (_) => page())], family: family, accent: accent,
        ownsVariant: true);

/// Each merged device's page, whatever variant it plays (the variant is a card on the page).
final Map<String, DeviceEditorEntry> _pages = {
  'org.caw.delay': _entry('delay', 'DELAY', Icons.blur_linear, DeviceFamily.space, () => const DelayDevicePage()),
  'org.caw.reverb': _entry('reverb', 'REVERB', Icons.blur_on, DeviceFamily.space, () => const ReverbDevicePage()),
  'org.caw.chorus': _entry('chorus', 'CHORUS', Icons.waves, DeviceFamily.modulation, () => const ChorusDevicePage(),
      accent: modulationAccent),
  'org.caw.phaser': _entry('phaser', 'PHASER', Icons.waves, DeviceFamily.modulation, () => const PhaserDevicePage(),
      accent: modulationAccent),
  'org.caw.tremolo': _entry('tremolo', 'TREMOLO', Icons.show_chart, DeviceFamily.modulation,
      () => const TremoloDevicePage(), accent: modulationAccent),
  'org.caw.utility': _entry('utility', 'UTILITY', Icons.tune, DeviceFamily.utility, () => const UtilityDevicePage()),
  'org.caw.shift': _entry('shift', 'PITCH', Icons.height, DeviceFamily.creative, () => const ShiftDevicePage(),
      accent: pitchAccent),
};

/// The pages by every id the editor registry looks up for these devices: each variant's old id (or page id), which
/// is what [DeviceEditors.custom] turns a merged device's id into (the EQ & Filter pages are registered the same way).
final Map<String, DeviceEditorEntry> fxSpaceMergedEditors = {
  for (final v in MergedDevices.variants)
    if (_pages.containsKey(v.id)) v.oldId: _pages[v.id]!,
};

/// A device page: [cards] (the variant cards), the [hero], [rows] (chips and switches), the [knobs] and, under MORE,
/// [more]. On a wide editor (900 dp and more) the hero sits beside the controls; inline in the FX stack it keeps the
/// cards, the hero at compact height and the main knobs.
Widget mergedPage(BuildContext context, String id, {Widget? cards, required Widget hero, List<Widget> rows = const [],
    required Widget knobs, Widget? more}) {
  final inline = DeviceScope.isInline(context);
  final controls = [
    for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 4), child: r),
    knobs,
    if (more != null && !inline) DeviceFold(child: more),
  ];
  if (inline) return effectPage(id, [?cards, hero, ...controls]);
  return LayoutBuilder(builder: (context, box) {
    if (box.maxWidth < 900) return effectPage(id, [?cards, hero, ...controls]);
    return ListView(key: ValueKey('fx-page-$id'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
      ?cards,
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 11, child: hero),
        const SizedBox(width: 18),
        Expanded(flex: 8, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min,
            children: controls)),
      ]),
    ]);
  });
}

/// A row of small labelled controls that wraps on a narrow panel.
Widget controlsRow(List<Widget> children) =>
    Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: children);

/// A small spaced-capital label beside a control.
Widget smallLabel(String text) => Text(text,
    style: const TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim));
