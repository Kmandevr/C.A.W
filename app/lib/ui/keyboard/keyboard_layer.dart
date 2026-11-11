// Around the app's navigator: keys from pages, menus and sheets in front reach the key router, menus get type-ahead,
// and the keyboard focus ring and the which-key hint strip are drawn over everything.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../actions/actions.dart';
import '../../actions/hints.dart';
import '../../actions/key_event.dart';
import '../../actions/keys.dart';
import '../../actions/vim.dart' show KeyHint;
import '../key_router.dart';
import '../motion.dart';
import '../page_closer.dart';
import '../theme.dart';
import '../tokens.dart';
import 'key_area.dart';

/// Wraps the navigator (inside [PageCloser], so Esc first goes up a level): a key a page, menu or sheet in front
/// didn't use goes to the key router; in a menu, sheet or dialog the [Area.menu] keys move, choose and close, and a
/// letter jumps to the next item that starts with what was typed. Draws the focus ring and the hint strip.
class KeyboardLayer extends StatefulWidget {
  const KeyboardLayer({super.key, required this.observer, required this.child});
  final PageCloserObserver observer;
  final Widget child;

  @override
  State<KeyboardLayer> createState() => _KeyboardLayerState();
}

class _KeyboardLayerState extends State<KeyboardLayer> {
  String _typed = '';
  Timer? _typedTimer;

  @override
  void dispose() {
    _typedTimer?.cancel();
    super.dispose();
  }

  /// The menu, sheet or dialog in front, if one is.
  ModalRoute<dynamic>? get _popup {
    final r = widget.observer.top;
    return r is PopupRoute && r.isCurrent ? r : null;
  }

  KeyEventResult _onKey(KeyEvent e) {
    final router = KeyRouterState.active.value;
    final popup = _popup;
    if (popup != null) return _menuKey(e, popup, router);
    if (router == null || router.ownsFocus) return KeyEventResult.ignored;
    return router.handle(e);
  }

  KeyEventResult _menuKey(KeyEvent e, ModalRoute<dynamic> route, KeyRouterState? router) {
    var chord = keyChordFromEvent(e);
    if (chord == null) return KeyEventResult.ignored;
    if (router != null) {
      if (!KeyAreaHost.keyboardSeen.value) KeyAreaHost.keyboardSeen.value = true;
      if (router.vimKeys) chord = vimArrowFor(chord) ?? chord;
      final ref = router.keymap.bindingsIn(Area.menu)[KeySeq.one(chord)];
      final scope = routeScope(route);
      if (scope == null) return KeyEventResult.ignored;
      switch (ref?.id) {
        case 'menu.item.up':
          moveFocusIn(scope, KeyMove.prev);
          return KeyEventResult.handled;
        case 'menu.item.down':
          moveFocusIn(scope, KeyMove.next);
          return KeyEventResult.handled;
        case 'menu.item.choose':
          return activateFocused() ? KeyEventResult.handled : KeyEventResult.ignored;
        case 'menu.item.close':
          route.navigator?.maybePop();
          return KeyEventResult.handled;
      }
    }
    final c = chord.char;
    if (c == null || c == ' ' || e is KeyRepeatEvent) return KeyEventResult.ignored;
    final scope = routeScope(route);
    if (scope == null) return KeyEventResult.ignored;
    return _typeAhead(scope, c) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Jumps to the next item whose text starts with what was typed in the last second (a repeated letter cycles).
  bool _typeAhead(FocusNode scope, String c) {
    _typedTimer?.cancel();
    _typedTimer = Timer(const Duration(seconds: 1), () => _typed = '');
    final same = _typed.isNotEmpty && _typed.split('').every((x) => x == c.toLowerCase());
    _typed = same ? c.toLowerCase() : _typed + c.toLowerCase();
    final items = keyItems(scope);
    if (items.isEmpty) return false;
    final at = items.indexOf(FocusManager.instance.primaryFocus ?? scope);
    // A new word starts at the focused item; a repeated letter (or a first one) looks past it.
    final start = _typed.length > 1 && at >= 0 ? at : at + 1;
    for (var k = 0; k < items.length; k++) {
      final n = items[(start + k) % items.length];
      final ctx = n.context;
      final text = ctx == null ? null : itemText(ctx);
      if (text != null && text.toLowerCase().startsWith(_typed)) {
        focusAndReveal(n);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, e) => _onKey(e),
        child: Stack(children: [
          widget.child,
          Positioned.fill(child: IgnorePointer(child: KeyFocusRing(menuOpen: () => _popup != null))),
        ]),
      );
}

/// The focus ring around the control (or area) with the keyboard focus, and the hint strip, while the keyboard is
/// in use (Flutter's traditional focus highlight). The ring glides to its new place at the theme's pace.
class KeyFocusRing extends StatefulWidget {
  const KeyFocusRing({super.key, required this.menuOpen});
  final bool Function() menuOpen;

  @override
  State<KeyFocusRing> createState() => _KeyFocusRingState();
}

class _KeyFocusRingState extends State<KeyFocusRing> {
  Rect? _ring, _area;
  bool _areaOnly = false;
  bool _armed = false;
  List<KeyHint> _hints = const [];
  KeyRouterState? _router;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_update);
    FocusManager.instance.addHighlightModeListener(_mode);
    KeyRouterState.active.addListener(_routerChanged);
    _routerChanged();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_update);
    FocusManager.instance.removeHighlightModeListener(_mode);
    KeyRouterState.active.removeListener(_routerChanged);
    _router?.revision.removeListener(_update);
    super.dispose();
  }

  void _routerChanged() {
    _router?.revision.removeListener(_update);
    _router = KeyRouterState.active.value;
    _router?.revision.addListener(_update);
    _update();
  }

  void _mode(FocusHighlightMode _) => _update();

  // Follows the focused control while it moves (a scroll, a strip widening): checked after each frame, which
  // costs nothing while nothing draws.
  void _update() {
    if (!mounted) return;
    final keyboard = FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final p = FocusManager.instance.primaryFocus;
    Rect? ring, area;
    var areaOnly = false;
    if (keyboard && p != null && p is! FocusScopeNode && p != _router?.rootNode &&
        (p.context?.findRenderObject()?.attached ?? false)) {
      final box = context.findRenderObject() as RenderBox?;
      final screen = box != null && box.hasSize ? Offset.zero & box.size : null;
      Rect local(Rect r) => box == null ? r : Rect.fromPoints(box.globalToLocal(r.topLeft), box.globalToLocal(r.bottomRight));
      final r = local(p.rect);
      final a = KeyArea.around(p);
      areaOnly = a != null && a.node == p;
      // A whole screen's worth isn't a control: no ring (the home screen's own node).
      if (screen != null && r.width * r.height < screen.width * screen.height * 0.85) ring = r;
      if (a != null) area = local(a.node.rect);
    }
    final r = _router;
    final hints = !keyboard || r == null || !r.hintsOn
        ? const <KeyHint>[]
        : r.hintsFor(widget.menuOpen() ? Area.menu : r.contextArea);
    if (ring != _ring || area != _area || areaOnly != _areaOnly || !_same(hints, _hints)) {
      setState(() {
        _ring = ring;
        _area = area;
        _areaOnly = areaOnly;
        _hints = hints;
      });
    }
    if (keyboard && !_armed) {
      _armed = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _armed = false;
        _update();
      });
    }
  }

  static bool _same(List<KeyHint> a, List<KeyHint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].keys != b[i].keys || a[i].label != b[i].label) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final d = Motion.fade(Motion.small, level);
    final ring = _ring;
    final area = _area;
    return LayoutBuilder(builder: (context, box) {
      final children = <Widget>[];
      if (ring != null) {
        final g = KeyRing.gap + (_areaOnly ? 0 : KeyRing.width / 2);
        children.add(AnimatedPositioned(
          key: const ValueKey('key-focus-ring'),
          duration: d,
          curve: EditMotion.curve,
          left: ring.left - g,
          top: ring.top - g,
          width: ring.width + 2 * g,
          height: ring.height + 2 * g,
          child: DecoratedBox(decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(KeyRing.radius + g),
            border: Border.all(
              color: _areaOnly ? KeyRing.accent.withValues(alpha: 0.85) : KeyRing.color,
              width: _areaOnly ? KeyRing.areaWidth : KeyRing.width),
            boxShadow: [BoxShadow(color: KeyRing.accent.withValues(alpha: _areaOnly ? 0.25 : 0.5), blurRadius: 6)],
          )),
        ));
      }
      if (_hints.isNotEmpty) {
        // At the bottom of the focused area, or of the screen above the system bars.
        final pad = MediaQuery.paddingOf(context);
        final bottom = area == null
            ? pad.bottom + 8
            : (box.maxHeight - area.bottom + 6).clamp(pad.bottom + 8, box.maxHeight - 40).toDouble();
        final left = area == null ? 8.0 : area.left.clamp(8.0, box.maxWidth - 120).toDouble();
        final width = area == null ? box.maxWidth - 16 : (area.width - 12).clamp(120.0, box.maxWidth - left - 8).toDouble();
        children.add(Positioned(
          left: left + (area == null ? 0 : 6),
          bottom: bottom,
          width: width,
          child: Align(alignment: Alignment.bottomLeft, child: KeyHintStrip(hints: _hints)),
        ));
      }
      return Stack(children: children);
    });
  }
}

/// The which-key strip: small key caps with what each does, in the device kit's look (mono keys in the accent,
/// a dark glass chip). It wraps onto a second line rather than hide keys.
class KeyHintStrip extends StatelessWidget {
  const KeyHintStrip({super.key, required this.hints});
  final List<KeyHint> hints;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: 'Keys: ${hints.map((h) => '${h.keys} ${h.label}').join(', ')}',
        excludeSemantics: true,
        child: Container(
          key: const ValueKey('key-hint-strip'),
          padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
          decoration: BoxDecoration(
            color: Neon.panelHi.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(Radii.m),
            border: Border.all(color: Neon.line),
          ),
          child: Wrap(spacing: Space.m, runSpacing: 2, children: [
            for (final h in hints)
              Text.rich(TextSpan(children: [
                TextSpan(text: h.keys, style: Neon.code(size: 11, color: KeyRing.accent).copyWith(height: 1.2)),
                TextSpan(text: ' ${h.label}', style: const TextStyle(fontSize: TypeScale.caption, color: Neon.dim)),
              ])),
          ]),
        ),
      );
}
