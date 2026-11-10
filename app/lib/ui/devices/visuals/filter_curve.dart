// A filter's response curve (approximate, computed in Dart) with a handle: sideways for the cutoff, up and down for resonance.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/flagship_shapes.dart';
import '../../theme.dart';
import '../device_scope.dart';
import 'grab.dart';

/// Frequency ↔ x on a log axis from 20 Hz to 20 kHz.
double freqToX(double hz, double width) => width * (math.log(hz.clamp(20.0, 20000.0) / 20) / math.log(1000));
double xToFreq(double x, double width) => 20 * math.pow(1000, (x / width).clamp(0.0, 1.0)).toDouble();

/// The filter whose parameters are `<prefix>type`, `cutoff`, `resonance`, `morph` and `mix`. The curve is an
/// approximation (labelled "≈" on screen) of where the filter cuts and rings, not the engine's exact response.
class FilterCurve extends StatefulWidget {
  const FilterCurve({super.key, required this.prefix, this.height = 110, this.color});
  final String prefix;
  final double height;
  final Color? color;

  @override
  State<FilterCurve> createState() => _FilterCurveState();
}

class _FilterCurveState extends State<FilterCurve> {
  bool _dragging = false;
  double _res = 0, _x = 0;

  String _id(String n) => '${widget.prefix}$n';

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final color = widget.color ?? scope.accent;
    final pCut = t.param(_id('cutoff'));
    if (pCut == null) return const SizedBox.shrink();
    final on = t.value(_id('on')) >= 0.5;
    final type = t.value(_id('type')).round();
    final cutoff = t.value(pCut.id), res = t.value(_id('resonance'));
    final morph = t.value(_id('morph')), mix = t.value(_id('mix'));
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return GrabPan(
        key: ValueKey('filter-${widget.prefix}'),
        onStart: (_) {
          _res = res;
          _x = freqToX(cutoff, w);
          setState(() => _dragging = true);
        },
        onUpdate: (_, d) {
          _x = (_x + d.dx).clamp(0.0, w);
          t.setLive(pCut.id, xToFreq(_x, w).clamp(pCut.min, pCut.max));
          _res = (_res - d.dy / (widget.height * 0.9)).clamp(0.0, 1.0);
          t.setLive(_id('resonance'), _res);
        },
        onEnd: () {
          if (_dragging) t.commit();
          setState(() => _dragging = false);
        },
        onDoubleTap: () => t.setAll({
          pCut.id: pCut.defaultValue,
          if (t.param(_id('resonance')) case final p?) p.id: p.defaultValue,
        }),
        child: SizedBox(height: widget.height, child: CustomPaint(
          painter: _FilterPainter(type, cutoff, res, morph, mix, on ? color : Neon.dim, _dragging),
          child: Align(alignment: Alignment.topRight, child: Padding(padding: const EdgeInsets.all(4), child: Text(
            '≈ ${filterTypeNames[type.clamp(0, filterTypeNames.length - 1)]} · ${formatParamValue(pCut, cutoff)} Hz',
            style: Neon.code(size: 9, color: Neon.dim)))),
        )),
      );
    });
  }
}

class _FilterPainter extends CustomPainter {
  _FilterPainter(this.type, this.cutoff, this.res, this.morph, this.mix, this.color, this.active);
  final int type;
  final double cutoff, res, morph, mix;
  final Color color;
  final bool active;

  static const top = 24.0, bottom = -36.0; // dB at the top and bottom edges

  @override
  void paint(Canvas canvas, Size size) {
    double y(double db) => (top - db.clamp(bottom, top)) / (top - bottom) * size.height;
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.05);
    for (final hz in [100.0, 1000.0, 10000.0]) {
      final x = freqToX(hz, size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), Paint()..color = Colors.white.withValues(alpha: 0.09));
    final path = Path();
    final n = math.max(64, size.width ~/ 2);
    for (var i = 0; i <= n; i++) {
      final x = size.width * i / n;
      final db = filterResponseDb(xToFreq(x, size.width), type: type, cutoff: cutoff, resonance: res, morph: morph, mix: mix);
      i == 0 ? path.moveTo(x, y(db)) : path.lineTo(x, y(db));
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0.0)]).createShader(Offset.zero & size));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8);
    final hx = freqToX(cutoff, size.width);
    final hy = y(filterResponseDb(cutoff, type: type, cutoff: cutoff, resonance: res, morph: morph, mix: mix));
    if (active) canvas.drawCircle(Offset(hx, hy), 14, Paint()..color = color.withValues(alpha: 0.15));
    canvas.drawCircle(Offset(hx, hy), active ? 7 : 5, Paint()..color = Neon.panelHi);
    canvas.drawCircle(Offset(hx, hy), active ? 7 : 5, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _FilterPainter o) => o.type != type || o.cutoff != cutoff || o.res != res ||
      o.morph != morph || o.mix != mix || o.color != color || o.active != active;
}
