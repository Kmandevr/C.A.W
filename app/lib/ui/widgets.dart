// Shared neon widgets: panels, the oscilloscope, level and progress meters, and small toggle buttons.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import 'theme.dart';
import 'glass.dart';

class NeonPanel extends StatelessWidget {
  const NeonPanel({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(12)});
  final Widget child;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          // No glow under a see-through card: it would show through and make the card look solid.
          boxShadow: color == null || Glass.active ? null : Neon.glow(color!, strength: 0.25),
        ),
        // A Material surface (not a coloured box) so list tiles and ink splashes inside draw correctly.
        // Glass: see-through, faintly tinted with the card's colour, with a solid outline.
        child: Material(
          color: Glass.active
              ? Color.lerp(Neon.panel, color ?? Neon.panel, 0.06)!.withValues(alpha: 0.55)
              : Neon.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
                color: Glass.active ? (color ?? Colors.white.withValues(alpha: 0.12)) : (color?.withValues(alpha: 0.7) ?? Neon.line)),
          ),
          child: Padding(padding: padding, child: child),
        ),
      );
}

/// Draws the latest samples of one engine output (a layer, the audition or the master).
class ScopeView extends StatefulWidget {
  const ScopeView({super.key, required this.state, required this.index, this.color = Neon.green, this.height = 96});
  final AppState state;
  final int index;
  final Color color;
  final double height;

  @override
  State<ScopeView> createState() => _ScopeViewState();
}

class _ScopeViewState extends State<ScopeView> {
  final Float32List _buf = Float32List(512);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: widget.height,
        child: ValueListenableBuilder<int>(
          valueListenable: widget.state.tick,
          builder: (context, _, _) {
            widget.state.engine?.scope(widget.index, _buf);
            return CustomPaint(painter: _ScopePainter(_buf, widget.color), size: Size.infinite);
          },
        ),
      );
}

class _ScopePainter extends CustomPainter {
  _ScopePainter(this.samples, this.color);
  final Float32List samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Neon.line);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * size.width / (samples.length - 1);
      final y = mid - samples[i].clamp(-1.0, 1.0) * (mid - 2);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4);
  }

  @override
  bool shouldRepaint(covariant _ScopePainter old) => true;
}

/// A horizontal bar for a 0..1 value, drawn in neon. With glass on: a faint fill and a solid outline, for the
/// track and the value alike, a little taller so the outline reads.
class Bar extends StatelessWidget {
  const Bar({super.key, required this.value, required this.color, this.height = 4});
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Glass.active ? _glass() : _plain();

  Widget _glass() {
    final h = height < 7 ? 7.0 : height;
    final r = BorderRadius.circular(h);
    return LayoutBuilder(
      builder: (context, c) => Container(
        height: h,
        decoration: BoxDecoration(
          color: Neon.line.withValues(alpha: 0.18),
          borderRadius: r,
          border: Border.all(color: Neon.line, width: 0.8),
        ),
        alignment: Alignment.centerLeft,
        child: Container(
          width: c.maxWidth * value.clamp(0.0, 1.0),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.35),
            borderRadius: r,
            border: value > 0 ? Border.all(color: color, width: 0.9) : null,
          ),
        ),
      ),
    );
  }

  Widget _plain() => LayoutBuilder(
        builder: (context, c) => Container(
          height: height,
          decoration: BoxDecoration(color: Neon.line, borderRadius: BorderRadius.circular(height)),
          alignment: Alignment.centerLeft,
          child: Container(
            width: c.maxWidth * value.clamp(0.0, 1.0),
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(height), boxShadow: Neon.glow(color, strength: 0.6)),
          ),
        ),
      );
}

/// A peak meter for one layer, folder or the master, on a dB scale: the bar rises at once to each sample peak and
/// falls at [fallDbPerSecond]; a thin line holds the highest peak for [holdSeconds]; at 0 dBFS or over it turns pink
/// for [clipSeconds]. It runs on wall-clock time (its own ticker, only while something shows), so it falls the same
/// on any refresh rate or meter cadence and never freezes partway when the engine goes quiet.
class PeakMeter extends StatefulWidget {
  const PeakMeter({super.key, required this.state, required this.read, required this.color});
  final AppState state;
  final double Function() read;
  final Color color;

  /// The meter's range: [floorDb] (empty) to 0 dBFS (full).
  static const floorDb = -60.0;
  static const fallDbPerSecond = 24.0;
  static const holdSeconds = 1.5;
  static const clipSeconds = 3.0;

  /// A linear peak (1 = 0 dBFS) in dB, [floorDb] for silence.
  static double db(double peak) => peak <= 0 || !peak.isFinite ? floorDb : math.max(floorDb, 20 * math.log(peak) / math.ln10);

  /// Where [db] sits along the meter, 0..1.
  static double fraction(double db) => ((db - floorDb) / -floorDb).clamp(0.0, 1.0);

  @override
  State<PeakMeter> createState() => PeakMeterState();
}

class PeakMeterState extends State<PeakMeter> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_frame);
  Duration _last = Duration.zero;
  double _shownDb = PeakMeter.floorDb, _holdDb = PeakMeter.floorDb;
  double _holdLeft = 0, _clipLeft = 0; // seconds

  /// The level the bar shows now, in dB (for tests).
  double get shownDb => _shownDb;

  /// The held peak line, in dB.
  double get holdDb => _holdDb;
  bool get clipped => _clipLeft > 0;

  @override
  void initState() {
    super.initState();
    widget.state.tick.addListener(_read);
  }

  @override
  void didUpdateWidget(PeakMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.tick.removeListener(_read);
      widget.state.tick.addListener(_read);
    }
  }

  @override
  void dispose() {
    widget.state.tick.removeListener(_read);
    _ticker.dispose();
    super.dispose();
  }

  // A meter read: the peak since the last one.
  void _read() {
    final peak = widget.read();
    final d = PeakMeter.db(peak);
    var changed = false;
    if (d > _shownDb) {
      _shownDb = d;
      changed = true;
    }
    if (d >= _holdDb && d > PeakMeter.floorDb) {
      _holdDb = d;
      _holdLeft = PeakMeter.holdSeconds;
      changed = true;
    }
    if (peak >= 1.0) {
      _clipLeft = PeakMeter.clipSeconds;
      changed = true;
    }
    if (changed) {
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
      setState(() {});
    }
  }

  void _frame(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _shownDb = math.max(PeakMeter.floorDb, _shownDb - PeakMeter.fallDbPerSecond * dt);
    // The peak line holds, then falls like the bar for whatever part of this frame came after its hold.
    final held = math.min(_holdLeft, dt);
    _holdLeft = math.max(0, _holdLeft - dt);
    _holdDb = math.max(_shownDb, _holdDb - PeakMeter.fallDbPerSecond * (dt - math.max(0, held)));
    if (_clipLeft > 0) _clipLeft -= dt;
    if (_shownDb <= PeakMeter.floorDb && _holdDb <= PeakMeter.floorDb && _clipLeft <= 0) _ticker.stop();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final color = clipped ? Neon.pink : widget.color;
    final hold = PeakMeter.fraction(_holdDb);
    return LayoutBuilder(
      builder: (context, c) => Stack(alignment: Alignment.centerLeft, children: [
        Bar(value: PeakMeter.fraction(_shownDb), color: color),
        if (hold > 0 && c.maxWidth.isFinite)
          Positioned(
            left: (c.maxWidth * hold - 1.5).clamp(0.0, math.max(0.0, c.maxWidth - 1.5)),
            top: 0,
            bottom: 0,
            child: IgnorePointer(child: Container(width: 1.5, color: color)),
          ),
      ]),
    );
  }
}

/// A compact square toggle such as M (mute) or S (solo).
class ToggleChip extends StatelessWidget {
  const ToggleChip({super.key, required this.label, required this.on, required this.color, required this.onTap, this.tooltip});
  final String label;
  final bool on;
  final Color color;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? label,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 48,
            height: 48,
            alignment: Alignment.center,
            // Glass: on is a faint fill with a solid outline (not a solid block); off is outlined only.
            decoration: BoxDecoration(
              color: on ? (Glass.active ? color.withValues(alpha: 0.22) : color) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? color : Neon.line, width: on && Glass.active ? 1.2 : 1),
              boxShadow: on && !Glass.active ? Neon.glow(color) : null,
            ),
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: on ? (Glass.active ? color : Neon.bg) : Neon.dim,
                    fontSize: 15)),
          ),
        ),
      );
}

/// Section heading in small caps.
class Heading extends StatelessWidget {
  const Heading(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: const TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w700, color: Neon.dim)),
          ),
          ?trailing,
        ]),
      );
}

String formatParam(double v, ParamInfo p) {
  final span = (p.max - p.min).abs();
  if (v == v.roundToDouble() && span >= 4) return v.toStringAsFixed(0);
  if (span >= 100) return v.toStringAsFixed(0);
  if (span >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}
