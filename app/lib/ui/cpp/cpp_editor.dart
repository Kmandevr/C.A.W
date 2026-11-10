// The C++ editor tab: re_editor with Neon colours, error marks, inline knob values, completion, the key row and sheets.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../model/cpp_completion.dart';
import '../../model/cpp_diagnostics.dart';
import '../../model/cpp_versions.dart';
import '../../model/cpp_workbench.dart';
import '../feedback.dart';
import '../frame/sections.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';
import 'code_style.dart';
import 'cpp_library.dart';
import 'key_row.dart';
import 'panels.dart';

/// One file's editor state, kept with its session so undo survives switching tabs and files.
class CppFileView {
  CppFileView(String text) {
    controller = CodeLineEditingController(
      codeLines: CodeLines.fromText(text),
      options: const CodeLineOptions(indentSize: 4),
      spanBuilder: ({required context, required index, required codeLine, required textSpan, required style}) {
        final m = marks[index];
        return m == null ? textSpan : decorateSpan(textSpan, m);
      },
    );
    _lines = controller.codeLines;
    controller.addListener(() => onChange?.call());
  }

  late final CodeLineEditingController controller;
  /// The editor showing this file now (an editor that goes away clears it).
  VoidCallback? onChange;
  Map<int, List<LineMark>> marks = const {};
  late CodeLines _lines;
  int revision = 0;

  /// Whether the text changed since the last call (not just the cursor).
  bool takeTextChange() {
    final now = controller.codeLines;
    if (identical(now, _lines)) return false;
    _lines = now;
    return true;
  }
}

final _views = Expando<Map<String, CppFileView>>('cpp file views');

Map<String, CppFileView> _viewsOf(CppWorkbench w) => _views[w] ??= {};

class CppEditor extends StatefulWidget {
  const CppEditor({super.key, required this.workbench, this.bar});

  final CppWorkbench workbench;

  /// Build's tab strip (explorer, open tabs, + New), at the start of the one top row; without it the row names
  /// the component and file.
  final Widget? bar;

  @override
  State<CppEditor> createState() => CppEditorState();
}

class CppEditorState extends State<CppEditor> {
  final _focus = FocusNode();
  final _scroll = CodeScrollController();
  final _paragraphs = ValueNotifier<CodeIndicatorValue?>(null);
  CodeIndicatorValueNotifier? _boundIndicator;
  late _EditorTarget _target;

  // Completion.
  List<CppCompletion> _items = const [];
  int _selected = 0;
  CppCompletionContext? _context;
  Timer? _completionTimer;
  int _completionRequest = 0;

  /// The diagnostic whose message shows under its line (the last one jumped to), else the cursor line's.
  CppDiagnostic? _focusDiagnostic;

  CppWorkbench get w => widget.workbench;

  CppFileView get view {
    final path = w.currentFile;
    final v = _viewOf(path);
    v.onChange = () => _onController(path, v);
    return v;
  }

  CppFileView _viewOf(String path) {
    final views = _viewsOf(w);
    final existing = views[path];
    if (existing != null && existing.revision == w.revision) return existing;
    if (existing != null) {
      // The files changed outside the editor (a version restored): an undoable replace keeps its history.
      existing.controller.text = w.texts[path] ?? '';
      existing.takeTextChange();
      existing.revision = w.revision;
      existing.marks = marksFor(w.diagnostics, path, (w.texts[path] ?? '').split('\n'));
      return existing;
    }
    final v = views[path] = CppFileView(w.texts[path] ?? '')..revision = w.revision;
    v.marks = marksFor(w.diagnostics, path, (w.texts[path] ?? '').split('\n'));
    return v;
  }

  @override
  void initState() {
    super.initState();
    _target = _EditorTarget(this);
    w.addListener(_onWorkbench);
    _refreshMarks();
  }

  @override
  void didUpdateWidget(CppEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (!identical(old.workbench, w)) {
      old.workbench.removeListener(_onWorkbench);
      for (final v in _viewsOf(old.workbench).values) {
        v.onChange = null;
      }
      w.addListener(_onWorkbench);
      _closeCompletion();
      _refreshMarks();
    }
  }

  @override
  void dispose() {
    for (final v in _viewsOf(w).values) {
      v.onChange = null;
    }
    _completionTimer?.cancel();
    w.removeListener(_onWorkbench);
    _boundIndicator?.removeListener(_mirrorIndicator);
    _paragraphs.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onWorkbench() {
    _refreshMarks();
    _rebuild();
  }

  // The squiggles of every open file follow the diagnostics.
  void _refreshMarks() {
    for (final entry in _viewsOf(w).entries) {
      final lines = entry.value.controller.codeLines;
      final texts = [for (var i = 0; i < lines.length; i++) lines[i].text];
      final next = marksFor(w.diagnostics, entry.key, texts);
      if (!_sameMarks(next, entry.value.marks)) {
        entry.value.marks = next;
        entry.value.controller.forceRepaint();
      }
    }
  }

  static bool _sameMarks(Map<int, List<LineMark>> a, Map<int, List<LineMark>> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      final o = b[e.key];
      if (o == null || o.length != e.value.length) return false;
      for (var i = 0; i < o.length; i++) {
        if (o[i].start != e.value[i].start || o[i].end != e.value[i].end || o[i].severity != e.value[i].severity) return false;
      }
    }
    return true;
  }

  void _onController(String path, CppFileView v) {
    if (v.takeTextChange()) {
      w.edit(path, v.controller.text);
      _focusDiagnostic = null;
      if (path == w.currentFile) _scheduleCompletion();
    } else if (_items.isNotEmpty) {
      // The cursor moved: the box goes unless it's still in the word being completed.
      final ctx = _contextNow();
      if (ctx == null || _context == null || ctx.prefix.isEmpty) _closeCompletion();
    }
    _rebuild();
  }

  // Controllers notify at any time (even while the editor builds): rebuild now or after this frame.
  void _rebuild() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  // ---------- jumping ----------

  void jumpTo(CppDiagnostic d) {
    if (w.texts.containsKey(d.file)) w.selectFile(d.file);
    final c = view.controller;
    final line = (d.line - 1).clamp(0, c.lineCount - 1);
    final text = c.codeLines[line].text;
    c.selection = CodeLineSelection.collapsed(index: line, offset: (d.column - 1).clamp(0, text.length));
    c.makeCursorCenterIfInvisible();
    setState(() => _focusDiagnostic = d);
  }

  void jumpToNextError() {
    final sel = view.controller.selection;
    final next = nextError(w.diagnostics,
        file: w.currentFile, line: sel.extentIndex + 1, column: sel.extentOffset + 1, order: w.fileOrder);
    if (next != null) jumpTo(next);
  }

  /// Puts the cursor at the start of 0-based [line] of the current file (the switcher's symbols).
  void goToLine(int line) {
    final c = view.controller;
    final l = line.clamp(0, c.lineCount - 1);
    c.selection = CodeLineSelection.collapsed(index: l, offset: 0);
    c.makeCursorCenterIfInvisible();
  }

  void jumpToPreviousError() {
    final sel = view.controller.selection;
    final prev = previousError(w.diagnostics,
        file: w.currentFile, line: sel.extentIndex + 1, column: sel.extentOffset + 1, order: w.fileOrder);
    if (prev != null) jumpTo(prev);
  }

  void insert(String text) {
    final c = view.controller;
    // A multi-line insert keeps the cursor line's indent.
    final line = c.codeLines[c.selection.extentIndex].text;
    final indent = RegExp(r'^\s*').firstMatch(line)!.group(0)!;
    final body = text.contains('\n') ? text.trimRight().split('\n').join('\n$indent') : text;
    c.replaceSelection(body);
    c.makeCursorVisible();
  }

  // ---------- completion ----------

  CppCompletionContext? _contextNow() {
    final c = view.controller;
    final sel = c.selection;
    if (!sel.isCollapsed) return null;
    return CppCompletionContext.at(c.codeLines[sel.extentIndex].text, sel.extentOffset);
  }

  void _scheduleCompletion({bool force = false}) {
    _completionTimer?.cancel();
    if (languageOf(w.currentFile) == 'plaintext') return _closeCompletion();
    final ctx = _contextNow();
    if (ctx == null || ctx.trigger == 'none') return _closeCompletion();
    if (!force && !ctx.opensAutomatically) return _closeCompletion();
    if (_items.isNotEmpty || ctx.trigger.isNotEmpty && ctx.prefix.isEmpty || force) {
      _openCompletion(ctx); // already open, or right after `.`/`::`/`->`: at once
    } else {
      _completionTimer = Timer(const Duration(milliseconds: 300), () {
        final now = _contextNow();
        if (now != null && now.opensAutomatically) _openCompletion(now);
      });
    }
  }

  void _openCompletion(CppCompletionContext ctx) {
    final c = view.controller;
    final instant = staticCompletions(ctx, c.codeLines.length < 6000 ? w.texts[w.currentFile] ?? '' : '',
        knobs: w.knobCompletions);
    _context = ctx;
    _items = instant;
    _selected = 0;
    _rebuild();
    // Clang's own results follow when the compiler answers (unmeasured on the phone; the instant list stays).
    final request = ++_completionRequest;
    final sel = c.selection;
    final path = w.currentFile;
    _completionTimer?.cancel();
    _completionTimer = Timer(const Duration(milliseconds: 450), () async {
      final clang = await w.clangCompletions(path, sel.extentIndex, sel.extentOffset, prefix: ctx.prefix);
      if (!mounted || request != _completionRequest || clang.isEmpty) return;
      final now = _contextNow();
      if (now == null || now.prefix != ctx.prefix || view.controller.selection != sel) return;
      setState(() => _items = mergeCompletions(clang, _items));
    });
  }

  void _closeCompletion() {
    _completionTimer?.cancel();
    _completionRequest++;
    if (_items.isEmpty && _context == null) return;
    _items = const [];
    _context = null;
    _rebuild();
  }

  void _accept(CppCompletion item) {
    final ctx = _contextNow();
    final c = view.controller;
    final sel = c.selection;
    final prefix = ctx?.prefix ?? '';
    c.selection = CodeLineSelection(
        baseIndex: sel.extentIndex, baseOffset: sel.extentOffset - prefix.length, extentIndex: sel.extentIndex, extentOffset: sel.extentOffset);
    c.replaceSelection(item.insert);
    _closeCompletion();
  }

  // ---------- build ----------

  Future<void> runBuild() async {
    _closeCompletion();
    final ok = await w.build();
    if (ok || !mounted) return;
    final trust = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Native code from elsewhere'),
        content: const Text('This effect came with the project, not from this device. Building runs it in the app '
            'as trusted code. Trust it and treat your edits as your own?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Trust and build')),
        ],
      ),
    );
    if (trust == true) await w.build(trustConfirmed: true);
  }

  // ---------- sheets ----------

  Future<void> _sheet(String title, WidgetBuilder body) {
    final h = MediaQuery.sizeOf(context).height;
    return showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: h * 0.5),
      builder: (c) => SizedBox(
        height: h * 0.45,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: body(c)),
        ]),
      ),
    );
  }

  void showProblems() => _sheet('Problems', (c) => ProblemsList(workbench: w, onJump: (d) {
        Navigator.pop(c);
        jumpTo(d);
      }));

  void showLibrary() => showCppLibrarySheet(context, onInsert: insert);

  void _showSnippets() => _sheet('Snippets', (c) => SnippetList(onInsert: (t) {
        Navigator.pop(c);
        insert(t);
      }));

  void _showTest() => _sheet('♪ Test', (c) => TestStrip(workbench: w));

  Future<void> _showVersions() async {
    final versions = (await w.versions()).reversed.toList();
    if (!mounted) return;
    await _sheet('Versions', (c) => versions.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Each successful build keeps a version here (the last 20).', style: TextStyle(fontSize: 12, color: Neon.dim)))
        : ListView(children: [
            for (final v in versions)
              ListTile(
                dense: true,
                title: Text(v.label, style: const TextStyle(fontSize: 13)),
                subtitle: Text('${v.files.length} file${v.files.length == 1 ? '' : 's'}', style: TextStyle(fontSize: 11, color: Neon.dim)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: () => _viewVersion(c, v), child: const Text('View')),
                  TextButton(
                    key: ValueKey('restore ${v.number}'),
                    onPressed: () {
                      Navigator.pop(c);
                      w.restore(v);
                    },
                    child: const Text('Restore'),
                  ),
                ]),
              ),
          ]));
  }

  void _viewVersion(BuildContext c, CppVersion v) {
    showDialog<void>(
      context: c,
      builder: (d) => AlertDialog(
        title: Text(v.label, style: const TextStyle(fontSize: 14)),
        content: SizedBox(
          width: 520,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              [for (final e in v.files.entries) '// ${e.key}\n${e.value}'].join('\n'),
              style: Neon.code(size: 11),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
      ),
    );
  }

  // ---------- layout ----------

  void _bindIndicator(CodeIndicatorValueNotifier n) {
    if (identical(n, _boundIndicator)) return;
    _boundIndicator?.removeListener(_mirrorIndicator);
    _boundIndicator = n..addListener(_mirrorIndicator);
  }

  void _mirrorIndicator() => _paragraphs.value = _boundIndicator?.value;

  double get _gutterWidth => 14 + 7.6 * math.max(3, view.controller.lineCount.toString().length);

  Widget _editor() {
    final v = view;
    final path = w.currentFile;
    return Stack(children: [
      Positioned.fill(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyB, control: true): runBuild,
            const SingleActivator(LogicalKeyboardKey.space, control: true): () => _scheduleCompletion(force: true),
            const SingleActivator(LogicalKeyboardKey.f8): jumpToNextError,
            const SingleActivator(LogicalKeyboardKey.f8, shift: true): jumpToPreviousError,
          },
          child: CodeEditor(
            key: ValueKey('code $path'),
            controller: v.controller,
            scrollController: _scroll,
            focusNode: _focus,
            wordWrap: false,
            autofocus: false, // the keyboard opens when the code is tapped, not when a tab opens
            chunkAnalyzer: const NonCodeChunkAnalyzer(),
            padding: const EdgeInsets.fromLTRB(6, 6, 24, 48),
            style: CodeEditorStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12.5,
              fontHeight: 1.45,
              textColor: Neon.text,
              backgroundColor: Colors.transparent,
              cursorColor: Neon.blue,
              selectionColor: Neon.blue.withValues(alpha: 0.3),
              cursorLineColor: Colors.white.withValues(alpha: 0.04),
              codeTheme: _themeFor(path),
            ),
            indicatorBuilder: (context, controller, chunks, notifier) {
              _bindIndicator(notifier);
              return SizedBox(
                width: _gutterWidth,
                child: CustomPaint(painter: _GutterPainter(_paragraphs, v, w, path)),
              );
            },
            shortcutOverrideActions: {
              CodeShortcutNewLineIntent: CallbackAction<CodeShortcutNewLineIntent>(onInvoke: (_) {
                if (_items.isNotEmpty) {
                  _accept(_items[_selected]);
                  return null;
                }
                v.controller.applyNewLine();
                return null;
              }),
              CodeShortcutIndentIntent: CallbackAction<CodeShortcutIndentIntent>(onInvoke: (_) {
                if (_items.isNotEmpty) {
                  _accept(_items[_selected]);
                  return null;
                }
                v.controller.applyIndent();
                return null;
              }),
              CodeShortcutCursorMoveIntent: CallbackAction<CodeShortcutCursorMoveIntent>(onInvoke: (i) {
                if (_items.isNotEmpty && (i.direction == AxisDirection.up || i.direction == AxisDirection.down)) {
                  setState(() => _selected = (_selected + (i.direction == AxisDirection.down ? 1 : -1)).clamp(0, _items.length - 1));
                  return null;
                }
                v.controller.moveCursor(i.direction);
                return null;
              }),
              CodeShortcutEscIntent: CallbackAction<CodeShortcutEscIntent>(onInvoke: (_) {
                _closeCompletion();
                return null;
              }),
            },
          ),
        ),
      ),
      Positioned.fill(
        left: _gutterWidth,
        child: IgnorePointer(
          child: CustomPaint(painter: _HintPainter(_paragraphs, v, w, path, _focusDiagnostic)),
        ),
      ),
      if (_items.isNotEmpty) _completionBox(v),
    ]);
  }

  final Map<String, CodeHighlightTheme> _themes = {};
  CodeHighlightTheme _themeFor(String path) {
    final lang = languageOf(path);
    return _themes[lang] ??= _only(cppHighlightTheme(), lang);
  }
  static CodeHighlightTheme _only(CodeHighlightTheme t, String lang) =>
      CodeHighlightTheme(languages: {lang: t.languages[lang]!}, theme: t.theme);

  Widget _completionBox(CppFileView v) {
    final caret = _caretOffset(v) ?? const Offset(40, 40);
    const rowHeight = 26.0;
    final rows = math.min(4, _items.length);
    final size = MediaQuery.sizeOf(context);
    final width = math.min(300.0, size.width - 16);
    final left = (caret.dx + _gutterWidth - 12).clamp(4.0, math.max(4.0, size.width - width - 4)).toDouble();
    // Visible rows scroll with the selection.
    final first = (_selected - rows + 1).clamp(0, math.max(0, _items.length - rows)).toInt();
    return Positioned(
      left: left,
      top: caret.dy + 20,
      width: width,
      child: CodeEditorTapRegion(
        child: GlassOverlay(
          radius: 8,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = first; i < first + rows; i++)
              InkWell(
                key: ValueKey('completion ${_items[i].label}'),
                onTap: () => _accept(_items[i]),
                child: Container(
                  height: rowHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  color: i == _selected ? Neon.blue.withValues(alpha: 0.22) : null,
                  child: Row(children: [
                    if (_items[i].fromClang) Icon(Icons.bolt, size: 12, color: Neon.green.withValues(alpha: 0.8)),
                    Flexible(
                      child: Text(_items[i].label, style: Neon.code(size: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_items[i].detail,
                          textAlign: TextAlign.right,
                          style: Neon.code(size: 10.5, color: Neon.dim),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Offset? _caretOffset(CppFileView v) {
    final value = _paragraphs.value;
    if (value == null) return null;
    final sel = v.controller.selection;
    for (final p in value.paragraphs) {
      if (p.index != sel.extentIndex) continue;
      final o = p.getOffset(TextPosition(offset: sel.extentOffset)) ?? Offset.zero;
      return p.offset + o;
    }
    return null;
  }

  /// Problems and the Library beside the code (landscape and desktop); null until toggled: open on a wide desktop.
  bool? _side;

  /// Which page the side panel shows: the Library (true) or Problems.
  bool _sideLibrary = false;

  Widget _iconAction(String id, IconData icon, String tip, VoidCallback? onTap, {Color? color, String? label, double height = 36}) {
    final c = color ?? Neon.dim;
    if (label != null) {
      return Pressable(
        child: TextButton.icon(
          key: ValueKey(id),
          style: TextButton.styleFrom(
            foregroundColor: c,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size(0, height),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 15),
          label: Text(label, style: const TextStyle(fontSize: 11.5)),
        ),
      );
    }
    return Pressable(
      child: IconButton(
        key: ValueKey(id),
        tooltip: tip,
        iconSize: height < 30 ? 16 : 18,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(width: height < 30 ? 30 : 34, height: height),
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: Icon(icon, color: c),
      ),
    );
  }

  /// Problems: beside the code when there is a side panel, else a half sheet.
  void _problems(bool wide) {
    Haptics.tap();
    if (wide) {
      setState(() {
        _side = true;
        _sideLibrary = false;
      });
    } else {
      showProblems();
    }
  }

  void _showSide({required bool library}) => setState(() => _sideLibrary = library);

  void _library(bool wide) {
    Haptics.tap();
    if (wide) {
      setState(() {
        _side = true;
        _sideLibrary = true;
      });
    } else {
      showLibrary();
    }
  }

  /// The top row: Build's tabs (or the file's name), the side-panel toggle when wide, and ▶ Build.
  Widget _topRow({required bool wide, required bool side}) {
    return SizedBox(
      height: 36,
      child: Row(children: [
        Expanded(
          child: widget.bar ??
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('${w.name} · ${w.currentFile.split('/').last}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              ),
        ),
        if (wide)
          _iconAction('side panel', side ? Icons.vertical_split : Icons.vertical_split_outlined,
              side ? 'Hide Problems and Library' : 'Show Problems and Library', () => setState(() => _side = !side),
              color: side ? Neon.blue : null),
        Padding(padding: const EdgeInsets.only(left: 2, right: 4), child: _BuildButton(phase: w.phase, onBuild: runBuild)),
      ]),
    );
  }

  /// Under the tabs, in the mono font like a code tool: the C++ badge, the file's breadcrumb (tap: the component's
  /// files), what the last build did (with "Try it on a track") or the problems, ‹ › between errors, then Problems,
  /// the Library, Versions and ⋯ (Snippets, ♪ Test), labelled when there is room.
  Widget _crumbRow({required bool wide, required bool side, required double width}) {
    final errors = w.errorCount;
    final count = w.diagnostics.length;
    final labels = width >= 640;
    final parts = w.currentFile.split('/');
    final crumb = PopupMenuButton<String>(
      key: const ValueKey('breadcrumb'),
      tooltip: "${w.name}'s files",
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 200),
      onSelected: (f) {
        Haptics.tap();
        w.selectFile(f);
      },
      itemBuilder: (c) => [
        for (final f in w.fileOrder)
          PopupMenuItem(
            height: 34,
            value: f,
            child: Row(children: [
              Icon(f == w.currentFile ? Icons.radio_button_checked : Icons.description_outlined, size: 16, color: Neon.dim),
              const SizedBox(width: 8),
              Flexible(child: Text(f, style: Neon.code(size: 12), overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text.rich(
          TextSpan(children: [
            if (width >= 420) ...[
              TextSpan(text: w.name, style: Neon.code(size: 11, color: Neon.dim)),
              TextSpan(text: ' › ', style: Neon.code(size: 11, color: Neon.line)),
              for (final p in parts.take(parts.length - 1)) ...[
                TextSpan(text: p, style: Neon.code(size: 11, color: Neon.dim)),
                TextSpan(text: ' › ', style: Neon.code(size: 11, color: Neon.line)),
              ],
            ],
            TextSpan(text: parts.last, style: Neon.code(size: 11, color: Neon.text)),
            const WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(Icons.arrow_drop_down, size: 14, color: Neon.dim)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
      ),
      child: Row(children: [
        const SizedBox(width: 6),
        Container(
          key: const ValueKey('cpp badge'),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: (w.isInstrument ? Neon.green : Neon.pink).withValues(alpha: 0.6)),
          ),
          child: Text('C++', style: Neon.code(size: 9.5, color: w.isInstrument ? Neon.green : Neon.pink)),
        ),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: crumb)),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.max(90.0, width * 0.45)),
          child: _StatusChip(editor: this, wide: wide),
        ),
        if (errors > 0) ...[
          _iconAction('previous error', Icons.keyboard_arrow_up, 'Previous error (Shift+F8)', jumpToPreviousError, height: 28),
          _iconAction('next error', Icons.keyboard_arrow_down, 'Next error (F8)', jumpToNextError, height: 28),
        ],
        _iconAction('bar problems', Icons.report_outlined, count == 0 ? 'Problems' : 'Problems ($count)', () => _problems(wide),
            color: errors > 0 ? Neon.pink : (count > 0 ? Neon.yellow : null),
            label: labels ? (count == 0 ? 'Problems' : 'Problems $count') : null,
            height: 28),
        _iconAction('bar library', Icons.menu_book_outlined, 'Library: the C++ reference', () => _library(wide),
            color: Neon.blue, label: labels ? 'Library' : null, height: 28),
        _iconAction('bar versions', Icons.history, 'Versions: every successful build', _showVersions,
            label: labels ? 'Versions' : null, height: 28),
        SizedBox(
          width: 30,
          height: 28,
          child: PopupMenuButton<void Function()>(
            key: const ValueKey('more'),
            tooltip: 'Snippets and ♪ Test',
            padding: EdgeInsets.zero,
            iconSize: 16,
            icon: const Icon(Icons.more_vert, color: Neon.dim),
            constraints: const BoxConstraints(minWidth: 180),
            onSelected: (f) => f(),
            itemBuilder: (c) => [
              PopupMenuItem(key: const ValueKey('bar snippets'), height: 34, value: _showSnippets,
                  child: const Text('Snippets', style: TextStyle(fontSize: 13))),
              PopupMenuItem(key: const ValueKey('bar test'), height: 34, value: _showTest,
                  child: const Text('♪ Test: play it with knobs', style: TextStyle(fontSize: 13))),
            ],
          ),
        ),
        const SizedBox(width: 2),
      ]),
    );
  }

  // ---------- try it on a track ----------

  /// Puts the built instrument or effect on a track the user picks (the selected one first, or a new one), says
  /// where it went and offers Show (Arrange, focused on that track).
  Future<void> tryOnTrack() async {
    Haptics.tap();
    final s = w.state;
    final selected = s.project.layers.where((l) => l.id == s.selectedLayerId && !l.isFolder).firstOrNull;
    final tracks = [?selected, ...s.project.layers.where((l) => !l.isFolder && l != selected)];
    const fresh = '\u0000new';
    final pick = await showGlassSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
          child: Text('Try ${w.name} on a track', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
              w.isInstrument ? 'It plays the track\'s notes in place of its sound. Undo takes it back.' : 'It joins the end of the track\'s effects.',
              style: const TextStyle(fontSize: 12, color: Neon.dim)),
        ),
        ListTile(
          key: const ValueKey('try new track'),
          dense: true,
          leading: const Icon(Icons.add, color: Neon.green, size: 20),
          title: const Text('New track', style: TextStyle(fontSize: 13)),
          subtitle: Text('Named ${w.name}', style: const TextStyle(fontSize: 11.5, color: Neon.dim)),
          onTap: () => Navigator.pop(c, fresh),
        ),
        for (final l in tracks)
          ListTile(
            key: ValueKey('try ${l.id}'),
            dense: true,
            leading: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: Neon.layer(l.color))),
            title: Text(l.name, style: const TextStyle(fontSize: 13)),
            trailing: l == selected ? const Text('selected', style: TextStyle(fontSize: 11, color: Neon.dim)) : null,
            onTap: () => Navigator.pop(c, l.id),
          ),
      ]),
    );
    if (pick == null || !mounted) return;
    final layer = pick == fresh ? null : s.project.layers.where((l) => l.id == pick).firstOrNull;
    final done = w.tryOn(layer);
    if (!mounted) return;
    final where = done ?? layer;
    final sections = SectionController.maybeOf(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(done == null ? '${w.name} is already on ${where?.name ?? 'that track'}' : '${w.name} is on ${done.name}'),
      action: where == null || sections == null
          ? null
          : SnackBarAction(label: 'Show', onPressed: () => sections.focusLayer(where.id)),
    ));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // The soft keyboard, from the window itself: a Scaffold above may already have taken it out of viewInsets.
    final view = View.of(context);
    final keyboard = view.viewInsets.bottom / view.devicePixelRatio > 80 || mq.viewInsets.bottom > 80;
    return LayoutBuilder(builder: (context, box) {
      // Room beside the code: landscape or desktop with at least 600 dp for the editor itself.
      final wide = mq.size.width > mq.size.height && box.maxWidth >= 600;
      final side = wide && (_side ?? box.maxWidth >= 1100);
      final column = Column(children: [
        _topRow(wide: wide, side: side),
        _crumbRow(wide: wide, side: side, width: box.maxWidth),
        Expanded(child: _editor()),
        if (keyboard) CodeEditorTapRegion(child: CodeKeyRow(target: _target, onChanged: () => setState(() {}))),
      ]);
      if (!side) return column;
      return Row(children: [
        Expanded(child: column),
        SizedBox(width: 290, child: Padding(padding: const EdgeInsets.all(4), child: _SidePanel(editor: this))),
      ]);
    });
  }
}

/// Landscape and desktop: Problems and the Library beside the code.
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.editor});
  final CppEditorState editor;

  @override
  Widget build(BuildContext context) {
    final e = editor;
    final library = e._sideLibrary;
    Widget tab(String id, String label, bool on, bool toLibrary) => Expanded(
          child: InkWell(
            key: ValueKey(id),
            onTap: () => e._showSide(library: toLibrary),
            child: Container(
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? Neon.green : Colors.transparent, width: 2))),
              child: Text(label, style: TextStyle(fontSize: 12, color: on ? Neon.text : Neon.dim)),
            ),
          ),
        );
    final count = e.w.diagnostics.length;
    return GlassPanel(
      child: Column(children: [
        Row(children: [
          tab('side problems', count == 0 ? 'Problems' : 'Problems $count', !library, false),
          tab('side library', 'Library', library, true),
        ]),
        Expanded(
          child: library ? CppLibraryView(onInsert: e.insert) : ProblemsList(workbench: e.w, onJump: e.jumpTo),
        ),
      ]),
    );
  }
}

/// The key row's target: the current file's controller.
class _EditorTarget implements CodeKeyTarget {
  _EditorTarget(this.editor);
  final CppEditorState editor;

  CodeLineEditingController get c => editor.view.controller;

  @override
  void insert(String text) => c.replaceSelection(text);

  @override
  void indent() => c.applyIndent();

  @override
  void moveCursor({int columns = 0, int lines = 0, bool select = false}) {
    void step(AxisDirection d, int n) {
      for (var i = 0; i < n.abs().clamp(0, 400); i++) {
        select ? c.extendSelection(d) : c.moveCursor(d);
      }
    }

    step(columns < 0 ? AxisDirection.left : AxisDirection.right, columns);
    step(lines < 0 ? AxisDirection.up : AxisDirection.down, lines);
    c.makeCursorVisible();
  }

  @override
  void undo() => c.undo();
  @override
  void redo() => c.redo();
  @override
  bool get canUndo => c.canUndo;
  @override
  bool get canRedo => c.canRedo;
}

/// Line numbers, with a pink (error) or yellow (warning) mark beside lines that have problems.
class _GutterPainter extends CustomPainter {
  _GutterPainter(this.paragraphs, this.view, this.workbench, this.path) : super(repaint: paragraphs);

  final ValueNotifier<CodeIndicatorValue?> paragraphs;
  final CppFileView view;
  final CppWorkbench workbench;
  final String path;

  @override
  void paint(Canvas canvas, Size size) {
    final value = paragraphs.value;
    if (value == null) return;
    final focused = view.controller.selection.extentIndex;
    for (final p in value.paragraphs) {
      final marks = view.marks[p.index];
      final y = p.offset.dy;
      final h = p.preferredLineHeight;
      if (marks != null) {
        final error = marks.any((m) => m.severity == CppSeverity.error);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(1, y + 2, 3, h - 4), const Radius.circular(1.5)),
          Paint()..color = error ? Neon.pink : Neon.yellow,
        );
      }
      final tp = TextPainter(
        text: TextSpan(
          text: '${p.index + 1}',
          style: TextStyle(
              fontFamily: Neon.mono,
              fontSize: 10.5,
              color: p.index == focused ? Neon.text : Neon.dim.withValues(alpha: 0.7)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 6, y + (h - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(_GutterPainter old) => true;
}

/// Over the code: each problem's message after its line (dim), the focused one in full under its line, and the
/// effect's knob values after the line that declares each knob while the effect is on a track.
class _HintPainter extends CustomPainter {
  _HintPainter(this.paragraphs, this.view, this.workbench, this.path, this.focus) : super(repaint: paragraphs);

  final ValueNotifier<CodeIndicatorValue?> paragraphs;
  final CppFileView view;
  final CppWorkbench workbench;
  final String path;
  final CppDiagnostic? focus;

  @override
  void paint(Canvas canvas, Size size) {
    final value = paragraphs.value;
    if (value == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final byLine = <int, CppDiagnostic>{};
    for (final d in workbench.diagnostics) {
      if (d.file != path) continue;
      final existing = byLine[d.line - 1];
      if (existing == null || (!existing.isError && d.isError)) byLine[d.line - 1] = d;
    }
    final knobs = _knobLines();
    final cursorLine = view.controller.selection.extentIndex;
    final under = focus != null && focus!.file == path ? focus!.line - 1 : (byLine.containsKey(cursorLine) ? cursorLine : -1);
    for (final p in value.paragraphs) {
      final h = p.preferredLineHeight;
      final x = p.offset.dx + p.width + 14;
      final d = byLine[p.index];
      if (d != null && p.index != under) {
        _text(canvas, d.message, Offset(x, p.offset.dy), h, size.width - x - 4,
            (d.isError ? Neon.pink : Neon.yellow).withValues(alpha: 0.7));
      } else if (knobs[p.index] case final String hint) {
        _text(canvas, hint, Offset(x, p.offset.dy), h, size.width - x - 4, Neon.blue.withValues(alpha: 0.75));
      }
      if (p.index == under) {
        final shown = d ?? focus!;
        // The message on one line under its line, over a band so it reads above the code below.
        final top = p.offset.dy + h;
        final band = Rect.fromLTWH(0, top, size.width, h);
        canvas.drawRect(band, Paint()..color = Neon.bg.withValues(alpha: 0.92));
        canvas.drawRect(Rect.fromLTWH(0, top, 2, h), Paint()..color = shown.isError ? Neon.pink : Neon.yellow);
        _text(canvas, '${shown.isError ? 'error' : 'warning'}: ${shown.message}', Offset(math.max(8, p.offset.dx), top), h,
            size.width - 12, shown.isError ? Neon.pink : Neon.yellow);
      }
    }
    canvas.restore();
  }

  Map<int, String> _knobLines() {
    final info = workbench.info;
    if (info == null || workbench.uses.isEmpty) return const {};
    final lines = view.controller.codeLines;
    final out = <int, String>{};
    for (final p in info.parameters) {
      final live = workbench.liveValue(p.id);
      if (live == null) continue;
      final needle = '"${p.id}"';
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].text.contains(needle)) {
          out[i] = '◉ ${formatKnob(live)}${p.unit.isEmpty ? '' : ' ${p.unit}'}';
          break;
        }
      }
    }
    return out;
  }

  static void _text(Canvas canvas, String text, Offset at, double lineHeight, double maxWidth, Color color) {
    if (maxWidth < 24) return;
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontFamily: Neon.mono, fontSize: 10.5, color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    tp.paint(canvas, Offset(at.dx, at.dy + (lineHeight - tp.height) / 2));
  }

  @override
  bool shouldRepaint(_HintPainter old) => true;
}

/// ▶ Build, labelled: a ring while building, green with a check once built and unchanged since.
class _BuildButton extends StatelessWidget {
  const _BuildButton({required this.phase, required this.onBuild});
  final CppBuildPhase phase;
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    final building = phase == CppBuildPhase.building;
    final built = phase == CppBuildPhase.built;
    final color = built ? Neon.green : (phase == CppBuildPhase.failed ? Neon.pink : Neon.text);
    return Tooltip(
      message: building ? 'Building…' : 'Build and load it (Ctrl+B)',
      child: Pressable(
        glow: Neon.green,
        child: OutlinedButton.icon(
          key: const ValueKey('build'),
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            backgroundColor: built ? Neon.green.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.04),
            side: BorderSide(color: color.withValues(alpha: built ? 0.8 : 0.45)),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(left: 6, right: 9),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          ),
          onPressed: building
              ? null
              : () {
                  Haptics.tap();
                  onBuild();
                },
          icon: building
              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: Neon.green))
              : Icon(built ? Icons.check : Icons.play_arrow, size: 17),
          label: Text(building ? 'Building' : 'Build', style: Neon.code(size: 12, color: building ? Neon.dim : color)),
        ),
      ),
    );
  }
}

/// What happened, in a word or two, and where the result went: Building…, ✓ Built · on Pad (tap: show it in
/// Arrange) with "Try it", the error count (tap: the next error), a build that failed without a line (tap: Problems),
/// Checking…, or Not built.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.editor, required this.wide});
  final CppEditorState editor;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final w = editor.w;
    final errors = w.errorCount;
    final warnings = w.warningCount;
    final uses = w.uses;
    final layers = [for (final u in uses) u.layer?.name ?? 'Master'];
    String text;
    Color color;
    IconData? icon;
    VoidCallback? onTap;
    var tip = '';
    var tryIt = false;
    switch (w.phase) {
      case CppBuildPhase.building:
        text = 'Building…';
        color = Neon.dim;
      case CppBuildPhase.failed when errors == 0:
        text = 'Build failed';
        color = Neon.pink;
        icon = Icons.report_gmailerrorred;
        tip = w.buildMessage ?? 'Build failed';
        onTap = () => editor._problems(wide);
      case _ when errors > 0:
        text = '$errors error${errors == 1 ? '' : 's'}';
        color = Neon.pink;
        icon = Icons.error;
        tip = 'Go to the next error (F8)';
        onTap = editor.jumpToNextError;
      case CppBuildPhase.built:
        color = Neon.green;
        icon = Icons.check_circle;
        tip = w.buildMessage ?? 'Built and loaded';
        if (layers.isEmpty) {
          text = 'Built';
          tryIt = true;
        } else {
          text = 'Built · on ${layers.first}${layers.length > 1 ? ' +${layers.length - 1}' : ''}';
          final first = uses.first.layer;
          final sections = SectionController.maybeOf(context);
          if (first != null && sections != null) onTap = () => sections.focusLayer(first.id);
          tip = '${w.buildMessage ?? 'Built'}: playing on ${layers.join(', ')}. Tap to show it.';
        }
      case CppBuildPhase.idle when w.checking || w.checkScheduled:
        text = 'Checking…';
        color = Neon.dim;
      case _ when warnings > 0:
        text = '$warnings warning${warnings == 1 ? '' : 's'}';
        color = Neon.yellow;
        icon = Icons.warning_amber;
        onTap = () => editor._problems(wide);
      case _:
        text = w.builds > 0 ? 'Edited · build again' : 'Not built yet';
        color = Neon.dim;
        tip = 'Build it to hear it (Ctrl+B)';
        onTap = editor.runBuild;
    }
    final building = w.phase == CppBuildPhase.building;
    final chip = InkWell(
      key: const ValueKey('build status'),
      borderRadius: BorderRadius.circular(10),
      onTap: onTap == null
          ? null
          : () {
              Haptics.tap();
              onTap!();
            },
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (building)
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Neon.green))
          else if (icon != null)
            Icon(icon, size: 12, color: color),
          if (building || icon != null) const SizedBox(width: 4),
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: Neon.code(size: 10.5, color: color)),
          ),
        ]),
      ),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: tip.isEmpty ? chip : Tooltip(message: tip, child: chip)),
      if (tryIt || (w.phase == CppBuildPhase.built && uses.isNotEmpty))
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Pressable(
            child: TextButton.icon(
              key: const ValueKey('try on track'),
              style: TextButton.styleFrom(
                foregroundColor: Neon.green,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: editor.tryOnTrack,
              icon: const Icon(Icons.queue_play_next, size: 14),
              label: Text(tryIt ? (MediaQuery.sizeOf(context).width >= 480 ? 'Try it on a track' : 'Try it') : 'Try on…',
                  style: const TextStyle(fontSize: 11)),
            ),
          ),
        ),
    ]);
  }
}
