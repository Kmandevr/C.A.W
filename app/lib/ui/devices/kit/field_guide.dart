// The device header's "?": one sheet with the device's field guide (what it does, the three knobs that matter, a starting preset to load).
import 'package:flutter/material.dart';

import '../../../model/arrange_fx.dart';
import '../../../model/device_target.dart';
import '../../../model/field_guides.dart';
import '../../../model/merged_devices.dart' show MergedDevices, variantParam;
import '../../../model/variant_edit.dart';
import '../../panel_motion.dart';
import '../../theme.dart';
import 'feel.dart';
import 'presets.dart';

/// [t]'s field guide: its own ([fieldGuides]), else one made from its first knobs.
FieldGuide fieldGuideFor(DeviceTarget t) {
  final id = t.componentId;
  return (id == null ? null : fieldGuides[id] ?? fieldGuides[MergedDevices.of(id)?.id ?? '']) ??
      fieldGuideFallback(t.shortLabel, [for (final p in t.info?.knobs ?? const []) p.label]);
}

/// Loads the engine preset [name] into [t] as one undo step (a merged device's variant changes with it); false when
/// the device has no preset of that name.
bool loadGuidePreset(DeviceTarget t, String name) {
  final id = t.componentId;
  final base = id == null ? null : t.state.componentInfo(id);
  final preset = base?.presets.where((p) => p.name == name).firstOrNull;
  if (id == null || base == null || preset == null || t.use == null) return false;
  final p = DevicePreset(preset.name, preset.params, category: 'Factory');
  final v = preset.params[variantParam]?.round();
  if (v != null && MergedDevices.isMerged(id) && base.variants.length > v && t.info?.variantIndex != v) {
    // The variant and the preset's values in one step (the knobs it leaves out at their defaults).
    if (!t.state.setDeviceVariant(t, v, also: p.resolve(base.variants[v]))) return false;
    DevicePresets.remember(t, p);
    return true;
  }
  DevicePresets.apply(t, p);
  return true;
}

/// The header's "?": opens the field guide.
class DeviceGuideButton extends StatelessWidget {
  const DeviceGuideButton({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(width: 32, height: 36, child: IconButton(
    key: const ValueKey('device-guide'),
    tooltip: 'Field guide: what ${target.shortLabel} does',
    padding: EdgeInsets.zero,
    iconSize: 18,
    color: Neon.dim,
    onPressed: () {
      DeviceFeel.tap();
      showFieldGuide(context, target, color);
    },
    icon: const Icon(Icons.help_outline)));
}

/// The field guide sheet of [t].
Future<void> showFieldGuide(BuildContext context, DeviceTarget t, Color color) {
  final g = fieldGuideFor(t);
  final preset = g.preset;
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetAnimation(context),
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Neon.panel,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => SafeArea(child: SingleChildScrollView(
      key: const ValueKey('device-guide-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 8),
        Text(g.what, style: const TextStyle(fontSize: 13, height: 1.35)),
        const SizedBox(height: 16),
        const Text('THE THREE KNOBS THAT MATTER', style: TextStyle(fontSize: 10, letterSpacing: 0.8, color: Neon.dim,
          fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final (i, (knob, text)) in g.knobs.indexed) Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 20, height: 20, alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color)),
              child: Text('${i + 1}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color))),
            const SizedBox(width: 10),
            Expanded(child: Text.rich(TextSpan(children: [
              TextSpan(text: '$knob  ', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: text, style: const TextStyle(color: Neon.dim)),
            ]), style: const TextStyle(fontSize: 12, height: 1.35))),
          ]),
        ),
        const SizedBox(height: 16),
        const Text('START HERE', style: TextStyle(fontSize: 10, letterSpacing: 0.8, color: Neon.dim,
          fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (preset == null)
          const Text('Init: every knob at its default. Turn one at a time and listen.',
            style: TextStyle(fontSize: 12, color: Neon.dim))
        else Row(children: [
          Expanded(child: Text(preset, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          FilledButton.icon(
            key: const ValueKey('device-guide-load'),
            style: FilledButton.styleFrom(backgroundColor: color.withValues(alpha: 0.85), foregroundColor: Neon.bg),
            onPressed: () {
              DeviceFeel.detent();
              loadGuidePreset(t, preset);
              Navigator.of(context).maybePop();
            },
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Load it')),
        ]),
      ]),
    )),
  );
}
