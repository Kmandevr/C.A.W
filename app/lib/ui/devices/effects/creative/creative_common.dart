// What the Creative and Pitch & Time plugin UIs share: the hold-to-trigger pad, a labelled choice row, and dragging a knob's taper from a hero.
import 'package:flutter/material.dart';

import '../../../feedback.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/feel.dart';

/// A big pad that holds parameter [paramId] at 1 while a finger is on it and puts it back to 0 on release (the tape
/// stop's Stop, the stutter's Hold): a grab haptic on press, a drop on release, and it glows while held (or while
/// the knob is up by other means).
class HoldPad extends StatefulWidget {
  const HoldPad(this.paramId, {super.key, required this.label, required this.icon, this.held, this.height = 56});
  final String paramId, label;
  final IconData icon;

  /// What the pad says while held.
  final String? held;
  final double height;

  @override
  State<HoldPad> createState() => _HoldPadState();
}

class _HoldPadState extends State<HoldPad> {
  bool _down = false;

  void _set(bool down) {
    final t = DeviceScope.of(context).target;
    if (down == _down) return;
    setState(() => _down = down);
    down ? DeviceFeel.grab() : DeviceFeel.release();
    t.set(widget.paramId, down ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final on = _down || scope.target.value(widget.paramId) >= 0.5;
    final c = scope.accent;
    return Semantics(
      button: true,
      label: widget.label,
      child: Listener(
        key: ValueKey('hold-${widget.paramId}'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: Pressable(glow: c, child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: on ? c.withValues(alpha: 0.32) : Colors.white.withValues(alpha: 0.04),
            border: Border.all(color: on ? c : Neon.line, width: on ? 2 : 1),
            boxShadow: on ? Neon.glow(c) : null),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(widget.icon, size: 20, color: on ? Neon.text : c),
            const SizedBox(width: 8),
            Text(on ? (widget.held ?? widget.label) : widget.label, style: TextStyle(fontSize: 12, letterSpacing: 1.2,
              fontWeight: FontWeight.w800, color: on ? Neon.text : Neon.dim)),
          ]),
        )),
      ),
    );
  }
}

/// A short capitalised label and a choice's segments, in one row.
class LabelledChoice extends StatelessWidget {
  const LabelledChoice(this.label, this.paramId, {super.key, this.maxSegments = 0});
  final String label, paramId;
  final int maxSegments;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
    SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 9, letterSpacing: 1.2,
      fontWeight: FontWeight.w800, color: Neon.dim))),
    Expanded(child: Align(alignment: Alignment.centerLeft, child: DeviceChoice(paramId, maxSegments: maxSegments))),
  ]));
}

/// Moves parameter [id] of the device by a drag of [delta] (in hero widths or heights: one travel per [span]) along
/// its own taper, from [from]; returns the new value (set live). Null when the device has no such parameter.
double? dragAlongTaper(DeviceScope scope, String id, double from, double delta, {double span = 1}) {
  final p = scope.target.param(id);
  if (p == null) return null;
  final taper = taperOf(p);
  final v = taper.value((taper.position(from) + delta / span * DeviceFingers.fine).clamp(0.0, 1.0));
  scope.target.setLive(id, v);
  return v;
}

/// The value of [id], or [fallback] when the device has no such parameter (a fixture, an older engine).
double valueOr(DeviceScope scope, String id, double fallback) => scope.target.param(id) == null ? fallback : scope.target.value(id);

/// Seconds of a note division label ("1/16 T", "1/8 D", "1 bar", "2 bars") at [bpm]; null for "Free" or an unknown one.
double? divisionSeconds(String label, double bpm) {
  final l = label.trim();
  double? whole;
  if (l.endsWith('bars') || l.endsWith('bar')) {
    whole = double.tryParse(l.split(' ').first);
  } else if (l.startsWith('1/')) {
    final parts = l.substring(2).split(' ');
    final d = double.tryParse(parts.first);
    if (d != null && d > 0) {
      whole = 1 / d;
      if (parts.length > 1 && parts[1] == 'T') whole *= 2 / 3;
      if (parts.length > 1 && parts[1] == 'D') whole *= 1.5;
    }
  }
  return whole == null ? null : whole * 240 / (bpm <= 1 ? 120 : bpm);
}
