// An LFO's shape over two cycles with a dot running at its rate (or the tempo's division when synced); drag sideways for the rate.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../model/flagship_shapes.dart';
import '../../arrange/knob.dart' show Taper;
import '../../motion.dart';
import '../../theme.dart';
import '../device_scope.dart';
import 'grab.dart';

/// The LFO whose parameters are `<prefix>shape`, `rate` and `sync` (or, with [shapeParam] and [fixedShape], the
/// random source: `rnd_mode` picks sample-and-hold or smooth). The dot is drawn from the clock in Dart, not read
/// from the engine, so it shows the speed and shape rather than the voice's exact phase.
class LfoView extends StatefulWidget {
  const LfoView({super.key, required this.rateParam, this.shapeParam, this.syncParam, this.bpm = 120,
    this.height = 72, this.color, this.randomModeParam});
  final String rateParam;
  final String? shapeParam, syncParam, randomModeParam;
  final double bpm;
  final double height;
  final Color? color;

  @override
  State<LfoView> createState() => _LfoViewState();
}

class _LfoViewState extends State<LfoView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((e) => _clock.value = e.inMicroseconds / 1e6);
  final _clock = ValueNotifier<double>(0);
  double? _pos;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = Motion.of(context) == MotionLevel.full;
    if (run && !_ticker.isActive) _ticker.start();
    if (!run && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final color = widget.color ?? scope.accent;
    final rate = t.param(widget.rateParam);
    if (rate == null) return const SizedBox.shrink();
    final taper = Taper(rate.min, rate.max, exponential: rate.exponential);
    final shape = widget.randomModeParam != null
        ? (t.value(widget.randomModeParam!) >= 0.5 ? 6 : 5)
        : (widget.shapeParam == null ? 0 : t.value(widget.shapeParam!).round());
    final sync = widget.syncParam == null ? 0 : t.value(widget.syncParam!).round();
    final hz = lfoHz(t.value(rate.id), sync, widget.bpm);
    final readout = sync > 0 ? (t.param(widget.syncParam!)?.choices.elementAtOrNull(sync) ?? '') : formatParamValue(rate, t.value(rate.id));
    return GrabPan(
      key: ValueKey('lfo-${widget.rateParam}'),
      onStart: (_) => _pos = taper.position(t.value(rate.id)),
      onUpdate: (_, d) {
        if (sync > 0) return; // synced: the division sets the speed
        _pos = ((_pos ?? 0) + d.dx / 240).clamp(0.0, 1.0);
        t.setLive(rate.id, taper.value(_pos!));
      },
      onEnd: () {
        if (_pos != null) t.commit();
        _pos = null;
      },
      onDoubleTap: () => t.set(rate.id, rate.defaultValue),
      child: SizedBox(height: widget.height, child: RepaintBoundary(child: CustomPaint(
        painter: _LfoPainter(shape, hz, _clock, color),
        child: Align(alignment: Alignment.topRight, child: Padding(padding: const EdgeInsets.all(4),
          child: Text(readout, style: Neon.code(size: 9, color: color)))),
      ))),
    );
  }
}

class _LfoPainter extends CustomPainter {
  _LfoPainter(this.shape, this.hz, this.clock, this.color) : super(repaint: clock);
  final int shape;
  final double hz;
  final ValueNotifier<double> clock;
  final Color color;

  static const cycles = 2;

  double _at(double x) {
    final c = x * cycles;
    return lfoValue(shape, c, cycle: c.floor());
  }

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 6.0;
    final w = size.width - 2 * pad, h = size.height - 2 * pad;
    Offset pt(double x, double v) => Offset(pad + x * w, pad + h * (1 - (v + 1) / 2));
    canvas.drawLine(pt(0, 0), pt(1, 0), Paint()..color = Colors.white.withValues(alpha: 0.06));
    canvas.drawLine(pt(0.5, -1), pt(0.5, 1), Paint()..color = Colors.white.withValues(alpha: 0.04));
    final path = Path()..moveTo(pt(0, _at(0)).dx, pt(0, _at(0)).dy);
    const n = 160;
    for (var i = 1; i <= n; i++) {
      final x = i / n;
      final steps = shape == 4 || shape == 5;
      if (steps) {
        final prev = pt((i - 1) / n, _at((i - 1) / n));
        path.lineTo(pt(x, 0).dx, prev.dy);
      }
      final p = pt(x, _at(x - 1e-6));
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8);
    // The dot: one pass over the drawn cycles takes `cycles / hz` seconds.
    final phase = (clock.value * hz / cycles) % 1.0;
    final dot = pt(phase, _at(phase));
    canvas.drawCircle(dot, 9, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawCircle(dot, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _LfoPainter o) => o.shape != shape || o.hz != hz || o.color != color;
}
