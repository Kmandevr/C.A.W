// Files, like Unity's Project window (owner, 2026-11-09): a folder tree, an asset grid with badges, size, breadcrumb, search and filters, and an inspector.
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/files_catalog.dart';
import 'files/asset_actions.dart';
import 'files/asset_inspector.dart';
import 'files/asset_views.dart';
import 'files/files_tree.dart';
import 'files/library_manager.dart';
import 'glass.dart';
import 'midi_file_actions.dart';
import 'theme.dart';
import 'tokens.dart';

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
  final _search = TextEditingController();

  AppState get state => widget.state;

  FilesActions get _actions => FilesActions(
        context: context,
        state: state,
        onOpenBuilder: widget.onOpenBuilder,
        onSelect: (key) {
          if (mounted) setState(() => _selected = key);
        },
      );

  @override
  void initState() {
    super.initState();
    state.filesFavourites.load().then((_) {
      if (mounted) setState(() {});
    });
    state.refreshNativeCatalog().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(FileManagerScreen old) {
    super.didUpdateWidget(old);
    final f = widget.folder;
    if (f != null && f != old.folder) _go(f);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _go(String path) => setState(() {
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
      MenuEntry('effect', Icons.tune, 'New .caw effect'),
      MenuEntry('generator', Icons.waves, 'New .caw instrument'),
      MenuEntry('pattern', Icons.piano, 'New pattern'),
    ]);
    if (action == null || !mounted) return;
    if (action == 'cpp') {
      _actions.newCppEffect();
    } else {
      _actions.newCawModule(action, folderPath: folder.libraryPath);
    }
  }

  /// ⋯: everything the old Files screen had (portable files, restore points, the library manager).
  Future<void> _projectMenu(Offset at, FilesFolder folder) async {
    final action = await showCompactMenu<String>(context, at, const [
      MenuEntry('export', Icons.file_upload_outlined, 'Export .cawproj'),
      MenuEntry('import', Icons.file_open_outlined, 'Import project'),
      MenuEntry('module', Icons.note_add_outlined, 'Import .caw module'),
      MenuEntry('midi', Icons.piano, 'Import MIDI file as clips'),
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
      case 'module':
        await importCawModule(context, state, folder.libraryPath);
      case 'midi':
        await importMidiFile(context, state);
      case 'restore':
        await createProjectRestorePoint(context, state);
      case 'history':
        await showProjectRestorePoints(context, state);
      case 'library':
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => LibraryManagerPage(state: state, onOpenBuilder: widget.onOpenBuilder)));
    }
  }

  Offset _centerOf(BuildContext c) {
    final box = c.findRenderObject() as RenderBox;
    return box.localToGlobal(box.size.bottomLeft(Offset.zero));
  }

  Widget _toolbar(List<FilesFolder> trail, bool wide, bool searching) {
    final folder = trail.last;
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
        if (wide)
          SizedBox(width: 200, child: _searchField())
        else
          _iconButton(Icons.search, 'Search', () => setState(() => _searchOpen = !_searchOpen), selected: _searchOpen),
        // Build's own + New makes new files there.
        if (!widget.explorer) Builder(builder: (c) => _iconButton(Icons.add, 'New', () => _newMenu(_centerOf(c), folder))),
        Builder(builder: (c) => _iconButton(Icons.more_vert, 'Project files', () => _projectMenu(_centerOf(c), folder))),
      ]),
    );
  }

  Widget _filterBar(int count, {required bool narrow}) {
    Widget toggle(FileAssetFilter f, IconData icon, String tip) => _iconButton(icon, tip, () => setState(() {
          if (!_filters.remove(f)) _filters.add(f);
        }), selected: _filters.contains(f));
    return SizedBox(
      height: 40,
      child: Row(children: [
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          toggle(FileAssetFilter.effects, Icons.auto_awesome, 'Effects'),
          toggle(FileAssetFilter.instruments, Icons.waves, 'Instruments'),
          toggle(FileAssetFilter.code, Icons.code, 'Code'),
          toggle(FileAssetFilter.patterns, Icons.piano, 'Patterns'),
          const SizedBox(width: Space.xs),
          Text('$count', style: TypeScale.number(size: TypeScale.caption, color: Neon.dim)),
        ]))),
        Tooltip(message: 'List', child: Icon(Icons.view_list, size: 14, color: _size < _listBelow ? Neon.blue : Neon.dim)),
        SizedBox(
          width: narrow ? 64 : 110,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: _size,
              label: 'Icon size',
              semanticFormatterCallback: (v) => v < _listBelow ? 'List' : 'Icons ${(v * 100).round()}%',
              onChanged: (v) => setState(() => _size = v),
            ),
          ),
        ),
        const Tooltip(message: 'Large icons', child: Icon(Icons.grid_view, size: 14, color: Neon.dim)),
        const SizedBox(width: Space.s),
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
      return AssetGestures(
        key: ValueKey(a.key),
        asset: a,
        onSelect: () {
          setState(() => _selected = a.key);
          if (widget.explorer) (widget.onOpenAsset ?? actions.open)(a);
        },
        onOpen: () => widget.explorer ? null : actions.open(a),
        onMenu: (at) => actions.assetMenu(a, at),
        child: list
            ? AssetRow(asset: a, selected: selected, favourite: fav, warning: warning,
                detail: searching ? a.type.label : null)
            : AssetTile(asset: a, extent: extent, selected: selected, favourite: fav, warning: warning),
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
    // A tap on empty space clears the selection.
    return GestureDetector(behavior: HitTestBehavior.deferToChild, onTap: () => setState(() => _selected = null), child: body);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
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
          final main = Column(children: [
            _toolbar(trail, wide, searching),
            if (!wide && _searchOpen)
              Padding(padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.xs), child: _searchField(autofocus: true)),
            if (!widget.explorer) _filterBar(subfolders.length + assets.length, narrow: c.maxWidth < 360),
            Expanded(child: _grid(folder, subfolders, assets, searching)),
            if (selected != null && !sideInspector && !widget.explorer)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.s),
                child: GlassPanel(child: inspector(compact: true)),
              ),
          ]);
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: c.maxWidth >= 900 ? 240 : 200,
                child: Padding(padding: const EdgeInsets.all(Space.s), child: GlassPanel(child: treeView)),
              ),
              Expanded(child: main),
              if (sideInspector)
                SizedBox(
                  width: 280,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.s),
                    child: GlassPanel(child: selected == null
                        ? const Center(child: Text('Tap an item to see it here', style: TextStyle(color: Neon.dim, fontSize: TypeScale.label)))
                        : Align(alignment: Alignment.topCenter, child: inspector(compact: false))),
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
                Expanded(child: treeView),
              ])),
            ),
            body: main,
          );
        }),
      );
}
