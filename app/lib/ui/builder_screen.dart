// Builder: pick or create a module, edit its code, hear it, Run to hot-swap it, and tweak its params.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'code_editor.dart';
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';

class BuilderScreen extends StatefulWidget {
  const BuilderScreen({super.key, required this.state});
  final AppState state;

  @override
  State<BuilderScreen> createState() => _BuilderScreenState();
}

class _BuilderScreenState extends State<BuilderScreen> {
  final CodeController _code = CodeController();
  final FocusNode _focus = FocusNode();
  String? _shownId;

  AppState get s => widget.state;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _syncEditor(ModuleDoc? m) {
    if (m?.id == _shownId) return;
    _shownId = m?.id;
    _code.text = m?.source ?? '';
  }

  Future<void> _run(ModuleDoc m) async {
    final info = await s.run(m.id);
    if (!mounted || info == null) return;
    if (!info.ok) _code.jumpTo(info.line, info.col);
  }

  Future<void> _newModule() async {
    final t = await showModalBottomSheet<Template>(
      context: context,
      backgroundColor: Neon.panel,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Start from a template', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          for (final t in s.templates)
            ListTile(
              leading: Icon(headerValue(t.source, 'kind') == 'effect' ? Icons.tune : Icons.graphic_eq,
                  color: headerValue(t.source, 'kind') == 'effect' ? Neon.pink : Neon.green),
              title: Text(headerValue(t.source, 'name') ?? t.file),
              subtitle: Text(headerValue(t.source, 'summary') ?? '', style: const TextStyle(color: Neon.dim)),
              onTap: () => Navigator.pop(context, t),
            ),
        ]),
      ),
    );
    if (t != null) s.addModule(t);
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
          const Expanded(child: Center(child: Text('No modules yet: tap + to start from a template'))),
        ]);
      }
      final info = s.info[m.id];
      final color = s.isEffect(m.id) ? Neon.pink : Neon.green;
      final editor = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _run(m),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _run(m),
        },
        child: CodeField(controller: _code, focus: _focus, onChanged: (v) => s.editSource(m.id, v)),
      );
      final status = _StatusLine(module: m, info: info, onJump: () => _code.jumpTo(info!.line, info.col));
      final header = Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
          child: Text(s.isEffect(m.id) ? 'EFFECT' : 'GENERATOR',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: () => _rename(m),
            child: Text(m.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        ),
        Tooltip(
          message: 'Hear only this module',
          child: FilterChip(
            label: const Text('Solo preview'),
            selected: s.previewOnly,
            onSelected: s.setPreviewOnly,
            selectedColor: Neon.blue.withValues(alpha: 0.25),
            checkmarkColor: Neon.blue,
          ),
        ),
        PopupMenuButton<String>(
          onSelected: (v) => v == 'rename' ? _rename(m) : _delete(m),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ]);
      final scope = NeonPanel(
        color: color,
        padding: const EdgeInsets.all(6),
        child: ScopeView(
            state: s, index: s.previewOnly ? Engine.auditionIndex : Engine.masterIndex, color: color, height: wide ? 140 : 88),
      );
      final params = _Params(state: s, module: m, info: info);
      final runBar = Row(children: [
        Expanded(child: SymbolRow(onInsert: (t) {
          _code.insert(t);
          s.editSource(m.id, _code.text);
          _focus.requestFocus();
        })),
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

      if (wide) {
        return Column(children: [
          picker,
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
                    Expanded(child: SingleChildScrollView(child: editor)),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: ListView(children: [scope, params])),
              ]),
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: runBar),
        ]);
      }
      return Column(children: [
        picker,
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            header,
            const SizedBox(height: 8),
            scope,
            const SizedBox(height: 8),
            status,
            const SizedBox(height: 6),
            editor,
            params,
            const SizedBox(height: 12),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(12, 6, 12, 10), child: runBar),
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
                avatar: Icon(state.isEffect(m.id) ? Icons.tune : Icons.graphic_eq,
                    size: 16, color: state.isEffect(m.id) ? Neon.pink : Neon.green),
                label: Text(m.name + (m.edited ? ' •' : '')),
                selected: m.id == state.selectedModuleId,
                onSelected: (_) => state.selectModule(m.id),
                selectedColor: (state.isEffect(m.id) ? Neon.pink : Neon.green).withValues(alpha: 0.2),
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
  const _Params({required this.state, required this.module, required this.info});
  final AppState state;
  final ModuleDoc module;
  final ModuleInfo? info;

  @override
  Widget build(BuildContext context) {
    final params = info?.params ?? const <ParamInfo>[];
    if (params.isEmpty && (info?.exports.isEmpty ?? true) && (info?.warnings.isEmpty ?? true)) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('Add `param name = 0.5 in 0..1` to get a slider.', style: TextStyle(color: Neon.dim, fontSize: 13)),
      );
    }
    final color = state.isEffect(module.id) ? Neon.pink : Neon.green;
    final i = info;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Heading('Controls'),
      ParamGroups(
        params: params,
        color: color,
        valueOf: (p) => p.global ? state.globalValue(p) : (module.params[p.name] ?? p.defaultValue),
        onChanged: (p, v) => p.global ? state.setGlobal(p.name, v) : state.setParam(module.id, p.name, v),
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
