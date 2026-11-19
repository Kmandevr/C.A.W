// The 1.1.0 tools' pages: Meters (Analyzer, Tuner, Loudness as cards), Lo-fi (a waveform aged by its sections) and Phase align (the key's and this track's waveforms, offset and polarity, Learn).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme.dart';
import '../../device_registry.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/device_style.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../dyn_drive/common.dart' show ChoiceChips, chipWrap, clampParam;
import '../effect_page.dart';
import '../eqfilter/variant_cards.dart' show VariantCards, variantOf;
import '../modes_kit.dart';
import '../space/space_devices.dart' show mergedPage;

/// The tools' pages by id (effect_editors.dart merges them in). Meters keys its section by the variant, so a new
/// meter builds afresh.
final Map<String, DeviceEditorEntry> toolsEditors = {
  'org.caw.meters': DeviceEditorEntry((t) => [DeviceSection('meters-${t.info?.variantIndex ?? 0}', 'METERS', Icons.speed,
      (_) => const MetersPage())], family: DeviceFamily.utility, ownsVariant: true),
  'org.caw.lofi': singlePage('lofi', 'LO-FI', Icons.album_outlined, DeviceFamily.creative, () => const LofiPage()),
  'org.caw.phasealign': singlePage('phasealign', 'ALIGN', Icons.compare_arrows, DeviceFamily.utility, () => const PhaseAlignPage()),
};

// ---------------------------------------------------------------------------------------------------------------
// Meters

void _meterIcon(Canvas canvas, Rect r, int i, Color c) {
  switch (i) {
    case 0:
      iconCurve(canvas, r, c, (x) => 0.5 - 0.6 * (x + 1) / 2 + 0.2 * math.sin(x * 9) * math.exp(-x));
    case 1:
      final center = Offset(r.center.dx, r.bottom - 2);
      final rad = math.min(r.width / 2, r.height - 4);
      canvas.drawArc(Rect.fromCircle(center: center, radius: rad), math.pi, math.pi, false, Paint()
        ..color = c.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4);
      canvas.drawLine(center, center + Offset(math.cos(-math.pi / 2 + 0.3), math.sin(-math.pi / 2 + 0.3)) * rad, Paint()
        ..color = c
        ..strokeWidth = 1.8);
    default:
      const h = [0.5, 0.7, 0.62];
      final bw = r.width / 5;
      for (var k = 0; k < 3; k++) {
        final hh = r.height * h[k];
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(r.left + bw * (k * 1.6 + 0.4), r.bottom - hh, bw, hh),
            const Radius.circular(2)), Paint()..color = c.withValues(alpha: 0.5 + 0.2 * k));
      }
      canvas.drawLine(Offset(r.left, r.bottom - r.height * 0.65), Offset(r.right, r.bottom - r.height * 0.65), Paint()..color = c);
  }
}

/// Meters: Analyzer, Tuner and Loudness as cards over the chosen meter.
class MetersPage extends StatelessWidget {
  const MetersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final inline = DeviceScope.isInline(context);
    final cards = Padding(padding: const EdgeInsets.only(bottom: 8),
        child: VariantCards(icon: (c, r, i, col) => _meterIcon(c, r.deflate(3), i, col), height: inline ? 44 : 50));
    return switch (variantOf(context)) {
      1 => _TunerPage(cards: cards),
      2 => _LoudnessPage(cards: cards),
      _ => _AnalyzerPage(cards: cards),
    };
  }
}

class _AnalyzerPage extends StatefulWidget {
  const _AnalyzerPage({required this.cards});
  final Widget cards;

  @override
  State<_AnalyzerPage> createState() => _AnalyzerPageState();
}

class _AnalyzerPageState extends State<_AnalyzerPage> {
  double _tilt = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final hero = HeroCanvas(
      color: scope.accent,
      height: 260,
      caption: 'ANALYZER',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final hz = f?.raw == null ? 0.0 : f!.at(6);
        return Text(hz <= 0 ? 'tilt ${valueText(scope, 'tilt')}' : 'peak ${hzLabel(hz)} Hz · ${f!.at(7).toStringAsFixed(0)} dB');
      }),
      child: LayoutBuilder(builder: (context, box) => GrabGesture(
        key: const ValueKey('analyzer-hero'),
        onStart: (_, _) {
          _tilt = t.value('tilt');
          DeviceFeel.grab();
        },
        onUpdate: (u) {
          _tilt = clampParam(scope, 'tilt', _tilt - u.delta.dy / box.maxHeight * 6 * DeviceFingers.fine);
          t.setLive('tilt', _tilt);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
        },
        onDoubleTap: (_) => t.set('tilt', t.param('tilt')?.defaultValue ?? 4.5),
        child: DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length >= 264 && f.at(3) > 0.5;
          final bins = live ? f.at(2).round().clamp(2, 128) : 0;
          return CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _SpectrumPainter(
            first: live ? [for (var i = 0; i < bins; i++) f.at(8 + i)] : null,
            second: live && f.at(4) < 1.5 ? [for (var i = 0; i < bins; i++) f.at(136 + i)] : null,
            peakHz: live ? f.at(6) : null,
            labels: t.value('source').round() == 1 ? ('MID', 'SIDE') : ('LEFT', 'RIGHT'),
            color: scope.accent,
            second2: scope.secondary));
        }),
      )),
    );
    return mergedPage(context, 'meters', cards: widget.cards, hero: hero,
        rows: [chipWrap([const ChoiceChips('source', title: 'SOURCE')])],
        knobs: const KnobRow(['tilt'], size: 52));
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({required this.first, required this.second, required this.peakHz, required this.labels, required this.color,
    required this.second2});
  final List<double>? first, second;
  final double? peakHz;
  final (String, String) labels;
  final Color color, second2;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(10, 24, size.width - 10, size.height - 8);
    paintLogGrid(canvas, r);
    for (final db in [-24.0, -48.0, -72.0]) {
      final y = r.top + (-db / 96) * r.height;
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), Paint()..color = Neon.ink.withValues(alpha: 0.06));
      paintLabel(canvas, '${db.round()}', Offset(r.right - 2, y - 6), Neon.dim, size: 7.5, align: 1);
    }
    Path line(List<double> v) {
      final p = Path();
      for (var i = 0; i < v.length; i++) {
        final x = r.left + r.width * i / (v.length - 1);
        final y = r.top + (1 - dbUnit(v[i], floor: 96)) * r.height;
        i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      return p;
    }
    if (second case final v?) strokeGlow(canvas, line(v), second2.withValues(alpha: 0.75), width: 1.4, glow: false);
    if (first case final v?) {
      final p = line(v);
      fillFade(canvas, Path.from(p)
        ..lineTo(r.right, r.bottom)
        ..lineTo(r.left, r.bottom)
        ..close(), r.bottom, size, color);
      strokeGlow(canvas, p, color, width: 1.8);
      paintLabel(canvas, labels.$1, Offset(r.left + 2, r.top + 4), color, size: 8, weight: FontWeight.w700);
      if (second != null) paintLabel(canvas, labels.$2, Offset(r.left + 40, r.top + 4), second2, size: 8, weight: FontWeight.w700);
    } else {
      paintLabel(canvas, 'Play something: the spectrum shows here', r.center, Neon.dim, size: 9, align: 0);
    }
    if (peakHz case final hz? when hz > 0) {
      final x = r.left + logUnit(hz) * r.width;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), Paint()..color = Neon.text.withValues(alpha: 0.3));
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter o) => true;
}

const _noteNames = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];

class _TunerPage extends StatelessWidget {
  const _TunerPage({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final hero = HeroCanvas(
      color: scope.accent,
      height: 240,
      caption: 'TUNER',
      grid: false,
      readout: Builder(builder: (context) => Text('A4 ${valueText(scope, 'reference')}')),
      child: DeviceDisplay(builder: (context, f) {
        final live = f?.raw != null && f!.raw!.length >= 9 && f.at(2) > 0.5;
        return LayoutBuilder(builder: (context, box) => CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _TunerPainter(
          note: live ? f.at(4).round() : null,
          cents: live ? f.at(5) : 0,
          hz: live ? f.at(3) : null,
          confidence: live ? f.at(6) : 0,
          color: scope.accent)));
      }),
    );
    return mergedPage(context, 'meters', cards: cards, hero: hero,
        rows: [chipWrap([const ChoiceChips('range', title: 'RANGE')])],
        knobs: const KnobRow(['reference', 'threshold'], size: 52, labels: {'reference': 'A4', 'threshold': 'Threshold'}));
  }
}

class _TunerPainter extends CustomPainter {
  _TunerPainter({required this.note, required this.cents, required this.hz, required this.confidence, required this.color});
  final int? note;
  final double cents, confidence;
  final double? hz;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height - 24);
    final rad = math.min(size.width / 2 - 20, size.height - 54);
    // The scale, −50..+50 cents, green within ±5.
    for (var k = -50; k <= 50; k += 5) {
      final a = -math.pi / 2 + k / 50 * 1.05;
      final d = Offset(math.cos(a), math.sin(a));
      final long = k % 25 == 0;
      canvas.drawLine(c + d * (rad - (long ? 14 : 8)), c + d * rad, Paint()
        ..color = (k.abs() <= 5 ? Neon.green : Neon.ink.withValues(alpha: 0.4))
        ..strokeWidth = long ? 2 : 1.2);
      if (long) paintLabel(canvas, k == 0 ? '0' : '${k > 0 ? '+' : ''}$k', c + d * (rad + 10), Neon.dim, size: 8, align: 0);
    }
    final inTune = note != null && cents.abs() <= 5;
    if (note case final n?) {
      final a = -math.pi / 2 + cents.clamp(-50.0, 50.0) / 50 * 1.05;
      final tip = c + Offset(math.cos(a), math.sin(a)) * (rad - 4);
      canvas.drawLine(c, tip, Paint()
        ..color = (inTune ? Neon.green : color).withValues(alpha: 0.4 + 0.6 * confidence.clamp(0.0, 1.0))
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round);
      final name = '${_noteNames[n % 12]}${n ~/ 12 - 1}';
      paintLabel(canvas, name, Offset(c.dx, c.dy - rad * 0.45), inTune ? Neon.green : Neon.text, size: 34, align: 0,
          weight: FontWeight.w800);
      paintLabel(canvas, '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(1)} ¢ · ${hz!.toStringAsFixed(1)} Hz',
          Offset(c.dx, c.dy - rad * 0.45 + 30), Neon.dim, size: 10, align: 0);
    } else {
      paintLabel(canvas, '—', Offset(c.dx, c.dy - rad * 0.45), Neon.dim, size: 34, align: 0);
      paintLabel(canvas, 'Play one note', Offset(c.dx, c.dy - rad * 0.45 + 30), Neon.dim, size: 10, align: 0);
    }
    canvas.drawCircle(c, 6, Paint()..color = Neon.text);
  }

  @override
  bool shouldRepaint(covariant _TunerPainter o) => true;
}

class _LoudnessPage extends StatelessWidget {
  const _LoudnessPage({required this.cards});
  final Widget cards;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final hero = HeroCanvas(
      color: scope.accent,
      height: 240,
      caption: 'LOUDNESS',
      grid: false,
      readout: Builder(builder: (context) => Text('target ${valueText(scope, 'target')}')),
      child: HistoryRecorder(lanes: 1, length: 200, pick: (f) => f.raw == null ? null : [f.at(3, -120)], builder: (context, hist, f) {
        final live = f?.raw != null && f!.raw!.length >= 13;
        return LayoutBuilder(builder: (context, box) => CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _LoudnessPainter(
          hist: hist,
          values: live ? [for (var i = 2; i < 13; i++) f.at(i)] : null,
          target: t.value('target'),
          color: scope.accent,
          second: scope.secondary)));
      }),
    );
    final on = t.value('reset') >= 0.5;
    return mergedPage(context, 'meters', cards: cards, hero: hero,
      rows: [Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        LitPill(label: 'Start over', icon: Icons.restart_alt, on: false, keyName: 'loudness-reset', height: 34, onTap: () {
          // The engine starts over on Off to On.
          if (on) t.set('reset', 0);
          t.set('reset', 1);
        }),
        const DeviceToggle('reset_on_play', label: 'Reset on Play', icon: Icons.play_arrow),
      ])],
      knobs: const KnobRow(['target'], size: 52));
  }
}

class _LoudnessPainter extends CustomPainter {
  _LoudnessPainter({required this.hist, required this.values, required this.target, required this.color, required this.second});
  final LevelHistory hist;
  final List<double>? values;
  final double target;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    const lo = -48.0, hi = 0.0;
    final bars = Rect.fromLTRB(12, 30, math.min(size.width * 0.45, 210), size.height - 22);
    double y(double l, Rect r) => r.bottom - ((l - lo) / (hi - lo)).clamp(0.0, 1.0) * r.height;
    final v = values;
    String fmt(double l) => l <= -100 ? '—' : l.toStringAsFixed(1);
    final items = [('M', v?[0]), ('S', v?[1]), ('I', v?[2])];
    final bw = bars.width / 3;
    for (var k = 0; k < 3; k++) {
      final (label, l) = items[k];
      final col = Rect.fromLTWH(bars.left + k * bw + 4, bars.top, bw - 8, bars.height);
      canvas.drawRRect(RRect.fromRectAndRadius(col, const Radius.circular(4)), Paint()..color = Neon.ink.withValues(alpha: 0.07));
      if (l != null && l > lo) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(col.left, y(l, col), col.right, col.bottom), const Radius.circular(4)),
            Paint()..color = (k == 2 ? color : second).withValues(alpha: k == 2 ? 0.9 : 0.55));
      }
      paintLabel(canvas, label, Offset(col.center.dx, col.bottom + 9), Neon.dim, size: 9, align: 0, weight: FontWeight.w800);
      paintLabel(canvas, l == null ? '—' : fmt(l), Offset(col.center.dx, col.top - 8), Neon.text, size: 9, align: 0);
    }
    canvas.drawLine(Offset(bars.left, y(target, bars)), Offset(bars.right, y(target, bars)), Paint()
      ..color = Neon.green
      ..strokeWidth = 1.6);
    // The numbers and the short-term history on the right.
    final right = Rect.fromLTRB(bars.right + 16, 26, size.width - 10, size.height - 10);
    if (right.width < 80) return;
    final integrated = v?[2];
    paintLabel(canvas, integrated == null || integrated <= -100 ? '— LUFS' : '${integrated.toStringAsFixed(1)} LUFS',
        Offset(right.left, right.top + 14), Neon.text, size: 24, weight: FontWeight.w800);
    final lu = v?[10];
    paintLabel(canvas, lu == null ? 'INTEGRATED' : 'INTEGRATED · ${lu >= 0 ? '+' : ''}${lu.toStringAsFixed(1)} LU vs target',
        Offset(right.left, right.top + 36), Neon.dim, size: 8.5);
    final tp = v?[7];
    paintLabel(canvas, 'TRUE PEAK MAX ${tp == null || tp <= -100 ? '—' : '${tp.toStringAsFixed(1)} dBTP'}',
        Offset(right.left, right.top + 52), tp != null && tp > -1 ? redColor() : Neon.dim, size: 8.5);
    final secs = v?[8];
    if (secs != null) paintLabel(canvas, '${secs.toStringAsFixed(0)} s measured', Offset(right.left, right.top + 66), Neon.dim, size: 8.5);
    final trace = Rect.fromLTRB(right.left, right.top + 80, right.right, right.bottom);
    if (trace.height < 30) return;
    canvas.drawRect(trace, Paint()
      ..color = Neon.ink.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke);
    canvas.drawLine(Offset(trace.left, y(target, trace)), Offset(trace.right, y(target, trace)), Paint()..color = Neon.green.withValues(alpha: 0.6));
    final n = hist.length;
    final path = Path();
    var started = false;
    for (var age = 0; age < n; age++) {
      final l = hist.at(0, age);
      if (l <= -100) continue;
      final p = Offset(trace.right - age * trace.width / (n - 1), y(l, trace));
      started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      started = true;
    }
    strokeGlow(canvas, path, color, width: 1.6);
    paintLabel(canvas, 'SHORT-TERM', Offset(trace.left + 4, trace.top + 8), Neon.dim, size: 7.5);
  }

  @override
  bool shouldRepaint(covariant _LoudnessPainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Lo-fi

/// Lo-fi: a phrase of a sine as the sections leave it (≈: worn darker, hiss and crackle on it, wobbling in time,
/// gritty steps), each section's amount as applied (the engine's, with Age) in a row under it; up and down on it
/// sets Age, the macro.
class LofiPage extends StatefulWidget {
  const LofiPage({super.key});

  @override
  State<LofiPage> createState() => _LofiPageState();
}

class _LofiPageState extends State<LofiPage> {
  double _age = 0;
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final inline = DeviceScope.isInline(context);
    double v(String id) => t.param(id) == null ? 0 : t.value(id);
    final hero = HeroCanvas(
      color: scope.accent,
      height: 210,
      caption: 'AGE ≈',
      grid: false,
      readout: Builder(builder: (context) => Text('age ${(t.value('age') * 100).round()}%')),
      child: LayoutBuilder(builder: (context, box) => GrabGesture(
        key: const ValueKey('lofi-hero'),
        onStart: (_, _) {
          _age = t.value('age');
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _age = (_age - u.delta.dy / box.maxHeight * DeviceFingers.fine).clamp(0.0, 1.0);
          t.setLive('age', _age);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.set('age', 0),
        child: DeviceDisplay(builder: (context, f) => DevicePhase(builder: (context, secs) {
          final live = f?.raw != null && f!.raw!.length >= 12;
          // As applied: the engine's (Age included), else the knobs with Age's own shares.
          final age = v('age');
          double applied(int i, String id, double share) =>
              live ? f.at(i) : (v(id) + age * share).clamp(0.0, 1.0);
          return CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _LofiPainter(
            secs: secs,
            crackle: applied(3, 'crackle', 0.6),
            wear: applied(4, 'wear', 1),
            hiss: applied(5, 'hiss', 0.5),
            wobble: applied(6, 'wobble', 0.5),
            grit: live ? f.at(8) : math.max(v('grit'), age > 0.6 ? (age - 0.6) / 0.4 : 0),
            band: v('band').round(),
            color: scope.accent,
            second: scope.secondary,
            active: _active));
        })),
      )),
    );
    if (inline) return effectPage('lofi', [hero, const KnobRow(['age', 'crackle', 'wear', 'hiss', 'wobble'], size: 40)]);
    return effectPage('lofi', [
      hero,
      const KnobRow(['age'], size: 70),
      const KnobRow(['crackle', 'wear', 'hiss', 'wobble', 'grit'], size: 44),
      chipWrap([const ChoiceChips('band', title: 'BAND')]),
      const DeviceFold(child: ParamGrid(only: ['seed'])),
    ]);
  }
}

class _LofiPainter extends CustomPainter {
  _LofiPainter({required this.secs, required this.crackle, required this.wear, required this.hiss, required this.wobble,
    required this.grit, required this.band, required this.color, required this.second, required this.active});
  final double secs, crackle, wear, hiss, wobble, grit;
  final int band;
  final Color color, second;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final meters = 30.0;
    final r = Rect.fromLTRB(10, 24, size.width - 10, size.height - meters - 8);
    final rnd = math.Random(7);
    final clean = Path(), worn = Path();
    const n = 360;
    final steps = grit > 0 ? (64 - 56 * grit).round().clamp(4, 64) : 0;
    double? last;
    for (var i = 0; i <= n; i++) {
      final u = i / n;
      final wob = wobble * 0.04 * math.sin(2 * math.pi * (u * 0.8 + secs * 0.55));
      var s = math.sin(2 * math.pi * (u + wob) * 3) * (0.8 - 0.25 * wear) + 0.25 * (1 - wear) * math.sin(2 * math.pi * u * 21);
      if (band > 0) s *= 0.85;
      if (steps > 0) {
        final hold = (i ~/ math.max(1, (n / (steps * 6)).round()));
        s = last != null && hold == ((i - 1) ~/ math.max(1, (n / (steps * 6)).round())) ? last : (s * steps).roundToDouble() / steps;
      }
      last = s;
      var y = s + hiss * 0.12 * (rnd.nextDouble() - 0.5);
      if (crackle > 0 && rnd.nextDouble() < crackle * 0.03) y += (rnd.nextBool() ? 1 : -1) * (0.3 + 0.6 * rnd.nextDouble());
      final x = r.left + u * r.width;
      final c0 = math.sin(2 * math.pi * u * 3) * 0.8 + 0.25 * math.sin(2 * math.pi * u * 21);
      i == 0 ? clean.moveTo(x, r.center.dy - c0 * r.height * 0.42) : clean.lineTo(x, r.center.dy - c0 * r.height * 0.42);
      final py = r.center.dy - y.clamp(-1.15, 1.15) * r.height * 0.42;
      i == 0 ? worn.moveTo(x, py) : worn.lineTo(x, py);
    }
    canvas.drawPath(clean, Paint()
      ..color = Neon.ink.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke);
    canvas.save();
    canvas.clipRect(r.inflate(4));
    strokeGlow(canvas, worn, Color.lerp(color, second, wear * 0.6)!, width: active ? 2.2 : 1.6);
    canvas.restore();
    // Each section as applied.
    const names = ['CRACKLE', 'WEAR', 'HISS', 'WOBBLE', 'GRIT'];
    final amounts = [crackle, wear, hiss, wobble, grit];
    final cw = (size.width - 20) / 5;
    for (var k = 0; k < 5; k++) {
      final cell = Rect.fromLTWH(10 + k * cw + 3, size.height - meters, cw - 6, 6);
      canvas.drawRRect(RRect.fromRectAndRadius(cell, const Radius.circular(3)), Paint()..color = Neon.ink.withValues(alpha: 0.08));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cell.left, cell.top, cell.width * amounts[k].clamp(0.0, 1.0), cell.height),
          const Radius.circular(3)), Paint()..color = color.withValues(alpha: 0.85));
      paintLabel(canvas, names[k], Offset(cell.left, cell.bottom + 9), amounts[k] > 0.01 ? Neon.text : Neon.dim, size: 7.5);
    }
  }

  @override
  bool shouldRepaint(covariant _LofiPainter o) => true;
}

// ---------------------------------------------------------------------------------------------------------------
// Phase align

/// Phase align: the key's waveform (the reference) over this track's (≈, a kick-like hit), this one moved by the
/// delay and flipped by the polarity; drag sideways for the delay (Manual). Learn (Auto) finds the lag and polarity:
/// its progress, the lag found, its confidence and the correlation with the key now.
class PhaseAlignPage extends StatefulWidget {
  const PhaseAlignPage({super.key});

  @override
  State<PhaseAlignPage> createState() => _PhaseAlignPageState();
}

class _PhaseAlignPageState extends State<PhaseAlignPage> {
  double _delay = 0;
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final inline = DeviceScope.isInline(context);
    final hero = HeroCanvas(
      color: scope.accent,
      height: 220,
      caption: 'ALIGN',
      grid: false,
      readout: Builder(builder: (context) => Text('${valueText(scope, 'delay')}${t.value('invert') >= 0.5 ? ' · Ø' : ''}')),
      child: LayoutBuilder(builder: (context, box) => GrabGesture(
        key: const ValueKey('phase-hero'),
        onStart: (_, _) {
          _delay = t.value('delay');
          DeviceFeel.grab();
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _delay = clampParam(scope, 'delay', _delay + u.delta.dx / box.maxWidth * 10 * DeviceFingers.fine);
          t.setLive('delay', _delay);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.set('delay', 0),
        child: DeviceDisplay(builder: (context, f) {
          final live = f?.raw != null && f!.raw!.length >= 10;
          return CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _AlignPainter(
            delayMs: live ? f.at(2) : t.value('delay'),
            inverted: live ? f.at(3) > 0.5 : t.value('invert') >= 0.5,
            lagMs: live ? f.at(6) : null,
            correlation: live ? f.at(8) : null,
            color: scope.accent,
            second: scope.secondary,
            active: _active));
        }),
      )),
    );
    final learnRow = DeviceDisplay(builder: (context, f) {
      final live = f?.raw != null && f!.raw!.length >= 10;
      final progress = live ? f.at(5) : 0.0, confidence = live ? f.at(7) : 0.0, lag = live ? f.at(6) : 0.0;
      final learning = t.value('learn') >= 0.5 && progress < 1;
      return Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        LitPill(label: learning ? 'Learning ${(progress * 100).round()}%' : 'Learn', icon: Icons.hearing, on: learning,
            height: 36, keyName: 'phase-learn', onTap: () {
          // Off to On learns again; Learn also turns Auto on.
          if (t.value('learn') >= 0.5) t.set('learn', 0);
          t.setAll({'mode': 1, 'learn': 1});
        }),
        LitPill(label: 'Ø Polarity', on: t.value('invert') >= 0.5, height: 36, keyName: 'phase-invert',
            onTap: () => t.set('invert', t.value('invert') >= 0.5 ? 0 : 1)),
        if (live && progress >= 1)
          Text('FOUND ${lag >= 0 ? '+' : ''}${lag.toStringAsFixed(2)} ms · ${(confidence * 100).round()}% sure${lag < 0 ? ' · delay the key\'s track' : ''}',
              style: Neon.code(size: 9.5, color: lag < 0 ? Neon.yellow : Neon.dim)),
      ]);
    });
    if (inline) return effectPage('phasealign', [hero, learnRow, const KnobRow(['delay'], size: 44)]);
    return effectPage('phasealign', [
      hero,
      learnRow,
      const SizedBox(height: 6),
      chipWrap([const ChoiceChips('mode', title: 'MODE')]),
      const KnobRow(['delay', 'window'], size: 54),
    ]);
  }
}

class _AlignPainter extends CustomPainter {
  _AlignPainter({required this.delayMs, required this.inverted, required this.lagMs, required this.correlation,
    required this.color, required this.second, required this.active});
  final double delayMs;
  final bool inverted, active;
  final double? lagMs, correlation;
  final Color color, second;

  /// A kick-like hit at [ms] after its start (≈): a falling sine under a fast envelope.
  static double hit(double ms) {
    if (ms < 0) return 0;
    final s = ms / 1000;
    final phase = 2 * math.pi * (55 * s + 90 * (1 - math.exp(-s * 40)) / 40);
    return math.sin(phase) * math.exp(-s * 18) * math.min(1, ms / 0.6);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const span = 24.0; // ms across
    final corrH = correlation == null ? 0.0 : 22.0;
    final r = Rect.fromLTRB(12, 26, size.width - 12, size.height - 10 - corrH);
    final lanes = [Rect.fromLTRB(r.left, r.top, r.right, r.center.dy - 3), Rect.fromLTRB(r.left, r.center.dy + 3, r.right, r.bottom)];
    double x(double ms) => r.left + (ms / span) * r.width;
    // Lag: where this track's hit starts against the key's (its own lag, when learned, else 2 ms early).
    final early = lagMs ?? 2.0;
    final keyStart = 4.0, ownStart = keyStart - early + delayMs;
    for (final (k, start, c, flip, label) in [(0, keyStart, second, false, 'KEY'), (1, ownStart, color, inverted, 'THIS TRACK')]) {
      final lane = lanes[k];
      canvas.drawLine(Offset(lane.left, lane.center.dy), Offset(lane.right, lane.center.dy), Paint()..color = Neon.ink.withValues(alpha: 0.1));
      final p = Path();
      for (var i = 0; i <= 240; i++) {
        final ms = span * i / 240;
        final y = hit(ms - start) * (flip ? -1 : 1);
        final pt = Offset(x(ms), lane.center.dy - y * lane.height * 0.45);
        i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
      }
      strokeGlow(canvas, p, c, width: k == 1 && active ? 2.4 : 1.8);
      paintLabel(canvas, label, Offset(lane.left + 2, lane.top + 6), c, size: 8, weight: FontWeight.w700);
      canvas.drawLine(Offset(x(start), lane.top), Offset(x(start), lane.bottom), Paint()..color = c.withValues(alpha: 0.4));
    }
    paintLabel(canvas, '≈ ${span.round()} ms', Offset(r.right, r.top + 6), Neon.dim, size: 8, align: 1);
    if (correlation case final cr?) {
      final bar = Rect.fromLTRB(r.left, size.height - 18, r.right, size.height - 10);
      canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(4)), Paint()..color = Neon.ink.withValues(alpha: 0.08));
      final mid = bar.center.dx, to = mid + cr.clamp(-1.0, 1.0) * bar.width / 2;
      canvas.drawRect(Rect.fromLTRB(math.min(mid, to), bar.top, math.max(mid, to), bar.bottom),
          Paint()..color = (cr >= 0 ? Neon.green : redColor()).withValues(alpha: 0.85));
      canvas.drawLine(Offset(mid, bar.top - 2), Offset(mid, bar.bottom + 2), Paint()..color = Neon.text.withValues(alpha: 0.5));
      paintLabel(canvas, 'CORRELATION ${cr.toStringAsFixed(2)}', Offset(bar.left, bar.top - 6), Neon.dim, size: 7.5);
    }
  }

  @override
  bool shouldRepaint(covariant _AlignPainter o) => true;
}
