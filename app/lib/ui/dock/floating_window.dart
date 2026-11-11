// A docked panel taken out into a window over the layout (desktop): drag its title bar to move it, its corner (or,
// with a mouse, any edge or corner) to resize it; ⇲ docks it back.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../glass.dart';
import '../theme.dart';
import '../tokens.dart';
import 'dock_controller.dart';

class FloatingWindow extends StatefulWidget {
  const FloatingWindow({
    super.key,
    required this.panel,
    required this.area,
    required this.title,
    required this.child,
    required this.onPlace,
    required this.onDock,
    required this.onRaise,
  });

  final FloatingPanel panel;
  final Size area;
  final String title;
  final Widget child;
  final void Function(Rect rect, {bool save}) onPlace;
  final VoidCallback onDock, onRaise;

  @override
  State<FloatingWindow> createState() => _FloatingWindowState();
}

class _FloatingWindowState extends State<FloatingWindow> {
  Rect get _r => widget.panel.rect;

  void _move(Offset d, {bool resize = false}) {
    final dx = d.dx / widget.area.width, dy = d.dy / widget.area.height;
    widget.onPlace(
        resize
            ? Rect.fromLTWH(_r.left, _r.top, _r.width + dx, _r.height + dy)
            : _r.translate(dx, dy),
        save: false);
  }

  // The smallest window, as a share of the area (FloatingPanel.clampRect's).
  static const _minShare = 0.2;

  /// A mouse drag on an edge or corner: the sides named move by [d], the opposite ones stay.
  void _resizeEdges(Offset d, {bool left = false, bool top = false, bool right = false, bool bottom = false}) {
    final dx = d.dx / widget.area.width, dy = d.dy / widget.area.height;
    var l = _r.left, t = _r.top, r = _r.right, b = _r.bottom;
    if (left) l = (l + dx).clamp(double.negativeInfinity, r - _minShare).toDouble();
    if (right) r = (r + dx).clamp(l + _minShare, double.infinity).toDouble();
    if (top) t = (t + dy).clamp(0.0, b - _minShare).toDouble();
    if (bottom) b = (b + dy).clamp(t + _minShare, double.infinity).toDouble();
    widget.onPlace(Rect.fromLTRB(l, t, r, b), save: false);
  }

  /// A mouse-only resize handle along an edge or at a corner (touch keeps the corner grip alone).
  Widget _edge(String id, MouseCursor cursor, void Function(Offset d) onDrag) => MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          key: ValueKey('float-edge-$id-${widget.panel.id}'),
          behavior: HitTestBehavior.translucent,
          supportedDevices: const {PointerDeviceKind.mouse, PointerDeviceKind.trackpad},
          onPanStart: (_) => widget.onRaise(),
          onPanUpdate: (d) => onDrag(d.delta),
          onPanEnd: (_) => widget.onPlace(_r),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final a = widget.area;
    const e = 5.0, c = 12.0; // an edge's grip, a corner's
    return Positioned(
      left: _r.left * a.width,
      top: _r.top * a.height,
      width: _r.width * a.width,
      height: _r.height * a.height,
      child: Stack(children: [
        Positioned.fill(child: Listener(
        onPointerDown: (_) => widget.onRaise(),
        // No blur: a floating window stays over live, repainting panels (the playhead, meters), where a backdrop
        // blur would run again on every frame; it keeps the glass look with a denser tint.
        child: GlassOverlay(
          blur: false,
          radius: Radii.m,
          padding: EdgeInsets.zero,
          child: Column(children: [
            GestureDetector(
              key: ValueKey('float-bar-${widget.panel.id}'),
              onPanUpdate: (d) => _move(d.delta),
              onPanEnd: (_) => widget.onPlace(_r),
              child: MouseRegion(cursor: SystemMouseCursors.move, child: Container(
                height: 30,
                padding: const EdgeInsets.only(left: 10),
                color: Colors.white.withValues(alpha: 0.04),
                child: Row(children: [
                  Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                  IconButton(
                    key: ValueKey('float-dock-${widget.panel.id}'),
                    tooltip: 'Dock ${widget.title}',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    color: Neon.dim,
                    icon: const Icon(Icons.call_to_action),
                    onPressed: widget.onDock,
                  ),
                ]),
              )),
            ),
            Expanded(
              child: Stack(children: [
                Positioned.fill(child: ClipRect(child: widget.child)),
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: 20,
                  height: 20,
                  child: GestureDetector(
                    key: ValueKey('float-resize-${widget.panel.id}'),
                    onPanUpdate: (d) => _move(d.delta, resize: true),
                    onPanEnd: (_) => widget.onPlace(_r),
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: Icon(Icons.south_east, size: 14, color: Neon.dim),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        )),
        // Mouse resize from every edge and corner, over the window's border.
        Positioned(left: c, right: c, top: 0, height: e,
            child: _edge('top', SystemMouseCursors.resizeUpDown, (d) => _resizeEdges(d, top: true))),
        Positioned(left: c, right: c, bottom: 0, height: e,
            child: _edge('bottom', SystemMouseCursors.resizeUpDown, (d) => _resizeEdges(d, bottom: true))),
        Positioned(top: c, bottom: c, left: 0, width: e,
            child: _edge('left', SystemMouseCursors.resizeLeftRight, (d) => _resizeEdges(d, left: true))),
        Positioned(top: c, bottom: c, right: 0, width: e,
            child: _edge('right', SystemMouseCursors.resizeLeftRight, (d) => _resizeEdges(d, right: true))),
        Positioned(left: 0, top: 0, width: c, height: c, child: _edge('top-left', SystemMouseCursors.resizeUpLeftDownRight,
            (d) => _resizeEdges(d, left: true, top: true))),
        Positioned(right: 0, top: 0, width: c, height: c, child: _edge('top-right',
            SystemMouseCursors.resizeUpRightDownLeft, (d) => _resizeEdges(d, right: true, top: true))),
        Positioned(left: 0, bottom: 0, width: c, height: c, child: _edge('bottom-left',
            SystemMouseCursors.resizeUpRightDownLeft, (d) => _resizeEdges(d, left: true, bottom: true))),
      ]),
    );
  }
}
