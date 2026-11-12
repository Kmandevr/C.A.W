// What Files does with an asset or folder: open it in Build, audition it, its long-press menu, rename, duplicate,
// delete, new C++ effects and instruments (blank or from a starter) and new patterns.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../model/pattern_templates.dart' show PatternTemplate;
import '../../model/app_state.dart';
import '../../model/cpp_starters.dart';
import '../../model/cpp_workbench.dart';
import '../../model/files_catalog.dart';
import '../../model/pattern_doc.dart';
import '../../model/user_presets.dart';
import '../../platform/save_copy.dart';
import '../cpp/build_start.dart' show ExamplesList, StarterExample;
import '../cpp/sample_pack_screen.dart' show openSamplePackMaker;
import '../devices/kit/preset_actions.dart' show exportPreset, importPreset;
import '../frame/sections.dart';
import '../glass.dart';
import '../pattern_fields.dart' show editPatternHeader;
import '../theme.dart';
import 'asset_views.dart';
import '../panel_motion.dart';

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

  /// Double-tap: a C++ component or file opens in a C++ Builder tab, a pattern in a pattern tab.
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

  /// ▶: Solo preview (the audition) of a pattern, starting the transport when it was stopped.
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
      context: context, animationStyle: dialogAnimation(context),
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
      context: context, animationStyle: dialogAnimation(context),
      builder: (context) => AlertDialog(
        title: Text('Delete "${a.name}"?'),
        content: Text(a.sample != null
            ? 'The WAV file is deleted from this device; undo can\'t bring it back.'
            : uses.isEmpty
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
      if (!a.builtin && a.sample == null) const MenuEntry('rename', Icons.drive_file_rename_outline, 'Rename'),
      if (!a.builtin && a.midi == null && a.sample == null) const MenuEntry('duplicate', Icons.copy, 'Duplicate'),
      if (a.isInstrument) const MenuEntry('sample-pack', Icons.library_music_outlined, 'Make sample pack…'),
      if (a.sample != null) const MenuEntry('save-wav', Icons.file_upload_outlined, 'Save WAV…'),
      if (a.module != null) const MenuEntry('tags', Icons.sell_outlined, 'Edit tags'),
      if (a.preset != null) const MenuEntry('export-preset', Icons.file_upload_outlined, 'Export preset file'),
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
      case 'export-preset':
        await exportPreset(context, a.preset!);
      case 'sample-pack':
        await openSamplePackMaker(context, state, instrumentId: a.native?.id ?? a.cpp?.componentId);
      case 'save-wav':
        try {
          final saved = await saveCopyOf(File(a.sample!.path), name: a.sample!.file, mimeType: 'audio/wav', extension: 'wav');
          if (saved) notice('Saved "${a.sample!.file}".');
        } catch (e) {
          notice('Could not save: $e', error: true);
        }
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

  /// "New from a starter": the C++ starters (instruments and effects, examples/cpp/starters) to copy into the
  /// project and open in Build. They replace the .caw templates (#160).
  Future<void> newFromStarter() async {
    final picked = await showGlassSheet<StarterExample>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      builder: (c) => ExamplesList(
          examples: [for (final s in cppStarters) StarterExample.cpp(s)], onPick: (e) => Navigator.pop(c, e)),
    );
    final starter = picked?.starter;
    if (starter == null || !context.mounted) return;
    final doc = state.addCppStarter(starter);
    onSelect('cpp:${doc.id}');
    final sections = SectionController.maybeOf(context);
    if (sections != null) {
      sections.openBuild(BuildTab(BuildTabKind.cpp, doc.componentId));
    } else {
      notice('Added "${doc.name}".');
    }
  }

  /// "New pattern", with its header at once, opened in Build.
  void newPattern() {
    final id = state.addModule(PatternTemplate('Pattern', PatternDoc.blank().serialize()));
    final m = state.project.module(id)!;
    m.source = m.runSource = editPatternHeader(m.source, m.name, name: m.name) ?? m.source;
    onSelect('mod:$id');
    final sections = SectionController.maybeOf(context);
    if (sections != null) {
      sections.openBuild(BuildTab(BuildTabKind.pattern, id));
    } else {
      onOpenBuilder();
    }
  }

  /// The long-press menu of a folder (in the tree or the grid). Returns the path to show after it, or null to stay.
  Future<String?> folderMenu(FilesFolder f, Offset at) async {
    if (f.kind == FilesFolderKind.cppComponent) {
      final c = state.cppAssets.where((a) => 'code/cpp/${a.cpp!.id}' == f.path).firstOrNull;
      if (c != null) await assetMenu(c, at);
      return null;
    }
    final entries = <MenuEntry<String>>[
      if (f.offersNewCpp) const MenuEntry('cpp', Icons.memory, 'New C++ effect'),
      if (f.offersNewCpp) const MenuEntry('cpp-instrument', Icons.piano_outlined, 'New C++ instrument'),
      if (f.offersNewCpp) const MenuEntry('starter', Icons.auto_awesome_outlined, 'New from a starter…'),
      if (f.offersNewPattern) const MenuEntry('pattern', Icons.note_add_outlined, 'New pattern'),
      if (f.kind == FilesFolderKind.presets)
        const MenuEntry('import-preset', Icons.file_open_outlined, 'Import preset file…'),
      if (f.kind == FilesFolderKind.samplePacks || f.kind == FilesFolderKind.audio)
        const MenuEntry('sample-pack', Icons.library_music_outlined, 'Make sample pack…'),
    ];
    if (entries.isEmpty) return null;
    final action = await showCompactMenu<String>(context, at, entries);
    if (action == null || !context.mounted) return null;
    switch (action) {
      case 'cpp':
        newCppEffect();
      case 'cpp-instrument':
        newCppEffect(instrument: true);
      case 'starter':
        await newFromStarter();
      case 'pattern':
        newPattern();
      case 'import-preset':
        await importPreset(context, state.userPresets);
      case 'sample-pack':
        await openSamplePackMaker(context, state);
        return 'audio/samples';
    }
    return null;
  }
}
