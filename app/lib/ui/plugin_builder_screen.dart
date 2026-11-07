// Dedicated native-module development workflow. Binary plugin targets are shown only when a backend exists.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';

class PluginBuilderScreen extends StatefulWidget {
  const PluginBuilderScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  State<PluginBuilderScreen> createState() => _PluginBuilderScreenState();
}

class _PluginBuilderScreenState extends State<PluginBuilderScreen> {
  bool _guided = true;
  String? _moduleId;
  String? _templateFile;
  String? _message;
  bool _error = false;
  bool _busy = false;

  AppState get s => widget.state;

  List<ModuleDoc> get _modules => s.project.modules
      .where((m) => s.isGenerator(m.id) || s.isEffect(m.id)).toList();

  List<Template> get _templates => s.templates.where((t) {
    final kind = headerValue(t.source, 'kind') ?? 'generator';
    return kind == 'generator' || kind == 'effect';
  }).toList();

  Future<void> _createFromTemplate() async {
    final template = _templates.where((t) => t.file == _templateFile).firstOrNull;
    if (template == null) return;
    final id = s.addModule(template);
    setState(() { _moduleId = id; _guided = false; _message = 'Created a new project module.'; _error = false; });
    await _validate();
  }

  Future<void> _cloneExisting(ModuleDoc module) async {
    final id = module.source.isEmpty
      ? s.addBlankModule(s.kindOf(module.id))
      : s.importModuleSource(
          module.source,
          fileName: '${module.name}.caw',
          folderPath: module.folderPath,
        );
    for (final entry in module.params.entries) {
      s.setParam(id, entry.key, entry.value);
    }
    if (!mounted) return;
    setState(() {
      _moduleId = id;
      _guided = false;
      _message = 'Created an independent copy of ${module.name}.';
      _error = false;
    });
    await _validate();
  }

  void _createBlank(String kind) {
    final id = s.addBlankModule(kind);
    setState(() {
      _moduleId = id;
      _guided = false;
      _message = 'Created a blank $kind module. Open it in Builder to author its source.';
      _error = false;
    });
  }

  Future<void> _validate() async {
    final id = _moduleId;
    if (id == null) return;
    if (s.engine == null) {
      setState(() { _error = true; _message = 'Engine unavailable; this module cannot be validated right now.'; });
      return;
    }
    setState(() { _busy = true; _message = null; });
    try {
      final info = await s.run(id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = info == null || !info.ok;
        _message = info == null ? 'Engine returned no validation report.' :
          info.ok ? 'Compiled successfully · ${info.params.length} generated parameters.' : info.error;
      });
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = true; _message = 'Validation failed: $e'; });
    }
  }

  Future<void> _export(ModuleDoc module) async {
    try {
      final safe = module.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      final saved = await FilePicker.saveFile(
        fileName: '${safe.isEmpty ? 'Module' : safe}.caw',
        bytes: utf8.encode(module.source),
        mimeType: 'text/plain',
        type: FileType.custom,
        allowedExtensions: const ['caw'],
      );
      if (mounted) setState(() { _message = saved == null ? 'Export cancelled.' : 'Exported ${module.name}.caw'; _error = false; });
    } catch (e) {
      if (mounted) setState(() { _message = 'Package export failed: $e'; _error = true; });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: s,
    builder: (context, _) {
      final modules = _modules;
      if (_moduleId == null || !modules.any((m) => m.id == _moduleId)) _moduleId = modules.firstOrNull?.id;
      final module = s.project.module(_moduleId);
      final info = module == null ? null : s.info[module.id];
      return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Guided')),
            ButtonSegment(value: false, label: Text('Advanced')),
          ],
          selected: {_guided},
          showSelectedIcon: false,
          onSelectionChanged: _busy ? null : (v) => setState(() => _guided = v.first),
        ),
        const SizedBox(height: 12),
        if (_guided) NeonPanel(color: Neon.green, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('START FROM A GENERATOR OR EFFECT', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w800)),
            const Text('Start from a blank module or an existing engine template. Source and generated parameters remain editable in Builder.',
              style: TextStyle(color: Neon.dim, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: _busy ? null : () => _createBlank('generator'),
                icon: const Icon(Icons.graphic_eq), label: const Text('Blank generator')),
              OutlinedButton.icon(onPressed: _busy ? null : () => _createBlank('effect'),
                icon: const Icon(Icons.auto_fix_high), label: const Text('Blank effect')),
            ]),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Starter module'),
              child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                value: _templateFile ?? _templates.firstOrNull?.file,
                isExpanded: true,
                items: [for (final t in _templates) DropdownMenuItem(value: t.file, child: Text(t.file))],
                onChanged: _busy ? null : (v) => setState(() => _templateFile = v),
              )),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy || _templates.isEmpty ? null : _createFromTemplate,
              icon: const Icon(Icons.add),
              label: const Text('Create project module'),
            ),
          ],
        )),
        if (!_guided) NeonPanel(color: Neon.blue, child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('EXISTING MODULE', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800)),
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Generator / effect'),
              child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                value: _moduleId,
                isExpanded: true,
                items: [for (final m in modules) DropdownMenuItem(value: m.id, child: Text(m.name))],
                onChanged: (v) => setState(() { _moduleId = v; _message = null; }),
              )),
            ),
            const SizedBox(height: 8),
            if (module == null) const Text('Create a module from a starter template first.',
              style: TextStyle(color: Neon.dim)),
            if (module != null) Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: () { s.selectModule(module.id); widget.onOpenBuilder(); },
                icon: const Icon(Icons.code), label: const Text('Edit source in Builder')),
              OutlinedButton.icon(onPressed: _busy ? null : _validate,
                icon: const Icon(Icons.fact_check_outlined), label: const Text('Validate / Run')),
              OutlinedButton.icon(onPressed: _busy ? null : () => _cloneExisting(module),
                icon: const Icon(Icons.copy_outlined), label: const Text('Clone as new module')),
              FilledButton.icon(onPressed: _busy ? null : () => _export(module),
                icon: const Icon(Icons.inventory_2_outlined), label: const Text('Package .caw')),
            ]),
          ],
        )),
        if (module != null) ...[
          const SizedBox(height: 12),
          NeonPanel(color: info?.ok == true ? Neon.green : Neon.pink, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(module.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                Text(info?.ok == true ? 'VALID' : 'NOT VALIDATED',
                  style: Neon.code(size: 10, color: info?.ok == true ? Neon.green : Neon.pink)),
              ]),
              Text(info?.summary.isNotEmpty == true ? info!.summary : s.kindOf(module.id),
                style: const TextStyle(color: Neon.dim, fontSize: 12)),
              if (module.edited) const Padding(padding: EdgeInsets.only(top: 6),
                child: Text('Source has unrun edits.', style: TextStyle(color: Neon.yellow, fontSize: 11))),
              if (info?.error.isNotEmpty == true) Padding(padding: const EdgeInsets.only(top: 6),
                child: Text(info!.error, style: const TextStyle(color: Neon.pink))),
              if (info?.warnings.isNotEmpty == true)
                for (final warning in info!.warnings) Text(warning, style: const TextStyle(color: Neon.yellow, fontSize: 11)),
              const SizedBox(height: 10),
              const Text('GENERATED PARAMETERS', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w800)),
              if (info?.ok == true && info!.params.isNotEmpty)
                ValueListenableBuilder<int>(valueListenable: s.values, builder: (context, _, _) =>
                  ParamGroups(params: info.params, valueOf: (p) => module.params[p.name] ?? p.defaultValue,
                    color: s.isEffect(module.id) ? Neon.pink : Neon.green,
                    onChanged: (p, v) => s.setParam(module.id, p.name, v))),
              if (info?.ok == true && info!.params.isEmpty)
                const Text('No user parameters declared.', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ],
          )),
        ],
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text(_message!, style: TextStyle(color: _error ? Neon.pink : Neon.green))),
        const SizedBox(height: 12),
        const NeonPanel(color: Neon.yellow, child: Text(
          'This screen edits and validates .caw modules. The separate C++ component path now has the CAW SDK, local CMake build service, explicit-trust loader and a zero-parameter stereo master-effect adapter. C++ source/build/trust controls are not wired into this screen yet, and on-device toolchain provisioning is still missing. CLAP/VST3 hosting and true separate-process isolation are also not implemented.',
          style: TextStyle(color: Neon.dim, fontSize: 12))),
      ]);
    },
  );
}
