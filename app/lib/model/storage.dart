// Saves projects as JSON files in app-private storage and remembers which one was open last.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'cpp_component.dart';
import 'project.dart';
import 'atomic_file.dart';

class ProjectSummary {
  const ProjectSummary(this.id, this.name, this.modified);
  final String id, name;
  final DateTime modified;
}

class RestorePointSummary {
  const RestorePointSummary(this.id, this.name, this.createdAt);
  final String id;
  final String name;
  final DateTime createdAt;
}

class ProjectStorage {
  ProjectStorage(this._root);

  final Directory _root;
  static int _restorePointSequence = 0;

  static Future<ProjectStorage> open() async {
    final base = await getApplicationSupportDirectory();
    final root = Directory('${base.path}${Platform.pathSeparator}projects');
    await root.create(recursive: true);
    return ProjectStorage(root);
  }

  File _file(String id) => File('${_root.path}${Platform.pathSeparator}$id.json');
  File get _settings => File('${_root.path}${Platform.pathSeparator}settings.json');

  /// The saved projects, newest first. Every file is read and decoded for its name, so this runs off the UI isolate:
  /// at startup it would otherwise cost as much as opening every project (#174).
  Future<List<ProjectSummary>> list() async {
    final root = _root.path, settings = _settings.path;
    final rows = await Isolate.run(() {
      final out = <(String, String, int)>[];
      for (final f in Directory(root).listSync()) {
        if (f is! File || !f.path.endsWith('.json') || f.path == settings) continue;
        try {
          final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
          out.add((j['id'] as String, (j['name'] as String?) ?? 'Untitled', f.lastModifiedSync().microsecondsSinceEpoch));
        } catch (_) {
          // A damaged file is skipped, not fatal.
        }
      }
      return out;
    });
    final out = [for (final (id, name, at) in rows) ProjectSummary(id, name, DateTime.fromMicrosecondsSinceEpoch(at))];
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// Whether a file for [id] exists, readable or not ([load] returns null for both a missing and a damaged one).
  Future<bool> has(String id) => _file(id).exists();

  Future<ProjectDoc?> load(String id) async {
    final f = _file(id);
    if (!await f.exists()) return null;
    try {
      // Reading and decoding a big project runs off the UI isolate; the decoded map comes back without a copy.
      final path = f.path;
      return ProjectDoc.fromJson(await Isolate.run(() => jsonDecode(File(path).readAsStringSync())) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Writes through a temporary file so a crash mid-save never leaves a half-written project. [json] is [p]'s
  /// `jsonEncode(p.toJson())` when the caller already has it (the app shares it with its undo snapshot).
  Future<void> save(ProjectDoc p, {String? json}) async {
    final f = _file(p.id);
    await writeFileAtomically(f, json ?? jsonEncode(p.toJson()));
  }

  String _validatedProjectId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'projectId', 'Invalid project identifier.');
    }
    return id;
  }

  Directory _restoreDirectory(String projectId) => Directory(
    '${_root.path}${Platform.pathSeparator}restore-points${Platform.pathSeparator}${_validatedProjectId(projectId)}');

  /// Creates an explicit restore point atomically and keeps the newest [keep] per project (Settings › Projects and
  /// files; 20 by default).
  Future<String> createRestorePoint(ProjectDoc project, {int keep = 20}) async {
    final directory = _restoreDirectory(project.id);
    await directory.create(recursive: true);
    final sequence = (_restorePointSequence++).toString().padLeft(4, '0');
    final id = 'rp_${DateTime.now().microsecondsSinceEpoch}_$sequence';
    final file = File('${directory.path}${Platform.pathSeparator}$id.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
      flush: true,
    );
    await temporary.rename(file.path);

    final snapshots = (await directory.list().where(
      (entity) => entity is File && entity.path.endsWith('.json'),
    ).cast<File>().toList())
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final stale in snapshots.skip(keep.clamp(1, 100))) {
      await stale.delete();
    }
    return id;
  }

  Future<List<RestorePointSummary>> listRestorePoints(String projectId) async {
    final directory = _restoreDirectory(projectId);
    if (!await directory.exists()) return const [];
    final points = <RestorePointSummary>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map<String, dynamic> || decoded['id'] != projectId) continue;
        final fileName = entity.uri.pathSegments.last;
        final id = fileName.substring(0, fileName.length - 5);
        points.add(RestorePointSummary(
          id,
          (decoded['name'] as String?) ?? 'Untitled',
          await entity.lastModified(),
        ));
      } catch (_) {
        // A corrupt restore point is skipped without hiding valid history.
      }
    }
    points.sort((a, b) => b.id.compareTo(a.id));
    return points;
  }

  Future<ProjectDoc?> loadRestorePoint(String projectId, String restorePointId) async {
    if (!RegExp(r'^rp_[0-9]{1,20}_[0-9]{1,8}$').hasMatch(restorePointId)) return null;
    try {
      final file = File(
        '${_restoreDirectory(projectId).path}${Platform.pathSeparator}$restorePointId.json',
      );
      if (!await file.exists()) return null;
      final path = file.path;
      final decoded = await Isolate.run(() => jsonDecode(File(path).readAsStringSync()));
      if (decoded is! Map<String, dynamic>) return null;
      final project = ProjectDoc.fromJson(decoded);
      return project.id == projectId ? project : null;
    } catch (_) {
      return null;
    }
  }

  /// Materializes saved C++ sources into a disposable app-private workspace for a local build.
  /// The project JSON remains authoritative; deleting this workspace never deletes user source.
  Future<Directory> materializeCppComponent(ProjectDoc project, CppComponentDoc component) async {
    final projectId = _validatedProjectId(project.id);
    final componentId = _validatedProjectId(component.id);
    for (final path in component.files.keys) {
      if (!CppComponentDoc.isSafeRelativePath(path)) {
        throw FormatException('Unsafe C++ project path: $path');
      }
    }

    final workspace = Directory(
      '${_root.path}${Platform.pathSeparator}cpp-workspaces'
      '${Platform.pathSeparator}$projectId${Platform.pathSeparator}$componentId',
    );
    if (await workspace.exists()) await workspace.delete(recursive: true);
    await workspace.create(recursive: true);
    try {
      for (final entry in component.files.entries) {
        final segments = entry.key.split('/');
        final file = File(
          '${workspace.path}${Platform.pathSeparator}${segments.join(Platform.pathSeparator)}',
        );
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value, flush: true);
      }
      return workspace;
    } catch (_) {
      if (await workspace.exists()) await workspace.delete(recursive: true);
      rethrow;
    }
  }

  /// Returns the persistent CMake build directory; unlike source workspaces, this is not cleared between builds.
  Future<Directory> prepareCppBuildDirectory(String projectId, String componentId) async {
    final safeProjectId = _validatedProjectId(projectId);
    final safeComponentId = _validatedProjectId(componentId);
    final directory = Directory(
      '${_root.path}${Platform.pathSeparator}cpp-builds'
      '${Platform.pathSeparator}$safeProjectId${Platform.pathSeparator}$safeComponentId',
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// The project's sample packs (the sample-pack maker's renders): one folder per pack, shown in Files.
  Directory samplePacksDirectory(String projectId) => Directory(
    '${_root.path}${Platform.pathSeparator}samples${Platform.pathSeparator}${_validatedProjectId(projectId)}');

  /// The project's audio (API 18): imported files are copied here, and recordings go into its `recordings` folder.
  Directory audioDirectory(String projectId) => Directory(
    '${_root.path}${Platform.pathSeparator}audio${Platform.pathSeparator}${_validatedProjectId(projectId)}');

  /// The drum pads' own WAVs the user picked (`DrumSampleImport`), app-wide beside the projects folder.
  Directory get drumSamplesDirectory => Directory('${_root.parent.path}${Platform.pathSeparator}drum_samples');

  /// Built C++ libraries that came in a project package (they load only once the user trusts each one).
  Directory nativeImportsDirectory(String projectId) => Directory(
    '${_root.path}${Platform.pathSeparator}native-imports${Platform.pathSeparator}${_validatedProjectId(projectId)}');

  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
    if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      final history = _restoreDirectory(id);
      if (await history.exists()) await history.delete(recursive: true);
      final samples = samplePacksDirectory(id);
      if (await samples.exists()) await samples.delete(recursive: true);
      final audio = audioDirectory(id);
      if (await audio.exists()) await audio.delete(recursive: true);
      final builds = nativeImportsDirectory(id);
      if (await builds.exists()) await builds.delete(recursive: true);
    }
  }

  Future<String?> lastOpened() async {
    try {
      final j = jsonDecode(await _settings.readAsString()) as Map<String, dynamic>;
      return j['last'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> setLastOpened(String id) => _settings.writeAsString(jsonEncode({'last': id}));
}

/// What the app's folders take on the device, in bytes (Settings › Projects and files).
class StorageUse {
  const StorageUse({this.projects = 0, this.restorePoints = 0, this.themes = 0, this.other = 0, this.caches = 0});
  final int projects, restorePoints, themes, other, caches;
  int get total => projects + restorePoints + themes + other + caches;

  /// Measures [support] (the app support folder: projects/, its restore-points/, themes/ and the rest, such as
  /// settings and C++ builds) and [temp] (caches: renders waiting for the save picker), off the UI isolate.
  static Future<StorageUse> measure(Directory support, Directory? temp) {
    final s = support.path, t = temp?.path, sep = Platform.pathSeparator;
    return Isolate.run(() {
      var projects = 0, restore = 0, themes = 0, other = 0, caches = 0;
      int size(FileSystemEntity f) {
        try {
          return f is File ? f.lengthSync() : 0;
        } catch (_) {
          return 0;
        }
      }
      final projectsDir = '$s${sep}projects', restoreDir = '$projectsDir${sep}restore-points', themesDir = '$s${sep}themes';
      if (Directory(s).existsSync()) {
        for (final f in Directory(s).listSync(recursive: true, followLinks: false)) {
          final n = size(f);
          if (f.path.startsWith(restoreDir)) {
            restore += n;
          } else if (f.path.startsWith(projectsDir)) {
            projects += n;
          } else if (f.path.startsWith(themesDir)) {
            themes += n;
          } else {
            other += n;
          }
        }
      }
      if (t != null && Directory(t).existsSync()) {
        for (final f in Directory(t).listSync(recursive: true, followLinks: false)) {
          caches += size(f);
        }
      }
      return StorageUse(projects: projects, restorePoints: restore, themes: themes, other: other, caches: caches);
    });
  }

  /// Deletes what is in [temp] (finished renders not saved yet; never projects or settings) and returns the bytes
  /// freed. A file in use stays.
  static Future<int> clearCaches(Directory temp) {
    final t = temp.path;
    return Isolate.run(() {
      var freed = 0;
      final dir = Directory(t);
      if (!dir.existsSync()) return 0;
      for (final f in dir.listSync(followLinks: false)) {
        try {
          if (f is File) {
            final n = f.lengthSync();
            f.deleteSync();
            freed += n;
          } else if (f is Directory) {
            var n = 0;
            for (final g in f.listSync(recursive: true, followLinks: false)) {
              if (g is File) n += g.lengthSync();
            }
            f.deleteSync(recursive: true);
            freed += n;
          }
        } catch (_) {
          // In use or not ours to delete: left.
        }
      }
      return freed;
    });
  }

  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
