// The Build section, laid out like VS Code: an explorer (the Files browser), one slim row of open tabs with + New, and the editor.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/engine.dart' show Template;
import '../../model/app_state.dart';
import '../../model/cpp_workbench.dart';
import '../../model/files_catalog.dart';
import '../../model/pattern_doc.dart';
import '../builder_screen.dart';
import '../file_manager_screen.dart';
import '../frame/frame_widgets.dart' show AwakeListenableBuilder;
import '../frame/sections.dart';
import '../pattern_fields.dart';
import '../glass.dart';
import '../theme.dart';
import 'cpp_editor.dart';

/// Build's tabs are project C++ components (the C++ editor) and .caw modules and patterns (the module Builder).
/// Wide screens (landscape or desktop) show the explorer as a sidebar that can be dragged wider or hidden
/// (Ctrl+Shift+E); phones open it as a drawer from ☰. Ctrl+PageDown / Ctrl+PageUp switch tabs and
/// Ctrl+Shift+N opens + New.
class BuildSection extends StatefulWidget {
  const BuildSection({super.key, required this.state});
  final AppState state;

  @override
  State<BuildSection> createState() => _BuildSectionState();
}

class _BuildSectionState extends State<BuildSection> {
  /// Without a SectionScope (tests, a screen on its own) the section keeps its own tabs.
  SectionController? _own;
  final _scaffold = GlobalKey<ScaffoldState>();
  final _newButton = GlobalKey();

  /// The sidebar on a wide screen: null until toggled (shown when there is room for it).
  bool? _explorer;
  double _explorerWidth = 250;

  AppState get s => widget.state;

  SectionController _controller(BuildContext context) => SectionController.maybeOf(context) ?? (_own ??= SectionController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  bool _exists(BuildTab t) =>
      t.kind == BuildTabKind.cpp ? s.cppComponent(t.id) != null : s.project.modules.any((m) => m.id == t.id);

  String _name(BuildTab t) => t.kind == BuildTabKind.cpp
      ? s.cppComponent(t.id)?.name ?? t.id
      : s.project.modules.where((m) => m.id == t.id).firstOrNull?.name ?? t.id;

  /// Where the explorer stands for [t]: the component's files, the patterns, or the module's folder.
  String _folderFor(BuildTab? t) {
    if (t == null) return 'code';
    if (t.kind == BuildTabKind.cpp) {
      final c = s.cppComponent(t.id);
      return c == null ? 'code/cpp' : 'code/cpp/${c.id}';
    }
    if (s.isPattern(t.id)) return 'audio/patterns';
    final f = s.project.module(t.id)?.folderPath ?? '';
    return f.isNotEmpty && s.project.libraryFolders.contains(f) ? 'code/caw/$f' : 'code/caw';
  }

  /// The explorer item that is open in the editor.
  String? _activeKey(BuildTab? t) {
    if (t == null) return null;
    if (t.kind == BuildTabKind.caw) return 'mod:${t.id}';
    final c = s.cppComponent(t.id);
    return c == null ? null : 'file:${c.id}/${s.cppWorkbench(c.id).currentFile}';
  }

  void _open(SectionController c, BuildTab t) => c.openBuild(t);

  /// A tap in the explorer: a source file opens in its component's tab, a module or pattern in its own.
  void _openAsset(SectionController c, FileAsset a) {
    final cpp = a.cpp;
    if (cpp != null) {
      _open(c, BuildTab(BuildTabKind.cpp, cpp.componentId));
      final path = a.filePath;
      if (path != null) s.cppWorkbench(cpp.id).selectFile(path);
    } else if (a.module != null) {
      s.selectModule(a.module!.id);
      _open(c, BuildTab(BuildTabKind.caw, a.module!.id));
    } else {
      return; // a built-in: nothing to edit (its docs are in the Library)
    }
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.of(context).pop();
  }

  void _toggleExplorer(bool wide) {
    if (wide) {
      setState(() => _explorer = !(_explorer ?? true));
    } else {
      _scaffold.currentState?.openDrawer();
    }
  }

  void _step(SectionController c, List<BuildTab> tabs, BuildTab? active, int d) {
    if (tabs.isEmpty) return;
    final i = active == null ? 0 : tabs.indexOf(active);
    c.activateBuild(tabs[(i + d) % tabs.length]);
  }

  // ---------- + New ----------

  /// + New: broad starting points only (owner, 2026-11-10). A text file goes into the open C++ component.
  Future<void> _newMenu(SectionController c, BuildTab? active) async {
    final box = _newButton.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final at = box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay);
    final cpp = active?.kind == BuildTabKind.cpp ? s.cppComponent(active!.id) : null;
    PopupMenuItem<String> item(String id, IconData icon, Color color, String label, String detail, {bool enabled = true}) =>
        PopupMenuItem(
          key: ValueKey('new $id'),
          value: id,
          enabled: enabled,
          height: 44,
          child: Row(children: [
            Icon(icon, size: 18, color: enabled ? color : Neon.line),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: const TextStyle(fontSize: 13)),
                Text(detail, style: const TextStyle(fontSize: 11, color: Neon.dim), overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        );
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      constraints: const BoxConstraints(minWidth: 230, maxWidth: 280),
      color: Neon.panel,
      items: [
        item('pattern', Icons.piano, Neon.yellow, 'Pattern', 'Notes for a track to play'),
        item('instrument', Icons.piano_outlined, Neon.green, 'Instrument', 'C++: plays notes (a polyphonic sine)'),
        item('effect', Icons.tune, Neon.pink, 'Effect', 'C++: changes the sound (a pass-through)'),
        item('text', Icons.notes, Neon.blue, 'Text file',
            cpp == null ? 'Open a C++ component to add one' : 'A file in ${cpp.name}: notes, a header…', enabled: cpp != null),
      ],
    );
    if (pick == null || !mounted) return;
    switch (pick) {
      case 'pattern':
        // With its header at once (the header is fields, not text, so the file needs one), named like the module.
        final id = s.addModule(Template('Pattern.caw', PatternDoc.blank().serialize()));
        final m = s.project.module(id)!;
        m.source = m.runSource = editPatternHeader(m.source, m.name, name: m.name) ?? m.source;
        _open(c, BuildTab(BuildTabKind.caw, id));
      case 'instrument' || 'effect':
        final doc = s.newCppEffect(instrument: pick == 'instrument');
        _open(c, BuildTab(BuildTabKind.cpp, doc.componentId));
      case 'text':
        if (cpp != null) await _newTextFile(s.cppWorkbench(cpp.id));
    }
  }

  Future<void> _newTextFile(CppWorkbench w) async {
    final controller = TextEditingController(text: 'notes.txt');
    String? error;
    await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          void done() {
            final p = controller.text.trim();
            if (w.addFile(p)) {
              Navigator.pop(context, p);
            } else {
              setDialog(() => error = w.texts.containsKey(p) ? 'That file exists' : 'A name like notes.txt or src/tables.hpp');
            }
          }

          return AlertDialog(
            title: Text('New file in ${w.name}'),
            content: TextField(
              key: const ValueKey('new file name'),
              controller: controller,
              autofocus: true,
              style: Neon.code(size: 13),
              decoration: InputDecoration(labelText: 'File name', errorText: error),
              onSubmitted: (_) => done(),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              TextButton(key: const ValueKey('create file'), onPressed: done, child: const Text('Create')),
            ],
          );
        },
      ),
    );
    // Not disposed here: the dialog's field still listens to it while the dialog animates out.
  }

  // ---------- layout ----------

  @override
  Widget build(BuildContext context) {
    final controller = _controller(context);
    // Asleep while Build is behind another section (frame_widgets.dart).
    return AwakeListenableBuilder(
      listenable: Listenable.merge([controller, s]),
      builder: (context, _) {
        final tabs = controller.buildTabs.where(_exists).toList();
        final active = tabs.contains(controller.activeBuildTab) ? controller.activeBuildTab : tabs.lastOrNull;
        final activeCpp = active?.kind == BuildTabKind.cpp ? s.cppComponent(active!.id) : null;
        final workbench = activeCpp == null ? null : s.cppWorkbench(activeCpp.id);
        return LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 720 && (box.maxWidth > box.maxHeight || box.maxWidth >= 900);
          final showExplorer = wide && (_explorer ?? box.maxWidth >= 900);
          // The tab strip follows the open component's current file (its label shows it).
          final strip = AwakeListenableBuilder(
            listenable: workbench ?? s,
            builder: (context, _) => _TabStrip(
              tabs: [
                for (final t in tabs)
                  (
                    tab: t,
                    label: t == active && workbench != null
                        ? '${_name(t)} · ${workbench.currentFile.split('/').last}'
                        : _name(t),
                    icon: t.kind == BuildTabKind.cpp ? Icons.code : (s.isPattern(t.id) ? Icons.piano : Icons.graphic_eq),
                  ),
              ],
              active: active,
              explorerOpen: showExplorer,
              newButton: _newButton,
              wideNew: box.maxWidth >= 520,
              onExplorer: () => _toggleExplorer(wide),
              onSelect: controller.activateBuild,
              onClose: controller.closeBuild,
              onNew: () => _newMenu(controller, active),
            ),
          );
          final Widget body;
          if (active == null) {
            body = Column(children: [
              SizedBox(height: 36, child: strip),
              Expanded(child: _StartView(state: s, onOpen: (t) => _open(controller, t))),
            ]);
          } else if (activeCpp != null) {
            body = CppEditor(key: ValueKey('cpp ${activeCpp.id}'), workbench: workbench!, bar: strip);
          } else {
            body = _CawTab(state: s, moduleId: active.id, bar: strip);
          }
          final explorer = FileManagerScreen(
            key: const ValueKey('build explorer'),
            state: s,
            explorer: true,
            folder: _folderFor(active),
            activeKey: _activeKey(active),
            onOpenAsset: (a) => _openAsset(controller, a),
          );
          final Widget layout;
          if (wide) {
            final maxWidth = math.max(180.0, box.maxWidth * 0.5);
            layout = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (showExplorer) ...[
                SizedBox(
                  width: _explorerWidth.clamp(180.0, maxWidth),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
                    child: GlassPanel(child: explorer),
                  ),
                ),
                // Drag to resize, like VS Code's sash.
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: const ValueKey('explorer sash'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) =>
                        setState(() => _explorerWidth = (_explorerWidth + d.delta.dx).clamp(180.0, maxWidth)),
                    child: const SizedBox(width: 8),
                  ),
                ),
              ],
              Expanded(child: body),
            ]);
          } else {
            layout = Scaffold(
              key: _scaffold,
              backgroundColor: Colors.transparent,
              // The frame above handles the soft keyboard (the editor reads it from the window).
              resizeToAvoidBottomInset: false,
              drawer: Drawer(
                width: math.min(300.0, box.maxWidth * 0.85),
                backgroundColor: Neon.panel.withValues(alpha: Glass.active ? 0.92 : 1),
                child: SafeArea(child: explorer),
              ),
              body: body,
            );
          }
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true): () => _toggleExplorer(wide),
              const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): () => _newMenu(controller, active),
              const SingleActivator(LogicalKeyboardKey.pageDown, control: true): () => _step(controller, tabs, active, 1),
              const SingleActivator(LogicalKeyboardKey.pageUp, control: true): () => _step(controller, tabs, active, -1),
            },
            child: layout,
          );
        });
      },
    );
  }
}

typedef _TabEntry = ({BuildTab tab, String label, IconData icon});

/// ☰ (the explorer), the open tabs (tap to switch, × to close) and + New, in 36 dp.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.active,
    required this.explorerOpen,
    required this.newButton,
    required this.wideNew,
    required this.onExplorer,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
  });

  final List<_TabEntry> tabs;
  final BuildTab? active;
  final bool explorerOpen, wideNew;
  final GlobalKey newButton;
  final VoidCallback onExplorer, onNew;
  final ValueChanged<BuildTab> onSelect, onClose;

  @override
  Widget build(BuildContext context) => Row(children: [
        IconButton(
          key: const ValueKey('explorer'),
          tooltip: 'Explorer (Ctrl+Shift+E)',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          onPressed: onExplorer,
          icon: Icon(Icons.folder_open_outlined, color: explorerOpen ? Neon.blue : Neon.dim),
        ),
        Expanded(
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final t in tabs) _Tab(entry: t, active: t.tab == active, onSelect: onSelect, onClose: onClose),
          ]),
        ),
        Padding(
          key: const ValueKey('new menu'),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: wideNew
              ? TextButton.icon(
                  key: newButton,
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 30)),
                  onPressed: onNew,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New', style: TextStyle(fontSize: 12.5)),
                )
              : IconButton(
                  key: newButton,
                  tooltip: 'New (Ctrl+Shift+N)',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 34, height: 36),
                  padding: EdgeInsets.zero,
                  onPressed: onNew,
                  icon: const Icon(Icons.add, color: Neon.text),
                ),
        ),
      ]);
}

class _Tab extends StatelessWidget {
  const _Tab({required this.entry, required this.active, required this.onSelect, required this.onClose});
  final _TabEntry entry;
  final bool active;
  final ValueChanged<BuildTab> onSelect, onClose;

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey('tab ${entry.tab.kind.name} ${entry.tab.id}'),
        onTap: () => onSelect(entry.tab),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 200),
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(
            color: active ? Neon.text.withValues(alpha: 0.05) : null,
            border: Border(bottom: BorderSide(color: active ? Neon.green : Colors.transparent, width: 2)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(entry.icon, size: 14, color: active ? Neon.green : Neon.dim),
            const SizedBox(width: 5),
            Flexible(
              child: Text(entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: active ? Neon.text : Neon.dim, fontWeight: active ? FontWeight.w600 : null)),
            ),
            InkResponse(
              key: ValueKey('close ${entry.tab.id}'),
              radius: 14,
              onTap: () => onClose(entry.tab),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                child: Icon(Icons.close, size: 13, color: active ? Neon.dim : Neon.line),
              ),
            ),
          ]),
        ),
      );
}

/// A .caw module or pattern tab: the module Builder under the same slim tab row.
class _CawTab extends StatelessWidget {
  const _CawTab({required this.state, required this.moduleId, required this.bar});
  final AppState state;
  final String moduleId;
  final Widget bar;

  @override
  Widget build(BuildContext context) {
    if (state.selectedModuleId != moduleId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (state.selectedModuleId != moduleId && state.project.module(moduleId) != null) state.selectModule(moduleId);
      });
    }
    return Column(children: [
      SizedBox(height: 36, child: bar),
      Expanded(child: BuilderScreen(state: state, embedded: true)),
    ]);
  }
}

/// No tab open: the broad starting points and the project's C++ components and .caw modules to open.
class _StartView extends StatelessWidget {
  const _StartView({required this.state, required this.onOpen});
  final AppState state;
  final ValueChanged<BuildTab> onOpen;

  @override
  Widget build(BuildContext context) {
    final cpp = state.project.cppComponents;
    final modules = state.project.modules;
    Widget row(String id, IconData icon, String title, String subtitle, VoidCallback onTap) => InkWell(
          key: ValueKey(id),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(children: [
              Icon(icon, size: 18, color: Neon.dim),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
              Text(subtitle, style: TextStyle(fontSize: 11, color: Neon.dim)),
            ]),
          ),
        );
    Widget heading(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
          child: Text(t.toUpperCase(),
              style: const TextStyle(fontSize: 10.5, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: Neon.dim)),
        );
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Wrap(spacing: 8, runSpacing: 6, children: [
          FilledButton.icon(
            key: const ValueKey('new effect'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New effect'),
            onPressed: () {
              final doc = state.newCppEffect();
              onOpen(BuildTab(BuildTabKind.cpp, doc.componentId));
            },
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('new instrument'),
            icon: const Icon(Icons.piano_outlined, size: 18),
            label: const Text('New instrument'),
            onPressed: () {
              final doc = state.newCppEffect(instrument: true);
              onOpen(BuildTab(BuildTabKind.cpp, doc.componentId));
            },
          ),
        ]),
      ),
      heading('C++ components'),
      if (cpp.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text('None yet. A new effect starts as a stereo pass-through you can build and play at once.',
              style: TextStyle(fontSize: 12, color: Neon.dim)),
        ),
      for (final c in cpp)
        row('open cpp ${c.componentId}', Icons.code, c.name, '${c.files.length} files',
            () => onOpen(BuildTab(BuildTabKind.cpp, c.componentId))),
      if (modules.isNotEmpty) heading('.caw modules and patterns'),
      for (final m in modules)
        row('open caw ${m.id}', state.isPattern(m.id) ? Icons.piano : Icons.graphic_eq, m.name, state.info[m.id]?.kind ?? '',
            () {
          state.selectModule(m.id);
          onOpen(BuildTab(BuildTabKind.caw, m.id));
        }),
    ]);
  }
}
