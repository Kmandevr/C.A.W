// The .caw project file in the UI: Export project… with its dependency checklist, Import project (packages, plain
// .caw and old .cawproj), the packaged-build trust prompt and the missing-files banner with Locate… and Replace….
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../../model/app_state.dart';
import '../../model/audio_edit.dart';
import '../../model/project_dependencies.dart';
import '../../model/project_package.dart';
import '../../model/storage.dart';
import '../../platform/save_copy.dart';
import '../glass.dart';
import '../theme.dart';

void _snack(BuildContext context, String text, {SnackBarAction? action}) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), action: action));

/// The system pickers the project file uses, for tests to replace: the file to import, where an export goes, and the
/// files Locate… and Replace… take.
class ProjectFilePicker {
  ProjectFilePicker._();

  static Future<String?> Function() pickImport = () async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: projectImportExtensions);
    if (f == null) return null;
    final path = f.xFile.path;
    if (path.isNotEmpty && await File(path).exists()) return path;
    // No readable path (some pickers): a temporary copy.
    final dir = await Directory.systemTemp.createTemp('caw-import');
    final copy = File('${dir.path}${Platform.pathSeparator}${safeArchiveName(f.name)}');
    await copy.writeAsBytes(await f.xFile.readAsBytes(), flush: true);
    return copy.path;
  };

  static Future<bool> Function(File file, String name, String mime) save =
      (file, name, mime) => saveCopyOf(file, name: name, mimeType: mime, extension: projectExtension);

  static Future<List<String>> Function({required bool many}) pickAudio = ({required bool many}) async {
    final files = many
        ? await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: audioExtensions)
        : [?await FilePicker.pickFile(type: FileType.custom, allowedExtensions: audioExtensions)];
    return [for (final f in files) if (f.xFile.path.isNotEmpty) f.xFile.path];
  };
}

// ---------- export ----------

/// Export project…: the dependency checklist, then the .caw file saved where the user picks.
Future<void> exportPortableProject(BuildContext context, AppState state) async {
  try {
    final deps = await state.projectDependencies();
    if (!context.mounted) return;
    final selected = await showPackageChecklist(context, state, deps);
    if (selected == null || !context.mounted) return;
    final file = await state.writeProjectFile(deps, selected);
    final zip = deps.any((d) => selected.contains(d.key) && d.packageable);
    final saved = await ProjectFilePicker.save(file, file.uri.pathSegments.last, zip ? 'application/zip' : 'application/json');
    try {
      await file.parent.delete(recursive: true);
    } catch (_) {}
    if (context.mounted) _snack(context, saved ? 'Exported project file.' : 'Project export cancelled.');
  } catch (e) {
    if (context.mounted) _snack(context, 'Project export failed: $e');
  }
}

/// The checklist sheet: every dependency with its package box, type, users, size and found or missing; Package
/// everything at the top and the file's total size at the bottom. Returns the ticked keys, or null when closed.
Future<Set<String>?> showPackageChecklist(BuildContext context, AppState state, List<ProjectDependency> deps) {
  final projectBytes = utf8.encode(jsonEncode(state.project.toJson())).length;
  return showGlassSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => PackageChecklist(projectName: state.project.name, projectBytes: projectBytes, deps: deps),
  );
}

/// What the sheet starts with ticked: the project's audio and samples (it doesn't sound right without them); C++
/// builds, presets and the theme are the user's call.
bool _tickedByDefault(ProjectDependency d) =>
    d.packageable && (d.kind == DependencyKind.audio || d.kind == DependencyKind.sample);

IconData _icon(DependencyKind k) => switch (k) {
      DependencyKind.audio => Icons.graphic_eq_rounded,
      DependencyKind.sample => Icons.music_note,
      DependencyKind.impulse => Icons.blur_on,
      DependencyKind.source => Icons.code,
      DependencyKind.binary => Icons.memory,
      DependencyKind.plugin => Icons.extension_outlined,
      DependencyKind.preset => Icons.tune,
      DependencyKind.theme => Icons.palette_outlined,
    };

String _kindLabel(DependencyKind k) => switch (k) {
      DependencyKind.audio => 'Audio',
      DependencyKind.sample => 'Sample',
      DependencyKind.impulse => 'Impulse',
      DependencyKind.source => 'C++ source',
      DependencyKind.binary => 'C++ build',
      DependencyKind.plugin => 'Plug-in',
      DependencyKind.preset => 'Preset',
      DependencyKind.theme => 'Theme',
    };

class PackageChecklist extends StatefulWidget {
  const PackageChecklist({super.key, required this.projectName, required this.projectBytes, required this.deps});
  final String projectName;
  final int projectBytes;
  final List<ProjectDependency> deps;

  @override
  State<PackageChecklist> createState() => _PackageChecklistState();
}

class _PackageChecklistState extends State<PackageChecklist> {
  late final Set<String> _ticked = {for (final d in widget.deps) if (_tickedByDefault(d)) d.key};

  Iterable<ProjectDependency> get _packageable => widget.deps.where((d) => d.packageable);
  bool get _everything => _packageable.every((d) => _ticked.contains(d.key));

  int get _total => widget.projectBytes +
      widget.deps.where((d) => d.packageable && _ticked.contains(d.key)).fold<int>(0, (n, d) => n + d.size);

  Widget _row(ProjectDependency d) {
    final always = d.embedded;
    final on = always || _ticked.contains(d.key);
    final status = always
        ? 'in the project'
        : d.outside
            ? 'outside this project: not packaged'
        : d.kind == DependencyKind.plugin
            ? 'licence unknown: listed as needed'
            : d.found
                ? 'found'
                : 'missing';
    final users = d.usedBy.isEmpty ? '' : 'used by ${d.usedBy.take(3).join(', ')}${d.usedBy.length > 3 ? '…' : ''} · ';
    final missing = !d.found && !always && !d.outside;
    return CheckboxListTile(
      key: ValueKey('package-${d.key}'),
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      value: on,
      onChanged: always || !d.packageable
          ? null
          : (v) => setState(() => v == true ? _ticked.add(d.key) : _ticked.remove(d.key)),
      secondary: Icon(_icon(d.kind), size: 18, color: missing ? Neon.pink : Neon.blue),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: missing ? Neon.pink : Neon.text)),
      subtitle: Text('${_kindLabel(d.kind)} · $users${StorageUse.format(d.size)} · $status',
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: missing ? Neon.pink : Neon.dim)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = [...widget.deps]..sort((a, b) => a.kind.index != b.kind.index
        ? a.kind.index.compareTo(b.kind.index)
        : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(key: const ValueKey('package-checklist'), mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: Text('EXPORT PROJECT · ${widget.projectName}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text))),
          CheckboxListTile(
            key: const ValueKey('package-everything'),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: const Text('Package everything', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            subtitle: const Text('Everything found here that may travel with the project',
                style: TextStyle(fontSize: 10, color: Neon.dim)),
            value: _packageable.isNotEmpty && _everything,
            onChanged: _packageable.isEmpty
                ? null
                : (v) => setState(() {
                      for (final d in _packageable) {
                        v == true ? _ticked.add(d.key) : _ticked.remove(d.key);
                      }
                    }),
          ),
          const Divider(height: 1),
          Flexible(child: ListView(shrinkWrap: true, children: [
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('This project uses no files besides itself.',
                  style: TextStyle(color: Neon.dim, fontSize: 12))),
            for (final d in rows) _row(d),
          ])),
          const Divider(height: 1),
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 12, 8), child: Row(children: [
            Expanded(child: Text('File size about ${StorageUse.format(_total)}', key: const ValueKey('package-total'),
                style: const TextStyle(color: Neon.dim, fontSize: 12))),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 4),
            FilledButton.icon(
              key: const ValueKey('package-export'),
              onPressed: () => Navigator.pop(context, Set.of(_ticked)),
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              label: const Text('Export .caw'),
            ),
          ])),
        ]),
      ),
    );
  }
}

// ---------- import ----------

/// Import project: a .caw (plain or package) or an old .cawproj, as a new project.
Future<void> importPortableProject(BuildContext context, AppState state) async {
  final String? path;
  try {
    path = await ProjectFilePicker.pickImport();
  } catch (e) {
    if (context.mounted) _snack(context, 'Project import failed: $e');
    return;
  }
  if (path == null || !context.mounted) return;
  await importProjectFromPath(context, state, path);
}

/// Imports the project file at [path] (a .caw or .cawproj opened with the app or dropped on its window, or one the
/// picker chose), asking first, as a new project.
Future<void> importProjectFromPath(BuildContext context, AppState state, String path) async {
  try {
    final result = await state.importProjectFile(path,
        confirm: (project) async {
          if (!context.mounted) return false;
          return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Import project?'),
                  content: Text('Open "${project.name}" as a new project? Your current project will be autosaved first.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
                  ],
                ),
              ) ??
              false;
        },
        askBinaryTrust: (b) async => context.mounted ? askPackagedBuildTrust(context, b) : null);
    if (result == null || !context.mounted) return;
    final parts = [
      'Imported "${state.project.name}"',
      if (result.filesUnpacked > 0) '${result.filesUnpacked} file${result.filesUnpacked == 1 ? '' : 's'} unpacked',
      if (result.presetsAdded.isNotEmpty) '${result.presetsAdded.length} preset${result.presetsAdded.length == 1 ? '' : 's'} added',
      ...result.notes.take(2),
    ];
    final theme = result.theme;
    _snack(context, '${parts.join('. ')}.', action: theme == null ? null : SnackBarAction(
      label: 'Add theme',
      onPressed: () => state.settings.addTheme(theme),
    ));
  } catch (e) {
    if (context.mounted) _snack(context, 'Project import failed: ${e is FormatException ? e.message : e}');
  }
}

/// Asks Trust or Block for a C++ build that came in a package: it runs in the app with full access, so it is asked
/// once for exactly this file (its fingerprint) and never assumed. Closing the dialog leaves it unused.
Future<NativeComponentTrust?> askPackagedBuildTrust(BuildContext context, ImportedBinary b) => showDialog<NativeComponentTrust>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('packaged-build-trust'),
        title: const Text('Use the packaged C++ build?'),
        content: Text('The project carries a build of ${b.name} (${b.componentId}) for this device. A build runs '
            'inside the app with full access, and C.A.W can\'t check what it does: trust it only if you trust whoever '
            'made the project. Block builds it from its source here instead (if you trust that).\n\n'
            'Fingerprint ${b.sha256.substring(0, 16)}…'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, NativeComponentTrust.blocked), child: const Text('Block')),
          FilledButton(onPressed: () => Navigator.pop(context, NativeComponentTrust.trusted), child: const Text('Trust')),
        ],
      ),
    );

// ---------- missing files ----------

/// The one-line banner for files the open project can't find, with Locate… (pick the files; matched by name and,
/// when the package recorded it, checked by hash) and Replace… (any audio file in place of one).
class MissingFilesBanner extends StatelessWidget {
  const MissingFilesBanner({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final missing = state.missingFiles;
    final names = missing.map((m) => m.name).toList();
    final text = missing.length == 1
        ? 'Missing: ${names.first} (silent until found)'
        : 'Missing ${missing.length} files: ${names.take(3).join(', ')}${names.length > 3 ? '…' : ''} (silent until found)';
    return Container(
      key: const ValueKey('banner-missing'),
      width: double.infinity,
      color: Neon.yellow.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.yellow))),
        TextButton(key: const ValueKey('missing-locate'), onPressed: () => locateMissingFiles(context, state),
            child: const Text('Locate…')),
        TextButton(key: const ValueKey('missing-replace'), onPressed: () => replaceMissingFile(context, state),
            child: const Text('Replace…')),
      ]),
    );
  }
}

String _base(String path) => path.split(RegExp(r'[/\\]')).last.toLowerCase();

/// Locate…: the picked files re-link the missing ones of the same name.
Future<void> locateMissingFiles(BuildContext context, AppState state) async {
  final picked = await ProjectFilePicker.pickAudio(many: true);
  if (picked.isEmpty) return;
  var linked = 0;
  final problems = <String>[];
  for (final path in picked) {
    final match = state.missingFiles.where((m) => m.name.toLowerCase() == _base(path)).firstOrNull;
    if (match == null) {
      problems.add('${_base(path)} is not one of the missing files');
      continue;
    }
    try {
      await state.relinkMissingFile(match, path);
      linked++;
    } catch (e) {
      problems.add(e is FormatException ? e.message : '$e');
    }
  }
  if (!context.mounted) return;
  _snack(context, [if (linked > 0) 'Found $linked file${linked == 1 ? '' : 's'}', ...problems].join('. '));
}

/// Replace…: another file in place of a missing one (asked which, when several are missing).
Future<void> replaceMissingFile(BuildContext context, AppState state) async {
  final missing = state.missingFiles;
  if (missing.isEmpty) return;
  final target = missing.length == 1
      ? missing.first
      : await showDialog<ProjectDependency>(
          context: context,
          builder: (context) => SimpleDialog(title: const Text('Replace which file?'), children: [
            for (final m in missing)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, m),
                child: Text('${m.name}${m.usedBy.isEmpty ? '' : ' · ${m.usedBy.join(', ')}'}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ]),
        );
  if (target == null) return;
  final picked = await ProjectFilePicker.pickAudio(many: false);
  if (picked.isEmpty) return;
  try {
    await state.relinkMissingFile(target, picked.first, verify: false);
    if (context.mounted) _snack(context, 'Replaced ${target.name}.');
  } catch (e) {
    if (context.mounted) _snack(context, 'Not replaced: ${e is FormatException ? e.message : e}');
  }
}
