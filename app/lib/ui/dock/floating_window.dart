// A docked panel taken out into a window over the layout (desktop): drag its title bar to move it, its corner to
// resize it; ⇲ docks it back.
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

  @override
  Widget build(BuildContext context) {
    final a = widget.area;
    return Positioned(
      left: _r.left * a.width,
      top: _r.top * a.height,
      width: _r.width * a.width,
      height: _r.height * a.height,
      child: Listener(
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
              child: Container(
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
              ),
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
      ),
    );
  }
}
