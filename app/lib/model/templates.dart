// Project and track templates (REAPER's File › Project templates and Track › track templates, UG 3.11 and 3.13):
// the starters bundled with the app, the user's own saved next to settings, saving, New project from one, and
// inserting a track template's tracks with fresh ids.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'cpp_component.dart';
import 'project.dart';
import 'routing.dart';

enum TemplateKind { project, track }

/// One template. A project template's [json] is a whole project (`ProjectDoc.toJson`); a track template's holds
/// `layers` (a track, or a folder and everything in it, in order), the `modules` they use, their project `automation`
/// lanes and the project's `cpp_components` they play.
class TemplateDoc {
  TemplateDoc({required this.id, required this.name, required this.kind, required this.json, this.summary = '',
      this.bundled = false});
  final String id;
  String name;
  final TemplateKind kind;
  final String summary;

  /// One of the app's starters (not deletable, not on disk).
  final bool bundled;
  final Map<String, dynamic> json;

  String encode() => jsonEncode({'caw_template': 1, 'name': name, 'kind': kind.name, 'summary': summary, 'body': json});

  static TemplateDoc? decode(String text, {required String id}) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['caw_template'] != 1 || j['body'] is! Map) return null;
      final kind = TemplateKind.values.where((k) => k.name == j['kind']).firstOrNull;
      final name = j['name'];
      if (kind == null || name is! String || name.trim().isEmpty) return null;
      return TemplateDoc(id: id, name: name.trim().length > 64 ? name.trim().substring(0, 64) : name.trim(), kind: kind,
          summary: j['summary'] is String ? j['summary'] as String : '',
          json: Map<String, dynamic>.from(j['body'] as Map));
    } catch (_) {
      return null;
    }
  }
}

/// Bounds on what the template folder holds.
abstract final class TemplateLimits {
  static const templates = 512;
  static const fileBytes = 16 << 20;
}

/// The user's templates, in memory and written through to `<app support>/templates/<id>.json` (memory only without
/// a folder, as in tests).
class TemplateStore extends ChangeNotifier {
  TemplateStore(this.dir);
  final Directory? dir;
  final Map<String, TemplateDoc> _byId = {};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  static int _sequence = 0;
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  bool loaded = false;

  Future<void> load() => _loading ??= () async {
        final d = dir;
        try {
          if (d != null && await d.exists()) {
            await for (final f in d.list()) {
              if (f is! File || _byId.length >= TemplateLimits.templates) continue;
              final name = f.uri.pathSegments.last;
              if (!name.endsWith('.json')) continue;
              final id = name.substring(0, name.length - 5);
              if (!_idPattern.hasMatch(id) || _byId.containsKey(id)) continue;
              try {
                if (await f.length() > TemplateLimits.fileBytes) continue;
                final t = TemplateDoc.decode(await f.readAsString(), id: id);
                if (t != null) _byId[id] = t;
              } catch (_) {
                // An unreadable file is skipped.
              }
            }
          }
        } catch (_) {
          // An unreadable folder starts empty.
        }
        loaded = true;
        notifyListeners();
      }();

  /// The user's templates of [kind], by name.
  List<TemplateDoc> of(TemplateKind kind) =>
      [for (final t in _byId.values) if (t.kind == kind) t]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  TemplateDoc? byId(String id) => _byId[id];

  String newId() => 'tp_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  /// Adds [t]; a template of the same kind and name is replaced (REAPER overwrites a template saved under its name).
  void put(TemplateDoc t) {
    final same = _byId.values.where((o) => o.kind == t.kind && o.name.toLowerCase() == t.name.toLowerCase() && o.id != t.id);
    for (final o in same.toList()) {
      _byId.remove(o.id);
      _write(o.id, null);
    }
    _byId[t.id] = t;
    _write(t.id, t.encode());
    notifyListeners();
  }

  void remove(String id) {
    if (_byId.remove(id) == null) return;
    _write(id, null);
    notifyListeners();
  }

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

  Future<void> flush() => _writes.catchError((_) {});
}

final Expando<TemplateStore> _stores = Expando('templates');

/// The id Settings › Projects stores for "Blank" as the default for New project.
const blankTemplateId = '';

/// The bundled First loop's id (the app's starter project, [AppState.starterProject]).
const firstLoopTemplateId = 'builtin:first-loop';

/// A short name for template [id] where only the settings are at hand (Settings' summaries).
String templateLabel(String id) => switch (id) {
      blankTemplateId => 'Blank',
      firstLoopTemplateId => 'First loop',
      'builtin:song-sketch' => 'Song sketch',
      _ => 'a saved template',
    };

extension Templates on AppState {
  /// The user's templates, next to settings.json; loads on first use.
  TemplateStore get templateStore {
    final existing = _stores[this];
    if (existing != null) return existing;
    final dir = settings.dir;
    final store = TemplateStore(dir == null ? null : Directory('${dir.path}${Platform.pathSeparator}templates'));
    _stores[this] = store;
    unawaited(store.load().catchError((_) {}));
    return store;
  }

  set templateStore(TemplateStore store) => _stores[this] = store;

  /// The project templates: the bundled starters, then the user's.
  List<TemplateDoc> get projectTemplates => [..._bundledProjects(), ...templateStore.of(TemplateKind.project)];

  /// The track templates: the bundled starters, then the user's.
  List<TemplateDoc> get trackTemplates => [..._bundledTracks(), ...templateStore.of(TemplateKind.track)];

  TemplateDoc? templateById(String id) =>
      [...projectTemplates, ...trackTemplates].where((t) => t.id == id).firstOrNull;

  /// What New project opens (Settings › Projects and files): the chosen template, or a blank project when it is
  /// [blankTemplateId] or no longer there.
  ProjectDoc newProjectDoc() {
    final id = settings.newProjectTemplate;
    final t = id == blankTemplateId ? null : templateById(id);
    return t == null || t.kind != TemplateKind.project ? blankProject() : projectFromTemplate(t);
  }

  /// A new project from [t], with its own id and the template's name.
  ProjectDoc projectFromTemplate(TemplateDoc t) {
    if (t.id == blankTemplateId) return blankProject();
    if (t.id == firstLoopTemplateId) return starterProject();
    final copy = ProjectDoc.fromJson(jsonDecode(jsonEncode(t.json)) as Map<String, dynamic>..['id'] = newId('p'));
    copy.name = t.name;
    return copy;
  }

  /// Saves the project as a template named [name] (REAPER's Save project as template: tracks, effects, sends,
  /// clips, master and project settings). Returns it.
  TemplateDoc saveProjectTemplate(String name) {
    final json = jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>;
    final t = TemplateDoc(id: templateStore.newId(), name: name.trim(), kind: TemplateKind.project, json: json,
        summary: '${project.layers.length} tracks · ${project.bpm.toStringAsFixed(0)} BPM');
    templateStore.put(t);
    return t;
  }

  /// Saves [layer] (a folder with everything inside it) as a track template named [name]: its instrument, effects,
  /// sends between the tracks it holds, volume, pan and lanes, and with [clips] its clips and their patterns
  /// (REAPER's "include items"). Returns it.
  TemplateDoc saveTrackTemplate(LayerDoc layer, String name, {bool clips = false}) {
    final tracks = [layer, ...project.layers.where((l) => _inside(l, layer.id))];
    final ids = {for (final l in tracks) l.id};
    final layers = <Map<String, dynamic>>[];
    final modules = <String>{};
    for (final l in tracks) {
      final j = jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>;
      if (identical(l, layer)) j['parent'] = null;
      j['sends'] = [for (final s in l.sends) if (ids.contains(s.to)) s.toJson()];
      if (!clips) j['clips'] = <Object>[];
      layers.add(j);
      if (clips) {
        for (final c in l.clips) {
          modules.addAll([c.patternId, ...c.takes]);
        }
      }
    }
    final used = {for (final l in tracks) ...[?l.instrument?.id, for (final c in l.components) c.id]};
    final json = {
      'layers': layers,
      'modules': [for (final m in project.modules) if (modules.contains(m.id)) m.toJson()],
      'automation': [for (final a in project.automation) if (a.layerId != null && ids.contains(a.layerId)) a.toJson()],
      'cpp_components': [for (final c in project.cppComponents) if (used.contains(c.componentId)) c.toJson()],
    };
    final t = TemplateDoc(id: templateStore.newId(), name: name.trim(), kind: TemplateKind.track, json: json,
        summary: tracks.length == 1 ? (layer.isFolder ? 'Folder' : 'Track') : '${tracks.length} tracks');
    templateStore.put(t);
    return t;
  }

  /// Puts track template [t]'s tracks at the end of the track list with new ids (its patterns too, so their notes
  /// are the new tracks' own), as REAPER's Insert track from template; one undo step. Returns the first track. A
  /// template saved with .caw sounds inserts without them (#160).
  LayerDoc? insertTrackTemplate(TemplateDoc t) {
    if (t.kind != TemplateKind.track) return null;
    final body = jsonDecode(jsonEncode(t.json)) as Map<String, dynamic>;
    final rawLayers = [for (final l in (body['layers'] as List? ?? const [])) if (l is Map<String, dynamic>) l];
    if (rawLayers.isEmpty) return null;
    final layerIds = <String, String>{for (final l in rawLayers) if (l['id'] is String) l['id'] as String: newId('l')};
    final moduleIds = <String, String>{};
    final modules = <ModuleDoc>[];
    for (final m in (body['modules'] as List? ?? const [])) {
      if (m is! Map<String, dynamic> || m['id'] is! String) continue;
      if (!isPatternSource('${m['run_source'] ?? m['source'] ?? ''}')) continue;
      final id = newId('m');
      moduleIds[m['id'] as String] = id;
      modules.add(ModuleDoc.fromJson({...m, 'id': id}));
    }
    String? mod(Object? id) => id is String ? moduleIds[id] ?? id : null;
    final layers = <LayerDoc>[];
    for (final j in rawLayers) {
      final id = layerIds[j['id']];
      if (id == null) continue;
      j['id'] = id;
      j['parent'] = layerIds[j['parent']];
      j['pattern'] = null;
      j['clips'] = [
        for (final c in (j['clips'] as List? ?? const []))
          if (c is Map<String, dynamic> && moduleIds.containsKey(c['pattern'])) {
            ...c, 'id': newId('c'), 'pattern': mod(c['pattern']),
            if (c['takes'] is List) 'takes': [for (final k in c['takes'] as List) ?mod(k)],
          },
      ];
      j['sends'] = [
        for (final s in (j['sends'] as List? ?? const []))
          if (s is Map && layerIds[s['to']] != null) {...s, 'to': layerIds[s['to']]},
      ];
      j['components'] = [
        for (final c in (j['components'] as List? ?? const []))
          if (c is Map && c['key'] is Map) {...c, 'key': layerIds[(c['key'] as Map)['layer']] == null
              ? null : {...(c['key'] as Map), 'layer': layerIds[(c['key'] as Map)['layer']]}}
          else c,
      ];
      layers.add(LayerDoc.fromJson(j));
    }
    final lanes = [
      for (final a in (body['automation'] as List? ?? const []))
        if (a is Map<String, dynamic> && layerIds[a['layer']] != null)
          ProjectAutomationLaneDoc.fromJson({...a, 'layer': layerIds[a['layer']]}),
    ];
    final cpp = [for (final c in (body['cpp_components'] as List? ?? const [])) if (c is Map<String, dynamic>) c];
    editProject((p) {
      p.modules.addAll(modules);
      final start = p.layers.length;
      for (var i = 0; i < layers.length; i++) {
        layers[i].color = (start + i) % LayerDoc.trackColors;
      }
      p.layers.addAll(layers);
      p.automation.addAll(lanes);
      final have = {for (final c in p.cppComponents) c.componentId};
      for (final c in cpp) {
        try {
          final doc = CppComponentDoc.fromJson(c);
          if (have.add(doc.componentId)) p.cppComponents.add(doc);
        } catch (_) {
          // A damaged entry is left out; its track says the component isn't part of the project.
        }
      }
    });
    selectedLayerId = layers.first.id;
    return layers.first;
  }

  bool _inside(LayerDoc l, String folderId) {
    var parent = l.parentId;
    for (var depth = 0; parent != null && depth <= project.layers.length; depth++) {
      if (parent == folderId) return true;
      parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
    }
    return false;
  }

  // ---------- bundled starters ----------

  List<TemplateDoc> _bundledProjects() => [
        TemplateDoc(id: firstLoopTemplateId, name: 'First loop', kind: TemplateKind.project, bundled: true,
            summary: 'Drums, bass, a lead and an acid line on C++ instruments', json: const {}),
        TemplateDoc(id: 'builtin:song-sketch', name: 'Song sketch', kind: TemplateKind.project, bundled: true,
            summary: 'Empty drums, bass, keys and pad tracks with a reverb bus, ready to record',
            json: _songSketch().toJson()),
      ];

  List<TemplateDoc> _bundledTracks() => [
        for (final (id, name, summary, layers) in _starterTracks())
          TemplateDoc(id: id, name: name, kind: TemplateKind.track, bundled: true, summary: summary,
              json: {'layers': [for (final l in layers) l.toJson()]}),
      ];

  ProjectDoc _songSketch() {
    final p = ProjectDoc(id: 'template', name: 'Song sketch')
      ..bpm = settings.newProjectBpm
      ..beatsPerBar = settings.newProjectBeatsPerBar;
    final tracks = [for (final (_, _, _, layers) in _starterTracks()) ...layers];
    final reverb = tracks.firstWhere((l) => l.isFolder);
    for (final l in tracks) {
      if (l.name == 'Keys' || l.name == 'Pad') l.sends.add(SendDoc(reverb.id));
    }
    p.layers.addAll([...tracks.where((l) => !l.isFolder), reverb]);
    for (var i = 0; i < p.layers.length; i++) {
      p.layers[i].color = i % LayerDoc.trackColors;
    }
    return p;
  }

  /// The bundled track templates: (id, name, summary, tracks). Instruments are the engine's built-ins.
  List<(String, String, String, List<LayerDoc>)> _starterTracks() {
    const flagship = 'org.caw.synth.flagship';
    LayerDoc track(String id, String name, String instrument, {String? preset, List<ComponentUseDoc> fx = const [],
        double volume = 0.8}) =>
        LayerDoc(id: id, name: name, color: 0, volume: volume,
            instrument: ComponentUseDoc(instrument, {}, false, null, 1, preset), components: [...fx]);
    return [
      ('builtin:track-drums', 'Drums', 'The 808 kit (General MIDI notes)',
          [track('tpl-drums', 'Drums', 'org.caw.drums', preset: 'Kit: 808', volume: 0.9)]),
      ('builtin:track-bass', 'Bass', 'Flagship, Mono bass', [track('tpl-bass', 'Bass', flagship, preset: 'Mono bass', volume: 0.75)]),
      ('builtin:track-keys', 'Keys', 'Flagship, Morph pad with a ping-pong delay', [track('tpl-keys', 'Keys', flagship,
          preset: 'Morph pad', volume: 0.6, fx: [ComponentUseDoc('org.caw.delay.pingpong', {'sync': 3, 'mix': 0.25})])]),
      ('builtin:track-pad', 'Pad', 'Flagship, Morph pad with chorus',
          [track('tpl-pad', 'Pad', flagship, preset: 'Morph pad', volume: 0.5, fx: [ComponentUseDoc('org.caw.chorus')])]),
      ('builtin:track-reverb-bus', 'Reverb bus', 'A bus running a reverb fully wet; send tracks to it', [
        LayerDoc(id: 'tpl-reverb', name: 'Reverb bus', color: 0, isFolder: true, volume: 1,
            components: [ComponentUseDoc('org.caw.reverb.pro', {'mix': 1.0})]),
      ]),
    ];
  }
}
