// The AutoStacc pack's Bend (a bending grid whose curve points drag) and Molt (a frozen spectrum painted through the device's state) pages.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../model/arrange_fx.dart';
import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/repaint.dart';
import '../creative/creative_common.dart' show LabelledChoice;
import '../dyn_drive/common.dart' show chipWrap;
import '../space/space_devices.dart' show mergedPage;
import '../voice/voice_devices.dart' show rawAt;
import 'pack_devices.dart' show paintToyTray, paintToyCell;

// ---------------------------------------------------------------------------------------------------------------
// Bend

/// The plot inside Bend's grid of [size] (the painter's and the drag's).
Rect bendPlot(Size size) => Rect.fromLTRB(18, 26, size.width - 18, size.height - 22);

/// Bend's curve at [x] (0..1 through a cycle) through [points] (−1..1, cyclic) by [shape] (0 Linear, 1 Smooth,
/// 2 Step), as the engine plays it.
double bendCurve(List<double> points, int shape, double x) {
  final n = points.length;
  if (n == 0) return 0;
  final u = (x - x.floorToDouble()) * n;
  final i = u.floor() % n;
  final f = u - u.floorToDouble();
  final a = points[i], b = points[(i + 1) % n];
  return switch (shape) {
    1 => a + (b - a) * (1 - math.cos(math.pi * f)) / 2,
    2 => a,
    _ => a + (b - a) * f,
  };
}

/// How many points Bend's `points` choice gives (4, 8 or 16).
int bendPoints(DeviceScope scope) {
  final p = scope.target.param('points');
  if (p == null || p.choices.isEmpty) return 8;
  final i = (scope.target.value('points') - p.min).round().clamp(0, p.choices.length - 1);
  return int.tryParse(p.choices[i].trim()) ?? 8;
}

/// Bend: a grid that bends with the curve (rows swell where the curve rises, columns lean with it), the points as
/// big handles to drag up and down, and the cycle's playhead; Time (depth) or Speed (range) over the knobs.
class BendPage extends StatelessWidget {
  const BendPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final speed = scope.target.value('mode') >= 0.5;
    return mergedPage(context, 'bend',
      hero: HeroCanvas(
        color: scope.accent,
        height: 220,
        caption: speed ? 'SPEED' : 'TIME',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final raw = f?.raw;
          if ((raw?.length ?? 0) < 88) return Text('≈ ${bendPoints(scope)} points');
          return Text(speed ? 'speed ×${rawAt(raw, 6).toStringAsFixed(2)}' : 'delay ${rawAt(raw, 5).toStringAsFixed(0)} ms');
        }),
        child: const _BendHero(),
      ),
      rows: [const LabelledChoice('MODE', 'mode'), const LabelledChoice('POINTS', 'points'),
        const LabelledChoice('SHAPE', 'shape'), if (speed) chipWrap([const DeviceToggle('resync', label: 'Resync')])],
      knobs: KnobRow([speed ? 'range' : 'depth', 'cycle', 'smooth', 'mix'], size: 50),
      more: const KnobRow(['output'], size: 42),
    );
  }
}

class _BendHero extends StatefulWidget {
  const _BendHero();

  @override
  State<_BendHero> createState() => _BendHeroState();
}

class _BendHeroState extends State<_BendHero> {
  int? _point;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final r = bendPlot(size);
      final n = bendPoints(scope);
      void move(Offset at) {
        final k = _point;
        if (k == null) return;
        t.setLive('p$k', (1 - 2 * (at.dy - r.top) / r.height).clamp(-1.0, 1.0));
      }
      return GrabGesture(
        key: const ValueKey('bend-hero'),
        onStart: (at, _) {
          setState(() => _point = (((at.dx - r.left) / r.width) * n).round() % n);
          DeviceFeel.grab();
          move(at);
        },
        onUpdate: (u) => move(u.local),
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _point = null);
        },
        onDoubleTap: (_) => t.setAll({for (var k = 0; k < n; k++) if (t.param('p$k') case final p?) 'p$k': p.defaultValue}),
        child: DeviceDisplay(builder: (context, f) {
          final raw = (f?.raw?.length ?? 0) >= 88 ? f!.raw : null;
          final played = raw != null && [for (var i = 24; i < 88; i++) raw[i]].any((v) => v != 0)
              ? [for (var i = 24; i < 88; i++) raw[i]] : null;
          return CustomPaint(size: size, painter: BendPainter(
            points: [for (var k = 0; k < n; k++) t.value('p$k')],
            shape: t.value('shape').round(),
            played: played,
            phase: raw == null ? null : rawAt(raw, 4),
            selected: _point,
            color: scope.accent,
            second: scope.secondary));
        }),
      );
    });
  }
}

class BendPainter extends CustomPainter {
  BendPainter({required this.points, required this.shape, required this.played, required this.phase, required this.selected,
    required this.color, required this.second});
  final List<double> points;
  final int shape;
  final List<double>? played;
  final double? phase;
  final int? selected;
  final Color color, second;

  double _v(double x) {
    if (played case final p?) {
      final u = (x - x.floorToDouble()) * p.length;
      final i = u.floor() % p.length;
      return p[i] + (p[(i + 1) % p.length] - p[i]) * (u - u.floorToDouble());
    }
    return bendCurve(points, shape, x);
  }

  @override
  void paint(Canvas canvas, Size size) {
    paintToyTray(canvas, size, color, second);
    final r = bendPlot(size);
    double yOf(double v) => r.center.dy - v.clamp(-1.0, 1.0) * r.height / 2;
    // The bending grid: rows pulled by the curve (most in the middle, the edges pinned), columns leaning with it.
    const rows = 8, cols = 16, steps = 48;
    Offset node(double x, int row) {
      final w = math.sin(math.pi * row / rows);
      final v = _v(x);
      final base = r.top + r.height * row / rows;
      final lean = (_v(x + 0.02) - _v(x - 0.02)) * r.width / cols * 0.6;
      return Offset(r.left + r.width * x + lean * w, base - v * w * r.height * 0.18);
    }
    for (var row = 0; row <= rows; row++) {
      final path = Path();
      for (var s = 0; s <= steps; s++) {
        final o = node(s / steps, row);
        s == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, Paint()
        ..color = Color.lerp(color, second, row / rows)!.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round);
    }
    for (var c = 0; c <= cols; c++) {
      final path = Path();
      for (var row = 0; row <= rows; row++) {
        final o = node(c / cols, row);
        row == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, Paint()
        ..color = Neon.ink.withValues(alpha: 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4);
    }
    // The curve itself.
    final curve = Path();
    for (var s = 0; s <= 96; s++) {
      final x = s / 96;
      final o = Offset(r.left + r.width * x, yOf(_v(x)));
      s == 0 ? curve.moveTo(o.dx, o.dy) : curve.lineTo(o.dx, o.dy);
    }
    strokeGlow(canvas, curve, color, width: 3.5);
    if (phase case final ph?) {
      final x = r.left + r.width * ph.clamp(0.0, 1.0);
      canvas.drawLine(Offset(x, r.top - 6), Offset(x, r.bottom + 6), Paint()
        ..color = Neon.text.withValues(alpha: 0.6)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round);
      canvas.drawCircle(Offset(x, yOf(_v(ph))), 6, Paint()..color = Neon.text);
    }
    final n = points.length;
    for (var k = 0; k < n; k++) {
      final at = Offset(r.left + r.width * k / n, yOf(points[k]));
      paintHandle(canvas, at, Color.lerp(color, second, k / n)!, active: selected == k, r: n > 8 ? 5.5 : 7.5);
    }
    paintLabel(canvas, '+1', Offset(r.left - 10, r.top), Neon.dim, size: 7, align: 0);
    paintLabel(canvas, '−1', Offset(r.left - 10, r.bottom), Neon.dim, size: 7, align: 0);
  }

  @override
  bool shouldRepaint(covariant BendPainter o) => paintInputsChanged(
      [...o.points, o.shape, ...?o.played, o.phase, o.selected, o.color, o.second],
      [...points, shape, ...?played, phase, selected, color, second]);
}

// ---------------------------------------------------------------------------------------------------------------
// Molt

const irisBands = 64;
const _irisMagic = 0x53495249;  // "IRIS"
const _irisHeader = 20;

/// The painted curve (64 bands, dB) in Molt state [bytes], or null when they are no Molt state.
List<double>? irisPaintOf(Uint8List? bytes) {
  if (bytes == null || bytes.length < _irisHeader + 4 * irisBands) return null;
  final b = ByteData.sublistView(bytes);
  if (b.getUint32(0, Endian.little) != _irisMagic || b.getUint32(4, Endian.little) != irisBands) return null;
  return [for (var k = 0; k < irisBands; k++) b.getFloat32(_irisHeader + 4 * k, Endian.little).clamp(-60.0, 12.0)];
}

/// Molt state [base] (as the engine saved it: its frozen spectrum kept) with [paint] as its painted curve; with no
/// usable base, a state of the curve alone (no spectrum: the next freeze captures one). docs/engine.md, "Molt".
Uint8List irisStateWith(Uint8List? base, List<double> paint) {
  final out = irisPaintOf(base) != null ? Uint8List.fromList(base!) : Uint8List(_irisHeader + 4 * irisBands);
  final b = ByteData.sublistView(out);
  if (irisPaintOf(base) == null) {
    b.setUint32(0, _irisMagic, Endian.little);
    b.setUint32(4, irisBands, Endian.little);
  }
  for (var k = 0; k < irisBands; k++) {
    b.setFloat32(_irisHeader + 4 * k, k < paint.length ? paint[k].clamp(-60.0, 12.0) : 0, Endian.little);
  }
  return out;
}

/// Molt: the frozen spectrum as a row of chunky bars (as it plays: the capture times the painted curve; its outline
/// unpainted), the input's spectrum as a line over it, and the painted curve, which a finger paints (dragging across
/// the bands, up to +12 dB, down to −60); double-tap: flat. Freeze and the stages under it.
class IrisPage extends StatelessWidget {
  const IrisPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return mergedPage(context, 'iris',
      hero: HeroCanvas(
        color: scope.accent,
        height: 230,
        caption: 'PAINT THE SPECTRUM',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final raw = f?.raw;
          if ((raw?.length ?? 0) < 201) return Text(scope.target.value('freeze') >= 0.5 ? '≈ frozen' : '≈ live');
          return Text('${rawAt(raw, 3) > 0.5 ? 'frozen ${(rawAt(raw, 2) * 100).round()} %' : 'nothing frozen'}'
              ' · ${rawAt(raw, 4).round()} pt · ${rawAt(raw, 5).toStringAsFixed(0)} ms');
        }),
        child: const _IrisHero(),
      ),
      rows: [chipWrap([const DeviceToggle('freeze', label: 'Freeze', icon: Icons.ac_unit)]), const LabelledChoice('WINDOW', 'quality')],
      knobs: KnobRow(const ['paint', 'fade', 'drift', 'blur', 'shift', 'mix'], size: 48),
      more: const KnobRow(['gate', 'gate_range', 'output'], size: 44),
    );
  }
}

/// The plot inside Molt's hero of [size] (the painter's and the brush's).
Rect irisPlot(Size size) => Rect.fromLTRB(14, 24, size.width - 30, size.height - 20);

class _IrisHero extends StatefulWidget {
  const _IrisHero();

  @override
  State<_IrisHero> createState() => _IrisHeroState();
}

class _IrisHeroState extends State<_IrisHero> {
  List<double>? _paint;  // while a finger paints (and the engine catches up)
  Uint8List? _base;
  int? _last;
  final _sent = Stopwatch();

  /// The project's copy of the state, else nothing.
  List<double>? _kept(DeviceScope scope) {
    final layer = scope.target.layer;
    final slot = scope.target.slot;
    if (layer == null || slot < 0 || slot >= layer.components.length) return null;
    return irisPaintOf(scope.target.state.savedEffectState(layer, slot));
  }

  void _write(DeviceScope scope, {required bool keep}) {
    final layer = scope.target.layer;
    final p = _paint;
    if (layer == null || p == null || scope.target.slot < 0) return;
    scope.target.state.writeNativeEffectState(layer, scope.target.slot, irisStateWith(_base, p), keep: keep);
    _sent..reset()..start();
  }

  void _brush(DeviceScope scope, Rect r, Offset at) {
    final p = _paint;
    if (p == null) return;
    final band = (((at.dx - r.left) / r.width) * irisBands).floor().clamp(0, irisBands - 1);
    final db = (12 - 72 * (at.dy - r.top) / r.height).clamp(-60.0, 12.0);
    final from = _last ?? band;
    final fromDb = p[from];
    final steps = (band - from).abs();
    for (var i = 0; i <= steps; i++) {
      final k = from + (band >= from ? i : -i);
      p[k] = steps == 0 ? db : fromDb + (db - fromDb) * i / steps;
    }
    _last = band;
    setState(() {});
    if (_sent.elapsedMilliseconds > 80) _write(scope, keep: false);
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final r = irisPlot(size);
      return GrabGesture(
        key: const ValueKey('iris-hero'),
        onStart: (at, _) {
          final layer = scope.target.layer;
          _base = layer == null ? null : scope.target.state.savedEffectState(layer, scope.target.slot);
          _paint = List.of(irisPaintOf(_base) ?? _kept(scope) ?? List.filled(irisBands, 0.0));
          _last = null;
          _sent..reset()..start();
          DeviceFeel.grab();
          _brush(scope, r, at);
        },
        onUpdate: (u) => _brush(scope, r, u.local),
        onEnd: () {
          _write(scope, keep: true);
          DeviceFeel.release();
          setState(() => _paint = null);
        },
        onDoubleTap: (_) {
          final layer = scope.target.layer;
          _base = layer == null ? null : scope.target.state.savedEffectState(layer, scope.target.slot);
          _paint = List.filled(irisBands, 0.0);
          _write(scope, keep: true);
          setState(() => _paint = null);
        },
        child: DeviceDisplay(builder: (context, f) {
          final raw = (f?.raw?.length ?? 0) >= 201 ? f!.raw : null;
          final captured = raw != null && rawAt(raw, 3) > 0.5;
          final paint = _paint ?? _kept(scope) ??
              (raw == null ? List.filled(irisBands, 0.0) : [for (var k = 0; k < irisBands; k++) raw[137 + k]]);
          return CustomPaint(size: size, painter: IrisPainter(
            input: raw == null ? null : [for (var k = 0; k < irisBands; k++) raw[9 + k]],
            frozen: captured ? [for (var k = 0; k < irisBands; k++) raw[73 + k]] : null,
            curve: List.of(paint),
            amount: scope.target.value('paint'),
            painting: _paint != null,
            color: scope.accent,
            second: scope.secondary));
        }),
      );
    });
  }
}

class IrisPainter extends CustomPainter {
  IrisPainter({required this.input, required this.frozen, required this.curve, required this.amount, required this.painting,
    required this.color, required this.second});
  final List<double>? input, frozen;
  final List<double> curve;
  final double amount;
  final bool painting;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    paintToyTray(canvas, size, color, second);
    final r = irisPlot(size);
    final w = r.width / irisBands;
    double specY(double db) => r.bottom - r.height * ((db + 96) / 96).clamp(0.0, 1.0);
    double paintY(double db) => r.top + r.height * (12 - db.clamp(-60.0, 12.0)) / 72;
    // The frozen spectrum as it plays (the capture times the paint); without one, the painted curve's own blocks.
    for (var k = 0; k < irisBands; k++) {
      final x = r.left + w * k;
      final Rect bar;
      double lit;
      if (frozen case final fz?) {
        bar = Rect.fromLTRB(x + w * 0.12, specY(fz[k] + curve[k] * amount), x + w * 0.88, r.bottom);
        lit = ((fz[k] + 96) / 96).clamp(0.0, 1.0);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x + w * 0.12, specY(fz[k]), x + w * 0.88, r.bottom),
            Radius.circular(w * 0.35)), Paint()
          ..color = Neon.ink.withValues(alpha: 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
      } else {
        bar = Rect.fromLTRB(x + w * 0.12, paintY(curve[k]), x + w * 0.88, r.bottom);
        lit = 0.15;
      }
      if (bar.height > 1) paintToyCell(canvas, bar, Color.lerp(color, second, k / irisBands)!, lit);
    }
    // The input's spectrum.
    if (input case final inp?) {
      final path = Path();
      for (var k = 0; k < irisBands; k++) {
        final o = Offset(r.left + w * (k + 0.5), specY(inp[k]));
        k == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, Paint()
        ..color = Neon.text.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
    }
    // The painted curve, its 0 dB line and scale.
    canvas.drawLine(Offset(r.left, paintY(0)), Offset(r.right, paintY(0)), Paint()..color = Neon.ink.withValues(alpha: 0.12));
    final line = Path();
    for (var k = 0; k < irisBands; k++) {
      final o = Offset(r.left + w * (k + 0.5), paintY(curve[k]));
      k == 0 ? line.moveTo(o.dx, o.dy) : line.lineTo(o.dx, o.dy);
    }
    strokeGlow(canvas, line, painting ? Neon.text : color, width: painting ? 3.5 : 2.5);
    for (final (db, label) in const [(12.0, '+12'), (0.0, '0'), (-30.0, '−30'), (-60.0, '−60')]) {
      paintLabel(canvas, label, Offset(r.right + 4, paintY(db)), Neon.dim, size: 7);
    }
    for (final (hz, label) in const [(100.0, '100'), (1000.0, '1k'), (10000.0, '10k')]) {
      final x = r.left + r.width * math.log(hz / 20) / math.log(1000);
      paintLabel(canvas, label, Offset(x, r.bottom + 9), Neon.dim, size: 7, align: 0);
    }
    if (frozen == null) {
      paintLabel(canvas, input == null ? '≈ freeze to capture' : 'freeze to capture', Offset(r.left + 4, r.top - 10),
          Neon.dim, size: 8);
    }
  }

  @override
  bool shouldRepaint(covariant IrisPainter o) => paintInputsChanged(
      [...?o.input, ...?o.frozen, ...o.curve, o.amount, o.painting, o.color, o.second],
      [...?input, ...?frozen, ...curve, amount, painting, color, second]);
}
