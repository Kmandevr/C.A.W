// Sounds (the Builder area): pick or create a module, tweak its controls, and one tap away edit its code or notes and Run it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'code_editor.dart';
import 'key_router.dart';
import 'library_sheet.dart';
import 'param_control.dart';
import 'pattern_editor.dart';
import 'theme.dart';
import 'widgets.dart';

/// Generators and synths are green, effects pink, libraries blue and patterns yellow.
Color kindColor(String kind) =>
    switch (kind) { 'effect' => Neon.pink, 'library' => Neon.blue, 'pattern' => Neon.yellow, _ => Neon.green };
IconData kindIcon(String kind) => switch (kind) {
  'synth' => Icons.waves,
  'effect' => Icons.tune,
  'library' => Icons.menu_book,
  'pattern' => Icons.piano,
  _ => Icons.graphic_eq,
};

class BuilderScreen extends StatefulWidget {
  const BuilderScreen({super.key, required this.state});
  final AppState state;

  @override
  State<BuilderScreen> createState() => _BuilderScreenState();
}

class _BuilderScreenState extends State<BuilderScreen> {
  /// Per module: true shows its code (a pattern's text), false its controls (a pattern's piano roll).
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

  ModuleDoc? get _module => s.project.module(s.selectedModuleId);

  bool _builderAction(String id, int count, String? arg) {
    final m = _module;
    final mods = s.project.modules;
    void step(int d) {
      if (mods.isEmpty) return;
      final i = mods.indexWhere((x) => x.id == m?.id);
      s.selectModule(mods[(i + d * count) % mods.length].id);
    }

    switch (id) {
      case 'builder.module.new':
        _newModule();
      case 'builder.module.next':
        step(1);
      case 'builder.module.prev':
        step(-1);
      default:
        if (m == null) return false;
        switch (id) {
          case 'builder.run':
            _run(m);
          case 'builder.library' || 'builder.complete':
            _openLibrary(m);
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
            if (!s.isPattern(m.id)) return false;
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
      s.editSource(m.id, text);
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

  /// A module opens on its controls (a pattern on its notes); an empty one, or one with nothing to control, on its code.
  bool _showingCode(ModuleDoc m) {
    final remembered = _codeView[m.id];
    if (remembered != null) return remembered;
    if (s.isPattern(m.id)) return false;
    final info = s.info[m.id];
    return m.source.isEmpty || info == null || !info.ok || (info.params.isEmpty && !info.isLibrary);
  }

  void _syncEditor(ModuleDoc? m) {
    if (m?.id == _shownId) return;
    _shownId = m?.id;
    _code.text = m?.source ?? '';
  }

  /// The built-in functions plus the project's own libraries; null if the engine library can't load.
  Library? get _library {
    try {
      return Library.builtIn.withProject(s.info.values);
    } catch (_) {
      return null;
    }
  }

  void _type(ModuleDoc m, String text, {bool completing = false}) {
    completing ? _code.completeWord(text) : _code.insert(text);
    s.editSource(m.id, _code.text);
    _focus.requestFocus();
  }

  /// Opens the code (a pattern's text) if it's hidden, so jumps and inserts land where they can be seen.
  void _showCode(ModuleDoc m) {
    if (!_showingCode(m)) setState(() => _codeView[m.id] = true);
  }

  void _showError(ModuleDoc m, ModuleInfo info) {
    _showCode(m);
    WidgetsBinding.instance.addPostFrameCallback((_) => _code.jumpTo(info.line, info.col));
  }

  void _openLibrary(ModuleDoc m) {
    final lib = _library;
    if (lib == null) return;
    _showCode(m);
    showLibrarySheet(context, library: lib, query: _code.wordAtCursor, onInsert: (t) => _type(m, t, completing: true));
  }

  Future<void> _run(ModuleDoc m) async {
    final info = await s.run(m.id);
    if (!mounted || info == null) return;
    if (!info.ok) _showError(m, info);
  }

  static const _blanks = [
    ('generator', 'Sound', 'Makes sound: a formula, a synth or a drum'),
    ('effect', 'Effect', 'Changes the sound coming in'),
    ('pattern', 'Pattern', 'Notes for a sound to play'),
    ('library', 'Library', 'Functions other modules can call'),
  ];

  /// New: a blank module of each kind first (an empty file with a faint hint), then the templates.
  Future<void> _newModule() async {
    final pick = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(shrinkWrap: true, children: [
            const Heading('New blank'),
            for (final (i, b) in _blanks.indexed)
              ListTile(
                autofocus: i == 0,
                leading: Icon(kindIcon(b.$1), color: kindColor(b.$1)),
                title: Text(b.$2),
                subtitle: Text(b.$3, style: const TextStyle(color: Neon.dim)),
                onTap: () => Navigator.pop(context, b.$1),
              ),
            const Heading('From a template'),
            for (final t in s.templates)
              ListTile(
                leading: Icon(kindIcon(headerValue(t.source, 'kind') ?? 'generator'),
                    color: kindColor(headerValue(t.source, 'kind') ?? 'generator')),
                title: Text(headerValue(t.source, 'name') ?? t.file),
                subtitle: Text(headerValue(t.source, 'summary') ?? '', style: const TextStyle(color: Neon.dim)),
                onTap: () => Navigator.pop(context, t),
              ),
          ]),
        ),
      ),
    );
    if (pick is Template) s.addModule(pick);
    if (pick is String) {
      s.addBlankModule(pick);
      _focus.requestFocus();
    }
  }

  Future<void> _rename(ModuleDoc m) async {
    final c = TextEditingController(text: m.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename module'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Rename')),
        ],
      ),
    );
    if (name != null) s.renameModule(m.id, name);
  }

  Future<void> _delete(ModuleDoc m) async {
    final used = s.project.layers.where((l) => l.chain.contains(m.id)).map((l) => l.name).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${m.name}?'),
        content: Text(used.isEmpty ? 'Its code will be gone.' : 'It is used by: ${used.join(', ')}. Those layers lose it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: Neon.pink))),
        ],
      ),
    );
    if (ok == true) s.deleteModule(m.id);
  }

  @override
  Widget build(BuildContext context) {
    final m = s.project.module(s.selectedModuleId);
    _syncEditor(m);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final picker = _ModulePicker(state: s, onNew: _newModule);
      if (m == null) {
        return Column(children: [
          picker,
          const Expanded(child: Center(child: Text('No modules yet: tap New to start one'))),
        ]);
      }
      final info = s.info[m.id];
      final look = s.settings.editor;
      // An empty module shows the kind picked for it until its header says otherwise.
      final kind = s.hintKindOf(m.id) ?? s.kindOf(m.id);
      final color = kindColor(kind);
      final pattern = s.isPattern(m.id);
      final showCode = _showingCode(m);
      final roll = pattern && !showCode ? PatternEditor(key: ValueKey(m.id), state: s, module: m) : null;
      // On a wide screen code and controls sit side by side, so only a pattern needs the switch there.
      final viewSwitch = wide && !pattern
          ? const SizedBox.shrink()
          : SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: color.withValues(alpha: 0.2), selectedForegroundColor: Neon.text),
              segments: [
                ButtonSegment(
                    value: false,
                    icon: Icon(pattern ? Icons.piano : Icons.tune, size: 18),
                    label: Text(pattern ? 'Notes' : 'Controls')),
                ButtonSegment(
                    value: true, icon: const Icon(Icons.code, size: 18), label: Text(pattern ? 'Text' : 'Code')),
              ],
              selected: {showCode},
              onSelectionChanged: (v) => setState(() => _codeView[m.id] = v.first),
            );
      final editor = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _run(m),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _run(m),
          const SingleActivator(LogicalKeyboardKey.f1): () => _openLibrary(m),
        },
        child: CodeField(
          controller: _code,
          focus: _focus,
          onChanged: (v) => s.editSource(m.id, v),
          hint: s.hintKindOf(m.id) == null ? null : codeHint(s.hintKindOf(m.id)!),
        ),
      );
      final status = _StatusLine(
          module: m,
          info: info,
          onJump: () => _showError(m, info!));
      final header = Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
          child: Text(kind.toUpperCase(),
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: () => _rename(m),
            child: Text(m.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
      final scope = s.settings.lightMode || !look.scope
          ? const SizedBox.shrink()
          : NeonPanel(
        color: color,
        padding: const EdgeInsets.all(6),
        child: ScopeView(
            state: s, index: s.previewOnly ? Engine.auditionIndex : Engine.masterIndex, color: color, height: wide ? 140 : 88),
      );
      final params = _Params(state: s, module: m, info: info, compact: look.compactControls);
      final library = _library;
      final completion = library == null || !look.chips
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: _code,
              builder: (context, _) => CompletionChips(
                  library: library,
                  word: _code.wordAtCursor,
                  minLetters: look.chipLetters,
                  limit: look.chipCount,
                  onPick: (t) => _type(m, t, completing: true)),
            );
      final runBar = Row(children: [
        Expanded(child: SymbolRow(symbols: look.keyRow, onInsert: (t) => _type(m, t))),
        const SizedBox(width: 4),
        if (look.libraryButton)
          IconButton(
            tooltip: 'Function library (F1)',
            onPressed: library == null ? null : () => _openLibrary(m),
            icon: const Icon(Icons.menu_book, color: Neon.blue),
          ),
        const SizedBox(width: 4),
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

      // The key row and Run bar sit under the code (by the keyboard) or above it, as set in Settings → Code editor.
      final bar = Padding(
          padding: look.barOnTop ? const EdgeInsets.fromLTRB(12, 6, 12, 6) : const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(children: look.barOnTop ? [runBar, completion] : [completion, runBar]));
      if (wide) {
        return Column(children: [
          picker,
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
                    if (pattern) Align(alignment: Alignment.centerLeft, child: viewSwitch),
                    if (pattern) const SizedBox(height: 6),
                    Expanded(child: roll ?? SingleChildScrollView(child: editor)),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: ListView(children: [scope, params])),
              ]),
            ),
          ),
          if (!look.barOnTop) bar,
        ]);
      }
      // Phone: one view at a time. Controls (or a pattern's notes) first; the code is one tap away.
      final top = [header, const SizedBox(height: 8), Center(child: viewSwitch), const SizedBox(height: 10)];
      if (roll != null) {
        return Column(children: [
          picker,
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Column(children: [...top, status])),
          const SizedBox(height: 6),
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: roll)),
          const SizedBox(height: 8),
        ]);
      }
      if (!showCode) {
        return Column(children: [
          picker,
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 24), children: [
              ...top,
              scope,
              const SizedBox(height: 8),
              status,
              params,
            ]),
          ),
        ]);
      }
      return Column(children: [
        picker,
        if (look.barOnTop) bar,
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            ...top,
            status,
            const SizedBox(height: 6),
            editor,
            const SizedBox(height: 12),
          ]),
        ),
        if (!look.barOnTop) bar,
      ]);
    });
  }
}

class _ModulePicker extends StatelessWidget {
  const _ModulePicker({required this.state, required this.onNew});
  final AppState state;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            ActionChip(
              avatar: const Icon(Icons.add, color: Neon.yellow, size: 18),
              label: const Text('New'),
              onPressed: onNew,
            ),
            for (final m in state.project.modules) ...[
              const SizedBox(width: 6),
              ChoiceChip(
                avatar: Icon(kindIcon(state.kindOf(m.id)), size: 16, color: kindColor(state.kindOf(m.id))),
                label: Text(m.name + (m.edited ? ' •' : '')),
                selected: m.id == state.selectedModuleId,
                onSelected: (_) => state.selectModule(m.id),
                selectedColor: kindColor(state.kindOf(m.id)).withValues(alpha: 0.2),
                labelStyle: const TextStyle(color: Neon.text, fontWeight: FontWeight.w600),
                showCheckmark: false,
              ),
            ],
          ],
        ),
      );
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

class _Params extends StatelessWidget {
  const _Params({required this.state, required this.module, required this.info, this.compact = false});
  final AppState state;
  final ModuleDoc module;
  final ModuleInfo? info;
  final bool compact;

  String _patternUse(ModuleInfo i) {
    final users = [for (final l in state.project.layers) if (l.patternId == module.id) l.name];
    final notes = '${i.noteCount} note${i.noteCount == 1 ? '' : 's'}';
    return users.isEmpty
        ? 'A pattern of $notes. To hear it, pick it as a track\'s notes in Tracks, or tap the headphones.'
        : 'A pattern of $notes, played by ${users.join(', ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final params = info?.params ?? const <ParamInfo>[];
    if (params.isEmpty &&
        !(info?.isLibrary ?? false) &&
        !(info?.isPattern ?? false) &&
        (info?.exports.isEmpty ?? true) &&
        (info?.warnings.isEmpty ?? true)) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('Add `param name = 0.5 in 0..1` to get a slider.', style: TextStyle(color: Neon.dim, fontSize: 13)),
      );
    }
    final color = kindColor(state.kindOf(module.id));
    final i = info;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Heading('Controls'),
      ValueListenableBuilder<int>(
        valueListenable: state.values,
        builder: (context, _, _) => ParamGroups(
          compact: compact,
          params: params,
          color: color,
          valueOf: (p) => p.global ? state.globalValue(p) : (module.params[p.name] ?? p.defaultValue),
          onChanged: (p, v) => p.global ? state.setGlobal(p.name, v) : state.setParam(module.id, p.name, v),
        ),
      ),
      if (i != null && i.isPattern)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(_patternUse(i), style: Neon.code(size: 13, color: Neon.yellow)),
        ),
      if (i != null && i.isLibrary)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
              i.functions.isEmpty
                  ? 'A library: add `fn name(a) = …` and other modules can call ${i.namespace}.name.'
                  : 'Other modules can call: ${i.functions.map((f) => f.signature).join(', ')}',
              style: Neon.code(size: 13, color: Neon.blue)),
        ),
      if (i != null && i.imports.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Reads: ${i.imports.join(', ')}', style: Neon.code(size: 13, color: Neon.blue)),
        ),
      if (i != null && i.exports.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Shares: ${i.exports.map((e) => '${i.ref}.${e.name}').join(', ')}',
              style: Neon.code(size: 13, color: Neon.blue)),
        ),
      for (final w in i?.warnings ?? const <String>[])
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(w, style: const TextStyle(color: Neon.yellow, fontSize: 13)),
        ),
    ]);
  }
}
