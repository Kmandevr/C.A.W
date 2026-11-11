// A device editor's controls bound to the device's parameters: knobs with Vital-style mod rings, drop and assign targets, choices, power, sliders.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/mod_matrix.dart';
import '../../model/modulation.dart';
import '../arrange/knob.dart' show Taper;
import '../feedback.dart';
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart' show ResetOnDoubleTap;
import 'device_scope.dart';
import 'midi_learn.dart';
import 'modulators/modulator_devices.dart' show modulatorColor, showModLinkSheet;
import 'kit/feel.dart';
import 'kit/hero.dart' show MotionClock, motionRuns;
import 'visuals/mod_sheet.dart';

/// [p]'s knob travel (its descriptor's curve).
Taper taperOf(ComponentParameterInfo p) => Taper(p.min, p.max, exponential: p.exponential);

/// A rotary knob for parameter [paramId]: drag up or down (200 px covers the travel; a second finger elsewhere or
/// Shift for fine), double-tap for the default, on the descriptor's taper. While it is dragged a bubble above it
/// shows the value, so the finger doesn't hide it.
///
/// With a mod matrix (Vital-style, owner 2026-11-10) it shows each route as a ring in its source's colour over the
/// span it covers (the selected route brighter), a count badge, and a dot riding the modulated value (≈, drawn in
/// Dart). It takes a dropped source chip (a new route) and, in assign mode, a tap adds or removes the route. The
/// amount always has its own target: a drag that starts on the knob's outer edge or its rings sets the selected
/// route's amount, two fingers on the knob do the same, and a long-press opens its Modulation sheet with a big
/// slider per route. Without a matrix a long-press types a value. Both offer "Learn MIDI CC" (midi_learn.dart).
class DeviceKnob extends StatefulWidget {
  const DeviceKnob(this.paramId, {super.key, this.label, this.size = 40, this.color, this.valueText});
  final String paramId;
  final String? label;
  final double size;
  final Color? color;
  final String Function(double v)? valueText;

  /// The width a knob of [size] takes (room for four rings).
  static double widthFor(double size) => math.max(54, size + 20);

  @override
  State<DeviceKnob> createState() => _DeviceKnobState();
}

class _DeviceKnobState extends State<DeviceKnob> {
  double? _pos; // the travel during a drag
  int? _ringSlot; // the route a ring drag sets
  int? _ringLink; // ... or the project link (#161)
  int? _lastLink; // the project link dropped or tapped last here
  bool _linkHover = false; // a modulator output hovers over the knob
  double _ringAmount = 0;
  int? _lastSlot; // the route dropped or dragged last here
  bool _held = false, _hover = false;
  final Set<int> _fingers = {}; // pointers down on this knob
  Offset _pressAt = Offset.zero, _pressLast = Offset.zero; // a long-press, and where its finger is now
  bool _pressDragged = false;
  final _motion = MotionClock();

  final _bubble = OverlayPortalController();

  double get _box => widget.size + 18;
  double get _width => DeviceKnob.widthFor(widget.size);
  // The track's radius in the painter (the face sits just inside it).
  double get _track => _box / 2 - 9;

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  ModRoute? _selected(List<ModRoute> routes, DeviceScope scope) {
    if (routes.isEmpty) return null;
    final sel = scope.selectedSlot?.value;
    return routes.where((x) => x.slot == sel).firstOrNull ??
        routes.where((x) => x.slot == _lastSlot).firstOrNull ?? routes.last;
  }

  @override
  Widget build(BuildContext context) {
    final app = DeviceScope.of(context).target.state;
    // Project modulation (#161): its links, the output being dragged and assign mode redraw the knob.
    return ListenableBuilder(
      listenable: Listenable.merge([app.modulationTick, app.draggingModulation, app.assigningModulation]),
      builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(widget.paramId);
    if (p == null) return const SizedBox.shrink();
    final app = t.state;
    // Links from the project's modulators (any knob in the project can take them; a choice can't).
    final modTarget = p.modulatable && !p.isChoice ? ModTarget.ofDevice(t, p.id) : null;
    final links = modTarget == null ? const <ModLinkDoc>[] : app.project.linksTo(modTarget);
    final projDrag = modTarget == null ? null : app.draggingModulation.value;
    final projAssign = modTarget == null ? null : app.assigningModulation.value;
    final color = widget.color ?? scope.accent;
    final taper = Taper(p.min, p.max, exponential: p.exponential);
    final value = t.value(p.id);
    final pos = taper.position(value);
    final matrix = scope.matrix;
    final canMod = matrix?.canModulate(p.id) ?? false;
    final routes = canMod ? matrix!.routesTo(p.id) : const <ModRoute>[];
    final text = widget.valueText?.call(value) ?? formatParamValue(p, value);
    final label = widget.label ?? shortParamLabel(p, p.id);
    _motion.run((routes.isNotEmpty || links.isNotEmpty) && motionRuns(context));
    ModLinkDoc? selLink() => links.where((l) => l.id == _lastLink).firstOrNull ?? links.lastOrNull;

    void set(double v) {
      final before = t.value(p.id);
      t.setLive(p.id, v);
      final now = t.value(p.id);
      final c = (p.min + p.max) / 2;
      if (before != now && before != c && (now == c || (before - c) * (now - c) < 0)) DeviceFeel.detent();
    }

    void ringMode(ModRoute r) {
      _ringSlot = r.slot;
      _ringAmount = r.amount;
      _lastSlot = r.slot;
      scope.selectedSlot?.value = r.slot;
    }

    void start(Offset local) {
      DeviceFeel.grab();
      _bubble.show();
      final centre = Offset(_width / 2, _box / 2);
      final d = (local - centre).distance;
      final sel = _selected(routes, scope);
      final link = sel == null ? selLink() : null;
      // The amount's own target: the knob's outer edge and its rings (not the labels under it), or two fingers.
      final edge = _fingers.length >= 2 || (local.dy <= _box && d >= _track * 0.7);
      _ringLink = null;
      if (sel != null && edge) {
        ringMode(sel);
      } else if (link != null && edge) {
        _ringSlot = null;
        _ringLink = link.id;
        _ringAmount = link.amount;
        _lastLink = link.id;
      } else {
        _ringSlot = null;
        _pos = pos;
      }
      setState(() => _held = true);
    }

    void update(double dy) {
      if (_ringLink != null) {
        final before = _ringAmount;
        _ringAmount = (_ringAmount - dy / 200 * (_fingers.length >= 2 ? 1.0 : DeviceFingers.fine)).clamp(-1.0, 1.0);
        if (before != 0 && (before > 0) != (_ringAmount > 0)) DeviceFeel.detent();
        app.setModLinkAmountLive(_ringLink!, _ringAmount);
        return;
      }
      if (_ringSlot != null) {
        final fine = _fingers.length >= 2 ? 1.0 : DeviceFingers.fine;
        final before = _ringAmount;
        _ringAmount = (_ringAmount - dy / 200 * fine).clamp(-1.0, 1.0);
        if (before != 0 && (before > 0) != (_ringAmount > 0)) DeviceFeel.detent();
        matrix!.setAmountLive(_ringSlot!, _ringAmount);
        return;
      }
      _pos = ((_pos ?? pos) - dy / 200 * DeviceFingers.fine).clamp(0.0, 1.0);
      set(taper.value(_pos!));
    }

    void end() {
      if (!_held) return; // a drag that never started (a tap, a long-press won)
      _pos = null;
      _ringSlot = null;
      final link = _ringLink;
      _ringLink = null;
      if (_bubble.isShowing) _bubble.hide();
      setState(() => _held = false);
      if (link != null) {
        app.commitModulation();
      } else {
        t.commit();
      }
    }

    void longPress() {
      if (modTarget != null && links.isNotEmpty && routes.isEmpty) {
        showModLinkSheet(context, app, modTarget, onTypeValue: p.isChoice ? null : () => _typeValue(context, p, t.value(p.id)));
      } else if (canMod) {
        showModulationSheet(context, p.id, onTypeValue: () => _typeValue(context, p, t.value(p.id)));
      } else if (!p.isChoice) {
        _typeValue(context, p, value);
      }
    }

    Widget knob({ModSource? offering, bool hovering = false, ModSource? assigning}) {
      final sel = _selected(routes, scope);
      final assignedHere = assigning != null && routes.any((r) => r.source == assigning);
      final ring = _ringSlot == null ? null : routes.where((r) => r.slot == _ringSlot).firstOrNull;
      final ringLink = _ringLink == null ? null : links.where((l) => l.id == _ringLink).firstOrNull;
      final bubbleText = ringLink != null
          ? '${app.modSourceLabel(ringLink.ref)} ${ringLink.amount > 0 ? '+' : ''}${(ringLink.amount * 100).round()}%'
          : ring == null ? text : '${ring.source.short} ${ring.amount > 0 ? '+' : ''}${(ring.amount * 100).round()}%';
      final bubbleColor = ringLink != null ? modulatorColor(app, ringLink.source)
          : ring == null ? color : modSourceColor(ring.source);
      final highlight = offering ?? assigning;
      final projOffer = projDrag ?? projAssign;
      final projAssigned = projAssign != null && links.any((l) => l.ref == projAssign);
      final selected = selLink();
      final face = SizedBox(width: _box, height: _box, child: ValueListenableBuilder<double>(
        valueListenable: _motion.seconds,
        builder: (context, seconds, _) => CustomPaint(
          painter: DeviceKnobPainter(
            pos: pos,
            color: color,
            bipolar: p.min < 0 && p.max > 0,
            rings: [
              for (final r in routes) (r.span(pos), modSourceColor(r.source), r.slot == sel?.slot),
              for (final l in links) (l.span(pos), modulatorColor(app, l.source), sel == null && l.id == selected?.id),
            ],
            modulated: !_motion.running || (routes.isEmpty && links.isEmpty) ? null : () {
              final inside = routes.isEmpty ? null : matrix!.modulatedPosition(p.id, pos, seconds);
              final live = links.isEmpty ? null : app.liveModOffset(links.first);  // what the engine applied
              if (inside == null && live == null) return null;
              return ((inside ?? pos) + (live ?? 0)).clamp(0.0, 1.0);
            }(),
            highlight: highlight != null ? modSourceColor(highlight)
                : projOffer == null ? null : modulatorColor(app, projOffer.modulatorId),
            strong: hovering || assignedHere || _linkHover || projAssigned,
            preview: hovering && offering != null ? (ModRoute(slot: 0, source: offering, paramId: p.id, amount: 0.25,
              bipolar: offering.naturallyBipolar).span(pos), modSourceColor(offering)) : null,
          ),
        ),
      ));
      return Semantics(
        label: label,
        value: text,
        slider: true,
        hint: canMod || links.isNotEmpty ? 'Long-press for modulation' : null,
        increasedValue: formatParamValue(p, _nudge(p, value, 1)),
        decreasedValue: formatParamValue(p, _nudge(p, value, -1)),
        onIncrease: () => t.set(p.id, _nudge(p, value, 1)),
        onDecrease: () => t.set(p.id, _nudge(p, value, -1)),
        child: Tooltip(
          message: '${p.label}: $text${routes.isEmpty && links.isEmpty ? '' : ' · ${routes.length + links.length} modulation${routes.length + links.length == 1 ? '' : 's'}'}',
          waitDuration: const Duration(milliseconds: 600),
          child: ResetOnDoubleTap(
            onReset: assigning != null || projAssign != null ? null : () => t.set(p.id, p.defaultValue),
            child: Listener(
              onPointerDown: (e) {
                _fingers.add(e.pointer);
                // A second finger on the knob during a drag: the selected route's amount from here on.
                if (_fingers.length == 2 && _held && _ringSlot == null) {
                  final s = _selected(routes, scope);
                  if (s != null) {
                    DeviceFeel.detent();
                    setState(() => ringMode(s));
                  }
                }
              },
              onPointerUp: (e) => _fingers.remove(e.pointer),
              onPointerCancel: (e) => _fingers.remove(e.pointer),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: projAssign != null && modTarget != null ? () {
                  final made = app.toggleModLink(projAssign, modTarget);
                  if (made == null && app.project.linksTo(modTarget).every((l) => l.ref != projAssign)) {
                    final why = app.whyNoLink(projAssign, modTarget);
                    if (why != null) {
                      DeviceFeel.tap();
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(duration: const Duration(seconds: 2),
                        content: Text(why)));
                      return;
                    }
                  }
                  DeviceFeel.detent();
                  if (made != null) _lastLink = made.id;
                } : assigning == null || !canMod ? null : () {
                  final slot = matrix!.toggle(assigning, p.id);
                  if (slot == null) {
                    DeviceFeel.tap();
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(duration: const Duration(seconds: 2),
                      content: Text('All ${matrix.slotCount} modulation slots are in use')));
                    return;
                  }
                  DeviceFeel.detent();
                  if (slot > 0) {
                    _lastSlot = slot;
                    scope.selectedSlot?.value = slot;
                  }
                },
                // Held still, then moved: the press becomes the drag it would have been (the finger rested before
                // moving: this used to open the value dialog and swallow the drag, the "can't move it" bug). Held
                // and let go without moving: the Modulation sheet (or, without a matrix, the value dialog).
                onLongPressStart: (d) {
                  DeviceFeel.tap();
                  _pressAt = _pressLast = d.localPosition;
                  _pressDragged = false;
                },
                onLongPressMoveUpdate: (d) {
                  if (!_pressDragged && (d.localPosition - _pressAt).distance < 6) return;
                  if (!_pressDragged) {
                    _pressDragged = true;
                    start(_pressAt);
                  }
                  update(d.localPosition.dy - _pressLast.dy);
                  _pressLast = d.localPosition;
                },
                onLongPressEnd: (_) {
                  if (_pressDragged) {
                    _pressDragged = false;
                    end();
                  } else {
                    longPress();
                  }
                },
                onLongPressCancel: () {
                  if (_pressDragged) {
                    _pressDragged = false;
                    end();
                  }
                },
                onVerticalDragStart: (d) => start(d.localPosition),
                onVerticalDragUpdate: (d) => update(d.delta.dy),
                onVerticalDragEnd: (_) => end(),
                onVerticalDragCancel: end,
                child: OverlayPortal(
                  controller: _bubble,
                  overlayChildBuilder: (_) => _ValueBubble(anchor: context, text: bubbleText, color: bubbleColor),
                  child: SizedBox(
                    width: _width,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Stack(clipBehavior: Clip.none, children: [
                        AnimatedScale(
                          scale: (hovering || _held) && Motion.of(context) == MotionLevel.full ? 1.08 : 1,
                          duration: Motion.fade(Motion.small, Motion.of(context)),
                          child: face),
                        if (routes.isNotEmpty || links.isNotEmpty) Positioned(right: -2, top: 0, child: _CountBadge(
                          key: ValueKey('dknob-badge-${p.id}'), count: routes.length + links.length,
                          color: routes.isNotEmpty ? modSourceColor((sel ?? routes.first).source)
                              : modulatorColor(app, links.first.source))),
                        if (assigning != null && canMod) Positioned(left: -2, top: 0, child: Icon(
                          assignedHere ? Icons.check_circle : Icons.add_circle_outline, size: 15,
                          color: modSourceColor(assigning)))
                        else if (projAssign != null && modTarget != null) Positioned(left: -2, top: 0, child: Icon(
                          projAssigned ? Icons.check_circle : Icons.add_circle_outline, size: 15,
                          color: modulatorColor(app, projAssign.modulatorId))),
                      ]),
                      Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: Neon.dim, height: 1.1)),
                      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: Neon.code(size: 10, color: color).copyWith(height: 1.25)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final key = ValueKey('dknob-${p.id}');
    // A modulator output dropped here links it (#161), as a dropped mod source makes a route.
    Widget takesLinks(Widget child) => modTarget == null ? child : DragTarget<ModSourceRef>(
      onWillAcceptWithDetails: (d) {
        if (app.whyNoLink(d.data, modTarget) != null &&
            app.project.linksTo(modTarget).every((l) => l.ref != d.data)) {
          return false;
        }
        DeviceFeel.detent();
        setState(() => _linkHover = true);
        return true;
      },
      onLeave: (_) => setState(() => _linkHover = false),
      onAcceptWithDetails: (d) {
        _linkHover = false;
        final link = app.addModLink(d.data, modTarget);
        if (link != null) {
          DeviceFeel.detent();
          setState(() => _lastLink = link.id);
        }
      },
      builder: (context, _, _) => child,
    );
    if (!canMod) return KeyedSubtree(key: key, child: takesLinks(knob()));
    final selNotifier = scope.selectedSlot, assigning = scope.assigning;
    Widget listening(Widget Function(ModSource? assigning) b) {
      Widget inner(ModSource? a) => selNotifier == null ? b(a)
          : ValueListenableBuilder<int?>(valueListenable: selNotifier, builder: (_, _, _) => b(a));
      return assigning == null ? inner(null)
          : ValueListenableBuilder<ModSource?>(valueListenable: assigning, builder: (_, a, _) => inner(a));
    }

    return KeyedSubtree(key: key, child: takesLinks(DragTarget<ModSource>(
        onWillAcceptWithDetails: (d) {
          if (d.data == ModSource.none) return false;
          DeviceFeel.detent(); // the finger reached a knob that takes it
          setState(() => _hover = true);
          return true;
        },
        onLeave: (_) => setState(() => _hover = false),
        onAcceptWithDetails: (d) {
          _hover = false;
          final slot = matrix!.add(d.data, p.id);
          if (slot != null) {
            DeviceFeel.detent();
            setState(() => _lastSlot = slot);
            scope.selectedSlot?.value = slot;
          } else {
            setState(() {});
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              duration: const Duration(seconds: 2), content: Text('All ${matrix.slotCount} modulation slots are in use')));
          }
        },
        builder: (context, hovering, _) => ValueListenableBuilder<ModSource?>(
          valueListenable: scope.dragging,
          builder: (context, dragging, _) => listening((a) => knob(
            offering: dragging ?? (hovering.isNotEmpty ? hovering.first : null),
            hovering: _hover || hovering.isNotEmpty,
            assigning: a)),
        ),
    )));
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
        MidiLearnButton(target: t, paramId: p.id),
        TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(c).pop(double.tryParse(field.text.trim())), child: const Text('Set')),
      ],
    ));
    field.dispose();
    if (typed != null) t.set(p.id, typed);
  }
}

/// How many routes move a knob: a small pill on its corner.
class _CountBadge extends StatelessWidget {
  const _CountBadge({super.key, required this.count, required this.color});
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(child: Container(
    constraints: const BoxConstraints(minWidth: 15),
    height: 15,
    padding: const EdgeInsets.symmetric(horizontal: 3),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8),
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)]),
    child: Text('$count', style: Neon.code(size: 9, color: Neon.bg).copyWith(fontWeight: FontWeight.w900, height: 1)),
  ));
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
    return Positioned(left: at.dx - 60, top: math.max(0, at.dy - 36), width: 120, child: IgnorePointer(child: Center(
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

/// A device knob's drawing (public for tests: [rings] is one entry per route).
class DeviceKnobPainter extends CustomPainter {
  DeviceKnobPainter({required this.pos, required this.color, required this.bipolar, required this.rings,
    this.modulated, this.highlight, this.strong = false, this.preview});
  final double pos;
  final Color color;
  final bool bipolar;

  /// Each route: its span, colour and whether it is the selected one.
  final List<((double, double), Color, bool)> rings;

  /// Where the routes take the knob now (≈), or null.
  final double? modulated;
  final Color? highlight;
  final bool strong;

  /// A route a dragged chip would make here (25 %), drawn dashed while it hovers.
  final ((double, double), Color)? preview;

  static const _start = math.pi * 0.75, _sweep = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 9;
    final rect = Rect.fromCircle(center: c, radius: r);
    if (highlight != null) {
      canvas.drawCircle(c, r + 7, Paint()..color = highlight!.withValues(alpha: strong ? 0.3 : 0.12));
      canvas.drawCircle(c, r + 7, Paint()
        ..color = highlight!.withValues(alpha: strong ? 1 : 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strong ? 2 : 1);
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
          colors: [color.withValues(alpha: 0.65), color, Color.lerp(color, Colors.white, 0.35)!],
          stops: const [0, 0.5, 0.75]).createShader(rect));
    stroke.shader = null;
    // One ring per route, outside the track, in its source's colour (up to four; the badge counts the rest).
    for (var i = 0; i < rings.length && i < 4; i++) {
      final ((lo, hi), rc, selected) = rings[i];
      final rr = Rect.fromCircle(center: c, radius: r + 5 + i * 3.4);
      canvas.drawArc(rr, _start, _sweep, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rc.withValues(alpha: 0.12));
      if (selected) {
        canvas.drawArc(rr, _start + _sweep * lo, math.max(0.04, _sweep * (hi - lo)), false, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..color = rc.withValues(alpha: 0.25));
      }
      canvas.drawArc(rr, _start + _sweep * lo, math.max(0.04, _sweep * (hi - lo)), false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : 2.2
        ..strokeCap = StrokeCap.round
        ..color = rc.withValues(alpha: selected ? 1 : 0.7));
    }
    if (preview != null) {
      final ((lo, hi), pc) = preview!;
      final rr = Rect.fromCircle(center: c, radius: r + 5 + math.min(rings.length, 3) * 3.4 + (rings.isEmpty ? 0 : 3.4));
      final dash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = pc.withValues(alpha: 0.85);
      const n = 10;
      for (var k = 0; k < n; k += 2) {
        canvas.drawArc(rr, _start + _sweep * (lo + (hi - lo) * k / n), _sweep * (hi - lo) / n, false, dash);
      }
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
    // The modulated value: a bright dot on the track, and a faint line from the knob's own value to it.
    if (modulated != null) {
      final m = modulated!;
      final am = _start + _sweep * m;
      canvas.drawArc(rect, _start + _sweep * math.min(pos, m), _sweep * (m - pos).abs(), false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.45));
      final dot = c + Offset(math.cos(am), math.sin(am)) * r;
      canvas.drawCircle(dot, 4.5, Paint()..color = Colors.white.withValues(alpha: 0.25));
      canvas.drawCircle(dot, 2.6, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant DeviceKnobPainter o) =>
      o.pos != pos || o.color != color || o.bipolar != bipolar || o.highlight != highlight || o.strong != strong ||
      o.modulated != modulated || o.preview != preview || !_sameRings(o.rings, rings);

  static bool _sameRings(List<((double, double), Color, bool)> a, List<((double, double), Color, bool)> b) {
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
      DeviceFeel.tap();
      t.set(p.id, p.min + k);
    }

    final Widget body;
    if (names.length <= maxSegments) {
      // 32 dp segments that dip and glow while pressed (feedback.dart), a haptic on pick.
      body = Container(
        height: 32,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Neon.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var k = 0; k < names.length; k++)
            Flexible(child: GestureDetector(
              key: ValueKey('dchoice-${p.id}-$k'),
              behavior: HitTestBehavior.opaque,
              onTap: () => pick(k),
              child: Pressable(glow: c, radius: 7, child: AnimatedContainer(
                duration: Motion.fade(Motion.small, Motion.of(context)),
                padding: const EdgeInsets.symmetric(horizontal: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: k == i ? c.withValues(alpha: 0.22) : Colors.transparent,
                  borderRadius: BorderRadius.circular(7)),
                child: Text(names[k], maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(
                  fontSize: 11, fontWeight: k == i ? FontWeight.w800 : FontWeight.w500, color: k == i ? c : Neon.dim)),
              )),
            )),
        ]),
      );
    } else {
      body = SizedBox(height: 32, child: DropdownButtonHideUnderline(child: DropdownButton<int>(
        key: ValueKey('dchoice-${p.id}'),
        value: i,
        isDense: true,
        style: Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 12, color: c, fontWeight: FontWeight.w700),
        iconSize: 18,
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
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      color: on ? c : Neon.dim,
      onPressed: () {
        DeviceFeel.tap();
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
          onHorizontalDragStart: (d) {
            DeviceFeel.grab();
            at(d.localPosition.dx);
          },
          onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
          onHorizontalDragEnd: (_) {
            DeviceFeel.release();
            t.commit();
          },
          child: SizedBox(height: 40, child: CustomPaint(
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
