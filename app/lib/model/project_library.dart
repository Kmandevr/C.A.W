// The project library (Files › Projects): folders, each project's metadata read cheaply through an index file, search
// and sort, and the trash that makes deleting projects undoable.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'atomic_file.dart';
import 'project.dart';

/// The index beside the projects (`projects/library.json`) and the trash folder (`projects/trash/`).
const libraryIndexName = 'library.json';
const libraryTrashName = 'trash';

/// Limits on what the index and the project files may make the library hold: both are untrusted input.
class LibraryLimits {
  LibraryLimits._();
  static const indexBytes = 8 << 20;
  static const folders = 2048;
  static const projects = 20000;
  static const folderName = 80;
  static const projectName = 200;
  static const depth = 16;

  /// A project file larger than this is listed without its details (the `.caw` import's limit on project JSON).
  static const projectBytes = 64 << 20;
}

/// What a project card shows: read from the project file once and kept in the index until the file changes.
class ProjectMeta {
  const ProjectMeta({
    required this.id,
    required this.name,
    required this.modified,
    this.created,
    this.savedWithVersion,
    this.savedWithBuild,
    this.tracks = 0,
    this.seconds = 0,
    this.bpm = 0,
    this.bytes = 0,
    this.folder,
  });

  final String id, name;

  /// Last edited: when the file last changed (the app writes a project only when its content changed).
  final DateTime modified;

  /// Null: unknown (a project from before C.A.W recorded these, 2026-11-12).
  final DateTime? created;
  final String? savedWithVersion;
  final int? savedWithBuild;
  final int tracks;
  final double seconds, bpm;
  final int bytes;

  /// The folder's id; null at the top level.
  final String? folder;

  ProjectMeta withFolder(String? f) => ProjectMeta(id: id, name: name, modified: modified, created: created,
      savedWithVersion: savedWithVersion, savedWithBuild: savedWithBuild, tracks: tracks, seconds: seconds, bpm: bpm,
      bytes: bytes, folder: f);

  /// "0.9.0-beta.1 (2)", or "unknown".
  String get savedWith => savedWithVersion == null
      ? 'unknown'
      : savedWithBuild == null ? savedWithVersion! : '$savedWithVersion ($savedWithBuild)';

  Map<String, dynamic> toJson() => {
        'name': name,
        'modified': modified.microsecondsSinceEpoch,
        if (created != null) 'created': created!.toUtc().toIso8601String(),
        if (savedWithVersion != null) 'saved_with': {'version': savedWithVersion, 'build': ?savedWithBuild},
        'tracks': tracks,
        'seconds': seconds,
        'bpm': bpm,
        'bytes': bytes,
      };

  /// A cached entry from the index (untrusted): null when anything is out of range.
  static ProjectMeta? fromJson(String id, Object? raw, {String? folder}) {
    if (raw is! Map) return null;
    final name = raw['name'], modified = raw['modified'], tracks = raw['tracks'], seconds = raw['seconds'],
        bpm = raw['bpm'], bytes = raw['bytes'];
    if (name is! String || modified is! int || tracks is! int || seconds is! num || bpm is! num || bytes is! int) {
      return null;
    }
    if (tracks < 0 || tracks > 1 << 20 || !seconds.isFinite || seconds < 0 || !bpm.isFinite || bytes < 0) return null;
    final saved = savedWithFromJson(raw['saved_with']);
    return ProjectMeta(
      id: id,
      name: _bounded(name, LibraryLimits.projectName, 'Untitled'),
      modified: DateTime.fromMicrosecondsSinceEpoch(modified.clamp(0, 1 << 53)),
      created: projectCreatedFromJson(raw['created']),
      savedWithVersion: saved.version,
      savedWithBuild: saved.build,
      tracks: tracks,
      seconds: seconds.toDouble(),
      bpm: bpm.toDouble(),
      bytes: bytes,
      folder: folder,
    );
  }

  /// Reads a project file's details from its decoded JSON [j] (on the scanning isolate).
  static ProjectMeta fromProject(String id, Map<String, dynamic> j, {required DateTime modified, required int bytes}) {
    var tracks = 0;
    var seconds = 0.0, bpm = 0.0;
    try {
      final doc = ProjectDoc.fromJson(j);
      tracks = doc.layers.where((l) => !l.isFolder).length;
      bpm = doc.bpm.isFinite && doc.bpm > 0 ? doc.bpm : 0;
      seconds = bpm <= 0 ? 0 : doc.arrangementEndSteps / 4 * 60 / bpm;
    } catch (_) {
      // Details that don't parse stay zero; the name and dates still show.
    }
    final saved = savedWithFromJson(j['saved_with']);
    return ProjectMeta(
      id: id,
      name: _bounded(j['name'], LibraryLimits.projectName, 'Untitled'),
      modified: modified,
      created: projectCreatedFromJson(j['created']),
      savedWithVersion: saved.version,
      savedWithBuild: saved.build,
      tracks: tracks,
      seconds: seconds.isFinite ? seconds : 0,
      bpm: bpm,
      bytes: bytes,
    );
  }
}

String _bounded(Object? raw, int max, String fallback) {
  if (raw is! String) return fallback;
  final t = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (t.isEmpty) return fallback;
  return t.length <= max ? t : t.substring(0, max);
}

/// A folder of projects; [parent] null is the top level.
class ProjectFolder {
  ProjectFolder(this.id, this.name, this.parent);
  final String id;
  String name;
  String? parent;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'parent': ?parent};
}

/// How the list is ordered (the sort menu above it).
enum ProjectSort {
  edited('Last edited'),
  created('Created'),
  name('Name'),
  size('Size');

  const ProjectSort(this.label);
  final String label;
}

/// [list] in [sort]'s order: names A to Z, dates and sizes newest or largest first (unknown created dates last);
/// ties by name, then id, so the order is stable.
List<ProjectMeta> sortProjects(Iterable<ProjectMeta> list, ProjectSort sort) {
  int byName(ProjectMeta a, ProjectMeta b) {
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  final out = list.toList();
  out.sort((a, b) {
    final c = switch (sort) {
      ProjectSort.name => 0,
      ProjectSort.edited => b.modified.compareTo(a.modified),
      ProjectSort.size => b.bytes.compareTo(a.bytes),
      ProjectSort.created => switch ((a.created, b.created)) {
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
          (final x?, final y?) => y.compareTo(x),
        },
    };
    return c != 0 ? c : byName(a, b);
  });
  return out;
}

/// The projects whose name contains every word of [query], ignoring case (all of them for an empty query).
List<ProjectMeta> searchProjects(Iterable<ProjectMeta> list, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return list.toList();
  return [
    for (final p in list)
      if (words.every(p.name.toLowerCase().contains)) p,
  ];
}

/// Projects moved to the trash together, kept until [ProjectLibrary.purge] (the Undo snackbar closing) or
/// [ProjectLibrary.restore] (Undo).
class TrashBatch {
  const TrashBatch(this.id, this.projectIds);
  final String id;
  final List<String> projectIds;
}

final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _batchPattern = RegExp(r'^t_[0-9]{1,20}_[0-9]{1,8}$');

/// The folders and each project's place in them, with the metadata cache, stored in `library.json` beside the
/// projects. Projects stay `projects/<id>.json` whatever folder they are in, so ids and paths never change; a
/// project the index doesn't name (every project from before the index) is at the top level.
class ProjectLibrary {
  ProjectLibrary(this.root);

  /// The projects folder.
  final Directory root;

  final Map<String, ProjectFolder> folders = {};
  final Map<String, String> _placement = {};

  /// Cached details by project id, with the file's (modified time, size) they were read at.
  final Map<String, (int, int, ProjectMeta)> _cache = {};

  /// Every project, as last listed by [refresh].
  List<ProjectMeta> projects = const [];

  bool _loaded = false;
  Future<void> _queue = Future.value();
  final Set<String> _liveBatches = {};
  static int _sequence = 0;

  String get _sep => Platform.pathSeparator;
  File get indexFile => File('${root.path}$_sep$libraryIndexName');
  Directory get trashDirectory => Directory('${root.path}$_sep$libraryTrashName');

  /// Runs [job] after every earlier one (refreshes, trash moves and restores never overlap).
  Future<T> _serial<T>(Future<T> Function() job) {
    final run = _queue.catchError((Object _) {}).then((_) => job());
    _queue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  // ---------- reading ----------

  /// Reads the index (the first time), lists the project files and reads the details of any that changed since the
  /// index saw them, off the UI isolate; saves the index when anything changed.
  Future<List<ProjectMeta>> refresh() => _serial(() async {
        if (!_loaded) {
          await _loadIndex();
          await _purgeLeftovers();
          _loaded = true;
        }
        final cached = <String, List<Object>>{
          for (final e in _cache.entries) e.key: [e.value.$1, e.value.$2, jsonEncode(e.value.$3.toJson())],
        };
        final rootPath = root.path;
        final rows = await _scanOff(rootPath, cached);
        var changed = false;
        final seen = <String>{};
        final next = <String, (int, int, ProjectMeta)>{};
        for (final (id, mtime, size, metaJson, fresh) in rows) {
          final meta = ProjectMeta.fromJson(id, jsonDecode(metaJson));
          if (meta == null) continue;
          seen.add(id);
          next[id] = (mtime, size, meta);
          if (fresh) changed = true;
        }
        if (next.length != _cache.length || _cache.keys.any((k) => !seen.contains(k))) changed = true;
        _cache
          ..clear()
          ..addAll(next);
        // A placement for a project that is gone, or in a folder that is gone, goes.
        final before = _placement.length;
        _placement.removeWhere((id, f) => !seen.contains(id) || !folders.containsKey(f));
        if (_placement.length != before) changed = true;
        _publish();
        if (changed) await _saveIndex();
        return projects;
      });

  // Static, so the isolate's closure carries only its arguments.
  static Future<List<(String, int, int, String, bool)>> _scanOff(String root, Map<String, List<Object>> cached) =>
      Isolate.run(() => _scan(root, cached));

  void _publish() {
    projects = [for (final e in _cache.entries) e.value.$3.withFolder(_placement[e.key])];
  }

  Future<void> _loadIndex() async {
    folders.clear();
    _placement.clear();
    _cache.clear();
    final f = indexFile;
    try {
      if (!await f.exists() || await f.length() > LibraryLimits.indexBytes) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['caw_project_library'] != 1) return;
      _readFolders(j['folders']);
      final projects = j['projects'];
      if (projects is Map) {
        for (final e in projects.entries.take(LibraryLimits.projects)) {
          final id = e.key, raw = e.value;
          if (id is! String || !_idPattern.hasMatch(id) || raw is! Map) continue;
          final folder = raw['folder'];
          if (folder is String && folders.containsKey(folder)) _placement[id] = folder;
          final stamp = raw['stamp'];
          final meta = ProjectMeta.fromJson(id, raw['meta']);
          if (meta != null && stamp is List && stamp.length == 2 && stamp[0] is int && stamp[1] is int) {
            _cache[id] = (stamp[0] as int, stamp[1] as int, meta);
          }
        }
      }
    } catch (_) {
      // An unreadable index starts again: every project at the top level, details read afresh.
      folders.clear();
      _placement.clear();
      _cache.clear();
    }
  }

  void _readFolders(Object? raw) {
    if (raw is! List) return;
    for (final f in raw.take(LibraryLimits.folders)) {
      if (f is! Map) continue;
      final id = f['id'], parent = f['parent'];
      if (id is! String || !_idPattern.hasMatch(id) || folders.containsKey(id)) continue;
      folders[id] = ProjectFolder(id, _bounded(f['name'], LibraryLimits.folderName, 'Folder'),
          parent is String && _idPattern.hasMatch(parent) ? parent : null);
    }
    // A parent that is missing, or a chain that loops or runs too deep, puts the folder at the top level.
    for (final f in folders.values) {
      final seen = <String>{f.id};
      var p = f.parent;
      var depth = 0;
      while (p != null) {
        final up = folders[p];
        if (up == null || !seen.add(p) || ++depth > LibraryLimits.depth) {
          f.parent = null;
          break;
        }
        p = up.parent;
      }
    }
  }

  Future<void> _saveIndex() {
    final text = jsonEncode({
      'caw_project_library': 1,
      'folders': [for (final f in folders.values) f.toJson()],
      'projects': {
        for (final id in {..._cache.keys, ..._placement.keys})
          id: {
            'folder': ?_placement[id],
            if (_cache[id] case final c?) ...{'stamp': [c.$1, c.$2], 'meta': c.$3.toJson()},
          },
      },
    });
    return writeFileAtomically(indexFile, text);
  }

  // ---------- folders ----------

  /// The folders directly inside [parent] (null: the top level), by name.
  List<ProjectFolder> childFolders(String? parent) =>
      [for (final f in folders.values) if (f.parent == parent) f]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// The projects directly in [folder] (null: the top level, where projects without a folder are).
  List<ProjectMeta> projectsIn(String? folder) => [for (final p in projects) if (p.folder == folder) p];

  /// [folder] and its ancestors, the top first; empty for the top level or a folder that is gone.
  List<ProjectFolder> trail(String? folder) {
    final out = <ProjectFolder>[];
    var f = folder == null ? null : folders[folder];
    while (f != null && out.length <= LibraryLimits.depth) {
      out.insert(0, f);
      f = f.parent == null ? null : folders[f.parent!];
    }
    return out;
  }

  /// The folder's path for a search result's detail line ("Drums / Kicks"); empty at the top level.
  String pathOf(String? folder) => trail(folder).map((f) => f.name).join(' / ');

  /// True when [folder] holds no projects and no folders.
  bool isEmpty(String folder) =>
      !_placement.containsValue(folder) && !folders.values.any((f) => f.parent == folder);

  /// How deep [folder] is (1 for a top-level folder).
  int depthOf(String? folder) => trail(folder).length;

  ProjectFolder createFolder(String name, {String? parent}) {
    if (folders.length >= LibraryLimits.folders) throw StateError('There are too many folders.');
    if (parent != null && !folders.containsKey(parent)) throw ArgumentError.value(parent, 'parent', 'No such folder');
    if (depthOf(parent) >= LibraryLimits.depth) throw StateError('Folders can nest ${LibraryLimits.depth} deep.');
    final n = _bounded(name, LibraryLimits.folderName, '');
    if (n.isEmpty) throw ArgumentError.value(name, 'name', 'A folder needs a name');
    final id = 'f_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
    final f = ProjectFolder(id, n, parent);
    folders[id] = f;
    _changed();
    return f;
  }

  void renameFolder(String id, String name) {
    final f = folders[id];
    final n = _bounded(name, LibraryLimits.folderName, '');
    if (f == null || n.isEmpty) return;
    f.name = n;
    _changed();
  }

  /// Deletes folder [id]. Not empty, it is refused unless [moveContentsUp]: then its projects and folders move to
  /// its parent first. Projects are never deleted with a folder.
  void deleteFolder(String id, {bool moveContentsUp = false}) {
    final f = folders[id];
    if (f == null) return;
    if (!isEmpty(id) && !moveContentsUp) throw StateError('The folder is not empty.');
    for (final e in _placement.entries.toList()) {
      if (e.value == id) f.parent == null ? _placement.remove(e.key) : _placement[e.key] = f.parent!;
    }
    for (final child in folders.values) {
      if (child.parent == id) child.parent = f.parent;
    }
    folders.remove(id);
    _changed();
  }

  /// Moves folder [id] into [parent] (null: the top level). Refused (false) into itself, one of its own folders,
  /// or past the depth limit.
  bool moveFolder(String id, String? parent) {
    final f = folders[id];
    if (f == null || (parent != null && !folders.containsKey(parent))) return false;
    for (final up in trail(parent)) {
      if (up.id == id) return false;
    }
    int height(String folder) =>
        1 + folders.values.where((c) => c.parent == folder).fold(0, (m, c) => m > height(c.id) ? m : height(c.id));
    if (depthOf(parent) + height(id) > LibraryLimits.depth) return false;
    f.parent = parent;
    _changed();
    return true;
  }

  /// Puts projects [ids] in [folder] (null: the top level).
  void moveProjects(Iterable<String> ids, String? folder) {
    if (folder != null && !folders.containsKey(folder)) return;
    for (final id in ids) {
      if (!_cache.containsKey(id)) continue;
      folder == null ? _placement.remove(id) : _placement[id] = folder;
    }
    _changed();
  }

  void _changed() {
    _publish();
    unawaited(_serial(_saveIndex).catchError((Object _) {}));
  }

  /// Waits for index writes queued so far (tests, and before the app closes).
  Future<void> settle() => _serial(() async {});

  // ---------- the trash ----------

  /// The files and folders that belong to project [id], relative to [root] (what [ProjectStorage.delete] removes).
  static List<String> ownedPaths(String id) {
    final s = Platform.pathSeparator;
    return ['$id.json', 'restore-points$s$id', 'samples$s$id', 'audio$s$id', 'native-imports$s$id'];
  }

  /// Moves projects [ids] with their audio, samples, restore points and imported builds into one trash batch. The
  /// batch's manifest is written first, so a crash part-way leaves a batch the next start can finish or empty.
  Future<TrashBatch> trash(List<String> ids) => _serial(() async {
        final safe = [for (final id in ids.toSet()) if (_idPattern.hasMatch(id)) id];
        final batchId = 't_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
        final dir = Directory('${trashDirectory.path}$_sep$batchId');
        await dir.create(recursive: true);
        _liveBatches.add(batchId);
        await writeFileAtomically(File('${dir.path}${_sep}manifest.json'), jsonEncode({
          'ids': safe,
          'folders': {for (final id in safe) if (_placement[id] != null) id: _placement[id]},
        }));
        for (final id in safe) {
          for (final rel in ownedPaths(id)) {
            await _move('${root.path}$_sep$rel', '${dir.path}$_sep$rel');
          }
          _placement.remove(id);
          _cache.remove(id);
        }
        _publish();
        await _saveIndex();
        return TrashBatch(batchId, safe);
      });

  /// Undo: moves batch [b]'s projects back where they were (and into their folders, when those are still there).
  /// Returns how many came back. A project whose id has a file again meanwhile can't come back over it: its copy in
  /// the batch is deleted with the batch (ids are unique, so this needs a file made by hand).
  Future<int> restore(TrashBatch b) => _serial(() => _restore(b.id));

  Future<int> _restore(String batchId) async {
    if (!_batchPattern.hasMatch(batchId)) return 0;
    final dir = Directory('${trashDirectory.path}$_sep$batchId');
    if (!await dir.exists()) return 0;
    await File('${dir.path}${_sep}restoring').writeAsString('1', flush: true);
    final manifest = await _readManifest(dir);
    var restored = 0;
    for (final id in manifest.ids) {
      final project = File('${dir.path}$_sep$id.json');
      if (await File('${root.path}$_sep$id.json').exists()) continue;
      // The project file goes back last, so it is listed only once everything it uses is in place.
      for (final rel in ownedPaths(id).reversed) {
        await _move('${dir.path}$_sep$rel', '${root.path}$_sep$rel');
      }
      if (await project.exists()) continue;
      final folder = manifest.folders[id];
      if (folder != null && folders.containsKey(folder)) _placement[id] = folder;
      restored++;
    }
    await _deleteTree(dir);
    _liveBatches.remove(batchId);
    return restored;
  }

  /// Empties batch [b] for good (the Undo snackbar closed without Undo).
  Future<void> purge(TrashBatch b) => _serial(() async {
        if (!_batchPattern.hasMatch(b.id)) return;
        _liveBatches.remove(b.id);
        await _deleteTree(Directory('${trashDirectory.path}$_sep${b.id}'));
      });

  /// Batches left by an earlier run (the app closed while Undo was still offered): one whose Undo had started is
  /// finished; the rest are emptied.
  Future<void> _purgeLeftovers() async {
    final t = trashDirectory;
    if (!await t.exists()) return;
    for (final d in t.listSync(followLinks: false)) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (d is! Directory || _liveBatches.contains(name)) continue;
      if (_batchPattern.hasMatch(name) && File('${d.path}${_sep}restoring').existsSync()) {
        await _restore(name);
      } else {
        await _deleteTree(d);
      }
    }
  }

  Future<({List<String> ids, Map<String, String> folders})> _readManifest(Directory dir) async {
    try {
      final f = File('${dir.path}${_sep}manifest.json');
      if (await f.length() > 4 << 20) throw const FormatException('manifest too large');
      final j = jsonDecode(await f.readAsString());
      final ids = [for (final id in ((j as Map)['ids'] as List).take(LibraryLimits.projects)) if (id is String && _idPattern.hasMatch(id)) id];
      final fs = <String, String>{
        for (final e in ((j['folders'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
      return (ids: ids, folders: fs);
    } catch (_) {
      // No manifest: whatever project files are in the batch.
      final ids = <String>[];
      if (await dir.exists()) {
        for (final f in dir.listSync()) {
          final n = f.uri.pathSegments.last;
          if (f is File && n.endsWith('.json') && n != 'manifest.json') {
            final id = n.substring(0, n.length - 5);
            if (_idPattern.hasMatch(id)) ids.add(id);
          }
        }
      }
      return (ids: ids, folders: const <String, String>{});
    }
  }

  static Future<void> _move(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await Directory(File(to).parent.path).create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  static Future<void> _deleteTree(Directory d) async {
    final path = d.path;
    // A trash batch can hold a project's whole audio folder: deleted off the UI isolate.
    await Isolate.run(() {
      final dir = Directory(path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
  }
}

/// On the scanning isolate: each project file in [root] with its (modified time, size) and its details, from
/// [cached] when the file hasn't changed since (then `fresh` is false), else read from the file.
List<(String, int, int, String, bool)> _scan(String root, Map<String, List<Object>> cached) {
  final out = <(String, int, int, String, bool)>[];
  final dir = Directory(root);
  if (!dir.existsSync()) return out;
  for (final f in dir.listSync(followLinks: false)) {
    if (out.length >= LibraryLimits.projects) break;
    if (f is! File) continue;
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.json') || name == 'settings.json' || name == libraryIndexName) continue;
    final id = name.substring(0, name.length - 5);
    if (!_idPattern.hasMatch(id)) continue;
    try {
      final stat = f.statSync();
      final mtime = stat.modified.microsecondsSinceEpoch, size = stat.size;
      final c = cached[id];
      if (c != null && c[0] == mtime && c[1] == size) {
        out.add((id, mtime, size, c[2] as String, false));
        continue;
      }
      if (size > LibraryLimits.projectBytes) {
        out.add((id, mtime, size,
            jsonEncode(ProjectMeta(id: id, name: id, modified: stat.modified, bytes: size).toJson()), true));
        continue;
      }
      final j = jsonDecode(f.readAsStringSync());
      // Only a project whose id is its file's name can be opened by it.
      if (j is! Map<String, dynamic> || j['id'] != id) continue;
      out.add((id, mtime, size,
          jsonEncode(ProjectMeta.fromProject(id, j, modified: stat.modified, bytes: size).toJson()), true));
    } catch (_) {
      // A damaged file is skipped, not fatal (it stays on disk).
    }
  }
  return out;
}
