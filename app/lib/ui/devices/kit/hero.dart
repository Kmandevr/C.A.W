// A device's hero visual frame (a tinted canvas with a grid and readouts), live display frames, a running phase for motion, and a level history.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../model/device_display.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_scope.dart';

final _idle = ValueNotifier<DeviceDisplayFrame?>(null);

/// Builds [builder] with the device's newest display frame (null until the engine plays the device, and while the
/// device is off screen).
class DeviceDisplay extends StatelessWidget {
  const DeviceDisplay({super.key, required this.builder});
  final Widget Function(BuildContext context, DeviceDisplayFrame? frame) builder;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    // Off screen (an inline device scrolled away, a covered route) nothing listens, so nothing is polled.
    final live = TickerMode.valuesOf(context).enabled;
    return ValueListenableBuilder<DeviceDisplayFrame?>(
        valueListenable: live ? DeviceDisplaySource.current.frames(t) : _idle, builder: (context, f, _) => builder(context, f));
  }
}

/// The frame of a device's one big visual: a rounded canvas tinted with [color], a faint grid, a short [caption]
/// at the top left ("≈" marks a drawing computed from the knobs) and [readout] at the top right.
class HeroCanvas extends StatelessWidget {
  const HeroCanvas({super.key, required this.child, required this.color, this.height = 180, this.caption,
    this.readout, this.grid = true});
  final Widget child;
  final Color color;
  final double height;
  final String? caption;
  final Widget? readout;
  final bool grid;

  @override
  Widget build(BuildContext context) => Container(
    height: heroHeight(context, height),
    margin: const EdgeInsets.only(bottom: 10),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: Neon.ramp([
        Color.lerp(Neon.bg, color, 0.10)!.withValues(alpha: 0.92),
        Color.lerp(Neon.bg, color, 0.03)!.withValues(alpha: 0.92),
      ])),
      border: Border.all(color: color.withValues(alpha: 0.35)),
      boxShadow: Neon.flat ? null : [BoxShadow(color: color.withValues(alpha: 0.12), blurRadius: 18)],
    ),
    child: Stack(fit: StackFit.expand, children: [
      if (grid) CustomPaint(painter: _GridPainter(color)),
      child,
      if (caption != null) Positioned(left: 10, top: 6, child: IgnorePointer(child: Text(caption!,
        style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: color.withValues(alpha: 0.75))))),
      if (readout != null) Positioned(right: 10, top: 6, child: IgnorePointer(child: DefaultTextStyle(
        style: Neon.code(size: 10, color: Neon.text), child: readout!))),
    ]),
  );
}

/// A hero's height on this screen: [base], grown toward a third of a tall screen (a phone in portrait), at most
/// half again; inline in the FX stack, compact ([inlineHeroHeight]).
double heroHeight(BuildContext context, double base) => DeviceScope.isInline(context)
    ? inlineHeroHeight(context, base)
    : math.max(base, math.min(base * 1.45, MediaQuery.sizeOf(context).height * 0.33));

/// A hero's compact height in the FX stack: 140–176 dp, lower on a short screen (a phone in landscape) so a whole
/// device fits the panel.
double inlineHeroHeight(BuildContext context, double base) =>
    math.min((base * 0.8).clamp(140.0, 176.0), math.max(100.0, MediaQuery.sizeOf(context).height * 0.3));

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color.withValues(alpha: 0.06);
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter o) => o.color != color;
}

/// Seconds since a visual's motion started, advanced about 30 times a second: the display data's rate. A Ticker
/// would ask for a frame on every screen refresh (120 a second on the S22+) for motion drawn at 30 (#174); this asks
/// for one frame per step, reads the frame's time (the clock a Ticker reads, so tests stay deterministic), and makes
/// no frames at all while stopped ([run] false) or while the app is in the background.
class MotionClock {
  final ValueNotifier<double> seconds = ValueNotifier(0);
  Timer? _timer;
  Duration? _start;
  bool _pending = false, _disposed = false;

  bool get running => _timer != null;

  /// Starts or stops the clock; stopped, it starts from 0 again next time.
  void run(bool on) {
    if (on == running || _disposed) return;
    if (!on) {
      _timer!.cancel();
      _timer = null;
      _start = null;
      return;
    }
    _timer = Timer.periodic(const Duration(microseconds: 33333), (_) => _step());
    _step();
  }

  void _step() {
    final b = SchedulerBinding.instance;
    if (_pending || (b.lifecycleState != null && b.lifecycleState != AppLifecycleState.resumed)) return;
    _pending = true;
    b.scheduleFrameCallback((stamp) {
      _pending = false;
      if (_disposed || _timer == null) return;
      final start = _start ??= stamp;
      seconds.value = (stamp - start).inMicroseconds / 1e6;
    });
    b.scheduleFrame();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    seconds.dispose();
  }
}

/// Whether motion may run under [context]: full motion, and the part of the screen shown (not a dormant section or
/// a covered route, whose tickers are off).
bool motionRuns(BuildContext context) => Motion.of(context) == MotionLevel.full && TickerMode.valuesOf(context).enabled;

/// Seconds since the visual started, for motion that shows state (a ping-pong ball, a sweeping notch, an LFO dot).
/// It runs only with full motion (so the Minimal profile and reduced motion stop it), and redraws at about 30 Hz,
/// the display data's rate, to keep the editor light on CPU ([MotionClock]); otherwise [builder] gets a fixed time.
class DevicePhase extends StatefulWidget {
  const DevicePhase({super.key, required this.builder, this.still = 0.35});
  final Widget Function(BuildContext context, double seconds) builder;

  /// The time drawn when motion is off.
  final double still;

  @override
  State<DevicePhase> createState() => _DevicePhaseState();
}

class _DevicePhaseState extends State<DevicePhase> {
  final _clock = MotionClock();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clock.run(motionRuns(context));
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: _clock.seconds,
    builder: (context, t, _) => widget.builder(context, _clock.running ? t : widget.still));
}

/// The last [length] values of a few lanes (input level, gain reduction...), newest last: a scrolling history.
class LevelHistory {
  LevelHistory(this.lanes, {this.length = 150, double fill = -120})
      : _data = List.generate(lanes, (_) => Float32List(length)..fillRange(0, length, fill));
  final int lanes, length;
  final List<Float32List> _data;
  int _head = 0; // the next write

  void push(List<double> values) {
    for (var l = 0; l < lanes; l++) {
      _data[l][_head] = l < values.length ? values[l] : _data[l][(_head - 1) % length];
    }
    _head = (_head + 1) % length;
  }

  /// Lane [lane]'s value [age] frames ago (0 is the newest).
  double at(int lane, int age) => _data[lane][(_head - 1 - age) % length];
}

/// Feeds a [LevelHistory] from the device's display frames ([pick] gives the lanes of one frame) and rebuilds
/// [builder] on each frame. With no live data, the history stays as it was.
class HistoryRecorder extends StatefulWidget {
  const HistoryRecorder({super.key, required this.lanes, required this.pick, required this.builder, this.length = 150});
  final int lanes, length;
  final List<double>? Function(DeviceDisplayFrame f) pick;
  final Widget Function(BuildContext context, LevelHistory history, DeviceDisplayFrame? frame) builder;

  @override
  State<HistoryRecorder> createState() => _HistoryRecorderState();
}

class _HistoryRecorderState extends State<HistoryRecorder> {
  late final LevelHistory _h = LevelHistory(widget.lanes, length: widget.length);
  DeviceDisplayFrame? _last;

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) {
    if (f != null && !identical(f, _last)) {
      _last = f;
      if (widget.pick(f) case final v?) _h.push(v);
    }
    return widget.builder(context, _h, f);
  });
}

/// dB (−[floor]..0) as 0..1.
double dbUnit(double db, {double floor = 60}) => ((db + floor) / floor).clamp(0.0, 1.0);

/// A short text in the mono font, painted at [at] ([align] −1 left .. 1 right of it).
void paintLabel(Canvas canvas, String text, Offset at, Color color, {double size = 9, double align = -1,
    FontWeight weight = FontWeight.w500}) {
  final tp = TextPainter(
      text: TextSpan(text: text, style: Neon.code(size: size, color: color).copyWith(fontWeight: weight, height: 1)),
      textDirection: TextDirection.ltr)
    ..layout();
  tp.paint(canvas, at - Offset(tp.width * (align + 1) / 2, tp.height / 2));
}

/// A stroke paint in [color], with a soft glow under it when [glow] (the neon look).
void strokeGlow(Canvas canvas, Path path, Color color, {double width = 2, bool glow = true}) {
  final strength = Neon.strokeGlow; // softer on a light palette, none with a flat theme
  if (glow && strength > 0) {
    canvas.drawPath(path, Paint()
      ..color = color.withValues(alpha: 0.25 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width + 4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
  }
  canvas.drawPath(path, Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round);
}

/// A fill under [path] (closed to [baseline]) fading from [color] to clear.
void fillFade(Canvas canvas, Path path, double baseline, Size size, Color color, {double alpha = 0.28}) {
  final b = path.getBounds();
  final fill = Path.from(path)
    ..lineTo(b.right, baseline)
    ..lineTo(b.left, baseline)
    ..close();
  canvas.drawPath(fill, Paint()
    ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: Neon.ramp([color.withValues(alpha: alpha), color.withValues(alpha: 0.02)]))
        .createShader(Rect.fromLTRB(0, math.min(b.top, baseline), size.width, math.max(b.bottom, baseline) + 1)));
}

/// A grab handle: a filled dot ringed in [color], larger and haloed while [active].
void paintHandle(Canvas canvas, Offset at, Color color, {bool active = false, double r = 7, String? label}) {
  if (active) canvas.drawCircle(at, r + 9, Paint()..color = color.withValues(alpha: 0.2));
  canvas.drawCircle(at, r + 2, Paint()..color = color.withValues(alpha: 0.25));
  canvas.drawCircle(at, r, Paint()..color = Neon.panelHi);
  canvas.drawCircle(at, r, Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2);
  if (label != null) paintLabel(canvas, label, at, color, size: 8, align: 0, weight: FontWeight.w800);
}
