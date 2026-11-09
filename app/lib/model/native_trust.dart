// Which native C++ components may load on this device: the owner's trust rules (2026-11-09), remembered per effect.
import 'dart:convert';
import 'dart:io';

import '../engine/engine.dart';
import 'cpp_component.dart';
import 'sha256.dart';

/// The owner's rules: an effect the user wrote on this device loads as Trusted without asking. Anything else (a
/// download, a shared project's code, a library built elsewhere) asks Trust or Block once; the choice is
/// remembered for exactly that code, and a change to the code asks again. Trust is never stored in a project.
class NativeTrustStore {
  NativeTrustStore(this.file);

  /// App-private JSON: {"authored": {id: [source fingerprint, ...]}, "choices": {id: {fingerprint: "trusted"|"blocked"}}}.
  final File file;
  final Map<String, Set<String>> _authored = {};
  final Map<String, Map<String, NativeComponentTrust>> _choices = {};

  static const _maxAuthoredPerComponent = 64;

  Future<void> load() async {
    _authored.clear();
    _choices.clear();
    if (!await file.exists()) return;
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is! Map) return;
      (j['authored'] as Map? ?? const {}).forEach((id, list) {
        if (id is String && list is List) _authored[id] = list.whereType<String>().toSet();
      });
      (j['choices'] as Map? ?? const {}).forEach((id, map) {
        if (id is! String || map is! Map) return;
        _choices[id] = {
          for (final e in map.entries)
            if (e.key is String && (e.value == 'trusted' || e.value == 'blocked'))
              e.key as String: e.value == 'trusted' ? NativeComponentTrust.trusted : NativeComponentTrust.blocked,
        };
      });
    } on FormatException {
      // A damaged store asks again rather than trusting anything.
    }
  }

  Future<void> save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'authored': {for (final e in _authored.entries) e.key: e.value.toList()},
      'choices': {
        for (final e in _choices.entries)
          e.key: {for (final c in e.value.entries) c.key: c.value == NativeComponentTrust.trusted ? 'trusted' : 'blocked'},
      },
    }));
    await tmp.rename(file.path); // never a half-written store
  }

  /// The fingerprint of a component's sources: every file and its content, in path order.
  static String sourceFingerprint(CppComponentDoc component) {
    final paths = component.files.keys.toList()..sort();
    final text = StringBuffer();
    for (final p in paths) {
      text
        ..write(p.length)
        ..write(':')
        ..write(p)
        ..write(component.files[p]!.length)
        ..write(':')
        ..write(component.files[p]);
    }
    return sha256Hex(utf8.encode(text.toString()));
  }

  /// The fingerprint of a built library from elsewhere.
  static Future<String> libraryFingerprint(String path) async => sha256Hex(await File(path).readAsBytes());

  /// The editor calls this when the user creates or edits a component here: those sources are theirs.
  void markAuthored(CppComponentDoc component) {
    final set = _authored.putIfAbsent(component.componentId, () => {});
    set.add(sourceFingerprint(component));
    while (set.length > _maxAuthoredPerComponent) {
      set.remove(set.first);
    }
  }

  /// Trusted for the user's own sources; otherwise the remembered choice for exactly this code, or null: ask.
  NativeComponentTrust? decide(String componentId, String fingerprint) {
    if (_authored[componentId]?.contains(fingerprint) ?? false) return NativeComponentTrust.trusted;
    return _choices[componentId]?[fingerprint];
  }

  /// The user's answer to the prompt. Trusting someone's sources and then editing them makes the edits the
  /// user's own (markAuthored), so they don't ask again.
  void remember(String componentId, String fingerprint, NativeComponentTrust trust) {
    if (trust == NativeComponentTrust.isolated) throw ArgumentError('Isolated is not available yet');
    _choices.putIfAbsent(componentId, () => {})[fingerprint] = trust;
  }

  /// "Change in its settings": forgets every choice for the component, so it asks again.
  void forget(String componentId) => _choices.remove(componentId);
}
