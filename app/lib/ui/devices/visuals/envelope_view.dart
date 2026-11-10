// A draggable ADSR envelope: handles for the attack time, the decay time with the sustain level, and the release time.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../arrange/knob.dart' show Taper;
import '../../theme.dart';
import '../device_scope.dart';
import 'grab.dart';

/// The envelope whose parameters are `<prefix>attack`, `decay`, `sustain` and `release` (times on their tapers,
/// each segment as wide as its knob's travel; the sustain hold has a fixed width).
class EnvelopeView extends StatefulWidget {
  const EnvelopeView({super.key, required this.prefix, this.height = 96, this.color});
  final String prefix;
  final double height;
  final Color? color;

  @override
  State<EnvelopeView> createState() => _EnvelopeViewState();
}

enum _Handle { attack, decay, release }

class EnvelopeGeometry {
  EnvelopeGeometry(this.size, this.a, this.d, this.s, this.r);
  final Size size;
  final double a, d, s, r; // travel positions 0..1 of the times, and the sustain level

  static const pad = 10.0;
  double get seg => (size.width - 2 * pad) * 0.28;
  double get hold => (size.width - 2 * pad) * 0.16;
  double get top => pad;
  double get bottom => size.height - pad;
  double get xA => pad + math.max(0.015, a) * seg;
  double get xD => xA + math.max(0.015, d) * seg;
  double get xS => xD + hold;
  double get xR => xS + math.max(0.015, r) * seg;
  double get yS => bottom - s * (bottom - top);

  Offset get attack => Offset(xA, top);
  Offset get decay => Offset(xD, yS);
  Offset get release => Offset(xR, bottom);
}

class _EnvelopeViewState extends State<EnvelopeView> {
  _Handle? _active;

  String _id(String name) => '${widget.prefix}$name';

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final color = widget.color ?? scope.accent;
    final pa = t.param(_id('attack')), pd = t.param(_id('decay')), pr = t.param(_id('release'));
    if (pa == null || pd == null || pr == null) return const SizedBox.shrink();
    Taper taper(ComponentParameterInfo p) => Taper(p.min, p.max, exponential: p.exponential);
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, widget.height);
      final g = EnvelopeGeometry(size, taper(pa).position(t.value(pa.id)), taper(pd).position(t.value(pd.id)),
          t.value(_id('sustain')).clamp(0.0, 1.0), taper(pr).position(t.value(pr.id)));
      _Handle? nearest(Offset p) {
        final c = {_Handle.attack: g.attack, _Handle.decay: g.decay, _Handle.release: g.release};
        _Handle? best;
        var bestD = 30.0;
        for (final e in c.entries) {
          final dist = (e.value - p).distance;
          if (dist < bestD) {
            bestD = dist;
            best = e.key;
          }
        }
        return best;
      }

      void move(Offset p) {
        switch (_active) {
          case _Handle.attack:
            t.setLive(pa.id, taper(pa).value((p.dx - EnvelopeGeometry.pad) / g.seg));
          case _Handle.decay:
            t.setLive(pd.id, taper(pd).value((p.dx - g.xA) / g.seg));
            t.setLive(_id('sustain'), ((g.bottom - p.dy) / (g.bottom - g.top)).clamp(0.0, 1.0));
          case _Handle.release:
            t.setLive(pr.id, taper(pr).value((p.dx - g.xS) / g.seg));
          case null:
        }
      }

      final label = switch (_active) {
        _Handle.attack => 'A ${formatParamValue(pa, t.value(pa.id))}',
        _Handle.decay => 'D ${formatParamValue(pd, t.value(pd.id))} · S ${(t.value(_id('sustain')) * 100).round()}%',
        _Handle.release => 'R ${formatParamValue(pr, t.value(pr.id))}',
        null => null,
      };
      return GrabPan(
        key: ValueKey('env-${widget.prefix}'),
        grabs: (p) => nearest(p) != null,
        onStart: (p) => setState(() => _active = nearest(p)),
        onUpdate: (p, _) => move(p),
        onEnd: () {
          if (_active != null) t.commit();
          setState(() => _active = null);
        },
        onDoubleTap: () => t.setAll({
          for (final n in ['attack', 'decay', 'sustain', 'release'])
            if (t.param(_id(n)) case final p?) p.id: p.defaultValue,
        }),
        child: SizedBox(height: widget.height, child: CustomPaint(
          size: size,
          painter: _EnvelopePainter(g, color, _active),
          child: label == null ? null : Align(alignment: Alignment.topRight, child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text(label, style: Neon.code(size: 9, color: color)))),
        )),
      );
    });
  }
}

class _EnvelopePainter extends CustomPainter {
  _EnvelopePainter(this.g, this.color, this.active);
  final EnvelopeGeometry g;
  final Color color;
  final _Handle? active;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.04);
    for (var i = 1; i < 4; i++) {
      final y = g.top + (g.bottom - g.top) * i / 4;
      canvas.drawLine(Offset(g.top, y), Offset(size.width - g.top, y), grid);
    }
    final path = Path()..moveTo(EnvelopeGeometry.pad, g.bottom);
    const n = 24;
    for (var i = 1; i <= n; i++) {
      final u = i / n;
      path.lineTo(EnvelopeGeometry.pad + (g.xA - EnvelopeGeometry.pad) * u, g.bottom - (g.bottom - g.top) * (1 - math.pow(1 - u, 1.8)));
    }
    for (var i = 1; i <= n; i++) {
      final u = i / n;
      final level = g.s + (1 - g.s) * math.pow(1 - u, 3);
      path.lineTo(g.xA + (g.xD - g.xA) * u, g.bottom - (g.bottom - g.top) * level);
    }
    path.lineTo(g.xS, g.yS);
    for (var i = 1; i <= n; i++) {
      final u = i / n;
      final level = g.s * math.pow(1 - u, 3);
      path.lineTo(g.xS + (g.xR - g.xS) * u, g.bottom - (g.bottom - g.top) * level);
    }
    final fill = Path.from(path)
      ..lineTo(g.xR, g.bottom)
      ..close();
    canvas.drawPath(fill, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.02)]).createShader(Offset.zero & size));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round);
    canvas.drawLine(Offset(g.xS, g.top), Offset(g.xS, g.bottom), Paint()..color = Colors.white.withValues(alpha: 0.08));
    for (final (h, at) in [(_Handle.attack, g.attack), (_Handle.decay, g.decay), (_Handle.release, g.release)]) {
      final on = h == active;
      canvas.drawCircle(at, on ? 7 : 5, Paint()..color = Neon.panelHi);
      canvas.drawCircle(at, on ? 7 : 5, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      if (on) canvas.drawCircle(at, 14, Paint()..color = color.withValues(alpha: 0.15));
    }
  }

  @override
  bool shouldRepaint(covariant _EnvelopePainter o) =>
      o.g.a != g.a || o.g.d != g.d || o.g.s != g.s || o.g.r != g.r || o.g.size != g.size || o.color != color || o.active != active;
}
