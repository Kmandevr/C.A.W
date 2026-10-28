// Saves projects as JSON files in app-private storage and remembers which one was open last.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'project.dart';

class ProjectSummary {
  const ProjectSummary(this.id, this.name, this.modified);
  final String id, name;
  final DateTime modified;
}

class ProjectStorage {
  ProjectStorage(this._root);

  final Directory _root;

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

  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
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
