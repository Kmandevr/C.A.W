// The Dynamics and Drive families' shared page parts (1.0.8 device pages): coloured mode cards and choice chips (variant cards: eqfilter/variant_cards.dart).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../feedback.dart';
import '../../../motion.dart';
import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart' show ChoiceIcon;
import '../../kit/feel.dart';
import '../../kit/key_param.dart';
import '../../kit/param_watch.dart';

/// One row (or rows of [perRow]) of big cards, each a drawn [icon] over its name, card [sel] lit in its own colour
/// ([colorOf]). The look of the kit's [ModeTiles], with a colour per card (Drive's modes each have their own curve
/// colour) and any action on a tap.
Widget cardRows(BuildContext context, {required int count, required int sel, required List<String> labels,
    required Color Function(int k) colorOf, required ChoiceIcon icon, required void Function(int k) onTap,
    required Key Function(int k) keyOf, required String Function(int k) semantics, double height = 54, int? perRow}) {
  final per = perRow == null || perRow >= count ? count : perRow;
  final rows = (count / per).ceil();
  Widget row(int from) {
    final to = math.min(count, from + per);
    return SizedBox(height: height, child: Row(children: [
      for (var k = from; k < to; k++)
        Expanded(child: Padding(padding: EdgeInsets.only(right: k < to - 1 ? 4 : 0), child: Semantics(
          button: true,
          selected: k == sel,
          label: semantics(k),
          child: GestureDetector(
            key: keyOf(k),
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap(k),
            child: Pressable(glow: colorOf(k), child: AnimatedContainer(
              duration: Motion.fade(Motion.small, Motion.of(context)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: k == sel ? colorOf(k).withValues(alpha: 0.18) : Neon.ink.withValues(alpha: 0.03),
                border: Border.all(color: k == sel ? colorOf(k) : Neon.line, width: k == sel ? 1.5 : 1),
                boxShadow: k == sel ? [BoxShadow(color: colorOf(k).withValues(alpha: 0.25), blurRadius: 10)] : null),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 6, 6, 2), child: CustomPaint(
                  size: Size.infinite,
                  painter: _CardIcon(icon, k, k == sel ? colorOf(k) : Color.lerp(Neon.dim, colorOf(k), 0.35)!)))),
                Padding(padding: const EdgeInsets.only(bottom: 4, left: 2, right: 2), child: Text(labels[k].toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, letterSpacing: 0.4,
                    fontWeight: FontWeight.w800, color: k == sel ? Neon.text : Neon.dim))),
              ]),
            )),
          ),
        ))),
      for (var k = to; k < from + per && rows > 1; k++) const Expanded(child: SizedBox()),
    ]));
  }

  return rows == 1 ? row(0) : Column(mainAxisSize: MainAxisSize.min, children: [
    for (var r = 0; r < rows; r++) Padding(padding: EdgeInsets.only(top: r == 0 ? 0 : 4), child: row(r * per)),
  ]);
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

/// A choice parameter as mode cards with a colour each ([colorOf]); keys `mode-<param>-<k>` as the kit's tiles.
class ColorModeCards extends StatelessWidget {
  const ColorModeCards(this.paramId, {super.key, required this.icon, required this.colorOf, this.names, this.height = 54,
    this.perRow});
  final String paramId;
  final ChoiceIcon icon;
  final Color Function(int k) colorOf;
  final List<String>? names;
  final double height;
  final int? perRow;

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final p = t.param(paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final n = p.choices.length;
    final sel = (t.value(p.id) - p.min).round().clamp(0, n - 1);
    return KeyParam(paramId: p.id, kind: KeyParamKind.choice, child: cardRows(context, count: n, sel: sel,
      labels: [for (var k = 0; k < n; k++) names != null && k < names!.length ? names![k] : p.choices[k]],
      colorOf: colorOf, icon: icon, height: height, perRow: perRow,
      keyOf: (k) => ValueKey('mode-${p.id}-$k'),
      semantics: (k) => '${p.label}: ${p.choices[k]}',
      onTap: (k) {
        DeviceFeel.tap();
        t.set(p.id, p.min + k);
      }));
  }
}

/// A short choice parameter as a titled row of pills (Detection: RMS, Peak, ISP; Sidechain: Internal, External);
/// keys `chip-<param>-<k>`. Nothing when the device has no such parameter.
class ChoiceChips extends StatelessWidget {
  const ChoiceChips(this.paramId, {super.key, required this.title, this.labels});
  final String paramId, title;
  final List<String>? labels;

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final sel = (t.value(p.id) - p.min).round().clamp(0, p.choices.length - 1);
    final c = scope.accent;
    // A Wrap, not a Row: a parameter with more choices than a phone's width (Swoop's) goes on to a second line.
    return KeyParam(paramId: p.id, kind: KeyParamKind.choice, child: Wrap(crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 4, children: [
      Text(title, style: const TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
      const SizedBox(width: 6),
      for (var k = 0; k < p.choices.length; k++)
        Padding(padding: const EdgeInsets.only(right: 4), child: Semantics(
          button: true,
          selected: k == sel,
          label: '${p.label}: ${p.choices[k]}',
          child: Pressable(glow: c, radius: 14, child: GestureDetector(
            key: ValueKey('chip-${p.id}-$k'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              DeviceFeel.tap();
              t.set(p.id, p.min + k);
            },
            child: AnimatedContainer(
              duration: Motion.fade(Motion.small, Motion.of(context)),
              height: 30,
              constraints: const BoxConstraints(minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: k == sel ? c.withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
                border: Border.all(color: k == sel ? c : Neon.line)),
              child: Text(labels != null && k < labels!.length ? labels![k] : p.choices[k],
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: k == sel ? Neon.text : Neon.dim)),
            ),
          )),
        )),
    ]));
  }
}

/// A wrap of [children] that are each present (chips and toggles under a hero), or nothing.
Widget chipWrap(List<Widget> children) => Padding(padding: const EdgeInsets.only(top: 4, bottom: 6),
    child: Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: children));

/// A drag's value change, held to [id]'s range on [scope]'s device.
double clampParam(DeviceScope scope, String id, double v) {
  final p = scope.target.param(id);
  return p == null ? v : v.clamp(p.min, p.max).toDouble();
}
