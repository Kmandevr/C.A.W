// Draws a docking layout: splits with draggable dividers, tab groups, long-press drags onto five drop zones, maximise.
// Not wired into the shell yet; each panel's body comes from the caller.
import 'package:flutter/material.dart';

import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'layout.dart';

/// A panel's tab title.
String dockPanelTitle(String id) => switch (id) {
  Panels.arrangement => 'Arrange',
  Panels.builder => 'Build',
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
    this.onFloat,
  });

  /// Takes a panel into a floating window (desktop); null hides the button.
  final ValueChanged<String>? onFloat;

  final DockLayout layout;
  final ValueChanged<DockLayout> onChanged;
  final Widget Function(BuildContext context, String id) panelBuilder;
  final String Function(String id) titleOf;

  /// The gap between panels; the divider's grab zone is wider ([Targets.of]).
  static const double gap = 6;

  /// How far a divider's grab zone reaches into each panel beside it. Kept small so a scroll or drag that starts
  /// near a panel's edge still reaches the panel.
  static const double grabReach = 10;

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
      // The panel's own size stands in for the screen's, so a screen lays out for the space it has.
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (c, box) => MediaQuery(
                data: MediaQuery.of(c).copyWith(size: box.biggest),
                child: Builder(builder: (c) => widget.panelBuilder(c, id)),
              ),
            ),
          ),
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
    // The same tree is always built, so maximising rebuilds nothing; while one panel fills the view the rest stays
    // mounted (and keeps its state) offstage.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: max != null,
          child: TickerMode(
            enabled: max == null,
            child: Padding(padding: const EdgeInsets.all(DockView.gap / 2), child: _node(widget.layout.root, const [])),
          ),
        ),
        if (max != null)
          Padding(
            padding: const EdgeInsets.all(DockView.gap / 2),
            child: _Group(
              tabs: TabsNode([max]),
              title: widget.titleOf,
              maximised: true,
              onActivate: (_) {},
              onMaximise: _toggleMax,
              onDrop: (_, _) {},
              accepts: (_) => false,
              body: _body(max, shown: true),
            ),
          ),
      ],
    );
  }

  Widget _node(DockNode n, List<int> path) => switch (n) {
    TabsNode t => _Group(
      tabs: t,
      title: widget.titleOf,
      maximised: false,
      onActivate: (id) => widget.onChanged(widget.layout.activate(id)),
      onMaximise: _toggleMax,
      onDrop: (id, edge) {
        // Dropping a group's own tab: aim at another tab of the group (dock refuses a panel onto itself).
        final target = t.activePanel != id ? t.activePanel : t.panels.firstWhere((p) => p != id, orElse: () => id);
        if (target != id) widget.onChanged(widget.layout.dock(id, target: target, edge: edge));
      },
      accepts: (id) => t.panels.length > 1 || t.panels.first != id,
      onFloat: widget.onFloat,
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
      children: [
        for (var i = 0; i < s.children.length; i++) _node(s.children[i], [...path, i]),
      ],
    ),
  };
}

/// Children laid out by their shares, with a divider between each pair. Each child gets at least [minExtent] pixels
/// (room for its tab strip) when there is room for that, whatever its share.
class _Split extends StatelessWidget {
  const _Split({required this.split, required this.onWeights, required this.children});

  final SplitNode split;
  final ValueChanged<List<double>> onWeights;
  final List<Widget> children;

  /// The smallest a group is drawn: its tab strip and a little body.
  static double minExtent(BuildContext context) => Targets.of(context) + 24;

  /// Pixel sizes for [weights] in [room], lifting any below [min] and taking the difference from the others in
  /// proportion; equal sizes when [room] can't fit every child at [min].
  static List<double> sizes(List<double> weights, double room, double min) {
    final n = weights.length;
    if (room <= 0) return List.filled(n, 0);
    if (room < n * min) return List.filled(n, room / n);
    var px = [for (final w in weights) w * room];
    for (var pass = 0; pass < n; pass++) {
      final low = [for (final x in px) x < min];
      if (!low.contains(true)) break;
      final need = [for (var i = 0; i < n; i++) low[i] ? min - px[i] : 0.0].fold(0.0, (a, b) => a + b);
      final spare = [for (var i = 0; i < n; i++) low[i] ? 0.0 : px[i] - min].fold(0.0, (a, b) => a + b);
      if (spare <= 0) return List.filled(n, room / n);
      px = [for (var i = 0; i < n; i++) low[i] ? min : px[i] - (px[i] - min) / spare * need];
    }
    return px;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final row = split.axis == DockAxis.row;
      final total = row ? box.maxWidth : box.maxHeight;
      final n = children.length;
      final room = (total - DockView.gap * (n - 1)).clamp(0.0, double.infinity);
      final px = sizes(split.weights, room, minExtent(context));
      const grab = DockView.gap + 2 * DockView.grabReach;
      final kids = <Widget>[];
      final dividers = <Widget>[];
      var at = 0.0;
      for (var i = 0; i < n; i++) {
        kids.add(
          Positioned(
            left: row ? at : 0,
            top: row ? 0 : at,
            width: row ? px[i] : box.maxWidth,
            height: row ? box.maxHeight : px[i],
            child: children[i],
          ),
        );
        at += px[i];
        if (i < n - 1) {
          final centre = at + DockView.gap / 2;
          dividers.add(
            Positioned(
              left: row ? centre - grab / 2 : 0,
              top: row ? 0 : centre - grab / 2,
              width: row ? grab : box.maxWidth,
              height: row ? box.maxHeight : grab,
              child: _Divider(
                axis: split.axis,
                index: i,
                weights: split.weights,
                onDrag: (start, moved) {
                  if (room <= 0) return;
                  // From the weights at the drag's start and the whole distance moved, so batched moves and moves
                  // past the minimum never put the divider out of step with the pointer.
                  final w = [...start];
                  final lo = DockLayout.minWeight - w[i], hi = w[i + 1] - DockLayout.minWeight;
                  if (lo > hi) return;
                  final d = (moved / room).clamp(lo, hi);
                  w[i] += d;
                  w[i + 1] -= d;
                  onWeights(w);
                },
              ),
            ),
          );
          at += DockView.gap;
        }
      }
      return Stack(children: [...kids, ...dividers]);
    },
  );
}

/// A divider's grab zone: a drag along the split's axis moves the boundary. Taps pass through to the panels.
class _Divider extends StatefulWidget {
  const _Divider({required this.axis, required this.index, required this.weights, required this.onDrag});

  final DockAxis axis;
  final int index;

  /// The split's current shares; the drag starts from these.
  final List<double> weights;

  /// Called with the shares at the drag's start and the distance moved since then.
  final void Function(List<double> start, double moved) onDrag;

  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> with GrabFeedback {
  List<double>? _start;
  double _moved = 0;

  @override
  Widget build(BuildContext context) {
    final row = widget.axis == DockAxis.row;
    final active = _start != null;
    void start(DragStartDetails _) {
      _start = widget.weights;
      _moved = 0;
      grab();
    }

    void update(double delta) {
      final s = _start;
      if (s == null) return;
      _moved += delta;
      widget.onDrag(s, _moved);
    }

    void end([_]) {
      if (_start == null) return;
      _start = null;
      release();
    }

    return Semantics(
      label: 'Resize panels',
      child: MouseRegion(
        cursor: row ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
        onEnter: (_) => hover(true),
        onExit: (_) => hover(false),
        child: GestureDetector(
          key: ValueKey('dock-divider-${widget.axis.name}-${widget.index}'),
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: row ? start : null,
          onHorizontalDragUpdate: row ? (d) => update(d.delta.dx) : null,
          onHorizontalDragEnd: row ? end : null,
          onHorizontalDragCancel: row ? end : null,
          onVerticalDragStart: row ? null : start,
          onVerticalDragUpdate: row ? null : (d) => update(d.delta.dy),
          onVerticalDragEnd: row ? null : end,
          onVerticalDragCancel: row ? null : end,
          // The grip grows and lights while held (and on hover with a mouse).
          child: Center(
            child: GripMark(
              axis: row ? Axis.horizontal : Axis.vertical,
              grabbed: active,
              hovered: hovered,
              length: 32,
              color: Roles.accent,
              restColor: Neon.line,
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
    required this.accepts,
    required this.body,
    this.onFloat,
  });

  final TabsNode tabs;
  final ValueChanged<String>? onFloat;
  final bool Function(String id) accepts;
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
        child: Column(
          children: [
            _TabStrip(
              tabs: widget.tabs,
              title: widget.title,
              maximised: widget.maximised,
              onActivate: widget.onActivate,
              onMaximise: widget.onMaximise,
              onFloat: widget.onFloat,
            ),
            Expanded(
              child: DragTarget<String>(
                onWillAcceptWithDetails: (d) => !widget.maximised && Panels.known(d.data) && widget.accepts(d.data),
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
                  Haptics.drop();
                  widget.onDrop(d.data, e);
                },
                builder: (context, candidates, _) => Stack(
                  key: _bodyKey,
                  fit: StackFit.expand,
                  children: [
                    widget.body,
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: candidates.isNotEmpty && _hover != null ? 1 : 0,
                        duration: Motion.fade(Motion.small, level),
                        child: _DropPreview(edge: _hover ?? DockEdge.center),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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
    this.onFloat,
  });

  final TabsNode tabs;
  final String Function(String) title;
  final bool maximised;
  final ValueChanged<String> onActivate, onMaximise;
  final ValueChanged<String>? onFloat;

  @override
  Widget build(BuildContext context) {
    final h = Targets.of(context) - 8;
    final float = onFloat;
    final shown = tabs.activePanel;
    return SizedBox(
      height: h,
      child: Row(
        children: [
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
          if (float != null && !maximised)
            IconButton(
              key: ValueKey('dock-float-${tabs.activePanel}'),
              tooltip: 'Float ${title(tabs.activePanel)} in a window',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: Neon.dim,
              icon: const Icon(Icons.picture_in_picture_alt),
              onPressed: () => float(tabs.activePanel),
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
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.id,
    required this.title,
    required this.selected,
    required this.draggable,
    required this.onTap,
  });

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
      hapticFeedbackOnStart: false,
      onDragStarted: Haptics.grab,
      feedback: Material(
        type: MaterialType.transparency,
        child: Transform.translate(
          offset: const Offset(-40, -24),
          child: GlassOverlay(
            radius: Radii.m,
            padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.s),
            child: Text(
              title,
              style: TextStyle(color: Neon.text, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: label),
      child: label,
    );
  }
}
