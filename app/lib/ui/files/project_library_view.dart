// Files › Projects (owner, 2026-11-12, "Select mode + folders"): the saved projects as cards with their details, in
// folders that nest, with search, sort, select mode (Delete with Undo, Move to folder, Export) and drag into a folder.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project_library.dart';
import '../../model/storage.dart' show StorageUse;
import '../../platform/save_copy.dart';
import '../glass.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../pointer_input.dart';
import '../theme.dart';
import '../tokens.dart';
import 'asset_views.dart' show MenuEntry, showCompactMenu;
import 'selection_bar.dart';

/// What a held project carries onto a folder: the selection when it is in it, else itself.
class ProjectDrag {
  const ProjectDrag(this.ids);
  final List<String> ids;
}

/// The system picker Export uses, for tests to replace: a folder, and each file with the name it gets there.
class ProjectExportPicker {
  ProjectExportPicker._();
  static Future<int> Function(List<(File, String)> files) saveFolder =
      (files) => saveCopiesToFolder(files, mimeType: 'application/json');
}

/// "12 Nov 2026" in local time.
String libraryDate(DateTime? t) {
  if (t == null) return 'unknown';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  return '${l.day} ${months[l.month - 1]} ${l.year}';
}

/// "1:32" (or "1:02:05").
String libraryLength(double seconds) {
  final s = seconds.isFinite ? seconds.round() : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  final two = r.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$two' : '$m:$two';
}

/// A name a file can take on any system ("Song (2).caw").
String exportFileName(String name, Set<String> taken) {
  var base = name.replaceAll(RegExp(r'[^A-Za-z0-9 ._()-]'), '_').trim();
  if (base.isEmpty || base.startsWith('.')) base = 'Project$base';
  if (base.length > 80) base = base.substring(0, 80);
  var out = '$base.caw';
  for (var n = 2; taken.contains(out.toLowerCase()); n++) {
    out = '$base ($n).caw';
  }
  taken.add(out.toLowerCase());
  return out;
}

class ProjectLibraryView extends StatefulWidget {
  const ProjectLibraryView({super.key, required this.state});
  final AppState state;

  @override
  State<ProjectLibraryView> createState() => _ProjectLibraryViewState();
}

class _ProjectLibraryViewState extends State<ProjectLibraryView> {
  String? _folder;
  String _query = '';
  ProjectSort _sort = ProjectSort.edited;
  bool _selecting = false;
  final Set<String> _selected = {};
  bool _loading = true;
  String? _openId;
  final _search = TextEditingController();

  AppState get state => widget.state;
  ProjectLibrary? get lib => state.storage?.library;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await state.flush(); // the open project's card shows its latest details
      await lib?.refresh();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _notice(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  // ---------- select mode ----------

  void _startSelect([String? id]) {
    Motion.tick();
    setState(() {
      _selecting = true;
      if (id != null) _selected.add(id);
    });
  }

  void _endSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggle(String id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  Future<void> _delete() async {
    final ids = _selected.toList();
    final l = lib;
    if (ids.isEmpty || l == null) return;
    final open = ids.contains(state.project.id);
    final ok = await confirmDelete(context, ids.length, ids.length == 1 ? 'project' : 'projects',
        detail: 'Their audio, samples and restore points go with them. You can undo this from the message that '
            'follows${open ? '; the open project closes' : ''}.');
    if (!ok || !mounted) return;
    final batch = await state.trashProjects(ids);
    if (!mounted || batch == null) return;
    _endSelect();
    showUndoSnack(context, 'Deleted ${batch.projectIds.length} project${batch.projectIds.length == 1 ? '' : 's'}.',
        onUndo: () async {
      await state.restoreProjects(batch);
      if (mounted) setState(() {});
    }, onGone: () => l.purge(batch));
  }

  Future<void> _moveSelected() async {
    final target = await _pickFolder('Move ${_selected.length} to…');
    if (target == null || !mounted) return;
    lib?.moveProjects(_selected, target.$1);
    _endSelect();
    _notice('Moved to ${target.$1 == null ? 'Projects' : lib!.folders[target.$1]?.name ?? 'the folder'}.');
  }

  Future<void> _export() async {
    final l = lib;
    if (l == null) return;
    if (_selected.contains(state.project.id)) await state.flush();
    final taken = <String>{};
    final files = [
      for (final p in l.projects)
        if (_selected.contains(p.id))
          (File('${l.root.path}${Platform.pathSeparator}${p.id}.json'), exportFileName(p.name, taken)),
    ];
    try {
      final n = await ProjectExportPicker.saveFolder(files);
      if (!mounted) return;
      if (n < 0) return _notice('Export cancelled.');
      _endSelect();
      _notice('Exported $n project file${n == 1 ? '' : 's'} (.caw, the project data; Export project… packages samples too).');
    } catch (e) {
      if (mounted) _notice('Export failed: $e');
    }
  }

  // ---------- folders ----------

  Future<String?> _askName(String title, String initial) async {
    final c = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      animationStyle: dialogAnimation(context),
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const ValueKey('folder-name'),
          controller: c,
          autofocus: true,
          maxLength: LibraryLimits.folderName,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('folder-name-ok'), onPressed: () => Navigator.pop(context, c.text),
              child: const Text('OK')),
        ],
      ),
    );
    c.dispose();
    return result == null || result.trim().isEmpty ? null : result.trim();
  }

  Future<ProjectFolder?> _newFolder({String? parent}) async {
    final name = await _askName('New folder', '');
    if (name == null || !mounted) return null;
    try {
      final f = lib!.createFolder(name, parent: parent);
      setState(() {});
      return f;
    } catch (e) {
      _notice('Folder could not be made: $e');
      return null;
    }
  }

  /// A sheet listing the top level and every folder, indented; returns the pick as (folder id or null).
  Future<(String?,)?> _pickFolder(String title, {String? excluding}) {
    final l = lib!;
    final rows = <(ProjectFolder, int)>[];
    void walk(String? parent, int depth) {
      for (final f in l.childFolders(parent)) {
        if (f.id == excluding) continue;
        rows.add((f, depth));
        walk(f.id, depth + 1);
      }
    }

    walk(null, 1);
    return showGlassSheet<(String?,)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.s),
              child: Text(title, style: const TextStyle(fontSize: TypeScale.title))),
          ListTile(
            key: const ValueKey('move-target:top'),
            dense: true,
            leading: const Icon(Icons.home_outlined, color: Neon.blue),
            title: const Text('Projects (top level)'),
            onTap: () => Navigator.pop(c, (null,)),
          ),
          for (final (f, depth) in rows)
            ListTile(
              key: ValueKey('move-target:${f.id}'),
              dense: true,
              contentPadding: EdgeInsets.only(left: Space.l + 16.0 * depth, right: Space.l),
              leading: const Icon(Icons.folder, color: Neon.blue),
              title: Text(f.name),
              onTap: () => Navigator.pop(c, (f.id,)),
            ),
          ListTile(
            key: const ValueKey('move-target:new'),
            dense: true,
            leading: const Icon(Icons.create_new_folder_outlined, color: Neon.green),
            title: const Text('New folder…'),
            onTap: () async {
              final made = await _newFolder(parent: _folder);
              if (made != null && c.mounted) Navigator.pop(c, (made.id,));
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _folderMenu(ProjectFolder f, Offset at) async {
    final action = await showCompactMenu<String>(context, at, const [
      MenuEntry('open', Icons.folder_open, 'Open'),
      MenuEntry('rename', Icons.drive_file_rename_outline, 'Rename'),
      MenuEntry('new', Icons.create_new_folder_outlined, 'New folder inside'),
      MenuEntry('move', Icons.drive_file_move_outline, 'Move to…'),
      MenuEntry('delete', Icons.delete_outline, 'Delete folder', danger: true, dividerBefore: true),
    ]);
    if (action == null || !mounted) return;
    final l = lib!;
    switch (action) {
      case 'open':
        _go(f.id);
      case 'rename':
        final name = await _askName('Rename folder', f.name);
        if (name != null) setState(() => l.renameFolder(f.id, name));
      case 'new':
        await _newFolder(parent: f.id);
      case 'move':
        final to = await _pickFolder('Move "${f.name}" to…', excluding: f.id);
        if (to != null && mounted && !l.moveFolder(f.id, to.$1)) _notice('A folder can\'t go inside itself.');
        if (mounted) setState(() {});
      case 'delete':
        await _deleteFolder(f);
    }
  }

  Future<void> _deleteFolder(ProjectFolder f) async {
    final l = lib!;
    if (!l.isEmpty(f.id)) {
      final ok = await showDialog<bool>(
        context: context,
        animationStyle: dialogAnimation(context),
        builder: (context) => AlertDialog(
          title: Text('Delete "${f.name}"?'),
          content: const Text('It isn\'t empty: what is in it moves up a level first. No project is deleted.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('folder-delete-ok'), onPressed: () => Navigator.pop(context, true),
                child: const Text('Move up and delete')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      l.deleteFolder(f.id, moveContentsUp: true);
      if (l.trail(_folder).isEmpty) _folder = null;
    });
  }

  void _go(String? folder) => setState(() => _folder = folder);

  void _drop(ProjectDrag d, String? folder) {
    Motion.tick();
    setState(() {
      lib?.moveProjects(d.ids, folder);
      _selected.removeAll(d.ids);
    });
  }

  // ---------- the header ----------

  Widget _header() => SizedBox(
        height: 44,
        child: Row(children: [
          const SizedBox(width: Space.s),
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                key: const ValueKey('projects-search'),
                controller: _search,
                style: const TextStyle(fontSize: TypeScale.label),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search projects',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          iconSize: 14,
                          onPressed: () => setState(() {
                            _query = '';
                            _search.clear();
                          }),
                          icon: const Icon(Icons.close)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.s)),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
          Builder(builder: (c) => IconButton(
                key: const ValueKey('projects-sort'),
                tooltip: 'Sort: ${_sort.label}',
                icon: const Icon(Icons.sort, size: 20),
                onPressed: () async {
                  final box = c.findRenderObject() as RenderBox;
                  final next = await showCompactMenu<ProjectSort>(context, box.localToGlobal(box.size.bottomLeft(Offset.zero)), [
                    for (final s in ProjectSort.values)
                      MenuEntry(s, s == _sort ? Icons.check : Icons.sort, s.label),
                  ]);
                  if (next != null && mounted) setState(() => _sort = next);
                },
              )),
          IconButton(
            key: const ValueKey('projects-new-folder'),
            tooltip: 'New folder',
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            onPressed: lib == null || _selecting ? null : () => _newFolder(parent: _folder),
          ),
          TextButton(
            key: const ValueKey('projects-select'),
            onPressed: lib == null ? null : (_selecting ? _endSelect : _startSelect),
            child: AnimatedSwitcher(
              duration: Motion.fade(Motion.standard, Motion.of(context)),
              child: Text(_selecting ? 'Done' : 'Select', key: ValueKey(_selecting)),
            ),
          ),
          const SizedBox(width: Space.xs),
        ]),
      );

  Widget _crumbs(bool searching) {
    final l = lib!;
    final trail = l.trail(_folder);
    final parts = <Widget>[];
    Widget crumb(String label, String? folder, bool last) => DragTarget<ProjectDrag>(
          onWillAcceptWithDetails: (_) => !last,
          onAcceptWithDetails: (d) => _drop(d.data, folder),
          builder: (context, hover, _) => AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.usabilityOf(context)),
            decoration: BoxDecoration(
              color: hover.isNotEmpty ? Neon.blue.withValues(alpha: 0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.s),
            ),
            child: InkWell(
              key: ValueKey('crumb:${folder ?? 'top'}'),
              borderRadius: BorderRadius.circular(Radii.s),
              onTap: last ? null : () => _go(folder),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Text(label, style: TextStyle(fontSize: TypeScale.label, color: last ? Neon.text : Neon.dim,
                    fontWeight: last ? FontWeight.w600 : FontWeight.normal)),
              ),
            ),
          ),
        );
    parts.add(crumb('Projects', null, trail.isEmpty && !searching));
    for (var i = 0; i < trail.length; i++) {
      parts
        ..add(const Icon(Icons.chevron_right, size: 14, color: Neon.dim))
        ..add(crumb(trail[i].name, trail[i].id, i == trail.length - 1 && !searching));
    }
    if (searching) {
      parts
        ..add(const Icon(Icons.chevron_right, size: 14, color: Neon.dim))
        ..add(const Padding(padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Search', style: TextStyle(fontSize: TypeScale.label, fontWeight: FontWeight.w600))));
    }
    return SizedBox(
      height: 32,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        child: Row(children: parts),
      ),
    );
  }

  // ---------- the list ----------

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final l = lib;
          if (l == null) {
            return const Center(child: Text('Projects show here once storage has opened.',
                style: TextStyle(color: Neon.dim, fontSize: TypeScale.label)));
          }
          if (l.trail(_folder).isEmpty) _folder = null;
          // Another project opened: the one left gets its latest details (it was saved on the way out).
          if (_openId != state.project.id) {
            final first = _openId == null;
            _openId = state.project.id;
            if (!first) Future.microtask(_refresh);
          }
          final searching = _query.trim().isNotEmpty;
          final folders = searching ? const <ProjectFolder>[] : l.childFolders(_folder);
          final projects = sortProjects(searching ? searchProjects(l.projects, _query) : l.projectsIn(_folder), _sort);
          _selected.removeWhere((id) => !l.projects.any((p) => p.id == id));
          final visible = projects.map((p) => p.id).toSet();
          final level = Motion.of(context);
          final Widget list;
          if (_loading && l.projects.isEmpty) {
            list = const Center(key: ValueKey('loading'), child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)));
          } else if (folders.isEmpty && projects.isEmpty) {
            list = Center(
              key: ValueKey('empty:$_folder:$searching'),
              child: Padding(
                padding: const EdgeInsets.all(Space.l),
                child: Text(
                    searching ? 'No project matches.' : _folder == null ? 'No saved projects yet.'
                        : 'This folder is empty. Hold a project and drag it here, or use Select › Move.',
                    textAlign: TextAlign.center, style: const TextStyle(color: Neon.dim, fontSize: TypeScale.label)),
              ),
            );
          } else {
            list = ListView(
              key: ValueKey('list:$_folder:$searching'),
              padding: const EdgeInsets.fromLTRB(Space.s, Space.xs, Space.s, Space.xl),
              children: [
                for (final f in folders)
                  LibraryFolderRow(
                    key: ValueKey('project-folder:${f.id}'),
                    folder: f,
                    projects: l.projectsIn(f.id).length,
                    folders: l.childFolders(f.id).length,
                    onOpen: () => _go(f.id),
                    onMenu: (at) => _folderMenu(f, at),
                    onDrop: (d) => _drop(d, f.id),
                  ),
                for (final p in projects)
                  ProjectCard(
                    key: ValueKey('project:${p.id}'),
                    meta: p,
                    open: p.id == state.project.id,
                    checked: _selecting ? _selected.contains(p.id) : null,
                    folderPath: searching ? l.pathOf(p.folder) : null,
                    drag: ProjectDrag(_selected.contains(p.id) ? _selected.toList() : [p.id]),
                    onTap: () => _selecting ? _toggle(p.id) : state.openProject(p.id),
                    onHold: () => _selecting ? _toggle(p.id) : _startSelect(p.id),
                  ),
              ],
            );
          }
          return Column(children: [
            _header(),
            // Inside a folder or searching: where the list is (each step back up is a drop target too).
            AnimatedSize(
              duration: Motion.move(Motion.standard, level),
              child: _folder != null || searching ? _crumbs(searching) : const SizedBox(width: double.infinity),
            ),
            Expanded(child: AnimatedSwitcher(duration: Motion.fade(Motion.standard, level), child: list)),
            SelectionBar(
              visible: _selecting,
              count: _selected.length,
              total: visible.length,
              onAll: () => setState(() => _selected.addAll(visible)),
              onNone: () => setState(_selected.clear),
              actions: [
                SelectionAction('move', Icons.drive_file_move_outline, 'Move to folder', _moveSelected),
                SelectionAction('export', Icons.ios_share, 'Export', _export),
                SelectionAction('delete', Icons.delete_outline, 'Delete', _delete, danger: true),
              ],
            ),
          ]);
        },
      );
}

/// A folder of projects: tap opens it, a long press (or right-click) opens its menu, and a project held over it
/// lights it up and drops in.
class LibraryFolderRow extends StatelessWidget {
  const LibraryFolderRow({super.key, required this.folder, required this.projects, required this.folders,
      required this.onOpen, required this.onMenu, required this.onDrop});
  final ProjectFolder folder;
  final int projects, folders;
  final VoidCallback onOpen;
  final void Function(Offset at) onMenu;
  final void Function(ProjectDrag d) onDrop;

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (projects > 0 || folders == 0) '$projects project${projects == 1 ? '' : 's'}',
      if (folders > 0) '$folders folder${folders == 1 ? '' : 's'}',
    ];
    return DragTarget<ProjectDrag>(
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, hover, _) => AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.usabilityOf(context)),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: hover.isNotEmpty ? Neon.blue.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.s),
          border: Border.all(color: hover.isNotEmpty ? Neon.blue : Colors.transparent),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          onLongPressStart: (d) {
            Motion.tick();
            onMenu(d.globalPosition);
          },
          onSecondaryTapUp: (d) => onMenu(d.globalPosition),
          child: SizedBox(
            height: 44,
            child: Row(children: [
              const SizedBox(width: Space.s),
              Icon(Icons.folder, size: 22, color: Neon.blue.withValues(alpha: 0.8)),
              const SizedBox(width: Space.s),
              Expanded(child: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TypeScale.body))),
              Text(parts.join(' · '), style: const TextStyle(fontSize: TypeScale.caption, color: Neon.dim)),
              const Icon(Icons.chevron_right, size: 18, color: Neon.dim),
              const SizedBox(width: Space.xs),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A project's card: name, last edited and created dates, tracks, length, tempo and the version that saved it.
/// Held still it starts select mode (or toggles it); held and moved it drags onto a folder.
class ProjectCard extends StatefulWidget {
  const ProjectCard({super.key, required this.meta, required this.open, required this.checked, required this.drag,
      required this.onTap, required this.onHold, this.folderPath});
  final ProjectMeta meta;
  final bool open;

  /// Null outside select mode.
  final bool? checked;
  final String? folderPath;
  final ProjectDrag drag;
  final VoidCallback onTap, onHold;

  @override
  State<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<ProjectCard> {
  double _moved = 0;
  PointerDeviceKind _kind = PointerDeviceKind.touch;

  @override
  Widget build(BuildContext context) {
    final m = widget.meta;
    final checked = widget.checked == true;
    final level = Motion.of(context);
    final details = [
      '${m.tracks} track${m.tracks == 1 ? '' : 's'}',
      libraryLength(m.seconds),
      if (m.bpm > 0) '${m.bpm.toStringAsFixed(m.bpm == m.bpm.roundToDouble() ? 0 : 1)} BPM',
      StorageUse.format(m.bytes),
    ];
    final card = AnimatedContainer(
      duration: Motion.fade(Motion.standard, level),
      margin: const EdgeInsets.only(bottom: Space.xs),
      padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.s),
      decoration: BoxDecoration(
        color: checked ? Neon.blue.withValues(alpha: 0.16) : Neon.panelHi.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.m),
        border: Border.all(color: checked ? Neon.blue.withValues(alpha: 0.8) : Neon.ink.withValues(alpha: 0.08)),
      ),
      child: Row(children: [
        SelectCheck(checked: widget.checked),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Neon.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(Radii.s),
            border: Border.all(color: Neon.green.withValues(alpha: 0.35)),
          ),
          child: const Icon(Icons.music_note, size: 20, color: Neon.green),
        ),
        const SizedBox(width: Space.s),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TypeScale.body, fontWeight: FontWeight.w600))),
              if (widget.open)
                Container(
                  margin: const EdgeInsets.only(left: Space.xs),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), border: Border.all(color: Neon.blue)),
                  child: const Text('OPEN', style: TextStyle(fontSize: 9, color: Neon.blue, fontWeight: FontWeight.w700)),
                ),
            ]),
            const SizedBox(height: 2),
            Text('Edited ${libraryDate(m.modified)} · Created ${libraryDate(m.created)}', maxLines: 1,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: TypeScale.caption, color: Neon.dim)),
            Text(details.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TypeScale.number(size: 10.5, color: Neon.dim)),
            Text('Saved with ${m.savedWith}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: TypeScale.caption, color: Neon.dim)),
            if (widget.folderPath != null && widget.folderPath!.isNotEmpty)
              Text('In ${widget.folderPath}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TypeScale.caption, color: Neon.blue)),
          ]),
        ),
      ]),
    );
    final body = Semantics(
      label: m.name,
      selected: checked,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap,
          onSecondaryTapUp: (_) => widget.onHold(), child: card),
    );
    final n = widget.drag.ids.length;
    return HoldDraggable<ProjectDrag>(
      data: widget.drag,
      hapticFeedbackOnStart: false,
      onDragStarted: () {
        _moved = 0;
        Motion.tick();
      },
      onDragUpdate: (d) => _moved += d.delta.distance,
      // Held still and let go: select mode (a finger; a mouse drags at once and right-clicks for it).
      onDraggableCanceled: (_, _) {
        if (_moved < 12 && !isMousePointer(_kind)) widget.onHold();
      },
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
          decoration: BoxDecoration(
            color: Neon.panelHi.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(Radii.s),
            border: Border.all(color: Neon.green),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.music_note, size: 18, color: Neon.green),
            const SizedBox(width: Space.xs),
            Text(n == 1 ? m.name : '$n projects', style: const TextStyle(fontSize: TypeScale.label, color: Neon.text)),
          ]),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: Listener(onPointerDown: (e) => _kind = e.kind, child: body),
    );
  }
}
