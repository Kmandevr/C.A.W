// The merged Filter's page (org.caw.filter, 1.0.8): a strip of curve icons picks the model, a big cutoff/resonance puck on the curve, its LFO and envelope moving it.
import '../../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../engine/component_info.dart';
import '../../../../model/arrange_fx.dart';
import '../../../../model/flagship_shapes.dart' show filterResponseDb, lfoValue;
import '../../../feedback.dart';
import '../../../motion.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../../kit/param_watch.dart';
import '../../visuals/filter_curve.dart' show freqToX, xToFreq;
import '../effect_page.dart';
import '../filters/filters_shared.dart';
import 'variant_cards.dart';

/// `org.caw.filter` Multimode's types as the drawing's shapes (flagship_shapes' numbering: ladder 0–2, SVF 3–6).
int filterDrawType(String label) {
  final l = label.toLowerCase();
  final ladder = l.contains('ladder');
  if (l.contains('notch')) return 6;
  if (l.contains('band')) return ladder ? 2 : 5;
  if (l.contains('high')) return ladder || l.contains('24') ? 1 : 4;
  return ladder || l.contains('24') ? 0 : 3;
}

/// The nonlinear filter's loop shapes (builtin_fx_filters.cpp's shapeOf), for the shape tiles.
double nlShape(int shape, double v) => switch (shape) {
  1 => _tanh(v),
  2 => v >= 0 ? _tanh(v) : 0.6 * _tanh(v / 0.6),
  3 => v.clamp(-1.0, 1.0),
  4 => math.sin(v.clamp(-6.0, 6.0)),
  5 => _tanh(v) + 0.35 * _tanh(v) * _tanh(v) - 0.35 * _tanh(v * v * 0.25),
  _ => v,
};
double _tanh(double x) {
  final e = math.exp(-2 * x.abs().clamp(0.0, 19.0));
  return (x < 0 ? -1 : 1) * (1 - e) / (1 + e);
}

/// The Multimode LFO's synced divisions in whole notes (its `lfo_sync` choices).
const _syncWhole = {'1/16': 1 / 16, '1/8': 1 / 8, '1/4': 1 / 4, '1/2': 1 / 2, '1 bar': 1.0, '2 bars': 2.0, '4 bars': 4.0};

/// Each variant's type parameter (the "type within it" the strip picks) and short names for its choices.
const _typeParam = ['type', 'mode', 'type'];
const _short = [
  ['LP 12', 'LP 24', 'HP 12', 'HP 24', 'BP', 'NOTCH', 'LAD LP', 'LAD HP', 'LAD BP'],
  ['LP', 'BP', 'HP'],
  ['LP', 'BP', 'HP', 'NOTCH', 'AP'],
];

/// The filter's response in dB at [hz] for variant [v]'s values [value] at cutoff [cut] (the dry mix blended in).
double filterDb(int v, double hz, double cut, double Function(String id) value, ComponentParameterInfo? typeParam) {
  final mix = value('mix');
  switch (v) {
    case 1:
      return mixDb(ladderResponse(hz, cutoff: cut, resonance: math.min(value('resonance'), 0.9), mode: value('mode').round(),
          slope: value('slope').round(), comp: value('comp')), mix);
    case 2:
      return mixDb(svfResponse(hz, cutoff: cut, q: value('q'), type: value('type').round()), mix);
    default:
      final type = typeParam == null ? 3 : filterDrawType(formatParamValue(typeParam, value('type')));
      final wet = math.pow(10, filterResponseDb(hz, type: type, cutoff: cut, resonance: value('resonance')) / 20).toDouble();
      return toDb(mix * wet + 1 - mix);
  }
}

/// The Filter: the model strip (every variant's types as small curves), the puck hero, the variant's knobs; the
/// less-used ones under MORE. Inline: the hero at compact height and its main knobs.
class FilterDevicePage extends StatelessWidget {
  const FilterDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final v = variantOf(context).clamp(0, 2);
    final inline = DeviceScope.isInline(context);
    final knob = inline ? 46.0 : 54.0;
    final res = v == 2 ? 'q' : 'resonance';
    final lfoFree = t.value('lfo_sync') < 0.5;
    return effectPage(const ['filter', 'ladder', 'nlfilter'][v], [
      if (!inline) const Padding(padding: EdgeInsets.only(bottom: 8), child: FilterModelStrip()),
      LayoutBuilder(builder: (context, box) => HeroCanvas(
        color: scope.accent,
        height: box.maxWidth > 600 ? 300 : 230,
        caption: '${const ['MULTIMODE', 'LADDER', 'NONLINEAR'][v]} ≈',
        grid: false,
        readout: watchDevice(context, (context) => Text('${formatParamValue(t.param('cutoff'), t.value('cutoff'))} Hz'
            '${v == 2 ? '  Q ${t.value('q').toStringAsFixed(1)}' : ''}'
            '${v == 1 && t.value('resonance') >= 0.91 ? '  ● SELF-OSC' : ''}')),
        child: FilterPuckHero(key: ValueKey('filter-puck-$v'), variant: v),
      )),
      if (v == 2 && !inline) Padding(padding: const EdgeInsets.only(top: 6), child: ModeTiles('shape', height: 46,
        color: scope.secondary, names: const ['CLEAN', 'WARM', 'DIODE', 'HARD', 'FOLD', 'RECT'],
        icon: (canvas, r, i, c) => iconCurve(canvas, r.deflate(2), c, (x) => nlShape(i, x * 3) * 0.9))),
      KnobRow(['cutoff', res, 'drive'], size: knob),
      if (v == 1 && !inline) Row(children: [fieldLabel('SLOPE'), const DeviceChoice('slope')]),
      if (v == 0 && !inline) ControlGroup(title: 'MODULATION', color: Neon.violet, child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KnobRow(['lfo_amount', if (lfoFree) 'lfo_rate', 'env_amount'], size: 46, labels: const {
            'lfo_amount': 'LFO', 'lfo_rate': 'Rate', 'env_amount': 'Env'}),
          Row(children: [fieldLabel('SYNC'), const Flexible(child: DeviceChoice('lfo_sync', maxSegments: 0, color: Neon.violet))]),
        ])),
      if (v == 0 && !inline) DeviceFold(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ModeTiles('lfo_shape', height: 42, color: Neon.violet,
            names: const ['Sine', 'Tri', 'Up', 'Down', 'Square', 'S&H', 'Smooth'],
            icon: (canvas, r, i, c) => iconCurve(canvas, r.deflate(2), c, (x) {
              final ph = i >= 5 ? (x + 1) * 2 : (x + 1) / 2; // the random shapes over four steps
              return lfoValue(i, ph, cycle: ph.floor() + 3) * 0.9;
            }, steps: 60)),
          const KnobRow(['lfo_stereo', 'env_attack', 'env_release'], size: 44,
            labels: {'lfo_stereo': 'Stereo', 'env_attack': 'Attack', 'env_release': 'Release'}),
        ])),
      if (v == 1 && !inline) const DeviceFold(child: ParamGrid(only: ['bias', 'comp'])),
    ]);
  }
}

/// Every model in one strip: each variant's types as small curves under its name. A tap on another variant's
/// model switches the variant and sets its type in one undo step. Where it scrolls (a phone), it opens at the
/// variant played.
class FilterModelStrip extends StatefulWidget {
  const FilterModelStrip({super.key});

  @override
  State<FilterModelStrip> createState() => _FilterModelStripState();
}

class _FilterModelStripState extends State<FilterModelStrip> {
  static const _tile = 56.0, _gap = 10.0;
  final _scroll = ScrollController();
  int? _shown;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings variant [v]'s group into view once laid out (it starts after the groups before it).
  void _reveal(int v, List<int> counts) {
    if (_shown == v) return;
    _shown = v;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      var x = 0.0;
      for (var g = 0; g < v; g++) {
        x += counts[g] * _tile + _gap;
      }
      _scroll.jumpTo(x.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) => watchDevice(context, (context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final id = t.componentId;
    final base = id == null ? null : t.state.componentInfo(id);
    if (base == null || base.variants.length < 3) return const SizedBox.shrink();
    final v = (t.info?.variantIndex ?? 0).clamp(0, 2);
    final sel = t.value(_typeParam[v]).round();
    final c = scope.accent;
    Widget tile(int variant, int k, ComponentParameterInfo p) {
      final on = variant == v && k == sel;
      return Padding(padding: const EdgeInsets.only(right: 4), child: Semantics(
        button: true,
        selected: on,
        label: '${const ['Multimode', 'Ladder', 'Nonlinear'][variant]} ${p.choices[k]}',
        child: GestureDetector(
          key: ValueKey('filter-model-$variant-$k'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            DeviceFeel.tap();
            pickVariant(context, variant, also: {p.id: p.min + k});
          },
          child: Pressable(glow: c, child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            width: 52,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: on ? c.withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: on ? c : Neon.line, width: on ? 1.5 : 1),
              boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 8)] : null),
            child: Column(children: [
              Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 5, 6, 1), child: CustomPaint(size: Size.infinite,
                painter: _ModelIcon(variant, k, p.choices[k], on ? c : Neon.dim)))),
              Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(
                k < _short[variant].length ? _short[variant][k] : p.choices[k], maxLines: 1, overflow: TextOverflow.clip,
                style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: on ? Neon.text : Neon.dim))),
            ]),
          )),
        ),
      ));
    }

    Widget group(int variant) {
      final p = base.variants[variant].param(_typeParam[variant]);
      if (p == null || !p.isChoice) return const SizedBox.shrink();
      final names = base.param('variant')?.choices ?? const ['Multimode', 'Ladder', 'Nonlinear'];
      return Padding(padding: const EdgeInsets.only(right: 10), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text((variant < names.length ? names[variant] : '').toUpperCase(), style: TextStyle(fontSize: 9, letterSpacing: 1.2,
            fontWeight: FontWeight.w800, color: variant == v ? c : Neon.dim)),
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, children: [for (var k = 0; k < p.choices.length; k++) tile(variant, k, p)]),
        ]));
    }

    _reveal(v, [for (var g = 0; g < 3; g++) base.variants[g].param(_typeParam[g])?.choices.length ?? 0]);
    return SingleChildScrollView(
      key: const ValueKey('filter-models'),
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var g = 0; g < 3; g++) group(g)]),
    );
  });
}

class _ModelIcon extends CustomPainter {
  _ModelIcon(this.variant, this.k, this.label, this.color);
  final int variant, k;
  final String label;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    iconCurve(canvas, r, color, (x) {
      final hz = 1000 * math.pow(2, x * 4).toDouble();
      return switch (variant) {
        1 => ((toDb(ladderResponse(hz, cutoff: 1000, resonance: 0.6, mode: k, slope: 1).abs) + 6) / 20).clamp(-1.0, 1.0),
        2 => k == 4 ? -x * 0.8 : ((toDb(svfResponse(hz, cutoff: 1000, q: 2, type: k).abs) + 8) / 20).clamp(-1.0, 1.0),
        _ => ((filterResponseDb(hz, type: filterDrawType(label), cutoff: 1000, resonance: 0.5) + 6) / 20).clamp(-1.0, 1.0),
      };
    }, width: 1.5);
  }

  @override
  bool shouldRepaint(covariant _ModelIcon o) => o.variant != variant || o.k != k || o.color != color || o.label != label;
}

/// The puck hero: the response on the log grid with a big puck, across the cutoff and up the resonance (the
/// Nonlinear's Q). A drag anywhere moves it (a second finger: fine), a double-tap resets both. On Multimode the LFO's
/// sweep and the envelope's reach are drawn through the puck, and a ghost puck with the moving curve shows where the
/// modulation has it now: the engine's own cutoff and response while it plays, else the LFO run in the drawing.
class FilterPuckHero extends StatefulWidget {
  const FilterPuckHero({super.key, required this.variant});
  final int variant;

  @override
  State<FilterPuckHero> createState() => _FilterPuckHeroState();
}

class _FilterPuckHeroState extends State<FilterPuckHero> {
  static const _pad = 30.0;
  bool _active = false;
  double _x = 0, _y = 0;

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final v = widget.variant;
    final pc = t.param('cutoff'), pr = t.param(v == 2 ? 'q' : 'resonance');
    if (pc == null || pr == null) return const SizedBox.shrink();
    final tr = taperOf(pr);
    final typeP = t.param('type');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final span = h - 2 * _pad;
      double y(double db) => h * 0.55 - db / 36 * (h * 0.55 - 24);
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: ValueKey(const ['filter-hero', 'ladder-hero', 'nlfilter-hero'][v]),
        onStart: (_, _) {
          _x = freqToX(t.value(pc.id), w);
          _y = tr.position(t.value(pr.id));
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _x = (_x + u.delta.dx * fine).clamp(0.0, w);
          _y = (_y - u.delta.dy / span * fine).clamp(0.0, 1.0);
          t.setLive(pc.id, xToFreq(_x, w).clamp(pc.min, pc.max));
          t.setLive(pr.id, tr.value(_y));
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({pc.id: pc.defaultValue, pr.id: pr.defaultValue}),
        child: DevicePhase(builder: (context, secs) {
          final cut = t.value(pc.id);
          final puck = Offset(freqToX(cut, w), _pad + (1 - tr.position(t.value(pr.id))) * span);
          double? moved;
          List<double>? engine;
          if (v == 0) {
            final lfoAmt = t.value('lfo_amount');
            final sync = t.param('lfo_sync');
            final whole = sync == null ? null : _syncWhole[formatParamValue(sync, t.value('lfo_sync'))];
            final rate = whole != null ? t.state.project.bpm / 60 / (whole * 4) : t.value('lfo_rate');
            final shape = t.value('lfo_shape').round();
            moved = f?.values['cutoff_l'] ??
                (lfoAmt.abs() < 0.001 ? null : cut * math.pow(2, lfoAmt * 4 * lfoValue(shape, secs * rate, cycle: (secs * rate).floor())).toDouble());
            final points = f?.values['points']?.toInt() ?? 0;
            if (points > 1) engine = [for (var j = 0; j < points; j++) f!.values['r$j'] ?? 0];
          }
          return CustomPaint(size: Size(w, h), painter: _PuckPainter(
            db: (hz, c) => filterDb(v, hz, c, t.value, typeP),
            cut: cut, moved: moved, engine: engine, puck: puck, y: y,
            lfoAmt: v == 0 ? t.value('lfo_amount') : 0, envAmt: v == 0 ? t.value('env_amount') : 0,
            ring: tr.position(t.value(pr.id)),
            selfOsc: v == 1 && t.value('resonance') >= 0.91,
            fray: v == 2 && t.value('shape').round() != 0 ? (t.value('drive') / 36).clamp(0.0, 1.0) : 0,
            color: scope.accent, second: scope.secondary, active: _active, live: f != null));
        }),
      ));
    });
  }
}

class _PuckPainter extends CustomPainter {
  _PuckPainter({required this.db, required this.cut, required this.moved, required this.engine, required this.puck,
    required this.y, required this.lfoAmt, required this.envAmt, required this.ring, required this.selfOsc,
    required this.fray, required this.color, required this.second, required this.active, required this.live});
  final double Function(double hz, double cutoff) db;
  final double cut, lfoAmt, envAmt, ring, fray;
  final double? moved;
  final List<double>? engine;
  final Offset puck;
  final double Function(double db) y;
  final bool selfOsc, active, live;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    paintEqGrid(canvas, size, y, rangeDb: 12);
    // The LFO's sweep (violet) through the puck and the envelope's reach (green) under it.
    if (lfoAmt.abs() > 0.001) {
      final lo = freqToX(cut * math.pow(2, -lfoAmt.abs() * 4).toDouble(), w), hi = freqToX(cut * math.pow(2, lfoAmt.abs() * 4).toDouble(), w);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(lo, puck.dy - 9, hi, puck.dy + 9), const Radius.circular(9)),
        Paint()..color = Neon.violet.withValues(alpha: 0.16));
      paintLabel(canvas, 'LFO', Offset(lo + 6, puck.dy - 16), Neon.violet, size: 8, weight: FontWeight.w800);
    }
    if (envAmt.abs() > 0.001) {
      final to = freqToX(cut * math.pow(2, envAmt * 4).toDouble(), w);
      final yy = puck.dy + 22;
      canvas.drawLine(Offset(puck.dx, yy), Offset(to, yy), Paint()
        ..color = Neon.green
        ..strokeWidth = 2);
      canvas.drawCircle(Offset(to, yy), 3.5, Paint()..color = Neon.green);
      paintLabel(canvas, 'ENV', Offset(to + (to > puck.dx ? 6 : -6), yy), Neon.green, size: 8, align: to > puck.dx ? -1 : 1,
        weight: FontWeight.w800);
    }
    Path curve(double c) => responsePath(size, (hz) => db(hz, c), y, lo: -60, hi: 30);
    final set = curve(cut);
    final m = moved;
    final modulated = m != null && (m - cut).abs() > cut * 0.01;
    if (modulated) {
      canvas.drawPath(set, Paint()
        ..color = Neon.ink.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
      // The engine's response at the modulated cutoff while it plays (its 64 points), else the drawing's.
      final e = engine;
      final now = e == null ? curve(m) : (Path()..addPolygon([
        for (var j = 0; j < e.length; j++) Offset(w * j / (e.length - 1), y(e[j].clamp(-60.0, 30.0)).clamp(-4.0, h + 4)),
      ], false));
      fillFade(canvas, now, h, size, second, alpha: 0.25);
      strokeGlow(canvas, now, second, width: 2.2);
      final ghost = Offset(freqToX(m, w), puck.dy);
      canvas.drawLine(puck, ghost, Paint()
        ..color = second.withValues(alpha: 0.5)
        ..strokeWidth = 2);
      canvas.drawCircle(ghost, 9, Paint()..color = second.withValues(alpha: 0.35));
      canvas.drawCircle(ghost, 9, Paint()
        ..color = second
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    } else {
      fillFade(canvas, set, h, size, color, alpha: 0.3);
      strokeGlow(canvas, set, Color.lerp(color, second, fray)!, width: 2.4 + 2 * fray);
    }
    // A stem from the puck to the curve at the cutoff.
    final onCurve = Offset(puck.dx, y(db(cut, cut).clamp(-60.0, 30.0)).clamp(0.0, h));
    canvas.drawLine(puck, onCurve, Paint()
      ..color = color.withValues(alpha: 0.3)
      ..strokeWidth = 1);
    if (selfOsc) {
      // Self-oscillation: a sine rings at the cutoff whatever comes in.
      for (var k = 1; k <= 3; k++) {
        canvas.drawCircle(puck, 18.0 + k * 7, Paint()
          ..style = PaintingStyle.stroke
          ..color = second.withValues(alpha: 0.35 / k));
      }
    }
    // The puck: its ring fills with the resonance.
    final r = active ? 18.0 : 16.0;
    canvas.drawCircle(puck, r + 5, Paint()
      ..color = Neon.ink.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    canvas.drawArc(Rect.fromCircle(center: puck, radius: r + 5), -math.pi / 2, 2 * math.pi * ring.clamp(0.0, 1.0), false, Paint()
      ..color = second
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3);
    paintHandle(canvas, puck, color, active: active, r: r);
    if (live) paintLabel(canvas, '● LIVE', Offset(w - 8, 30), second, size: 8, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _PuckPainter o) => paintInputsChanged(
      [o.db, o.cut, o.moved, o.engine, o.puck, o.y, o.lfoAmt, o.envAmt, o.ring, o.selfOsc, o.fray, o.color, o.second, o.active, o.live],
      [db, cut, moved, engine, puck, y, lfoAmt, envAmt, ring, selfOsc, fray, color, second, active, live]);
}
