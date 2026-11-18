// The variant picker under a merged device's header (FX consolidation): "Variant: <name>" opens the choice of variants.
import 'package:flutter/material.dart';

import '../../model/arrange_fx.dart';
import '../../model/device_target.dart';
import '../../model/merged_devices.dart';
import '../../model/variant_edit.dart';
import '../arrange/long_press_menu.dart';
import '../feedback.dart';
import '../haptics.dart';
import '../theme.dart';

/// Shown for a merged device with more than one variant (Drive, Delay...): picking another is one undo step that
/// resets the knobs the new variant doesn't share ([VariantEdit.setDeviceVariant]). `variant` is set here only: it
/// is never automated, modulated or MIDI-learned.
class VariantBar extends StatelessWidget {
  const VariantBar({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = target, id = t.componentId;
    final base = id == null || t.isInstrument ? null : t.state.componentInfo(id);
    final info = t.info;
    if (base == null || info == null || base.variants.length < 2 || !MergedDevices.isMerged(id!)) {
      return const SizedBox.shrink();
    }
    final names = _names(base.variants.length, base.param(variantParam)?.choices ?? const []);
    final current = _current(t, base.variants.length);
    return SizedBox(height: 40, child: SingleChildScrollView(
      key: ValueKey('variant-bar-${t.slot}-${t.displayChild}'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Icon(Icons.layers_outlined, size: 14, color: color),
        const SizedBox(width: 6),
        Tooltip(message: 'Which kind of ${base.label} this is', child: Pressable(glow: color, radius: 14,
          child: GestureDetector(
            key: ValueKey('variant-pick-${t.slot}'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _pick(context, d.globalPosition, names, current),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: color.withValues(alpha: 0.1),
                border: Border.all(color: color.withValues(alpha: 0.6))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Variant: ${names[current]}', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800,
                  color: Neon.text)),
                const Icon(Icons.arrow_drop_down, size: 16, color: Neon.dim),
              ]),
            ),
          ))),
      ]),
    ));
  }

  static List<String> _names(int count, List<String> choices) =>
      [for (var i = 0; i < count; i++) i < choices.length ? choices[i] : 'Variant ${i + 1}'];

  /// The variant [t]'s values choose (a rack child's from its slot's `<slot>.variant`).
  static int _current(DeviceTarget t, int count) => t.info?.variantIndex.clamp(0, count - 1) ?? 0;

  Future<void> _pick(BuildContext context, Offset at, List<String> names, int current) async {
    final t = target;
    final pick = await showLongPressMenu<int>(context, at: at, title: '${t.label}: variant', actions: [
      for (var i = 0; i < names.length; i++) MenuAction(i, names[i], Icons.layers_outlined, checked: i == current),
    ]);
    if (pick == null || pick == current) return;
    if (t.state.setDeviceVariant(t, pick)) {
      Haptics.tap();
    } else {
      Haptics.error();
    }
  }
}
