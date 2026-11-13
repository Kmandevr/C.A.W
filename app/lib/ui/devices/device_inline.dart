// A device shown right in the FX stack: its faceplate header, compact hero and main controls, live only while on screen.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/device_target.dart';
import '../../model/mod_matrix.dart';
import '../arrange/track_color.dart';
import '../glass.dart';
import '../motion.dart';
import '../theme.dart';
import 'device_editor.dart' show DevicePresetChip;
import 'device_registry.dart';
import 'device_scope.dart';
import 'sidechain_bar.dart';
import 'kit/hero.dart' show MotionTouch;
import 'kit/param_watch.dart';
import 'kit/device_style.dart';
import 'kit/feel.dart';
import 'kit/presets.dart';

/// Whether [target]'s device has a plugin UI the FX stack shows inline (built-ins with a custom editor, once their
/// descriptor is known); others keep the knob card.
bool hasInlineDevice(DeviceTarget target) {
  final id = target.componentId, info = target.info;
  return id != null && info != null && DeviceEditors.custom(id, info) != null;
}

/// A device's plugin UI inline in the FX stack (owner, 2026-11-10: "Show the UI right in the FX tab"): the faceplate
/// header (drag handle [leading], family badge, name, preset, then the stack's [actions]: ⤢, bypass, remove), the
/// hero at a compact height and the main controls ([DeviceEditorEntry.inline], else its first section laid out
/// compact). It has its own repaint boundary, and its motion and live display run only while it is on screen.
class DeviceInline extends StatefulWidget {
  const DeviceInline({super.key, required this.target, this.leading, this.actions = const [], this.onTitle,
    this.titleKey, this.onMenu, this.selected = false, this.glow, this.onSelect, this.matrix, this.nested = false});
  final DeviceTarget target;
  final Widget? leading;
  final List<Widget> actions;

  /// A tap on the name (the stack opens the device full screen).
  final VoidCallback? onTitle;
  final Key? titleKey;

  /// A long-press or right-click on the header: the stack's options menu.
  final void Function(Offset at)? onMenu;
  final bool selected;
  final Color? glow;
  final VoidCallback? onSelect;

  /// The mod matrix its knobs show (null: the device's own). A rack's child (fx-racks) takes the rack's, by prefix.
  final ModMatrix? matrix;

  /// Inside another device (a rack's chain): it shares that device's drag, assign mode and selected route, and has
  /// no sidechain bar of its own.
  final bool nested;

  @override
  State<DeviceInline> createState() => _DeviceInlineState();
}

class _DeviceInlineState extends State<DeviceInline> {
  final _dragging = ValueNotifier<ModSource?>(null);
  final _focus = ValueNotifier<ModSource>(ModSource.env1);
  final _assigning = ValueNotifier<ModSource?>(null);
  final _selected = ValueNotifier<int?>(null);

  DeviceTarget get t => widget.target;
  AppState get s => t.state;

  @override
  void dispose() {
    _dragging.dispose();
    _focus.dispose();
    _assigning.dispose();
    _selected.dispose();
    super.dispose();
  }

  @override
  // Rebuilt by a value it shows, not by a knob step of a value only that knob shows (param_watch.dart).
  Widget build(BuildContext context) =>
      MotionTouch(child: ParamWatch(target: t, page: true, also: s.componentCatalog, builder: _build));

  Widget _build(BuildContext context) {
    final use = t.use, layer = t.layer, info = t.info;
    final entry = use == null ? null : DeviceEditors.custom(use.id, info);
    if (use == null || layer == null || info == null || entry == null) return const SizedBox.shrink();
    if (entry.presets.isNotEmpty) DevicePresets.register(use.id, entry.presets);
    final style = entry.family == null ? null : deviceStyle(entry.family!);
    final color = entry.accent ?? style?.primary ?? trackColor(s, layer);
    final second = style?.secondary ?? color;
    final matrix = widget.matrix ?? ModMatrix(t);
    final glow = widget.glow ?? color;
    final key = t.isInstrument ? 'instrument' : (t.displayChild > 0 ? '${t.slot}-${t.displayChild}' : '${t.slot}');
    final parent = widget.nested ? DeviceScope.maybeOf(context) : null;
    return OnScreenGate(child: RepaintBoundary(child: DeviceScope(
      target: t,
      matrix: matrix.slotCount > 0 ? matrix : null,
      dragging: parent?.dragging ?? _dragging,
      accent: color,
      secondary: second,
      focusSource: parent?.focusSource ?? _focus,
      assigning: matrix.slotCount > 0 ? (parent?.assigning ?? _assigning) : null,
      selectedSlot: parent?.selectedSlot ?? _selected,
      inline: true,
      child: Builder(builder: (context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Listener(
          onPointerDown: (_) {
            if (!widget.selected) widget.onSelect?.call();
          },
          child: DeviceFingers.counter(child: DecoratedBox(
            key: ValueKey('fx-inline-$key'),
            // The selected device glows in its track's colour, as the knob cards do (owner, 2026-11-09).
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: widget.selected ? glow : color.withValues(alpha: 0.25),
                width: widget.selected ? 1.6 : 1),
              boxShadow: widget.selected ? [BoxShadow(color: glow.withValues(alpha: 0.35), blurRadius: 10)] : null),
            child: GlassPanel(radius: 12, tint: color, child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                _header(context, color, second, style, key),
                Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: Neon.ramp([
                  color.withValues(alpha: 0.0), color.withValues(alpha: 0.8), second.withValues(alpha: 0.8),
                  second.withValues(alpha: 0.0)])))),
                if (!widget.nested) SidechainBar(target: t, color: color),
                AnimatedOpacity(
                  duration: Motion.fade(Motion.small, Motion.of(context)),
                  opacity: t.bypass ? 0.55 : 1,
                  child: KeyedSubtree(key: ValueKey('fx-inline-body-$key'),
                    child: entry.inline?.call(context) ?? entry.sections(t).first.builder(context))),
              ])),
          )),
        ),
      )),
    )));
  }

  Widget _header(BuildContext context, Color color, Color second, DeviceStyle? style, String key) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPressStart: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
    onSecondaryTapUp: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
    child: SizedBox(height: 42, child: LayoutBuilder(builder: (context, box) {
      // The name keeps about 72 dp; the preset chip takes what is left, up to 128, and hides below 64 (the full
      // screen editor still has it). Each action is a 48 dp touch target.
      final fixed = (widget.leading == null ? 8 : 32) + 32 + 48.0 * widget.actions.length;
      final chip = (box.maxWidth - fixed - 72).clamp(0.0, 128.0);
      return Row(children: [
      widget.leading ?? const SizedBox(width: 8),
      Container(
        width: 26, height: 26,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: Neon.ramp([color.withValues(alpha: 0.9), second.withValues(alpha: 0.75)])),
          boxShadow: Neon.glow(color, strength: 0.3)),
        child: Icon(style?.icon ?? Icons.extension_outlined, size: 15, color: Neon.bg)),
      const SizedBox(width: 6),
      Expanded(child: InkWell(
        key: widget.titleKey,
        onTap: widget.onTitle,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          Text(style?.label ?? 'Built-in', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, color: color)),
        ]),
      )),
      if (chip >= 64) ConstrainedBox(constraints: BoxConstraints(maxWidth: chip), child: Row(mainAxisSize: MainAxisSize.min, children: [
        DevicePresetChip(target: t, color: color, maxWidth: chip, chipKey: ValueKey('fx-presets-$key')),
      ])),
      ...widget.actions,
    ]);
    })),
  );
}

/// Runs [child]'s tickers, motion and live display polling only while some part of it is inside every scrolling
/// viewport around it (the FX stack scrolled; a device scrolled away stands still and polls nothing).
class OnScreenGate extends StatefulWidget {
  const OnScreenGate({super.key, required this.child});
  final Widget child;

  @override
  State<OnScreenGate> createState() => OnScreenGateState();
}

class OnScreenGateState extends State<OnScreenGate> {
  final List<ScrollableState> _scrollables = [];
  bool _visible = true;
  bool _checkPending = false;

  /// Whether the child counts as on screen now.
  bool get visible => _visible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Scrollable.maybeOf(context); // depend on the nearest scrollable, so a new one is picked up
    _unlisten();
    BuildContext? ctx = context;
    while (ctx != null) {
      final s = ctx.findAncestorStateOfType<ScrollableState>();
      if (s == null) break;
      _scrollables.add(s);
      s.position.addListener(_scheduleCheck);
      ctx = s.context;
    }
    _scheduleCheck();
  }

  void _unlisten() {
    for (final s in _scrollables) {
      if (s.mounted) s.position.removeListener(_scheduleCheck);
    }
    _scrollables.clear();
  }

  @override
  void dispose() {
    _unlisten();
    super.dispose();
  }

  void _scheduleCheck() {
    if (_checkPending) return;
    _checkPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPending = false;
      if (mounted) _check();
    });
  }

  void _check() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final me = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    var on = true;
    for (final s in _scrollables) {
      final view = s.context.findRenderObject();
      if (view is! RenderBox || !view.attached || !view.hasSize) continue;
      final r = MatrixUtils.transformRect(view.getTransformTo(null), Offset.zero & view.size);
      if (!r.overlaps(me)) {
        on = false;
        break;
      }
    }
    if (on != _visible) setState(() => _visible = on);
  }

  @override
  Widget build(BuildContext context) {
    // Layout may have moved it (a reorder, a resized panel): check again after this frame.
    _scheduleCheck();
    return TickerMode(enabled: _visible, child: widget.child);
  }
}
