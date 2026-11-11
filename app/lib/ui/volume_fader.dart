// REAPER-like volume faders: a dB taper over the engine's linear gain, dB readouts and typing, fine drags and reset.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/project.dart' show kMaxMixGain;
import 'motion.dart';
import 'pointer_input.dart';
import 'theme.dart';

/// The fader taper (owner, 2026-11-10: like REAPER's). A track's or the master's `volume` is a linear gain (1 is
/// 0 dB; the engine takes 0..+12 dB, `kMaxMixGain`, `Engine::setLayerMix`), so the app converts at the UI only.
///
/// Over REAPER's full travel the level is `zeroAt` (three quarters up) at 0 dB and [topDb] at the top, and in dB it
/// grows with the log of the position: `dB = 20 k log10(p / zeroAt)`, so it falls to -inf at the bottom with most of
/// the travel spent on the useful range. [Assumption] REAPER's exact curve is not published; this matches its
/// landmarks (-inf bottom, 0 dB about 3/4, +12 dB top) and was not measured against it.
///
/// The engine allows +12 dB ([maxGain]), so the fader has REAPER's full travel: 0 dB three quarters up, +12 dB at
/// the top.
class VolumeTaper {
  VolumeTaper._();

  static const zeroAt = 0.75, topDb = 12.0;
  static final double _k = topDb / (20 * math.log(1 / zeroAt) / math.ln10);

  /// The loudest gain the engine takes: +12 dB.
  static const maxGain = kMaxMixGain;

  /// The fader's top on REAPER's travel: 1 now that [maxGain] is +12 dB (0.75 if it were 0 dB).
  static double get top => _position(maxGain);

  static double _position(double gain) =>
      gain <= 0 || !gain.isFinite ? 0 : (zeroAt * math.pow(gain, 1 / _k)).clamp(0.0, 1.0).toDouble();

  /// Where [gain] sits along the fader's own travel, 0 (bottom, -inf) to 1 (top).
  static double position(double gain) => (_position(gain.clamp(0.0, maxGain).toDouble()) / top).clamp(0.0, 1.0);

  /// The gain at fader position [p] (0..1).
  static double gain(double p) {
    final t = p.clamp(0.0, 1.0) * top;
    return t <= 0 ? 0 : math.min(maxGain, math.pow(t / zeroAt, _k).toDouble());
  }

  /// [gain] in dB, -inf for silence.
  static double db(double gain) => gain <= 0 ? double.negativeInfinity : 20 * math.log(gain) / math.ln10;

  /// "-6.0 dB", "0.0 dB", "-inf dB".
  static String label(double gain) {
    final d = db(gain);
    if (d < -150) return '-inf dB';
    final shown = d.abs() < 0.05 ? 0.0 : d;
    return '${shown > 0 ? '+' : ''}${shown.toStringAsFixed(1)} dB';
  }

  /// A typed level: "-6", "-6 dB", "-inf" or "inf" (silence); clamped to [maxGain]. Null when it isn't one.
  static double? parse(String text) {
    final t = text.toLowerCase().replaceAll('db', '').trim();
    if (t == '-inf' || t == 'inf' || t == '-∞') return 0;
    final v = double.tryParse(t);
    if (v == null || v.isNaN) return null;
    return math.min(maxGain, math.pow(10, v / 20).toDouble());
  }
}

/// A volume fader on [VolumeTaper]: upright (bottom to top) or sideways. Dragging follows the finger along the
/// travel; with Shift held, or a second finger resting on it, it moves a fifth as fast for fine changes. A
/// double-tap sets [defaultGain] (0 dB). The level's dB value shows on hover and to screen readers; screens show it
/// under the fader.
class VolumeFader extends StatefulWidget {
  const VolumeFader({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.color = Neon.green,
    this.vertical = true,
    this.defaultGain = 1.0,
    this.onChangeEnd,
  });

  final double value; // linear gain
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;
  final String label;
  final Color color;
  final bool vertical;
  final double defaultGain;

  /// A fine drag moves this fraction of a plain one.
  static const fine = 0.2;

  @override
  State<VolumeFader> createState() => _VolumeFaderState();
}

class _VolumeFaderState extends State<VolumeFader> {
  double? _pos;
  final Set<int> _fingers = {};
  bool _active = false;

  void _move(double delta, double length, {bool? fine}) {
    fine ??= HardwareKeyboard.instance.isShiftPressed || _fingers.length > 1;
    final from = _pos ?? VolumeTaper.position(widget.value);
    final next = (from + delta / math.max(1.0, length) * (fine ? VolumeFader.fine : 1)).clamp(0.0, 1.0).toDouble();
    // Crossing 0 dB ticks once, like a knob reaching its centre.
    if ((from < 1 && next >= 1) || (from >= 1 && next < 1)) Motion.tick();
    _pos = next;
    widget.onChanged(VolumeTaper.gain(next));
  }

  void _end() {
    setState(() {
      _pos = null;
      _active = false;
    });
    widget.onChangeEnd?.call();
  }

  // The mouse wheel: 2% of the travel a turn (a fifth of that with Shift); the burst's end is one change.
  void _wheel(int dir, bool fine) => _move(dir * 0.02 * (fine ? VolumeFader.fine : 1), 1, fine: false);

  void _wheelEnd() {
    _pos = null;
    widget.onChangeEnd?.call();
  }

  void _step(double by) {
    widget.onChanged(VolumeTaper.gain((VolumeTaper.position(widget.value) + by).clamp(0.0, 1.0)));
    widget.onChangeEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = VolumeTaper.position(widget.value);
    final text = VolumeTaper.label(widget.value);
    return Semantics(
      slider: true,
      label: widget.label,
      value: text,
      increasedValue: VolumeTaper.label(VolumeTaper.gain(math.min(1.0, p + 0.02))),
      decreasedValue: VolumeTaper.label(VolumeTaper.gain(math.max(0.0, p - 0.02))),
      onIncrease: () => _step(0.02),
      onDecrease: () => _step(-0.02),
      child: Tooltip(
        message: '${widget.label}: $text',
        waitDuration: const Duration(milliseconds: 600),
        child: Listener(
          onPointerDown: (e) => _fingers.add(e.pointer),
          onPointerUp: (e) => _fingers.remove(e.pointer),
          onPointerCancel: (e) => _fingers.remove(e.pointer),
          child: LayoutBuilder(builder: (context, box) {
            final length = widget.vertical ? box.maxHeight : box.maxWidth;
            return WheelSteps(
              onStep: _wheel,
              onEnd: _wheelEnd,
              cursor: widget.vertical ? SystemMouseCursors.resizeUpDown : SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () {
                Motion.tick();
                widget.onChanged(widget.defaultGain);
                widget.onChangeEnd?.call();
              },
              onVerticalDragStart: widget.vertical ? (_) => setState(() { _active = true; _pos = p; }) : null,
              onVerticalDragUpdate: widget.vertical ? (d) => _move(-d.delta.dy, length - 16) : null,
              onVerticalDragEnd: widget.vertical ? (_) => _end() : null,
              onHorizontalDragStart: widget.vertical ? null : (_) => setState(() { _active = true; _pos = p; }),
              onHorizontalDragUpdate: widget.vertical ? null : (d) => _move(d.delta.dx, length - 16),
              onHorizontalDragEnd: widget.vertical ? null : (_) => _end(),
              child: CustomPaint(
                size: Size(box.maxWidth.isFinite ? box.maxWidth : 40, box.maxHeight.isFinite ? box.maxHeight : 40),
                painter: _FaderPainter(p, widget.color, widget.vertical, _active),
              ),
            ));
          }),
        ),
      ),
    );
  }
}

class _FaderPainter extends CustomPainter {
  const _FaderPainter(this.pos, this.color, this.vertical, this.active);
  final double pos;
  final Color color;
  final bool vertical, active;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 8.0;
    final length = (vertical ? size.height : size.width) - 2 * pad;
    if (length <= 0) return;
    Offset at(double t) => vertical
        ? Offset(size.width / 2, size.height - pad - t * length)
        : Offset(pad + t * length, size.height / 2);
    final track = Paint()
      ..color = Neon.line
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(at(0), at(1), track);
    canvas.drawLine(at(0), at(pos), Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round);
    // Ticks at 0, -6, -12, -24 and -48 dB, the 0 dB one longer.
    for (final d in const [0.0, -6.0, -12.0, -24.0, -48.0]) {
      final c = at(VolumeTaper.position(math.pow(10, d / 20).toDouble()));
      final half = d == 0 ? 7.0 : 4.0;
      final tick = Paint()
        ..color = Neon.dim.withValues(alpha: d == 0 ? 0.8 : 0.45)
        ..strokeWidth = 1;
      vertical
          ? canvas.drawLine(c + Offset(-half - 3, 0), c + Offset(-3, 0), tick)
          : canvas.drawLine(c + Offset(0, -half - 3), c + Offset(0, -3), tick);
    }
    // The cap: a short bar across the track, like a mixing desk's.
    final cap = at(pos);
    final rect = vertical
        ? Rect.fromCenter(center: cap, width: math.min(26, size.width), height: 10)
        : Rect.fromCenter(center: cap, width: 10, height: math.min(22, size.height));
    final r = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(r, Paint()..color = Color.lerp(Neon.panelHi, color, active ? 0.45 : 0.25)!);
    canvas.drawRRect(r, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
    final line = Paint()
      ..color = Neon.text
      ..strokeWidth = 1.4;
    vertical
        ? canvas.drawLine(Offset(rect.left + 3, cap.dy), Offset(rect.right - 3, cap.dy), line)
        : canvas.drawLine(Offset(cap.dx, rect.top + 3), Offset(cap.dx, rect.bottom - 3), line);
  }

  @override
  bool shouldRepaint(covariant _FaderPainter old) =>
      old.pos != pos || old.color != color || old.vertical != vertical || old.active != active;
}
