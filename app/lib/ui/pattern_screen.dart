// A pattern's Build tab (note clips, #158): its name and length as fields, the piano roll or the pattern text, and
// Run. It replaced the .caw module Builder (#160); C++ instruments and effects have the C++ editor.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/pattern_doc.dart';
import '../model/project.dart';
import 'code_editor.dart';
import 'frame/sections.dart';
import 'key_router.dart';
import 'pattern_editor.dart';
import 'pattern_fields.dart';
import 'theme.dart';
import 'widgets.dart';

class PatternScreen extends StatefulWidget {
  const PatternScreen({super.key, required this.state});
  final AppState state;

  @override
  State<PatternScreen> createState() => _PatternScreenState();
}

class _PatternScreenState extends State<PatternScreen> {
  /// Per pattern: true shows its text, false its piano roll.
  final Map<String, bool> _codeView = {};
  final CodeController _code = CodeController();
  final FocusNode _focus = FocusNode();
  String? _shownId;

  AppState get s => widget.state;

  KeyRouterState? _router;
  String _yank = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = KeyRouter.of(context);
    if (r == _router) return;
    _router?.unregister(Area.builder, _focus);
    _router?.unregister(Area.code, _focus);
    _router = r
      ?..register(Area.builder, _focus, _builderAction)
      ..register(Area.code, _focus, _codeAction);
  }

  ModuleDoc? get _module {
    final m = s.project.module(s.selectedModuleId);
    return m != null && s.isPattern(m.id) ? m : null;
  }

  bool _builderAction(String id, int count, String? arg) {
    final m = _module;
    final patterns = [for (final x in s.project.modules) if (s.isPattern(x.id)) x];
    void step(int d) {
      if (patterns.isEmpty) return;
      final i = patterns.indexWhere((x) => x.id == m?.id);
      final next = patterns[(i + d * count) % patterns.length];
      s.selectModule(next.id);
      SectionController.maybeOf(context)?.openBuild(BuildTab(BuildTabKind.pattern, next.id));
    }

    switch (id) {
      case 'builder.module.new':
        _newPattern();
      case 'builder.module.next':
        step(1);
      case 'builder.module.prev':
        step(-1);
      default:
        if (m == null) return false;
        switch (id) {
          case 'builder.run':
            _run(m);
          case 'builder.jumpError':
            final info = s.info[m.id];
            if (info != null && !info.ok) _showError(m, info);
          case 'builder.solo':
            s.setPreviewOnly(!s.previewOnly);
          case 'builder.module.rename':
            _rename(m);
          case 'builder.module.delete':
            _delete(m);
          case 'builder.pattern.text':
            setState(() => _codeView[m.id] = !_showingCode(m));
          default:
            return false;
        }
    }
    return true;
  }

  /// Vim editing in the code editor (Settings: "Vim keys in the code editor").
  bool _codeAction(String id, int count, String? arg) {
    final m = _module;
    if (m == null) return false;
    final t = _code.text;
    var at = _code.selection.isValid ? _code.selection.extentOffset : 0;
    int lineStart(int i) => i <= 0 ? 0 : t.lastIndexOf('\n', i - 1) + 1;
    int lineEnd(int i) {
      final e = t.indexOf('\n', i);
      return e < 0 ? t.length : e;
    }

    void go(int i) => _code.selection = TextSelection.collapsed(offset: i.clamp(0, t.length));
    void setText(String text, int cursor) {
      _code.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor.clamp(0, text.length)));
      _write(m, text);
    }

    int vertical(int i, int lines) {
      final col = i - lineStart(i);
      var ls = lineStart(i);
      for (var k = 0; k < lines.abs(); k++) {
        if (lines > 0) {
          final e = lineEnd(ls);
          if (e >= t.length) break;
          ls = e + 1;
        } else {
          if (ls == 0) break;
          ls = lineStart(ls - 1);
        }
      }
      return (ls + col).clamp(ls, lineEnd(ls));
    }

    bool word(int c) => RegExp(r'[A-Za-z0-9_]').hasMatch(String.fromCharCode(c));
    for (var k = 0; k < count; k++) {
      switch (id) {
        case 'code.vim.left':
          at = at > lineStart(at) ? at - 1 : at;
        case 'code.vim.right':
          at = at < lineEnd(at) ? at + 1 : at;
        case 'code.vim.up':
          at = vertical(at, -1);
        case 'code.vim.down':
          at = vertical(at, 1);
        case 'code.vim.halfPageUp':
          at = vertical(at, -10);
        case 'code.vim.halfPageDown':
          at = vertical(at, 10);
        case 'code.vim.lineStart':
          at = lineStart(at);
        case 'code.vim.lineEnd':
          at = lineEnd(at);
        case 'code.vim.wordForward':
          while (at < t.length && word(t.codeUnitAt(at))) {
            at++;
          }
          while (at < t.length && !word(t.codeUnitAt(at))) {
            at++;
          }
        case 'code.vim.wordBack':
          while (at > 0 && !word(t.codeUnitAt(at - 1))) {
            at--;
          }
          while (at > 0 && word(t.codeUnitAt(at - 1))) {
            at--;
          }
        default:
          k = count;
      }
    }
    switch (id) {
      case 'code.vim.left' || 'code.vim.right' || 'code.vim.up' || 'code.vim.down' || 'code.vim.halfPageUp' ||
            'code.vim.halfPageDown' || 'code.vim.lineStart' || 'code.vim.lineEnd' || 'code.vim.wordForward' ||
            'code.vim.wordBack':
        go(at);
      case 'code.vim.insert':
        break; // the action switches to insert mode
      case 'code.vim.append':
        go(at < lineEnd(at) ? at + 1 : at);
      case 'code.vim.openLine':
        final e = lineEnd(at);
        setText('${t.substring(0, e)}\n${t.substring(e)}', e + 1);
      case 'code.vim.deleteLine' || 'code.vim.yankLine':
        final ls = lineStart(at);
        var e = lineEnd(at);
        for (var k = 1; k < count && e < t.length; k++) {
          e = lineEnd(e + 1);
        }
        final end = e < t.length ? e + 1 : e;
        _yank = t.substring(ls, end);
        if (!_yank.endsWith('\n')) _yank = '$_yank\n';
        if (id == 'code.vim.deleteLine') setText(t.substring(0, ls) + t.substring(end), ls);
      case 'code.vim.paste':
        if (_yank.isEmpty) return true;
        final e = lineEnd(at);
        final pos = e < t.length ? e + 1 : e;
        final text = pos == t.length && !t.endsWith('\n') && t.isNotEmpty ? '\n$_yank' : _yank;
        setText(t.substring(0, pos) + text * count + t.substring(pos), pos);
      case 'code.vim.changeWord' || 'code.vim.changeInnerWord':
        var a = at, b = at;
        if (id == 'code.vim.changeInnerWord') {
          while (a > 0 && word(t.codeUnitAt(a - 1))) {
            a--;
          }
        }
        while (b < t.length && word(t.codeUnitAt(b))) {
          b++;
        }
        setText(t.substring(0, a) + t.substring(b), a);
        _router?.vim.mode = VimMode.insert;
      default:
        return false;
    }
    return true;
  }

  @override
  void dispose() {
    _router?.unregister(Area.builder, _focus);
    _router?.unregister(Area.code, _focus);
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A pattern opens on its notes unless its text was chosen.
  bool _showingCode(ModuleDoc m) => _codeView[m.id] ?? false;

  /// Loads the pattern's text: on a new selection, or when its source changed outside the editor (an undo). Typing
  /// writes the source straight back, so the two only differ after such a change. The header is hidden (name and
  /// length are fields above it).
  void _syncEditor(ModuleDoc? m) {
    final shown = m == null ? '' : splitPatternHeader(m.source).$2;
    if (m?.id == _shownId && _code.text == shown) return;
    _shownId = m?.id;
    _code.text = shown;
  }

  /// The editor's text back into the pattern, under its header (a new one for a blank pattern).
  void _write(ModuleDoc m, String text) => s.editSource(m.id, joinPatternHeader(m.source, text, m.name));

  /// Lines the editor doesn't show above its text (the header).
  int _hiddenLines(ModuleDoc m) => '\n'.allMatches(splitPatternHeader(m.source).$1).length;

  void _type(ModuleDoc m, String text) {
    _code.insert(text);
    _write(m, _code.text);
    _focus.requestFocus();
  }

  /// Opens the text if it's hidden, so jumps and inserts land where they can be seen.
  void _showCode(ModuleDoc m) {
    if (!_showingCode(m)) setState(() => _codeView[m.id] = true);
  }

  void _showError(ModuleDoc m, ModuleInfo info) {
    _showCode(m);
    final hidden = _hiddenLines(m);
    // An error in a hidden header lands on the first line.
    final (line, col) = info.line > hidden ? (info.line - hidden, info.col) : (1, 1);
    WidgetsBinding.instance.addPostFrameCallback((_) => _code.jumpTo(line, col));
  }

  Future<void> _run(ModuleDoc m) async {
    final info = await s.run(m.id);
    if (!mounted || info == null) return;
    if (!info.ok) _showError(m, info);
  }

  /// A new pattern, with its header at once, opened in its own tab (Build's New › Pattern does the same).
  void _newPattern() {
    final id = s.addModule(Template('Pattern.caw', PatternDoc.blank().serialize()));
    final m = s.project.module(id)!;
    m.source = m.runSource = editPatternHeader(m.source, m.name, name: m.name) ?? m.source;
    SectionController.maybeOf(context)?.openBuild(BuildTab(BuildTabKind.pattern, id));
    _focus.requestFocus();
  }

  Future<void> _rename(ModuleDoc m) async {
    final c = TextEditingController(text: m.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename pattern'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Rename')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    s.renameModule(m.id, name);
    final next = editPatternHeader(m.source, name.trim(), name: name.trim());
    if (next != null) s.editSource(m.id, next);
  }

  Future<void> _delete(ModuleDoc m) async {
    final used = s.project.layers.where((l) => l.clips.any((c) => c.patternId == m.id)).map((l) => l.name).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${m.name}?'),
        content: Text(used.isEmpty ? 'Its notes will be gone.' : 'It is played by: ${used.join(', ')}. Those clips go.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: Neon.pink))),
        ],
      ),
    );
    if (ok == true) s.deleteModule(m.id);
  }

  /// Who plays the pattern, or how to hear it.
  String _patternUse(ModuleDoc m, ModuleInfo i) {
    final users = [for (final l in s.project.layers) if (l.clips.any((c) => c.patternId == m.id)) l.name];
    final notes = '${i.noteCount} note${i.noteCount == 1 ? '' : 's'}';
    return users.isEmpty
        ? 'A pattern of $notes. To hear it, drop it on a track in Arrange, or tap the headphones.'
        : 'A pattern of $notes, played by ${users.join(', ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final m = _module;
    _syncEditor(m);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      if (m == null) return const Center(child: Text('No pattern open'));
      final info = s.info[m.id];
      final look = s.settings.editor;
      const color = Neon.yellow;
      final showCode = _showingCode(m);
      final roll = !showCode ? PatternEditor(key: ValueKey(m.id), state: s, module: m) : null;
      final viewSwitch = SegmentedButton<bool>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
            selectedBackgroundColor: color.withValues(alpha: 0.2), selectedForegroundColor: Neon.text),
        segments: const [
          ButtonSegment(value: false, icon: Icon(Icons.piano, size: 18), label: Text('Notes')),
          ButtonSegment(value: true, icon: Icon(Icons.code, size: 18), label: Text('Text')),
        ],
        selected: {showCode},
        onSelectionChanged: (v) => setState(() => _codeView[m.id] = v.first),
      );
      final editor = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _run(m),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _run(m),
        },
        child: CodeField(
          controller: _code,
          focus: _focus,
          onChanged: (v) => _write(m, v),
          hint: m.source.isEmpty ? splitPatternHeader(patternHint).$2 : null,
        ),
      );
      final status = _StatusLine(module: m, info: info, onJump: () => _showError(m, info!));
      final header = Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
          child: const Text('PATTERN',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        ),
        const SizedBox(width: 10),
        // A pattern's header is fields here, not text (owner, 2026-11-10).
        Expanded(
          child: PatternFields(
            key: ValueKey('fields ${m.id}'),
            source: () => m.source,
            name: m.name,
            stepsPerBar: s.project.stepsPerBar,
            onSource: (v) => s.editSource(m.id, v),
            onRename: (v) => s.renameModule(m.id, v),
          ),
        ),
        if (look.soloButton)
          IconButton(
            tooltip: s.previewOnly ? 'Hearing only this (tap for the whole project)' : 'Hear only this',
            isSelected: s.previewOnly,
            onPressed: () => s.setPreviewOnly(!s.previewOnly),
            icon: const Icon(Icons.headphones_outlined, color: Neon.dim),
            selectedIcon: const Icon(Icons.headphones, color: Neon.blue),
          ),
        PopupMenuButton<String>(
          onSelected: (v) => switch (v) {
            'rename' => _rename(m),
            'solo' => s.setPreviewOnly(!s.previewOnly),
            _ => _delete(m),
          },
          itemBuilder: (_) => [
            // With the Solo button hidden (Settings → Code editor), Solo preview stays here.
            if (!look.soloButton)
              CheckedPopupMenuItem(value: 'solo', checked: s.previewOnly, child: const Text('Solo preview')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ]);
      final scope = s.settings.lightMode || !look.scope || !Neon.showScopes
          ? const SizedBox.shrink()
          : NeonPanel(
              color: color,
              padding: const EdgeInsets.all(6),
              child: ScopeView(
                  state: s, index: s.previewOnly ? Engine.auditionIndex : Engine.masterIndex, color: color,
                  height: wide ? 140 : 88),
            );
      final use = info != null && info.isPattern
          ? Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_patternUse(m, info), style: Neon.code(size: 13, color: Neon.yellow)),
            )
          : const SizedBox.shrink();
      final runBar = Row(children: [
        Expanded(child: SymbolRow(symbols: look.keyRow, onInsert: (t) => _type(m, t))),
        const SizedBox(width: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: m.edited ? Neon.green : Neon.panelHi,
            foregroundColor: m.edited ? Neon.bg : Neon.text,
            minimumSize: const Size(96, 46),
          ),
          onPressed: () => _run(m),
          icon: const Icon(Icons.bolt),
          label: const Text('Run', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ]);

      // The key row and Run bar sit under the text (by the keyboard) or above it, as set in Settings → Code editor.
      final bar = Padding(
          padding: look.barOnTop ? const EdgeInsets.fromLTRB(12, 6, 12, 6) : const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: runBar);
      if (wide) {
        return Column(children: [
          if (look.barOnTop) bar,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: Column(children: [
                    header,
                    const SizedBox(height: 8),
                    status,
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerLeft, child: viewSwitch),
                    const SizedBox(height: 6),
                    Expanded(child: roll ?? SingleChildScrollView(child: editor)),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: ListView(children: [scope, use])),
              ]),
            ),
          ),
          if (!look.barOnTop) bar,
        ]);
      }
      // Phone, or a narrow panel: one view at a time, the notes first; the text is one tap away.
      final top = [header, const SizedBox(height: 8), Center(child: viewSwitch), const SizedBox(height: 10)];
      if (roll != null) {
        return Column(children: [
          // Above the notes the header takes at most 45% of the panel and scrolls inside that.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: box.maxHeight * 0.45),
            child: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Column(children: [...top, status])),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: roll)),
          const SizedBox(height: 8),
        ]);
      }
      return Column(children: [
        if (look.barOnTop) bar,
        Expanded(
          child: ListView(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: [
                ...top,
                status,
                const SizedBox(height: 6),
                editor,
                use,
                const SizedBox(height: 12),
              ]),
            ),
          ]),
        ),
        if (!look.barOnTop) bar,
      ]);
    });
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.module, required this.info, required this.onJump});
  final ModuleDoc module;
  final ModuleInfo? info;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final i = info;
    if (i != null && !i.ok) {
      return InkWell(
        onTap: onJump,
        child: Row(children: [
          const Icon(Icons.error_outline, color: Neon.pink, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(i.error,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: Neon.code(size: 13, color: Neon.pink)),
          ),
        ]),
      );
    }
    final text = module.edited
        ? 'Edited: tap Run (Ctrl+Enter) to hear it'
        : (i?.summary.isNotEmpty == true ? i!.summary : 'Compiled and playing');
    return Row(children: [
      Icon(module.edited ? Icons.edit_note : Icons.check_circle_outline,
          color: module.edited ? Neon.yellow : Neon.green, size: 18),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: const TextStyle(color: Neon.dim, fontSize: 13))),
    ]);
  }
}
