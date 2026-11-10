// The device kit's controls: mode tiles with drawn icons, glowing toggles, an XY pad, level meters, knob rows and the "More" fold.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import 'feel.dart';
import 'grab_gesture.dart';
import 'hero.dart';

/// Draws a small picture of choice [index] in [rect] (a mode's curve, a filter's shape, a waveform).
typedef ChoiceIcon = void Function(Canvas canvas, Rect rect, int index, Color color);

/// A choice parameter as a row of big tiles, each a drawn icon over its name (FabFilter Saturn's style picker):
/// readable at phone size and a 48 dp target. [names] shortens the descriptor's labels.
class ModeTiles extends StatelessWidget {
  const ModeTiles(this.paramId, {super.key, required this.icon, this.names, this.color, this.height = 54});
  final String paramId;
  final ChoiceIcon icon;
  final List<String>? names;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final labels = names ?? p.choices;
    final n = p.choices.length;
    final sel = (t.value(p.id) - p.min).round().clamp(0, n - 1);
    final c = color ?? scope.accent;
    return SizedBox(height: height, child: Row(children: [
      for (var k = 0; k < n; k++)
        Expanded(child: Padding(padding: EdgeInsets.only(right: k < n - 1 ? 4 : 0), child: Semantics(
          button: true,
          selected: k == sel,
          label: '${p.label}: ${p.choices[k]}',
          child: GestureDetector(
            key: ValueKey('mode-${p.id}-$k'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              DeviceFeel.tap();
              t.set(p.id, p.min + k);
            },
            child: AnimatedContainer(
              duration: Motion.fade(Motion.small, Motion.of(context)),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: k == sel ? c.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.03),
                border: Border.all(color: k == sel ? c : Neon.line, width: k == sel ? 1.5 : 1),
                boxShadow: k == sel ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 10)] : null),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(6, 6, 6, 2), child: CustomPaint(
                  size: Size.infinite, painter: _IconPainter(icon, k, k == sel ? c : Neon.dim)))),
                Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(k < labels.length ? labels[k] : p.choices[k],
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9.5, letterSpacing: 0.3,
                    fontWeight: FontWeight.w800, color: k == sel ? Neon.text : Neon.dim))),
              ]),
            ),
          ),
        ))),
    ]));
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.icon, this.index, this.color);
  final ChoiceIcon icon;
  final int index;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => icon(canvas, Offset.zero & size, index, color);

  @override
  bool shouldRepaint(covariant _IconPainter o) => o.index != index || o.color != color || o.icon != icon;
}

/// Draws y = [f](x) for x in −1..1 (y −1..1) inside [r]: the stroke of a choice icon.
void iconCurve(Canvas canvas, Rect r, Color color, double Function(double x) f, {double width = 1.8, int steps = 40}) {
  final path = Path();
  for (var i = 0; i <= steps; i++) {
    final x = -1 + 2 * i / steps;
    final p = Offset(r.left + (x + 1) / 2 * r.width, r.center.dy - f(x).clamp(-1.0, 1.0) * r.height / 2);
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(path, Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round);
}

/// An Off/On parameter as a pill with its name, glowing in [color] when on (Freeze, Invert, Bass mono).
class DeviceToggle extends StatelessWidget {
  const DeviceToggle(this.paramId, {super.key, this.label, this.icon, this.color});
  final String paramId;
  final String? label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null) return const SizedBox.shrink();
    final on = t.value(p.id) >= (p.min + p.max) / 2;
    final c = color ?? scope.accent;
    return Semantics(
      toggled: on,
      label: p.label,
      child: GestureDetector(
        key: ValueKey('toggle-${p.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          DeviceFeel.tap();
          t.set(p.id, on ? p.min : p.max);
        },
        child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: on ? c.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: on ? c : Neon.line),
            boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 10)] : null),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon ?? Icons.power_settings_new, size: 15, color: on ? c : Neon.dim),
            const SizedBox(width: 6),
            Text((label ?? p.label).toUpperCase(), style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w800,
              color: on ? Neon.text : Neon.dim)),
          ]),
        ),
      ),
    );
  }
}

/// Two parameters on one pad: [xParam] across, [yParam] up, each on its descriptor's taper; drag anywhere, a
/// second finger for fine, double-tap for both defaults. [painter] draws behind the dot.
class XYPad extends StatefulWidget {
  const XYPad({super.key, required this.xParam, required this.yParam, this.height = 160, this.color, this.painter,
    this.caption});
  final String xParam, yParam;
  final double height;
  final Color? color;
  final CustomPainter Function(Offset dot)? painter;
  final String? caption;

  @override
  State<XYPad> createState() => _XYPadState();
}

class _XYPadState extends State<XYPad> {
  bool _active = false;
  double _x = 0, _y = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final px = t.param(widget.xParam), py = t.param(widget.yParam);
    if (px == null || py == null) return const SizedBox.shrink();
    final tx = taperOf(px), ty = taperOf(py);
    final c = widget.color ?? scope.accent;
    return HeroCanvas(color: c, height: widget.height, caption: widget.caption,
      readout: Text('${shortParamLabel(px, px.id)} ${formatParamValue(px, t.value(px.id))} · '
          '${shortParamLabel(py, py.id)} ${formatParamValue(py, t.value(py.id))}'),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final dot = Offset(tx.position(t.value(px.id)) * w, (1 - ty.position(t.value(py.id))) * h);
        return GrabGesture(
          key: ValueKey('xy-${px.id}-${py.id}'),
          onStart: (p, _) {
            _x = tx.position(t.value(px.id));
            _y = ty.position(t.value(py.id));
            setState(() => _active = true);
          },
          onUpdate: (u) {
            final f = DeviceFingers.fine;
            _x = (_x + u.delta.dx / w * f).clamp(0.0, 1.0);
            _y = (_y - u.delta.dy / h * f).clamp(0.0, 1.0);
            t.setLive(px.id, tx.value(_x));
            t.setLive(py.id, ty.value(_y));
          },
          onEnd: () {
            t.commit();
            setState(() => _active = false);
          },
          onDoubleTap: (_) => t.setAll({px.id: px.defaultValue, py.id: py.defaultValue}),
          child: CustomPaint(
            painter: widget.painter?.call(dot),
            foregroundPainter: _DotPainter(dot, c, _active),
            child: const SizedBox.expand()),
        );
      }),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.dot, this.color, this.active);
  final Offset dot;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = color.withValues(alpha: active ? 0.4 : 0.18);
    canvas.drawLine(Offset(dot.dx, 0), Offset(dot.dx, size.height), line);
    canvas.drawLine(Offset(0, dot.dy), Offset(size.width, dot.dy), line);
    paintHandle(canvas, dot, color, active: active, r: 9);
  }

  @override
  bool shouldRepaint(covariant _DotPainter o) => o.dot != dot || o.color != color || o.active != active;
}

/// A vertical level meter: [db] (−60..0, or reduction 0..24 dB down from the top when [reduction]), a peak line,
/// its [label] under it.
class LevelMeter extends StatelessWidget {
  const LevelMeter({super.key, required this.db, required this.label, this.color, this.reduction = false,
    this.width = 12, this.height = 120});
  final double? db;
  final String label;
  final Color? color;
  final bool reduction;
  final double width, height;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DeviceScope.of(context).accent;
    final v = db == null ? 0.0 : (reduction ? (db!.abs() / 24).clamp(0.0, 1.0) : dbUnit(db!));
    return Semantics(
      label: '$label meter',
      value: db == null ? 'no signal' : '${db!.toStringAsFixed(1)} dB',
      child: SizedBox(width: math.max(width, 24), height: height, child: Column(children: [
        Expanded(child: SizedBox(width: width, child: CustomPaint(painter: _MeterPainter(v, c, reduction)))),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(fontSize: 8, letterSpacing: 0.8, fontWeight: FontWeight.w800, color: Neon.dim)),
      ])),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.v, this.color, this.reduction);
  final double v;
  final Color color;
  final bool reduction;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(r, Paint()..color = Colors.white.withValues(alpha: 0.05));
    canvas.save();
    canvas.clipRRect(r);
    final h = size.height * v;
    final rect = reduction ? Rect.fromLTWH(0, 0, size.width, h) : Rect.fromLTWH(0, size.height - h, size.width, h);
    canvas.drawRect(rect, Paint()
      ..shader = LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: reduction ? [Neon.pink, Neon.pink.withValues(alpha: 0.6)] : [color.withValues(alpha: 0.7), color, Neon.pink])
          .createShader(Offset.zero & size));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MeterPainter o) => o.v != v || o.color != color || o.reduction != reduction;
}

/// Input, gain reduction (when the device has one) and output meters side by side, from the live frame.
class MeterStack extends StatelessWidget {
  const MeterStack({super.key, this.height = 150, this.gr = true});
  final double height;
  final bool gr;

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) => Row(mainAxisSize: MainAxisSize.min, children: [
    LevelMeter(db: f?.inputDb, label: 'IN', height: height),
    if (gr) LevelMeter(db: f?.gainReductionDb, label: 'GR', reduction: true, height: height),
    LevelMeter(db: f?.outputDb, label: 'OUT', height: height),
  ]));
}

/// The input and output levels as one line of text (the readout of a hero), or nothing while there is no live data.
class LevelReadout extends StatelessWidget {
  const LevelReadout({super.key});

  @override
  Widget build(BuildContext context) => DeviceDisplay(builder: (context, f) {
    if (f == null) return const SizedBox.shrink();
    String db(double? v) => v == null ? '' : '${v.toStringAsFixed(1)} dB';
    return Text('IN ${db(f.inputDb)}  OUT ${db(f.outputDb)}', style: Neon.code(size: 9, color: Neon.dim));
  });
}

/// Big knobs spread evenly across the width, in balanced rows when they don't fit on one (six knobs on a phone: two
/// rows of three, not five and one).
class KnobRow extends StatelessWidget {
  const KnobRow(this.knobs, {super.key, this.size = 50, this.labels = const {}, this.color});
  final List<String> knobs;
  final double size;
  final Color? color;

  /// Shorter labels by parameter id (inside an "LFO" group, "Amount" rather than "LFO amount").
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final ids = [for (final k in knobs) if (t.param(k) != null) k];
    if (ids.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      final item = math.max(52.0, size + 16);
      final fit = math.max(1, (box.maxWidth / item).floor());
      final rows = (ids.length / fit).ceil();
      final per = (ids.length / rows).ceil();
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < rows; r++)
          Padding(padding: EdgeInsets.only(top: r == 0 ? 0 : 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (final id in ids.skip(r * per).take(per)) DeviceKnob(id, size: size, label: labels[id], color: color),
          ])),
      ]));
    });
  }
}

/// Progressive disclosure: the device's advanced controls behind a "MORE" fold, closed by default.
class DeviceFold extends StatefulWidget {
  const DeviceFold({super.key, required this.child, this.title = 'MORE'});
  final Widget child;
  final String title;

  @override
  State<DeviceFold> createState() => _DeviceFoldState();
}

class _DeviceFoldState extends State<DeviceFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = DeviceScope.of(context).accent;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        key: const ValueKey('device-fold'),
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          DeviceFeel.tap();
          setState(() => _open = !_open);
        },
        child: SizedBox(height: 40, child: Row(children: [
          AnimatedRotation(turns: _open ? 0.25 : 0, duration: Motion.fade(Motion.small, Motion.of(context)),
            child: Icon(Icons.chevron_right, size: 18, color: c)),
          const SizedBox(width: 4),
          Text(widget.title, style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: c)),
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: c.withValues(alpha: 0.2))),
        ])),
      ),
      AnimatedSize(
        duration: Motion.fade(Motion.standard, Motion.of(context)),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _open ? Padding(padding: const EdgeInsets.only(bottom: 8), child: widget.child) : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

/// Every parameter in [only] (or all not in [skip]) as knobs, choices and toggles: the fold's contents.
class ParamGrid extends StatelessWidget {
  const ParamGrid({super.key, this.skip = const {}, this.only});
  final Set<String> skip;
  final List<String>? only;

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final all = t.info?.parameters ?? const <ComponentParameterInfo>[];
    final params = only == null
        ? [for (final p in all) if (!skip.contains(p.id)) p]
        : [for (final id in only!) ?t.param(id)];
    final toggles = [for (final p in params) if (p.isChoice && p.choices.length == 2 && p.choices.first == 'Off') p];
    final choices = [for (final p in params) if (p.isChoice && !toggles.contains(p)) p];
    final knobs = [for (final p in params) if (!p.isChoice) p];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (toggles.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final p in toggles) DeviceToggle(p.id),
      ])),
      for (final p in choices) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 92, child: Text(p.label, maxLines: 2, style: const TextStyle(fontSize: 10, color: Neon.dim))),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: DeviceChoice(p.id, maxSegments: 5))),
      ])),
      if (knobs.isNotEmpty) KnobRow([for (final p in knobs) p.id], size: 42),
    ]);
  }
}
