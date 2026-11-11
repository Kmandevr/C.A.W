// A compact rotary knob for effect cards: drag up or down to turn, double-tap for the default, a tick at the centre;
// exponential parameters turn on a log taper.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';

/// Where a value sits along a control's travel (0..1) and back. Linear by default; an exponential parameter
/// (`curve: exponential` in a component's descriptor: times, frequencies, rates) moves little at the start of the
/// travel and a lot at the end (owner, 2026-11-10): a log scale when the range is above zero, otherwise a curve
/// that spans three decades from the minimum.
class Taper {
  const Taper(this.min, this.max, {this.exponential = false});
  final double min, max;
  final bool exponential;

  static const _decades = 1000.0;

  bool get _log => min > 0 && max > min;

  double position(double value) {
    final range = max - min;
    if (range <= 0) return 0;
    final v = value.clamp(min, max).toDouble();
    if (!exponential) return (v - min) / range;
    if (_log) return math.log(v / min) / math.log(max / min);
    return math.log(1 + (v - min) / range * (_decades - 1)) / math.log(_decades);
  }

  double value(double position) {
    final t = position.clamp(0.0, 1.0).toDouble();
    final range = max - min;
    if (!exponential || range <= 0) return min + t * range;
    if (_log) return (min * math.pow(max / min, t)).clamp(min, max).toDouble();
    return (min + (math.pow(_decades, t) - 1) / (_decades - 1) * range).clamp(min, max).toDouble();
  }
}

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
    this.exponential = false,
  });

  /// Turn on an exponential taper ([Taper]): the parameter descriptor's `curve: exponential`.
  final bool exponential;

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
  // The travel position during a drag, so slow drags still move along a curved or stepped taper.
  double? _dragPos;
  bool _held = false;

  Taper get _taper => Taper(widget.min, widget.max, exponential: widget.exponential);

  double get _centre => (widget.min + widget.max) / 2;

  double _quantize(double v) {
    v = v.clamp(widget.min, widget.max).toDouble();
    if (widget.step > 0) v = widget.min + ((v - widget.min) / widget.step).round() * widget.step;
    return v.clamp(widget.min, widget.max).toDouble();
  }

  void _set(double next) {
    final before = _dragValue ?? widget.value;
    next = _quantize(next);
    // Reaching the centre ticks once (owner: light haptics on a knob reaching centre), and so does each step: a
    // stepped knob's every value, a smooth knob's every 1/24 of its travel (Haptics rate-limits a fast turn).
    final c = _centre;
    final notches = widget.step > 0 ? null : 24;
    int notch(double v) => notches == null ? ((v - widget.min) / widget.step).round() : (_taper.position(v) * notches).floor();
    if (before != next && before != c && (next == c || (before - c) * (next - c) < 0)) {
      Motion.tick();
    } else if (before != next && notch(before) != notch(next)) {
      Haptics.tick();
    }
    _dragValue = next;
    if (next != widget.value) widget.onChanged(next);
  }

  double _stepped(int dir) {
    final range = widget.max - widget.min;
    return _quantize(widget.value + dir * (widget.step > 0 ? widget.step : range / 100));
  }

  String _describe(double v) =>
      widget.valueText?.call(v) ?? v.toStringAsFixed(widget.max - widget.min > 20 ? 0 : 2);

  void _nudge(int dir) {
    _set(_stepped(dir));
    _dragValue = null;
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final norm = _taper.position(widget.value);
    final text = _describe(widget.value);
    final color = widget.enabled ? widget.color : Neon.dim;
    return Semantics(
      label: widget.label,
      value: text,
      slider: true,
      increasedValue: widget.enabled ? _describe(_stepped(1)) : null,
      decreasedValue: widget.enabled ? _describe(_stepped(-1)) : null,
      onIncrease: widget.enabled ? () => _nudge(1) : null,
      onDecrease: widget.enabled ? () => _nudge(-1) : null,
      child: Tooltip(
        message: '${widget.label}: $text',
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: widget.enabled
              ? (_) {
                  _dragValue = widget.value;
                  _dragPos = _taper.position(widget.value);
                  Haptics.grab();
                  setState(() => _held = true);
                }
              : null,
          onVerticalDragUpdate: widget.enabled
              ? (d) {
                  // 200 px of travel covers the range; hold Shift on a desktop for fine moves.
                  final fine = HardwareKeyboard.instance.isShiftPressed ? 0.2 : 1.0;
                  final pos = ((_dragPos ?? _taper.position(widget.value)) - d.delta.dy / 200 * fine).clamp(0.0, 1.0).toDouble();
                  _dragPos = pos;
                  _set(_taper.value(pos));
                }
              : null,
          onVerticalDragEnd: widget.enabled
              ? (_) {
                  _dragValue = null;
                  _dragPos = null;
                  setState(() => _held = false);
                  widget.onChangeEnd?.call();
                }
              : null,
          onVerticalDragCancel: () {
            if (_held) setState(() => _held = false);
          },
          onDoubleTap: widget.enabled && widget.defaultValue != null
              ? () { _set(widget.defaultValue!); _dragValue = null; widget.onChangeEnd?.call(); }
              : null,
          child: SizedBox(
            width: math.max(48, widget.size + 14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Held, the knob grows a little and glows (feedback.dart's press look).
              SizedBox(width: widget.size + 6, height: widget.size + 6, child: Center(child: AnimatedScale(
                key: const ValueKey('knob-held'),
                scale: _held && Motion.of(context) == MotionLevel.full ? 1.1 : 1,
                duration: Motion.fade(Motion.small, Motion.of(context)),
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    boxShadow: _held ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10)] : null),
                  child: RepaintBoundary(child: CustomPaint(
                    size: Size.square(widget.size),
                    painter: _KnobPainter(norm, color, bipolar: widget.min < 0 && widget.max > 0),
                  )),
                ),
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
