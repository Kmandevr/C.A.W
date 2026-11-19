// The Gate's Pedal gate and the Ducker's Level and Carve (1.1.0): a pedal's open/closed light with the key level across its threshold and a trace of the cuts; Level's loudness ride on a transfer curve and trace; Carve's dips across the spectrum.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/param_watch.dart';
import '../effect_page.dart';
import '../modes_kit.dart';
import 'common.dart';

// ---------------------------------------------------------------------------------------------------------------
// Pedal gate

/// The Pedal gate: a big pedal-like light (open or shut, the engine's), the key's level moving across the threshold
/// (drag the bar for the threshold; the close point trails it by the hysteresis) and a scrolling trace that shows
/// where it cut; threshold and decay (release) as big knobs.
class PedalGatePage extends StatelessWidget {
  const PedalGatePage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final inline = DeviceScope.isInline(context);
    final hero = HeroCanvas(color: scope.accent, height: 190, caption: 'PEDAL GATE', grid: false,
        readout: DeviceDisplay(builder: (context, f) => Text('GR ${(-(f?.gainReductionDb ?? 0)).toStringAsFixed(1)} dB',
            style: Neon.code(size: 10, color: Neon.yellow))),
        child: const _GateHero());
    if (inline) return effectPage('compressor', [cards, hero, const _ThresholdBar(), const KnobRow(['threshold', 'release'], size: 44)]);
    return effectPage('compressor', [
      cards,
      hero,
      const _ThresholdBar(),
      const KnobRow(['threshold', 'release'], size: 64, labels: {'release': 'Decay'}),
      const KnobRow(['hysteresis', 'attack', 'hold', 'range', 'tracking'], size: 42, labels: {'tracking': 'Tracking'}),
      chipWrap([const ChoiceChips('sidechain', title: 'KEY', labels: ['Self', 'Key'])]),
      const DeviceFold(child: ParamGrid(only: ['sc_hpf'])),
    ]);
  }
}

class _GateHero extends StatelessWidget {
  const _GateHero();

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return HistoryRecorder(lanes: 2, length: 120, pick: (f) => [f.values['detector_db'] ?? -120, f.values['open'] ?? 0],
        builder: (context, hist, f) {
      final open = (f?.values['open'] ?? 0) >= 0.5;
      return Row(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 24, 10, 12), child: _BigLight(open: open, color: scope.accent)),
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(0, 26, 10, 10), child: CustomPaint(size: Size.infinite,
          painter: _CutTrace(hist: hist, threshold: t.value('threshold'), close: t.value('threshold') - t.value('hysteresis'),
              color: scope.accent)))),
      ]);
    });
  }
}

/// A pedal's big lamp in a bezel: lit when the gate is open, dark when it cuts.
class _BigLight extends StatelessWidget {
  const _BigLight({required this.open, required this.color});
  final bool open;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Container(
      key: const ValueKey('gate-light'),
      width: 84,
      height: 84,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(shape: BoxShape.circle, color: Neon.ink.withValues(alpha: 0.08),
          border: Border.all(color: Neon.ink.withValues(alpha: 0.3), width: 3)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: open
              ? [Color.lerp(Neon.green, Colors.white, 0.5)!, Neon.green, Neon.green.withValues(alpha: 0.6)]
              : [redColor().withValues(alpha: 0.5), redColor().withValues(alpha: 0.25), redColor().withValues(alpha: 0.12)]),
          boxShadow: open ? [BoxShadow(color: Neon.green.withValues(alpha: 0.7), blurRadius: 26, spreadRadius: 3)] : null,
        ),
      ),
    ),
    const SizedBox(height: 8),
    Text(open ? 'OPEN' : 'SHUT', style: TextStyle(fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.w900,
        color: open ? Neon.green : Neon.dim)),
  ]);
}

class _CutTrace extends CustomPainter {
  _CutTrace({required this.hist, required this.threshold, required this.close, required this.color});
  final LevelHistory hist;
  final double threshold, close;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const floor = 90.0;
    double y(double db) => size.height * (1 - dbUnit(db, floor: floor));
    final n = hist.length;
    final dx = size.width / (n - 1);
    // Where it cut: shaded red columns.
    for (var age = 0; age < n; age++) {
      if (hist.at(1, age) < 0.5 && hist.at(0, age) > -119) {  // -120: before any frame
        final x = size.width - age * dx;
        canvas.drawRect(Rect.fromLTWH(x - dx / 2, 0, dx + 0.5, size.height), Paint()..color = redColor().withValues(alpha: 0.16));
      }
    }
    final path = Path();
    for (var age = 0; age < n; age++) {
      final p = Offset(size.width - age * dx, y(hist.at(0, age)));
      age == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    strokeGlow(canvas, path, Neon.text.withValues(alpha: 0.85), width: 1.4, glow: false);
    for (final (db, label, c) in [(threshold, 'OPEN', color), (close, 'CLOSE', color.withValues(alpha: 0.5))]) {
      canvas.drawLine(Offset(0, y(db)), Offset(size.width, y(db)), Paint()
        ..color = c
        ..strokeWidth = 1.2);
      paintLabel(canvas, '$label ${db.toStringAsFixed(0)}', Offset(2, y(db) - 7), c, size: 8, weight: FontWeight.w700);
    }
  }

  @override
  bool shouldRepaint(covariant _CutTrace o) => true;
}

/// The key's level as a bar (−90..0 dB) with the open threshold and the close point on it; drag it sideways for the
/// threshold.
class _ThresholdBar extends StatefulWidget {
  const _ThresholdBar();

  @override
  State<_ThresholdBar> createState() => _ThresholdBarState();
}

class _ThresholdBarState extends State<_ThresholdBar> {
  double _thr = 0;
  bool _active = false;

  // Its own watch: the threshold it draws rebuilds it alone.
  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) => GrabGesture(
      key: const ValueKey('gate-threshold-bar'),
      onStart: (_, _) {
        _thr = t.value('threshold');
        DeviceFeel.grab();
        setState(() => _active = true);
      },
      onUpdate: (u) {
        _thr = clampParam(scope, 'threshold', _thr + u.delta.dx / box.maxWidth * 90 * DeviceFingers.fine);
        t.setLive('threshold', _thr);
      },
      onEnd: () {
        t.commit();
        DeviceFeel.release();
        setState(() => _active = false);
      },
      onDoubleTap: (_) => t.set('threshold', t.param('threshold')?.defaultValue ?? -50),
      child: SizedBox(height: 40, child: DeviceDisplay(builder: (context, f) => CustomPaint(size: Size(box.maxWidth, 40),
          painter: _BarPainter(level: f?.values['detector_db'], threshold: t.value('threshold'),
              close: t.value('threshold') - t.value('hysteresis'), open: (f?.values['open'] ?? 0) >= 0.5,
              color: scope.accent, active: _active)))),
    ));
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.level, required this.threshold, required this.close, required this.open, required this.color,
    required this.active});
  final double? level;
  final double threshold, close;
  final bool open, active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bar = Rect.fromLTWH(0, 14, size.width, 12);
    double x(double db) => bar.left + dbUnit(db, floor: 90) * bar.width;
    canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(6)), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    canvas.drawRect(Rect.fromLTRB(x(close), bar.top, x(threshold), bar.bottom), Paint()..color = color.withValues(alpha: 0.18));
    if (level case final l?) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(bar.left, bar.top + 2, x(l), bar.bottom - 2), const Radius.circular(4)),
          Paint()..color = (open ? Neon.green : Neon.dim).withValues(alpha: 0.85));
    }
    canvas.drawLine(Offset(x(threshold), bar.top - 4), Offset(x(threshold), bar.bottom + 4), Paint()
      ..color = color
      ..strokeWidth = active ? 3 : 2);
    paintHandle(canvas, Offset(x(threshold), bar.center.dy), color, active: active, r: 7);
    paintLabel(canvas, 'THRESHOLD ${threshold.toStringAsFixed(1)} dB', Offset(0, 5), Neon.dim, size: 8);
    paintLabel(canvas, '0', Offset(size.width, 5), Neon.dim, size: 8, align: 1);
  }

  @override
  bool shouldRepaint(covariant _BarPainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Level

/// Level: a scrolling trace of the momentary loudness with the target across it and the ride (boost up, cut down)
/// in yellow, beside the transfer curve in LUFS (pulled toward the target within the boost and cut, still under the
/// gate); up and down anywhere moves the target.
class LevelPage extends StatelessWidget {
  const LevelPage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final inline = DeviceScope.isInline(context);
    final hero = HeroCanvas(color: scope.accent, height: 210, caption: 'LEVEL', grid: false,
        readout: DeviceDisplay(builder: (context, f) {
          final ride = f?.values['ride'] ?? 0;
          return Text('RIDE ${ride >= 0 ? '+' : ''}${ride.toStringAsFixed(1)} dB', style: Neon.code(size: 10, color: Neon.yellow));
        }),
        child: const _LevelHero());
    if (inline) return effectPage('compressor', [cards, hero, const KnobRow(['target', 'max_boost', 'max_cut'], size: 44)]);
    return effectPage('compressor', [
      cards,
      hero,
      const KnobRow(['target', 'speed'], size: 60),
      const KnobRow(['max_boost', 'max_cut', 'gate'], size: 46, labels: {'max_boost': 'Max boost', 'max_cut': 'Max cut'}),
      chipWrap([const ChoiceChips('lookahead', title: 'LOOK-AHEAD')]),
    ]);
  }
}

class _LevelHero extends StatefulWidget {
  const _LevelHero();

  @override
  State<_LevelHero> createState() => _LevelHeroState();
}

class _LevelHeroState extends State<_LevelHero> {
  double _target = 0;
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return HistoryRecorder(lanes: 2, pick: (f) => [f.values['lufs'] ?? -120, f.values['ride'] ?? 0], builder: (context, hist, f) =>
        GrabGesture(
          key: const ValueKey('level-hero'),
          onStart: (_, _) {
            _target = t.value('target');
            DeviceFeel.grab();
            setState(() => _active = true);
          },
          onUpdate: (u) {
            _target = clampParam(scope, 'target', _target - u.delta.dy / (h - 30) * 60 * DeviceFingers.fine);
            t.setLive('target', _target);
          },
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() => _active = false);
          },
          onDoubleTap: (_) => t.set('target', t.param('target')?.defaultValue ?? -18),
          child: CustomPaint(size: Size(w, h), painter: _LevelPainter(
            hist: hist,
            target: t.value('target'),
            boost: t.value('max_boost'),
            cut: t.value('max_cut'),
            gate: t.value('gate'),
            now: f?.values['lufs'],
            riding: (f?.values['riding'] ?? 1) >= 0.5,
            color: scope.accent,
            active: _active)),
        ));
    });
  }
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({required this.hist, required this.target, required this.boost, required this.cut, required this.gate,
    required this.now, required this.riding, required this.color, required this.active});
  final LevelHistory hist;
  final double target, boost, cut, gate;
  final double? now;
  final bool riding, active;
  final Color color;

  static const _floor = -60.0;

  @override
  void paint(Canvas canvas, Size size) {
    final pw = math.min(size.width * 0.4, size.height - 30);
    final plot = Rect.fromLTWH(size.width - pw - 10, 24, pw, size.height - 34);
    final trace = Rect.fromLTRB(10, 24, plot.left - 12, size.height - 10);
    double ty(double lufs) => trace.bottom - ((lufs - _floor) / -_floor).clamp(0.0, 1.0) * trace.height;
    // The trace: loudness in white, the target across, the ride as yellow from the target.
    if (trace.width > 30) {
      final n = hist.length;
      final dx = trace.width / (n - 1);
      for (var age = 0; age < n; age++) {
        final ride = hist.at(1, age);
        if (ride.abs() < 0.05 || hist.at(0, age) <= -119) continue;  // nothing yet (the history's fill)
        final x = trace.right - age * dx;
        final a = ty(target), b = ty(target + ride);
        canvas.drawRect(Rect.fromLTRB(x - dx / 2, math.min(a, b), x + dx / 2 + 0.5, math.max(a, b)),
            Paint()..color = Neon.yellow.withValues(alpha: ride > 0 ? 0.45 : 0.3));
      }
      final path = Path();
      for (var age = 0; age < n; age++) {
        final p = Offset(trace.right - age * dx, ty(hist.at(0, age)));
        age == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      strokeGlow(canvas, path, Neon.text.withValues(alpha: 0.8), width: 1.3, glow: false);
      canvas.drawLine(Offset(trace.left, ty(target)), Offset(trace.right, ty(target)), Paint()
        ..color = color
        ..strokeWidth = active ? 2.4 : 1.6);
      canvas.drawLine(Offset(trace.left, ty(gate)), Offset(trace.right, ty(gate)), Paint()..color = Neon.dim.withValues(alpha: 0.4));
      paintLabel(canvas, 'TARGET ${target.toStringAsFixed(0)} LUFS', Offset(trace.left + 2, ty(target) - 8), color, size: 8,
          weight: FontWeight.w700);
      paintLabel(canvas, 'GATE', Offset(trace.left + 2, ty(gate) - 7), Neon.dim, size: 7.5);
      if (!riding) paintLabel(canvas, 'HELD', Offset(trace.right, trace.top + 4), Neon.dim, size: 8, align: 1, weight: FontWeight.w700);
    }
    // The curve: in LUFS to out LUFS.
    double px(double l) => plot.left + ((l - _floor) / -_floor).clamp(0.0, 1.0) * plot.width;
    double py(double l) => plot.bottom - ((l - _floor) / -_floor).clamp(0.0, 1.0) * plot.height;
    canvas.drawRect(plot, Paint()
      ..color = Neon.ink.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke);
    canvas.drawLine(Offset(px(_floor), py(_floor)), Offset(px(0), py(0)), Paint()..color = Neon.ink.withValues(alpha: 0.12));
    double out(double l) => l < gate ? l : l + (target - l).clamp(-cut, boost);
    final path = Path();
    for (var i = 0; i <= 120; i++) {
      final l = _floor - _floor * i / 120;
      final p = Offset(px(l), py(out(l)));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.save();
    canvas.clipRect(plot.inflate(2));
    strokeGlow(canvas, path, color, width: active ? 2.6 : 2);
    canvas.restore();
    paintHandle(canvas, Offset(px(target), py(target)), color, active: active, r: 6);
    if (now case final l? when l > _floor) {
      canvas.drawCircle(Offset(px(l), py(out(l))), 4, Paint()..color = Neon.text);
    }
    paintLabel(canvas, 'IN → OUT', Offset(plot.left, plot.top - 8), Neon.dim, size: 7.5);
  }

  @override
  bool shouldRepaint(covariant _LevelPainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Carve

/// Carve: across the spectrum, the dip each band makes now where the key is loud (the engine's, per band; side 1
/// faint in Stereo or Mid/Side), inside the window (its low and high edges as handles), and the key's level; up and
/// down elsewhere sets the amount.
class CarvePage extends StatelessWidget {
  const CarvePage({super.key, required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final inline = DeviceScope.isInline(context);
    final hero = HeroCanvas(color: scope.accent, height: 210, caption: 'CARVE', grid: false,
        readout: Builder(builder: (context) => Text('amount ${(scope.target.value('amount') * 100).round()}%')),
        child: const _CarveHero());
    if (inline) return effectPage('compressor', [cards, hero, const KnobRow(['amount', 'range', 'threshold'], size: 44)]);
    return effectPage('compressor', [
      cards,
      hero,
      const KnobRow(['amount', 'range', 'threshold'], size: 54),
      const KnobRow(['attack', 'release'], size: 42),
      chipWrap([
        const ChoiceChips('bands', title: 'BANDS'),
        const ChoiceChips('stereo', title: 'STEREO'),
        const DeviceToggle('listen', label: 'Listen', icon: Icons.hearing),
      ]),
      const DeviceFold(child: KnobRow(['low', 'high'], size: 42, labels: {'low': 'Low edge', 'high': 'High edge'})),
    ]);
  }
}

class _CarveHero extends StatefulWidget {
  const _CarveHero();

  @override
  State<_CarveHero> createState() => _CarveHeroState();
}

class _CarveHeroState extends State<_CarveHero> {
  String? _grip;
  double _u = 0, _amount = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final plot = Rect.fromLTRB(28, 26, w - 10, h - 10);
      double xOf(double hz) => plot.left + logUnit(hz) * plot.width;
      return DeviceDisplay(builder: (context, f) {
        final live = f?.raw != null && f!.at(3) >= 1;
        final n = live ? f.at(3).round() : 0;
        final bands = [for (var k = 0; k < n && 5 + 3 * k + 2 < f!.raw!.length; k++) (f.at(5 + 3 * k), f.at(6 + 3 * k), f.at(7 + 3 * k))];
        return GrabGesture(
          key: const ValueKey('carve-hero'),
          onStart: (p, _) {
            _grip = null;
            for (final id in ['low', 'high']) {
              if ((xOf(t.value(id)) - p.dx).abs() < 22) _grip = id;
            }
            _grip ??= 'amount';
            _u = _grip == 'amount' ? 0 : logUnit(t.value(_grip!));
            _amount = t.value('amount');
            DeviceFeel.grab();
            setState(() {});
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            if (_grip == 'amount') {
              _amount = (_amount - u.delta.dy / plot.height * fine).clamp(0.0, 1.0);
              t.setLive('amount', _amount);
            } else if (_grip case final id?) {
              _u = (_u + u.delta.dx / plot.width * fine).clamp(0.0, 1.0);
              t.setLive(id, clampParam(scope, id, logHz(_u)));
            }
          },
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() => _grip = null);
          },
          child: CustomPaint(size: Size(w, h), painter: _CarvePainter(
            plot: plot,
            bands: bands,
            window: (t.value('low'), t.value('high')),
            range: t.value('range'),
            amount: t.value('amount'),
            key: live ? f.at(2, -120) : null,
            twoSides: t.value('stereo').round() > 0,
            grip: _grip,
            color: scope.accent,
            second: scope.secondary)),
        );
      });
    });
  }
}

class _CarvePainter extends CustomPainter {
  _CarvePainter({required this.plot, required this.bands, required this.window, required this.range, required this.amount,
    required this.key, required this.twoSides, required this.grip, required this.color, required this.second});
  final Rect plot;
  final List<(double, double, double)> bands;
  final (double, double) window;
  final double range, amount;
  final double? key;
  final bool twoSides;
  final String? grip;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    paintLogGrid(canvas, plot);
    // The key's level on the left.
    final meter = Rect.fromLTWH(8, plot.top, 8, plot.height);
    canvas.drawRRect(RRect.fromRectAndRadius(meter, const Radius.circular(4)), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    if (key case final k?) {
      final hgt = dbUnit(k, floor: 80) * meter.height;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(meter.left, meter.bottom - hgt, meter.width, hgt), const Radius.circular(4)),
          Paint()..color = second.withValues(alpha: 0.85));
    }
    paintLabel(canvas, 'KEY', Offset(meter.left - 2, plot.top - 9), Neon.dim, size: 7.5);
    final top = plot.top + 14;
    final depth = math.max(3.0, range);
    double y(double db) => top + (-db / depth).clamp(0.0, 1.0) * (plot.bottom - top - 4);
    canvas.drawLine(Offset(plot.left, top), Offset(plot.right, top), Paint()..color = Neon.ink.withValues(alpha: 0.18));
    // Outside the window: shaded.
    final (lo, hi) = window;
    final shade = Paint()..color = Neon.bg.withValues(alpha: 0.45);
    canvas.drawRect(Rect.fromLTRB(plot.left, plot.top, plot.left + logUnit(lo) * plot.width, plot.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(plot.left + logUnit(hi) * plot.width, plot.top, plot.right, plot.bottom), shade);
    // The dips, a smooth line through the bands' centres (side 0 bold, side 1 faint), or the most it can dip, dashed.
    Path line(double Function((double, double, double) b) dip) {
      final p = Path()..moveTo(plot.left, top);
      for (final b in bands) {
        p.lineTo(plot.left + logUnit(b.$1) * plot.width, y(dip(b)));
      }
      p.lineTo(plot.right, top);
      return p;
    }
    if (bands.isNotEmpty) {
      final main = line((b) => b.$2);
      fillFade(canvas, Path.from(main)..close(), top, size, color, alpha: 0.22);
      strokeGlow(canvas, main, color, width: grip == 'amount' ? 2.6 : 2);
      if (twoSides) strokeGlow(canvas, line((b) => b.$3), second.withValues(alpha: 0.6), width: 1.3, glow: false);
    }
    final most = y(-range * amount);
    for (var x = plot.left + logUnit(lo) * plot.width; x < plot.left + logUnit(hi) * plot.width; x += 8) {
      canvas.drawLine(Offset(x, most), Offset(x + 4, most), Paint()..color = color.withValues(alpha: 0.45));
    }
    paintLabel(canvas, '−${(range * amount).toStringAsFixed(1)} dB', Offset(plot.right - 4, most + 8), color, size: 8, align: 1);
    for (final (id, hz) in [('low', lo), ('high', hi)]) {
      final px = plot.left + logUnit(hz) * plot.width;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), Paint()..color = Neon.text.withValues(alpha: 0.35));
      paintHandle(canvas, Offset(px, plot.top + 4), Neon.text, active: grip == id, r: 6);
    }
    if (bands.isEmpty) paintLabel(canvas, 'Route a key: its loud bands dip here', plot.center, Neon.dim, size: 9, align: 0);
  }

  @override
  bool shouldRepaint(covariant _CarvePainter o) => true;
}
