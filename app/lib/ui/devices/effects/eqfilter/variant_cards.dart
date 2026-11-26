// A merged device's mode cards (EQ & Filter, 1.0.8): its variants as drawn cards in the ModeTiles style, one undo step each.
import 'package:flutter/material.dart';

import '../../../../model/arrange_fx.dart';
import '../../../../model/merged_devices.dart';
import '../../../../model/variant_edit.dart';
import '../../../feedback.dart';
import '../../../haptics.dart';
import '../../../motion.dart';
import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart' show ChoiceIcon;
import '../../kit/feel.dart';

/// The variant the device under [context] plays (0 for a device that is no merged one).
int variantOf(BuildContext context) => DeviceScope.of(context).target.info?.variantIndex ?? 0;

/// Picks [t]'s variant [k] (the shell's change: one undo step, the knobs the variants don't share reset), with
/// [also] set in the same step; a haptic error when it can't.
void pickVariant(BuildContext context, int k, {Map<String, double> also = const {}}) {
  final t = DeviceScope.of(context).target;
  if ((t.info?.variantIndex ?? 0) == k) {
    if (also.isNotEmpty) t.setAll(also);
    return;
  }
  if (t.state.setDeviceVariant(t, k, also: also)) {
    DeviceFeel.tap();
  } else {
    Haptics.error();
  }
}

/// The device's variants as cards, each a drawn [icon] over its name ([names] shortens the engine's), the one it
/// plays lit. Replaces the shell's "Variant:" pill on these pages ([DeviceEditorEntry.ownsVariant]).
class VariantCards extends StatelessWidget {
  const VariantCards({super.key, required this.icon, this.names, this.height = 54, this.colorOf, this.rows});
  final ChoiceIcon icon;
  final List<String>? names;

  /// One row's height (each of [rows]).
  final double height;

  /// The cards in rows, by variant index (Curlew: woodwinds over brass), any it leaves out in a last row; null: one
  /// row in the engine's order.
  final List<List<int>>? rows;

  /// Each card's own colour (the Drive's variants), else the device's accent.
  final Color Function(int k)? colorOf;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final id = t.componentId;
    final base = id == null ? null : t.state.componentInfo(id);
    final choices = base?.param(variantParam)?.choices ?? const <String>[];
    if (base == null || base.variants.length < 2) return const SizedBox.shrink();
    final n = base.variants.length;
    final sel = (t.info?.variantIndex ?? 0).clamp(0, n - 1);
    Color col(int k) => colorOf?.call(k) ?? scope.accent;
    String name(int k) => names != null && k < names!.length ? names![k] : (k < choices.length ? choices[k] : 'Variant ${k + 1}');
    Widget card(int k) => _card(context, k, sel, col, name, base.label);
    final groups = rows?.map((r) => r.where((k) => k < n).toList()).where((r) => r.isNotEmpty).toList() ??
        [List.generate(n, (k) => k)];
    // A variant no row lists (a newer library's) still gets a card, in a last row.
    final rest = [for (var k = 0; k < n; k++) if (!groups.any((r) => r.contains(k))) k];
    if (rest.isNotEmpty) groups.add(rest);
    // Every row as many slots as the longest, so the cards keep one width (a shorter row ends early).
    final slots = groups.fold(0, (m, r) => r.length > m ? r.length : m);
    Widget row(List<int> ks) => SizedBox(height: height, child: Row(children: [
      for (var i = 0; i < slots; i++) Expanded(child: Padding(padding: EdgeInsets.only(right: i < slots - 1 ? 4 : 0),
          child: i < ks.length ? card(ks[i]) : const SizedBox.shrink())),
    ]));
    if (groups.length == 1) return row(groups.first);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < groups.length; i++) ...[if (i > 0) const SizedBox(height: 4), row(groups[i])],
    ]);
  }

  Widget _card(BuildContext context, int k, int sel, Color Function(int) col, String Function(int) name, String label) =>
        Semantics(
          button: true,
          selected: k == sel,
          label: '$label: ${name(k)}',
          child: GestureDetector(
            key: ValueKey('variant-card-$k'),
            behavior: HitTestBehavior.opaque,
            onTap: () => pickVariant(context, k),
            child: Pressable(glow: col(k), child: AnimatedContainer(
              duration: Motion.fade(Motion.small, Motion.of(context)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: k == sel ? col(k).withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
                border: Border.all(color: k == sel ? col(k) : Neon.line, width: k == sel ? 1.5 : 1),
                boxShadow: k == sel ? [BoxShadow(color: col(k).withValues(alpha: 0.25), blurRadius: 10)] : null),
              child: Column(children: [
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 2), child: CustomPaint(
                  size: Size.infinite, painter: _CardIcon(icon, k, k == sel ? col(k) : colorOf == null ? Neon.dim : Color.lerp(Neon.dim, col(k), 0.35)!)))),
                Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(name(k).toUpperCase(), maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9.5, letterSpacing: 0.6,
                    fontWeight: FontWeight.w800, color: k == sel ? Neon.text : Neon.dim))),
              ]),
            )),
          ),
        );
}

class _CardIcon extends CustomPainter {
  _CardIcon(this.icon, this.index, this.color);
  final ChoiceIcon icon;
  final int index;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => icon(canvas, Offset.zero & size, index, color);

  @override
  bool shouldRepaint(covariant _CardIcon o) => o.index != index || o.color != color || o.icon != icon;
}
