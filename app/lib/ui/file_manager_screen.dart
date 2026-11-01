// Portable project/module files plus user-owned project library folders and tags.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/project.dart';
import 'theme.dart';
import 'widgets.dart';

class FileManagerScreen extends StatefulWidget {
  const FileManagerScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  String _folderPath = '';
  String _query = '';
  String _sort = 'name';
  bool _selectionMode = false;
  final Set<String> _selectedModuleIds = {};
  final TextEditingController _searchController = TextEditingController();

  AppState get state => widget.state;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New library folder'),
        content: TextField(controller: controller, autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name', hintText: 'Drums / Kicks')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    final path = _folderPath.isEmpty ? name.trim() : '$_folderPath/${name.trim()}';
    try {
      state.createLibraryFolder(path);
      setState(() => _folderPath = path);
    } catch (e) {
      _notice('Folder could not be created: $e', error: true);
    }
  }

  Future<void> _renameFolder(String path) async {
    final controller = TextEditingController(text: path.split('/').last);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename folder'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'New name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    final parent = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    final next = parent.isEmpty ? name.trim() : '$parent/${name.trim()}';
    try {
      if (!state.renameLibraryFolder(path, next)) {
        _notice('Folder name is invalid or already in use.', error: true);
        return;
      }
    } catch (e) {
      _notice('Folder name is invalid: $e', error: true);
      return;
    }
    setState(() {
      if (_folderPath == path) {
        _folderPath = next;
      } else if (_folderPath.startsWith('$path/')) {
        _folderPath = '$next${_folderPath.substring(path.length)}';
      }
    });
  }

  Future<void> _deleteFolder(String path) async {
    final parent = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete folder?'),
        content: Text('Delete "$path"? Modules in this folder and its subfolders will move to the parent folder. Folder nodes are removed; module source is never deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete folder')),
        ],
      ),
    );
    if (proceed != true) return;
    state.deleteLibraryFolder(path);
    if (mounted && (_folderPath == path || _folderPath.startsWith('$path/'))) {
      setState(() => _folderPath = parent);
    }
  }

  Future<void> _editTags(ModuleDoc module) async {
    final controller = TextEditingController(text: module.tags.join(', '));
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Tags · ${module.name}'),
        content: TextField(controller: controller, autofocus: true,
          decoration: const InputDecoration(labelText: 'Comma-separated tags', hintText: 'bass, analog, lead')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save tags')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null) return;
    state.setModuleTags(module.id, value.split(','));
  }

  Future<void> _editSelectedTags() async {
    final count = _selectedModuleIds.length;
    if (count == 0) return;
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Tags · $count modules'),
        content: TextField(controller: controller, autofocus: true,
          decoration: const InputDecoration(labelText: 'Replace tags on selected modules',
            hintText: 'bass, analog, lead')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Apply tags')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null) return;
    if (state.setModulesTags(_selectedModuleIds, value.split(','))) {
      _notice('Updated tags on $count modules.');
    }
    setState(() => _selectedModuleIds.clear());
  }

  Future<void> _saveSearch() async {
    if (_query.trim().isEmpty) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save library search'),
        content: TextField(controller: controller, autofocus: true,
          decoration: const InputDecoration(labelText: 'Search name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (name != null && name.trim().isNotEmpty && !state.saveLibrarySearch(name, _query)) {
      _notice('Search name/query is too long or the 32-search limit has been reached.', error: true);
    }
  }

  void _notice(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Neon.pink : null,
    ));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final folders = state.project.libraryFolders.toList()..sort();
      final modules = state.project.modules.where((module) {
        if (module.folderPath != _folderPath) return false;
        if (_query.trim().isEmpty) return true;
        final q = _query.trim().toLowerCase();
        return module.name.toLowerCase().contains(q) ||
          state.kindOf(module.id).toLowerCase().contains(q) ||
          module.tags.any((tag) => tag.toLowerCase().contains(q));
      }).toList();
      modules.sort((a, b) => _sort == 'kind'
        ? state.kindOf(a.id).compareTo(state.kindOf(b.id))
        : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final sourceCounts = <String, int>{};
      for (final module in state.project.modules) {
        final source = module.source.trim();
        if (source.isNotEmpty) sourceCounts[source] = (sourceCounts[source] ?? 0) + 1;
      }
      return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
        const Text('FILES / PORTABILITY', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w900, fontSize: 12)),
        const Text('Your library folders and tags · portable files · choose your own save locations',
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
            OutlinedButton.icon(onPressed: () async {
              await _importProject(context, state);
              if (mounted) {
                setState(() {
                _folderPath = '';
                _query = '';
                _searchController.clear();
                _selectedModuleIds.clear();
                _selectionMode = false;
                });
              }
            }, icon: const Icon(Icons.file_open_outlined), label: const Text('Import project')),
          ]),
        ])),
        const SizedBox(height: 14),
        NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('LIBRARY FOLDERS', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800))),
            IconButton(tooltip: 'Undo library operation', onPressed: state.canUndoLibrary ? state.undoLibraryOperation : null,
              icon: const Icon(Icons.undo)),
            IconButton(tooltip: 'Redo library operation', onPressed: state.canRedoLibrary ? state.redoLibraryOperation : null,
              icon: const Icon(Icons.redo)),
            IconButton(tooltip: 'Create folder', onPressed: _createFolder, icon: const Icon(Icons.create_new_folder_outlined)),
          ]),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.home_outlined, color: Neon.blue),
            title: const Text('Project root'),
            selected: _folderPath.isEmpty,
            onTap: () => setState(() => _folderPath = ''),
          ),
          for (final folder in folders)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.only(left: 8.0 + 16.0 * (folder.split('/').length - 1)),
              leading: const Icon(Icons.folder_outlined, color: Neon.blue),
              title: Text(folder.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(folder, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Neon.dim, fontSize: 10)),
              selected: _folderPath == folder,
              onTap: () => setState(() => _folderPath = folder),
              trailing: PopupMenuButton<String>(
                tooltip: 'Folder actions',
                onSelected: (action) {
                  if (action == 'rename') _renameFolder(folder);
                  if (action == 'delete') _deleteFolder(folder);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename folder')),
                  PopupMenuItem(value: 'delete', child: Text('Delete folder')),
                ],
              ),
            ),
        ])),
        const SizedBox(height: 14),
        NeonPanel(color: Neon.green, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_folderPath.isEmpty ? 'PROJECT MODULES' : _folderPath.toUpperCase(),
              style: const TextStyle(color: Neon.green, fontWeight: FontWeight.w800))),
            IconButton(tooltip: _selectionMode ? 'Exit bulk selection' : 'Select modules',
              onPressed: () => setState(() { _selectionMode = !_selectionMode; _selectedModuleIds.clear(); }),
              icon: Icon(_selectionMode ? Icons.close : Icons.checklist)),
            IconButton(tooltip: 'Import .caw module into this folder', onPressed: () => _importModule(context, state, _folderPath),
              icon: const Icon(Icons.file_open_outlined)),
          ]),
          Row(children: [
            Expanded(child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name, type or tags'),
              onChanged: (value) => setState(() => _query = value),
            )),
            IconButton(tooltip: 'Save current search', onPressed: _query.trim().isEmpty ? null : _saveSearch,
              icon: const Icon(Icons.bookmark_add_outlined)),
            const SizedBox(width: 4),
            DropdownButton<String>(
              value: _sort,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'name', child: Text('Name')),
                DropdownMenuItem(value: 'kind', child: Text('Kind')),
              ],
              onChanged: (value) { if (value != null) setState(() => _sort = value); },
            ),
          ]),
          if (state.project.savedLibrarySearches.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (final entry in state.project.savedLibrarySearches.entries)
                  InputChip(
                    label: Text(entry.key),
                    tooltip: 'Search: ${entry.value}',
                    onPressed: () {
                      _searchController.text = entry.value;
                      setState(() => _query = entry.value);
                    },
                    onDeleted: () => state.deleteLibrarySearch(entry.key),
                  ),
              ])),
          if (_selectionMode) Padding(padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${_selectedModuleIds.length} selected', style: Neon.code(size: 11, color: Neon.blue)),
              TextButton(
                onPressed: modules.isEmpty ? null : () => setState(() {
                  final visible = modules.map((m) => m.id).toSet();
                  if (_selectedModuleIds.containsAll(visible)) {
                    _selectedModuleIds.removeAll(visible);
                  } else {
                    _selectedModuleIds.addAll(visible);
                  }
                }),
                child: const Text('Select all / none'),
              ),
              TextButton.icon(
                onPressed: _selectedModuleIds.isEmpty ? null : _editSelectedTags,
                icon: const Icon(Icons.sell_outlined, size: 16),
                label: const Text('Tag selected'),
              ),
              PopupMenuButton<String>(
                tooltip: 'Move selected modules',
                enabled: _selectedModuleIds.isNotEmpty,
                onSelected: (destination) {
                  final folder = destination == 'root' ? '' : destination.substring('folder:'.length);
                  state.moveModulesToFolder(_selectedModuleIds, folder);
                  setState(() => _selectedModuleIds.clear());
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'root', child: Text('Move to project root')),
                  for (final folder in folders)
                    PopupMenuItem(value: 'folder:$folder', child: Text('Move to $folder')),
                ],
                child: const Chip(avatar: Icon(Icons.drive_file_move_outlined, size: 16), label: Text('Move selected')),
              ),
            ])),
          if (modules.isEmpty)
            Padding(padding: const EdgeInsets.only(top: 12),
              child: Text(_query.isEmpty ? 'This folder is empty.' : 'No modules match this search.',
                style: const TextStyle(color: Neon.dim))),
          for (final module in modules)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Row(children: [
                Expanded(child: Text(module.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if ((sourceCounts[module.source.trim()] ?? 0) > 1 && module.source.trim().isNotEmpty)
                  const Padding(padding: EdgeInsets.only(left: 6),
                    child: Tooltip(message: 'Identical source also exists in another module',
                      child: Icon(Icons.copy_all, size: 14, color: Neon.yellow))),
              ]),
              subtitle: Wrap(spacing: 4, runSpacing: 2, children: [
                Text(state.kindOf(module.id).toUpperCase(), style: Neon.code(size: 9, color: Neon.dim)),
                for (final tag in module.tags)
                  Chip(label: Text(tag, style: const TextStyle(fontSize: 9)),
                    visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ]),
              leading: _selectionMode
                ? Checkbox(
                    value: _selectedModuleIds.contains(module.id),
                    onChanged: (selected) => setState(() {
                      if (selected == true) {
                        _selectedModuleIds.add(module.id);
                      } else {
                        _selectedModuleIds.remove(module.id);
                      }
                    }),
                  )
                : Icon(Icons.description_outlined,
                    color: state.isEffect(module.id) ? Neon.pink : state.isPattern(module.id) ? Neon.yellow : Neon.green),
              trailing: _selectionMode ? null : Wrap(spacing: 0, runSpacing: 0, children: [
                IconButton(
                  tooltip: 'Solo preview in Builder',
                  onPressed: state.isLibrary(module.id) ? null : () {
                    state.selectModule(module.id);
                    if (!state.previewOnly) state.setPreviewOnly(true);
                    widget.onOpenBuilder();
                  },
                  icon: const Icon(Icons.play_arrow, color: Neon.green),
                ),
                IconButton(tooltip: 'Open in Builder', onPressed: () {
                  state.selectModule(module.id);
                  widget.onOpenBuilder();
                }, icon: const Icon(Icons.edit_outlined)),
                PopupMenuButton<String>(
                  tooltip: 'Module actions',
                  onSelected: (action) {
                    if (action == 'tags') _editTags(module);
                    if (action == 'export') _exportModule(context, module);
                    if (action == 'root') state.moveModuleToFolder(module.id, '');
                    if (action.startsWith('folder:')) {
                      state.moveModuleToFolder(module.id, action.substring('folder:'.length));
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
                    const PopupMenuItem(value: 'export', child: Text('Export .caw')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'root', child: Text('Move to project root')),
                    for (final folder in folders)
                      PopupMenuItem(value: 'folder:$folder', child: Text('Move to $folder')),
                  ],
                ),
              ]),
              onTap: () {
                if (_selectionMode) {
                  setState(() {
                    if (!_selectedModuleIds.add(module.id)) _selectedModuleIds.remove(module.id);
                  });
                } else {
                  state.selectModule(module.id);
                }
              },
              onLongPress: _selectionMode ? null : () => _editTags(module),
            ),
        ])),
        const SizedBox(height: 12),
        const NeonPanel(color: Neon.yellow, child: Text(
          'Portable formats currently supported here: .cawproj project files and .caw module source. Library folders and tags are stored inside the project. Use Exporter for WAV audio, MIDI patterns and wavetable output. Import/export file pickers let you choose your own operating-system folders.',
          style: TextStyle(color: Neon.dim, fontSize: 12))),
      ]);
    },
  );
}

String _safeFileName(String value) =>
    value.trim().replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '').replaceAll(RegExp(r'\s+'), '_');

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
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Project export failed: $e')));
    }
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
    if (decoded is! Map<String, dynamic> || decoded['caw_app_project'] is! num) {
      throw const FormatException('This is not a C.A.W. project file.');
    }
    final version = (decoded['caw_app_project'] as num).toInt();
    if (version > ProjectDoc.fileVersion) {
      throw FormatException('This project uses a newer format (v$version); this app supports v${ProjectDoc.fileVersion}.');
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
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${state.project.name}".')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Project import failed: $e')));
    }
  }
}

Future<void> _importModule(BuildContext context, AppState state, String folderPath) async {
  try {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['caw'],
    );
    if (file == null) return;
    final source = await file.xFile.readAsString();
    final id = state.importModuleSource(source, fileName: file.name, folderPath: folderPath);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported module "${state.project.module(id)?.name ?? file.name}".')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Module import failed: $e')));
    }
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
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(saved == null ? 'Module export cancelled.' : 'Exported "${module.name}.caw".')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Module export failed: $e')));
    }
  }
}
