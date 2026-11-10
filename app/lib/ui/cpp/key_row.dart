// The symbol key row above the soft keyboard: a trackpad cursor key, code symbols with held variants, undo/redo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';

/// What the key row edits (the C++ editor's controller; a fake in tests).
abstract class CodeKeyTarget {
  void insert(String text);
  void indent();
  /// Moves the cursor [columns] right (negative: left) and [lines] down (negative: up); with [select] it extends
  /// the selection instead.
  void moveCursor({int columns = 0, int lines = 0, bool select = false});
  void undo();
  void redo();
  bool get canUndo;
  bool get canRedo;
}

/// A key: what it types, and what holding it offers.
class _Key {
  const _Key(this.label, {String? text, this.variants = const []}) : text = text ?? label;
  final String label, text;
  final List<String> variants;
}

const _page1 = [
  _Key('{', variants: ['{}', '}']),
  _Key('}'),
  _Key('(', variants: ['()', ')']),
  _Key(')'),
  _Key(';'),
  _Key('=', variants: ['==', '!=', '+=', '-=']),
  _Key('<', variants: ['<=', '<<', '->']),
  _Key('>', variants: ['>=', '>>']),
  _Key('"', variants: ['""', "'"]),
];

const _page2 = [
  _Key('::'),
  _Key('&', variants: ['&&', '&=']),
  _Key('*', variants: ['*=']),
  _Key('[', variants: ['[]', ']']),
  _Key(']'),
  _Key('+', variants: ['++', '+=']),
  _Key('-', variants: ['--', '-=']),
  _Key('/', variants: ['//', '/=']),
  _Key('%'),
  _Key('!', variants: ['!=']),
];

/// One row (about 40 dp) that swipes to a second page. The ⌖ key moves the cursor like a trackpad: drag sideways
/// for columns, up and down for lines; hold, then drag, to select. Holding a symbol shows its variants.
class CodeKeyRow extends StatefulWidget {
  const CodeKeyRow({super.key, required this.target, this.onChanged});

  final CodeKeyTarget target;
  /// After any key: the editor refreshes undo/redo and completion.
  final VoidCallback? onChanged;

  static const height = 40.0;

  /// How many times the row has shown its hint this run: the first [hintTimes] showings explain the hidden moves.
  static int hintsShown = 0;
  static const hintTimes = 2;

  @override
  State<CodeKeyRow> createState() => _CodeKeyRowState();
}

class _CodeKeyRowState extends State<CodeKeyRow> {
  final _pages = PageController();
  int _page = 0;
  OverlayEntry? _variants;

  /// The hint over the row (hold for more, swipe for more, drag ⌖), for a few seconds on its first showings.
  bool _hint = false;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    if (CodeKeyRow.hintsShown < CodeKeyRow.hintTimes) {
      CodeKeyRow.hintsShown++;
      _hint = true;
      _hintTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _hint = false);
      });
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _variants?.remove();
    _pages.dispose();
    super.dispose();
  }

  void _type(String text) {
    Haptics.tap();
    widget.target.insert(text);
    widget.onChanged?.call();
    setState(() {});
  }

  void _showVariants(BuildContext keyContext, _Key key) {
    if (key.variants.isEmpty) return;
    if (Motion.haptics) HapticFeedback.selectionClick();
    _variants?.remove();
    final box = keyContext.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset.zero);
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(builder: (c) {
      final width = 44.0 * key.variants.length;
      final screen = MediaQuery.sizeOf(c).width;
      return Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closeVariants)),
        Positioned(
          left: (at.dx + box.size.width / 2 - width / 2).clamp(4.0, screen - width - 4),
          top: at.dy - 46,
          child: Material(
            color: Neon.panelHi,
            borderRadius: BorderRadius.circular(8),
            elevation: 6,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final v in key.variants)
                InkWell(
                  key: ValueKey('variant $v'),
                  onTap: () {
                    _closeVariants();
                    _type(v);
                  },
                  child: SizedBox(
                      width: 44, height: 40, child: Center(child: Text(v, style: Neon.code(size: 14, color: Neon.text)))),
                ),
            ]),
          ),
        ),
      ]);
    });
    _variants = entry;
    overlay.insert(entry);
  }

  void _closeVariants() {
    _variants?.remove();
    _variants = null;
  }

  Widget _symbol(_Key key) => Expanded(
        child: Builder(
          builder: (c) => InkWell(
            key: ValueKey('key ${key.label}'),
            onTap: () => _type(key.text),
            onLongPress: key.variants.isEmpty ? null : () => _showVariants(c, key),
            child: SizedBox(
              height: CodeKeyRow.height,
              child: Center(child: Text(key.label, style: Neon.code(size: 15, color: Neon.text))),
            ),
          ),
        ),
      );

  Widget _icon(String id, IconData icon, VoidCallback? onTap, {String? tip}) => SizedBox(
        width: 40,
        height: CodeKeyRow.height,
        child: IconButton(
          key: ValueKey(id),
          tooltip: tip,
          padding: EdgeInsets.zero,
          iconSize: 18,
          onPressed: onTap,
          icon: Icon(icon, color: onTap == null ? Neon.dim.withValues(alpha: 0.4) : Neon.text),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    Widget page(List<_Key> keys, {bool tab = false}) => Row(children: [
          if (tab)
            Expanded(
              child: InkWell(
                key: const ValueKey('key tab'),
                onTap: () {
                  t.indent();
                  widget.onChanged?.call();
                },
                child: SizedBox(height: CodeKeyRow.height, child: Center(child: Text('⇥', style: Neon.code(size: 15)))),
              ),
            ),
          for (final k in keys) _symbol(k),
        ]);
    final row = Container(
      height: CodeKeyRow.height,
      decoration: BoxDecoration(color: Neon.panel, border: Border(top: BorderSide(color: Neon.line))),
      child: Row(children: [
        CursorKey(target: t, onMoved: widget.onChanged),
        Expanded(
          child: PageView(
            controller: _pages,
            onPageChanged: (p) => setState(() => _page = p),
            children: [page(_page1, tab: true), page(_page2)],
          ),
        ),
        // Which page: two dots, tap to flip.
        GestureDetector(
          onTap: () => _pages.animateToPage(1 - _page, duration: const Duration(milliseconds: 180), curve: Curves.easeOut),
          child: SizedBox(
            width: 10,
            height: CodeKeyRow.height,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < 2; i++)
                Container(
                  width: 4,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: i == _page ? Neon.text : Neon.dim.withValues(alpha: 0.5)),
                ),
            ]),
          ),
        ),
        _icon('key undo', Icons.undo, t.canUndo ? () { t.undo(); widget.onChanged?.call(); setState(() {}); } : null, tip: 'Undo'),
        _icon('key redo', Icons.redo, t.canRedo ? () { t.redo(); widget.onChanged?.call(); setState(() {}); } : null, tip: 'Redo'),
      ]),
    );
    return Stack(clipBehavior: Clip.none, children: [
      row,
      // Above the row, over the code: what is not visible on the keys themselves.
      Positioned(
        left: 0,
        right: 0,
        top: -26,
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _hint ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: Center(
              child: Container(
                key: const ValueKey('key row hint'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Neon.panelHi.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Neon.blue.withValues(alpha: 0.4)),
                ),
                child: Text('Hold a key for more · swipe for :: & * [ ] · drag ⌖ to move',
                    style: Neon.code(size: 10.5, color: Neon.text)),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// The ⌖ key: a small trackpad. Every [columnStep] dp sideways is one column, every [lineStep] dp up or down one
/// line. Hold it first (a tick), then drag, to select.
class CursorKey extends StatefulWidget {
  const CursorKey({super.key, required this.target, this.onMoved});

  final CodeKeyTarget target;
  final VoidCallback? onMoved;

  static const columnStep = 9.0, lineStep = 16.0;

  @override
  State<CursorKey> createState() => _CursorKeyState();
}

class _CursorKeyState extends State<CursorKey> {
  double _dx = 0, _dy = 0;
  bool _selecting = false;
  bool _active = false;

  void _drag(Offset delta) {
    _dx += delta.dx;
    _dy += delta.dy;
    final columns = (_dx / CursorKey.columnStep).truncate();
    final lines = (_dy / CursorKey.lineStep).truncate();
    if (columns == 0 && lines == 0) return;
    _dx -= columns * CursorKey.columnStep;
    _dy -= lines * CursorKey.lineStep;
    widget.target.moveCursor(columns: columns, lines: lines, select: _selecting);
    widget.onMoved?.call();
  }

  void _end() => setState(() {
        _dx = _dy = 0;
        _selecting = false;
        _active = false;
      });

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: const ValueKey('cursor key'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _active = true),
        onPanUpdate: (d) => _drag(d.delta),
        onPanEnd: (_) => _end(),
        onPanCancel: _end,
        onLongPressStart: (_) {
          if (Motion.haptics) HapticFeedback.selectionClick();
          setState(() {
            _selecting = true;
            _active = true;
          });
        },
        onLongPressMoveUpdate: (d) {
          _drag(d.offsetFromOrigin - _lastLong);
          _lastLong = d.offsetFromOrigin;
        },
        onLongPressEnd: (_) {
          _lastLong = Offset.zero;
          _end();
        },
        child: Container(
          width: 46,
          height: CodeKeyRow.height,
          color: _active ? (_selecting ? Neon.blue.withValues(alpha: 0.25) : Neon.line) : Colors.transparent,
          child: Center(child: Icon(Icons.control_camera, size: 20, color: _selecting ? Neon.blue : Neon.text)),
        ),
      );

  // Long-press drags report the distance from the press; this is the part already applied.
  Offset _lastLong = Offset.zero;
}
