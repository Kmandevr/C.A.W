// A compact rotary knob for effect cards: drag up or down to turn, double-tap for the default, a tick at the centre.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../motion.dart';
import '../theme.dart';

class Knob extends StatefulWidget {
  const Knob({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    this.defaultValue,
    this.step = 0,
    this.color = Neon.blue,
    this.valueText,
    this.onChangeEnd,
    this.enabled = true,
    this.size = 34,
  });

  final double value, min, max, step;
  final double? defaultValue;
  final String label;
  final Color color;
  final String Function(double v)? valueText;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;
  final bool enabled;

  /// The drawn diameter; the touch area is padded to about 40 dp around it.
  final double size;

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double? _dragValue;

  double get _centre => (widget.min + widget.max) / 2;

  double _quantize(double v) {
    v = v.clamp(widget.min, widget.max).toDouble();
    if (widget.step > 0) v = widget.min + ((v - widget.min) / widget.step).round() * widget.step;
    return v.clamp(widget.min, widget.max).toDouble();
  }

  void _set(double next) {
    final before = _dragValue ?? widget.value;
    next = _quantize(next);
    // Reaching the centre ticks once (owner: light haptics on a knob reaching centre).
    final c = _centre;
    if (before != next && before != c && (next == c || (before - c) * (next - c) < 0)) Motion.tick();
    _dragValue = next;
    if (next != widget.value) widget.onChanged(next);
  }

  void _nudge(int dir) {
    final range = widget.max - widget.min;
    final step = widget.step > 0 ? widget.step : range / 100;
    _set(widget.value + dir * step);
    _dragValue = null;
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final range = widget.max - widget.min;
    final norm = range <= 0 ? 0.0 : ((widget.value - widget.min) / range).clamp(0.0, 1.0).toDouble();
    final text = widget.valueText?.call(widget.value) ?? widget.value.toStringAsFixed(range > 20 ? 0 : 2);
    final color = widget.enabled ? widget.color : Neon.dim;
    return Semantics(
      label: widget.label,
      value: text,
      slider: true,
      onIncrease: widget.enabled ? () => _nudge(1) : null,
      onDecrease: widget.enabled ? () => _nudge(-1) : null,
      child: Tooltip(
        message: '${widget.label}: $text',
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: widget.enabled ? (_) => _dragValue = widget.value : null,
          onVerticalDragUpdate: widget.enabled
              ? (d) {
                  // 200 px of travel covers the range; hold Shift on a desktop for fine moves.
                  final fine = HardwareKeyboard.instance.isShiftPressed ? 0.2 : 1.0;
                  final raw = (_dragValue ?? widget.value) - d.delta.dy / 200 * range * fine;
                  final before = _dragValue ?? widget.value;
                  _set(raw);
                  // Keep sub-step travel so slow drags still move a stepped knob.
                  if (widget.step > 0 && _dragValue == before) _dragValue = raw.clamp(widget.min, widget.max).toDouble();
                }
              : null,
          onVerticalDragEnd: widget.enabled ? (_) { _dragValue = null; widget.onChangeEnd?.call(); } : null,
          onDoubleTap: widget.enabled && widget.defaultValue != null
              ? () { _set(widget.defaultValue!); _dragValue = null; widget.onChangeEnd?.call(); }
              : null,
          child: SizedBox(
            width: math.max(48, widget.size + 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: widget.size + 6, height: widget.size + 6, child: Center(child: CustomPaint(
                size: Size.square(widget.size),
                painter: _KnobPainter(norm, color, bipolar: widget.min < 0 && widget.max > 0),
              ))),
              Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: Neon.dim)),
              Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: Neon.code(size: 9, color: color)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  const _KnobPainter(this.norm, this.color, {this.bipolar = false});
  final double norm;
  final Color color;
  final bool bipolar;

  static const _start = math.pi * 0.75, _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(rect, _start, _sweep, false, Paint()
      ..color = Neon.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round);
    final from = bipolar ? 0.5 : 0.0;
    canvas.drawArc(rect, _start + _sweep * math.min(from, norm), _sweep * (norm - from).abs(), false, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round);
    canvas.drawCircle(c, r - 5, Paint()..color = Neon.panelHi);
    final a = _start + _sweep * norm;
    canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * (r - 12), c + Offset(math.cos(a), math.sin(a)) * (r - 5),
        Paint()..color = Neon.text..strokeWidth = 2..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _KnobPainter old) => old.norm != norm || old.color != color || old.bipolar != bipolar;
}
