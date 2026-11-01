// User-controlled import/export for portable project and module files.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/project.dart';
import 'theme.dart';
import 'widgets.dart';

class FileManagerScreen extends StatelessWidget {
  const FileManagerScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [
        const Text('FILES / LIBRARY', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w900, fontSize: 12)),
        const Text('Portable files · user-chosen locations · no forced folder layout',
          style: TextStyle(color: Neon.dim, fontSize: 11)),
        const SizedBox(height: 14),
        NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('CURRENT PROJECT', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(state.project.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text('${state.project.modules.length} modules · ${state.project.layers.length} tracks',
            style: const TextStyle(color: Neon.dim, fontSize: 12)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: () => _exportProject(context, state),
              icon: const Icon(Icons.file_upload_outlined), label: const Text('Export .cawproj')),
            OutlinedButton.icon(onPressed: () => _importProject(context, state),
              icon: const Icon(Icons.file_open_outlined), label: const Text('Import project')),
          ]),
        ])),
        const SizedBox(height: 14),
        NeonPanel(color: Neon.green, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('MODULE FILES', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w800)),
          const Text('Portable .caw source files. Import creates a new module; it never overwrites an existing one.',
            style: TextStyle(color: Neon.dim, fontSize: 12)),
          const SizedBox(height: 10),
          OutlinedButton.icon(onPressed: () => _importModule(context, state),
            icon: const Icon(Icons.add), label: const Text('Import .caw module')),
          if (state.project.modules.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 8),
              child: Text('No modules in this project.', style: TextStyle(color: Neon.dim))),
          for (final module in state.project.modules)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(module.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(module.edited ? 'Unrun source edits' : state.kindOf(module.id),
                style: const TextStyle(color: Neon.dim, fontSize: 11)),
              leading: Icon(Icons.description_outlined,
                color: state.isEffect(module.id) ? Neon.pink : state.isPattern(module.id) ? Neon.yellow : Neon.green),
              trailing: Wrap(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: 'Open in Builder', onPressed: () {
                  state.selectModule(module.id);
                  onOpenBuilder();
                }, icon: const Icon(Icons.edit_outlined)),
                IconButton(tooltip: 'Export .caw', onPressed: () => _exportModule(context, module),
                  icon: const Icon(Icons.ios_share)),
              ]),
            ),
        ])),
        const SizedBox(height: 12),
        const NeonPanel(color: Neon.yellow, child: Text(
          'Portable formats currently supported here: .cawproj project files and .caw module source. Use Exporter for WAV audio, MIDI patterns and wavetable output. These files can be saved into any folder chosen in the system file picker.',
          style: TextStyle(color: Neon.dim, fontSize: 12))),
      ],
    ),
  );
}

String _safeFileName(String value) =>
    value.trim().replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '').replaceAll(RegExp(r'\\s+'), '_');

Future<void> _exportProject(BuildContext context, AppState state) async {
  try {
    await state.flush();
    final name = _safeFileName(state.project.name);
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(state.project.toJson()));
    final saved = await FilePicker.saveFile(
      fileName: '${name.isEmpty ? 'Caw_Project' : name}.cawproj',
      bytes: bytes,
      mimeType: 'application/json',
      type: FileType.custom,
      allowedExtensions: const ['cawproj'],
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(saved == null ? 'Project export cancelled.' : 'Exported project file.')));
    }
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Project export failed: $e')));
  }
}

Future<void> _importProject(BuildContext context, AppState state) async {
  try {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['cawproj', 'json'],
    );
    if (file == null) return;
    final decoded = jsonDecode(await file.xFile.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['caw_app_project'] == null) {
      throw const FormatException('This is not a C.A.W. project file.');
    }
    final project = ProjectDoc.fromJson(decoded);
    if (!context.mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import project?'),
        content: Text('Open "${project.name}" as a new project? Your current project will be autosaved first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
        ],
      ),
    );
    if (proceed != true) return;
    await state.importProject(project);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported "${state.project.name}".')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Project import failed: $e')));
  }
}

Future<void> _importModule(BuildContext context, AppState state) async {
  try {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['caw'],
    );
    if (file == null) return;
    final source = await file.xFile.readAsString();
    final id = state.importModuleSource(source, fileName: file.name);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported module "${state.project.module(id)?.name ?? file.name}".')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Module import failed: $e')));
  }
}

Future<void> _exportModule(BuildContext context, ModuleDoc module) async {
  try {
    final name = _safeFileName(module.name);
    final saved = await FilePicker.saveFile(
      fileName: '${name.isEmpty ? 'Module' : name}.caw',
      bytes: utf8.encode(module.source),
      mimeType: 'text/plain',
      type: FileType.custom,
      allowedExtensions: const ['caw'],
    );
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(saved == null ? 'Module export cancelled.' : 'Exported "${module.name}.caw".')));
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Module export failed: $e')));
  }
}
