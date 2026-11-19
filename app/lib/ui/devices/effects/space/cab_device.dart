// The Convolver's Cab mode (org.caw.convolver 1, 1.1.0): cabinet cards, the speaker with its mic dragged for position and distance, and the cabinet's response curve.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart' show spectrumColors;
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../dyn_drive/common.dart' show ColorModeCards;
import '../effect_page.dart';
import '../eqfilter/variant_cards.dart' show VariantCards;
import '../modes_kit.dart';
import 'space_devices.dart' show mergedPage;

/// The six cabinets' speaker layouts (columns, rows, cone size 0..1): 1x12 open, 2x12, 4x12, 1x10, 4x10, 1x15.
const _layouts = [(1, 1, 0.8), (2, 1, 0.8), (2, 2, 0.8), (1, 1, 0.6), (2, 2, 0.6), (1, 1, 1.0)];

/// A sketch of each cabinet's voice in dB (≈: C.A.W's cabinets are its own designs, rendered in the engine; this
/// draws their kind: the lows a box holds, the peaks and the top roll-off), then the mic's position (a high shelf at
/// 3 kHz, +2..−8 dB, and a presence bell at 4.5 kHz, +3..−3) and distance (proximity +6 dB at 150 Hz close, a low-pass
/// from 20 down to 9 kHz far), as the engine's filters after it.
double cabResponseDb(int cab, double hz, {required double position, required double distance}) {
  const hp = [90.0, 75.0, 60.0, 110.0, 45.0, 35.0];
  const lp = [7500.0, 6200.0, 5200.0, 9500.0, 4400.0, 3600.0];
  const bumps = [
    [(140.0, 3.0), (900.0, -2.0), (2400.0, 4.0), (4800.0, -3.0)],
    [(120.0, 3.5), (700.0, -2.5), (2000.0, 3.5), (4000.0, -4.0)],
    [(100.0, 5.0), (600.0, -3.0), (1800.0, 4.0), (3400.0, -4.5)],
    [(180.0, 2.0), (1100.0, -1.5), (2900.0, 5.0), (6000.0, -2.0)],
    [(80.0, 5.5), (500.0, -2.0), (1500.0, 3.0), (3000.0, -5.0)],
    [(70.0, 6.0), (400.0, -2.5), (1200.0, 2.5), (2600.0, -5.0)],
  ];
  final k = cab.clamp(0, 5);
  double oct(double a, double b) => math.log(a / b) / math.ln2;
  var db = -10 * math.log(1 + math.pow(hp[k] / hz, 4)) / math.ln10 - 10 * math.log(1 + math.pow(hz / lp[k], 8)) / math.ln10;
  for (final (f0, g) in bumps[k]) {
    db += g * math.exp(-math.pow(oct(hz, f0) * 1.6, 2));
  }
  double shelf(double fc) => 1 / (1 + math.exp(-oct(hz, fc) * 3));
  db += (2 - 10 * position) * shelf(3000) + (3 - 6 * position) * math.exp(-math.pow(oct(hz, 4500) * 1.4, 2));
  db += 6 * (1 - distance) * (1 - shelf(150));
  final top = 20000 - 11000 * distance;
  db -= 10 * math.log(1 + math.pow(hz / top, 4)) / math.ln10;
  return db;
}

/// Cab: the Convolver and Cab as cards; the six cabinets as cards (each its speakers drawn); the speaker seen from
/// the front with the mic on it (drag sideways from centre to edge for position, up and down for distance) beside
/// the cabinet's response; position, distance and the engine's live response under it.
class CabDevicePage extends StatelessWidget {
  const CabDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final inline = DeviceScope.isInline(context);
    final cards = Padding(padding: const EdgeInsets.only(bottom: 8), child: VariantCards(height: inline ? 44 : 50,
        icon: (c, r, i, col) => i == 0 ? iconCurve(c, r.deflate(3), col, (x) => x < -0.8 ? 0.9 : 0.9 * math.exp(-(x + 0.8) * 2.2) * math.cos(x * 9))
            : _cabIcon(c, r.deflate(2), 2, col)));
    final cabs = Padding(padding: const EdgeInsets.only(bottom: 8), child: LayoutBuilder(builder: (context, box) =>
        ColorModeCards('cab', height: inline ? 46 : 58, perRow: box.maxWidth < 560 ? 3 : 6,
            colorOf: (k) => spectrumColors()[const [1, 2, 7, 4, 5, 6][k.clamp(0, 5)]],
            icon: (c, r, i, col) => _cabIcon(c, r, i, col))));
    final hero = HeroCanvas(
      color: scope.accent,
      height: 200,
      caption: 'MIC',
      grid: false,
      readout: Builder(builder: (context) =>
          Text('${valueText(scope, 'cab')} · ${(scope.target.value('position') * 100).round()}% edge')),
      child: const _CabHero(),
    );
    if (inline) return effectPage('cab', [cards, cabs, hero]);
    return mergedPage(context, 'cab', cards: Column(mainAxisSize: MainAxisSize.min, children: [cards, cabs]), hero: hero,
        knobs: const KnobRow(['position', 'distance'], size: 56, labels: {'position': 'Mic position', 'distance': 'Distance'}));
  }
}

void _cabIcon(Canvas canvas, Rect r, int i, Color c) {
  final (cols, rows, cone) = _layouts[i.clamp(0, 5)];
  final box = Rect.fromCenter(center: r.center, width: math.min(r.width, r.height * 1.5), height: r.height);
  canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)), Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.3);
  final cw = box.width / cols, ch = box.height / rows;
  for (var x = 0; x < cols; x++) {
    for (var y = 0; y < rows; y++) {
      final center = Offset(box.left + cw * (x + 0.5), box.top + ch * (y + 0.5));
      final rad = math.min(cw, ch) * 0.42 * (0.55 + 0.45 * cone);
      canvas.drawCircle(center, rad, Paint()
        ..color = c.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
      canvas.drawCircle(center, rad * 0.3, Paint()..color = c.withValues(alpha: 0.6));
    }
  }
}

class _CabHero extends StatefulWidget {
  const _CabHero();

  @override
  State<_CabHero> createState() => _CabHeroState();
}

class _CabHeroState extends State<_CabHero> {
  bool _active = false;
  double _pos = 0, _dist = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final cone = Rect.fromLTWH(10, 24, math.min(w * 0.42, h - 30), h - 30);
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('cab-hero'),
        onStart: (_, _) {
          _pos = t.value('position');
          _dist = t.value('distance');
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _pos = (_pos + u.delta.dx / (cone.width / 2) * fine).clamp(0.0, 1.0);
          _dist = (_dist - u.delta.dy / cone.height * fine).clamp(0.0, 1.0);
          t.setLive('position', _pos);
          t.setLive('distance', _dist);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({for (final id in ['position', 'distance']) if (t.param(id) case final p?) id: p.defaultValue}),
        child: CustomPaint(size: Size(w, h), painter: _CabPainter(
          cone: cone,
          cab: t.value('cab').round(),
          position: t.value('position'),
          distance: t.value('distance'),
          ir: f?.raw == null || f!.at(7) < 2 ? null : [for (var k = 0; k < f.at(7).round() && 8 + k < f.raw!.length; k++) f.at(8 + k)],
          color: scope.accent,
          second: scope.secondary,
          active: _active)),
      ));
    });
  }
}

class _CabPainter extends CustomPainter {
  _CabPainter({required this.cone, required this.cab, required this.position, required this.distance, required this.ir,
    required this.color, required this.second, required this.active});
  final Rect cone;
  final int cab;
  final double position, distance;
  final List<double>? ir;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // The speaker, face on: the surround, the cone's rings and the dust cap; the mic over it, smaller as it backs off.
    final c = cone.center, rad = math.min(cone.width, cone.height) / 2;
    canvas.drawCircle(c, rad, Paint()..color = Neon.ink.withValues(alpha: 0.06));
    for (final (k, a) in [(1.0, 0.5), (0.86, 0.25), (0.62, 0.18), (0.4, 0.18)]) {
      canvas.drawCircle(c, rad * k, Paint()
        ..color = color.withValues(alpha: a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = k == 1 ? 2 : 1);
    }
    canvas.drawCircle(c, rad * 0.22, Paint()..color = color.withValues(alpha: 0.3));
    final mic = Offset(c.dx + position * rad * 0.95, c.dy);
    final mr = 11 - 6 * distance;
    canvas.drawLine(mic, Offset(mic.dx, cone.top - 4), Paint()
      ..color = Neon.ink.withValues(alpha: 0.3)
      ..strokeWidth = 2);
    canvas.drawCircle(mic, mr + 6 * (1 - distance), Paint()..color = second.withValues(alpha: 0.12 + 0.12 * (1 - distance)));
    paintHandle(canvas, mic, second, active: active, r: mr);
    paintLabel(canvas, 'CENTRE', Offset(c.dx, cone.bottom + 2), Neon.dim, size: 7.5, align: 0);
    paintLabel(canvas, 'EDGE', Offset(c.dx + rad, cone.bottom + 2), Neon.dim, size: 7.5, align: 0);
    paintLabel(canvas, distance < 0.33 ? 'CLOSE' : distance < 0.66 ? 'MID' : 'FAR', Offset(cone.left, cone.top + 4), second,
        size: 8, weight: FontWeight.w800);
    // The response, 40 Hz..16 kHz on a log axis, ±18 dB.
    final r = Rect.fromLTRB(cone.right + 16, 30, size.width - 10, size.height - 22);
    if (r.width < 60) return;
    paintLogGrid(canvas, r, lo: 40, hi: 16000);
    double y(double db) => r.center.dy - (db / 18).clamp(-1.0, 1.0) * r.height / 2;
    canvas.drawLine(Offset(r.left, y(0)), Offset(r.right, y(0)), Paint()..color = Neon.ink.withValues(alpha: 0.12));
    final path = Path();
    const n = 120;
    for (var i = 0; i <= n; i++) {
      final hz = logHz(i / n, lo: 40, hi: 16000);
      final p = Offset(r.left + r.width * i / n, y(cabResponseDb(cab, hz, position: position, distance: distance)));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    fillFade(canvas, Path.from(path)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..close(), r.bottom, size, color, alpha: 0.18);
    strokeGlow(canvas, path, color, width: active ? 2.4 : 1.9);
    paintLabel(canvas, 'RESPONSE ≈', Offset(r.left, r.top - 8), Neon.dim, size: 8, weight: FontWeight.w700);
    // The engine's impulse response, live: a strip under the curve.
    if (ir case final v? when v.any((x) => x != 0)) {
      final top = v.fold(1e-9, (a, b) => math.max(a, b.abs()));
      final strip = Rect.fromLTRB(r.left, size.height - 16, r.right, size.height - 4);
      final bw = strip.width / v.length;
      for (var k = 0; k < v.length; k++) {
        final a = (v[k].abs() / top).clamp(0.0, 1.0);
        canvas.drawRect(Rect.fromLTWH(strip.left + k * bw, strip.bottom - strip.height * a, math.max(1, bw - 0.5), strip.height * a),
            Paint()..color = second.withValues(alpha: 0.7));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CabPainter o) => true;
}
