// Editing cues for Arrange and the piano roll (owner, 2026-11-12): a clip drag's two guide lines with its start on the
// ruler, the bar.beat they read, and a fade that keeps the last look while a cue goes (a collapsed loop band).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../motion.dart';
import '../theme.dart';

/// Where a dragged (or trimmed) clip, or the selection it moves, starts and ends in steps, and the clip's colour.
@immutable
class ClipGuide {
  const ClipGuide(this.start, this.end, this.color);
  final double start, end;
  final Color color;

  @override
  bool operator ==(Object other) => other is ClipGuide && other.start == start && other.end == end && other.color == color;
  @override
  int get hashCode => Object.hash(start, end, color);
}

/// [step] as bar.beat, counted from 1 ('3.2'), with the sixteenth when it is off a beat ('3.2.3').
String barBeatLabel(double step, int beatsPerBar) {
  final s = math.max(0, step.round());
  final bar = s ~/ (beatsPerBar * 4) + 1, beat = s % (beatsPerBar * 4) ~/ 4 + 1, sixteenth = s % 4;
  return sixteenth == 0 ? '$bar.$beat' : '$bar.$beat.${sixteenth + 1}';
}

/// Shows [builder] for [value]: it fades in when a value arrives and out when it goes (null), drawn as it last was
/// while it fades, with the motion setting (Reduced fades too; Off shows and hides at once). A value there from the
/// first build shows at once.
class FadeHold<T extends Object> extends StatefulWidget {
  const FadeHold({super.key, required this.value, required this.builder, this.duration = Motion.standard});
  final T? value;
  final Widget Function(BuildContext context, T value) builder;
  final Duration duration;

  @override
  State<FadeHold<T>> createState() => _FadeHoldState<T>();
}

class _FadeHoldState<T extends Object> extends State<FadeHold<T>> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this);
  T? _last;
  bool _started = false;

  Duration get _length => Motion.fade(widget.duration, Motion.of(context));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // What is already there when it is first built shows as it is: only a change fades.
    if (widget.value != null) {
      _last = widget.value;
      _fade.value = 1;
    }
  }

  @override
  void didUpdateWidget(FadeHold<T> old) {
    super.didUpdateWidget(old);
    final v = widget.value;
    if (v != null) {
      _show(v);
    } else if (old.value != null) {
      _hide();
    }
  }

  void _show(T v) {
    _last = v;
    final d = _length;
    if (d == Duration.zero) {
      _fade.value = 1;
      return;
    }
    if (_fade.status == AnimationStatus.forward || _fade.value == 1) return;
    _fade.duration = d;
    _fade.forward();
  }

  void _hide() {
    final d = _length;
    if (d == Duration.zero) {
      _fade.value = 0;
      _last = null;
      return;
    }
    _fade.duration = d;
    _fade.reverse().whenCompleteOrCancel(() {
      if (mounted && widget.value == null && _fade.value == 0) setState(() => _last = null);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    if (last == null) return const SizedBox.shrink();
    return FadeTransition(opacity: _fade, child: widget.builder(context, last));
  }
}

/// A clip drag's guides (owner, 2026-11-12): two thin lines in the clip's colour at its start and end, down through
/// the ruler and every track, and its start as bar.beat in a small tag on the ruler. [left] is the x of step 0.
class ClipGuidePainter extends CustomPainter {
  const ClipGuidePainter(this.guide, {required this.stepW, required this.rulerH, required this.beatsPerBar,
    this.left = 0, this.scrollX = 0});
  final ClipGuide guide;
  final double stepW, rulerH, left, scrollX;
  final int beatsPerBar;

  double get startX => left + guide.start * stepW - scrollX;
  double get endX => left + guide.end * stepW - scrollX;
  String get label => barBeatLabel(guide.start, beatsPerBar);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = guide.color.withValues(alpha: 0.85)..strokeWidth = 1;
    for (final x in [startX, endX]) {
      if (x < left - 1 || x > size.width + 1) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    final text = TextPainter(text: TextSpan(text: label,
        style: Neon.code(size: 9, color: Neon.ink).copyWith(fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr, maxLines: 1)..layout();
    final h = math.min(rulerH - 2, text.height + 2);
    final tag = RRect.fromRectAndRadius(
      Rect.fromLTWH(math.max(left, startX + 2), rulerH - h - 1, text.width + 6, h), const Radius.circular(3));
    canvas.drawRRect(tag, Paint()..color = guide.color);
    text.paint(canvas, Offset(tag.left + 3, tag.top + (h - text.height) / 2));
    text.dispose();
  }

  @override
  bool shouldRepaint(covariant ClipGuidePainter old) => old.guide != guide || old.stepW != stepW ||
      old.rulerH != rulerH || old.beatsPerBar != beatsPerBar || old.left != left || old.scrollX != scrollX;
}

/// The guides layer for [guides]: they fade in as a drag starts and out when it ends.
class ClipGuides extends StatelessWidget {
  const ClipGuides({super.key, required this.guides, required this.stepW, required this.rulerH,
    required this.beatsPerBar});
  final ValueListenable<ClipGuide?> guides;
  final double stepW, rulerH;
  final int beatsPerBar;

  @override
  Widget build(BuildContext context) => IgnorePointer(child: RepaintBoundary(child: ValueListenableBuilder<ClipGuide?>(
    valueListenable: guides,
    builder: (context, g, _) => FadeHold<ClipGuide>(value: g, duration: Motion.small,
      builder: (context, g) => CustomPaint(key: const ValueKey('clip-drag-guides'), size: Size.infinite,
        painter: ClipGuidePainter(g, stepW: stepW, rulerH: rulerH, beatsPerBar: beatsPerBar))))));
}
