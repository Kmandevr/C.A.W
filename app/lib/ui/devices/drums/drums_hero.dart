// The drums' waveform hero: the shown pad's last hit (live) or its sound drawn from the knobs (≈), its pitch curve, and drags for the pitch sweep and decay; in Points mode the pitch shape's four points drag in place.
import '../kit/repaint.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/device_target.dart';
import '../../../model/drums.dart';
import '../../theme.dart';
import '../../widgets.dart' show LiveIsland;
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/feel.dart';
import '../kit/grab_gesture.dart';
import '../kit/hero.dart';
import 'drums_pads.dart';

/// What a hero drag moves: a pair of knobs (x then y, either null), or point [point] of the pitch shape
/// (0: the start, `body_pitch`; 1..4: `penv_tN` across and `penv_pN` up).
class _Grab {
  const _Grab({this.x, this.y, this.point});
  final String? x, y;
  final int? point;
}

/// The hero of pad [pad]: drag the left quarter for the pitch sweep (up: depth, sideways: its time), anywhere else
/// sideways for the decay and up or down for the pitch; in Points mode grab a point to move it.
class DrumHero extends StatefulWidget {
  const DrumHero({super.key, required this.pad, this.height = 190});
  final int pad;
  final double height;

  @override
  State<DrumHero> createState() => _DrumHeroState();
}

class _DrumHeroState extends State<DrumHero> {
  _Grab? _grab;
  double _x = 0, _y = 0;
  (double, double)? _frozenAxis;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final p = DrumPadView(t, layout, widget.pad);
    final shape = DrumPitchShape(p);
    final sketch = DrumSketch.of(p);
    final body = p.on('body_on');
    final c = p.used ? drumTypeColor(p.v('type').round()) : scope.accent;
    final axis = _frozenAxis ?? drumHeroAxis(shape);
    final readout = body
        ? '${shape.fEnd.toStringAsFixed(shape.fEnd < 100 ? 1 : 0)} Hz'
            '${sketch.decayId == null ? '' : ' · ${formatParamValue(t.param(sketch.decayId!), t.value(sketch.decayId!))}'}'
        : (sketch.decayId == null ? '' : formatParamValue(t.param(sketch.decayId!), t.value(sketch.decayId!)));
    return HeroCanvas(
      color: c,
      height: widget.height,
      caption: '${padLabel(widget.pad)} · ${p.used ? p.typeName.toUpperCase() : 'EMPTY'}${shape.points && body ? ' · POINTS' : ''}',
      readout: Text(readout),
      child: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        return GrabGesture(
          key: const ValueKey('drums-hero'),
          onStart: (at, _) => _start(t, p, shape, at, size, axis),
          onUpdate: (u) => _update(t, p, shape, u, size),
          onEnd: () {
            t.commit();
            DeviceFeel.release();
            setState(() {
              _grab = null;
              _frozenAxis = null;
            });
          },
          onDoubleTap: (_) {
            final id = p.id('penv_mode');
            if (body) t.set(id, shape.points ? 0 : 1);
          },
          // A live island: the 30 Hz frames rebuild, lay out and repaint the drawing alone, not the page around it.
          child: LiveIsland(child: DeviceDisplay(builder: (context, f) {
            final live = f is DrumsDisplayFrame && f.shownPad == widget.pad && f.waveSeconds > 0 ? f : null;
            return CustomPaint(size: size, painter: _HeroPainter(
              color: c, second: scope.secondary, sketch: sketch, live: live, shape: body ? shape : null, axis: axis,
              active: _grab?.point));
          })),
        );
      }),
    );
  }

  /// The hero's time axis: the pitch shape's span in Points mode (zoomed to it), else the sound's length.
  static double _seconds(DrumPitchShape? s, DrumSketch sketch, DrumsDisplayFrame? live) {
    if (s != null && s.points) return math.max(0.01, s.span);
    return live?.waveSeconds ?? sketch.seconds;
  }

  void _start(DeviceTarget t, DrumPadView p, DrumPitchShape shape, Offset at, Size size, (double, double) axis) {
    DeviceFeel.grab();
    _Grab g;
    if (p.on('body_on') && shape.points) {
      var best = -1;
      var dist = 32.0;
      for (var i = 0; i <= 4; i++) {
        final d = (drumHeroPoint(shape, i, size, axis) - at).distance;
        if (d < dist) {
          dist = d;
          best = i;
        }
      }
      if (best >= 0) {
        _frozenAxis = axis;
        setState(() => _grab = _Grab(point: best));
        return;
      }
    }
    final decay = DrumSketch.of(p).decayId;
    g = at.dx < size.width * 0.25 && p.on('body_on')
        ? _Grab(x: shape.points ? null : p.id('body_ptime'), y: p.id('body_pitch'))
        : _Grab(x: decay, y: p.on('body_on') ? p.id('body_freq') : null);
    double pos(String? id) => id == null ? 0 : (t.param(id) == null ? 0 : taperOf(t.param(id)!).position(t.value(id)));
    _x = pos(g.x);
    _y = pos(g.y);
    setState(() => _grab = g);
  }

  void _update(DeviceTarget t, DrumPadView p, DrumPitchShape shape, GrabUpdate u, Size size) {
    final g = _grab;
    if (g == null) return;
    final fine = DeviceFingers.fine;
    if (g.point case final i?) {
      final axis = _frozenAxis ?? drumHeroAxis(shape);
      final dSt = -u.delta.dy / (size.height - 28) * (axis.$2 - axis.$1) * fine;
      if (i == 0) {
        t.setLive(p.id('body_pitch'), p.v('body_pitch') + dSt);
      } else {
        final secs = math.max(0.01, shape.span);
        final dT = u.delta.dx / (size.width - 24) * secs / shape.timeScale * fine;
        t.setLive(p.id('penv_t$i'), p.v('penv_t$i') + dT);
        t.setLive(p.id('penv_p$i'), p.v('penv_p$i') + dSt);
      }
      return;
    }
    if (g.x case final id?) {
      _x = (_x + u.delta.dx / size.width * fine).clamp(0.0, 1.0);
      t.setLive(id, taperOf(t.param(id)!).value(_x));
    }
    if (g.y case final id?) {
      _y = (_y - u.delta.dy / size.height * fine).clamp(0.0, 1.0);
      t.setLive(id, taperOf(t.param(id)!).value(_y));
    }
  }
}

/// The pitch axis in semitones over the settled pitch, (low, high), held still while a point is dragged.
(double, double) drumHeroAxis(DrumPitchShape s) {
  var hi = s.depth, lo = 0.0;
  if (s.points) {
    for (final v in s.st) {
      hi = math.max(hi, v);
      lo = math.min(lo, v);
    }
  }
  return (math.min(-6.0, (lo / 12).floorToDouble() * 12 - 6), math.max(24.0, ((hi + 6) / 12).ceilToDouble() * 12));
}


/// Where point [i] of [s] (0: the start, 1..4) sits on a hero of [size] with pitch axis [axis].
Offset drumHeroPoint(DrumPitchShape s, int i, Size size, (double, double) axis) {
  final secs = math.max(0.01, s.span);
  final x = i == 0 ? 0.0 : s.pointTime(i - 1) / secs;
  final st = i == 0 ? s.depth : s.st[i - 1];
  return Offset(12 + x * (size.width - 24), drumHeroY(st, size, axis));
}

/// The height of [st] semitones on the hero.
double drumHeroY(double st, Size size, (double, double) axis) =>
    size.height - 10 - (st - axis.$1) / (axis.$2 - axis.$1) * (size.height - 28);


class _HeroPainter extends CustomPainter {
  _HeroPainter({required this.color, required this.second, required this.sketch, required this.live,
    required this.shape, required this.axis, required this.active});
  final Color color, second;
  final DrumSketch sketch;
  final DrumsDisplayFrame? live;
  final DrumPitchShape? shape;
  final (double, double) axis;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final secs = _DrumHeroState._seconds(shape, sketch, live);
    final waveSecs = live?.waveSeconds ?? sketch.seconds;
    final mx = live?.waveMax ?? sketch.max, mn = live?.waveMin ?? sketch.min;
    final mid = size.height * 0.55, amp = size.height * 0.4;
    final left = 12.0, w = size.width - 24;
    // The waveform as a filled band of each bin's maximum and minimum.
    final top = Path(), bottom = <Offset>[];
    final n = mx.length;
    var started = false;
    for (var i = 0; i < n; i++) {
      final t = waveSecs * (i + 0.5) / n;
      if (t > secs) break;
      final x = left + w * t / secs;
      final hi = mid - _soft(mx[i]) * amp, lo = mid - _soft(mn[i]) * amp;
      started ? top.lineTo(x, hi) : top.moveTo(x, hi);
      started = true;
      bottom.add(Offset(x, lo));
    }
    if (started) {
      final band = Path.from(top);
      for (final o in bottom.reversed) {
        band.lineTo(o.dx, o.dy);
      }
      band.close();
      canvas.drawPath(band, Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: Neon.ramp([
          color.withValues(alpha: 0.55), color.withValues(alpha: 0.18), color.withValues(alpha: 0.55)]))
            .createShader(Offset.zero & size));
      strokeGlow(canvas, top, color, width: 1.4);
    }
    canvas.drawLine(Offset(left, mid), Offset(left + w, mid), Paint()..color = color.withValues(alpha: 0.2));
    final s = shape;
    if (s != null) {
      // The pitch curve, in semitones over the settled pitch; live, the engine's own (Hz over its span).
      final curve = Path();
      final pitchLive = live != null && live!.pitchSpan > 0 && live!.pitch.any((v) => v > 0) && live!.penvMode == (s.points ? 1 : 0);
      final pts = pitchLive ? live!.pitch.length : 96;
      for (var i = 0; i < pts; i++) {
        final t = pitchLive ? live!.pitchSpan * i / (pts - 1) : secs * math.pow(i / (pts - 1), s.points ? 1 : 2.5);
        if (t > secs) break;
        final st = pitchLive ? 12 * math.log(math.max(1e-3, live!.pitch[i]) / s.fEnd) / math.ln2 : s.semitones(t);
        final o = Offset(left + w * t / secs, drumHeroY(st, size, axis));
        i == 0 ? curve.moveTo(o.dx, o.dy) : curve.lineTo(o.dx, o.dy);
      }
      strokeGlow(canvas, curve, second, width: 2);
      if (s.points) {
        for (var i = 0; i <= 4; i++) {
          paintHandle(canvas, drumHeroPoint(s, i, size, axis), second, active: active == i, r: 6,
            label: i == 0 ? null : '$i');
        }
      } else {
        // The sweep's grab zone.
        canvas.drawRect(Rect.fromLTWH(0, 0, size.width * 0.25, size.height),
          Paint()..color = second.withValues(alpha: 0.04));
        paintLabel(canvas, 'SWEEP', Offset(10, size.height - 10), second.withValues(alpha: 0.6), size: 8, weight: FontWeight.w800);
      }
      paintLabel(canvas, '${(s.fEnd * math.pow(2, s.depth / 12)).round()} → ${s.fEnd.round()} Hz',
        Offset(size.width - 10, size.height - 10), second, size: 8, align: 1, weight: FontWeight.w700);
    }
    if (live == null) paintLabel(canvas, '≈', Offset(size.width - 12, 24), Neon.dim, size: 10, align: 1);
  }

  /// Bins drawn on a gently compressed scale, so a quiet tail still shows.
  static double _soft(double v) => v.sign * math.pow(v.abs().clamp(0.0, 1.0), 0.7).toDouble();

  @override
  bool shouldRepaint(covariant _HeroPainter o) =>
      paintInputsChanged([o.color, o.second, o.sketch, o.live, o.shape, o.axis, o.active], [color, second, sketch, live, shape, axis, active]);
}
