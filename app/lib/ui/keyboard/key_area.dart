// Keyboard focus areas: a part of a screen with its own key context (FX chain, mixer, Files...), and moving the
// focus between the controls inside one in reading order or by direction.
import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../actions/key_event.dart';
import '../../actions/keymap.dart';
import '../../actions/keys.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

/// Runs one of an area's actions; false when it doesn't do that one (the generic moves then try it).
typedef KeyAreaAction = bool Function(String id, int count, String? arg);

/// Where an area's controls are, for [KeyArea]'s generic moves and the router's Tab order.
enum KeyMove { up, down, left, right, prev, next }

/// Finds the [KeyRouter]-like owner an area registers with, without importing it (the router sets it).
abstract class KeyAreaHost {
  void register(Area area, FocusNode focus, bool Function(String id, int count, String? arg) run);
  void unregister(Area area, FocusNode focus);

  /// The host in force (the app's key router); null in tests that build a screen alone.
  static KeyAreaHost? current;

  /// True once a hardware key was pressed (or on a desktop): the key hint strip's default.
  static final ValueNotifier<bool> keyboardSeen = ValueNotifier(false);

  /// Whether the hint strip shows: Settings' choice, else whether a keyboard is in use.
  static bool hintsOn(bool? setting) => setting ?? keyboardSeen.value;
}

/// A part of the screen with its own key context: while the keyboard focus is inside it, the keys of [area] (and the
/// global ones it doesn't override) run, [onAction] first and then the generic moves (`*.up`, `*.down`, `*.left`,
/// `*.right`, `*.prev`, `*.next` move between its controls; `*.activate` and `*.toggle` press the focused one).
/// Tab and Shift+Tab move between the areas on screen in reading order, Enter goes in, Esc comes back out. The
/// area is a semantics container named [label].
class KeyArea extends StatefulWidget {
  const KeyArea({
    super.key,
    required this.area,
    required this.label,
    required this.child,
    this.onAction,
    this.focusNode,
    this.autofocus = false,
  });

  final Area area;
  final String label;
  final Widget child;
  final KeyAreaAction? onAction;

  /// The area's own node (a screen that wants to know when it has the focus); one is made otherwise.
  final FocusNode? focusNode;
  final bool autofocus;

  static final Map<FocusNode, KeyAreaState> _byNode = {};

  /// The area whose node is [node].
  static KeyAreaState? ofNode(FocusNode? node) => node == null ? null : _byNode[node];

  /// The innermost area holding [node] (the node itself, or one of its ancestors).
  static KeyAreaState? around(FocusNode? node) {
    for (var n = node; n != null; n = n.parent) {
      final a = _byNode[n];
      if (a != null) return a;
    }
    return null;
  }

  /// The area the keyboard focus is in, or null.
  static KeyAreaState? get focused => around(FocusManager.instance.primaryFocus);

  @override
  State<KeyArea> createState() => KeyAreaState();
}

class KeyAreaState extends State<KeyArea> {
  FocusNode? _own;
  FocusNode get node => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'key-area ${widget.label}'));
  KeyAreaHost? _host;
  FocusNode? _registered;
  Area? _registeredArea;

  Area get area => widget.area;
  String get label => widget.label;

  /// The area that holds this one, if any.
  KeyAreaState? get parent => KeyArea.around(node.parent);

  @override
  void initState() {
    super.initState();
    KeyArea._byNode[node] = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(KeyArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      KeyArea._byNode.remove(oldWidget.focusNode ?? _own);
      KeyArea._byNode[node] = this;
    }
    _attach();
  }

  void _attach() {
    final host = KeyAreaHost.current;
    if (host == _host && _registered == node && _registeredArea == area) return;
    if (_registered != null) _host?.unregister(_registeredArea!, _registered!);
    _host = host;
    _registered = node;
    _registeredArea = area;
    host?.register(area, node, run);
  }

  @override
  void dispose() {
    if (_registered != null) _host?.unregister(_registeredArea!, _registered!);
    KeyArea._byNode.remove(node);
    _own?.dispose();
    super.dispose();
  }

  /// Runs [id] for this area: the screen's own handler first, then the generic moves.
  bool run(String id, int count, String? arg) {
    if (widget.onAction?.call(id, count, arg) ?? false) return true;
    // A screen's own area (the Build editor) has no generic moves: its actions are its screen's. The moves are the
    // area's own actions only (not the global focus.next, say).
    if (!area.navigates || _registry.lookup(id)?.area != area) return false;
    final dot = id.lastIndexOf('.');
    final verb = dot < 0 ? id : id.substring(dot + 1);
    final move = switch (verb) {
      'up' => KeyMove.up,
      'down' => KeyMove.down,
      'left' => KeyMove.left,
      'right' => KeyMove.right,
      'prev' => KeyMove.prev,
      'next' => KeyMove.next,
      _ => null,
    };
    if (move != null) {
      for (var i = 0; i < count; i++) {
        if (!moveFocusIn(node, move)) return i > 0;
      }
      return true;
    }
    if (verb == 'activate' || verb == 'toggle') return activateFocused();
    return false;
  }

  static Keymap? _defaults;
  static final ActionRegistry _registry = ActionRegistry.standard();

  // With no key router above (a screen shown alone), the area's own default keys still work.
  KeyEventResult _alone(KeyEvent e) {
    // Typing in a text field inside the area is the field's (the music video's Text tab), not the area's keys.
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    final chord = keyChordFromEvent(e);
    if (chord == null) return KeyEventResult.ignored;
    final km = _defaults ??= Keymap.defaults(_registry);
    final ref = km.bindingsIn(area)[KeySeq.one(chord)];
    if (ref == null || ref.isMacro) return KeyEventResult.ignored;
    return run(ref.id, 1, null) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Focuses the area's first control (Enter on the area); false when it has none.
  bool enter() => moveFocusIn(node, KeyMove.next);

  /// Whether the focus is on a control inside the area rather than on the area itself.
  bool get controlFocused {
    final p = FocusManager.instance.primaryFocus;
    return p != null && p != node && KeyArea.around(p) == this;
  }

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        explicitChildNodes: true,
        label: widget.label,
        child: Focus(
          focusNode: node,
          autofocus: widget.autofocus,
          onKeyEvent: _host == null ? (_, e) => _alone(e) : null,
          child: FocusTraversalGroup(child: widget.child),
        ),
      );
}

/// The controls inside [scope] that take the keyboard focus, in reading order (rows top to bottom, each left to
/// right): on screen, with a size, not skipped by traversal.
List<FocusNode> keyItems(FocusNode scope) {
  final out = <FocusNode>[];
  for (final n in scope.traversalDescendants) {
    if (n == scope || !n.canRequestFocus || n.skipTraversal || n is FocusScopeNode) continue;
    final ctx = n.context;
    if (ctx == null || !ctx.mounted) continue;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) continue;
    // A control inside a nested area belongs to that area: the outer one steps onto the area itself.
    final inner = KeyArea.around(n.parent);
    if (inner != null && inner.node != scope && _isUnder(inner.node, scope)) {
      if (!out.contains(inner.node)) out.add(inner.node);
      continue;
    }
    out.add(n);
  }
  return readingOrder(out);
}

bool _isUnder(FocusNode n, FocusNode scope) {
  for (var p = n.parent; p != null; p = p.parent) {
    if (p == scope) return true;
  }
  return false;
}

/// Sorts [nodes] into reading order: rows (nodes whose vertical middles lie within each other's height) top to
/// bottom, each row left to right.
List<FocusNode> readingOrder(List<FocusNode> nodes) {
  final rects = {for (final n in nodes) n: n.rect};
  final byTop = [...nodes]..sort((a, b) => rects[a]!.top.compareTo(rects[b]!.top));
  final rows = <List<FocusNode>>[];
  for (final n in byTop) {
    final r = rects[n]!;
    final row = rows.isEmpty ? null : rows.last;
    if (row != null) {
      final first = rects[row.first]!;
      if (r.center.dy >= first.top && r.center.dy <= first.bottom) {
        row.add(n);
        continue;
      }
    }
    rows.add([n]);
  }
  return [
    for (final row in rows) ...(row..sort((a, b) => rects[a]!.left.compareTo(rects[b]!.left))),
  ];
}

/// Moves the keyboard focus inside [scope] one step [move]: up and down to the nearest control above or below,
/// left and right to the nearest beside (prev and next: in reading order). From the area itself (nothing inside
/// focused yet) it lands on the first control (the last for up, left and prev). False when there is nowhere to go.
bool moveFocusIn(FocusNode scope, KeyMove move) {
  final items = keyItems(scope);
  if (items.isEmpty) return false;
  final cur = FocusManager.instance.primaryFocus;
  final i = cur == null ? -1 : items.indexOf(cur);
  FocusNode? to;
  final back = move == KeyMove.up || move == KeyMove.left || move == KeyMove.prev;
  if (i < 0) {
    to = back ? items.last : items.first;
  } else if (move == KeyMove.prev || move == KeyMove.next) {
    final j = i + (back ? -1 : 1);
    if (j >= 0 && j < items.length) to = items[j];
  } else {
    to = _nearest(items[i], items, move);
  }
  if (to == null) return false;
  focusAndReveal(to);
  return true;
}

FocusNode? _nearest(FocusNode from, List<FocusNode> items, KeyMove move) {
  final f = from.rect;
  FocusNode? best;
  var bestScore = double.infinity;
  for (final n in items) {
    if (n == from) continue;
    final r = n.rect;
    final double along, across;
    switch (move) {
      case KeyMove.up:
        if (r.center.dy >= f.center.dy - 1 || r.bottom > f.bottom) continue;
        along = f.top - r.bottom;
        across = _gap(r.left, r.right, f.left, f.right);
      case KeyMove.down:
        if (r.center.dy <= f.center.dy + 1 || r.top < f.top) continue;
        along = r.top - f.bottom;
        across = _gap(r.left, r.right, f.left, f.right);
      case KeyMove.left:
        if (r.center.dx >= f.center.dx - 1 || r.right > f.right) continue;
        along = f.left - r.right;
        across = _gap(r.top, r.bottom, f.top, f.bottom);
      case KeyMove.right:
        if (r.center.dx <= f.center.dx + 1 || r.left < f.left) continue;
        along = r.left - f.right;
        across = _gap(r.top, r.bottom, f.top, f.bottom);
      case KeyMove.prev || KeyMove.next:
        continue;
    }
    // Lined up first (no gap across), then the closest along the way.
    final score = across * 4 + along.clamp(0, double.infinity);
    if (score < bestScore) {
      bestScore = score;
      best = n;
    }
  }
  return best;
}

/// How far apart two spans are (0 when they overlap).
double _gap(double a0, double a1, double b0, double b1) => a1 < b0 ? b0 - a1 : (b1 < a0 ? a0 - b1 : 0);

/// Focuses [node] and scrolls it into view, at the theme's pace (instantly with motion Off).
void focusAndReveal(FocusNode node) {
  node.requestFocus();
  final ctx = node.context;
  if (ctx == null || !ctx.mounted || Scrollable.maybeOf(ctx) == null) return;
  final d = Motion.fade(Motion.standard, Motion.of(ctx));
  Scrollable.ensureVisible(ctx, duration: d, curve: EditMotion.curve,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
  Scrollable.ensureVisible(ctx, duration: d, curve: EditMotion.curve,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
}

/// Presses the focused control as Enter or Space would ([ActivateIntent]); false when it takes no press.
bool activateFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null || !ctx.mounted) return false;
  final action = Actions.maybeFind<ActivateIntent>(ctx);
  if (action == null || !action.isEnabled(const ActivateIntent())) return false;
  Actions.invoke(ctx, const ActivateIntent());
  return true;
}

/// The first widget of type [T] at or under [context], or null (a focused row's switch).
T? findWidgetUnder<T extends Widget>(BuildContext context) {
  if (context.widget is T) return context.widget as T;
  T? found;
  void visit(Element e) {
    if (found != null) return;
    if (e.widget is T) {
      found = e.widget as T;
      return;
    }
    e.visitChildren(visit);
  }
  context.visitChildElements(visit);
  return found;
}

/// The text a focused item shows, for menus' type-ahead: its first [Text] or [RichText], or its semantics label.
String? itemText(BuildContext context) {
  String? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Icon) return; // a glyph, not words
    if (w is Text) {
      found = w.data ?? w.textSpan?.toPlainText();
    } else if (w is RichText) {
      found = w.text.toPlainText();
    } else if (w is Tooltip && w.message != null && w.message!.isNotEmpty) {
      found = w.message;
    }
    if (found != null && found!.trim().isEmpty) found = null;
    if (found == null) e.visitChildren(visit);
  }
  if (context is Element) visit(context);
  return found?.trim();
}

/// Whether [node]'s widget is on screen in front: mounted, laid out, on the route in front, and not in a part of the
/// screen that is asleep or hidden (a section behind: its [TickerMode] is off; an [Offstage]).
bool isShownNode(FocusNode node) {
  final ctx = node.context;
  if (ctx == null || !ctx.mounted || !node.canRequestFocus) return false;
  final box = ctx.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return false;
  if (!(ModalRoute.of(ctx)?.isCurrent ?? true)) return false;
  var shown = true;
  ctx.visitAncestorElements((e) {
    final w = e.widget;
    if ((w is TickerMode && !w.enabled) || (w is Offstage && w.offstage)) shown = false;
    return shown;
  });
  return shown;
}

/// How deep [node] sits in the focus tree (the root is 0).
int focusDepth(FocusNode node) {
  var d = 0;
  for (var n = node.parent; n != null; n = n.parent) {
    d++;
  }
  return d;
}

/// The focus scope of [route] (a menu, sheet or dialog), or null before it is built.
FocusScopeNode? routeScope(ModalRoute<dynamic> route) {
  final ctx = route.subtreeContext;
  return ctx == null || !ctx.mounted ? null : FocusScope.of(ctx);
}

/// The focus ring drawn on an item a screen selects with the keyboard itself (the FX chain's effect, the mixer's
/// strip), where the item is not a focus node of its own.
class KeyRingBox extends StatelessWidget {
  const KeyRingBox({super.key, required this.child, this.label});
  final Widget child;

  /// A small tag above the ring (the mixer's control: "Pan +0.20").
  final String? label;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('key-ring-box'),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(KeyRing.radius + KeyRing.gap),
          border: Border.all(color: KeyRing.color, width: KeyRing.width),
          boxShadow: [BoxShadow(color: KeyRing.accent.withValues(alpha: 0.45), blurRadius: 6)],
        ),
        child: label == null
            ? child
            : Stack(clipBehavior: Clip.none, children: [
                child,
                Positioned(left: 2, right: 2, top: 2, child: Center(child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(color: KeyRing.accent, borderRadius: BorderRadius.circular(Radii.s)),
                  child: Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Neon.bg)),
                ))),
              ]),
      );
}

/// The first [KeyArea] at or under [context] (a part of the screen that holds one, such as the Build explorer).
KeyAreaState? keyAreaUnder(BuildContext? context) {
  if (context == null || !context.mounted) return null;
  KeyAreaState? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is KeyAreaState) {
      found = e.state as KeyAreaState;
      return;
    }
    e.visitChildren(visit);
  }
  if (context is Element) visit(context);
  return found;
}
