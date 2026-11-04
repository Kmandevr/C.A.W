// Draws a docking layout: splits with draggable dividers, tab groups, long-press drags onto five drop zones, maximise.
// Not wired into the shell yet; each panel's body comes from the caller.
import 'package:flutter/material.dart';

import '../glass.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'layout.dart';

/// A panel's tab title.
String dockPanelTitle(String id) => switch (id) {
      Panels.arrangement => 'Arrange',
      Panels.builder => 'Code',
      Panels.mixer => 'Mixer',
      Panels.engineLab => 'Engine lab',
      Panels.automation => 'Automation',
      Panels.exporter => 'Export',
      Panels.files => 'Files',
      Panels.pluginBuilder => 'Plugins',
      _ => id,
    };

/// Draws [layout] and reports every edit (divider drags, tab taps, drops) through [onChanged]. The caller keeps the
/// layout and passes the new one back.
///
/// Every panel body sits under a `GlobalObjectKey(id)` and its own `RepaintBoundary`, so it keeps its state when it
/// moves to another group or is maximised. Hidden tabs stay mounted with their tickers off.
class DockView extends StatefulWidget {
  const DockView({
    super.key,
    required this.layout,
    required this.onChanged,
    required this.panelBuilder,
    this.titleOf = dockPanelTitle,
  });

  final DockLayout layout;
  final ValueChanged<DockLayout> onChanged;
  final Widget Function(BuildContext context, String id) panelBuilder;
  final String Function(String id) titleOf;

  /// The gap between panels; the divider's grab zone is wider ([Targets.of]).
  static const double gap = 6;

  @override
  State<DockView> createState() => _DockViewState();
}

class _DockViewState extends State<DockView> {
  String? _maximised;

  /// The panel bodies, built once per id and moved around the tree by their global keys.
  Widget _body(String id, {required bool shown}) => TickerMode(
        enabled: shown,
        child: KeyedSubtree(
          key: GlobalObjectKey(id),
          child: RepaintBoundary(child: Builder(builder: (c) => widget.panelBuilder(c, id))),
        ),
      );

  @override
  void didUpdateWidget(DockView old) {
    super.didUpdateWidget(old);
    if (_maximised != null && !widget.layout.contains(_maximised!)) _maximised = null;
  }

  void _toggleMax(String id) => setState(() => _maximised = _maximised == id ? null : id);

  @override
  Widget build(BuildContext context) {
    final max = _maximised;
    final tree = _node(widget.layout.root, const []);
    if (max == null) return Padding(padding: const EdgeInsets.all(DockView.gap / 2), child: tree);
    // The rest of the tree stays mounted (and keeps its state) offstage while one panel fills the view.
    return Stack(children: [
      Offstage(child: TickerMode(enabled: false, child: tree)),
      Padding(
        padding: const EdgeInsets.all(DockView.gap / 2),
        child: _Group(
          tabs: TabsNode([max]),
          title: widget.titleOf,
          maximised: true,
          onActivate: (_) {},
          onMaximise: _toggleMax,
          onDrop: (_, _) {},
          body: _body(max, shown: true),
        ),
      ),
    ]);
  }

  Widget _node(DockNode n, List<int> path) => switch (n) {
        TabsNode t => _Group(
            tabs: t,
            title: widget.titleOf,
            maximised: false,
            onActivate: (id) => widget.onChanged(widget.layout.activate(id)),
            onMaximise: _toggleMax,
            onDrop: (id, edge) => widget.onChanged(widget.layout.dock(id, target: t.activePanel, edge: edge)),
            body: IndexedStack(
              index: t.active,
              sizing: StackFit.expand,
              children: [
                for (final p in t.panels)
                  p == _maximised ? const SizedBox.shrink() : _body(p, shown: p == t.panels[t.active]),
              ],
            ),
          ),
        SplitNode s => _Split(
            split: s,
            onWeights: (w) => widget.onChanged(widget.layout.setWeights(path, w)),
            children: [for (var i = 0; i < s.children.length; i++) _node(s.children[i], [...path, i])],
          ),
      };
}

/// Children laid out by their shares, with a divider between each pair.
class _Split extends StatelessWidget {
  const _Split({required this.split, required this.onWeights, required this.children});

  final SplitNode split;
  final ValueChanged<List<double>> onWeights;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final row = split.axis == DockAxis.row;
        final total = row ? box.maxWidth : box.maxHeight;
        final n = children.length;
        final room = (total - DockView.gap * (n - 1)).clamp(0.0, double.infinity);
        final grab = Targets.of(context);
        final kids = <Widget>[];
        final dividers = <Widget>[];
        var at = 0.0;
        for (var i = 0; i < n; i++) {
          final size = room * split.weights[i];
          kids.add(Positioned(
            left: row ? at : 0,
            top: row ? 0 : at,
            width: row ? size : box.maxWidth,
            height: row ? box.maxHeight : size,
            child: children[i],
          ));
          at += size;
          if (i < n - 1) {
            final centre = at + DockView.gap / 2;
            dividers.add(Positioned(
              left: row ? centre - grab / 2 : 0,
              top: row ? 0 : centre - grab / 2,
              width: row ? grab : box.maxWidth,
              height: row ? box.maxHeight : grab,
              child: _Divider(
                axis: split.axis,
                index: i,
                onDrag: (delta) {
                  if (room <= 0) return;
                  // A drag past the minimum stops there, on either side.
                  final w = [...split.weights];
                  final lo = DockLayout.minWeight - w[i], hi = w[i + 1] - DockLayout.minWeight;
                  if (lo > hi) return;
                  final d = (delta / room).clamp(lo, hi);
                  if (d == 0) return;
                  w[i] += d;
                  w[i + 1] -= d;
                  onWeights(w);
                },
              ),
            ));
            at += DockView.gap;
          }
        }
        return Stack(children: [...kids, ...dividers]);
      });
}

/// A divider's grab zone: a drag along the split's axis moves the boundary. Taps pass through to the panels.
class _Divider extends StatefulWidget {
  const _Divider({required this.axis, required this.index, required this.onDrag});

  final DockAxis axis;
  final int index;
  final ValueChanged<double> onDrag;

  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.axis == DockAxis.row;
    final level = Motion.of(context);
    void start(_) => setState(() => _active = true);
    void end([_]) => setState(() => _active = false);
    return Semantics(
      label: 'Resize panels',
      child: MouseRegion(
        cursor: row ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        child: GestureDetector(
          key: ValueKey('dock-divider-${widget.axis.name}-${widget.index}'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: row ? start : null,
          onHorizontalDragUpdate: row ? (d) => widget.onDrag(d.delta.dx) : null,
          onHorizontalDragEnd: row ? end : null,
          onHorizontalDragCancel: row ? end : null,
          onVerticalDragStart: row ? null : start,
          onVerticalDragUpdate: row ? null : (d) => widget.onDrag(d.delta.dy),
          onVerticalDragEnd: row ? null : end,
          onVerticalDragCancel: row ? null : end,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.fade(Motion.small, level),
              width: row ? 3 : (_active ? 56 : 32),
              height: row ? (_active ? 56 : 32) : 3,
              decoration: BoxDecoration(
                color: _active ? Roles.accent : Neon.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab group: its tab strip (tap to show, long-press to drag, maximise) over the shown body, and the drop
/// target for dragged tabs, which shows where a drop would land.
class _Group extends StatefulWidget {
  const _Group({
    required this.tabs,
    required this.title,
    required this.maximised,
    required this.onActivate,
    required this.onMaximise,
    required this.onDrop,
    required this.body,
  });

  final TabsNode tabs;
  final String Function(String) title;
  final bool maximised;
  final ValueChanged<String> onActivate, onMaximise;
  final void Function(String id, DockEdge edge) onDrop;
  final Widget body;

  @override
  State<_Group> createState() => _GroupState();
}

/// Which drop zone a point falls in: the middle half is the centre (join the group), otherwise the nearest edge.
DockEdge dockEdgeAt(Offset local, Size size) {
  if (size.isEmpty) return DockEdge.center;
  final x = local.dx / size.width, y = local.dy / size.height;
  final d = {DockEdge.left: x, DockEdge.right: 1 - x, DockEdge.top: y, DockEdge.bottom: 1 - y};
  final nearest = d.entries.reduce((a, b) => a.value <= b.value ? a : b);
  return nearest.value < 0.25 ? nearest.key : DockEdge.center;
}

class _GroupState extends State<_Group> {
  DockEdge? _hover;
  final _bodyKey = GlobalKey();

  DockEdge _edgeFor(Offset global) {
    final box = _bodyKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return DockEdge.center;
    return dockEdgeAt(box.globalToLocal(global), box.size);
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    return GlassPanel(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.m),
        child: Column(children: [
          _TabStrip(
            tabs: widget.tabs,
            title: widget.title,
            maximised: widget.maximised,
            onActivate: widget.onActivate,
            onMaximise: widget.onMaximise,
          ),
          Expanded(
            child: DragTarget<String>(
              onWillAcceptWithDetails: (d) => !widget.maximised && Panels.known(d.data),
              onMove: (d) {
                final e = _edgeFor(d.offset);
                if (e != _hover) {
                  setState(() => _hover = e);
                  Motion.tick();
                }
              },
              onLeave: (_) => setState(() => _hover = null),
              onAcceptWithDetails: (d) {
                final e = _edgeFor(d.offset);
                setState(() => _hover = null);
                widget.onDrop(d.data, e);
              },
              builder: (context, candidates, _) => Stack(key: _bodyKey, fit: StackFit.expand, children: [
                widget.body,
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: candidates.isNotEmpty && _hover != null ? 1 : 0,
                    duration: Motion.fade(Motion.small, level),
                    child: _DropPreview(edge: _hover ?? DockEdge.center),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The highlighted area a drop would fill: the whole group for the centre, or the half on that edge.
class _DropPreview extends StatelessWidget {
  const _DropPreview({required this.edge});

  final DockEdge edge;

  @override
  Widget build(BuildContext context) {
    final align = switch (edge) {
      DockEdge.center => Alignment.center,
      DockEdge.left => Alignment.centerLeft,
      DockEdge.right => Alignment.centerRight,
      DockEdge.top => Alignment.topCenter,
      DockEdge.bottom => Alignment.bottomCenter,
    };
    final horizontal = edge == DockEdge.left || edge == DockEdge.right;
    final vertical = edge == DockEdge.top || edge == DockEdge.bottom;
    return Padding(
      padding: const EdgeInsets.all(Space.xs),
      child: FractionallySizedBox(
        alignment: align,
        widthFactor: horizontal ? 0.5 : 1,
        heightFactor: vertical ? 0.5 : 1,
        child: DecoratedBox(
          key: ValueKey('dock-drop-${edge.name}'),
          decoration: BoxDecoration(
            color: Roles.selection.withValues(alpha: 0.18),
            border: Border.all(color: Roles.selection.withValues(alpha: 0.8), width: 2),
            borderRadius: BorderRadius.circular(Radii.s),
          ),
        ),
      ),
    );
  }
}

/// The tabs of one group (scrolling sideways when they don't fit) and the maximise button.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.title,
    required this.maximised,
    required this.onActivate,
    required this.onMaximise,
  });

  final TabsNode tabs;
  final String Function(String) title;
  final bool maximised;
  final ValueChanged<String> onActivate, onMaximise;

  @override
  Widget build(BuildContext context) {
    final h = Targets.of(context) - 8;
    final shown = tabs.activePanel;
    return SizedBox(
      height: h,
      child: Row(children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            children: [
              for (final p in tabs.panels)
                _Tab(id: p, title: title(p), selected: p == shown, draggable: !maximised, onTap: () => onActivate(p)),
            ],
          ),
        ),
        IconButton(
          key: ValueKey('dock-max-$shown'),
          tooltip: maximised ? 'Restore layout' : 'Maximise ${title(shown)}',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          color: Neon.dim,
          icon: Icon(maximised ? Icons.close_fullscreen : Icons.open_in_full),
          onPressed: () => onMaximise(shown),
        ),
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.id, required this.title, required this.selected, required this.draggable, required this.onTap});

  final String id, title;
  final bool selected, draggable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final label = Semantics(
      selected: selected,
      button: true,
      label: '$title panel',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('dock-tab-$id'),
        borderRadius: BorderRadius.circular(Radii.s),
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.fade(Motion.standard, level),
          margin: const EdgeInsets.symmetric(vertical: Space.xs, horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Roles.accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.s),
            border: Border.all(color: selected ? Roles.accent.withValues(alpha: 0.6) : Colors.transparent),
          ),
          child: Text(
            title,
            style: TextStyle(
              fontSize: TypeScale.label,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? Neon.text : Neon.dim,
            ),
          ),
        ),
      ),
    );
    if (!draggable) return label;
    return LongPressDraggable<String>(
      data: id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      hapticFeedbackOnStart: Motion.haptics,
      feedback: Material(
        type: MaterialType.transparency,
        child: Transform.translate(
          offset: const Offset(-40, -24),
          child: GlassOverlay(
            radius: Radii.m,
            padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.s),
            child: Text(title, style: TextStyle(color: Neon.text, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: label),
      child: label,
    );
  }
}
