// Named versions of a C++ component ("Build 3 · 14:05"), one per successful build, kept in app-private storage.
import 'dart:convert';
import 'dart:io';

class CppVersion {
  const CppVersion({required this.number, required this.time, required this.files});

  final int number;
  final DateTime time;
  final Map<String, String> files;

  String get label {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Build $number · ${two(time.hour)}:${two(time.minute)}';
  }

  Map<String, Object> toJson() => {'number': number, 'time': time.toIso8601String(), 'files': files};

  static CppVersion? fromJson(Object? j) {
    if (j is! Map) return null;
    final number = j['number'], time = DateTime.tryParse('${j['time']}'), files = j['files'];
    if (number is! int || time == null || files is! Map) return null;
    return CppVersion(number: number, time: time, files: {
      for (final e in files.entries)
        if (e.key is String && e.value is String) e.key as String: e.value as String,
    });
  }
}

/// One JSON file per component under [directory] (`<project id>/<component entry id>.json`), newest last. Kept
/// out of the project file so project saves and project undo stay small; the project still holds the live code.
class CppVersionStore {
  CppVersionStore(this.directory, {this.keep = 20});

  final Directory directory;
  final int keep;

  static final _safe = RegExp(r'[^A-Za-z0-9._-]');

  File _file(String projectId, String componentEntryId) =>
      File('${directory.path}/${projectId.replaceAll(_safe, '_')}/${componentEntryId.replaceAll(_safe, '_')}.json');

  Future<List<CppVersion>> list(String projectId, String componentEntryId) async {
    try {
      final j = jsonDecode(await _file(projectId, componentEntryId).readAsString());
      if (j is! List) return [];
      return [for (final v in j) ?CppVersion.fromJson(v)];
    } on FileSystemException {
      return [];
    } on FormatException {
      return []; // a damaged history only loses the old versions, never the code
    }
  }

  /// Keeps [files] as the next numbered version; the oldest go past [keep]. A build of unchanged code adds none.
  Future<CppVersion> add(String projectId, String componentEntryId, Map<String, String> files, {DateTime? at}) async {
    final versions = await list(projectId, componentEntryId);
    final last = versions.lastOrNull;
    if (last != null && _same(last.files, files)) return last;
    final version = CppVersion(number: (last?.number ?? 0) + 1, time: at ?? DateTime.now(), files: Map.of(files));
    versions.add(version);
    while (versions.length > keep) {
      versions.removeAt(0);
    }
    final file = _file(projectId, componentEntryId);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final v in versions) v.toJson()]));
    await tmp.rename(file.path);
    return version;
  }

  static bool _same(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}
