// Small parts the 1.1.0 modes' pages share: a log frequency axis, a lit pill, a choice as a pill with a menu, a drag-to-edit area and an LED.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../feedback.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart' show taperOf;
import '../device_scope.dart';
import '../kit/feel.dart';
import '../kit/device_style.dart' show spectrumColors;
import '../kit/hero.dart';

/// [hz] on a log axis from [lo] to [hi] as 0..1.
double logUnit(double hz, {double lo = 20, double hi = 20000}) =>
    ((math.log(math.max(hz, 1e-3)) - math.log(lo)) / (math.log(hi) - math.log(lo))).clamp(0.0, 1.0);

/// The frequency at [u] 0..1 on that axis.
double logHz(double u, {double lo = 20, double hi = 20000}) => lo * math.pow(hi / lo, u.clamp(0.0, 1.0)).toDouble();

/// A short Hz label: 120, 1.2k, 12k.
String hzLabel(double hz) => hz >= 10000
    ? '${(hz / 1000).round()}k'
    : hz >= 1000
        ? '${(hz / 1000).toStringAsFixed(1)}k'
        : '${hz.round()}';

/// The faint frequency lines of a log grid (100 Hz, 1 kHz, 10 kHz labelled) inside [r].
void paintLogGrid(Canvas canvas, Rect r, {double lo = 20, double hi = 20000, bool labels = true}) {
  final line = Paint()..color = Neon.ink.withValues(alpha: 0.07);
  for (final hz in [50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0]) {
    if (hz <= lo || hz >= hi) continue;
    final x = r.left + logUnit(hz, lo: lo, hi: hi) * r.width;
    canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), line);
    if (labels && (hz == 100 || hz == 1000 || hz == 10000)) {
      paintLabel(canvas, hzLabel(hz), Offset(x + 3, r.bottom - 7), Neon.dim, size: 8);
    }
  }
}

/// A pill that lights when [on] and runs [onTap] (a solo, a Clean, a Learn); [keyName] keys it for tests.
class LitPill extends StatelessWidget {
  const LitPill({super.key, required this.label, required this.on, required this.onTap, this.color, this.icon,
    this.height = 30, this.keyName});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final Color? color;
  final IconData? icon;
  final double height;
  final String? keyName;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DeviceScope.of(context).accent;
    return Semantics(button: true, toggled: on, label: label, child: GestureDetector(
      key: keyName == null ? null : ValueKey<String>(keyName!),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DeviceFeel.tap();
        onTap();
      },
      child: Pressable(glow: c, radius: height / 2, child: AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        height: height,
        constraints: BoxConstraints(minWidth: height),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          color: on ? c.withValues(alpha: 0.24) : Neon.ink.withValues(alpha: 0.03),
          border: Border.all(color: on ? c : Neon.line),
          boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 8)] : null),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: on ? c : Neon.dim), const SizedBox(width: 4)],
          // Ellipsized rather than overflowing a phone-width pill (Lark's "Edit pitch… (put an audio clip on this
          // track)" ran 132 px past a 390 dp screen).
          Flexible(child: Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, letterSpacing: 0.8, fontWeight: FontWeight.w800,
              color: on ? Neon.text : Neon.dim))),
        ]),
      )),
    ));
  }
}

/// A choice parameter as one pill naming its value; a tap opens the choices (a band's drive type). Keys
/// `pill-<param>` and `pill-<param>-<k>` for its menu's items.
class ChoicePill extends StatelessWidget {
  const ChoicePill(this.paramId, {super.key, this.color, this.prefix});
  final String paramId;
  final Color? color;
  final String? prefix;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final c = color ?? scope.accent;
    final sel = (t.value(p.id) - p.min).round().clamp(0, p.choices.length - 1);
    return PopupMenuButton<int>(
      key: ValueKey('pill-${p.id}'),
      tooltip: p.label,
      initialValue: sel,
      onSelected: (k) {
        DeviceFeel.tap();
        t.set(p.id, p.min + k);
      },
      itemBuilder: (_) => [
        for (var k = 0; k < p.choices.length; k++)
          PopupMenuItem(key: ValueKey('pill-${p.id}-$k'), value: k, height: 36, child: Text(p.choices[k])),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), color: c.withValues(alpha: 0.16),
            border: Border.all(color: c.withValues(alpha: 0.8))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${prefix ?? ''}${p.choices[sel]}'.toUpperCase(), style: const TextStyle(fontSize: 9.5, letterSpacing: 0.6,
              fontWeight: FontWeight.w800, color: Neon.text)),
          Icon(Icons.arrow_drop_down, size: 16, color: c),
        ]),
      ),
    );
  }
}

/// A round light: lit in [color] when [on], with a glow.
class LedLight extends StatelessWidget {
  const LedLight({super.key, required this.on, required this.color, this.size = 12});
  final bool on;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: on
          ? [Color.lerp(color, Colors.white, 0.55)!, color, color.withValues(alpha: 0.6)]
          : [Neon.ink.withValues(alpha: 0.18), Neon.ink.withValues(alpha: 0.08), Neon.ink.withValues(alpha: 0.05)]),
      border: Border.all(color: on ? color : Neon.line),
      boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: size * 0.9, spreadRadius: size * 0.08)] : null,
    ),
  );
}

/// The value of [id] moved by [delta] of its travel (0..1 of its taper), held to its range.
double travelBy(DeviceScope scope, String id, double from, double delta) {
  final p = scope.target.param(id);
  if (p == null) return from;
  final tp = taperOf(p);
  return tp.value((tp.position(from) + delta).clamp(0.0, 1.0));
}

/// [id]'s value as its descriptor writes it, or '' with no such parameter.
String valueText(DeviceScope scope, String id) {
  final p = scope.target.param(id);
  return p == null ? '' : formatParamValue(p, scope.target.value(id));
}

/// The kit's red (the spectrum's last slot): a clip light, a mute, a pilot lamp.
Color redColor() => spectrumColors()[7];
