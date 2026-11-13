// The modulation family's plugin UIs: phaser and flanger (their notch combs sweeping with the LFO, left and right) and chorus
// (its two voices' delay sweeps on an XY pad of rate and depth).
import '../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import '../visuals/filter_curve.dart' show freqToX, xToFreq;
import 'effect_page.dart';
import 'space_editors.dart' show syncWholeNotes;

/// The LFO rate in Hz of a device with `rate` and a `sync` choice (Off, 1/16 .. 4 bars).
double modRateHz(DeviceScope scope, {String rate = 'rate', String sync = 'sync'}) {
  final t = scope.target;
  final p = t.param(sync);
  final whole = p == null ? null : syncWholeNotes[formatParamValue(p, t.value(sync))];
  return whole != null ? t.state.project.bpm / 60 / (whole * 4) : (t.param(rate) == null ? 0.5 : t.value(rate));
}

/// |dry·(1 − mix) + mix·wet| in dB, where wet = A / (1 − g·A) and A has unit magnitude and phase [phase]: the
/// response of a phaser (all-pass phase) or a flanger (a delay's phase) with feedback [g].
double combDb(double phase, double g, double mix) {
  final ar = math.cos(phase), ai = math.sin(phase);
  // 1 − g·A
  final dr = 1 - g * ar, di = -g * ai;
  final den = dr * dr + di * di;
  // A / (1 − gA)
  final wr = (ar * dr + ai * di) / den, wi = (ai * dr - ar * di) / den;
  final m = mix.clamp(0.0, 1.0);
  final or = (1 - m) + m * wr, oi = m * wi;
  return 20 * math.log(math.max(1e-5, math.sqrt(or * or + oi * oi))) / math.ln10;
}

/// The phaser and the flanger: the comb (drag sideways for the centre or delay, up and down for the feedback), its
/// left and right sweeps moving with the LFO, then rate, depth and the rest.
class CombPage extends StatelessWidget {
  const CombPage({super.key, required this.flanger});
  final bool flanger;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final free = t.value('sync') < 0.5;
    return effectPage(flanger ? 'flanger' : 'phaser', [
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: flanger ? 'FLANGER ≈' : 'PHASER ≈',
        grid: false,
        readout: Builder(builder: (context) => Text(flanger ? '${formatParamValue(t.param('delay'), t.value('delay'))} ms'
            : '${formatParamValue(t.param('center'), t.value('center'))} Hz')),
        child: _CombHero(flanger: flanger),
      )),
      Row(children: [
        if (!flanger) ...[
          const Text('STAGES', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 8),
          const Flexible(child: DeviceChoice('stages', maxSegments: 6)),
          const SizedBox(width: 12),
        ],
        const Text('SYNC', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
        const SizedBox(width: 8),
        const DeviceChoice('sync', maxSegments: 0),
      ]),
      KnobRow([if (free) 'rate', 'depth', flanger ? 'delay' : 'center', 'feedback', 'stereo', 'mix'], size: 50),
    ]);
  }
}

class _CombHero extends StatefulWidget {
  const _CombHero({required this.flanger});
  final bool flanger;

  @override
  State<_CombHero> createState() => _CombHeroState();
}

class _CombHeroState extends State<_CombHero> {
  bool _active = false;
  double _x = 0, _fb = 0;

  String get _place => widget.flanger ? 'delay' : 'center';

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final place = t.value(_place), fb = t.value('feedback'), depth = t.value('depth');
    final stereo = t.value('stereo'), mix = t.param('mix') == null ? 0.5 : t.value('mix');
    final stagesP = t.param('stages');
    final stages = stagesP == null ? 4 : int.tryParse(formatParamValue(stagesP, t.value('stages'))) ?? 4;
    final rate = modRateHz(scope);
    final pp = t.param(_place);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: ValueKey('${widget.flanger ? 'flanger' : 'phaser'}-hero'),
        onStart: (_, _) {
          _x = pp == null ? 0 : taperOf(pp).position(place);
          _fb = fb;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          if (pp != null) {
            _x = (_x + u.delta.dx / w * fine).clamp(0.0, 1.0);
            t.setLive(pp.id, taperOf(pp).value(_x));
          }
          _fb = (_fb - u.delta.dy / (h * 0.8) * 1.9 * fine).clamp(-0.95, 0.95);
          t.setLive('feedback', _fb);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in [_place, 'feedback']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: DevicePhase(builder: (context, secs) {
          // Left and right now: the engine's while it plays, else a sine LFO run here, the right side `stereo`
          // half-cycles behind.
          double lfo(double offset) => math.sin(2 * math.pi * (secs * rate - offset));
          final double l, r;
          if (widget.flanger) {
            l = f?.values['delay_l_ms'] ?? place * (1 + 0.95 * depth * lfo(0));
            r = f?.values['delay_r_ms'] ?? place * (1 + 0.95 * depth * lfo(stereo * 0.5));
          } else {
            l = f?.values['freq_l'] ?? place * math.pow(2, 3 * depth * lfo(0)).toDouble();
            r = f?.values['freq_r'] ?? place * math.pow(2, 3 * depth * lfo(stereo * 0.5)).toDouble();
          }
          double response(double hz, double at) => widget.flanger
              ? combDb(-2 * math.pi * hz * at / 1000, fb, mix)
              : combDb(-2 * stages * math.atan(hz / at), fb, mix);
          return CustomPaint(size: Size(w, h), painter: _CombPainter(response: response, left: l, right: r, set: place,
              color: scope.accent, second: scope.secondary, active: _active, flanger: widget.flanger, fb: fb));
        }),
      ));
    });
  }
}

class _CombPainter extends CustomPainter {
  _CombPainter({required this.response, required this.left, required this.right, required this.set, required this.color,
    required this.second, required this.active, required this.flanger, required this.fb});
  final double Function(double hz, double at) response;
  final double left, right, set, fb;
  final Color color, second;
  final bool active, flanger;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    double y(double db) => 30 + (h - 40) * (1 - ((db + 30) / 42).clamp(0.0, 1.0));
    // A phaser on the log axis; a flanger's comb on a linear one up to its sixth notch at the set delay, so the
    // teeth are seen to squeeze and spread as the delay sweeps.
    final fMax = 6 / math.max(0.05, set) * 1000;
    double fx(double hz) => flanger ? w * hz / fMax : freqToX(hz, w);
    double xf(double x) => flanger ? fMax * x / w : xToFreq(x, w);
    final marks = flanger
        ? [for (var k = 1; k <= 3; k++) (fMax * k / 4, '${(fMax * k / 4000).toStringAsFixed(1)}k')]
        : [(100.0, '100'), (1000.0, '1k'), (10000.0, '10k')];
    for (final (hz, l) in marks) {
      canvas.drawLine(Offset(fx(hz), 0), Offset(fx(hz), h), Paint()..color = Neon.ink.withValues(alpha: 0.05));
      paintLabel(canvas, l, Offset(fx(hz) + 3, h - 7), Neon.dim, size: 8);
    }
    Path curve(double at) {
      final p = Path();
      const n = 240;
      for (var i = 0; i <= n; i++) {
        final x = w * i / n;
        final py = y(response(math.max(1, xf(x)), at));
        i == 0 ? p.moveTo(x, py) : p.lineTo(x, py);
      }
      return p;
    }

    final r = curve(right);
    final l = curve(left);
    canvas.drawPath(r, Paint()
      ..color = second.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);
    fillFade(canvas, l, h, size, color, alpha: 0.22);
    strokeGlow(canvas, l, color, width: 2);
    paintLabel(canvas, 'L', Offset(10, 34), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(22, 34), second, size: 9, weight: FontWeight.w800);
    // The set point, where the handle is.
    final hx = flanger ? fx(1000 / math.max(0.05, set) / 2) : fx(set);
    paintHandle(canvas, Offset(hx.clamp(10.0, w - 10), y(0) - fb * 30), color, active: active, r: 7);
    paintLabel(canvas, 'FB ${(fb * 100).round()}%', Offset(w - 8, h - 18), active ? Neon.text : color, size: 9, align: 1,
        weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _CombPainter o) =>
      paintInputsChanged([o.response, o.left, o.right, o.set, o.fb, o.color, o.second, o.active, o.flanger], [response, left, right, set, fb, color, second, active, flanger]);
}

/// The chorus: its two voices' delay sweeps (left and right a quarter cycle apart) drawn on an XY pad of rate
/// (sideways) and depth (up).
class ChorusPage extends StatelessWidget {
  const ChorusPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return effectPage('chorus', [
      DevicePhase(builder: (context, secs) => XYPad(
        xParam: 'rate', yParam: 'depth', height: 220, caption: 'CHORUS',
        painter: (dot) => _ChorusPainter(secs: secs, rate: t.value('rate'), depth: t.value('depth'), mix: t.value('mix'),
          color: scope.accent, second: scope.secondary))),
      const KnobRow(['rate', 'depth', 'mix'], size: 58),
    ]);
  }
}

class _ChorusPainter extends CustomPainter {
  _ChorusPainter({required this.secs, required this.rate, required this.depth, required this.mix, required this.color,
    required this.second});
  final double secs, rate, depth, mix;
  final Color color, second;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height * 0.55, amp = size.height * 0.32 * depth;
    // Two seconds of each voice's delay, the newest at the right.
    for (final (offset, c) in [(0.0, color), (0.25, second)]) {
      final p = Path();
      for (var i = 0; i <= 120; i++) {
        final x = size.width * i / 120;
        final t = secs - 2 * (1 - i / 120);
        final yy = mid - amp * math.sin(2 * math.pi * (t * rate - offset));
        i == 0 ? p.moveTo(x, yy) : p.lineTo(x, yy);
      }
      canvas.drawPath(p, Paint()
        ..color = c.withValues(alpha: 0.25 + 0.6 * mix)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round);
      final now = mid - amp * math.sin(2 * math.pi * (secs * rate - offset));
      canvas.drawCircle(Offset(size.width - 4, now), 4, Paint()..color = c);
    }
    paintLabel(canvas, 'L', Offset(10, size.height - 12), color, size: 9, weight: FontWeight.w800);
    paintLabel(canvas, 'R', Offset(22, size.height - 12), second, size: 9, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _ChorusPainter o) =>
      paintInputsChanged([o.secs, o.rate, o.depth, o.mix, o.color, o.second], [secs, rate, depth, mix, color, second]);
}
