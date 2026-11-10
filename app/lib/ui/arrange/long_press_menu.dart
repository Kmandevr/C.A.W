// Long-press menus (owner, 2026-11-09): a compact glass list near the finger, or a Bitwig-style ring as a setting.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../glass.dart';
import '../motion.dart';
import '../theme.dart';

/// One entry of a long-press menu: an icon and a short name, optionally ticked, disabled or destructive.
@immutable
class MenuAction<T> {
  const MenuAction(this.value, this.label, this.icon,
      {this.enabled = true, this.danger = false, this.checked = false, this.hint});
  final T value;
  final String label;
  final IconData icon;
  final bool enabled, danger, checked;

  /// Why a disabled entry is disabled (shown under it in the list, and as the ring's tooltip).
  final String? hint;
}

/// Opens a menu of [actions] at [at] (a global position, usually where the finger is) and returns the chosen
/// value, or null when dismissed. [style] picks the list or the ring; a light haptic tick marks it opening.
Future<T?> showLongPressMenu<T>(BuildContext context,
    {required Offset at, required List<MenuAction<T>> actions, LongPressMenuStyle style = LongPressMenuStyle.list,
    String? title}) {
  if (actions.isEmpty) return Future.value(null);
  Motion.tick();
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close menu',
    barrierColor: Colors.black.withValues(alpha: style == LongPressMenuStyle.ring ? 0.25 : 0.08),
    transitionDuration: Motion.fade(Motion.small, Motion.of(context)),
    pageBuilder: (context, _, _) => style == LongPressMenuStyle.ring
        ? _RingMenu<T>(at: at, actions: actions, title: title)
        : _ListMenu<T>(at: at, actions: actions, title: title),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(animation), child: child),
    ),
  );
}

/// The point to open a menu at for a widget that has no finger position (a button, a keyboard): its centre.
Offset menuAnchorOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Offset.zero;
  return box.localToGlobal(box.size.center(Offset.zero));
}

class _ListMenu<T> extends StatelessWidget {
  const _ListMenu({required this.at, required this.actions, this.title});
  final Offset at;
  final List<MenuAction<T>> actions;
  final String? title;

  static const width = 228.0, row = 36.0;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final height = math.min(screen.height - pad.vertical - 16,
        actions.length * row + (title == null ? 0 : 28) + 12 + actions.where((a) => a.hint != null && !a.enabled).length * 12);
    // Beside the finger, kept on screen; above it when there is no room below.
    var left = at.dx + 8;
    if (left + width > screen.width - 8) left = math.max(8.0, at.dx - width - 8);
    var top = at.dy - 12;
    if (top + height > screen.height - pad.bottom - 8) top = screen.height - pad.bottom - 8 - height;
    top = math.max(pad.top + 8, top);
    return Stack(children: [
      Positioned(left: left, top: top, width: width, height: height, child: Material(
        type: MaterialType.transparency,
        child: GlassOverlay(
          key: const ValueKey('long-press-menu'),
          radius: 12,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ListView(padding: EdgeInsets.zero, shrinkWrap: true, children: [
            if (title != null)
              SizedBox(height: 28, child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(alignment: Alignment.centerLeft, child: Text(title!.toUpperCase(),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w700))),
              )),
            for (final a in actions) _row(context, a),
          ]),
        ),
      )),
    ]);
  }

  Widget _row(BuildContext context, MenuAction<T> a) {
    final color = !a.enabled ? Neon.dim.withValues(alpha: 0.6) : a.danger ? Neon.pink : Neon.text;
    return InkWell(
      onTap: a.enabled ? () => Navigator.of(context).pop(a.value) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: row),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            Icon(a.icon, size: 18, color: a.danger && a.enabled ? Neon.pink : (a.enabled ? Neon.dim : color)),
            const SizedBox(width: 10),
            Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: color)),
              if (!a.enabled && a.hint != null)
                Text(a.hint!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, color: Neon.dim)),
            ])),
            if (a.checked) const Icon(Icons.check, size: 16, color: Neon.green),
          ]),
        ),
      ),
    );
  }
}

/// The ring: the actions around the finger, the hovered (or last touched) one named in the middle.
class _RingMenu<T> extends StatefulWidget {
  const _RingMenu({required this.at, required this.actions, this.title});
  final Offset at;
  final List<MenuAction<T>> actions;
  final String? title;

  @override
  State<_RingMenu<T>> createState() => _RingMenuState<T>();
}

class _RingMenuState<T> extends State<_RingMenu<T>> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final n = widget.actions.length;
    const button = 44.0;
    final radius = math.max(72.0, n * (button + 8) / (2 * math.pi));
    final size = MediaQuery.sizeOf(context);
    final reach = radius + button / 2 + 8;
    final centre = Offset(widget.at.dx.clamp(reach, math.max(reach, size.width - reach)).toDouble(),
        widget.at.dy.clamp(reach, math.max(reach, size.height - reach)).toDouble());
    final label = _hover != null ? widget.actions[_hover!].label : (widget.title ?? '');
    return Material(type: MaterialType.transparency, child: Stack(key: const ValueKey('long-press-ring'), children: [
      Positioned(left: centre.dx - radius + button / 2, top: centre.dy - radius + button / 2,
        width: 2 * radius - button, height: 2 * radius - button,
        child: IgnorePointer(child: GlassOverlay(radius: radius, child: Center(child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ))))),
      for (var i = 0; i < n; i++) () {
        final a = widget.actions[i];
        final angle = -math.pi / 2 + 2 * math.pi * i / n;
        final p = centre + Offset(math.cos(angle), math.sin(angle)) * radius;
        final color = !a.enabled ? Neon.dim.withValues(alpha: 0.5) : a.danger ? Neon.pink : Neon.blue;
        return Positioned(left: p.dx - button / 2, top: p.dy - button / 2, width: button, height: button,
          child: Tooltip(message: a.enabled ? a.label : '${a.label}${a.hint == null ? '' : ' (${a.hint})'}',
            child: MouseRegion(
              onEnter: (_) => setState(() => _hover = i),
              child: InkResponse(
                radius: button / 2,
                onTap: a.enabled ? () => Navigator.of(context).pop(a.value) : null,
                onHighlightChanged: (on) { if (on) setState(() => _hover = i); },
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle,
                    color: Color.lerp(Neon.panelHi, color, a.checked ? 0.35 : 0.12)!.withValues(alpha: 0.92),
                    border: Border.all(color: color.withValues(alpha: a.enabled ? 0.9 : 0.4))),
                  child: Icon(a.icon, size: 18, color: a.enabled ? (a.danger ? Neon.pink : Neon.text) : color),
                ),
              ),
            )));
      }(),
    ]));
  }
}
