// The user's own presets, app-wide: a device preset (one component's values and saved state) or a track preset (an
// instrument and its native effects), each a small JSON file in app-private storage, read as untrusted input.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'arrange_fx.dart';
import 'mixer_fx.dart';
import 'device_target.dart';
import 'project.dart';

enum UserPresetKind { device, track }

/// The bounds a preset file must keep (it may come from anywhere: an import, a damaged disk). Anything past them is
/// refused or dropped, never trusted.
abstract final class PresetLimits {
  /// A whole file, before it is decoded.
  static const fileBytes = 4 << 20;

  /// One device's saved state (base64 text); a larger one is left out of the preset.
  static const stateChars = 3 << 20;
  static const params = 512;
  static const effects = 64;
  static const name = 64;
  static const category = 32;
  static const paramId = 64;

  /// How many presets the library keeps; past it a save is refused.
  static const presets = 4000;
}

/// One device's settings in a preset: its component, the descriptor version it was saved with, its values and the
/// component's saved state (what save_state wrote, base64), if any.
@immutable
class PresetDevice {
  const PresetDevice(this.componentId, this.params,
      {this.descriptorVersion = 1, this.bypass = false, this.state, this.stateVersion = 1});
  final String componentId;
  final Map<String, double> params;
  final int descriptorVersion;
  final bool bypass;
  final String? state;
  final int stateVersion;

  Map<String, Object> toJson() => {
        'component': componentId,
        'descriptor_version': descriptorVersion,
        'params': params,
        if (bypass) 'bypass': true,
        if (state != null) ...{'state': state!, 'state_version': stateVersion},
      };

  /// Null when [j] has no usable component id. Unknown keys are ignored; values must be finite numbers.
  static PresetDevice? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['component'];
    if (id is! String || !_componentId.hasMatch(id)) return null;
    final params = <String, double>{};
    if (j['params'] case final Map raw) {
      for (final e in raw.entries.take(PresetLimits.params)) {
        final k = e.key, v = e.value;
        if (k is String && k.isNotEmpty && k.length <= PresetLimits.paramId && v is num && v.isFinite) {
          params[k] = v.toDouble();
        }
      }
    }
    final state = j['state'];
    return PresetDevice(
      id,
      params,
      descriptorVersion: _int(j['descriptor_version'], 1),
      bypass: j['bypass'] == true,
      state: state is String && state.isNotEmpty && state.length <= PresetLimits.stateChars && _base64.hasMatch(state)
          ? state
          : null,
      stateVersion: _int(j['state_version'], 1),
    );
  }

  /// A new project entry with these settings.
  ComponentUseDoc toUse() => ComponentUseDoc(componentId, Map.of(params), bypass, state, stateVersion);

  static final _componentId = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
  static final _base64 = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
  static int _int(Object? v, int fallback) => v is int && v >= 0 && v <= 0xFFFFFFFF ? v : fallback;
}

/// One saved preset. [device] is set for a device preset; [instrument] and [effects] for a track preset.
@immutable
class UserPreset {
  const UserPreset({
    required this.id,
    required this.kind,
    required this.name,
    this.category = '',
    this.device,
    this.instrument,
    this.effects = const [],
    required this.modified,
  });

  /// The file's name (without `.json`), unique in the library.
  final String id;
  final UserPresetKind kind;
  final String name, category;
  final PresetDevice? device;
  final PresetDevice? instrument;
  final List<PresetDevice> effects;
  final DateTime modified;

  /// The device preset's component; null for a track preset.
  String? get componentId => device?.componentId;

  UserPreset copyWith({String? id, String? name, String? category, PresetDevice? device, DateTime? modified}) =>
      UserPreset(id: id ?? this.id, kind: kind, name: name ?? this.name, category: category ?? this.category,
          device: device ?? this.device, instrument: instrument, effects: effects, modified: modified ?? this.modified);

  static const format = 'caw.preset';
  static const formatVersion = 1;

  Map<String, Object> toJson() => {
        'format': format,
        'version': formatVersion,
        'kind': kind.name,
        'name': name,
        if (category.isNotEmpty) 'category': category,
        'modified': modified.toUtc().toIso8601String(),
        if (device != null) 'device': device!.toJson(),
        if (instrument != null) 'instrument': instrument!.toJson(),
        if (kind == UserPresetKind.track) 'effects': [for (final e in effects) e.toJson()],
      };

  String encode() => jsonEncode(toJson());

  /// Reads a preset file's text, or null when it isn't one this app can use: too large, not JSON, another format,
  /// a newer version, no name, or a device preset without a device. Bounded and type-checked throughout.
  static UserPreset? decode(String text, {required String id}) {
    if (text.length > PresetLimits.fileBytes) return null;
    Object? j;
    try {
      j = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (j is! Map || j['format'] != format) return null;
    final version = j['version'];
    if (version is! int || version < 1 || version > formatVersion) return null;
    final kind = switch (j['kind']) { 'device' => UserPresetKind.device, 'track' => UserPresetKind.track, _ => null };
    if (kind == null) return null;
    final name = cleanName(j['name'], PresetLimits.name);
    if (name.isEmpty) return null;
    final modified = j['modified'] is String ? DateTime.tryParse(j['modified'] as String) : null;
    if (kind == UserPresetKind.device) {
      final device = PresetDevice.fromJson(j['device']);
      if (device == null) return null;
      return UserPreset(id: id, kind: kind, name: name, category: cleanName(j['category'], PresetLimits.category),
          device: device, modified: modified ?? DateTime.now());
    }
    final effects = <PresetDevice>[
      if (j['effects'] case final List list)
        for (final e in list.take(PresetLimits.effects)) ?PresetDevice.fromJson(e),
    ];
    final instrument = PresetDevice.fromJson(j['instrument']);
    if (instrument == null && effects.isEmpty) return null;
    return UserPreset(id: id, kind: kind, name: name, category: cleanName(j['category'], PresetLimits.category),
        instrument: instrument, effects: effects, modified: modified ?? DateTime.now());
  }

  /// [v] as a name: trimmed, control characters and path separators removed, at most [max] characters.
  static String cleanName(Object? v, int max) {
    if (v is! String) return '';
    final s = v.replaceAll(RegExp(r'[\x00-\x1F\x7F/\\]'), '').trim();
    return s.length <= max ? s : s.substring(0, max).trim();
  }
}

/// The library: every user preset in memory, written through to `<app support>/presets/<id>.json` (memory only
/// without a folder, as in tests). Edits are synchronous in memory; writes are queued behind each other. Favourites
/// (of user and factory presets) are kept in `presets/favourites.json`.
class UserPresetStore extends ChangeNotifier {
  UserPresetStore(this.dir);
  final Directory? dir;
  final Map<String, UserPreset> _byId = {};
  final Set<String> _favourites = {};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  static int _sequence = 0;
  static final _random = Random();
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// True once the folder has been read (or there is none).
  bool loaded = false;

  /// Reads the folder once; damaged or oversized files are skipped.
  Future<void> load() => _loading ??= () async {
        final d = dir;
        try {
          if (d != null && await d.exists()) {
            await for (final f in d.list()) {
              if (f is! File) continue;
              final name = f.uri.pathSegments.last;
              if (name == 'favourites.json') {
                await _readFavourites(f);
                continue;
              }
              if (!name.endsWith('.json') || _byId.length >= PresetLimits.presets) continue;
              final id = name.substring(0, name.length - 5);
              if (!_idPattern.hasMatch(id) || _byId.containsKey(id)) continue;
              try {
                if (await f.length() > PresetLimits.fileBytes) continue;
                final p = UserPreset.decode(await f.readAsString(), id: id);
                if (p != null) _byId[id] = p;
              } catch (_) {
                // An unreadable file is skipped, not fatal.
              }
            }
          }
        } catch (_) {
          // An unreadable folder starts empty.
        }
        loaded = true;
        notifyListeners();
      }();

  Future<void> _readFavourites(File f) async {
    try {
      if (await f.length() > 1 << 20) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['favourites'] is List) {
        _favourites.addAll((j['favourites'] as List).whereType<String>().where((k) => k.length <= 400).take(4096));
      }
    } catch (_) {}
  }

  /// Every preset, by name.
  List<UserPreset> get all => _byId.values.toList()..sort(_byName);

  List<UserPreset> forComponent(String componentId) =>
      [for (final p in all) if (p.kind == UserPresetKind.device && p.componentId == componentId) p];

  List<UserPreset> get trackPresets => [for (final p in all) if (p.kind == UserPresetKind.track) p];

  UserPreset? byId(String id) => _byId[id];

  /// The preset of [kind] (for [componentId], for a device preset) called [name], ignoring case.
  UserPreset? named(UserPresetKind kind, String name, {String? componentId}) {
    final n = name.trim().toLowerCase();
    return _byId.values.where((p) => p.kind == kind && p.name.toLowerCase() == n &&
        (kind == UserPresetKind.track || p.componentId == componentId)).firstOrNull;
  }

  /// The first of "[base] 1", "[base] 2"... no preset of [kind] (for [componentId]) is called.
  String freeName(String base, UserPresetKind kind, {String? componentId}) {
    final b = UserPreset.cleanName(base, PresetLimits.name - 4);
    for (var n = 1;; n++) {
      final name = '${b.isEmpty ? 'Preset' : b} $n';
      if (named(kind, name, componentId: componentId) == null) return name;
    }
  }

  String newId() => 'up_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}_${_random.nextInt(1 << 20)}';

  bool get full => _byId.length >= PresetLimits.presets;

  /// Adds [p], or replaces the preset with its id. Returns the one it replaced, for an undo.
  UserPreset? put(UserPreset p) {
    if (!_idPattern.hasMatch(p.id)) throw ArgumentError.value(p.id, 'id', 'Invalid preset id');
    final text = p.encode();
    if (text.length > PresetLimits.fileBytes) throw const FormatException('The preset is too large to save.');
    final old = _byId[p.id];
    if (old == null && full) throw StateError('The preset library is full.');
    _byId[p.id] = p;
    _write(p.id, text);
    notifyListeners();
    return old;
  }

  /// Removes preset [id]; returns it (for an undo), or null.
  UserPreset? remove(String id) {
    final old = _byId.remove(id);
    if (old == null) return null;
    _write(id, null);
    if (_favourites.remove('user:$id')) _writeFavourites();
    notifyListeners();
    return old;
  }

  UserPreset? rename(String id, String name, {String? category}) {
    final p = _byId[id];
    final n = UserPreset.cleanName(name, PresetLimits.name);
    if (p == null || n.isEmpty) return null;
    final next = p.copyWith(name: n, category: category == null ? null : UserPreset.cleanName(category, PresetLimits.category),
        modified: DateTime.now());
    put(next);
    return next;
  }

  /// A copy of preset [id] under a free name ("Pad 1 copy", "Pad 1 copy 2"...).
  UserPreset? duplicate(String id) {
    final p = _byId[id];
    if (p == null) return null;
    var name = UserPreset.cleanName('${p.name} copy', PresetLimits.name);
    for (var n = 2; named(p.kind, name, componentId: p.componentId) != null; n++) {
      name = UserPreset.cleanName('${p.name} copy $n', PresetLimits.name);
    }
    final copy = p.copyWith(id: newId(), name: name, modified: DateTime.now());
    put(copy);
    return copy;
  }

  /// Adds the preset file [text] (an import) under a new id and, when its name is taken, a free one. Null when the
  /// text isn't a usable preset.
  UserPreset? importText(String text) {
    final p = UserPreset.decode(text, id: newId());
    if (p == null) return null;
    var name = p.name;
    for (var n = 2; named(p.kind, name, componentId: p.componentId) != null; n++) {
      name = UserPreset.cleanName('${p.name} $n', PresetLimits.name);
    }
    final next = p.copyWith(name: name);
    put(next);
    return next;
  }

  // ---------- favourites ----------

  bool isFavourite(String key) => _favourites.contains(key);

  void setFavourite(String key, bool on) {
    if (key.length > 400 || (on && _favourites.length >= 4096)) return;
    if (on ? _favourites.add(key) : _favourites.remove(key)) {
      _writeFavourites();
      notifyListeners();
    }
  }

  // ---------- disk ----------

  void _write(String id, String? text) {
    final d = dir;
    if (d == null) return;
    _writes = _writes.catchError((_) {}).then((_) async {
      final f = File('${d.path}${Platform.pathSeparator}$id.json');
      if (text == null) {
        if (await f.exists()) await f.delete();
        return;
      }
      await d.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    });
  }

  void _writeFavourites() => _write('favourites', jsonEncode({'favourites': _favourites.toList()}));

  /// Waits for the queued writes (tests; before the app closes).
  Future<void> flush() => _writes.catchError((_) {});
}

int _byName(UserPreset a, UserPreset b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());

final Expando<UserPresetStore> _stores = Expando('user presets');

extension UserPresets on AppState {
  /// The app-wide preset library, next to settings.json (memory only when settings have no folder). It starts
  /// loading on first use and notifies when loaded.
  UserPresetStore get userPresets {
    final existing = _stores[this];
    if (existing != null) return existing;
    final dir = settings.dir;
    final store = UserPresetStore(dir == null ? null : Directory('${dir.path}${Platform.pathSeparator}presets'));
    _stores[this] = store;
    unawaited(store.load().catchError((_) {}));
    return store;
  }

  /// Tests set a store of their own.
  set userPresets(UserPresetStore store) => _stores[this] = store;

  /// [t]'s device as it is now: every parameter's value, and its saved state (the running component's when the
  /// engine has one, else the project's).
  PresetDevice? captureDevice(DeviceTarget t) {
    final use = t.use, layer = t.layer;
    if (use == null || layer == null) return null;
    final info = t.info;
    final params = info == null
        ? Map.of(use.params)
        : {for (final p in info.parameters) p.id: t.value(p.id)};
    String? state = use.state;
    var version = use.stateVersion;
    final e = engine;
    final index = t.isInstrument ? ProjectDoc.instrumentIndex : engineComponentIndex(layer, t.slot);
    if (e != null && index != null) {
      try {
        final s = e.componentStates(engineLayerId(layer))[index];
        if (s != null) {
          state = s.state.isEmpty ? null : s.state;
          version = s.version;
        }
      } catch (_) {
        // No running state: the project's stays.
      }
    }
    if (state != null && state.length > PresetLimits.stateChars) state = null;
    return PresetDevice(use.id, params, descriptorVersion: info?.version ?? 1, bypass: use.bypass,
        state: state, stateVersion: version);
  }

  /// [layer]'s instrument and native effects as a track preset (not yet saved). Null when it has neither.
  UserPreset? captureTrack(LayerDoc layer, {required String name, String category = '', String? id}) {
    if (layer.isFolder) return null;
    final instrument = layer.instrument == null ? null : captureDevice(DeviceTarget(this, layer.id, DeviceTarget.instrumentSlot));
    final effects = [
      for (var i = 0; i < layer.components.length && i < PresetLimits.effects; i++) ?captureDevice(DeviceTarget(this, layer.id, i)),
    ];
    if (instrument == null && effects.isEmpty) return null;
    return UserPreset(id: id ?? userPresets.newId(), kind: UserPresetKind.track,
        name: UserPreset.cleanName(name, PresetLimits.name), category: UserPreset.cleanName(category, PresetLimits.category),
        instrument: instrument, effects: effects, modified: DateTime.now());
  }

  /// Loads track preset [p] onto [layer] as one undo step: its instrument replaces the track's (a .caw generator
  /// too) when it has one, and its effects replace the track's native effects (.caw effects and clips stay).
  /// Automation lanes of replaced devices go with them. False for a folder or a preset with nothing to load.
  bool applyTrackPreset(LayerDoc layer, UserPreset p) {
    if (layer.isFolder || p.kind != UserPresetKind.track) return false;
    final before = List.of(layer.components);
    editProject((project) {
      final instrument = p.instrument;
      if (instrument != null) {
        project.automation.removeWhere((a) => a.targetType == 'instrument' && a.layerId == layer.id);
        layer.instrument = instrument.toUse();
      }
      layer.components
        ..clear()
        ..addAll([for (final e in p.effects) e.toUse()]);
      followComponentLanes(project, layer.id, before);
    });
    layerValueTick(layer.id).value++;
    return true;
  }

  /// Puts device preset [p] on [layer]: an instrument's becomes its instrument, an effect's joins its inserts, with
  /// the preset's values. False when it can't go there.
  bool applyDevicePresetToTrack(LayerDoc layer, UserPreset p) {
    final d = p.device;
    if (layer.isFolder || d == null) return false;
    if (componentInfo(d.componentId)?.isInstrument ?? false) {
      editProject((project) {
        if (layer.instrument?.id != d.componentId) {
          project.automation.removeWhere((a) => a.targetType == 'instrument' && a.layerId == layer.id);
        }
        layer.instrument = d.toUse()..preset = null;
      });
      return true;
    }
    if (layer.components.length >= 64) return false;
    final before = List.of(layer.components);
    editProject((project) {
      layer.components.add(d.toUse());
      followComponentLanes(project, layer.id, before);
    });
    return true;
  }
}
