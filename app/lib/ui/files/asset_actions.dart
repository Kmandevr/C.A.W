// What Files does with an asset or folder: open it in Build, audition it, its long-press menu, rename, duplicate, delete, new effects and modules.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/files_catalog.dart';
import '../frame/sections.dart';
import '../theme.dart';
import 'asset_views.dart';
import 'library_manager.dart';

/// Actions shared by the Files screen and its inspector. [onOpenBuilder] is the old shell's fallback for opening
/// a module when there is no SectionScope; [onSelect] makes a new or copied asset the selection.
class FilesActions {
  FilesActions({required this.context, required this.state, required this.onOpenBuilder, required this.onSelect});

  final BuildContext context;
  final AppState state;
  final VoidCallback onOpenBuilder;
  final void Function(String? key) onSelect;

  /// Set when ▶ preview started the transport, so stopping the preview stops it too.
  static bool _previewStartedPlay = false;

  void notice(String message, {bool error = false}) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Neon.pink : null,
      duration: const Duration(seconds: 2),
    ));
  }

  /// Double-tap: a C++ component or file opens in a C++ Builder tab, a .caw module or pattern in a .caw tab.
  void open(FileAsset a) {
    final tab = a.buildTab;
    if (tab == null) return;
    if (a.module != null) state.selectModule(a.module!.id);
    final sections = SectionController.maybeOf(context);
    if (sections != null) {
      sections.openBuild(tab);
    } else {
      onOpenBuilder();
    }
  }

  bool isPreviewing(FileAsset a) => a.module != null && state.previewOnly && state.selectedModuleId == a.module!.id;

  /// ▶: Solo preview (the audition) of a .caw module or pattern, starting the transport when it was stopped.
  void togglePreview(FileAsset a) {
    final m = a.module;
    if (m == null || !a.previewable) return;
    if (isPreviewing(a)) {
      state.setPreviewOnly(false);
      if (_previewStartedPlay && state.transportOn) state.stopPlayback();
      _previewStartedPlay = false;
      return;
    }
    state.selectModule(m.id);
    if (!state.previewOnly) state.setPreviewOnly(true);
    if (!state.transportOn) {
      state.togglePlay();
      _previewStartedPlay = state.transportOn;
    }
  }

  Future<String?> askName(String title, String initial, {String label = 'Name'}) async {
    var value = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(labelText: label),
          onChanged: (v) => value = v,
          onFieldSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, value.trim()), child: const Text('OK')),
        ],
      ),
    );
    return result == null || result.trim().isEmpty ? null : result.trim();
  }

  Future<void> rename(FileAsset a) async {
    final next = await askName('Rename', a.name, label: a.type == FileAssetType.cppFile ? 'File path' : 'Name');
    if (next == null || next == a.name) return;
    if (a.type == FileAssetType.cppFile && !state.canNameFile(a.cpp!, next)) {
      notice('That file name is taken or not a safe relative path.', error: true);
      return;
    }
    state.renameAsset(a, next);
    if (a.type == FileAssetType.cppFile) onSelect('file:${a.cpp!.id}/$next');
  }

  void duplicate(FileAsset a) {
    final key = state.duplicateAsset(a);
    if (key != null) {
      onSelect(key);
      notice('Duplicated "${a.name}".');
    }
  }

  /// Asks first; an asset used on tracks says which, and deleting removes it from them.
  Future<void> delete(FileAsset a) async {
    final uses = state.usesOf(a);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${a.name}"?'),
        content: Text(uses.isEmpty
            ? 'This cannot be undone from Files (project undo still can).'
            : 'Used on ${uses.join(', ')}. Deleting removes it from ${uses.length == 1 ? 'that track' : 'those tracks'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Neon.pink),
            onPressed: () => Navigator.pop(context, true),
            child: Text(uses.isEmpty ? 'Delete' : 'Delete anyway'),
          ),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;
    state.deleteAsset(a);
    SectionController.maybeOf(context)?.pruneBuild(state.buildTabExists);
    onSelect(null);
    notice('Deleted "${a.name}".');
  }

  Future<void> editTags(FileAsset a) async {
    final m = a.module;
    if (m == null) return;
    final next = await askName('Tags · ${m.name}', m.tags.join(', '), label: 'Comma-separated tags');
    if (next != null) state.setModuleTags(m.id, next.split(','));
  }

  /// The long-press menu of an asset.
  Future<void> assetMenu(FileAsset a, Offset at) async {
    final fav = state.isFavourite(a);
    final action = await showCompactMenu<String>(context, at, [
      if (a.buildTab != null) const MenuEntry('open', Icons.open_in_new, 'Open'),
      if (a.previewable) MenuEntry('preview', isPreviewing(a) ? Icons.stop : Icons.play_arrow, isPreviewing(a) ? 'Stop preview' : 'Preview'),
      MenuEntry('fav', fav ? Icons.star_rounded : Icons.star_outline_rounded, fav ? 'Remove from Favourites' : 'Add to Favourites'),
      if (!a.builtin) const MenuEntry('rename', Icons.drive_file_rename_outline, 'Rename'),
      if (!a.builtin) const MenuEntry('duplicate', Icons.copy, 'Duplicate'),
      if (a.module != null) const MenuEntry('tags', Icons.sell_outlined, 'Edit tags'),
      if (a.module != null) const MenuEntry('export', Icons.file_upload_outlined, 'Export .caw'),
      if (!a.builtin) const MenuEntry('delete', Icons.delete_outline, 'Delete', danger: true, dividerBefore: true),
    ]);
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'open':
        open(a);
      case 'preview':
        togglePreview(a);
      case 'fav':
        state.setFavourite(a, !fav);
        onSelect(a.key);
      case 'rename':
        await rename(a);
      case 'duplicate':
        duplicate(a);
      case 'tags':
        await editTags(a);
      case 'export':
        await exportCawModule(context, a.module!);
      case 'delete':
        await delete(a);
    }
  }

  /// "New C++ effect" (the blank pass-through template) or, with [instrument], "New C++ instrument" (a polyphonic
  /// sine played by the track's notes), added to the project and opened in Build.
  void newCppEffect({bool instrument = false}) {
    final doc = instrument ? state.addBlankCppEffect(base: 'New instrument', instrument: true) : state.addBlankCppEffect();
    onSelect('cpp:${doc.id}');
    final sections = SectionController.maybeOf(context);
    if (sections != null) {
      sections.openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
    } else {
      notice('Added "${doc.name}".');
    }
  }

  /// "New .caw module" of [kind] (effect, generator or pattern) in [folderPath], opened in Build.
  void newCawModule(String kind, {String folderPath = ''}) {
    final id = state.addBlankModule(kind);
    if (folderPath.isNotEmpty) state.moveModuleToFolder(id, folderPath);
    onSelect('mod:$id');
    final sections = SectionController.maybeOf(context);
    if (sections != null) {
      sections.openBuild(BuildTab(BuildTabKind.caw, id));
    } else {
      onOpenBuilder();
    }
  }

  Future<void> newLibraryFolder(String parent) async {
    final name = await askName('New folder', '', label: 'Folder name');
    if (name == null) return;
    try {
      if (!state.createLibraryFolder(parent.isEmpty ? name : '$parent/$name')) notice('That folder already exists.', error: true);
    } catch (e) {
      notice('Folder could not be created: $e', error: true);
    }
  }

  /// The long-press menu of a folder (in the tree or the grid). Returns the path to show after it (a renamed
  /// or deleted library folder moves the view), or null to stay.
  Future<String?> folderMenu(FilesFolder f, Offset at) async {
    if (f.kind == FilesFolderKind.cppComponent) {
      final c = state.cppAssets.where((a) => 'code/cpp/${a.cpp!.id}' == f.path).firstOrNull;
      if (c != null) await assetMenu(c, at);
      return null;
    }
    final cawKind = f.newCawKind;
    final libraryParent = f.kind == FilesFolderKind.libraryFolder ? f.libraryPath : '';
    final entries = <MenuEntry<String>>[
      if (f.offersNewCpp) const MenuEntry('cpp', Icons.memory, 'New C++ effect'),
      if (f.offersNewCpp) const MenuEntry('cpp-instrument', Icons.piano_outlined, 'New C++ instrument'),
      if (cawKind != null)
        MenuEntry('caw', Icons.note_add_outlined, switch (cawKind) {
          'effect' => 'New .caw effect',
          'pattern' => 'New pattern',
          _ => 'New .caw module',
        }),
      if (f.kind == FilesFolderKind.cawModules || f.kind == FilesFolderKind.libraryFolder) ...[
        const MenuEntry('import', Icons.file_open_outlined, 'Import .caw module here'),
        const MenuEntry('folder', Icons.create_new_folder_outlined, 'New folder'),
      ],
      if (f.kind == FilesFolderKind.libraryFolder) ...[
        const MenuEntry('rename', Icons.drive_file_rename_outline, 'Rename folder'),
        const MenuEntry('delete', Icons.delete_outline, 'Delete folder', danger: true, dividerBefore: true),
      ],
    ];
    if (entries.isEmpty) return null;
    final action = await showCompactMenu<String>(context, at, entries);
    if (action == null || !context.mounted) return null;
    switch (action) {
      case 'cpp':
        newCppEffect();
      case 'cpp-instrument':
        newCppEffect(instrument: true);
      case 'caw':
        newCawModule(cawKind!, folderPath: libraryParent);
      case 'import':
        await importCawModule(context, state, libraryParent);
      case 'folder':
        await newLibraryFolder(libraryParent);
      case 'rename':
        final next = await askName('Rename folder', f.label, label: 'Folder name');
        if (next == null) return null;
        final parent = libraryParent.contains('/') ? libraryParent.substring(0, libraryParent.lastIndexOf('/')) : '';
        final to = parent.isEmpty ? next : '$parent/$next';
        try {
          if (state.renameLibraryFolder(libraryParent, to)) return 'code/caw/$to';
        } catch (_) {}
        notice('Folder name is invalid or already in use.', error: true);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete folder?'),
            content: Text('Delete "${f.label}"? Its modules move to the parent folder; no module is deleted.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete folder')),
            ],
          ),
        );
        if (ok != true) return null;
        state.deleteLibraryFolder(libraryParent);
        final parent = libraryParent.contains('/') ? libraryParent.substring(0, libraryParent.lastIndexOf('/')) : '';
        return parent.isEmpty ? 'code/caw' : 'code/caw/$parent';
    }
    return null;
  }
}
