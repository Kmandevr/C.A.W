// The device page for a component with no editor of its own: its declared UI controls (XY pads, buttons, curves...) in the device kit, else every parameter as knobs.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/arrange_fx.dart' show isBuiltinComponent;
import '../../model/device_target.dart';
import '../arrange/knob.dart';
import '../feedback.dart';
import '../theme.dart';
import 'device_controls.dart';
import 'device_scope.dart';
import 'kit/controls.dart';
import 'kit/feel.dart';
import 'kit/grab_gesture.dart';
import 'kit/hero.dart';

/// The same knobs the FX card shows (owner: "strictly a fallback if there's no UI built in"), on a full page. A
/// component that declares `uiControls` (its descriptor's UI hints, #10) gets them instead: [GeneratedControls].
class GenericDevicePage extends StatelessWidget {
  const GenericDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final info = t.info;
    final use = t.use;
    if (info == null || use == null) return const SizedBox.shrink();
    if (info.uiControls.isNotEmpty) return const GeneratedControls();
    if (info.parameters.isEmpty) {
      return const Center(child: Text('No knobs', style: TextStyle(color: Neon.dim)));
    }
    final color = isBuiltinComponent(use.id) ? Neon.blue : Neon.green;
    return SingleChildScrollView(
      key: const ValueKey('device-fallback'),
      padding: const EdgeInsets.all(12),
      child: Wrap(spacing: 2, runSpacing: 4, children: [
        for (final p in info.parameters)
          if (p.isChoice)
            SizedBox(width: 96, height: 62, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              DropdownButton<int>(
                value: (t.value(p.id) - p.min).round().clamp(0, p.choices.length - 1),
                isDense: true,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                style: const TextStyle(fontSize: 11, color: Neon.text),
                items: [for (var k = 0; k < p.choices.length; k++) DropdownMenuItem(value: k, child: Text(p.choices[k],
                  maxLines: 1, overflow: TextOverflow.ellipsis))],
                onChanged: (k) { if (k != null) t.set(p.id, p.min + k); },
              ),
              Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Neon.dim)),
            ]))
          else
            Knob(key: ValueKey('knob-${use.id}-${p.id}'), value: t.value(p.id),
              min: p.min, max: p.max, step: p.step, defaultValue: p.defaultValue, label: p.label,
              exponential: p.exponential,
              enabled: !use.bypass,
              color: color,
              valueText: (v) => '${v.toStringAsFixed(p.max - p.min > 20 ? 0 : 2)}${p.unit.isEmpty ? '' : ' ${p.unit}'}',
              onChanged: (v) => t.setLive(p.id, v),
              onChangeEnd: t.commit),
      ]),
    );
  }
}

/// One piece of a generated page: a run of controls laid out together.
sealed class UiControlGroup {
  const UiControlGroup();
}

/// Two `xy_pad` controls in a row: the first drives X, the second Y. A lone one is [y] null (a pad that moves across).
class UiXYGroup extends UiControlGroup {
  const UiXYGroup(this.x, this.y);
  final ComponentUiControlInfo x;
  final ComponentUiControlInfo? y;
}

/// Toggles and buttons next to each other, in one wrapping row of pills.
class UiPillGroup extends UiControlGroup {
  const UiPillGroup(this.controls);
  final List<ComponentUiControlInfo> controls;
}

/// One control on its own line (a slider, a dropdown, a curve).
class UiSingleGroup extends UiControlGroup {
  const UiSingleGroup(this.control);
  final ComponentUiControlInfo control;
}

/// The descriptor's UI controls in order, grouped for layout: consecutive XY pads pair up (X, then Y), toggles and
/// buttons share rows, everything else gets a line. A control naming an unknown parameter is left out.
List<UiControlGroup> groupUiControls(NativeComponentInfo info) {
  bool known(ComponentUiControlInfo c) => c.parameterId.isEmpty || info.parameters.any((p) => p.id == c.parameterId);
  final controls = [
    for (final c in info.uiControls)
      if (known(c) && (c.parameterId.isNotEmpty || c.kind == 'button')) c,
  ];
  final groups = <UiControlGroup>[];
  for (var i = 0; i < controls.length; i++) {
    final c = controls[i];
    switch (c.kind) {
      case 'xy_pad':
        final next = i + 1 < controls.length && controls[i + 1].kind == 'xy_pad' ? controls[i + 1] : null;
        groups.add(UiXYGroup(c, next));
        if (next != null) i++;
      case 'toggle' || 'button':
        if (groups.lastOrNull case UiPillGroup(:final controls)) {
          controls.add(c);
        } else {
          groups.add(UiPillGroup([c]));
        }
      default:
        groups.add(UiSingleGroup(c));
    }
  }
  return groups;
}

/// A device target whose parameters span only their UI control's range (a control's `min`/`max` may narrow its
/// parameter's), so the kit's widgets, which read ranges from the target, move within it.
class UiRangeTarget extends DeviceTarget {
  UiRangeTarget(DeviceTarget base, this.ranges) : super(base.state, base.layerId, base.slot);

  /// Parameter id to the (min, max) its first control declares.
  final Map<String, (double, double)> ranges;

  @override
  ComponentParameterInfo? param(String id) {
    final p = super.param(id);
    final r = ranges[id];
    if (p == null || r == null || p.isChoice || (r.$1 <= p.min && r.$2 >= p.max)) return p;
    final lo = math.max(p.min, r.$1), hi = math.min(p.max, r.$2);
    if (!(hi > lo)) return p;
    return ComponentParameterInfo(id: p.id, name: p.name, unit: p.unit, defaultValue: p.defaultValue.clamp(lo, hi),
      min: lo, max: hi, step: p.step, exponential: p.exponential && lo > 0, smoothingFrames: p.smoothingFrames,
      automatable: p.automatable, modulatable: p.modulatable, midiMappable: p.midiMappable);
  }
}

/// A component's declared UI controls as device-kit widgets (#10, roadmap UI.4): XY pads on the hero canvas, sliders,
/// toggles and momentary buttons as glowing pills, dropdowns as segments, curves drawn and bent by a drag. The
/// parameters no control covers follow under MORE as knobs. Inline in the FX stack it lays out without scrolling.
class GeneratedControls extends StatelessWidget {
  const GeneratedControls({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final info = scope.target.info;
    if (info == null) return const SizedBox.shrink();
    final ranges = <String, (double, double)>{};
    for (final c in info.uiControls) {
      if (c.parameterId.isNotEmpty) ranges.putIfAbsent(c.parameterId, () => (c.min, c.max));
    }
    final target = UiRangeTarget(scope.target, ranges);
    final covered = {for (final c in info.uiControls) if (c.parameterId.isNotEmpty) c.parameterId};
    final rest = [for (final p in info.parameters) if (!covered.contains(p.id)) p.id];
    final inline = scope.inline;
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final g in groupUiControls(info))
        Padding(padding: const EdgeInsets.only(bottom: 8), child: _group(g, info, inline)),
      if (rest.isNotEmpty)
        inline ? KnobRow(rest, size: 38) : DeviceFold(child: ParamGrid(only: rest)),
    ]);
    final scoped = DeviceScope(target: target, matrix: scope.matrix, dragging: scope.dragging, accent: scope.accent,
      secondary: scope.secondary, focusSource: scope.focusSource, openSource: scope.openSource, inline: inline,
      assigning: scope.assigning, selectedSlot: scope.selectedSlot, child: body);
    if (inline) return Padding(key: const ValueKey('device-generated'), padding: const EdgeInsets.all(8), child: scoped);
    return SingleChildScrollView(key: const ValueKey('device-generated'), padding: const EdgeInsets.all(12), child: scoped);
  }

  Widget _group(UiControlGroup g, NativeComponentInfo info, bool inline) => switch (g) {
        UiXYGroup(:final x, :final y) => y == null
            ? DeviceSlider(x.parameterId, label: _label(x, info))
            : XYPad(key: ValueKey('ui-xy-${x.id}'), xParam: x.parameterId, yParam: y.parameterId,
                height: inline ? 120 : 180, caption: x.label.isNotEmpty ? x.label : null),
        UiPillGroup(:final controls) => Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in controls)
              c.kind == 'toggle'
                  ? DeviceToggle(c.parameterId, key: ValueKey('ui-toggle-${c.id}'), label: _label(c, info))
                  : UiButton(c, key: ValueKey('ui-button-${c.id}')),
          ]),
        UiSingleGroup(:final control) => switch (control.kind) {
            'dropdown' when info.parameters.any((p) => p.id == control.parameterId && p.isChoice) =>
              Row(children: [
                SizedBox(width: 92, child: Text(_label(control, info), maxLines: 2,
                    style: const TextStyle(fontSize: 10, color: Neon.dim))),
                Expanded(child: Align(alignment: Alignment.centerLeft,
                    child: DeviceChoice(control.parameterId, key: ValueKey('ui-choice-${control.id}'), maxSegments: 5))),
              ]),
            'curve' => UiCurve(control, height: inline ? 84 : 120, key: ValueKey('ui-curve-${control.id}')),
            _ => DeviceSlider(control.parameterId, key: ValueKey('ui-slider-${control.id}'), label: _label(control, info)),
          },
      };

  static String _label(ComponentUiControlInfo c, NativeComponentInfo info) {
    if (c.label.isNotEmpty) return c.label;
    return info.parameters.where((p) => p.id == c.parameterId).firstOrNull?.label ?? c.id;
  }
}

/// A momentary button (`button` control): its parameter sits at the top of its range while held and returns to the
/// bottom on release (a stutter, a freeze while held), one undo step per press. A button with no parameter has
/// nothing to send yet (the component interface has no actions), so it shows dimmed.
class UiButton extends StatefulWidget {
  const UiButton(this.control, {super.key});
  final ComponentUiControlInfo control;

  @override
  State<UiButton> createState() => _UiButtonState();
}

class _UiButtonState extends State<UiButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final c = widget.control;
    final p = c.parameterId.isEmpty ? null : t.param(c.parameterId);
    final label = (c.label.isNotEmpty ? c.label : (p?.label ?? c.id)).toUpperCase();
    final color = scope.accent;
    final held = p != null && (_down || t.value(p.id) >= (p.min + p.max) / 2);
    final pill = AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: held ? color.withValues(alpha: 0.32) : Neon.ink.withValues(alpha: 0.03),
        border: Border.all(color: p == null ? Neon.line.withValues(alpha: 0.5) : (held ? color : Neon.line)),
        boxShadow: held ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 12)] : null),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.touch_app_outlined, size: 15, color: p == null ? Neon.dim.withValues(alpha: 0.5) : (held ? color : Neon.dim)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w800,
          color: p == null ? Neon.dim.withValues(alpha: 0.5) : (held ? Neon.text : Neon.dim))),
      ]),
    );
    if (p == null) {
      return Tooltip(message: 'This button has no parameter, so the app has nothing to send yet', child: pill);
    }
    void release() {
      if (!_down) return;
      setState(() => _down = false);
      DeviceFeel.release();
      t.setLive(p.id, p.min);
      t.commit();
    }

    return Semantics(
      button: true,
      label: '${p.label}, hold',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          setState(() => _down = true);
          DeviceFeel.grab();
          t.setLive(p.id, p.max);
        },
        onTapUp: (_) => release(),
        onTapCancel: release,
        child: Pressable(glow: color, radius: 18, child: pill),
      ),
    );
  }
}

/// A `curve` control: its parameter drawn as the bend of a response curve (the bottom of the range bends down, the
/// middle is a straight line, the top bends up); drag up or down to bend it (a second finger or Shift for fine),
/// double-tap for the default.
class UiCurve extends StatefulWidget {
  const UiCurve(this.control, {super.key, this.height = 120});
  final ComponentUiControlInfo control;
  final double height;

  /// The curve at [x] (0..1) for a bend of [bend] (−1..1): x raised to a power from 1/8 to 8.
  static double shape(double x, double bend) => math.pow(x.clamp(0.0, 1.0), math.pow(8, -bend).toDouble()).toDouble();

  @override
  State<UiCurve> createState() => _UiCurveState();
}

class _UiCurveState extends State<UiCurve> {
  bool _active = false;
  double _pos = 0;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(widget.control.parameterId);
    if (p == null) return const SizedBox.shrink();
    final taper = taperOf(p);
    final pos = taper.position(t.value(p.id));
    final c = scope.accent;
    final label = widget.control.label.isNotEmpty ? widget.control.label : p.label;
    return HeroCanvas(color: c, height: widget.height, caption: label,
      readout: Text(formatParamValue(p, t.value(p.id))),
      child: LayoutBuilder(builder: (context, box) => GrabGesture(
        key: ValueKey('curve-${p.id}'),
        onStart: (_, _) {
          _pos = taper.position(t.value(p.id));
          setState(() => _active = true);
        },
        onUpdate: (u) {
          _pos = (_pos - u.delta.dy / box.maxHeight * DeviceFingers.fine).clamp(0.0, 1.0);
          t.setLive(p.id, taper.value(_pos));
        },
        onEnd: () {
          t.commit();
          setState(() => _active = false);
        },
        onDoubleTap: (_) => t.set(p.id, p.defaultValue),
        child: CustomPaint(painter: _CurvePainter(pos * 2 - 1, c, _active), child: const SizedBox.expand()),
      )),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.bend, this.color, this.active);
  final double bend;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(10);
    final path = Path();
    for (var i = 0; i <= 64; i++) {
      final x = i / 64;
      final pt = Offset(r.left + x * r.width, r.bottom - UiCurve.shape(x, bend) * r.height);
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    final fill = Path.from(path)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.10));
    canvas.drawPath(path, Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    paintHandle(canvas, Offset(r.center.dx, r.bottom - UiCurve.shape(0.5, bend) * r.height), color, active: active, r: 8);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter o) => o.bend != bend || o.color != color || o.active != active;
}
