// A device editor's controls bound to the device's parameters: knobs with mod rings and drop targets, choices, power, sliders.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/mod_matrix.dart';
import '../arrange/knob.dart' show Taper;
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart' show ResetOnDoubleTap;
import 'device_scope.dart';
import 'kit/feel.dart';

/// [p]'s knob travel (its descriptor's curve).
Taper taperOf(ComponentParameterInfo p) => Taper(p.min, p.max, exponential: p.exponential);

/// A rotary knob for parameter [paramId]: drag up or down (200 px covers the travel; a second finger or Shift for
/// fine), double-tap for the default, long-press to type a value, on the descriptor's taper. While it is dragged a
/// bubble above it shows the value, so the finger doesn't hide it. With a mod matrix it takes a dropped source (a new route) and shows
/// each route's span as a coloured ring outside the knob; a drag that starts on the ring sets that route's amount.
class DeviceKnob extends StatefulWidget {
  const DeviceKnob(this.paramId, {super.key, this.label, this.size = 40, this.color, this.valueText});
  final String paramId;
  final String? label;
  final double size;
  final Color? color;
  final String Function(double v)? valueText;

  @override
  State<DeviceKnob> createState() => _DeviceKnobState();
}

class _DeviceKnobState extends State<DeviceKnob> {
  double? _pos; // the travel during a drag
  int? _ringSlot; // the route a ring drag sets
  double _ringAmount = 0;
  int? _lastSlot; // the route dropped or dragged last: the one a ring drag picks

  final _bubble = OverlayPortalController();

  double get _box => widget.size + 14;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(widget.paramId);
    if (p == null) return const SizedBox.shrink();
    final color = widget.color ?? scope.accent;
    final taper = Taper(p.min, p.max, exponential: p.exponential);
    final value = t.value(p.id);
    final pos = taper.position(value);
    final matrix = scope.matrix;
    final routes = matrix?.routesTo(p.id) ?? const <ModRoute>[];
    final text = widget.valueText?.call(value) ?? formatParamValue(p, value);
    final label = widget.label ?? shortParamLabel(p, p.id);
    final canMod = matrix?.canModulate(p.id) ?? false;

    void set(double v) {
      final before = t.value(p.id);
      t.setLive(p.id, v);
      final now = t.value(p.id);
      final c = (p.min + p.max) / 2;
      if (before != now && before != c && (now == c || (before - c) * (now - c) < 0)) DeviceFeel.detent();
    }

    void start(Offset local) {
      DeviceFeel.grab();
      _bubble.show();
      final centre = Offset(math.max(52, _box + 2) / 2, _box / 2);
      final r = widget.size / 2;
      if (routes.isNotEmpty && (local - centre).distance > r * 0.8) {
        final r0 = routes.where((x) => x.slot == _lastSlot).firstOrNull ?? routes.last;
        _ringSlot = r0.slot;
        _ringAmount = r0.amount;
      } else {
        _ringSlot = null;
        _pos = pos;
      }
    }

    void update(double dy) {
      final fine = DeviceFingers.fine;
      if (_ringSlot != null) {
        _ringAmount = (_ringAmount - dy / 200 * fine).clamp(-1.0, 1.0);
        matrix!.setAmountLive(_ringSlot!, _ringAmount);
        _lastSlot = _ringSlot;
        return;
      }
      _pos = ((_pos ?? pos) - dy / 200 * fine).clamp(0.0, 1.0);
      set(taper.value(_pos!));
    }

    void end() {
      _pos = null;
      _ringSlot = null;
      _bubble.hide();
      t.commit();
    }

    Widget knob(bool highlight) => Semantics(
      label: label,
      value: text,
      slider: true,
      increasedValue: formatParamValue(p, _nudge(p, value, 1)),
      decreasedValue: formatParamValue(p, _nudge(p, value, -1)),
      onIncrease: () => t.set(p.id, _nudge(p, value, 1)),
      onDecrease: () => t.set(p.id, _nudge(p, value, -1)),
      child: Tooltip(
        message: '${p.label}: $text${routes.isEmpty ? '' : ' · ${routes.length} mod'}',
        waitDuration: const Duration(milliseconds: 600),
        child: ResetOnDoubleTap(
          onReset: () => t.set(p.id, p.defaultValue),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: p.isChoice ? null : () => _typeValue(context, p, value),
            onVerticalDragStart: (d) => start(d.localPosition),
            onVerticalDragUpdate: (d) => update(d.delta.dy),
            onVerticalDragEnd: (_) => end(),
            onVerticalDragCancel: end,
            child: OverlayPortal(
              controller: _bubble,
              overlayChildBuilder: (_) => _ValueBubble(anchor: context, text: text, color: color),
              child: SizedBox(
              width: math.max(52, _box + 2),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: _box, height: _box, child: CustomPaint(
                  painter: _DeviceKnobPainter(
                    pos: pos,
                    color: color,
                    bipolar: p.min < 0 && p.max > 0,
                    rings: [for (final r in routes) (r.span(pos), modSourceColor(r.source))],
                    highlight: highlight ? modSourceColor(scope.dragging.value ?? ModSource.none) : null,
                  ),
                )),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, color: Neon.dim, height: 1.1)),
                Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Neon.code(size: 9, color: color).copyWith(height: 1.2)),
              ]),
            )),
          ),
        ),
      ),
    );

    final key = ValueKey('dknob-${p.id}');
    if (!canMod) return KeyedSubtree(key: key, child: knob(false));
    return KeyedSubtree(key: key, child: DragTarget<ModSource>(
        onWillAcceptWithDetails: (d) => d.data != ModSource.none,
        onAcceptWithDetails: (d) {
          final slot = matrix!.add(d.data, p.id);
          if (slot != null) {
            Motion.tick();
            setState(() => _lastSlot = slot);
          } else {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
              duration: Duration(seconds: 2), content: Text('All 16 mod slots are in use')));
          }
        },
        builder: (context, hovering, _) => ValueListenableBuilder<ModSource?>(
          valueListenable: scope.dragging,
          builder: (context, dragging, _) => knob(dragging != null || hovering.isNotEmpty),
        ),
    ));
  }

  Future<void> _typeValue(BuildContext context, ComponentParameterInfo p, double value) async {
    final t = DeviceScope.of(context).target;
    DeviceFeel.tap();
    final field = TextEditingController(text: value.toStringAsFixed(p.max - p.min > 20 ? 1 : 3));
    final typed = await showDialog<double>(context: context, builder: (c) => AlertDialog(
      title: Text(p.label, style: const TextStyle(fontSize: 14)),
      content: TextField(
        key: const ValueKey('dknob-type'),
        controller: field,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(suffixText: p.unit, helperText: '${p.min} .. ${p.max}'),
        onSubmitted: (s) => Navigator.of(c).pop(double.tryParse(s.trim())),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(c).pop(double.tryParse(field.text.trim())), child: const Text('Set')),
      ],
    ));
    field.dispose();
    if (typed != null) t.set(p.id, typed);
  }
}

/// The value above a knob while it is dragged.
class _ValueBubble extends StatelessWidget {
  const _ValueBubble({required this.anchor, required this.text, required this.color});
  final BuildContext anchor;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return const SizedBox.shrink();
    final at = box.localToGlobal(Offset(box.size.width / 2, 0));
    return Positioned(left: at.dx - 50, top: math.max(0, at.dy - 34), width: 100, child: IgnorePointer(child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Neon.panelHi, borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color), boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10)]),
        child: Text(text, style: Neon.code(size: 12, color: Neon.text).copyWith(height: 1.1, fontWeight: FontWeight.w700)),
      ),
    )));
  }
}

double _nudge(ComponentParameterInfo p, double v, int dir) {
  final step = p.step > 0 ? p.step : (p.max - p.min) / 100;
  return (v + dir * step).clamp(p.min, p.max).toDouble();
}

class _DeviceKnobPainter extends CustomPainter {
  _DeviceKnobPainter({required this.pos, required this.color, required this.bipolar, required this.rings, this.highlight});
  final double pos;
  final Color color;
  final bool bipolar;
  final List<((double, double), Color)> rings;
  final Color? highlight;

  static const _start = math.pi * 0.75, _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 8;
    final rect = Rect.fromCircle(center: c, radius: r);
    if (highlight != null) {
      canvas.drawCircle(c, r + 5, Paint()..color = highlight!.withValues(alpha: 0.16));
      canvas.drawCircle(c, r + 5, Paint()
        ..color = highlight!.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, stroke..color = Neon.line);
    final from = bipolar ? 0.5 : 0.0;
    final a0 = _start + _sweep * math.min(from, pos), sweep = _sweep * (pos - from).abs();
    if (sweep > 0.001) {
      canvas.drawArc(rect, a0, sweep, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.18));
    }
    canvas.drawArc(rect, a0, sweep, false, stroke
      ..shader = SweepGradient(startAngle: 0, endAngle: math.pi * 2, transform: GradientRotation(_start),
          colors: [Color.lerp(color, Colors.white, 0.0)!.withValues(alpha: 0.65), color, Color.lerp(color, Colors.white, 0.35)!],
          stops: const [0, 0.5, 0.75]).createShader(rect));
    stroke.shader = null;
    for (var i = 0; i < rings.length && i < 3; i++) {
      final ((lo, hi), rc) = rings[i];
      final rr = Rect.fromCircle(center: c, radius: r + 4 + i * 3.0);
      canvas.drawArc(rr, _start + _sweep * lo, math.max(0.02, _sweep * (hi - lo)), false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = rc.withValues(alpha: 0.9));
    }
    canvas.drawCircle(c, r - 4.5, Paint()..color = Neon.panelHi);
    canvas.drawCircle(c, r - 4.5, Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke);
    final a = _start + _sweep * pos;
    final dir = Offset(math.cos(a), math.sin(a));
    canvas.drawLine(c + dir * (r * 0.3), c + dir * (r - 5), Paint()
      ..color = Neon.text
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _DeviceKnobPainter o) =>
      o.pos != pos || o.color != color || o.bipolar != bipolar || o.highlight != highlight || !_sameRings(o.rings, rings);

  static bool _sameRings(List<((double, double), Color)> a, List<((double, double), Color)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A choice parameter as compact segments (up to [maxSegments] choices, labels from [labels] or the
/// descriptor's), else a small dropdown.
class DeviceChoice extends StatelessWidget {
  const DeviceChoice(this.paramId, {super.key, this.labels, this.maxSegments = 5, this.color, this.label});
  final String paramId;
  final List<String>? labels;
  final int maxSegments;
  final Color? color;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final names = labels ?? p.choices;
    final i = (t.value(p.id) - p.min).round().clamp(0, names.length - 1);
    final c = color ?? scope.accent;
    void pick(int k) {
      Motion.tick();
      t.set(p.id, p.min + k);
    }

    final Widget body;
    if (names.length <= maxSegments) {
      body = Container(
        height: 26,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: Neon.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var k = 0; k < names.length; k++)
            Flexible(child: InkWell(
              key: ValueKey('dchoice-${p.id}-$k'),
              onTap: () => pick(k),
              child: AnimatedContainer(
                duration: Motion.fade(Motion.small, Motion.of(context)),
                padding: const EdgeInsets.symmetric(horizontal: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: k == i ? c.withValues(alpha: 0.22) : Colors.transparent,
                  borderRadius: BorderRadius.circular(5)),
                child: Text(names[k], maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(
                  fontSize: 10, fontWeight: k == i ? FontWeight.w800 : FontWeight.w500, color: k == i ? c : Neon.dim)),
              ),
            )),
        ]),
      );
    } else {
      body = SizedBox(height: 26, child: DropdownButtonHideUnderline(child: DropdownButton<int>(
        key: ValueKey('dchoice-${p.id}'),
        value: i,
        isDense: true,
        style: Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 11, color: c, fontWeight: FontWeight.w700),
        iconSize: 16,
        items: [for (var k = 0; k < names.length; k++) DropdownMenuItem(value: k, child: Text(names[k]))],
        onChanged: (k) { if (k != null) pick(k); },
      )));
    }
    if (label == null) return body;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label!, style: const TextStyle(fontSize: 9, color: Neon.dim)),
      const SizedBox(height: 2),
      body,
    ]);
  }
}

/// An Off/On parameter as a small power button.
class DevicePower extends StatelessWidget {
  const DevicePower(this.paramId, {super.key, this.color});
  final String paramId;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null) return const SizedBox.shrink();
    final on = t.value(p.id) >= 0.5;
    final c = color ?? scope.accent;
    return IconButton(
      key: ValueKey('dpower-${p.id}'),
      tooltip: on ? 'Turn ${p.label} off' : 'Turn ${p.label} on',
      iconSize: 16,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      color: on ? c : Neon.dim,
      onPressed: () {
        Motion.tick();
        t.set(p.id, on ? p.min : p.max);
      },
      icon: Icon(Icons.power_settings_new, shadows: on ? [Shadow(color: c, blurRadius: 6)] : null),
    );
  }
}

/// A full-width horizontal slider for [paramId] (phones' big target): drag sideways, double-tap for the default.
class DeviceSlider extends StatelessWidget {
  const DeviceSlider(this.paramId, {super.key, this.label, this.color});
  final String paramId;
  final String? label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(paramId);
    if (p == null) return const SizedBox.shrink();
    final taper = Taper(p.min, p.max, exponential: p.exponential);
    final v = t.value(p.id);
    final c = color ?? scope.accent;
    final bipolar = p.min < 0 && p.max > 0;
    return ResetOnDoubleTap(
      onReset: () => t.set(p.id, p.defaultValue),
      child: LayoutBuilder(builder: (context, box) {
        void at(double x) => t.setLive(p.id, taper.value(x / box.maxWidth));
        return GestureDetector(
          key: ValueKey('dslider-${p.id}'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => at(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
          onHorizontalDragEnd: (_) => t.commit(),
          child: SizedBox(height: 30, child: CustomPaint(
            painter: _SliderPainter(taper.position(v), c, bipolar),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
              Text(label ?? shortParamLabel(p, p.id), style: const TextStyle(fontSize: 10, color: Neon.text)),
              const Spacer(),
              Text(formatParamValue(p, v), style: Neon.code(size: 10, color: c)),
            ])),
          )),
        );
      }),
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter(this.pos, this.color, this.bipolar);
  final double pos;
  final Color color;
  final bool bipolar;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.drawRRect(r, Paint()..color = Colors.white.withValues(alpha: 0.04));
    canvas.drawRRect(r, Paint()
      ..color = Neon.line
      ..style = PaintingStyle.stroke);
    final from = bipolar ? 0.5 : 0.0;
    final x0 = size.width * math.min(from, pos), x1 = size.width * math.max(from, pos);
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Rect.fromLTRB(x0, 0, x1, size.height), Paint()..color = color.withValues(alpha: 0.22));
    canvas.restore();
    canvas.drawLine(Offset(size.width * pos, 3), Offset(size.width * pos, size.height - 3), Paint()
      ..color = color
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _SliderPainter o) => o.pos != pos || o.color != color || o.bipolar != bipolar;
}
