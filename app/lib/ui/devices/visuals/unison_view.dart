// A unison stack fanned out: each copy where it pans, as tall as its level, as high as its detune; drag for spread and detune.
import '../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/flagship_shapes.dart';
import '../../theme.dart';
import '../device_scope.dart';
import 'grab.dart';

/// The stack of `<prefix>unison`, `detune` (cents), `detune_power`, `spread`, `blend` and `stack`, laid out with
/// the engine's own unison maths. Sideways sets the spread, up and down the detune; double-tap resets both.
class UnisonView extends StatefulWidget {
  const UnisonView({super.key, required this.prefix, this.height = 72, this.color});
  final String prefix;
  final double height;
  final Color? color;

  @override
  State<UnisonView> createState() => _UnisonViewState();
}

class _UnisonViewState extends State<UnisonView> {
  double _spread = 0, _detune = 0;
  bool _dragging = false;

  String _id(String n) => '${widget.prefix}$n';

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final color = widget.color ?? scope.accent;
    final pDetune = t.param(_id('detune'));
    if (pDetune == null) return const SizedBox.shrink();
    final copies = unisonLayout(t.value(_id('unison')).round(), t.value(_id('detune')) / 100, t.value(_id('detune_power')),
        t.value(_id('spread')), t.value(_id('blend')), t.value(_id('stack')).round());
    return GrabPan(
      key: ValueKey('unison-${widget.prefix}'),
      onStart: (_) {
        _spread = t.value(_id('spread'));
        _detune = t.value(pDetune.id);
        setState(() => _dragging = true);
      },
      onUpdate: (_, d) {
        _spread = (_spread + d.dx / 160).clamp(0.0, 1.0);
        _detune = (_detune - d.dy * (pDetune.max - pDetune.min) / 160).clamp(pDetune.min, pDetune.max);
        t.setLive(_id('spread'), _spread);
        t.setLive(pDetune.id, _detune);
      },
      onEnd: () {
        if (_dragging) t.commit();
        setState(() => _dragging = false);
      },
      onDoubleTap: () => t.setAll({
        pDetune.id: pDetune.defaultValue,
        if (t.param(_id('spread')) case final p?) p.id: p.defaultValue,
      }),
      child: SizedBox(height: widget.height, child: CustomPaint(
        painter: _UnisonPainter(copies, pDetune.max / 100, color, _dragging),
        child: Align(alignment: Alignment.topRight, child: Padding(padding: const EdgeInsets.all(4), child: Text(
          '${copies.length}× · ${t.value(pDetune.id).round()} ct · ${(t.value(_id('spread')) * 100).round()}%',
          style: Neon.code(size: 9, color: Neon.dim)))),
      )),
    );
  }
}

class _UnisonPainter extends CustomPainter {
  _UnisonPainter(this.copies, this.maxSemis, this.color, this.active);
  final List<UnisonCopy> copies;
  final double maxSemis;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, base = size.height - 8;
    final half = size.width / 2 - 14;
    canvas.drawLine(Offset(cx - half, base), Offset(cx + half, base), Paint()..color = Neon.ink.withValues(alpha: 0.08));
    canvas.drawLine(Offset(cx, 6), Offset(cx, base), Paint()..color = Neon.ink.withValues(alpha: 0.05));
    for (final s in ['L', 'R']) {
      final tp = TextPainter(text: TextSpan(text: s, style: Neon.code(size: 8, color: Neon.dim)),
        textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(s == 'L' ? 2 : size.width - tp.width - 2, base - tp.height / 2));
    }
    final top = 10.0, span = base - top;
    final maxGain = copies.fold<double>(0, (m, c) => math.max(m, c.gain));
    for (final c in copies) {
      final x = cx + c.pan * half;
      // Height: the detune away from the note (the stack's intervals push copies higher too), at least the level.
      final pitch = maxSemis <= 0 ? 0.0 : (c.semitones.abs() / math.max(maxSemis, 0.01)).clamp(0.0, 1.0);
      final level = maxGain <= 0 ? 0.0 : c.gain / maxGain;
      final h = span * (0.25 + 0.75 * pitch) * (0.4 + 0.6 * level);
      final hue = c.semitones < 0 ? Color.lerp(color, Neon.blue, pitch * 0.7)! : Color.lerp(color, Neon.pink, pitch * 0.7)!;
      final paint = Paint()
        ..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: Neon.ramp([hue.withValues(alpha: 0.05), hue.withValues(alpha: 0.9)]))
          .createShader(Rect.fromLTRB(x - 2, base - h, x + 2, base))
        ..strokeWidth = active ? 3 : 2.2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, base), Offset(x, base - h), paint);
      canvas.drawCircle(Offset(x, base - h), 2.6, Paint()..color = hue);
    }
  }

  @override
  bool shouldRepaint(covariant _UnisonPainter o) =>
      paintInputsChanged([o.copies, o.maxSemis, o.color, o.active], [copies, maxSemis, color, active]);
}
