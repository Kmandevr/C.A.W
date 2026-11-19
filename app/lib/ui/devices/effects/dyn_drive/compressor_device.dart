// The Compressor device page (org.caw.compressor; 1.1.0's Talon variants): variant cards, a transfer curve with handles beside a scrolling level trace, per-variant knobs.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../model/device_display.dart';
import '../../../../model/merged_devices.dart';
import '../../../theme.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../visuals/fx_visuals.dart' show CompressorGraph;
import '../dynamics/fx_math.dart';
import '../dynamics_editors.dart' show duckRatio;
import '../ducker_editor.dart' show duckAt;
import '../effect_page.dart';
import '../eqfilter/variant_cards.dart' show VariantCards;
import 'common.dart';
import 'dynamics_modes.dart';

/// The cards' names for the variants (1.1.0: Down, Dynamics, Up, Bus). Gate, Shape and Duck left for Gate,
/// Tremolo/Pan and Ducker, which open their own pages ([MergedDevices.pageId]).
const compressorCardNames = ['Down', 'Dynamics', 'Up', 'Bus'];

/// The Bus variant's stepped ratios (its `ratio` choice; the engine's builtin_fx_talon.cpp).
const busRatios = [1.5, 2.0, 4.0, 10.0];

/// Gate's and Ducker's cards (1.1.0: their own devices, sharing this page's language).
const gateCardNames = ['Gate', 'Expand', 'Pedal gate'];
const duckCardNames = ['Duck', 'Level', 'Carve'];

/// What this page draws for a device's variant: 0 Down, 1 Dynamics, 2 a gate or expander (Gate, Expand), 4 Duck,
/// 5 Up, 6 Bus (the 1.0.9 Compressor's numbers kept for those it had); -1 a page of its own (Pedal gate, Level,
/// Carve: dynamics_modes.dart).
int compressorPageKind(String? id, int v) => switch (id) {
      'org.caw.gate' => v <= 1 ? 2 : -1,
      'org.caw.duck' => v == 0 ? 4 : -1,
      _ => const [0, 1, 5, 6][v.clamp(0, 3)],
    };

void gateCardIcon(Canvas canvas, Rect r, int i, Color c) {
  final rr = r.deflate(2);
  if (i == 0) {
    iconCurve(canvas, rr, c, (x) => x < -0.2 ? math.max(-1.0, -0.2 + (x + 0.2) * 4) : x);
  } else if (i == 1) {
    iconCurve(canvas, rr, c, (x) => x < -0.2 ? -0.2 + (x + 0.2) * 2 : x);
  } else {
    iconCurve(canvas, rr, c, (x) => x < 0 ? -1.0 : x);
  }
}

void duckCardIcon(Canvas canvas, Rect r, int i, Color c) {
  final rr = r.deflate(2);
  if (i == 0) {
    iconCurve(canvas, rr, c, (x) => 0.8 - 1.5 * duckAt(((x + 1) % 1) * 200, 3, 10, 150, 0.6), steps: 60);
  } else if (i == 1) {
    iconCurve(canvas, rr, c, (x) => 0.3 * math.sin(x * math.pi));
  } else {
    iconCurve(canvas, rr, c, (x) => (x - 0.1).abs() < 0.25 ? -0.6 : 0.2);
  }
}

/// Each variant's card: its transfer curve.
void compressorCardIcon(Canvas canvas, Rect r, int i, Color c) {
  final rr = r.deflate(2);
  switch (i) {
    case 0:
      iconCurve(canvas, rr, c, (x) => x < 0 ? x : x * 0.3);
    case 1:
      iconCurve(canvas, rr, c, (x) => x < -0.4 ? -0.4 + (x + 0.4) * 0.45 : x > 0.3 ? 0.3 + (x - 0.3) * 0.35 : x);
    case 2:
      iconCurve(canvas, rr, c, (x) => x < 0 ? x * 0.5 : x);
    default:
      iconCurve(canvas, rr, c, (x) => x < -0.1 ? x : -0.1 + (x + 0.1) * 0.5);
  }
}

/// The Compressor: Down, Dynamics, Up and Bus as cards (one undo step each, resetting the knobs the new variant
/// doesn't share). Each draws the transfer curve with its handles (threshold and ratio; Down's knee bracket;
/// Dynamics' low and high thresholds) beside a scrolling trace of the input with the gain change hanging from the
/// top in yellow; up and down on the trace drags a threshold line. Detection and Sidechain are chips where the
/// variant has them (the key itself is the shell's Key bar); Mix and Output are the footer's.
class CompressorDevice extends StatelessWidget {
  const CompressorDevice({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final id = t.componentId;
    final v = compressorPageKind(id, t.info?.variantIndex ?? 0);
    final inline = DeviceScope.isInline(context);
    final (names, icon) = switch (id) {
      'org.caw.gate' => (gateCardNames, gateCardIcon),
      'org.caw.duck' => (duckCardNames, duckCardIcon),
      _ => (compressorCardNames, compressorCardIcon),
    };
    final cards = Padding(padding: const EdgeInsets.only(bottom: 8),
        child: VariantCards(icon: icon, names: names, height: inline ? 46 : 54));
    if (v < 0) {
      // Pedal gate, Level and Carve: pages of their own (dynamics_modes.dart).
      return switch ((id, t.info?.variantIndex ?? 0)) {
        ('org.caw.gate', _) => PedalGatePage(cards: cards),
        ('org.caw.duck', 1) => LevelPage(cards: cards),
        _ => CarvePage(cards: cards),
      };
    }
    final caption = switch (v) {
      1 => 'DYNAMICS', 2 => (t.info?.variantIndex ?? 0) == 1 ? 'EXPAND' : 'GATE',
      4 => 'DUCK', 5 => 'UP', 6 => 'BUS', _ => 'COMPRESSOR',
    };
    final hero = HeroCanvas(
      color: scope.accent,
      height: 220,
      caption: caption,
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        if (f == null) return const SizedBox.shrink();
        if (v == 1) {
          final g = f.values['gain_db'] ?? 0;
          return Text('${g >= 0 ? '+' : ''}${g.toStringAsFixed(1)} dB', style: Neon.code(size: 10, color: g >= 0 ? scope.accent : Neon.yellow));
        }
        final gr = f.gainReductionDb ?? 0;
        if (v == 5) return Text('LIFT +${gr.toStringAsFixed(1)} dB', style: Neon.code(size: 10, color: scope.accent));
        return Text('GR ${gr.toStringAsFixed(1)} dB', style: Neon.code(size: 10, color: Neon.yellow));
      }),
      child: const _DynHero(),
    );
    final main = switch (v) {
      1 => const ['low_threshold', 'low_ratio', 'high_threshold', 'high_ratio', 'attack', 'release'],
      2 => const ['threshold', 'range', 'attack', 'hold', 'release'],
      4 => const ['threshold', 'amount', 'attack', 'hold', 'release'],
      5 => const ['threshold', 'ratio', 'range', 'attack', 'release'],
      6 => const ['threshold', 'attack', 'knee', 'makeup'],
      _ => const ['threshold', 'ratio', 'attack', 'release', 'makeup'],
    };
    const labels = {'low_threshold': 'Low thr', 'high_threshold': 'High thr', 'low_ratio': 'Low ratio', 'high_ratio': 'High ratio'};
    if (inline) return effectPage('compressor', [cards, hero, KnobRow(main, size: 44, labels: labels)]);
    final more = switch (v) {
      1 => const ['knee', 'range', 'in_gain'],
      2 => const ['ratio', 'knee', 'sc_hpf'],
      4 => const <String>[],
      5 => const ['floor', 'knee', 'lookahead', 'link', 'sc_hpf', 'sc_lpf', 'sc_listen'],
      6 => const ['link', 'sc_hpf', 'sc_lpf', 'sc_listen'],
      _ => const ['knee', 'lookahead', 'link', 'sc_hpf', 'sc_lpf', 'sc_listen'],
    };
    return effectPage('compressor', [
      cards,
      hero,
      KnobRow(main, size: 50, labels: labels),
      chipWrap([
        if (t.param('detect') != null) const ChoiceChips('detect', title: 'DETECT'),
        if (t.param('detection') != null) const ChoiceChips('detection', title: 'DETECT'),
        if (t.param('sidechain') != null) const ChoiceChips('sidechain', title: 'SIDECHAIN', labels: ['Self', 'Key']),
        if (v == 6) const ChoiceChips('ratio', title: 'RATIO'),
        if (v == 6) const ChoiceChips('release', title: 'RELEASE'),
        if (t.param('character') != null) const ChoiceChips('character', title: 'CHARACTER'),
        if (v == 0) const DeviceToggle('auto_makeup', label: 'Auto makeup', icon: Icons.auto_fix_high),
        if (v == 0) const DeviceToggle('auto_release', label: 'Auto release', icon: Icons.auto_mode),
      ]),
      if (more.isNotEmpty) DeviceFold(child: ParamGrid(only: more)),
    ]);
  }

}

/// One way a drag on a handle moves a parameter: [move] gives the new value from the one at the drag's start
/// plus the drag so far (in dB across for x, in pixels up for y).
class _Axis {
  const _Axis(this.param, this.move);
  final String param;
  final double Function(double v, double d) move;
}

/// A handle on the curve at input [inDb], moving [x] sideways and [y] up and down.
class _Grip {
  const _Grip(this.key, this.inDb, this.color, {this.label, this.x, this.y});
  final String key;
  final double inDb;
  final Color color;
  final String? label;
  final _Axis? x, y;
}

/// A threshold drawn across the trace (drag it up or down).
class _Line {
  const _Line(this.param, this.db, this.color, this.label);
  final String param, label;
  final double db;
  final Color color;
}

/// What a variant draws: the axes' floor, its curve, its handles and its trace lines.
class _Model {
  const _Model(this.floor, this.out, this.grips, this.lines, this.detector, this.tag, {this.knee});
  final double floor;
  final double Function(double x) out;
  final List<_Grip> grips;
  final List<_Line> lines;
  final double? detector;
  final String tag;

  /// Down's knee: from and to (dB in) for its bracket.
  final (double, double)? knee;
}

double _ratioUp(double v, double up) => v * math.pow(2, -up / 50).toDouble();

class _DynHero extends StatefulWidget {
  const _DynHero();

  @override
  State<_DynHero> createState() => _DynHeroState();
}

class _DynHeroState extends State<_DynHero> {
  String? _grip; // a handle's key, or 'trace'
  String? _traceParam;
  double _xv = 0, _yv = 0, _dx = 0, _dy = 0;

  _Model _model(DeviceScope scope, int variant, DeviceDisplayFrame? f, double boxH) {
    final t = scope.target;
    double v(String id, double d) => t.param(id) == null ? d : t.value(id);
    final accent = scope.accent, second = scope.secondary;
    double clampTo(String id, double x) => clampParam(scope, id, x);
    switch (variant) {
      case 1:
        final lo = v('low_threshold', -40), lr = v('low_ratio', 1), hi = v('high_threshold', -12), hr = v('high_ratio', 2);
        final knee = v('knee', 6), range = v('range', 24);
        return _Model(72, (x) => x + dynamicsGainDb(x, lowThr: lo, lowRatio: lr, highThr: hi, highRatio: hr, knee: knee, range: range), [
          _Grip('high', hi, accent, label: 'H', x: _Axis('high_threshold', (s, d) => clampTo('high_threshold', s + d)),
              y: _Axis('high_ratio', (s, d) => clampTo('high_ratio', _ratioUp(s, d)))),
          _Grip('low', math.min(lo, hi), second, label: 'L', x: _Axis('low_threshold', (s, d) => clampTo('low_threshold', s + d)),
              y: _Axis('low_ratio', (s, d) => clampTo('low_ratio', _ratioUp(s, -d)))),
        ], [
          _Line('high_threshold', hi, accent, 'HIGH ${hi.toStringAsFixed(1)}'),
          _Line('low_threshold', lo, second, 'LOW ${lo.toStringAsFixed(1)}'),
        ], f?.values['level_db'] ?? f?.inputDb, '${ratioLabel(lr)} · ${ratioLabel(hr)}');
      case 2:
        final thr = v('threshold', -40), range = v('range', -80), ratio = v('ratio', 10);
        double out(double x) => x >= thr ? x : math.max(x + range, thr + (x - thr) * ratio);
        final x0 = ratio > 1.001 ? (thr + range / (ratio - 1)).clamp(-80.0, thr) : thr - 20;
        return _Model(80, out, [
          _Grip('thr', thr, accent, x: _Axis('threshold', (s, d) => clampTo('threshold', s + d)),
              y: _Axis('ratio', (s, d) => clampTo('ratio', _ratioUp(s, d)))),
          _Grip('range', x0.toDouble(), second, label: 'R',
              y: _Axis('range', (s, d) => clampTo('range', s + d / math.max(1, boxH) * 80))),
        ], [_Line('threshold', thr, accent, 'THR ${thr.toStringAsFixed(1)}')], f?.values['detector_db'] ?? f?.inputDb,
            '1:${ratio.toStringAsFixed(ratio < 10 ? 1 : 0)}');
      case 4:
        final thr = v('threshold', -20), amount = v('amount', 0.5), output = v('output', 0);
        final ratio = duckRatio(amount);
        return _Model(60, (x) => CompressorGraph.outputDb(x, thr, ratio, 0) + output, [
          _Grip('thr', thr, accent, x: _Axis('threshold', (s, d) => clampTo('threshold', s + d)),
              y: _Axis('amount', (s, d) => (1 - 1 / _ratioUp(duckRatio(s), d).clamp(1.0, 20.0)).clamp(0.0, 1.0))),
        ], [_Line('threshold', thr, accent, 'THR ${thr.toStringAsFixed(1)}')], f?.values['detector_db'] ?? f?.inputDb,
            '${(amount * 100).round()}%');
      case 5:  // Up: below the threshold the level rises (thr - x)(1 - 1/ratio), at most Range, fading under Floor
        final thr = v('threshold', -30), ratio = v('ratio', 2), range = v('range', 12), floor = v('floor', -60);
        double lift(double x) => math.min(range, math.max(0.0, (thr - x) * (1 - 1 / ratio)));
        double out(double x) => x + (x >= floor ? lift(x) : math.max(0.0, lift(floor) - (floor - x)));
        return _Model(80, out, [
          _Grip('thr', thr, accent, x: _Axis('threshold', (s, d) => clampTo('threshold', s + d)),
              y: _Axis('ratio', (s, d) => clampTo('ratio', _ratioUp(s, -d)))),
        ], [_Line('threshold', thr, accent, 'THR ${thr.toStringAsFixed(1)}')], f?.values['detector_db'] ?? f?.inputDb,
            '${ratio.toStringAsFixed(1)}:1 UP');
      case 6:  // Bus: the stepped ratio (a choice), the threshold handle only
        final thr = v('threshold', -12), knee = v('knee', 6);
        final ratio = busRatios[v('ratio', 1).round().clamp(0, busRatios.length - 1)];
        return _Model(60, (x) => CompressorGraph.outputDb(x, thr, ratio, knee), [
          _Grip('thr', thr, accent, x: _Axis('threshold', (s, d) => clampTo('threshold', s + d))),
        ], [_Line('threshold', thr, accent, 'THR ${thr.toStringAsFixed(1)}')], f?.values['detector_db'] ?? f?.inputDb,
            '${ratio.toStringAsFixed(ratio < 10 && ratio != ratio.roundToDouble() ? 1 : 0)}:1');
      default:
        final thr = v('threshold', -18), ratio = v('ratio', 4), knee = v('knee', 6);
        // With auto makeup the engine's own makeup (display) lifts the curve; else the knob's.
        final makeup = v('auto_makeup', 0) >= 0.5 ? (f?.values['makeup_db'] ?? v('makeup', 0)) : v('makeup', 0);
        return _Model(60, (x) => CompressorGraph.outputDb(x, thr, ratio, knee) + makeup, [
          _Grip('thr', thr, accent, x: _Axis('threshold', (s, d) => clampTo('threshold', s + d)),
              y: _Axis('ratio', (s, d) => clampTo('ratio', _ratioUp(s, d)))),
          if (t.param('knee') != null)
            _Grip('knee', thr + knee / 2, second, label: 'K', x: _Axis('knee', (s, d) => clampTo('knee', s + 2 * d))),
        ], [_Line('threshold', thr, accent, 'THR ${thr.toStringAsFixed(1)}')], f?.values['detector_db'] ?? f?.inputDb,
            '${ratio >= 19.95 ? '∞' : ratio.toStringAsFixed(ratio < 10 ? 1 : 0)}:1', knee: (thr - knee / 2, thr + knee / 2));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final variant = compressorPageKind(t.componentId, t.info?.variantIndex ?? 0);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      // The curve's box: square where the hero is wide, taller than wide on a phone (the hero grows there).
      final ph = math.max(60.0, h - 28), pw = math.max(60.0, math.min(ph, w * 0.48));
      final plot = Rect.fromLTWH(w - pw - 10, 22, pw, ph);
      final trace = Rect.fromLTRB(0, 20, math.max(10, plot.left - 10), h - 4);
      return HistoryRecorder(lanes: 4, pick: (f) => [
        f.inputDb ?? -120, f.outputDb ?? -120,
        variant == 1 ? -(f.values['gain_db'] ?? 0) : -(f.gainReductionDb ?? 0),
        f.values['open'] ?? 1,
      ], builder: (context, hist, f) {
        final m = _model(scope, variant, f, plot.height);
        Offset pt(double inDb, double outDb) => Offset(plot.left + dbUnit(inDb, floor: m.floor) * plot.width,
            plot.bottom - dbUnit(outDb, floor: m.floor) * plot.height);
        Offset gripAt(_Grip g) => g.key == 'knee' && m.knee != null
            ? Offset(pt(m.knee!.$2, -m.floor).dx, plot.bottom - 12)
            : pt(g.inDb, m.out(g.inDb));
        double lineY(double db) => trace.bottom - dbUnit(db, floor: m.floor) * trace.height;
        return GrabGesture(
          key: const ValueKey('comp-hero'),
          onStart: (p, _) {
            _dx = _dy = 0;
            if (plot.inflate(8).contains(p) || m.lines.isEmpty) {
              var best = m.grips.first;
              var bestD = double.infinity;
              for (final g in m.grips) {
                final d = (gripAt(g) - p).distance;
                if (d < bestD) {
                  bestD = d;
                  best = g;
                }
              }
              final g = bestD < 30 ? best : m.grips.first;
              _grip = g.key;
              if (g.x case final a?) _xv = t.value(a.param);
              if (g.y case final a?) _yv = t.value(a.param);
            } else {
              final line = m.lines.reduce((a, b) => (lineY(a.db) - p.dy).abs() <= (lineY(b.db) - p.dy).abs() ? a : b);
              _grip = 'trace';
              _traceParam = line.param;
              _xv = t.value(line.param);
            }
            DeviceFeel.grab();
            setState(() {});
          },
          onUpdate: (u) {
            final fine = DeviceFingers.fine;
            _dx += u.delta.dx * fine;
            _dy -= u.delta.dy * fine;
            if (_grip == 'trace') {
              final id = _traceParam!;
              t.setLive(id, clampParam(scope, id, _xv + _dy / trace.height * m.floor));
              return;
            }
            final g = m.grips.where((g) => g.key == _grip).firstOrNull;
            if (g == null) return;
            if (g.x case final a?) t.setLive(a.param, a.move(_xv, _dx / plot.width * m.floor));
            if (g.y case final a?) t.setLive(a.param, a.move(_yv, _dy));
          },
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() => _grip = null);
          },
          onDoubleTap: (_) => t.setAll({
            for (final g in m.grips) ...{
              if (g.x case final a?) if (t.param(a.param) case final p?) a.param: p.defaultValue,
              if (g.y case final a?) if (t.param(a.param) case final p?) a.param: p.defaultValue,
            },
          }),
          child: CustomPaint(size: Size(w, h), painter: _DynPainter(
            hist: hist, trace: trace, plot: plot, model: m, pt: pt, gripAt: gripAt, lineY: lineY,
            gate: variant == 2, lift: variant == 1 || variant == 5, color: scope.accent, second: scope.secondary,
            active: _grip == 'trace' ? 'trace:$_traceParam' : _grip)),
        );
      });
    });
  }
}

class _DynPainter extends CustomPainter {
  _DynPainter({required this.hist, required this.trace, required this.plot, required this.model, required this.pt,
    required this.gripAt, required this.lineY, required this.gate, required this.lift, required this.color,
    required this.second, required this.active});
  final LevelHistory hist;
  final Rect trace, plot;
  final _Model model;
  final Offset Function(double inDb, double outDb) pt;
  final Offset Function(_Grip g) gripAt;
  final double Function(double db) lineY;
  final bool gate, lift;
  final Color color, second;
  final String? active;

  @override
  void paint(Canvas canvas, Size size) {
    _paintTrace(canvas);
    _paintCurve(canvas);
  }

  void _paintTrace(Canvas canvas) {
    final area = trace;
    if (area.width < 30) return;
    final n = hist.length;
    final dx = area.width / (n - 1);
    final floor = model.floor;
    double y(double db) => area.bottom - dbUnit(db, floor: floor) * area.height;
    final input = Path()..moveTo(area.right, area.bottom);
    final output = Path();
    final cut = Path()..moveTo(area.right, area.top);
    final up = Path()..moveTo(area.right, area.top);
    for (var age = 0; age < n; age++) {
      final x = area.right - age * dx;
      input.lineTo(x, y(hist.at(0, age)));
      age == 0 ? output.moveTo(x, y(hist.at(1, age))) : output.lineTo(x, y(hist.at(1, age)));
      final r = hist.at(2, age);
      cut.lineTo(x, area.top + (math.max(0.0, r) / 24).clamp(0.0, 1.0) * area.height * 0.6);
      up.lineTo(x, area.top + (math.max(0.0, -r) / 24).clamp(0.0, 1.0) * area.height * 0.6);
    }
    input
      ..lineTo(area.left, area.bottom)
      ..close();
    cut
      ..lineTo(area.left, area.top)
      ..close();
    up
      ..lineTo(area.left, area.top)
      ..close();
    canvas.save();
    canvas.clipRect(area);
    canvas.drawPath(input, Paint()..color = Neon.ink.withValues(alpha: 0.11));
    canvas.drawPath(output, Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);
    canvas.drawPath(cut, Paint()..color = Neon.yellow.withValues(alpha: 0.5));
    if (lift) canvas.drawPath(up, Paint()..color = Neon.green.withValues(alpha: 0.4));
    if (gate) {
      // Open (bright) and closed along the bottom.
      for (var age = 0; age < n; age++) {
        final open = hist.at(3, age) >= 0.5;
        if (!open) continue;
        final x = area.right - age * dx;
        canvas.drawRect(Rect.fromLTWH(x - dx / 2, area.bottom - 4, dx + 0.5, 4), Paint()..color = color.withValues(alpha: 0.7));
      }
    }
    canvas.restore();
    for (final l in model.lines) {
      final ly = lineY(l.db);
      final on = active == 'trace:${l.param}';
      final p = Paint()
        ..color = l.color.withValues(alpha: on ? 0.95 : 0.7)
        ..strokeWidth = on ? 2 : 1.2;
      for (var x = area.left; x < area.right; x += 8) {
        canvas.drawLine(Offset(x, ly), Offset(math.min(x + 5, area.right), ly), p);
      }
      paintHandle(canvas, Offset(area.left + 14, ly), l.color, active: on, r: 6);
      paintLabel(canvas, l.label, Offset(area.left + 26, ly - 10), l.color, size: 9, weight: FontWeight.w700);
    }
    paintLabel(canvas, 'IN', Offset(area.left + 6, area.bottom - 10), Neon.dim, size: 8, weight: FontWeight.w700);
    paintLabel(canvas, lift ? 'CUT · LIFT' : 'GR', Offset(area.right - 4, area.top + 8), Neon.yellow, size: 8, align: 1,
        weight: FontWeight.w700);
  }

  void _paintCurve(Canvas canvas) {
    final r = RRect.fromRectAndRadius(plot, const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = Neon.bg.withValues(alpha: 0.55));
    canvas.drawRRect(r, Paint()
      ..color = color.withValues(alpha: active != null && !active!.startsWith('trace') ? 0.8 : 0.3)
      ..style = PaintingStyle.stroke);
    final floor = model.floor;
    final faint = Paint()..color = Neon.ink.withValues(alpha: 0.08);
    canvas.drawLine(pt(-floor, -floor), pt(0, 0), faint);
    for (var d = -12.0; d > -floor; d -= 12) {
      canvas.drawLine(pt(d, -floor), pt(d, 0), faint);
      canvas.drawLine(pt(-floor, d), pt(0, d), faint);
    }
    final path = Path();
    for (var i = 0; i <= 120; i++) {
      final x = -floor + floor * i / 120;
      final p = pt(x, model.out(x));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.save();
    canvas.clipRRect(r);
    if (model.knee case (final a, final b) when b > a) {
      canvas.drawRect(Rect.fromLTRB(pt(a, 0).dx, plot.top, pt(b, 0).dx, plot.bottom), Paint()..color = second.withValues(alpha: 0.07));
    }
    fillFade(canvas, path, plot.bottom, Size(plot.right, plot.bottom), color, alpha: 0.22);
    strokeGlow(canvas, path, color, width: 2.2);
    if (model.detector case final d? when d > -floor) {
      final x = d.clamp(-floor, 0.0);
      final at = pt(x, model.out(x));
      canvas.drawCircle(at, 10, Paint()..color = Neon.ink.withValues(alpha: 0.15));
      canvas.drawCircle(at, 5, Paint()..color = Neon.ink);
    }
    canvas.restore();
    if (model.knee case (final a, final b)) {
      final y = plot.bottom - 12;
      final p = Paint()
        ..color = second.withValues(alpha: 0.8)
        ..strokeWidth = 1.4;
      canvas.drawLine(Offset(pt(a, 0).dx, y), Offset(pt(b, 0).dx, y), p);
      canvas.drawLine(Offset(pt(a, 0).dx, y - 4), Offset(pt(a, 0).dx, y + 4), p);
    }
    for (final g in model.grips) {
      paintHandle(canvas, gripAt(g), g.color, active: active == g.key, r: 7, label: g.label);
    }
    paintLabel(canvas, model.tag, Offset(plot.right - 6, plot.top + 10), color, size: 11, align: 1, weight: FontWeight.w800);
    paintLabel(canvas, 'in → out', Offset(plot.left + 6, plot.top + 9), Neon.dim, size: 8);
  }

  @override
  bool shouldRepaint(covariant _DynPainter o) => paintInputsChanged(
      [o.hist, o.trace, o.plot, o.model, o.gate, o.lift, o.color, o.second, o.active],
      [hist, trace, plot, model, gate, lift, color, second, active]);
}
