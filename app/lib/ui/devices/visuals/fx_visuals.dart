// Effect visuals drawn from parameters: an EQ curve with draggable band nodes, a saturation transfer curve, a
// compressor's transfer graph, delay echoes and a reverb tail. All are approximations computed in Dart (labelled "≈").
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../device_scope.dart';
import 'filter_curve.dart' show freqToX, xToFreq;
import 'grab.dart';

enum EqKind { lowShelf, peak, highShelf, lowCut, highCut }

/// One EQ band: its kind, where its frequency and gain come from (a parameter, or a fixed number), its Q.
class EqBand {
  const EqBand({required this.kind, this.freqParam, this.fixedFreq = 1000, this.gainParam, this.qParam,
    this.onParam, this.label = ''});
  final EqKind kind;
  final String? freqParam, gainParam, qParam, onParam;
  final double fixedFreq;
  final String label;
}

/// The approximate gain in dB of [kind] at [hz] (centre [fc], [gain] dB, width [q]): smooth log-frequency shapes
/// for drawing, not the filters' exact responses.
double eqBandDb(EqKind kind, double hz, double fc, double gain, double q) {
  final o = math.log(hz / fc) / math.ln2; // octaves from the centre
  final width = 1.2 / q.clamp(0.1, 18.0);
  return switch (kind) {
    EqKind.peak => gain * math.exp(-o * o / (2 * width * width)),
    EqKind.lowShelf => gain / (1 + math.exp(o * 3)),
    EqKind.highShelf => gain / (1 + math.exp(-o * 3)),
    EqKind.lowCut => o >= 0 ? -3 * math.exp(-o * 2) : -3 + 12 * o * (1 + q / 2),
    EqKind.highCut => o <= 0 ? -3 * math.exp(o * 2) : -3 - 12 * o * (1 + q / 2),
  };
}

/// An EQ's summed curve with a node per band: drag a node sideways for its frequency (when it has a parameter),
/// up and down for its gain; double-tap resets the band. [rangeDb] is the top and bottom of the view.
class EqCurve extends StatefulWidget {
  const EqCurve({super.key, required this.bands, this.height = 120, this.rangeDb = 18, this.color, this.spectrum});
  final List<EqBand> bands;
  final double height, rangeDb;
  final Color? color;

  /// A live spectrum (0..1 per bin, low to high frequency on the same log axis) to draw behind the curve: the
  /// seam for the engine's display data. Null draws none.
  final List<double>? spectrum;

  @override
  State<EqCurve> createState() => _EqCurveState();
}

class _EqCurveState extends State<EqCurve> {
  int? _active;
  double _x = 0, _gain = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final color = widget.color ?? scope.accent;
    double freq(EqBand b) => b.freqParam == null ? b.fixedFreq : t.value(b.freqParam!);
    double gain(EqBand b) => b.gainParam == null ? 0 : t.value(b.gainParam!);
    double q(EqBand b) => b.qParam == null ? 0.9 : t.value(b.qParam!);
    bool on(EqBand b) => b.onParam == null || t.value(b.onParam!) >= 0.5;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = widget.height;
      double y(double db) => h / 2 - db / widget.rangeDb * (h / 2 - 8);
      Offset node(EqBand b) => Offset(freqToX(freq(b), w), y(gain(b)));
      int? nearest(Offset p) {
        int? best;
        var d = 32.0;
        for (var i = 0; i < widget.bands.length; i++) {
          final dist = (node(widget.bands[i]) - p).distance;
          if (dist < d) {
            d = dist;
            best = i;
          }
        }
        return best;
      }

      return GrabPan(
        key: const ValueKey('eq-curve'),
        grabs: (p) => nearest(p) != null,
        onStart: (p) {
          final i = nearest(p);
          if (i == null) return;
          _x = node(widget.bands[i]).dx;
          _gain = gain(widget.bands[i]);
          setState(() => _active = i);
        },
        onUpdate: (_, d) {
          final i = _active;
          if (i == null) return;
          final b = widget.bands[i];
          if (b.freqParam != null) {
            _x = (_x + d.dx).clamp(0.0, w);
            t.setLive(b.freqParam!, xToFreq(_x, w));
          }
          if (b.gainParam != null) {
            _gain -= d.dy / (h / 2 - 8) * widget.rangeDb;
            t.setLive(b.gainParam!, _gain);
          }
        },
        onEnd: () {
          if (_active != null) t.commit();
          setState(() => _active = null);
        },
        onDoubleTap: () {
          final ids = [for (final b in widget.bands) ...[?b.gainParam]];
          t.setAll({for (final id in ids) if (t.param(id) case final p?) id: p.defaultValue});
        },
        child: SizedBox(height: h, child: CustomPaint(painter: _EqPainter(
          curve: (hz) {
            var db = 0.0;
            for (final b in widget.bands) {
              if (on(b)) db += eqBandDb(b.kind, hz, freq(b), gain(b), q(b));
            }
            return db;
          },
          nodes: [for (final b in widget.bands) (node(b), on(b), b.label)],
          y: y,
          color: color,
          active: _active,
          spectrum: widget.spectrum,
        ))),
      );
    });
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({required this.curve, required this.nodes, required this.y, required this.color, this.active, this.spectrum});
  final double Function(double hz) curve;
  final List<(Offset, bool, String)> nodes;
  final double Function(double db) y;
  final Color color;
  final int? active;
  final List<double>? spectrum;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = Neon.ink.withValues(alpha: 0.05);
    for (final hz in [100.0, 1000.0, 10000.0]) {
      final x = freqToX(hz, size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), Paint()..color = Neon.ink.withValues(alpha: 0.1));
    if (spectrum case final s? when s.isNotEmpty) {
      final p = Path()..moveTo(0, size.height);
      for (var i = 0; i < s.length; i++) {
        p.lineTo(size.width * i / (s.length - 1), size.height * (1 - s[i].clamp(0.0, 1.0)));
      }
      p
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(p, Paint()..color = Neon.violet.withValues(alpha: 0.12));
    }
    final path = Path();
    final n = math.max(64, size.width ~/ 2);
    for (var i = 0; i <= n; i++) {
      final x = size.width * i / n;
      final py = y(curve(xToFreq(x, size.width)));
      i == 0 ? path.moveTo(x, py) : path.lineTo(x, py);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, y(0))
      ..lineTo(0, y(0))
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8);
    for (var i = 0; i < nodes.length; i++) {
      final (at, on, label) = nodes[i];
      final c = on ? color : Neon.dim;
      if (i == active) canvas.drawCircle(at, 14, Paint()..color = c.withValues(alpha: 0.18));
      canvas.drawCircle(at, 6, Paint()..color = Neon.panelHi);
      canvas.drawCircle(at, 6, Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      if (label.isNotEmpty) {
        final tp = TextPainter(text: TextSpan(text: label, style: Neon.code(size: 8, color: c)),
          textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, at + Offset(-tp.width / 2, 8));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EqPainter o) => true;
}

/// A saturation curve: input level across, output up, for shape [type] (0 drive, 1 hard clip, 2 fold, 3 crush)
/// at [drive], blended with the dry line by [mix]. An approximation of the shapes, for drawing.
class SaturationCurve extends StatelessWidget {
  const SaturationCurve({super.key, required this.type, required this.drive, this.mix = 1, this.height = 90, this.color = Neon.pink});
  final int type;
  final double drive, mix, height;
  final Color color;

  static double shape(int type, double x, double drive) {
    final d = math.max(1.0, drive);
    switch (type) {
      case 1:
        return (x * d).clamp(-1.0, 1.0);
      case 2:
        return math.sin(x * d * math.pi / 2);
      case 3:
        final steps = math.max(2.0, 18 - d * 0.8);
        return (x * steps).roundToDouble() / steps;
      default:
        return _tanh(x * d) / _tanh(d);
    }
  }

  static double _tanh(double x) {
    final e = math.exp(2 * x.clamp(-20.0, 20.0));
    return (e - 1) / (e + 1);
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: CustomPaint(painter: _CurvePainter(
    (x) => mix * shape(type, x, drive) + (1 - mix) * x, color, label: '≈ transfer')));
}

/// A compressor's static curve: input level (dB) across, output up, from [threshold] dB, [ratio] and [knee] dB,
/// with a gain-reduction bar fed by [gainReductionDb] (the display-data seam; null draws none).
class CompressorGraph extends StatelessWidget {
  const CompressorGraph({super.key, required this.threshold, required this.ratio, this.knee = 6, this.makeup = 0,
    this.height = 120, this.color = Neon.yellow, this.gainReductionDb, this.inputDb});
  final double threshold, ratio, knee, makeup, height;
  final Color color;
  final double? gainReductionDb, inputDb;

  static double outputDb(double x, double threshold, double ratio, double knee) {
    final r = math.max(1.0, ratio);
    final over = x - threshold;
    if (knee > 0 && over.abs() <= knee / 2) {
      final k = over + knee / 2;
      return x + (1 / r - 1) * k * k / (2 * knee);
    }
    return over <= 0 ? x : threshold + over / r;
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: Row(children: [
    Expanded(child: CustomPaint(painter: _CurvePainter((x) {
      final db = (x + 1) / 2 * 60 - 60; // -60..0 dB across
      return ((outputDb(db, threshold, ratio, knee) + makeup) + 60) / 60 * 2 - 1;
    }, color, label: 'in → out', marker: inputDb == null ? null : (inputDb! + 60) / 60 * 2 - 1))),
    const SizedBox(width: 6),
    SizedBox(width: 10, child: CustomPaint(painter: _GrPainter(gainReductionDb, color))),
  ]));
}

class _GrPainter extends CustomPainter {
  _GrPainter(this.gr, this.color);
  final double? gr;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(3));
    canvas.drawRRect(r, Paint()..color = Neon.ink.withValues(alpha: 0.05));
    if (gr == null) return;
    final h = (gr!.abs() / 24).clamp(0.0, 1.0) * size.height;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, h), Paint()..color = color.withValues(alpha: 0.8));
  }

  @override
  bool shouldRepaint(covariant _GrPainter o) => o.gr != gr || o.color != color;
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.f, this.color, {this.label = '', this.marker});
  final double Function(double x) f; // -1..1 → -1..1
  final Color color;
  final String label;
  final double? marker;

  @override
  void paint(Canvas canvas, Size size) {
    Offset pt(double x, double v) => Offset((x + 1) / 2 * size.width, (1 - (v.clamp(-1.0, 1.0) + 1) / 2) * size.height);
    final faint = Paint()..color = Neon.ink.withValues(alpha: 0.06);
    canvas.drawLine(pt(-1, -1), pt(1, 1), faint);
    canvas.drawLine(pt(-1, 0), pt(1, 0), faint);
    canvas.drawLine(pt(0, -1), pt(0, 1), faint);
    final path = Path();
    const n = 120;
    for (var i = 0; i <= n; i++) {
      final x = -1 + 2 * i / n;
      final p = pt(x, f(x));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8);
    if (marker != null) canvas.drawCircle(pt(marker!, f(marker!)), 4, Paint()..color = color);
    if (label.isNotEmpty) {
      final tp = TextPainter(text: TextSpan(text: label, style: Neon.code(size: 8, color: Neon.dim)),
        textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, const Offset(4, 2));
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter o) => true;
}

/// Delay echoes: one bar per repeat at [seconds] apart, each [feedback] times the last, alternating sides when
/// [pingPong]; [mix] sets the first echo's height.
class DelayEchoes extends StatelessWidget {
  const DelayEchoes({super.key, required this.seconds, required this.feedback, this.mix = 0.5, this.pingPong = true,
    this.height = 64, this.color = Neon.blue});
  final double seconds, feedback, mix, height;
  final bool pingPong;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: CustomPaint(painter: _EchoPainter(this)));
}

class _EchoPainter extends CustomPainter {
  _EchoPainter(this.d);
  final DelayEchoes d;

  @override
  void paint(Canvas canvas, Size size) {
    final span = math.max(2.0, d.seconds * 8); // the view shows about eight echoes, at least two seconds
    final mid = size.height / 2;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = Neon.ink.withValues(alpha: 0.06));
    canvas.drawLine(const Offset(3, 4), Offset(3, size.height - 4), Paint()..color = Neon.text..strokeWidth = 2);
    var level = d.mix.clamp(0.0, 1.0);
    for (var k = 1; k < 64 && level > 0.01; k++) {
      final x = 3 + (size.width - 6) * (k * d.seconds / span);
      if (x > size.width) break;
      final h = (mid - 4) * level;
      final up = !d.pingPong || k.isOdd;
      canvas.drawLine(Offset(x, mid), Offset(x, up ? mid - h : mid + h), Paint()
        ..color = (up ? d.color : Neon.violet).withValues(alpha: 0.4 + 0.6 * level)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round);
      level *= d.feedback;
    }
  }

  @override
  bool shouldRepaint(covariant _EchoPainter o) => true;
}

/// A reverb tail: early reflections then a decay [decaySeconds] long, denser with [size], darker with [damping].
class ReverbTail extends StatelessWidget {
  const ReverbTail({super.key, required this.decaySeconds, required this.size, required this.damping, this.mix = 0.3,
    this.height = 64, this.color = Neon.violet});
  final double decaySeconds, size, damping, mix, height;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(height: height, child: CustomPaint(painter: _TailPainter(this)));
}

class _TailPainter extends CustomPainter {
  _TailPainter(this.r);
  final ReverbTail r;

  @override
  void paint(Canvas canvas, Size size) {
    final span = math.max(1.0, r.decaySeconds * 1.3);
    final bars = (40 + r.size * 80).round();
    var seed = 12345;
    double rand() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return seed / 0x7FFFFFFF;
    }

    for (var i = 0; i < bars; i++) {
      final tSec = span * i / bars;
      final env = math.exp(-6.9 * tSec / math.max(0.1, r.decaySeconds)) * (0.3 + 0.7 * r.mix);
      final x = size.width * i / bars;
      final h = (size.height - 6) * env * (0.5 + 0.5 * rand());
      final c = Color.lerp(r.color, Neon.blue, (r.damping * tSec / span).clamp(0.0, 1.0))!;
      canvas.drawLine(Offset(x, size.height - 3), Offset(x, size.height - 3 - h), Paint()
        ..color = c.withValues(alpha: 0.35 + 0.5 * env)
        ..strokeWidth = math.max(1.0, size.width / bars * 0.6));
    }
  }

  @override
  bool shouldRepaint(covariant _TailPainter o) => true;
}
