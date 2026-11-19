// The EQ's and Filter's 1.1.0 modes: Linear (Bands' curve with its quality and latency), Match (the reference's and input's spectra, the match curve, Learn) and the Filter's Wah (a pedal rocking the peak along its curve).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../dyn_drive/common.dart' show ChoiceChips, chipWrap, clampParam;
import '../filters/filters_shared.dart' show svfResponse, toDb;
import '../modes_kit.dart';
import '../space/space_devices.dart' show mergedPage;

// ---------------------------------------------------------------------------------------------------------------
// Linear

/// Linear's own row over Bands' page: its quality (it sets the latency) and the latency, taps and design state now.
class LinearRow extends StatelessWidget {
  const LinearRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Wrap(spacing: 12, runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center, children: [
        const ChoiceChips('lin_quality', title: 'QUALITY'),
        DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length > 458;
          final ms = live ? f.at(456) : null, taps = live ? f.at(457) : null, designing = live && f.at(458) > 0.5;
          return Row(mainAxisSize: MainAxisSize.min, children: [
            LedLight(on: designing, color: Neon.yellow, size: 9),
            const SizedBox(width: 6),
            Text(ms == null ? 'LINEAR PHASE' : '${designing ? 'DESIGNING · ' : ''}${ms.toStringAsFixed(0)} ms · ${taps!.round()} taps',
                key: const ValueKey('linear-latency'), style: Neon.code(size: 10, color: Neon.dim)),
          ]);
        }),
      ]));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Match

/// Match: the reference's spectrum (the key) and the input's, faint, and the match curve as it plays (±12 dB); the
/// low and high limits as handles dragged sideways; up and down anywhere else sets the amount. Learn takes the
/// reference, the input or both (the engine's `match_learn`); Match on, amount and smoothing below.
class MatchPage extends StatelessWidget {
  const MatchPage({super.key, required this.lead});
  final List<Widget> lead;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final hero = HeroCanvas(
      color: scope.accent,
      height: 230,
      caption: 'MATCH',
      grid: false,
      readout: Builder(builder: (context) => Text('amount ${(t.value('match_amount') * 100).round()}%')),
      child: const _MatchHero(),
    );
    final learn = t.param('match_learn');
    final sel = learn == null ? 0 : (t.value('match_learn') - learn.min).round();
    Widget learnPill(int k, String label) => LitPill(label: label, on: sel == k,
        icon: k == 0 ? Icons.stop : Icons.hearing, keyName: 'match-learn-$k', height: 34,
        onTap: () => t.set('match_learn', (learn?.min ?? 0) + (sel == k ? 0 : k)));
    final learnRow = DeviceDisplay(builder: (context, f) {
      final live = f?.raw != null && f!.raw!.length > 5;
      final secs = live ? 'REF ${f.at(1).toStringAsFixed(1)} s · IN ${f.at(2).toStringAsFixed(1)} s' : 'NOTHING LEARNED YET';
      return Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        learnPill(1, 'Learn reference'),
        learnPill(2, 'Learn input'),
        learnPill(3, 'Both'),
        if (sel != 0) learnPill(0, 'Stop'),
        Text(secs, style: Neon.code(size: 9.5, color: Neon.dim)),
      ]);
    });
    return mergedPage(context, 'eq',
      cards: lead.isEmpty ? null : Column(mainAxisSize: MainAxisSize.min, children: lead),
      hero: hero,
      rows: [learnRow, chipWrap([const DeviceToggle('match', label: 'Match', icon: Icons.compare_arrows)])],
      knobs: const KnobRow(['match_amount', 'match_smooth'], size: 52, labels: {'match_amount': 'Amount', 'match_smooth': 'Smooth'}),
      more: const KnobRow(['match_low', 'match_high'], size: 42, labels: {'match_low': 'Low limit', 'match_high': 'High limit'}),
    );
  }
}

class _MatchHero extends StatefulWidget {
  const _MatchHero();

  @override
  State<_MatchHero> createState() => _MatchHeroState();
}

class _MatchHeroState extends State<_MatchHero> {
  String? _grip;
  double _u = 0, _amount = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final plot = Rect.fromLTRB(10, 24, w - 10, h - 8);
      double xOf(double hz) => plot.left + logUnit(hz) * plot.width;
      String? near(Offset p) {
        for (final id in ['match_low', 'match_high']) {
          if ((xOf(t.value(id)) - p.dx).abs() < 22) return id;
        }
        return null;
      }
      return DeviceDisplay(builder: (context, f) {
        final live = f?.raw != null && f!.raw!.length >= 366;
        final n = live ? f.at(3).round().clamp(2, 120) : 0;
        List<double>? lane(int from) => live ? [for (var i = 0; i < n; i++) f.at(from + i)] : null;
        return GrabGesture(
          key: const ValueKey('match-hero'),
          onStart: (p, _) {
            _grip = near(p) ?? 'amount';
            _u = _grip == 'amount' ? 0 : logUnit(t.value(_grip!));
            _amount = t.value('match_amount');
            DeviceFeel.grab();
            setState(() {});
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            if (_grip == 'amount') {
              _amount = (_amount - u.delta.dy / plot.height * fine).clamp(0.0, 1.0);
              t.setLive('match_amount', _amount);
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
          child: CustomPaint(size: Size(w, h), painter: _MatchPainter(
            plot: plot,
            lo: live ? f.at(4, 20) : 20,
            hi: live ? f.at(5, 20000) : 20000,
            reference: lane(6),
            input: lane(126),
            curve: lane(246),
            limits: (t.value('match_low'), t.value('match_high')),
            on: t.value('match') >= 0.5 || (t.param('match') == null),
            grip: _grip,
            color: scope.accent,
            second: scope.secondary)),
        );
      });
    });
  }
}

class _MatchPainter extends CustomPainter {
  _MatchPainter({required this.plot, required this.lo, required this.hi, required this.reference, required this.input,
    required this.curve, required this.limits, required this.on, required this.grip, required this.color, required this.second});
  final Rect plot;
  final double lo, hi;
  final List<double>? reference, input, curve;
  final (double, double) limits;
  final bool on;
  final String? grip;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    paintLogGrid(canvas, plot);
    final mid = plot.center.dy;
    canvas.drawLine(Offset(plot.left, mid), Offset(plot.right, mid), Paint()..color = Neon.ink.withValues(alpha: 0.15));
    double x(int i, int n) => plot.left + logUnit(lo * math.pow(hi / lo, i / (n - 1)).toDouble()) * plot.width;
    // The spectra (dB, −90..0) in the lower part, reference in the second colour, input faint.
    void spectrum(List<double> v, Color c, double alpha) {
      final path = Path();
      for (var i = 0; i < v.length; i++) {
        final y = plot.bottom - dbUnit(v[i], floor: 90) * plot.height * 0.9;
        i == 0 ? path.moveTo(x(i, v.length), y) : path.lineTo(x(i, v.length), y);
      }
      canvas.drawPath(path, Paint()
        ..color = c.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3);
    }
    if (input case final v?) spectrum(v, Neon.ink, 0.35);
    if (reference case final v?) spectrum(v, second, 0.7);
    // Outside the limits: shaded.
    final (l, h) = limits;
    final shade = Paint()..color = Neon.bg.withValues(alpha: 0.45);
    canvas.drawRect(Rect.fromLTRB(plot.left, plot.top, plot.left + logUnit(l) * plot.width, plot.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(plot.left + logUnit(h) * plot.width, plot.top, plot.right, plot.bottom), shade);
    // The match curve, ±12 dB.
    final path = Path();
    final v = curve;
    if (v != null && v.isNotEmpty) {
      for (var i = 0; i < v.length; i++) {
        final y = mid - (v[i] / 12).clamp(-1.0, 1.0) * plot.height * 0.42;
        i == 0 ? path.moveTo(x(i, v.length), y) : path.lineTo(x(i, v.length), y);
      }
    } else {
      path
        ..moveTo(plot.left, mid)
        ..lineTo(plot.right, mid);
    }
    strokeGlow(canvas, path, on ? color : Neon.dim, width: grip == 'amount' ? 2.8 : 2.2);
    for (final (id, hz) in [('match_low', l), ('match_high', h)]) {
      final px = plot.left + logUnit(hz) * plot.width;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), Paint()..color = Neon.text.withValues(alpha: 0.35));
      paintHandle(canvas, Offset(px, plot.top + 14), Neon.text, active: grip == id, r: 6);
      paintLabel(canvas, hzLabel(hz), Offset(px + (id == 'match_low' ? 9 : -9), plot.top + 30), Neon.dim, size: 8,
          align: id == 'match_low' ? -1 : 1);
    }
    paintLabel(canvas, '+12', Offset(plot.right - 2, mid - plot.height * 0.42), Neon.dim, size: 7.5, align: 1);
    paintLabel(canvas, '−12', Offset(plot.right - 2, mid + plot.height * 0.42), Neon.dim, size: 7.5, align: 1);
    if (reference == null) {
      paintLabel(canvas, 'Learn a reference (the key) and the input', Offset(plot.center.dx, mid + 22), Neon.dim, size: 9, align: 0);
    } else {
      paintLabel(canvas, 'REFERENCE', Offset(plot.center.dx - 6, plot.top + 6), second, size: 8, align: 1, weight: FontWeight.w700);
      paintLabel(canvas, 'INPUT', Offset(plot.center.dx + 6, plot.top + 6), Neon.dim, size: 8, weight: FontWeight.w700);
    }
  }

  @override
  bool shouldRepaint(covariant _MatchPainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Wah

/// Each wah curve's sweep (heel to toe Hz) and Q (heel, toe): C.A.W's own (builtin_fx_filters_wah.cpp).
const wahCurves = [(400.0, 2200.0, 4.0, 7.0), (450.0, 1700.0, 6.0, 9.0), (150.0, 1100.0, 3.0, 5.0), (250.0, 4000.0, 2.5, 5.0)];

/// Where a wah's peak sits at [position] 0..1 (heel to toe) on [curve]: its frequency and Q, [resonance] 0..1
/// scaling Q by 0.5..1.5.
(double, double) wahPeak(int curve, double position, double resonance) {
  final (lo, hi, q0, q1) = wahCurves[curve.clamp(0, 3)];
  final p = position.clamp(0.0, 1.0);
  return (lo * math.pow(hi / lo, p).toDouble(), (q0 + (q1 - q0) * p) * (0.5 + resonance.clamp(0.0, 1.0)));
}

/// The Wah: the strip of models (its curves as a group), the treadle rocking heel to toe beside the band-pass peak
/// it moves (drag up and down: the pedal in Pedal mode, the sensitivity in Envelope; sideways the resonance), the
/// level the envelope follows, then its knobs.
class WahPage extends StatelessWidget {
  const WahPage({super.key, required this.strip});
  final Widget? strip;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final pedal = t.value('mode').round() == 1;
    final hero = HeroCanvas(
      color: scope.accent,
      height: 220,
      caption: pedal ? 'WAH · PEDAL' : 'WAH · ENVELOPE',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final hz = f?.raw != null && f!.at(2) > 0 ? f.at(2)
            : wahPeak(t.value('curve').round(), t.value('pedal'), t.value('resonance')).$1;
        return Text('${hz.round()} Hz');
      }),
      child: const _WahHero(),
    );
    return mergedPage(context, 'filter',
      cards: strip,
      hero: hero,
      rows: [chipWrap([const ChoiceChips('mode', title: 'MODE'), const ChoiceChips('direction', title: 'SWEEP')])],
      knobs: KnobRow(pedal ? const ['pedal', 'range', 'resonance'] : const ['sensitivity', 'attack', 'release', 'range', 'resonance'],
          size: 50),
    );
  }
}

class _WahHero extends StatefulWidget {
  const _WahHero();

  @override
  State<_WahHero> createState() => _WahHeroState();
}

class _WahHeroState extends State<_WahHero> {
  bool _active = false;
  double _y = 0, _res = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final pedal = t.value('mode').round() == 1;
    final yId = pedal ? 'pedal' : 'sensitivity';
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) {
        final live = f?.raw != null && f!.raw!.length >= 9;
        final pos = live ? f.at(3) : (pedal ? t.value('pedal') : 0.3);
        return GrabGesture(
          key: const ValueKey('wah-hero'),
          onStart: (_, _) {
            _y = t.value(yId);
            _res = t.value('resonance');
            DeviceFeel.grab();
            setState(() => _active = true);
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            _y = travelBy(scope, yId, _y, -u.delta.dy / (h * 0.8) * fine);
            _res = travelBy(scope, 'resonance', _res, u.delta.dx / w * fine);
            t.setLive(yId, _y);
            t.setLive('resonance', _res);
          },
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() => _active = false);
          },
          onDoubleTap: (_) => t.setAll({for (final id in [yId, 'resonance']) if (t.param(id) case final p?) id: p.defaultValue}),
          child: CustomPaint(size: Size(w, h), painter: _WahPainter(
            curve: t.value('curve').round(),
            position: pos,
            resonance: t.value('resonance'),
            level: live && !pedal ? f.at(4, -120) : null,
            sensitivity: t.value('sensitivity'),
            color: scope.accent,
            second: scope.secondary,
            active: _active)),
        );
      });
    });
  }
}

class _WahPainter extends CustomPainter {
  _WahPainter({required this.curve, required this.position, required this.resonance, required this.level,
    required this.sensitivity, required this.color, required this.second, required this.active});
  final int curve;
  final double position, resonance, sensitivity;
  final double? level;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    // The treadle on the left: a pedal seen from the side, tilted heel (up) to toe (down) by the position.
    final pw = math.min(size.width * 0.3, 150.0);
    final base = Offset(14 + pw / 2, size.height - 40);
    final angle = (0.5 - position) * 0.6; // toe down
    canvas.drawPath(Path()
      ..moveTo(base.dx - pw / 2, base.dy + 22)
      ..lineTo(base.dx - pw / 2 + 6, base.dy + 4)
      ..lineTo(base.dx + pw / 2 - 6, base.dy + 4)
      ..lineTo(base.dx + pw / 2, base.dy + 22)
      ..close(), Paint()..color = Neon.ink.withValues(alpha: 0.18));
    canvas.save();
    canvas.translate(base.dx, base.dy - 6);
    canvas.rotate(angle);
    final plate = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: pw, height: 22), const Radius.circular(7));
    canvas.drawRRect(plate, Paint()..color = color.withValues(alpha: active ? 0.75 : 0.55));
    for (var k = -3; k <= 3; k++) {
      canvas.drawLine(Offset(k * pw / 8, -7), Offset(k * pw / 8, 7), Paint()
        ..color = Neon.bg.withValues(alpha: 0.5)
        ..strokeWidth = 1.5);
    }
    canvas.restore();
    canvas.drawCircle(base + Offset(0, -2), 4, Paint()..color = Neon.text);
    paintLabel(canvas, 'HEEL', Offset(base.dx - pw / 2, size.height - 8), Neon.dim, size: 7.5);
    paintLabel(canvas, 'TOE', Offset(base.dx + pw / 2, size.height - 8), Neon.dim, size: 7.5, align: 1);
    // The envelope's level against the sensitivity.
    if (level case final l?) {
      final bar = Rect.fromLTWH(14, 30, pw, 6);
      canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(3)), Paint()..color = Neon.ink.withValues(alpha: 0.1));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bar.left, bar.top, bar.width * dbUnit(l, floor: 60), bar.height),
          const Radius.circular(3)), Paint()..color = second.withValues(alpha: 0.85));
      paintLabel(canvas, 'LEVEL', Offset(bar.left, bar.bottom + 8), Neon.dim, size: 7.5);
    }
    // The response: a band-pass peak on a log grid, 80 Hz..8 kHz, its sweep's span marked.
    final r = Rect.fromLTRB(14 + pw + 18, 26, size.width - 10, size.height - 10);
    if (r.width < 60) return;
    const lo = 80.0, hi = 8000.0;
    paintLogGrid(canvas, r, lo: lo, hi: hi);
    final (a, b, _, _) = wahCurves[curve.clamp(0, 3)];
    final span = Rect.fromLTRB(r.left + logUnit(a, lo: lo, hi: hi) * r.width, r.bottom - 6, r.left + logUnit(b, lo: lo, hi: hi) * r.width, r.bottom - 2);
    canvas.drawRRect(RRect.fromRectAndRadius(span, const Radius.circular(2)), Paint()..color = second.withValues(alpha: 0.4));
    final (f0, q) = wahPeak(curve, position, resonance);
    double y(double db) => r.top + (1 - ((db + 30) / 54).clamp(0.0, 1.0)) * r.height;
    final path = Path();
    const n = 140;
    for (var i = 0; i <= n; i++) {
      final hz = logHz(i / n, lo: lo, hi: hi);
      final db = toDb(svfResponse(hz, cutoff: f0, q: q, type: 1).abs) + 20 * math.log(q) / math.ln10 * 0.5;
      final p = Offset(r.left + r.width * i / n, y(db));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    fillFade(canvas, Path.from(path)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..close(), r.bottom, size, color);
    strokeGlow(canvas, path, color, width: active ? 2.6 : 2);
    final px = r.left + logUnit(f0, lo: lo, hi: hi) * r.width;
    final peakDb = 20 * math.log(q) / math.ln10 * 0.5;
    paintHandle(canvas, Offset(px, y(peakDb)), Neon.text, active: active, r: 7);
  }

  @override
  bool shouldRepaint(covariant _WahPainter o) => true;
}

/// The Wah's model icons: its band-pass peak at each curve's middle.
void wahIcon(Canvas canvas, Rect r, int k, Color c) {
  final (f0, q) = wahPeak(k, 0.5, 0.5);
  iconCurve(canvas, r, c, (x) {
    final hz = 1000 * math.pow(2, x * 4).toDouble();
    return ((toDb(svfResponse(hz, cutoff: f0, q: q, type: 1).abs) + 10) / 14).clamp(-1.0, 1.0);
  }, width: 1.5);
}
