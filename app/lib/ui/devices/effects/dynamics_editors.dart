// The dynamics family's plugin UIs: compressor (level history under a knee graph with a moving dot), limiter (ceiling over the
// gain-reduction history), gate (threshold on a scrolling level) and transient shaper (a hit's envelope reshaped).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_display.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import '../visuals/fx_visuals.dart' show CompressorGraph;
import 'effect_page.dart';

List<double> _levels(DeviceDisplayFrame f) =>
    [f.inputDb ?? -120, f.outputDb ?? -120, -(f.gainReductionDb ?? 0), f.values['open'] ?? 1, f.values['gain_db'] ?? 0];

String _db(double v, {int digits = 1}) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(digits)} dB';

// ---------------------------------------------------------------------------------------------------------------
// Compressor

/// The compressor: its level history (input grey, output in colour, reduction hanging from the top in pink) with
/// the threshold line, and the knee graph beside it with a dot riding the curve at the detector's level. Drag up
/// and down on the history for the threshold; in the knee graph sideways for the threshold, up and down for the
/// ratio. Then the main knobs, and the rest behind MORE.
class CompressorPage extends StatelessWidget {
  const CompressorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('compressor', [
      HeroCanvas(
        color: scope.accent,
        height: 214,
        caption: 'COMPRESSOR',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) => Text(f?.gainReductionDb == null ? '' : 'GR ${_db(f!.gainReductionDb!)}',
          style: Neon.code(size: 10, color: Neon.pink))),
        child: const _CompressorHero(),
      ),
      const KnobRow(['threshold', 'ratio', 'attack', 'release', 'makeup', 'mix'], size: 50),
      Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: const [
        DeviceToggle('auto_makeup', label: 'Auto makeup', icon: Icons.auto_fix_high),
        DeviceToggle('auto_release', label: 'Auto release', icon: Icons.auto_mode),
      ])),
      const DeviceFold(child: ParamGrid(only: ['knee', 'lookahead', 'detect', 'link', 'sc_hpf', 'sc_listen'])),
    ]);
  }
}

class _CompressorHero extends StatefulWidget {
  const _CompressorHero();

  @override
  State<_CompressorHero> createState() => _CompressorHeroState();
}

class _CompressorHeroState extends State<_CompressorHero> {
  bool? _knee; // the drag's part: the knee graph (true) or the history (false)
  double _thr = 0, _ratio = 1;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    double v(String id, double d) => t.param(id) == null ? d : t.value(id);
    final thr = v('threshold', -18), ratio = v('ratio', 4), knee = v('knee', 0), makeup = v('makeup', 0);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final side = math.min(h - 26, w * 0.48);
      final inset = Rect.fromLTWH(w - side - 10, 22, side, side);
      return HistoryRecorder(lanes: 5, pick: _levels, builder: (context, hist, f) => GrabGesture(
        key: const ValueKey('comp-hero'),
        onStart: (p, _) {
          _knee = inset.inflate(8).contains(p);
          _thr = thr;
          _ratio = ratio;
          setState(() {});
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          if (_knee == true) {
            _thr += u.delta.dx / inset.width * 60 * fine;
            // The curve follows the finger: up lifts the slope above the threshold, a lower ratio.
            _ratio = (_ratio * math.pow(2, u.delta.dy / 50 * fine)).toDouble();
            t.setLive('threshold', _thr);
            t.setLive('ratio', _ratio.clamp(1, 20));
          } else {
            _thr -= u.delta.dy / (h - 20) * 60 * fine;
            t.setLive('threshold', _thr);
          }
        },
        onEnd: () {
          t.commit();
          setState(() => _knee = null);
        },
        onDoubleTap: (_) => t.setAll({
          if (t.param('threshold') case final p?) p.id: p.defaultValue,
          if (t.param('ratio') case final p?) p.id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _CompPainter(
          hist: hist, thr: thr, ratio: ratio, knee: knee, makeup: makeup, inset: inset,
          detector: f?.values['detector_db'] ?? f?.inputDb, color: scope.accent, second: scope.secondary, active: _knee)),
      ));
    });
  }
}

class _CompPainter extends CustomPainter {
  _CompPainter({required this.hist, required this.thr, required this.ratio, required this.knee, required this.makeup,
    required this.inset, required this.detector, required this.color, required this.second, required this.active});
  final LevelHistory hist;
  final double thr, ratio, knee, makeup;
  final Rect inset;
  final double? detector;
  final Color color, second;
  final bool? active;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Rect.fromLTRB(0, 20, inset.left - 10, size.height - 4);
    paintHistory(canvas, area, hist, color);
    // The threshold across the history.
    final ty = area.bottom - dbUnit(thr) * area.height;
    final line = Paint()
      ..color = color.withValues(alpha: active == false ? 0.95 : 0.7)
      ..strokeWidth = active == false ? 2 : 1.2;
    for (var x = area.left; x < area.right; x += 8) {
      canvas.drawLine(Offset(x, ty), Offset(math.min(x + 5, area.right), ty), line);
    }
    paintHandle(canvas, Offset(area.left + 14, ty), color, active: active == false, r: 6);
    paintLabel(canvas, 'THR ${thr.toStringAsFixed(1)}', Offset(area.left + 26, ty - 10), color, size: 9, weight: FontWeight.w700);
    // The knee graph.
    canvas.drawRRect(RRect.fromRectAndRadius(inset, const Radius.circular(8)), Paint()..color = Neon.bg.withValues(alpha: 0.55));
    canvas.drawRRect(RRect.fromRectAndRadius(inset, const Radius.circular(8)), Paint()
      ..color = color.withValues(alpha: active == true ? 0.8 : 0.3)
      ..style = PaintingStyle.stroke);
    Offset pt(double inDb, double outDb) =>
        Offset(inset.left + dbUnit(inDb) * inset.width, inset.bottom - dbUnit(outDb) * inset.height);
    final faint = Paint()..color = Colors.white.withValues(alpha: 0.08);
    canvas.drawLine(pt(-60, -60), pt(0, 0), faint);
    for (final d in [-48.0, -36.0, -24.0, -12.0]) {
      canvas.drawLine(pt(d, -60), pt(d, 0), faint);
      canvas.drawLine(pt(-60, d), pt(0, d), faint);
    }
    double out(double x) => CompressorGraph.outputDb(x, thr, ratio, knee) + makeup;
    final path = Path();
    for (var i = 0; i <= 90; i++) {
      final x = -60 + 60 * i / 90;
      final p = pt(x, out(x));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(inset, const Radius.circular(8)));
    fillFade(canvas, path, inset.bottom, Size(inset.right, inset.bottom), color, alpha: 0.22);
    strokeGlow(canvas, path, color, width: 2.2);
    final tp = pt(thr, out(thr));
    canvas.drawCircle(tp, 3, Paint()..color = second);
    if (detector case final d? when d > -60) {
      final at = pt(d.clamp(-60.0, 0.0), out(d.clamp(-60.0, 0.0)));
      canvas.drawCircle(at, 10, Paint()..color = Colors.white.withValues(alpha: 0.15));
      canvas.drawCircle(at, 5, Paint()..color = Colors.white);
    }
    canvas.restore();
    paintLabel(canvas, '${ratio >= 19.95 ? '∞' : ratio.toStringAsFixed(ratio < 10 ? 1 : 0)}:1', Offset(inset.right - 6, inset.bottom - 10),
      color, size: 11, align: 1, weight: FontWeight.w800);
    paintLabel(canvas, 'in → out', Offset(inset.left + 6, inset.top + 9), Neon.dim, size: 8);
  }

  @override
  bool shouldRepaint(covariant _CompPainter o) => true;
}

/// A level history in [area]: input as a grey fill from the bottom, output as a line in [color], gain reduction as
/// a pink fill hanging from the top (24 dB full height), newest at the right.
void paintHistory(Canvas canvas, Rect area, LevelHistory hist, Color color, {bool reduction = true}) {
  final n = hist.length;
  final dx = area.width / (n - 1);
  final input = Path()..moveTo(area.right, area.bottom);
  final output = Path();
  final gr = Path()..moveTo(area.right, area.top);
  for (var age = 0; age < n; age++) {
    final x = area.right - age * dx;
    input.lineTo(x, area.bottom - dbUnit(hist.at(0, age)) * area.height);
    final oy = area.bottom - dbUnit(hist.at(1, age)) * area.height;
    age == 0 ? output.moveTo(x, oy) : output.lineTo(x, oy);
    gr.lineTo(x, area.top + (hist.at(2, age) / 24).clamp(0.0, 1.0) * area.height * 0.6);
  }
  input
    ..lineTo(area.left, area.bottom)
    ..close();
  gr
    ..lineTo(area.left, area.top)
    ..close();
  canvas.save();
  canvas.clipRect(area);
  canvas.drawPath(input, Paint()..color = Colors.white.withValues(alpha: 0.10));
  canvas.drawPath(output, Paint()
    ..color = color.withValues(alpha: 0.85)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4);
  if (reduction) {
    canvas.drawPath(gr, Paint()..color = Neon.pink.withValues(alpha: 0.45));
  }
  canvas.restore();
}

// ---------------------------------------------------------------------------------------------------------------
// Limiter

/// The limiter: its gain-reduction history with the ceiling line (drag it) over the input; drag elsewhere up and
/// down to push the input gain.
class LimiterPage extends StatelessWidget {
  const LimiterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('limiter', [
      HeroWithMeters(height: 200, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'LIMITER',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) => Text(f?.gainReductionDb == null ? '' : 'GR ${_db(f!.gainReductionDb!)}',
          style: Neon.code(size: 10, color: Neon.pink))),
        child: const _LimiterHero(),
      )),
      const KnobRow(['gain', 'ceiling', 'release'], size: 56),
      Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, children: const [
        DeviceToggle('true_peak', label: 'True peak', icon: Icons.insights),
      ])),
      const DeviceFold(child: ParamGrid(only: ['lookahead'])),
    ]);
  }
}

class _LimiterHero extends StatefulWidget {
  const _LimiterHero();

  @override
  State<_LimiterHero> createState() => _LimiterHeroState();
}

class _LimiterHeroState extends State<_LimiterHero> {
  bool? _ceiling;
  double _v = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final ceiling = t.value('ceiling'), gain = t.value('gain');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final area = Rect.fromLTRB(0, 22, w, h - 4);
      // From −24 to +3 dB: a limiter works near full scale.
      double y(double db) => area.bottom - ((db + 24) / 27).clamp(0.0, 1.0) * area.height;
      return HistoryRecorder(lanes: 5, pick: _levels, builder: (context, hist, f) => GrabGesture(
        key: const ValueKey('limiter-hero'),
        onStart: (p, _) {
          _ceiling = (p.dy - y(ceiling)).abs() < 26;
          _v = _ceiling! ? ceiling : gain;
          setState(() {});
        },
        onUpdate: (u) {
          final d = -u.delta.dy / area.height * 24 * DeviceFingers.fine;
          _v += d;
          t.setLive(_ceiling == true ? 'ceiling' : 'gain', _v);
        },
        onEnd: () {
          t.commit();
          setState(() => _ceiling = null);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['ceiling', 'gain']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: CustomPaint(size: Size(w, h), painter: _LimiterPainter(hist, area, y, ceiling, gain, scope.accent, _ceiling)),
      ));
    });
  }
}

class _LimiterPainter extends CustomPainter {
  _LimiterPainter(this.hist, this.area, this.y, this.ceiling, this.gain, this.color, this.active);
  final LevelHistory hist;
  final Rect area;
  final double Function(double db) y;
  final double ceiling, gain;
  final Color color;
  final bool? active;

  @override
  void paint(Canvas canvas, Size size) {
    final n = hist.length;
    final dx = area.width / (n - 1);
    final input = Path()..moveTo(area.right, area.bottom);
    final gr = Path()..moveTo(area.right, area.top);
    for (var age = 0; age < n; age++) {
      final x = area.right - age * dx;
      input.lineTo(x, y(hist.at(0, age)).clamp(area.top, area.bottom));
      gr.lineTo(x, area.top + (hist.at(2, age) / 12).clamp(0.0, 1.0) * area.height * 0.5);
    }
    input
      ..lineTo(area.left, area.bottom)
      ..close();
    gr
      ..lineTo(area.left, area.top)
      ..close();
    canvas.save();
    canvas.clipRect(area);
    canvas.drawPath(input, Paint()
      ..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: [color.withValues(alpha: 0.1), color.withValues(alpha: 0.45)]).createShader(area));
    canvas.drawPath(gr, Paint()..color = Neon.pink.withValues(alpha: 0.5));
    canvas.restore();
    for (final db in [-6.0, -12.0, -18.0]) {
      canvas.drawLine(Offset(0, y(db)), Offset(area.right, y(db)), Paint()..color = Colors.white.withValues(alpha: 0.05));
      paintLabel(canvas, '${db.round()}', Offset(area.right - 4, y(db) - 6), Neon.dim, size: 8, align: 1);
    }
    final cy = y(ceiling);
    canvas.drawRect(Rect.fromLTRB(0, area.top, area.right, cy), Paint()..color = Neon.pink.withValues(alpha: 0.05));
    strokeGlow(canvas, Path()
      ..moveTo(0, cy)
      ..lineTo(area.right, cy), Neon.pink, width: active == true ? 2.5 : 1.8);
    paintHandle(canvas, Offset(area.right - 26, cy), Neon.pink, active: active == true, r: 7);
    paintLabel(canvas, 'CEILING ${ceiling.toStringAsFixed(1)} dB', Offset(10, cy + 11), Neon.pink, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'GAIN +${gain.toStringAsFixed(1)} dB', Offset(10, area.bottom - 10), active == false ? Neon.text : color,
        size: 10, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _LimiterPainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Gate

/// The gate: the input level scrolling as a waveform-like band, bright while the gate is open and dimmed by the
/// range while it is closed, with the threshold as two lines (drag up and down).
class GatePage extends StatelessWidget {
  const GatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('gate', [
      HeroWithMeters(height: 190, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: 'GATE',
        grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final open = (f?.values['open'] ?? 0) >= 0.5;
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
              color: f == null ? Neon.line : (open ? Neon.green : Neon.pink),
              boxShadow: f == null ? null : Neon.glow(open ? Neon.green : Neon.pink, strength: 0.5))),
            const SizedBox(width: 5),
            Text(f == null ? '' : (open ? 'OPEN' : 'CLOSED'), style: Neon.code(size: 9, color: Neon.text)),
          ]);
        }),
        child: const _GateHero(),
      )),
      const KnobRow(['threshold', 'range', 'attack', 'hold', 'release'], size: 50),
      const DeviceFold(child: ParamGrid(only: ['ratio', 'knee', 'sc_hpf'])),
    ]);
  }
}

class _GateHero extends StatefulWidget {
  const _GateHero();

  @override
  State<_GateHero> createState() => _GateHeroState();
}

class _GateHeroState extends State<_GateHero> {
  bool _active = false;
  double _thr = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final thr = t.value('threshold'), range = t.value('range');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return HistoryRecorder(lanes: 5, pick: _levels, builder: (context, hist, f) => GrabGesture(
        key: const ValueKey('gate-hero'),
        onStart: (p, _) {
          _thr = thr;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          // Away from the centre line is louder, on either half.
          final sign = u.local.dy < h / 2 ? -1 : 1;
          _thr += sign * u.delta.dy / (h / 2 - 12) * 80 * DeviceFingers.fine;
          t.setLive('threshold', _thr);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) {
          if (t.param('threshold') case final p?) t.set(p.id, p.defaultValue);
        },
        child: CustomPaint(size: Size(w, h), painter: _GatePainter(hist, thr, range, scope.accent, scope.secondary, _active)),
      ));
    });
  }
}

class _GatePainter extends CustomPainter {
  _GatePainter(this.hist, this.thr, this.range, this.color, this.second, this.active);
  final LevelHistory hist;
  final double thr, range;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2 + 6, half = size.height / 2 - 14;
    double amp(double db) => dbUnit(db, floor: 80) * half;
    final n = hist.length;
    final dx = size.width / (n - 1);
    final closedScale = math.pow(10, range / 20).toDouble();
    for (var age = 0; age < n; age++) {
      final x = size.width - age * dx;
      final open = hist.at(3, age) >= 0.5;
      final a = amp(hist.at(0, age)) * (open ? 1 : math.max(0.08, closedScale));
      canvas.drawLine(Offset(x, mid - a), Offset(x, mid + a), Paint()
        ..color = (open ? color : Neon.dim).withValues(alpha: open ? 0.7 : 0.3)
        ..strokeWidth = math.max(1.0, dx * 0.7));
    }
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Colors.white.withValues(alpha: 0.08));
    final ta = amp(thr);
    for (final y in [mid - ta, mid + ta]) {
      strokeGlow(canvas, Path()
        ..moveTo(0, y)
        ..lineTo(size.width, y), second, width: active ? 2.4 : 1.6, glow: active);
    }
    paintHandle(canvas, Offset(22, mid - ta), second, active: active, r: 6);
    paintLabel(canvas, 'THRESHOLD ${thr.toStringAsFixed(1)} dB', Offset(34, mid - ta - 10), second, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'RANGE ${range.toStringAsFixed(0)} dB', Offset(10, size.height - 10), Neon.dim, size: 8);
  }

  @override
  bool shouldRepaint(covariant _GatePainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Transient shaper

/// The transient shaper: a drum hit's envelope as it comes in (faint) and as shaped (the attack in the family's
/// colour, the sustain in its second colour). Drag the left half up or down for attack, the right half for sustain.
class TransientPage extends StatelessWidget {
  const TransientPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return effectPage('transient', [
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'TRANSIENTS ≈',
        readout: DeviceDisplay(builder: (context, f) => Text(f?.values['gain_db'] == null ? '' : _db(f!.values['gain_db']!),
          style: Neon.code(size: 10, color: (f?.values['gain_db'] ?? 0) >= 0 ? scope.accent : Neon.pink))),
        child: const _TransientHero(),
      )),
      const KnobRow(['attack', 'sustain', 'output', 'mix'], size: 56),
    ]);
  }
}

class _TransientHero extends StatefulWidget {
  const _TransientHero();

  @override
  State<_TransientHero> createState() => _TransientHeroState();
}

class _TransientHeroState extends State<_TransientHero> {
  String? _param;
  double _v = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final attack = t.value('attack'), sustain = t.value('sustain');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return GrabGesture(
        key: const ValueKey('transient-hero'),
        onStart: (p, _) {
          _param = p.dx < w * 0.3 ? 'attack' : 'sustain';
          _v = t.value(_param!);
          setState(() {});
        },
        onUpdate: (u) {
          _v -= u.delta.dy / (h * 0.6) * DeviceFingers.fine;
          t.setLive(_param!, _v);
        },
        onEnd: () {
          t.commit();
          setState(() => _param = null);
        },
        onDoubleTap: (_) => t.setAll({'attack': 0, 'sustain': 0}),
        child: CustomPaint(size: Size(w, h), painter: _TransientPainter(attack, sustain, scope.accent, scope.secondary, _param)),
      );
    });
  }
}

class _TransientPainter extends CustomPainter {
  _TransientPainter(this.attack, this.sustain, this.color, this.second, this.active);
  final double attack, sustain;
  final Color color, second;
  final String? active;

  // A hit: 3 ms rise, a fast fall to a body that decays over 0.4 s. The shaper's gain: attack ±24 dB over the
  // first ~25 ms, sustain ±24 dB after.
  static double hit(double s) =>
      s < 0.003 ? s / 0.003 : 0.7 * math.exp(-(s - 0.003) / 0.015) + 0.3 * math.exp(-(s - 0.003) / 0.25);
  static double gain(double s, double attack, double sustain) {
    final a = math.pow(10, attack * 24 / 20).toDouble(), su = math.pow(10, sustain * 24 / 20).toDouble();
    final k = 1 / (1 + math.exp((s - 0.03) / 0.008));
    return a * k + su * (1 - k);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const span = 0.5;
    final base = size.height - 10, top = 26.0;
    double y(double v) => base - (v / 2.2).clamp(0.0, 1.0) * (base - top);
    double x(double s) => size.width * math.sqrt(s / span); // more room for the attack
    final orig = Path(), shaped = Path();
    for (var i = 0; i <= 200; i++) {
      final s = span * i / 200;
      final px = x(s);
      final o = hit(s), sh = o * gain(s, attack, sustain);
      i == 0 ? orig.moveTo(px, y(o)) : orig.lineTo(px, y(o));
      i == 0 ? shaped.moveTo(px, y(sh)) : shaped.lineTo(px, y(sh));
    }
    canvas.drawPath(orig, Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
    final split = x(0.03);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, split, size.height));
    fillFade(canvas, shaped, base, size, color, alpha: 0.35);
    strokeGlow(canvas, shaped, color, width: 2.4);
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(split, 0, size.width, size.height));
    fillFade(canvas, shaped, base, size, second, alpha: 0.3);
    strokeGlow(canvas, shaped, second, width: 2.4);
    canvas.restore();
    canvas.drawLine(Offset(split, top), Offset(split, base), Paint()..color = Colors.white.withValues(alpha: 0.1));
    paintLabel(canvas, 'ATTACK ${_pct(attack)}', Offset(8, base - 2), active == 'attack' ? Neon.text : color, size: 9,
        weight: FontWeight.w800);
    paintLabel(canvas, 'SUSTAIN ${_pct(sustain)}', Offset(size.width - 8, top + 18), active == 'sustain' ? Neon.text : second,
        size: 9, align: 1, weight: FontWeight.w800);
  }

  static String _pct(double v) => '${v > 0 ? '+' : ''}${(v * 100).round()}%';

  @override
  bool shouldRepaint(covariant _TransientPainter o) =>
      o.attack != attack || o.sustain != sustain || o.color != color || o.active != active;
}
