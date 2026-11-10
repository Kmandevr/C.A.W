// The Build section: its open tabs (C++ effects in the C++ editor, .caw modules in the module Builder) and a start view.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/cpp_workbench.dart';
import '../builder_screen.dart';
import '../frame/sections.dart';
import '../theme.dart';
import 'cpp_editor.dart';

class BuildSection extends StatefulWidget {
  const BuildSection({super.key, required this.state});
  final AppState state;

  @override
  State<BuildSection> createState() => _BuildSectionState();
}

class _BuildSectionState extends State<BuildSection> {
  /// Without a SectionScope (tests, a screen on its own) the section keeps its own tabs.
  SectionController? _own;
  bool _start = false; // the start view over open tabs (from the file menu)

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

  void _open(SectionController c, BuildTab t) {
    setState(() => _start = false);
    c.openBuild(t);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, s]),
      builder: (context, _) {
        final tabs = controller.buildTabs.where(_exists).toList();
        final active = tabs.contains(controller.activeBuildTab) ? controller.activeBuildTab : tabs.lastOrNull;
        if (active == null || _start) {
          return _StartView(
            state: s,
            onOpen: (t) => _open(controller, t),
            onBack: tabs.isEmpty ? null : () => setState(() => _start = false),
          );
        }
        final menu = BuildTabsMenu(
          entries: [
            for (final t in tabs) (tab: t, name: _name(t), active: t == active, cpp: t.kind == BuildTabKind.cpp),
          ],
          onSelect: (t) => controller.activateBuild(t as BuildTab),
          onClose: (t) => controller.closeBuild(t as BuildTab),
          onStart: () => setState(() => _start = true),
        );
        if (active.kind == BuildTabKind.cpp) {
          final doc = s.cppComponent(active.id)!;
          return CppEditor(key: ValueKey('cpp ${doc.id}'), workbench: s.cppWorkbench(doc.id), tabs: menu);
        }
        return _CawTab(state: s, moduleId: active.id, menu: menu);
      },
    );
  }
}

/// A .caw module tab: the module Builder, with the same thin tab row above it.
class _CawTab extends StatelessWidget {
  const _CawTab({required this.state, required this.moduleId, required this.menu});
  final AppState state;
  final String moduleId;
  final BuildTabsMenu menu;

  @override
  Widget build(BuildContext context) {
    if (state.selectedModuleId != moduleId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (state.selectedModuleId != moduleId && state.project.module(moduleId) != null) state.selectModule(moduleId);
      });
    }
    final name = menu.entries.where((e) => e.active).firstOrNull?.name ?? moduleId;
    return Column(children: [
      SizedBox(
        height: 36,
        child: Row(children: [
          PopupMenuButton<VoidCallback>(
            key: const ValueKey('tab menu'),
            tooltip: 'Build tabs',
            onSelected: (f) => f(),
            itemBuilder: (c) => [
              for (final t in menu.entries)
                PopupMenuItem(
                  height: 34,
                  value: () => menu.onSelect(t.tab),
                  child: Row(children: [
                    Icon(t.cpp ? Icons.code : Icons.graphic_eq, size: 16, color: t.active ? Neon.green : Neon.dim),
                    const SizedBox(width: 8),
                    Expanded(child: Text(t.name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              PopupMenuItem(
                height: 34,
                value: () => menu.onClose(menu.entries.firstWhere((e) => e.active).tab),
                child: const Text('Close this tab', style: TextStyle(fontSize: 13)),
              ),
              PopupMenuItem(height: 34, value: menu.onStart, child: const Text('Start page…', style: TextStyle(fontSize: 13))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const Icon(Icons.arrow_drop_down, size: 18),
              ]),
            ),
          ),
        ]),
      ),
      Expanded(child: BuilderScreen(state: state)),
    ]);
  }
}

/// No tab open: New effect, and the project's C++ effects and .caw modules to open.
class _StartView extends StatelessWidget {
  const _StartView({required this.state, required this.onOpen, this.onBack});
  final AppState state;
  final ValueChanged<BuildTab> onOpen;
  final VoidCallback? onBack;

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
      SizedBox(
        height: 36,
        child: Row(children: [
          if (onBack != null) IconButton(iconSize: 18, tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: onBack),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('Build', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('new effect'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New effect'),
            onPressed: () {
              final doc = state.newCppEffect();
              onOpen(BuildTab(BuildTabKind.cpp, doc.componentId));
            },
          ),
        ),
      ),
      heading('C++ effects'),
      if (cpp.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text('None yet. A new effect starts as a stereo pass-through you can build and play at once.',
              style: TextStyle(fontSize: 12, color: Neon.dim)),
        ),
      for (final c in cpp)
        row('open cpp ${c.componentId}', Icons.code, c.name, '${c.files.length} files',
            () => onOpen(BuildTab(BuildTabKind.cpp, c.componentId))),
      if (modules.isNotEmpty) heading('.caw modules'),
      for (final m in modules)
        row('open caw ${m.id}', Icons.graphic_eq, m.name, state.info[m.id]?.kind ?? '',
            () => onOpen(BuildTab(BuildTabKind.caw, m.id))),
    ]);
  }
}
