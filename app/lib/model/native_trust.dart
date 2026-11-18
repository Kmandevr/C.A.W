// Which native C++ components may load on this device: the owner's trust rules (2026-11-09), remembered per effect.
import 'dart:convert';
import 'dart:io';

import '../engine/engine.dart';
import 'cpp_component.dart';
import 'package:caw_services/sha256.dart';
import 'atomic_file.dart';

/// The owner's rules: an effect the user wrote on this device loads as Trusted without asking. Anything else (a
/// download, a shared project's code, a library built elsewhere) asks Trust or Block once; the choice is
/// remembered for exactly that code, and a change to the code asks again. Trust is never stored in a project.
class NativeTrustStore {
  NativeTrustStore(this.file);

  /// App-private JSON: {"authored": {id: [source fingerprint, ...]}, "choices": {id: {fingerprint: "trusted"|"blocked"}},
  /// "scan": 1, "legacy": {id: [library SHA-256, ...]}}. "scan" marks a store written by 1.0.7 or later (the
  /// pre-load scan); "legacy" holds the exact builds the user trusted before it, which load with legacy grace.
  final File file;
  final Map<String, Set<String>> _authored = {};
  final Map<String, Map<String, NativeComponentTrust>> _choices = {};
  final Map<String, Set<String>> _legacy = {};
  bool _needsLegacyMigration = false;

  static const _maxAuthoredPerComponent = 64;
  static const _scanFormat = 1;

  /// The store was written by an app from before the pre-load scan (1.0.7: no "scan" marker): what it trusts was
  /// trusted then. The manager records those builds' hashes once ([finishLegacyMigration]); until then [save]
  /// keeps the store unmarked, so nothing is lost if the app stops first.
  bool get needsLegacyMigration => _needsLegacyMigration;

  Future<void> load() async {
    _authored.clear();
    _choices.clear();
    _legacy.clear();
    _needsLegacyMigration = false;
    if (!await file.exists()) return; // a new install: nothing was trusted before 1.0.7
    try {
      final j = jsonDecode(await file.readAsString());
      if (j is! Map) return;
      _needsLegacyMigration = !j.containsKey('scan');
      (j['legacy'] as Map? ?? const {}).forEach((id, list) {
        if (id is String && list is List) _legacy[id] = list.whereType<String>().where(_isSha256).toSet();
      });
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
      // A damaged store asks again rather than trusting anything (and grants no grace).
    } on TypeError {
      // As damaged.
    }
  }

  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static bool _isSha256(String s) => _sha.hasMatch(s);

  Future<void> save() async {
    await file.parent.create(recursive: true);
    await writeFileAtomically(file, jsonEncode({
      'authored': {for (final e in _authored.entries) e.key: e.value.toList()},
      'choices': {
        for (final e in _choices.entries)
          e.key: {for (final c in e.value.entries) c.key: c.value == NativeComponentTrust.trusted ? 'trusted' : 'blocked'},
      },
      if (!_needsLegacyMigration) 'scan': _scanFormat,
      if (_legacy.isNotEmpty) 'legacy': {for (final e in _legacy.entries) e.key: e.value.toList()},
    }), flush: false); // never a half-written store
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

  /// "Change in its settings": forgets every choice for the component, so it asks again (and its grace: a build
  /// trusted again is trusted now, under the scan's rules).
  void forget(String componentId) {
    _choices.remove(componentId);
    _legacy.remove(componentId);
  }

  /// Records [builds] (component id, library SHA-256) as trusted before 1.0.7 and marks the store as migrated.
  /// Only while [needsLegacyMigration]: a build trusted from 1.0.7 on never gets grace.
  void finishLegacyMigration(Iterable<(String, String)> builds) {
    if (!_needsLegacyMigration) return;
    for (final (id, sha) in builds) {
      final hash = sha.toLowerCase();
      if (_isSha256(hash)) _legacy.putIfAbsent(id, () => {}).add(hash);
    }
    _needsLegacyMigration = false;
  }

  /// Whether any build of [componentId] was trusted before 1.0.7.
  bool hasLegacy(String componentId) => _legacy[componentId]?.isNotEmpty ?? false;

  /// [sha256] when this exact build of [componentId] was trusted before 1.0.7 (it loads with legacy grace), else
  /// null. A rebuild has a new hash, so it never matches.
  String? legacyTrusted(String componentId, String sha256) {
    final hash = sha256.toLowerCase();
    return (_legacy[componentId]?.contains(hash) ?? false) ? hash : null;
  }
}
