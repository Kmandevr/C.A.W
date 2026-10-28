// Shared neon widgets: panels, the oscilloscope, level and progress meters, and small toggle buttons.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import 'theme.dart';

class NeonPanel extends StatelessWidget {
  const NeonPanel({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(12)});
  final Widget child;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: color == null ? null : Neon.glow(color!, strength: 0.25),
        ),
        // A Material surface (not a coloured box) so list tiles and ink splashes inside draw correctly.
        child: Material(
          color: Neon.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: color?.withValues(alpha: 0.7) ?? Neon.line),
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

/// A horizontal bar for a 0..1 value, drawn in neon.
class Bar extends StatelessWidget {
  const Bar({super.key, required this.value, required this.color, this.height = 4});
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
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

/// Peak meter with a slow fall, for one layer or the master.
class PeakMeter extends StatefulWidget {
  const PeakMeter({super.key, required this.state, required this.read, required this.color});
  final AppState state;
  final double Function() read;
  final Color color;

  @override
  State<PeakMeter> createState() => _PeakMeterState();
}

class _PeakMeterState extends State<PeakMeter> {
  double _shown = 0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: widget.state.tick,
        builder: (context, _, _) {
          final p = widget.read();
          _shown = p > _shown ? p : _shown * 0.85;
          return Bar(value: _shown, color: _shown > 0.95 ? Neon.pink : widget.color);
        },
      );
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
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? color : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: on ? color : Neon.line),
              boxShadow: on ? Neon.glow(color) : null,
            ),
            child: Text(label,
                style: TextStyle(fontWeight: FontWeight.w700, color: on ? Neon.bg : Neon.dim, fontSize: 15)),
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
