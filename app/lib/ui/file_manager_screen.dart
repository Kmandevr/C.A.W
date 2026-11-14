// Files, like Unity's Project window (owner, 2026-11-09): a folder tree, an asset grid with badges, size, breadcrumb, search and filters, and an inspector.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../model/app_state.dart';
import '../model/files_catalog.dart';
import '../model/sample_packs.dart';
import '../model/user_presets.dart';
import 'frame/frame_widgets.dart' show AwakeListenableBuilder, ScrollFade;
import 'keyboard/key_area.dart';
import 'files/asset_actions.dart';
import 'files/asset_inspector.dart';
import 'files/asset_views.dart';
import 'files/files_tree.dart';
import 'files/library_manager.dart';
import 'files/project_file_actions.dart';
import 'files/project_library_view.dart';
import 'files/selection_bar.dart';
import 'frame/sections.dart' show SectionController;
import 'glass.dart';
import 'panel_motion.dart';
import 'arrange/sample_editor.dart';
import 'audio_file_actions.dart';
import 'midi_file_actions.dart';
import 'theme.dart';
import 'tokens.dart';
import 'widgets.dart' show ResetOnDoubleTap;

/// The Files section. Landscape and desktop (wider than tall, or 900 dp and up) show the folder tree on the left;
/// portrait puts it in a drawer and leads with the breadcrumb. Tap selects, double-tap opens in Build, a long
/// press without moving opens the item's menu and a long press that moves drags it onto a track.
class FileManagerScreen extends StatefulWidget {
  const FileManagerScreen({super.key, required this.state, this.onOpenBuilder = _none, this.explorer = false,
      this.folder, this.onOpenAsset, this.activeKey});
  final AppState state;

  /// Build's explorer (#169): one column (breadcrumb, search, a list of folders and items), no filters, tree
  /// drawer or inspector, and a tap opens the item ([onOpenAsset], else as a double-tap would).
  final bool explorer;

  /// The folder shown first (and again whenever it changes), e.g. the open component's.
  final String? folder;
  final ValueChanged<FileAsset>? onOpenAsset;

  /// The item open in the editor, highlighted in the explorer.
  final String? activeKey;

  /// Opens the Builder when Files is shown without the three-section frame (no SectionScope).
  final VoidCallback onOpenBuilder;

  static void _none() {}

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  late String _path = widget.folder ?? 'fx';
  String? _selected;
  String _query = '';
  bool _searchOpen = false;
  final Set<FileAssetFilter> _filters = {};
  late double _size = widget.explorer ? 0 : 0.35; // 0..1; under [_listBelow] the grid is a list
  static const _listBelow = 0.12;
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Select mode (owner, 2026-11-12): checkboxes on the items and the bottom bar with Delete.
  bool _selecting = false;
  final Set<String> _checked = {};
  final _search = TextEditingController();

  AppState get state => widget.state;

  FilesActions get _actions => FilesActions(
        context: context,
        state: state,
        onOpenBuilder: widget.onOpenBuilder,
        onSelect: (key) {
          if (mounted) setState(() => _selected = key);
        },
        onStartSelect: widget.explorer ? null : _startSelect,
      );

  void _startSelect([String? key]) => setState(() {
        _selecting = true;
        if (key != null) _checked.add(key);
      });

  void _endSelect() => setState(() {
        _selecting = false;
        _checked.clear();
      });

  Future<void> _deleteChecked(List<FileAsset> shown) async {
    final list = [for (final a in shown) if (_checked.contains(a.key) && !a.builtin) a];
    if (list.isEmpty) return;
    final uses = {for (final a in list) ...state.usesOf(a)};
    final ok = await confirmDelete(context, list.length, list.length == 1 ? 'item' : 'items',
        detail: uses.isEmpty ? null : 'Some are used on ${uses.take(4).join(', ')}${uses.length > 4 ? '…' : ''}; '
            'deleting removes them there. You can undo this from the message that follows.');
    if (!ok || !mounted) return;
    final done = state.deleteAssets(list);
    SectionController.maybeOf(context)?.pruneBuild(state.buildTabExists);
    _endSelect();
    setState(() => _selected = null);
    showUndoSnack(context, 'Deleted ${done.count} item${done.count == 1 ? '' : 's'}.',
        onUndo: () => state.undoAssetDeletion(done), onGone: () => state.finishAssetDeletion(done));
  }

  @override
  void initState() {
    super.initState();
    state.filesFavourites.load().then((_) {
      if (mounted) setState(() {});
    });
    state.refreshNativeCatalog().then((_) {
      if (mounted) setState(() {});
    });
    state.refreshSamplePacks();
  }

  @override
  void didUpdateWidget(FileManagerScreen old) {
    super.didUpdateWidget(old);
    final f = widget.folder;
    if (f != null && f != old.folder) _go(f);
  }

  @override
  void dispose() {
    _keys.dispose();
    _search.dispose();
    super.dispose();
  }

  void _go(String path) => setState(() {
        if (path != _path) {
          _selecting = false;
          _checked.clear();
        }
        _path = path;
        _query = '';
        _search.clear();
      });

  Future<void> _folderMenu(FilesFolder f, Offset at) async {
    final next = await _actions.folderMenu(f, at);
    if (next != null && mounted) _go(next);
  }

  // ---------- the toolbar ----------

  Widget _iconButton(IconData icon, String tip, VoidCallback? onPressed, {bool selected = false, Color? color}) => IconButton(
        tooltip: tip,
        onPressed: onPressed,
        isSelected: selected,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        iconSize: 18,
        style: IconButton.styleFrom(backgroundColor: selected ? Neon.blue.withValues(alpha: 0.16) : null),
        icon: Icon(icon, color: onPressed == null ? Neon.line : (selected ? Neon.blue : (color ?? Neon.text))),
      );

  Widget _breadcrumb(List<FilesFolder> trail, bool searching) {
    final parts = <Widget>[];
    for (var i = 0; i < trail.length; i++) {
      final f = trail[i];
      final last = i == trail.length - 1 && !searching;
      if (i > 0) parts.add(const Icon(Icons.chevron_right, size: 14, color: Neon.dim));
      parts.add(InkWell(
        borderRadius: BorderRadius.circular(Radii.s),
        onTap: last ? null : () => _go(f.path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Text(f.label, style: TextStyle(fontSize: TypeScale.label, color: last ? Neon.text : Neon.dim,
              fontWeight: last ? FontWeight.w600 : FontWeight.normal)),
        ),
      ));
    }
    if (searching) {
      parts
        ..add(const Icon(Icons.chevron_right, size: 14, color: Neon.dim))
        ..add(const Padding(padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Search', style: TextStyle(fontSize: TypeScale.label, fontWeight: FontWeight.w600))));
    }
    return SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: Row(children: parts));
  }

  Widget _searchField({bool autofocus = false}) => SizedBox(
        height: 32,
        child: TextField(
          controller: _search,
          autofocus: autofocus,
          style: const TextStyle(fontSize: TypeScale.label),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search all files',
            prefixIcon: const Icon(Icons.search, size: 16),
            prefixIconConstraints: const BoxConstraints(minWidth: 30),
            suffixIcon: _query.isEmpty ? null : IconButton(
              tooltip: 'Clear search',
              iconSize: 14,
              onPressed: () => setState(() {
                _query = '';
                _search.clear();
              }),
              icon: const Icon(Icons.close),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.s)),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
      );

  Future<void> _newMenu(Offset at, FilesFolder folder) async {
    final action = await showCompactMenu<String>(context, at, const [
      MenuEntry('cpp', Icons.memory, 'New C++ effect'),
      MenuEntry('cpp-instrument', Icons.piano_outlined, 'New C++ instrument'),
      MenuEntry('starter', Icons.auto_awesome_outlined, 'New from a starter…'),
      MenuEntry('pattern', Icons.piano, 'New pattern'),
    ]);
    if (action == null || !mounted) return;
    switch (action) {
      case 'cpp':
        _actions.newCppEffect();
      case 'cpp-instrument':
        _actions.newCppEffect(instrument: true);
      case 'starter':
        await _actions.newFromStarter();
      case 'pattern':
        _actions.newPattern();
    }
  }

  /// ⋯: everything the old Files screen had (portable files, restore points, the library manager).
  Future<void> _projectMenu(Offset at, FilesFolder folder) async {
    final action = await showCompactMenu<String>(context, at, const [
      MenuEntry('export', Icons.file_upload_outlined, 'Export project…'),
      MenuEntry('import', Icons.file_open_outlined, 'Import project'),
      MenuEntry('midi', Icons.piano, 'Import MIDI file as clips'),
      MenuEntry('audio', Icons.graphic_eq_rounded, 'Import audio files (WAV, FLAC, MP3)'),
      MenuEntry('restore', Icons.bookmark_add_outlined, 'Create restore point', dividerBefore: true),
      MenuEntry('history', Icons.history, 'Version history'),
      MenuEntry('library', Icons.folder_copy_outlined, 'Project library (folders, tags)', dividerBefore: true),
    ]);
    if (action == null || !mounted) return;
    switch (action) {
      case 'export':
        await exportPortableProject(context, state);
      case 'import':
        await importPortableProject(context, state);
        if (mounted) setState(() => _selected = null);
      case 'midi':
        await importMidiFile(context, state);
      case 'audio':
        await importAudioFiles(context, state, place: false);
      case 'restore':
        await createProjectRestorePoint(context, state);
      case 'history':
        await showProjectRestorePoints(context, state);
      case 'library':
        await Navigator.of(context).push(panelRoute<void>(context,
            (_) => LibraryManagerPage(state: state, onOpenBuilder: widget.onOpenBuilder)));
    }
  }

  Offset _centerOf(BuildContext c) {
    final box = c.findRenderObject() as RenderBox;
    return box.localToGlobal(box.size.bottomLeft(Offset.zero));
  }

  Widget _toolbar(List<FilesFolder> trail, bool wide, bool searching, {bool canSelect = false}) {
    final folder = trail.last;
    final projects = folder.kind == FilesFolderKind.projects;
    return SizedBox(
      height: 40,
      child: Row(children: [
        if (!wide && !widget.explorer)
          _iconButton(Icons.account_tree_outlined, 'Folders', () => _scaffold.currentState?.openDrawer()),
        // The explorer has no tree beside it: every folder, indented, from one menu.
        if (widget.explorer)
          Builder(builder: (c) => _iconButton(Icons.account_tree_outlined, 'Folders', () async {
                final all = <(FilesFolder, int)>[];
                void walk(List<FilesFolder> level, int depth) {
                  for (final f in level) {
                    all.add((f, depth));
                    walk(f.children, depth + 1);
                  }
                }

                walk(state.filesTree, 0);
                final path = await showCompactMenu<String>(context, _centerOf(c), [
                  for (final (f, depth) in all) MenuEntry(f.path, folderIcon(f.kind), '${'    ' * depth}${f.label}'),
                ]);
                if (path != null && mounted) _go(path);
              })),
        Expanded(child: _breadcrumb(trail, searching)),
        if (projects)
          const SizedBox.shrink()
        else if (wide)
          SizedBox(width: 200, child: _searchField())
        else
          _iconButton(Icons.search, 'Search', () => setState(() => _searchOpen = !_searchOpen), selected: _searchOpen),
        if (canSelect || _selecting)
          KeyedSubtree(key: const ValueKey('files-select'), child: _iconButton(Icons.checklist, _selecting ? 'Done selecting' : 'Select',
              () => _selecting ? _endSelect() : _startSelect(), selected: _selecting)),
        // Build's own + New makes new files there.
        if (!widget.explorer && !projects) Builder(builder: (c) => _iconButton(Icons.add, 'New', () => _newMenu(_centerOf(c), folder))),
        Builder(builder: (c) => _iconButton(Icons.more_vert, 'Project files', () => _projectMenu(_centerOf(c), folder))),
      ]),
    );
  }

  Widget _filterBar(int count, {required bool narrow}) {
    // Labelled, so what each filter does is plain (the icons alone were guesswork).
    Widget toggle(FileAssetFilter f, IconData icon, String label) {
      final on = _filters.contains(f);
      return Padding(
        padding: const EdgeInsets.only(right: Space.xs),
        child: FilterChip(
          key: ValueKey('filter ${f.name}'),
          selected: on,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          labelPadding: const EdgeInsets.only(left: 2, right: 4),
          avatar: Icon(icon, size: 14, color: on ? Neon.blue : Neon.dim),
          label: Text(label, style: TextStyle(fontSize: 11.5, color: on ? Neon.text : Neon.dim)),
          selectedColor: Neon.blue.withValues(alpha: 0.16),
          side: BorderSide(color: on ? Neon.blue.withValues(alpha: 0.6) : Neon.ink.withValues(alpha: 0.1)),
          onSelected: (_) => setState(() {
            if (!_filters.remove(f)) _filters.add(f);
          }),
        ),
      );
    }
    return SizedBox(
      height: 40,
      child: Row(children: [
        // The chips scroll on a phone; a fade says there are more.
        Expanded(child: ScrollFade(child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(left: Space.s),
          child: Row(children: [
            toggle(FileAssetFilter.effects, Icons.auto_awesome, 'Effects'),
            toggle(FileAssetFilter.instruments, Icons.waves, 'Instruments'),
            toggle(FileAssetFilter.code, Icons.code, 'Code'),
            toggle(FileAssetFilter.patterns, Icons.piano, 'Patterns'),
            const SizedBox(width: Space.xs),
            Text('$count item${count == 1 ? '' : 's'}', style: TypeScale.number(size: TypeScale.caption, color: Neon.dim)),
            const SizedBox(width: Space.s),
          ]),
        ))),
        // A phone gets one list/icons toggle instead of the size slider, so the filters keep the room.
        if (narrow)
          _iconButton(_size < _listBelow ? Icons.grid_view : Icons.view_list, _size < _listBelow ? 'Show as icons' : 'Show as a list',
              () => setState(() => _size = _size < _listBelow ? 0.35 : 0)),
        if (!narrow) ...[
        Tooltip(message: 'List', child: Icon(Icons.view_list, size: 14, color: _size < _listBelow ? Neon.blue : Neon.dim)),
        SizedBox(
          width: 110,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: ResetOnDoubleTap(onReset: () => setState(() => _size = widget.explorer ? 0 : 0.35), child: Slider(
              value: _size,
              label: 'Icon size',
              semanticFormatterCallback: (v) => v < _listBelow ? 'List' : 'Icons ${(v * 100).round()}%',
              onChanged: (v) => setState(() => _size = v),
            )),
          ),
        ),
        const Tooltip(message: 'Large icons', child: Icon(Icons.grid_view, size: 14, color: Neon.dim)),
        ],
        const SizedBox(width: Space.s),
      ]),
    );
  }

  /// Build's explorer: one tap to each kind of code (C++ components, patterns), with counts; the group
  /// the explorer stands in is lit.
  Widget _explorerGroups(String path) {
    final p = state.project;
    final patterns = p.modules.where((m) => state.isPattern(m.id)).length;
    Widget group(String key, String to, IconData icon, Color color, String label, int count) {
      final on = path == to || path.startsWith('$to/');
      return Padding(
        padding: const EdgeInsets.only(right: Space.xs),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('explorer group $key'),
            borderRadius: BorderRadius.circular(Radii.s),
            onTap: () => _go(to),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.s),
                color: on ? color.withValues(alpha: 0.14) : null,
                border: Border.all(color: on ? color.withValues(alpha: 0.6) : Neon.ink.withValues(alpha: 0.08)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 4),
                Text(label, style: TextStyle(fontSize: 11.5, color: on ? Neon.text : Neon.dim)),
                const SizedBox(width: 4),
                Text('$count', style: TypeScale.number(size: 10.5, color: Neon.dim)),
              ]),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 32,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: Space.s), children: [
        group('cpp', 'code/cpp', Icons.memory, Neon.pink, 'C++', p.cppComponents.length),
        group('patterns', 'audio/patterns', Icons.queue_music, Neon.yellow, 'Patterns', patterns),
      ]),
    );
  }

  // ---------- the grid ----------

  String _emptyText(FilesFolder folder, bool searching) {
    if (searching || _filters.isNotEmpty) return 'Nothing matches.';
    return switch (folder.kind) {
      FilesFolderKind.favourites => 'Hold an item and choose Add to Favourites.',
      FilesFolderKind.builtin => 'Built-in effects appear once the engine is running.',
      FilesFolderKind.cppEffects || FilesFolderKind.cppList => 'No C++ effects yet. Hold this folder or tap + for a new one.',
      FilesFolderKind.patterns => 'No patterns yet. Tap + for a new one.',
      FilesFolderKind.presets => 'Your presets show here: Save preset… in a device, or Save track preset… in its ⋯ '
          'menu. Drag one onto a track, or onto the empty area for a new track.',
      FilesFolderKind.audioFiles => 'Audio files show here (⋯ › Import audio files, or a recording); drag one onto a '
          'track, or onto the empty area for a new audio track.',
      FilesFolderKind.midiFiles => 'Imported MIDI files show here (⋯ › Import MIDI file as clips); drag one onto a track.',
      _ => 'This folder is empty.',
    };
  }

  Widget _grid(FilesFolder folder, List<FilesFolder> subfolders, List<FileAsset> assets, bool searching) {
    if (subfolders.isEmpty && assets.isEmpty) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Text(_emptyText(folder, searching), textAlign: TextAlign.center,
            style: const TextStyle(color: Neon.dim, fontSize: TypeScale.label)),
      ));
    }
    final list = _size < _listBelow;
    final extent = 64 + 96 * ((_size - _listBelow) / (1 - _listBelow)).clamp(0.0, 1.0);
    final actions = _actions;
    Widget assetItem(FileAsset a) {
      final selected = a.key == (widget.explorer ? widget.activeKey ?? _selected : _selected);
      final fav = state.isFavourite(a);
      final warning = a.type == FileAssetType.cppComponent && state.cppStatus(a.cpp!) != null;
      final check = _selecting && !a.builtin ? _checked.contains(a.key) : null;
      return AssetGestures(
        key: ValueKey(a.key),
        asset: a,
        onSelect: () {
          _keys.requestFocus();
          if (_selecting) {
            if (!a.builtin) setState(() => _checked.contains(a.key) ? _checked.remove(a.key) : _checked.add(a.key));
            return;
          }
          setState(() => _selected = a.key);
          // An audio file opens in the sample editor (owner, 2026-11-14: a tap in Files).
          if (a.type == FileAssetType.audioFile && a.audio != null) return openSampleEditor(context, state, a.audio!);
          if (widget.explorer) (widget.onOpenAsset ?? actions.open)(a);
        },
        onOpen: () => widget.explorer || _selecting ? null : actions.open(a),
        onMenu: (at) => actions.assetMenu(a, at),
        child: list
            ? AssetRow(asset: a, selected: selected, favourite: fav, warning: warning,
                detail: searching ? a.type.label : null, checked: check)
            : AssetTile(asset: a, extent: extent, selected: selected, favourite: fav, warning: warning, checked: check),
      );
    }

    Widget folderItem(FilesFolder f) => FolderItem(
          key: ValueKey('folder:${f.path}'),
          folder: f,
          list: list,
          extent: extent,
          onOpen: () => _go(f.path),
          onMenu: (at) => _folderMenu(f, at),
        );
    final count = subfolders.length + assets.length;
    Widget item(int i) => i < subfolders.length ? folderItem(subfolders[i]) : assetItem(assets[i - subfolders.length]);
    final body = list
        ? ListView.builder(
            padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, Space.xl),
            itemCount: count,
            itemBuilder: (_, i) => Padding(padding: const EdgeInsets.only(bottom: 2), child: item(i)),
          )
        : GridView.builder(
            padding: const EdgeInsets.fromLTRB(Space.s, Space.xs, Space.s, Space.xl),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: extent,
              childAspectRatio: 0.82,
              mainAxisSpacing: Space.xs,
              crossAxisSpacing: Space.xs,
            ),
            itemCount: count,
            itemBuilder: (_, i) => item(i),
          );
    // A tap on empty space clears the selection. The keyboard moves it (arrows), opens (Enter), renames (F2) and
    // deletes (Delete, asking first) once the grid has focus (a click on an item gives it).
    return LayoutBuilder(builder: (context, c) {
      // As the grid lays out: as many columns as fit [extent] wide (SliverGridDelegateWithMaxCrossAxisExtent).
      final columns = list ? 1 : math.max(1, ((c.maxWidth - 2 * Space.s) / (extent + Space.xs)).ceil());
      return KeyArea(
        area: Area.files,
        label: widget.explorer ? 'Explorer' : 'Files',
        focusNode: _keys,
        onAction: (id, count, _) => _onKey(id, count, assets, columns),
        child: GestureDetector(behavior: HitTestBehavior.deferToChild, onTap: () => setState(() => _selected = null),
            child: body),
      );
    });
  }

  /// The grid's keys (owner, 2026-11-11: a desktop browses Files from the keyboard): the Files context's arrows and
  /// WASD move the selection, Enter opens, F2 renames, Delete deletes (asking first).
  final _keys = FocusNode(debugLabel: 'files-grid');

  bool _onKey(String id, int count, List<FileAsset> assets, int columns) {
    if (assets.isEmpty) return false;
    final i = assets.indexWhere((a) => a.key == _selected);
    final step = switch (id) {
          'files.right' => 1,
          'files.left' => -1,
          'files.down' => columns,
          'files.up' => -columns,
          _ => 0,
        } *
        count;
    if (step != 0) {
      final next = i < 0 ? (step > 0 ? 0 : assets.length - 1) : (i + step).clamp(0, assets.length - 1);
      setState(() => _selected = assets[next].key);
      return true;
    }
    if (i < 0) return false;
    final a = assets[i], actions = _actions;
    switch (id) {
      case 'files.open':
        (widget.explorer ? (widget.onOpenAsset ?? actions.open) : actions.open)(a);
      case 'files.rename' when !a.builtin && a.sample == null:
        unawaited(actions.rename(a));
      case 'files.delete' when !a.builtin:
        unawaited(actions.delete(a));
      default:
        return false;
    }
    return true;
  }

  @override
  // Asleep while Files is behind another section (frame_widgets.dart).
  Widget build(BuildContext context) => AwakeListenableBuilder(
        listenable: Listenable.merge([state, state.userPresets, state.samplePacksTick]),
        builder: (context, _) => LayoutBuilder(builder: (context, c) {
          // A small docked panel in a landscape window still uses the drawer: the tree needs room beside the grid.
          final wide = !widget.explorer && (c.maxWidth > c.maxHeight || c.maxWidth >= 900) && c.maxWidth >= 560;
          final tree = state.filesTree;
          var trail = state.folderTrail(_path);
          if (trail.isEmpty) trail = state.folderTrail('fx');
          final folder = trail.last;
          final searching = _query.trim().isNotEmpty;
          final assets = searching
              ? state.searchAssets(_query, _filters)
              : state.folderAssets(folder).where((a) => state.passes(a, _filters)).toList();
          final subfolders = searching ? const <FilesFolder>[] : folder.children;
          final selected = _selected == null ? null : state.assetByKey(_selected!);
          final sideInspector = wide && c.maxWidth >= 1000;
          final actions = _actions;
          Widget inspector({required bool compact}) => AssetInspector(
                key: ValueKey('inspector:${selected!.key}'),
                state: state,
                asset: selected,
                actions: actions,
                compact: compact,
                onClose: () => setState(() => _selected = null),
              );
          final treeView = FilesTree(
            tree: tree,
            current: searching ? '' : folder.path,
            onOpen: (f) {
              _go(f.path);
              if (!wide) _scaffold.currentState?.closeDrawer();
            },
            onMenu: _folderMenu,
          );
          final deletable = [for (final a in assets) if (!a.builtin) a];
          _checked.removeWhere((k) => !deletable.any((a) => a.key == k));
          final Widget main;
          if (folder.kind == FilesFolderKind.projects) {
            main = Column(children: [
              _toolbar(trail, wide, false),
              Expanded(child: ProjectLibraryView(state: state)),
            ]);
          } else {
          main = Column(children: [
            _toolbar(trail, wide, searching, canSelect: !widget.explorer && deletable.isNotEmpty),
            if (widget.explorer && !searching) _explorerGroups(folder.path),
            if (!wide && _searchOpen)
              Padding(padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.xs), child: _searchField(autofocus: true)),
            if (!widget.explorer) _filterBar(subfolders.length + assets.length, narrow: c.maxWidth < 480),
            Expanded(child: _grid(folder, subfolders, assets, searching)),
            if (selected != null && !sideInspector && !widget.explorer && !_selecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.s),
                child: GlassPanel(child: inspector(compact: true)),
              ),
            if (!widget.explorer)
              SelectionBar(
                visible: _selecting,
                count: _checked.length,
                total: deletable.length,
                onAll: () => setState(() => _checked.addAll(deletable.map((a) => a.key))),
                onNone: () => setState(_checked.clear),
                actions: [
                  SelectionAction('delete', Icons.delete_outline, 'Delete', () => _deleteChecked(assets), danger: true),
                ],
              ),
          ]);
          }
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: c.maxWidth >= 900 ? 240 : 200,
                child: Padding(padding: const EdgeInsets.all(Space.s), child: GlassPanel(
                    child: KeyArea(area: Area.page, label: 'Folders', child: treeView))),
              ),
              Expanded(child: main),
              if (sideInspector)
                SizedBox(
                  width: 280,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.s),
                    child: GlassPanel(child: KeyArea(area: Area.page, label: 'Inspector', child: selected == null
                        ? const Center(child: Text('Tap an item to see it here', style: TextStyle(color: Neon.dim, fontSize: TypeScale.label)))
                        : Align(alignment: Alignment.topCenter, child: inspector(compact: false)))),
                  ),
                ),
            ]);
          }
          if (widget.explorer) return main;
          return Scaffold(
            key: _scaffold,
            backgroundColor: Colors.transparent,
            drawer: Drawer(
              width: 280,
              backgroundColor: Neon.panel.withValues(alpha: Glass.active ? 0.92 : 1),
              child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.xs),
                    child: Text('FOLDERS', style: TypeScale.heading())),
                Expanded(child: KeyArea(area: Area.page, label: 'Folders', autofocus: true, child: treeView)),
              ])),
            ),
            body: main,
          );
        }),
      );
}
