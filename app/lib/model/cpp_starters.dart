// The C++ starters the Build page's "Open an example" lists (examples/cpp/starters): each one's name, summary and a fresh copy for a project.
import 'dart:convert';

import 'cpp_component.dart';
import 'cpp_starters_sources.dart';

/// One starter: its folder under examples/cpp/starters and its files (`caw-component.json`, `src/<name>.cpp`).
class CppStarter {
  const CppStarter(this.folder, this.files);
  final String folder;
  final Map<String, String> files;

  /// The component id the starter's files use; a copy gets its own.
  String get starterId => 'org.caw.starter.$folder';

  /// The manifest's `component.name` ("Bass").
  String get name {
    try {
      final j = jsonDecode(files['caw-component.json'] ?? '') as Map<String, dynamic>;
      return (j['component'] as Map<String, dynamic>)['name'] as String? ?? folder;
    } catch (_) {
      return folder;
    }
  }

  /// The source's first line after its name ("// Bass: a filtered saw bass..." gives "A filtered saw bass...").
  String get summary {
    final src = files.entries.firstWhere((e) => e.key.endsWith('.cpp'), orElse: () => const MapEntry('', '')).value;
    final first = src.split('\n').first;
    final m = RegExp(r'^//\s*[^:]+:\s*(.*)$').firstMatch(first);
    if (m == null) return '';
    final s = m.group(1)!.trim();
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  }

  /// Whether it plays notes (derives from `caw::InstrumentProcessor`) rather than shaping a track's sound.
  bool get instrument => files.values.any((s) => s.contains('InstrumentProcessor'));

  /// A copy for a project, entry [id] named [displayName]: the files with the starter's id replaced by a local one
  /// (`local.<folder>.<entry>`, as a blank component's), so two copies never share an id.
  CppComponentDoc copy({required String id, required String displayName}) {
    final entry = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    final componentId = 'local.$folder.$entry';
    return CppComponentDoc(
      id: id,
      name: displayName,
      componentId: componentId,
      files: {for (final f in files.entries) f.key: f.value.replaceAll(starterId, componentId)},
    );
  }
}

/// Every starter, in the order of [cppStarterSources] (the folders' names, sorted).
final List<CppStarter> cppStarters = [for (final e in cppStarterSources.entries) CppStarter(e.key, e.value)];
