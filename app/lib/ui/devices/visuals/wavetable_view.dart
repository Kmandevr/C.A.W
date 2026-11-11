// An oscillator's wavetable: the frames stacked in depth, the current cycle (with its warp) bright on top; drag for the frame.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../model/flagship_shapes.dart';
import '../../theme.dart';
import '../device_scope.dart';
import 'grab.dart';

/// The oscillator whose parameters are `<prefix>table`, `frame`, `warp` and `warp_amt`. The cycle is computed in
/// Dart from the engine's own table recipe (fewer harmonics, enough to draw), so it is the shape that plays; the
/// User table is drawn from the instrument's saved state, and Osc FM from the oscillator it hears.
/// Drag sideways for the frame position, up or down for the warp amount; double-tap resets both.
class WavetableView extends StatefulWidget {
  const WavetableView({super.key, required this.prefix, this.height = 104, this.color});
  final String prefix;
  final double height;
  final Color? color;

  @override
  State<WavetableView> createState() => _WavetableViewState();
}

class _WavetableViewState extends State<WavetableView> {
  double _frame = 0, _warp = 0;
  bool _dragging = false;

  String _id(String n) => '${widget.prefix}$n';

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final color = widget.color ?? scope.accent;
    if (t.param(_id('frame')) == null) return const SizedBox.shrink();
    final table = t.value(_id('table')).round().clamp(0, wavetableFrames.length - 1);
    final user = table == userTableIndex ? userWavetableOf(t.use?.state) : null;
    final frames = tableFrameCount(table, user);
    final frame = t.value(_id('frame'));
    final warp = Warp.values[t.value(_id('warp')).round().clamp(0, Warp.values.length - 1)];
    final amount = t.value(_id('warp_amt'));
    final ratio = t.param(_id('fm_ratio')) == null ? 1 : t.value(_id('fm_ratio')).round();
    final on = t.value(_id('on')) >= 0.5;
    // Osc FM: the oscillator before this one, one cycle at its pitch against this one's (unison left out).
    Float32List? modulator;
    var modRatio = 1.0;
    final n = int.tryParse(widget.prefix.replaceAll(RegExp(r'[^0-9]'), ''));
    if (warp == Warp.oscFm && n != null && t.param('osc${oscFmSource(n)}_table') != null) {
      final m = 'osc${oscFmSource(n)}_';
      if (t.value('${m}on') >= 0.5) {
        final mt = t.value('${m}table').round().clamp(0, wavetableFrames.length - 1);
        modulator = oscillatorCycle(mt, t.value('${m}frame'), Warp.none, 0, points: _points,
            user: mt == userTableIndex ? userWavetableOf(t.use?.state) : null);
        double offset(String p) => 12 * t.value('${p}octave') + t.value('${p}semi') + t.value('${p}fine') / 100;
        modRatio = math.pow(2, (offset(m) - offset(widget.prefix)) / 12).toDouble();
      }
    }
    return LayoutBuilder(builder: (context, box) => GrabPan(
      key: ValueKey('wt-${widget.prefix}'),
      onStart: (_) {
        _frame = frame;
        _warp = amount;
        setState(() => _dragging = true);
      },
      onUpdate: (_, d) {
        _frame = (_frame + d.dx / (box.maxWidth * 0.8)).clamp(0.0, 1.0);
        t.setLive(_id('frame'), _frame);
        if (warp != Warp.none && d.dy.abs() > 0) {
          _warp = (_warp - d.dy / 160).clamp(0.0, 1.0);
          t.setLive(_id('warp_amt'), _warp);
        }
      },
      onEnd: () {
        if (_dragging) t.commit();
        setState(() => _dragging = false);
      },
      onDoubleTap: () => t.setAll({
        _id('frame'): t.param(_id('frame'))!.defaultValue,
        if (t.param(_id('warp_amt')) case final p?) p.id: p.defaultValue,
      }),
      child: SizedBox(height: widget.height, child: CustomPaint(
        painter: _WavetablePainter(table, frame, warp, amount, on ? color : Neon.dim, _dragging, ratio,
            user: user, modulator: modulator, modRatio: modRatio),
        child: Align(alignment: Alignment.bottomLeft, child: Padding(padding: const EdgeInsets.all(4), child: Text(
          '${wavetableNames[table]}${table == userTableIndex && user == null ? ' (none: a sine)' : ''}'
          ' · ${(frame * (frames - 1) + 1).toStringAsFixed(1)}/$frames'
          '${warp == Warp.none || amount <= 0 ? '' : ' · ${warpNames[warp.index]} ${(amount * 100).round()}%'}',
          style: Neon.code(size: 9, color: Neon.dim)))),
      )),
    ));
  }
}

const _points = 192;

UserWavetable? _lastUser;
String? _lastState;

/// The User table in an instrument's saved state (base64, the flagship's "CWT1" form), parsed once per state.
UserWavetable? userWavetableOf(String? state) {
  if (state == null || state.isEmpty) return null;
  if (state != _lastState) {
    _lastState = state;
    try {
      _lastUser = UserWavetable.parse(base64Decode(state));
    } on FormatException {
      _lastUser = null;
    }
  }
  return _lastUser;
}

class _WavetablePainter extends CustomPainter {
  _WavetablePainter(this.table, this.frame, this.warp, this.amount, this.color, this.active, this.fmRatio,
      {this.user, this.modulator, this.modRatio = 1});
  final int table, fmRatio;
  final UserWavetable? user;
  final Float32List? modulator;
  final double modRatio;
  final double frame, amount;
  final Warp warp;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    const points = _points;
    final frames = tableFrameCount(table, user);
    // The frames recede up and to the right, the way a wavetable is usually drawn in depth.
    final depthX = size.width * 0.12, depthY = size.height * 0.22;
    final w = size.width - depthX - 8, h = (size.height - depthY - 18) / 2;
    Path cycle(List<double> s, double dx, double dy, double scale) {
      final p = Path();
      for (var i = 0; i <= points; i++) {
        final x = 4 + dx + w * i / points;
        final y = 4 + depthY - dy + h - s[i % points] * h * scale;
        i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
      }
      return p;
    }

    // At most 32 frames behind (an imported table can have 256), evenly through the table.
    final ghosts = frames <= 1 ? 1 : math.min(frames, 32);
    for (var f = ghosts - 1; f >= 0; f--) {
      final u = ghosts <= 1 ? 0.0 : f / (ghosts - 1);
      final s = oscillatorCycle(table, u, Warp.none, 0, points: points, user: user);
      canvas.drawPath(cycle(s, depthX * u, depthY * u, 0.55), Paint()
        ..color = color.withValues(alpha: 0.08 + 0.06 * (1 - (u - frame).abs()))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    final now = oscillatorCycle(table, frame, warp, amount, points: points, fmRatio: fmRatio, user: user,
        modulator: modulator, modRatio: modRatio);
    final path = cycle(now, depthX * frame, depthY * frame, 0.8);
    canvas.drawPath(path, Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 7 : 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _WavetablePainter o) => o.table != table || o.frame != frame || o.warp != warp ||
      o.amount != amount || o.color != color || o.active != active || o.fmRatio != fmRatio || o.user != user ||
      o.modulator != modulator || o.modRatio != modRatio;
}
