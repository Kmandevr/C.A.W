// A device control's keyboard focus: the knob, slider, toggle or choice the device editor's keys change.
import 'package:flutter/material.dart';

import '../../../actions/actions.dart';
import '../../keyboard/key_area.dart';
import '../../arrange/knob.dart' show Taper;
import '../device_scope.dart';

/// How a focused control takes the keys: a [range] steps along its travel, a [toggle] goes to on or off, a
/// [choice] steps through its values.
enum KeyParamKind { range, toggle, choice }

/// Makes [child] (a device control for [paramId]) take the keyboard focus. In the device editor's area (an
/// [Area.device] [KeyArea]) Up, W, + raise it, Down, S, - lower it (Shift: finer), Home puts the default back and
/// Enter types a value ([onType]; a toggle or choice steps instead). Each press is one undo step.
class KeyParam extends StatefulWidget {
  const KeyParam({super.key, required this.paramId, required this.child, this.kind = KeyParamKind.range, this.onType});
  final String paramId;
  final Widget child;
  final KeyParamKind kind;

  /// Asks for a typed value (the knob's own dialog); null: Enter steps a toggle or choice and does nothing else.
  final VoidCallback? onType;

  static final Map<FocusNode, KeyParamState> _byNode = {};

  /// The control with the keyboard focus, if it is one.
  static KeyParamState? get focused {
    final p = FocusManager.instance.primaryFocus;
    return p == null ? null : _byNode[p];
  }

  @override
  State<KeyParam> createState() => KeyParamState();
}

class KeyParamState extends State<KeyParam> {
  late final FocusNode node = FocusNode(debugLabel: 'param ${widget.paramId}');

  @override
  void initState() {
    super.initState();
    KeyParam._byNode[node] = this;
    node.addListener(_changed);
  }

  @override
  void dispose() {
    KeyParam._byNode.remove(node);
    node.removeListener(_changed);
    node.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  /// One press up ([dir] 1) or down (-1): a step of the travel (a fiftieth, a five-hundredth [fine]), or the next
  /// value of a stepped or choice parameter, or on or off.
  void step(int dir, {bool fine = false}) {
    final t = DeviceScope.of(context).target;
    final p = t.param(widget.paramId);
    if (p == null) return;
    final now = t.value(p.id);
    final double v;
    if (widget.kind == KeyParamKind.toggle) {
      v = dir > 0 ? p.max : p.min;
    } else if (widget.kind == KeyParamKind.choice || p.isChoice || p.step > 0) {
      final s = p.isChoice || widget.kind == KeyParamKind.choice ? 1.0 : p.step;
      v = (now + dir * s).clamp(p.min, p.max).toDouble();
    } else {
      final taper = Taper(p.min, p.max, exponential: p.exponential);
      v = taper.value((taper.position(now) + dir * (fine ? 0.002 : 0.02)).clamp(0.0, 1.0));
    }
    if (v != now) t.set(p.id, v);
  }

  /// Home: the parameter's default.
  void reset() {
    final t = DeviceScope.of(context).target;
    final p = t.param(widget.paramId);
    if (p != null) t.set(p.id, p.defaultValue);
  }

  /// Enter: type a value, or (a toggle, a choice) step it.
  void type() {
    if (widget.onType != null) return widget.onType!();
    final t = DeviceScope.of(context).target;
    final p = t.param(widget.paramId);
    if (p == null) return;
    if (widget.kind == KeyParamKind.toggle) {
      t.set(p.id, t.value(p.id) >= (p.min + p.max) / 2 ? p.min : p.max);
    } else {
      final next = t.value(p.id) + 1;
      t.set(p.id, next > p.max ? p.min : next);
    }
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: node, child: widget.child);
}

/// The device editor's keys (an [Area.device] area): the focused control's value; a press with no control focused
/// lands on the first one. Moves (Left/Right, A/D) are the area's own reading-order moves.
bool deviceKey(KeyAreaState? area, String id, int count) {
  final k = KeyParam.focused;
  if (k == null) {
    if (area == null) return false;
    // On a button (a preset, a tab), up and down move instead.
    if (id == 'device.inc' || id == 'device.incFine') return moveFocusIn(area.node, KeyMove.up) || area.enter();
    if (id == 'device.dec' || id == 'device.decFine') return moveFocusIn(area.node, KeyMove.down) || area.enter();
    if (id == 'device.type') return activateFocused() || area.enter();
    return area.enter();
  }
  for (var i = 0; i < count; i++) {
    switch (id) {
      case 'device.inc':
        k.step(1);
      case 'device.dec':
        k.step(-1);
      case 'device.incFine':
        k.step(1, fine: true);
      case 'device.decFine':
        k.step(-1, fine: true);
      case 'device.reset':
        k.reset();
        return true;
      case 'device.type':
        k.type();
        return true;
      default:
        return false;
    }
  }
  return true;
}

/// The device editor's key area around [child].
class DeviceKeyArea extends StatefulWidget {
  const DeviceKeyArea({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  State<DeviceKeyArea> createState() => _DeviceKeyAreaState();
}

class _DeviceKeyAreaState extends State<DeviceKeyArea> {
  final _area = GlobalKey<KeyAreaState>();

  @override
  Widget build(BuildContext context) => KeyArea(
        key: _area,
        area: Area.device,
        label: widget.label,
        // Opened from the keyboard (Enter on an effect), the editor takes the focus, so its keys work at once.
        autofocus: true,
        onAction: (id, count, _) => deviceKey(_area.currentState, id, count),
        child: widget.child,
      );
}
