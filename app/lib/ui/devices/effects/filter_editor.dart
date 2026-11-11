// The filter's plugin UI: its response with the cutoff handle, the LFO and envelope modulation drawn as a band and a moving curve,
// type and LFO-shape tiles.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/flagship_shapes.dart' show filterResponseDb, lfoValue;
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

/// `org.caw.filter`'s types as the drawing's shapes (flagship_shapes' numbering: ladder 0–2, SVF 3–6).
int filterDrawType(String label) {
  final l = label.toLowerCase();
  final ladder = l.contains('ladder');
  if (l.contains('notch')) return 6;
  if (l.contains('band')) return ladder ? 2 : 5;
  if (l.contains('high')) return ladder || l.contains('24') ? 1 : 4;
  return ladder || l.contains('24') ? 0 : 3;
}

String _shortType(String s) => s
    .replaceAll('Ladder low-pass', 'LAD LP')
    .replaceAll('Ladder high-pass', 'LAD HP')
    .replaceAll('Ladder band-pass', 'LAD BP')
    .replaceAll('Low-pass ', 'LP')
    .replaceAll('High-pass ', 'HP')
    .replaceAll('Band-pass', 'BP');

/// The filter: type tiles, the response (drag the handle: sideways the cutoff, up and down the resonance) with the
/// LFO's sweep shaded and the curve moving with the modulation, then its LFO and envelope follower.
class FilterPage extends StatelessWidget {
  const FilterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final types = t.param('type');
    final lfoOn = t.value('lfo_sync') < 0.5;
    return effectPage('filter', [
      if (types != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: ModeTiles('type', height: 50,
        names: [for (final c in types.choices) _shortType(c)],
        icon: (canvas, r, i, c) {
          final type = filterDrawType(types.choices[i]);
          iconCurve(canvas, r.deflate(1), c, (x) {
            final hz = 1000 * math.pow(2, x * 4).toDouble();
            return ((filterResponseDb(hz, type: type, cutoff: 1000, resonance: 0.5) + 6) / 20).clamp(-1.0, 1.0);
          });
        })),
      HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: 'FILTER ≈',
        grid: false,
        readout: Text('${formatParamValue(t.param('cutoff'), t.value('cutoff'))} Hz'),
        child: const _FilterHero(),
      )),
      const KnobRow(['cutoff', 'resonance', 'drive', 'mix'], size: 54),
      ControlGroup(title: 'LFO', color: Neon.violet, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ModeTiles('lfo_shape', height: 42, color: Neon.violet,
          names: const ['Sine', 'Tri', 'Up', 'Down', 'Square', 'S&H', 'Smooth'],
          icon: (canvas, r, i, c) => iconCurve(canvas, r.deflate(2), c, (x) {
            final ph = i >= 5 ? (x + 1) * 2 : (x + 1) / 2; // the random shapes over four steps
            return lfoValue(i, ph, cycle: ph.floor() + 3) * 0.9;
          }, steps: 60)),
        const SizedBox(height: 4),
        Row(children: [
          const Text('SYNC', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 8),
          const DeviceChoice('lfo_sync', maxSegments: 0, color: Neon.violet),
        ]),
        KnobRow(['lfo_amount', if (lfoOn) 'lfo_rate', 'lfo_stereo'], size: 46,
          labels: const {'lfo_amount': 'Amount', 'lfo_rate': 'Rate', 'lfo_stereo': 'Stereo'}),
      ])),
      ControlGroup(title: 'ENVELOPE', color: Neon.green, child: const KnobRow(['env_amount', 'env_attack', 'env_release'], size: 46,
        labels: {'env_amount': 'Amount', 'env_attack': 'Attack', 'env_release': 'Release'})),
    ]);
  }
}

class _FilterHero extends StatefulWidget {
  const _FilterHero();

  @override
  State<_FilterHero> createState() => _FilterHeroState();
}

class _FilterHeroState extends State<_FilterHero> {
  bool _active = false;
  double _x = 0, _res = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final cut = t.value('cutoff'), res = t.value('resonance');
    final tp = t.param('type');
    final type = tp == null ? 3 : filterDrawType(formatParamValue(tp, t.value('type')));
    final lfoAmt = t.value('lfo_amount'), envAmt = t.value('env_amount');
    final sync = t.param('lfo_sync');
    final whole = sync == null ? null : syncWholeNotes[formatParamValue(sync, t.value('lfo_sync'))];
    final rate = whole != null ? 60 / t.state.project.bpm / (whole * 4) : t.value('lfo_rate');
    final shape = t.value('lfo_shape').round();
    final mix = t.param('mix') == null ? 1.0 : t.value('mix');
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      double y(double db) => h * 0.5 - db / 30 * (h * 0.5 - 22);
      return DeviceDisplay(builder: (context, f) => GrabGesture(
        key: const ValueKey('filter-hero'),
        onStart: (p, _) {
          _x = freqToX(cut, w);
          _res = res;
          setState(() => _active = true);
        },
        onUpdate: (u) {
          final fine = DeviceFingers.fine;
          _x = (_x + u.delta.dx * fine).clamp(0.0, w);
          _res = (_res - u.delta.dy / (h * 0.8) * fine).clamp(0.0, 1.0);
          t.setLive('cutoff', xToFreq(_x, w));
          t.setLive('resonance', _res);
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.setAll({
          for (final id in ['cutoff', 'resonance']) if (t.param(id) case final p?) id: p.defaultValue,
        }),
        child: DevicePhase(builder: (context, secs) {
          // The cutoff now: the engine's (modulated) while it plays, else the LFO run in the drawing.
          final live = f?.values['cutoff_l'];
          final moved = live ?? cut * math.pow(2, lfoAmt * 4 * lfoValue(shape, secs * rate, cycle: (secs * rate).floor())).toDouble();
          return CustomPaint(size: Size(w, h), painter: _FilterPainter(
            // The dry blend lifts the stop band (magnitudes added, phase ignored).
            response: (hz, c) {
              final wet = math.pow(10, filterResponseDb(hz, type: type, cutoff: c, resonance: res) / 20).toDouble();
              return 20 * math.log(math.max(1e-6, mix * wet + 1 - mix)) / math.ln10;
            },
            cut: cut, moved: moved, lfoAmt: lfoAmt, envAmt: envAmt, y: y, color: scope.accent, second: scope.secondary,
            active: _active, live: live != null));
        }),
      ));
    });
  }
}

class _FilterPainter extends CustomPainter {
  _FilterPainter({required this.response, required this.cut, required this.moved, required this.lfoAmt,
    required this.envAmt, required this.y, required this.color, required this.second, required this.active, required this.live});
  final double Function(double hz, double cutoff) response;
  final double cut, moved, lfoAmt, envAmt;
  final double Function(double db) y;
  final Color color, second;
  final bool active, live;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.05);
    for (final (hz, l) in [(100.0, '100'), (1000.0, '1k'), (10000.0, '10k')]) {
      canvas.drawLine(Offset(freqToX(hz, w), 0), Offset(freqToX(hz, w), h), grid);
      paintLabel(canvas, l, Offset(freqToX(hz, w) + 3, h - 7), Neon.dim, size: 8);
    }
    canvas.drawLine(Offset(0, y(0)), Offset(w, y(0)), Paint()..color = Colors.white.withValues(alpha: 0.1));
    // The LFO's sweep (violet) and the envelope's reach (green) as bands of cutoffs.
    if (lfoAmt.abs() > 0.001) {
      final lo = freqToX(cut * math.pow(2, -lfoAmt.abs() * 4).toDouble(), w), hi = freqToX(cut * math.pow(2, lfoAmt.abs() * 4).toDouble(), w);
      canvas.drawRect(Rect.fromLTRB(lo, 22, hi, h), Paint()..color = Neon.violet.withValues(alpha: 0.12));
      paintLabel(canvas, 'LFO', Offset((lo + hi) / 2, 30), Neon.violet, size: 8, align: 0, weight: FontWeight.w800);
    }
    if (envAmt.abs() > 0.001) {
      final to = freqToX(cut * math.pow(2, envAmt * 4).toDouble(), w);
      final from = freqToX(cut, w);
      final yy = h - 22;
      canvas.drawLine(Offset(from, yy), Offset(to, yy), Paint()
        ..color = Neon.green
        ..strokeWidth = 2);
      canvas.drawCircle(Offset(to, yy), 3.5, Paint()..color = Neon.green);
      paintLabel(canvas, 'ENV', Offset(to + (to > from ? 6 : -6), yy), Neon.green, size: 8, align: to > from ? -1 : 1, weight: FontWeight.w800);
    }
    Path curve(double c) {
      final p = Path();
      for (var i = 0; i <= 160; i++) {
        final x = w * i / 160;
        final py = y(response(xToFreq(x, w), c).clamp(-60.0, 30.0)).clamp(-4.0, h + 4);
        i == 0 ? p.moveTo(x, py) : p.lineTo(x, py);
      }
      return p;
    }

    final modulated = (moved - cut).abs() > cut * 0.01;
    final set = curve(cut);
    if (modulated) {
      canvas.drawPath(set, Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
      final now = curve(moved);
      fillFade(canvas, now, h, size, second, alpha: 0.25);
      strokeGlow(canvas, now, second, width: 2.2);
    } else {
      fillFade(canvas, set, h, size, color, alpha: 0.3);
      strokeGlow(canvas, set, color, width: 2.4);
    }
    final hx = freqToX(cut, w);
    final hy = y(response(cut, cut).clamp(-60.0, 30.0)).clamp(28.0, h - 16);
    paintHandle(canvas, Offset(hx, hy), color, active: active, r: 8);
    if (live) paintLabel(canvas, '● LIVE', Offset(w - 8, 30), second, size: 8, align: 1, weight: FontWeight.w800);
  }

  @override
  bool shouldRepaint(covariant _FilterPainter o) => true;
}
