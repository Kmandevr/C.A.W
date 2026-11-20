// The small crow the app draws: perched beside empty states (asleep between 2 and 5 am), circling as the loader, a few at once as a group's icon.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/easter_eggs.dart';
import 'capped_ticker.dart';
import 'motion.dart';
import 'theme.dart';

/// How the crow is drawn.
enum CrowPose { perched, sleeping, flying }

/// A small crow facing right in a square: body, head, beak, tail and an eye in [eye]; perched on a branch line,
/// asleep on one (the eye a closed line, a small "z"), or flying with its wings at [wing] (-1 down to 1 up).
class CrowPainter extends CustomPainter {
  CrowPainter({required this.color, this.eye, this.pose = CrowPose.perched, this.wing = 0, this.branch});
  final Color color;
  final Color? eye;
  final Color? branch;
  final CrowPose pose;
  final double wing;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    canvas.scale(s);
    final fill = Paint()..color = color;
    // The body, leaning forward, and the head.
    canvas.save();
    canvas.translate(0.48, 0.56);
    canvas.rotate(-0.26);
    canvas.drawOval(const Rect.fromLTRB(-0.25, -0.15, 0.25, 0.15), fill);
    canvas.restore();
    canvas.drawCircle(const Offset(0.72, 0.38), 0.12, fill);
    canvas.drawPath(Path()..moveTo(0.8, 0.32)..lineTo(0.98, 0.4)..lineTo(0.8, 0.45)..close(), fill);
    canvas.drawPath(Path()..moveTo(0.3, 0.56)..lineTo(0.04, 0.72)..lineTo(0.1, 0.78)..lineTo(0.33, 0.67)..close(), fill);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.045
      ..strokeCap = StrokeCap.round;
    if (pose == CrowPose.flying) {
      // Two wings from the shoulder.
      final up = wing.clamp(-1.0, 1.0);
      canvas.drawPath(
          Path()
            ..moveTo(0.42, 0.5)
            ..lineTo(0.3, 0.5 - 0.38 * up)
            ..lineTo(0.62, 0.48)
            ..close(),
          fill);
    } else {
      canvas.drawLine(const Offset(0.45, 0.7), const Offset(0.43, 0.86), line);
      canvas.drawLine(const Offset(0.55, 0.69), const Offset(0.56, 0.86), line);
      canvas.drawLine(const Offset(0.0, 0.88), const Offset(1.0, 0.85),
          line..color = branch ?? color.withValues(alpha: 0.5));
    }
    if (pose == CrowPose.sleeping) {
      final closed = Paint()
        ..color = eye ?? Neon.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.03
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCircle(center: const Offset(0.74, 0.36), radius: 0.035), 0.2, math.pi - 0.4, false, closed);
      final z = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.03
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(Path()..moveTo(0.82, 0.08)..lineTo(0.94, 0.08)..lineTo(0.82, 0.2)..lineTo(0.94, 0.2), z);
    } else {
      canvas.drawCircle(const Offset(0.745, 0.36), 0.032, Paint()..color = eye ?? Neon.pink);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CrowPainter old) =>
      old.color != color || old.eye != eye || old.pose != pose || old.wing != wing || old.branch != branch;
}

/// The crow perched beside an empty state's text; between 2 and 5 am it sleeps. [now] is for tests.
class PerchedCrow extends StatelessWidget {
  const PerchedCrow({super.key, this.size = 36, this.now});
  final double size;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final asleep = crowSleepsAt(now ?? DateTime.now());
    return ExcludeSemantics(
      child: SizedBox.square(
        key: ValueKey(asleep ? 'crow-asleep' : 'crow-perched'),
        dimension: size,
        child: CustomPaint(
            painter: CrowPainter(
                color: Neon.dim.withValues(alpha: 0.55),
                pose: asleep ? CrowPose.sleeping : CrowPose.perched,
                eye: asleep ? Neon.bg : Neon.pink.withValues(alpha: 0.8))),
      ),
    );
  }
}

/// An empty state: the perched crow over a line of text (and an optional action under it).
class CrowEmptyState extends StatelessWidget {
  const CrowEmptyState({super.key, required this.text, this.action, this.crowSize = 36});
  final String text;
  final Widget? action;
  final double crowSize;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        PerchedCrow(size: crowSize),
        const SizedBox(height: 6),
        Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Neon.dim, fontSize: 12)),
        ?action,
      ]);
}

/// How long the loader's crow takes to circle once.
const crowLoaderLap = Duration(milliseconds: 1600);

/// The loader in place of a spinner: a small crow circling on a thermal. Full motion circles; Reduced fades it
/// gently in and out where it is; Off holds it still.
class CrowLoader extends StatefulWidget {
  const CrowLoader({super.key, this.size = 16, this.color});
  final double size;
  final Color? color;

  @override
  State<CrowLoader> createState() => _CrowLoaderState();
}

class _CrowLoaderState extends State<CrowLoader> with SingleTickerProviderStateMixin {
  /// The loader's frames a second (1.1.1: it drew on every frame the screen ran, 120 on the S22+).
  static const maxHz = 30.0;
  late final _ticker = CappedTicker(_tick, maxHz: maxHz, vsync: this);
  final _t = ValueNotifier<double>(0); // 0 to 1 of a lap
  MotionLevel? _level;

  void _tick(Duration elapsed) =>
      _t.value = (elapsed.inMicroseconds % crowLoaderLap.inMicroseconds) / crowLoaderLap.inMicroseconds;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final level = Motion.of(context);
    if (level == _level) return;
    _level = level;
    if (level == MotionLevel.off) {
      _ticker.stop();
      _t.value = 0;
    } else {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Loading',
      child: SizedBox.square(
        key: ValueKey('crow-loader-${_level?.name}'),
        dimension: widget.size,
        // In a layer of its own: each step repaints the crow, not the screen around it.
        child: RepaintBoundary(
          child: ValueListenableBuilder<double>(
            valueListenable: _t,
            builder: (context, t, _) =>
                CustomPaint(painter: CrowLoaderPainter(t: t, level: _level ?? MotionLevel.full, color: color)),
          ),
        ),
      ),
    );
  }
}

/// One frame of [CrowLoader] at [t] (0 to 1 of a lap).
class CrowLoaderPainter extends CustomPainter {
  CrowLoaderPainter({required this.t, required this.level, required this.color});
  final double t;
  final MotionLevel level;
  final Color color;

  /// Where the crow is and its heading at [t] with [level]: still at the top unless motion is full.
  static ({double angle, double alpha}) frame(double t, MotionLevel level) => switch (level) {
        MotionLevel.full => (angle: 2 * math.pi * t, alpha: 1.0),
        MotionLevel.reduced => (angle: 0.0, alpha: 0.55 + 0.45 * (0.5 + 0.5 * math.cos(2 * math.pi * t))),
        MotionLevel.off => (angle: 0.0, alpha: 1.0),
      };

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame(t, level);
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    // The thermal: a faint ring.
    canvas.drawCircle(c, s * 0.36, Paint()
      ..color = color.withValues(alpha: 0.22 * f.alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, s * 0.07));
    final crow = s * 0.62;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(f.angle);
    canvas.translate(0, -s * 0.3);
    canvas.translate(-crow / 2, -crow / 2);
    CrowPainter(
      color: color.withValues(alpha: f.alpha),
      eye: color.withValues(alpha: f.alpha),
      pose: CrowPose.flying,
      wing: level == MotionLevel.full ? math.sin(4 * math.pi * t) : 0.6,
    ).paint(canvas, Size.square(crow));
    canvas.restore();
  }

  @override
  bool shouldRepaint(CrowLoaderPainter old) => old.t != t || old.level != level || old.color != color;
}

/// A group of crows (a "murder"): three overlapping crows, for a project of that name in Files.
class MurderIcon extends StatelessWidget {
  const MurderIcon({super.key, this.size = 22, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        key: const ValueKey('murder-icon'),
        dimension: size,
        child: Stack(children: [
          for (final (dx, dy, k) in const [(0.0, 0.32, 0.62), (0.38, 0.32, 0.62), (0.18, 0.0, 0.62)])
            Positioned(
              left: dx * size,
              top: dy * size,
              width: k * size,
              height: k * size,
              child: CustomPaint(painter: CrowPainter(color: color, eye: Neon.bg, pose: CrowPose.flying, wing: 0.4)),
            ),
        ]),
      );
}
