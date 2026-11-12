// Long-press menus (owner, 2026-11-09): a compact glass list near the finger, or a Bitwig-style ring as a setting;
// grouped into sections, numbers with a big slider, a type-in field and a reset (owner, 2026-11-11).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/settings.dart';
import '../glass.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../theme.dart';

/// One entry of a long-press menu: an icon and a short name, optionally ticked, disabled or destructive. Entries
/// with a [section] are grouped under its header in the list (the ring keeps their order); a [number] entry edits a
/// value in place instead of closing the menu.
@immutable
class MenuAction<T> {
  const MenuAction(this.value, this.label, this.icon,
      {this.enabled = true, this.danger = false, this.checked = false, this.hint, this.section, this.number});
  final T value;
  final String label;
  final IconData icon;
  final bool enabled, danger, checked;

  /// Why a disabled entry is disabled (shown under it in the list, and as the ring's tooltip).
  final String? hint;

  /// The header this entry sits under; a new header starts where it changes from the entry before.
  final String? section;

  /// A value this entry edits: a big slider, a type-in field and a reset in the list; the ring opens the same
  /// editor over itself.
  final MenuNumber? number;
}

/// A number a menu entry edits. [onChanged] follows the slider (null: only [onChangeEnd] applies it, for an edit
/// that rebuilds the project); [onChangeEnd] runs when a drag ends, a typed value is entered or reset is pressed.
@immutable
class MenuNumber {
  const MenuNumber({required this.value, required this.min, required this.max, this.defaultValue, this.onChanged,
    required this.onChangeEnd, this.format, this.parse, this.divisions});
  final double value, min, max;
  final double? defaultValue;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double> onChangeEnd;

  /// How the value reads (also what the type-in field starts with); [parse] reads a typed value back.
  final String Function(double)? format;
  final double? Function(String)? parse;
  final int? divisions;

  String show(double v) => format?.call(v) ?? (v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2));
  double? read(String text) => parse != null ? parse!(text) : double.tryParse(text.trim());
}

/// The rows a list menu is built from: section headers between entries.
List<Object> _rowsOf<T>(List<MenuAction<T>> actions) {
  final rows = <Object>[];
  String? section;
  for (final a in actions) {
    if (a.section != null && a.section != section) rows.add(a.section!);
    section = a.section;
    rows.add(a);
  }
  return rows;
}

/// Opens a menu of [actions] at [at] (a global position, usually where the finger is) and returns the chosen
/// value, or null when dismissed. [style] picks the list or the ring; a light haptic tick marks it opening.
///
/// Opened by a finger's hold ([HoldToMove.start] just before), the menu sits in the overlay rather than on a new
/// route, so the finger that is still down keeps its gesture: moving on closes the menu and moves the item (owner,
/// 2026-11-12). It looks and closes the same way: a tap outside, Esc, Back or a choice.
Future<T?> showLongPressMenu<T>(BuildContext context,
    {required Offset at, required List<MenuAction<T>> actions, LongPressMenuStyle style = LongPressMenuStyle.list,
    String? title}) {
  final held = HoldToMove._opens;
  HoldToMove._opens = false;
  if (actions.isEmpty) return Future.value(null);
  Motion.tick();
  final barrier = Colors.black.withValues(alpha: style == LongPressMenuStyle.ring ? 0.25 : 0.08);
  Widget menu() => style == LongPressMenuStyle.ring
      ? _RingMenu<T>(at: at, actions: actions, title: title)
      : _ListMenu<T>(at: at, actions: actions, title: title);
  if (held) return _showHeldMenu<T>(context, menu: menu, barrier: barrier);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close menu',
    barrierColor: barrier,
    transitionDuration: Motion.fade(Motion.small, Motion.of(context)),
    pageBuilder: (context, _, _) => _MenuClose<T>(close: (v) => Navigator.of(context).pop(v), child: menu()),
    // In and out with the theme's entrance and exit kinds; a tap outside or Esc runs the exit too.
    transitionBuilder: (context, animation, _, child) => popupTransition(context, animation, child),
  );
}

/// How a menu's entries close it with their value: its route's pop, or the held menu's own exit.
class _MenuClose<T> extends InheritedWidget {
  const _MenuClose({super.key, required this.close, required super.child});
  final void Function(T? value) close;

  static void of<T>(BuildContext context, T? value) =>
      context.dependOnInheritedWidgetOfExactType<_MenuClose<T>>()!.close(value);

  @override
  bool updateShouldNotify(_MenuClose<T> old) => false;
}

/// The held menu on screen: closes it (null), if any.
VoidCallback? _closeHeld;

/// Whether a menu opened by a hold is on screen.
bool get longPressMenuOpen => _closeHeld != null;

/// Closes the menu a hold opened, if it is still open, as if dismissed (it returns null; its exit runs with the
/// motion setting).
void closeLongPressMenu() => _closeHeld?.call();

Future<T?> _showHeldMenu<T>(BuildContext context, {required Widget Function() menu, required Color barrier}) {
  final done = Completer<T?>();
  final overlay = Overlay.of(context, rootOverlay: true);
  final route = ModalRoute.of(context);
  final key = GlobalKey<_HeldMenuState<T>>();
  late final OverlayEntry entry;
  LocalHistoryEntry? back;
  void closer() => key.currentState?.close(null);
  void closed(T? v) {
    if (done.isCompleted) return;
    entry.remove();
    entry.dispose();
    final b = back;
    back = null;
    if (b != null) route?.removeLocalHistoryEntry(b);
    if (identical(_closeHeld, closer)) _closeHeld = null;
    done.complete(v);
  }
  entry = OverlayEntry(builder: (_) => _HeldMenu<T>(key: key, barrier: barrier, onClosed: closed, child: menu()));
  // Back closes the menu first, as it would a menu's route.
  if (route != null) {
    back = LocalHistoryEntry(impliesAppBarDismissal: false, onRemove: () {
      back = null;
      key.currentState?.close(null);
    });
    route.addLocalHistoryEntry(back!);
  }
  _closeHeld = closer;
  overlay.insert(entry);
  return done.future;
}

/// A held menu over the page: a barrier that closes it on a tap, Esc to close, and the popup's way in and out.
class _HeldMenu<T> extends StatefulWidget {
  const _HeldMenu({super.key, required this.barrier, required this.onClosed, required this.child});
  final Color barrier;
  final void Function(T? value) onClosed;
  final Widget child;

  @override
  State<_HeldMenu<T>> createState() => _HeldMenuState<T>();
}

class _HeldMenuState<T> extends State<_HeldMenu<T>> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this);
  bool _closing = false;
  // The menu takes the keyboard (Esc closes it) and gives it back as it closes.
  final _focus = FocusScopeNode(debugLabel: 'held menu');
  FocusNode? _before;

  @override
  void initState() {
    super.initState();
    _before = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closing) _focus.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_in.status != AnimationStatus.dismissed || _closing) return;
    final d = Motion.fade(Motion.small, Motion.of(context));
    _in.duration = d;
    d == Duration.zero ? _in.value = 1 : _in.forward();
  }

  void close(T? value) {
    if (_closing || !mounted) return;
    _closing = true;
    final before = _before;
    if (_focus.hasFocus && before != null && before.context != null) before.requestFocus();
    final d = Motion.fade(Motion.small, Motion.of(context));
    if (d == Duration.zero) return widget.onClosed(value);
    _in.reverseDuration = d;
    _in.reverse().whenCompleteOrCancel(() => widget.onClosed(value));
  }

  @override
  void dispose() {
    _in.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MenuClose<T>(close: close, child: FocusScope(
    node: _focus,
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
        close(null);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Stack(children: [
      Positioned.fill(child: Semantics(label: 'Close menu', button: true, child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => close(null),
        child: FadeTransition(opacity: _in, child: ColoredBox(color: widget.barrier))))),
      Positioned.fill(child: IgnorePointer(ignoring: _closing, child: popupTransition(context, _in, widget.child))),
    ])));
}

/// A finger's hold on an item (owner, 2026-11-12): held still, its menu opens ([start], called as the long press
/// fires, just before the caller opens the menu, which then keeps the finger's gesture alive); moved past the touch
/// slop, the item moves instead and the menu closes. From the hold on the finger is followed here, on the pointer
/// router: [start]'s `begin` starts the move from where the hold went down, `move` follows the finger and `end`
/// drops it (true when the finger was cancelled). A mouse drags without a hold and opens the menu with a right-click.
class HoldToMove {
  /// The next menu is opened by a hold ([showLongPressMenu] reads and clears it).
  static bool _opens = false;

  int? _pointer;
  Offset _at = Offset.zero;
  bool _moving = false;
  void Function(Offset from)? _begin;
  ValueChanged<Offset>? _move;
  ValueChanged<bool>? _end;

  /// Whether a hold is being followed, and whether it has turned into a move.
  bool get holding => _pointer != null;
  bool get moving => _moving;

  void start(int pointer, Offset at, {required void Function(Offset from) begin, required ValueChanged<Offset> move,
      required ValueChanged<bool> end}) {
    stop();
    _pointer = pointer;
    _at = at;
    _moving = false;
    _begin = begin;
    _move = move;
    _end = end;
    _opens = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
  }

  void _route(PointerEvent e) {
    if (e.pointer != _pointer) return;
    if (e is PointerMoveEvent) {
      if (!_moving && (e.position - _at).distance > kTouchSlop) {
        _moving = true;
        closeLongPressMenu();
        _begin?.call(_at);
      }
      if (_moving) _move?.call(e.position);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      final moved = _moving, end = _end;
      stop();
      if (moved) end?.call(e is PointerCancelEvent);
    }
  }

  /// Stops following the finger (the item's widget went away, or the hold ended).
  void stop() {
    if (_pointer != null) GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    _pointer = null;
    _moving = false;
    _begin = null;
    _move = null;
    _end = null;
  }
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

  static const width = 248.0, row = 36.0, header = 24.0, numberRow = 104.0;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final rows = _rowsOf(actions);
    final content = rows.fold<double>(0, (h, r) => h + switch (r) {
      String _ => header,
      MenuAction<T>(number: _?) => numberRow,
      MenuAction<T> a => row + (a.hint != null && !a.enabled ? 12 : 0),
      _ => 0,
    });
    final height = math.min(screen.height - pad.vertical - 16, content + (title == null ? 0 : 28) + 12);
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
            for (final r in rows)
              if (r is String) _header(r)
              else if (r is MenuAction<T> && r.number != null)
                SizedBox(height: numberRow, child: MenuNumberEditor(label: r.label, icon: r.icon, number: r.number!,
                  enabled: r.enabled))
              else _row(context, r as MenuAction<T>),
          ]),
        ),
      )),
    ]);
  }

  Widget _header(String text) => SizedBox(height: header, child: Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Row(children: [
      Text(text.toUpperCase(), key: ValueKey('menu-section-$text'),
        style: const TextStyle(color: Neon.blue, fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
      const SizedBox(width: 6),
      Expanded(child: Container(height: 1, color: Neon.dim.withValues(alpha: 0.25))),
    ])));

  Widget _row(BuildContext context, MenuAction<T> a) {
    final color = !a.enabled ? Neon.dim.withValues(alpha: 0.6) : a.danger ? Neon.pink : Neon.text;
    return InkWell(
      onTap: a.enabled ? () => _MenuClose.of<T>(context, a.value) : null,
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

  /// A number entry: its editor over the ring; the ring closes with it.
  Future<void> _editNumber(BuildContext context, MenuAction<T> a) async {
    final close = context.getInheritedWidgetOfExactType<_MenuClose<T>>()!.close;
    await showGeneralDialog<void>(context: context, barrierDismissible: true, barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: 0.1),
      pageBuilder: (context, _, _) => Center(child: SizedBox(width: 280, height: _ListMenu.numberRow + 16,
        child: Material(type: MaterialType.transparency, child: GlassOverlay(radius: 12,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: MenuNumberEditor(label: a.label, icon: a.icon, number: a.number!))))));
    if (mounted) close(null);
  }

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
                onTap: !a.enabled ? null : a.number == null ? () => _MenuClose.of<T>(context, a.value)
                    : () => _editNumber(context, a),
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

/// A menu's number: its name and value, a big slider, a type-in field and a reset to its default.
class MenuNumberEditor extends StatefulWidget {
  const MenuNumberEditor({super.key, required this.label, required this.icon, required this.number,
    this.enabled = true});
  final String label;
  final IconData icon;
  final MenuNumber number;
  final bool enabled;

  @override
  State<MenuNumberEditor> createState() => _MenuNumberEditorState();
}

class _MenuNumberEditorState extends State<MenuNumberEditor> {
  late double _value = _clamp(widget.number.value);
  late final _text = TextEditingController(text: widget.number.show(_value));
  final _focus = FocusNode();

  MenuNumber get n => widget.number;
  double _clamp(double v) => v.isFinite ? v.clamp(n.min, n.max).toDouble() : n.min;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _set(double v, {bool end = false}) {
    v = _clamp(v);
    setState(() => _value = v);
    if (!_focus.hasFocus) _text.text = n.show(v);
    n.onChanged?.call(v);
    if (end) n.onChangeEnd(v);
  }

  void _typed(String text) {
    final v = n.read(text);
    if (v != null) _set(v, end: true);
    _text.text = n.show(_value);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.label.toLowerCase().replaceAll(' ', '-');
    final d = n.defaultValue;
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 26, child: Row(children: [
          Icon(widget.icon, size: 18, color: Neon.dim),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13))),
          // The type-in field: Enter (or leaving it) applies what was typed.
          SizedBox(width: 76, height: 26, child: TextField(
            key: ValueKey('menu-number-field-$key'),
            controller: _text, focusNode: _focus, enabled: widget.enabled,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-+0-9.,a-zA-Z ]'))],
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
            onSubmitted: _typed,
            onTapOutside: (_) { if (_focus.hasFocus) _typed(_text.text); },
          )),
          if (d != null) IconButton(key: ValueKey('menu-number-reset-$key'), tooltip: 'Reset',
            visualDensity: VisualDensity.compact, padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 26),
            onPressed: widget.enabled && _value != d ? () => _set(d, end: true) : null,
            icon: const Icon(Icons.restart_alt, size: 18)),
        ])),
        // The big slider: a thick track and a thumb a finger can find.
        SizedBox(height: 56, child: SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 10,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 13),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
            activeTrackColor: Neon.blue, thumbColor: Neon.blue,
            inactiveTrackColor: Neon.dim.withValues(alpha: 0.3)),
          child: Slider(key: ValueKey('menu-number-slider-$key'), value: _value, min: n.min, max: n.max,
            divisions: n.divisions,
            onChanged: widget.enabled ? _set : null,
            onChangeEnd: widget.enabled ? (v) => _set(v, end: true) : null))),
      ]));
  }
}
