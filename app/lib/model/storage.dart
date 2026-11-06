// Saves projects as JSON files in app-private storage and remembers which one was open last.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cpp_component.dart';
import 'project.dart';

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

  Future<List<ProjectSummary>> list() async {
    final out = <ProjectSummary>[];
    await for (final f in _root.list()) {
      if (f is! File || !f.path.endsWith('.json') || f.path == _settings.path) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        out.add(ProjectSummary(j['id'] as String, (j['name'] as String?) ?? 'Untitled', await f.lastModified()));
      } catch (_) {
        // A damaged file is skipped, not fatal.
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// Whether a file for [id] exists, readable or not ([load] returns null for both a missing and a damaged one).
  Future<bool> has(String id) => _file(id).exists();

  Future<ProjectDoc?> load(String id) async {
    final f = _file(id);
    if (!await f.exists()) return null;
    try {
      return ProjectDoc.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Writes through a temporary file so a crash mid-save never leaves a half-written project.
  Future<void> save(ProjectDoc p) async {
    final f = _file(p.id);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(p.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  String _validatedProjectId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'projectId', 'Invalid project identifier.');
    }
    return id;
  }

  Directory _restoreDirectory(String projectId) => Directory(
    '${_root.path}${Platform.pathSeparator}restore-points${Platform.pathSeparator}${_validatedProjectId(projectId)}');

  /// Creates an explicit restore point atomically and retains at most 20 per project.
  Future<String> createRestorePoint(ProjectDoc project) async {
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
    for (final stale in snapshots.skip(20)) {
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
      final decoded = jsonDecode(await file.readAsString());
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
      '\${_root.path}\${Platform.pathSeparator}cpp-builds'
      '\${Platform.pathSeparator}$safeProjectId\${Platform.pathSeparator}$safeComponentId',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
    if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      final history = _restoreDirectory(id);
      if (await history.exists()) await history.delete(recursive: true);
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
