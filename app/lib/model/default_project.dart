// The default project (owner, 2026-11-12): the owner's "mid tempo" project, bundled as an asset. A first run, a
// deleted last project and the bundled template open a copy of it, with fresh ids so two copies never collide.
import 'dart:convert';

import 'package:flutter/services.dart';

import 'project.dart';

/// Where the default project is bundled (listed in pubspec.yaml).
const defaultProjectAsset = 'assets/projects/default.json';

/// The bundled project's largest accepted size: it is our own file, but it is still parsed with a limit.
const _maxDefaultProjectBytes = 1 << 20;

Map<String, dynamic>? _defaultJson;

/// Whether [loadDefaultProject] has read the asset.
bool get defaultProjectLoaded => _defaultJson != null;

/// Reads the bundled default project once (later calls return at once). [bundle] defaults to the app's bundle.
Future<void> loadDefaultProject([AssetBundle? bundle]) async {
  if (_defaultJson != null) return;
  final text = await (bundle ?? rootBundle).loadString(defaultProjectAsset, cache: false);
  if (text.length > _maxDefaultProjectBytes) throw const FormatException('The default project is too large');
  _defaultJson = jsonDecode(text) as Map<String, dynamic>;
}

/// A new copy of the default project: its own project id, and fresh pattern, track and clip ids, with every
/// reference to them (clips' patterns, parents, sends, sidechain keys) moved to the new ids.
ProjectDoc defaultProject() {
  final json = _defaultJson;
  if (json == null) throw StateError('The default project is not loaded (call loadDefaultProject first)');
  return projectWithFreshIds(json);
}

/// [json] (a stored project) as a new project: fresh ids for the project, its patterns, tracks and clips, and
/// every string in it that named an old id renamed to match. Component ids (org.caw.*) are type names, not
/// instances, and stay.
ProjectDoc projectWithFreshIds(Map<String, dynamic> json) {
  final copy = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
  final ids = <String, String>{};
  void fresh(Object? list, String prefix) {
    if (list is! List) return;
    for (final item in list.whereType<Map>()) {
      final id = item['id'];
      if (id is String) ids[id] = newId(prefix);
    }
  }

  fresh(copy['modules'], 'm');
  fresh(copy['layers'], 'l');
  for (final layer in ((copy['layers'] as List?) ?? const []).whereType<Map>()) {
    fresh(layer['clips'], 'c');
    fresh(layer['audio_clips'], 'a');
  }
  dynamic remap(dynamic v) => switch (v) {
        final String s => ids[s] ?? s,
        final List l => <dynamic>[for (final x in l) remap(x)],
        final Map m => <String, dynamic>{for (final e in m.entries) e.key as String: remap(e.value)},
        _ => v,
      };
  final remapped = remap(copy) as Map<String, dynamic>..['id'] = newId('p');
  return ProjectDoc.fromJson(remapped);
}
