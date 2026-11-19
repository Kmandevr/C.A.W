// The Limiter device page (org.caw.limiter, 1.0.8): the ceiling over the level history, a big gain-reduction meter, ceiling, release, ISP and (1.1.0) the loudness target.
import '../../kit/repaint.dart';

import 'package:flutter/material.dart';

import '../../../../model/device_display.dart';
import '../../../motion.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/grab_gesture.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';

/// The Limiter: its level history with the ceiling line (drag it; elsewhere up and down pushes the input gain),
/// and beside it a big gain-reduction meter (now in yellow, the most since the last publish as a tick, the number
/// under it). Then gain, ceiling and release, the ISP (true peak) switch, the loudness area ([LimiterLoudness]: a
/// LUFS target the engine only reports against, never applies) and look-ahead under MORE.
class LimiterDevice extends StatelessWidget {
  const LimiterDevice({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final inline = DeviceScope.isInline(context);
    final hero = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: HeroCanvas(
        color: scope.accent,
        height: 210,
        caption: 'LIMITER',
        grid: false,
        readout: const LevelReadout(),
        child: const _LimiterHero(),
      )),
      const SizedBox(width: 8),
      Builder(builder: (context) => _BigGrMeter(height: heroHeight(context, 210), width: inline ? 54 : 70)),
    ]);
    if (inline) return effectPage('limiter', [hero, const KnobRow(['gain', 'ceiling', 'release'], size: 44)]);
    return effectPage('limiter', [
      hero,
      const KnobRow(['gain', 'ceiling', 'release'], size: 58),
      Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, children: const [
        DeviceToggle('true_peak', label: 'ISP (true peak)', icon: Icons.insights),
      ])),
      const LimiterLoudness(),
      const DeviceFold(child: ParamGrid(only: ['lookahead'])),
    ]);
  }
}

/// The Limiter's loudness area (1.1.0): the target switch and its LUFS, and the output's short-term and integrated
/// loudness with how far each is from the target (display floats 7-12; the engine sends -200 while off or not yet
/// measured, shown as "—"). Integrated counts from when the target turned on or the last Play. Only a readout: the
/// Limiter never moves its gain for it. Nothing on an engine without the target.
class LimiterLoudness extends StatelessWidget {
  const LimiterLoudness({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    if (t.param('target_on') == null) return const SizedBox.shrink();
    final on = t.value('target_on') >= 0.5;
    return Padding(padding: const EdgeInsets.only(top: 8), child: Container(
      key: const ValueKey('limiter-loudness'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scope.accent.withValues(alpha: 0.25))),
      child: Row(children: [
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('LOUDNESS', style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(height: 4),
          const DeviceToggle('target_on', label: 'Target', icon: Icons.track_changes),
        ]),
        const SizedBox(width: 8),
        AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: on ? 1 : 0.45,
          child: const DeviceKnob('target', size: 44, label: 'LUFS')),
        const SizedBox(width: 10),
        Expanded(child: DeviceDisplay(builder: (context, f) {
          final v = f?.values ?? const <String, double>{};
          final live = on && (v['target_on'] ?? 0) >= 0.5;
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _LoudnessLine(key: const ValueKey('limiter-lufs-short'), label: 'Short-term',
              lufs: live ? v['short_lufs'] : null, from: live ? v['short_from_target'] : null),
            const SizedBox(height: 4),
            _LoudnessLine(key: const ValueKey('limiter-lufs-integrated'), label: 'Integrated',
              lufs: live ? v['integrated_lufs'] : null, from: live ? v['integrated_from_target'] : null),
          ]);
        })),
      ]),
    ));
  }
}

/// One loudness reading: "Short-term  −15.2 LUFS  +0.8 LU" (the distance green within 1 LU of the target).
class _LoudnessLine extends StatelessWidget {
  const _LoudnessLine({super.key, required this.label, required this.lufs, required this.from});
  final String label;
  final double? lufs, from;

  @override
  Widget build(BuildContext context) {
    final d = loudnessDistance(from);
    final near = from != null && from! > -100 && from!.abs() <= 1;
    return FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 62, child: Text(label, style: const TextStyle(fontSize: 9.5, color: Neon.dim))),
      Text(formatLufs(lufs), style: Neon.code(size: 11, color: Neon.text)),
      const SizedBox(width: 8),
      Text(d, style: Neon.code(size: 10, color: d == '' ? Neon.dim : near ? Neon.green : Neon.yellow)),
    ]));
  }
}

/// A loudness as the Limiter shows it: "−14.2 LUFS", "—" for none (the engine's −200, or no reading).
String formatLufs(double? lufs) {
  if (lufs == null || !lufs.isFinite || lufs <= -100) return '— LUFS';
  return '${lufs < 0 ? '−' : ''}${lufs.abs().toStringAsFixed(1)} LUFS';
}

/// The distance from the target as the Limiter shows it: "+0.8 LU", "−2.1 LU", '' for none.
String loudnessDistance(double? lu) {
  if (lu == null || !lu.isFinite || lu <= -100) return '';
  final v = (lu * 10).round() / 10;
  return '${v > 0 ? '+' : v < 0 ? '−' : '±'}${v.abs().toStringAsFixed(1)} LU';
}

/// The gain reduction now as a tall bar from the top (0..12 dB), the most since the last frame as a tick, and the
/// number under it.
class _BigGrMeter extends StatelessWidget {
  const _BigGrMeter({required this.height, required this.width});
  final double height, width;

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) => Container(
    key: const ValueKey('limiter-gr-meter'),
    width: width,
    height: height - 10,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      color: Color.lerp(Neon.bg, Neon.yellow, 0.05),
      border: Border.all(color: Neon.yellow.withValues(alpha: 0.3))),
    child: CustomPaint(painter: _GrPainter(-(f?.gainReductionDb ?? 0), f?.values['gr_max'], f != null)),
  ));
}

class _GrPainter extends CustomPainter {
  _GrPainter(this.gr, this.most, this.live);
  final double gr;
  final double? most;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    const full = 12.0;
    final bar = Rect.fromLTRB(size.width / 2 - 9, 22, size.width / 2 + 9, size.height - 40);
    canvas.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(5)), Paint()..color = Neon.ink.withValues(alpha: 0.06));
    for (final db in [3.0, 6.0, 9.0]) {
      final y = bar.top + db / full * bar.height;
      canvas.drawLine(Offset(bar.left - 4, y), Offset(bar.left, y), Paint()..color = Neon.dim);
      paintLabel(canvas, db.toStringAsFixed(0), Offset(bar.left - 6, y), Neon.dim, size: 7, align: 1);
    }
    final g = gr.clamp(0.0, full);
    if (g > 0) {
      final fill = Rect.fromLTRB(bar.left, bar.top, bar.right, bar.top + g / full * bar.height);
      canvas.drawRRect(RRect.fromRectAndRadius(fill, const Radius.circular(5)), Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: Neon.ramp([Neon.yellow.withValues(alpha: 0.95), Neon.yellow.withValues(alpha: 0.55)])).createShader(fill));
    }
    if (most case final m? when m > 0.05) {
      final y = bar.top + (m.clamp(0.0, full) / full) * bar.height;
      canvas.drawLine(Offset(bar.left - 2, y), Offset(bar.right + 2, y), Paint()
        ..color = Neon.pink
        ..strokeWidth = 2);
    }
    paintLabel(canvas, 'GR', Offset(size.width / 2, 11), Neon.yellow, size: 9, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, live ? '−${g.toStringAsFixed(1)}' : '—', Offset(size.width / 2, size.height - 26), Neon.text,
        size: 15, align: 0, weight: FontWeight.w800);
    paintLabel(canvas, 'dB', Offset(size.width / 2, size.height - 11), Neon.dim, size: 8, align: 0);
  }

  @override
  bool shouldRepaint(covariant _GrPainter o) => o.gr != gr || o.most != most || o.live != live;
}

class _LimiterHero extends StatefulWidget {
  const _LimiterHero();

  @override
  State<_LimiterHero> createState() => _LimiterHeroState();
}

class _LimiterHeroState extends State<_LimiterHero> {
  bool? _ceiling;
  double _v = 0;

  static List<double> _pick(DeviceDisplayFrame f) => [f.inputDb ?? -120, f.outputDb ?? -120, -(f.gainReductionDb ?? 0)];

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
      return HistoryRecorder(lanes: 3, pick: _pick, builder: (context, hist, f) => GrabGesture(
        key: const ValueKey('limiter-hero'),
        onStart: (p, _) {
          _ceiling = (p.dy - y(ceiling)).abs() < 26;
          _v = _ceiling! ? ceiling : gain;
          DeviceFeel.grab();
          setState(() {});
        },
        onUpdate: (u) {
          _v += -u.delta.dy / area.height * 24 * DeviceFingers.fine;
          t.setLive(_ceiling == true ? 'ceiling' : 'gain', _v);
        },
        onEnd: () {
          t.commit();
          DeviceFeel.release();
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
    final output = Path();
    final gr = Path()..moveTo(area.right, area.top);
    for (var age = 0; age < n; age++) {
      final x = area.right - age * dx;
      input.lineTo(x, y(hist.at(0, age)).clamp(area.top, area.bottom));
      final oy = y(hist.at(1, age)).clamp(area.top, area.bottom);
      age == 0 ? output.moveTo(x, oy) : output.lineTo(x, oy);
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
          colors: Neon.ramp([color.withValues(alpha: 0.1), color.withValues(alpha: 0.45)])).createShader(area));
    canvas.drawPath(output, Paint()
      ..color = Neon.ink.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
    canvas.drawPath(gr, Paint()..color = Neon.yellow.withValues(alpha: 0.5));
    canvas.restore();
    for (final db in [-6.0, -12.0, -18.0]) {
      canvas.drawLine(Offset(0, y(db)), Offset(area.right, y(db)), Paint()..color = Neon.ink.withValues(alpha: 0.05));
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
  bool shouldRepaint(covariant _LimiterPainter o) =>
      paintInputsChanged([o.hist, o.area, o.y, o.ceiling, o.gain, o.color, o.active], [hist, area, y, ceiling, gain, color, active]);
}
