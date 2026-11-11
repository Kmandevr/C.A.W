// Docking layout model: a tree of splits and tab groups holding panels, its edits, presets per form factor and a
// damage-tolerant JSON form. Pure Dart, with no widgets.
import 'dart:math' as math;

/// Panel ids. They are strings, not enum indexes, so a renamed or split panel (Builder becomes Code and Inspector in
/// a later step) drops out of a saved layout instead of breaking it.
class Panels {
  Panels._();
  static const arrangement = 'arrangement';
  static const builder = 'builder';
  static const files = 'files';

  /// Every panel, in the order a preset lists the ones it doesn't place on purpose: the three main sections (owner,
  /// 2026-11-09). The older workspaces (mixer, automation, export, engine lab, plugins) are gone; a saved layout that
  /// names one drops it.
  static const all = [arrangement, builder, files];

  static bool known(String id) => all.contains(id);

  /// The constant for [id] (so keys that compare by identity match after a load), or null for an unknown id.
  static String? canonical(String id) {
    final i = all.indexOf(id);
    return i < 0 ? null : all[i];
  }
}

/// Side by side ([row]) or stacked ([column]).
enum DockAxis { row, column }

/// Where a dragged panel lands relative to a target panel: in its tab group, or split beside it.
enum DockEdge { center, left, right, top, bottom }

/// The screen shapes that keep their own saved layout.
enum FormFactor { phonePortrait, phoneLandscape, desktop }

/// The starting layouts: Arrange or Code in front (the Mix preset went with the Mixer panel; Arrange's mixer
/// button shows the strips).
enum DockPreset { arrange, code }

sealed class DockNode {
  const DockNode();
}

/// One tab group: its [panels] in tab order and the [active] one shown.
class TabsNode extends DockNode {
  TabsNode(List<String> panels, [int active = 0])
      : panels = List.unmodifiable(panels),
        active = panels.isEmpty ? 0 : active.clamp(0, panels.length - 1);

  final List<String> panels;
  final int active;

  String get activePanel => panels[active];
}

/// Children laid out along [axis], each taking its share of [weights] (which sum to 1).
class SplitNode extends DockNode {
  SplitNode(this.axis, List<DockNode> children, [List<double>? weights])
      : children = List.unmodifiable(children),
        weights = List.unmodifiable(_normalise(weights ?? List.filled(children.length, 1.0), children.length));

  final DockAxis axis;
  final List<DockNode> children;
  final List<double> weights;

  static List<double> _normalise(List<double> w, int n) {
    final v = [for (var i = 0; i < n; i++) i < w.length && w[i].isFinite && w[i] > 0 ? w[i] : 1.0];
    final sum = v.fold(0.0, (a, b) => a + b);
    return [for (final x in v) x / sum];
  }
}

/// A docking layout. Every edit returns a new layout; an edit that would break an invariant (each panel at most once,
/// at least one panel) returns the same layout. The constructor enforces them on any tree: unknown and repeated ids
/// are dropped, ids become the [Panels] constants, and every split share is at least [minWeight].
class DockLayout {
  DockLayout(DockNode root)
      : root = _tidy(_clean(root, <String>{})) ?? TabsNode(const [Panels.arrangement]);

  final DockNode root;

  /// The smallest share of a split child.
  static const minWeight = 0.12;

  /// Every panel in the layout, in tree order.
  List<String> get panels => [..._panelsOf(root)];

  bool contains(String id) => panels.contains(id);

  /// The panels currently on screen: each tab group's active one.
  List<String> get visible => [..._visibleOf(root)];

  /// Shows [id] in its tab group.
  DockLayout activate(String id) => DockLayout(_map(root, (t) {
        final i = t.panels.indexOf(id);
        return i < 0 ? t : TabsNode(t.panels, i);
      }));

  /// Takes [id] out. Empty tab groups disappear and one-child splits collapse. The last panel can't be removed.
  DockLayout remove(String id) {
    if (!contains(id) || panels.length == 1) return this;
    return DockLayout(_without(root, id) ?? root);
  }

  /// Moves [id] next to [target]: into its tab group ([DockEdge.center]) or into a new group split off on [edge].
  /// [id] may be new to the layout (an unknown id is refused).
  DockLayout dock(String id, {required String target, DockEdge edge = DockEdge.center}) {
    if (!Panels.known(id) || !contains(target)) return this;
    if (id == target) return this;
    final base = contains(id) ? DockLayout(_without(root, id) ?? root) : this;
    if (!base.contains(target)) return this;
    return DockLayout(_place(base.root, id, target, edge));
  }

  /// Shows [id]: activates it where it is, or adds it to the main tab group (the first group without the
  /// arrangement, or the arrangement's when there is no other) and activates it there.
  DockLayout reveal(String id) {
    if (!Panels.known(id)) return this;
    if (contains(id)) return activate(id);
    final groups = _tabsOf(root).toList();
    final main = groups.firstWhere((t) => !t.panels.contains(Panels.arrangement), orElse: () => groups.first);
    return dock(id, target: main.panels.first).activate(id);
  }

  /// Sets the shares of the split at [path] (child indexes from the root), keeping each at least [minWeight].
  DockLayout setWeights(List<int> path, List<double> weights) {
    final node = nodeAt(path);
    if (node is! SplitNode || weights.length != node.children.length) return this;
    final clamped = _clampWeights(weights);
    return DockLayout(_replaceAt(root, path, SplitNode(node.axis, node.children, clamped)));
  }

  /// The node at [path], or null when the path doesn't lead anywhere.
  DockNode? nodeAt(List<int> path) {
    DockNode n = root;
    for (final i in path) {
      if (n is! SplitNode || i < 0 || i >= n.children.length) return null;
      n = n.children[i];
    }
    return n;
  }

  // ---------- presets ----------

  /// A starting layout for [form]: [preset]'s main panel large, every other panel as tabs in a second group.
  static DockLayout preset(FormFactor form, [DockPreset preset = DockPreset.arrange]) {
    final main = switch (preset) {
      DockPreset.arrange => const [Panels.arrangement],
      DockPreset.code => const [Panels.builder],
    };
    final rest = [for (final p in Panels.all) if (!main.contains(p)) p];
    final axis = form == FormFactor.phonePortrait ? DockAxis.column : DockAxis.row;
    final share = form == FormFactor.desktop ? 0.62 : 0.55;
    return DockLayout(SplitNode(axis, [TabsNode(main), TabsNode(rest)], [share, 1 - share]));
  }

  // ---------- JSON ----------

  /// `{"tabs": [...], "active": n}` or `{"split": "row"|"column", "weights": [...], "children": [...]}`.
  Map<String, Object?> toJson() => _toJson(root);

  static Map<String, Object?> _toJson(DockNode n) => switch (n) {
        TabsNode t => {'tabs': t.panels, 'active': t.active},
        SplitNode s => {
            'split': s.axis.name,
            'weights': [for (final w in s.weights) double.parse(w.toStringAsFixed(4))],
            'children': [for (final c in s.children) _toJson(c)],
          },
      };

  /// Reads a saved layout. Unknown and repeated panel ids are dropped, and damaged parts are skipped; null when
  /// nothing usable is left, so the caller falls back to a preset.
  static DockLayout? fromJson(Object? json) {
    final seen = <String>{};
    final node = _fromJson(json, seen, 0);
    final tidy = node == null ? null : _tidy(node);
    return tidy == null ? null : DockLayout(tidy);
  }

  static DockNode? _fromJson(Object? j, Set<String> seen, int depth) {
    if (j is! Map || depth > 16) return null;
    final tabs = j['tabs'];
    if (tabs is List) {
      final ids = <String>[];
      for (final p in tabs) {
        if (p is String && Panels.known(p) && seen.add(p)) ids.add(Panels.canonical(p)!);
      }
      if (ids.isEmpty) return null;
      // The active index is into the saved list; find the same panel among those kept.
      final a = j['active'];
      final activeId = a is int && a >= 0 && a < tabs.length ? tabs[a] : null;
      return TabsNode(ids, activeId is String ? math.max(0, ids.indexOf(activeId)) : 0);
    }
    final axis = DockAxis.values.where((a) => a.name == j['split']).firstOrNull;
    final kids = j['children'];
    if (axis == null || kids is! List) return null;
    final rawW = j['weights'] is List ? j['weights'] as List : const [];
    final children = <DockNode>[], weights = <double>[];
    for (var i = 0; i < kids.length; i++) {
      final c = _fromJson(kids[i], seen, depth + 1);
      if (c == null) continue;
      children.add(c);
      final w = i < rawW.length ? rawW[i] : null;
      weights.add(w is num ? w.toDouble() : 1.0);
    }
    if (children.isEmpty) return null;
    return SplitNode(axis, children, weights);
  }

  // ---------- tree helpers ----------

  /// [n] with unknown and repeated ids dropped and the rest replaced by their [Panels] constants.
  static DockNode _clean(DockNode n, Set<String> seen) => switch (n) {
        TabsNode t => () {
            final ids = [
              for (final p in t.panels)
                if (Panels.known(p) && seen.add(p)) Panels.canonical(p)!,
            ];
            final kept = ids.indexOf(t.panels.isEmpty ? '' : t.activePanel);
            return TabsNode(ids, kept < 0 ? 0 : kept);
          }(),
        SplitNode s => SplitNode(s.axis, [for (final c in s.children) _clean(c, seen)], s.weights),
      };

  static Iterable<String> _panelsOf(DockNode n) sync* {
    switch (n) {
      case TabsNode t:
        yield* t.panels;
      case SplitNode s:
        for (final c in s.children) {
          yield* _panelsOf(c);
        }
    }
  }

  static Iterable<String> _visibleOf(DockNode n) sync* {
    switch (n) {
      case TabsNode t:
        yield t.activePanel;
      case SplitNode s:
        for (final c in s.children) {
          yield* _visibleOf(c);
        }
    }
  }

  static Iterable<TabsNode> _tabsOf(DockNode n) sync* {
    switch (n) {
      case TabsNode t:
        yield t;
      case SplitNode s:
        for (final c in s.children) {
          yield* _tabsOf(c);
        }
    }
  }

  static DockNode _map(DockNode n, TabsNode Function(TabsNode) f) => switch (n) {
        TabsNode t => f(t),
        SplitNode s => SplitNode(s.axis, [for (final c in s.children) _map(c, f)], s.weights),
      };

  /// [n] without [id]; null when nothing is left.
  static DockNode? _without(DockNode n, String id) {
    switch (n) {
      case TabsNode t:
        final i = t.panels.indexOf(id);
        if (i < 0) return t;
        final rest = [...t.panels]..removeAt(i);
        if (rest.isEmpty) return null;
        // Removing a tab before or at the active one keeps the neighbour in view.
        return TabsNode(rest, t.active > i ? t.active - 1 : math.min(t.active, rest.length - 1));
      case SplitNode s:
        final kids = <DockNode>[], w = <double>[];
        for (var i = 0; i < s.children.length; i++) {
          final c = _without(s.children[i], id);
          if (c != null) {
            kids.add(c);
            w.add(s.weights[i]);
          }
        }
        if (kids.isEmpty) return null;
        return SplitNode(s.axis, kids, w);
    }
  }

  static DockNode _place(DockNode n, String id, String target, DockEdge edge) {
    switch (n) {
      case TabsNode t:
        if (!t.panels.contains(target)) return t;
        if (edge == DockEdge.center) {
          final at = t.panels.indexOf(target) + 1;
          final ids = [...t.panels]..insert(at, id);
          return TabsNode(ids, at);
        }
        final axis = edge == DockEdge.left || edge == DockEdge.right ? DockAxis.row : DockAxis.column;
        final first = edge == DockEdge.left || edge == DockEdge.top;
        final fresh = TabsNode([id]);
        return SplitNode(axis, first ? [fresh, t] : [t, fresh]);
      case SplitNode s:
        final kids = <DockNode>[], w = <double>[];
        for (var i = 0; i < s.children.length; i++) {
          final c = _place(s.children[i], id, target, edge);
          // A new split along this split's own axis joins it as siblings, sharing the target's share.
          if (c is SplitNode && c.axis == s.axis && s.children[i] is TabsNode && c.children.length == 2) {
            kids.addAll(c.children);
            w.addAll([s.weights[i] / 2, s.weights[i] / 2]);
          } else {
            kids.add(c);
            w.add(s.weights[i]);
          }
        }
        return SplitNode(s.axis, kids, w);
    }
  }

  static DockNode _replaceAt(DockNode n, List<int> path, DockNode with_) {
    if (path.isEmpty) return with_;
    final s = n as SplitNode;
    final kids = [...s.children];
    kids[path.first] = _replaceAt(kids[path.first], path.sublist(1), with_);
    return SplitNode(s.axis, kids, s.weights);
  }

  /// Collapses one-child splits, merges a split's same-axis child splits into it and lifts shares below
  /// [minWeight]; null for an empty tree.
  static DockNode? _tidy(DockNode n) {
    switch (n) {
      case TabsNode t:
        return t.panels.isEmpty ? null : t;
      case SplitNode s:
        final kids = <DockNode>[], w = <double>[];
        for (var i = 0; i < s.children.length; i++) {
          final c = _tidy(s.children[i]);
          if (c == null) continue;
          if (c is SplitNode && c.axis == s.axis) {
            for (var k = 0; k < c.children.length; k++) {
              kids.add(c.children[k]);
              w.add(s.weights[i] * c.weights[k]);
            }
          } else {
            kids.add(c);
            w.add(s.weights[i]);
          }
        }
        if (kids.isEmpty) return null;
        if (kids.length == 1) return kids.first;
        return SplitNode(s.axis, kids, _clampWeights(w));
    }
  }

  static List<double> _clampWeights(List<double> raw) {
    final n = raw.length;
    final v = [for (final x in raw) x.isFinite && x > 0 ? x : minWeight];
    final sum = v.fold(0.0, (a, b) => a + b);
    var w = [for (final x in v) x / sum];
    // Lift any share below the minimum and take the difference from the others in proportion.
    for (var pass = 0; pass < n; pass++) {
      final low = [for (var i = 0; i < n; i++) w[i] < minWeight];
      if (!low.contains(true)) break;
      final need = [for (var i = 0; i < n; i++) low[i] ? minWeight - w[i] : 0.0].fold(0.0, (a, b) => a + b);
      final spare = [for (var i = 0; i < n; i++) low[i] ? 0.0 : w[i] - minWeight].fold(0.0, (a, b) => a + b);
      if (spare <= 0) return List.filled(n, 1 / n);
      w = [for (var i = 0; i < n; i++) low[i] ? minWeight : w[i] - (w[i] - minWeight) / spare * need];
    }
    return w;
  }
}
