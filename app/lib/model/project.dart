// The project as the app stores it (modules, layers, settings) and its translation to the engine's project JSON.
import 'dart:convert';
import 'dart:math';

import 'cpp_component.dart';
import 'pattern_doc.dart';

String newId(String prefix) {
  final r = Random.secure();
  return '$prefix${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

/// A sound module: its code in the editor, and the code last sent to the engine with Run.
class ModuleDoc {
  ModuleDoc({
    required this.id,
    required this.name,
    required this.source,
    String? runSource,
    Map<String, double>? params,
    this.folderPath = '',
    List<String>? tags,
  })  : runSource = runSource ?? source,
        params = params ?? {},
        tags = tags ?? [];

  final String id;
  String name;
  String source;
  String runSource;
  Map<String, double> params;
  String folderPath;
  List<String> tags;

  bool get edited => source != runSource;

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'source': source, 'run_source': runSource, 'params': params,
    'folder_path': folderPath, 'tags': tags,
  };

  static ModuleDoc fromJson(Map<String, dynamic> j) => ModuleDoc(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? 'Module',
    source: (j['source'] as String?) ?? '',
    runSource: j['run_source'] as String?,
    params: ((j['params'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
    folderPath: (j['folder_path'] as String?) ?? '',
    tags: ((j['tags'] as List?) ?? const []).whereType<String>().take(16)
        .map((tag) => _boundedProjectText(tag, 48)).where((tag) => tag.isNotEmpty).toList(),
  );
}

class ClipDoc {
  ClipDoc({required this.id, required this.patternId, this.startSteps = 0, this.lengthSteps = 64, this.sourceOffsetSteps = 0, this.loop = true, this.linked = false});
  final String id;
  String patternId;
  int startSteps;
  int lengthSteps;
  int sourceOffsetSteps;
  bool loop;
  bool linked;

  Map<String, dynamic> toJson() => {
        'id': id, 'pattern': patternId, 'start_steps': startSteps,
        'length_steps': lengthSteps, 'source_offset_steps': sourceOffsetSteps, 'loop': loop, 'linked': linked,
      };

  static ClipDoc fromJson(Map<String, dynamic> j) => ClipDoc(
        id: j['id'] as String,
        patternId: j['pattern'] as String,
        startSteps: (j['start_steps'] as num?)?.toInt() ?? 0,
        lengthSteps: (j['length_steps'] as num?)?.toInt() ?? 64,
        sourceOffsetSteps: (j['source_offset_steps'] as num?)?.toInt() ?? 0,
        loop: j['loop'] != false,
        linked: j['linked'] == true,
      );
}

class AutomationPointDoc {
  AutomationPointDoc({required this.step, required this.value});
  double step, value;
  Map<String, dynamic> toJson() => {'step': step, 'value': value};
  static AutomationPointDoc fromJson(Map<String, dynamic> j) => AutomationPointDoc(
    step: (j['step'] as num?)?.toDouble() ?? 0, value: (j['value'] as num?)?.toDouble() ?? 0);
}

class AutomationLaneDoc {
  AutomationLaneDoc({required this.target, List<AutomationPointDoc>? points}) : points = points ?? [];
  String target;
  List<AutomationPointDoc> points;
  Map<String, dynamic> toJson() => {'target': target, 'points': [for (final p in points) p.toJson()]};
  static AutomationLaneDoc fromJson(Map<String, dynamic> j) => AutomationLaneDoc(
    target: j['target'] as String, points: ((j['points'] as List?) ?? const [])
      .map((p) => AutomationPointDoc.fromJson(p as Map<String, dynamic>)).toList());
}

/// A project-level automation lane: a module parameter (`param`), a global (`global`), or a native component's
/// parameter (`component`: [layerId] null for the master chain, [component] its index in that chain).
class ProjectAutomationLaneDoc {
  ProjectAutomationLaneDoc(
      {required this.targetType, required this.target, this.moduleId, this.layerId, this.component, List<AutomationPointDoc>? points})
      : points = points ?? [];
  String targetType;
  String target;
  String? moduleId;
  String? layerId;
  int? component;
  List<AutomationPointDoc> points;

  Map<String, dynamic> toJson() => {
        'target_type': targetType,
        'target': target,
        if (moduleId != null) 'module': moduleId,
        if (layerId != null) 'layer': layerId,
        if (component != null) 'component': component,
        'points': [for (final p in points) p.toJson()],
      };

  static ProjectAutomationLaneDoc fromJson(Map<String, dynamic> j) => ProjectAutomationLaneDoc(
        targetType: j['target_type'] as String? ?? 'global',
        target: j['target'] as String? ?? '',
        moduleId: j['module'] as String?,
        layerId: j['layer'] as String?,
        component: (j['component'] as num?)?.toInt(),
        points: ((j['points'] as List?) ?? const []).map((p) => AutomationPointDoc.fromJson(p as Map<String, dynamic>)).toList(),
      );
}

/// A native C++ component placed in a chain (a track's inserts or the master's), with the parameter
/// values the project sets. Placing one is not a trust grant: the component must be loaded first.
class ComponentUseDoc {
  ComponentUseDoc(this.id, [Map<String, double>? params, this.bypass = false, this.state, this.stateVersion = 1])
      : params = params ?? {};

  final String id;
  Map<String, double> params;

  /// Passes its input through and is not run.
  bool bypass;

  /// What the component's save_state wrote, base64 (`Engine.componentStates`), so a reload or an export starts
  /// from it; null for none.
  String? state;
  int stateVersion;

  /// A bare id when nothing else is set, as older projects stored it.
  Object toJson() => params.isEmpty && !bypass && state == null
      ? id
      : {
          'id': id,
          if (params.isNotEmpty) 'params': params,
          if (bypass) 'bypass': true,
          if (state != null) ...{'state': state, 'state_version': stateVersion},
        };

  /// Null for an entry without a usable id. Ids and parameter names are bounded; values must be finite.
  static ComponentUseDoc? fromJson(Object? j) {
    if (j is String) {
      final id = _boundedProjectText(j, 128);
      return id.isEmpty ? null : ComponentUseDoc(id);
    }
    if (j is! Map) return null;
    final id = _boundedProjectText(j['id'], 128);
    if (id.isEmpty) return null;
    final params = <String, double>{};
    if (j['params'] case final Map raw) {
      for (final entry in raw.entries.take(256)) {
        final name = _boundedProjectText(entry.key, 64);
        if (name.isNotEmpty && entry.value is num && (entry.value as num).isFinite) {
          params[name] = (entry.value as num).toDouble();
        }
      }
    }
    final state = j['state'];
    final version = j['state_version'];
    return ComponentUseDoc(
      id,
      params,
      j['bypass'] == true,
      state is String && state.length <= (16 << 20) && RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(state) ? state : null,
      version is int && version >= 0 && version <= 0xFFFFFFFF ? version : 1,
    );
  }

  static List<ComponentUseDoc> listFromJson(Object? raw) => [
        for (final entry in ((raw as List?) ?? const []).take(64)) ?ComponentUseDoc.fromJson(entry),
      ];
}

class LayerDoc {
  LayerDoc({
    required this.id,
    required this.name,
    required this.color,
    this.generatorId,
    List<String>? effectIds,
    this.patternId,
    this.lengthSteps = 0,
    this.volume = 0.8,
    this.pan = 0,
    this.mute = false,
    this.solo = false,
    List<ClipDoc>? clips,
    List<AutomationLaneDoc>? automation,
    List<ComponentUseDoc>? components,
    this.parentId,
    this.isFolder = false,
    this.busEnabled = true,
    this.collapsed = false,
    this.spaceBelow = 0,
  }) : effectIds = effectIds ?? [], clips = clips ?? [], automation = automation ?? [], components = components ?? [];

  /// The tallest visual spacer under a track, in logical pixels.
  static const maxSpaceBelow = 160.0;

  /// How many track colours the themes define (`layer1`..`layer8`); [color] indexes them, wrapping.
  static const trackColors = 8;

  final String id;
  String name;
  int color;
  String? generatorId;
  List<String> effectIds;
  String? patternId; // a pattern module whose notes play the generator; it sets the layer's length
  int lengthSteps; // 16ths; 0 follows the project loop
  double volume, pan;
  bool mute, solo;
  List<ClipDoc> clips;
  List<AutomationLaneDoc> automation;
  List<ComponentUseDoc> components; // native C++ effects after the chain, before volume and pan
  String? parentId;
  bool isFolder, busEnabled, collapsed;

  /// A spacer drawn under the track in the arrangement, in logical pixels (0: none). It only separates tracks on
  /// screen: it is saved with the project but never sent to the engine.
  double spaceBelow;

  List<String> get chain => [?generatorId, ...effectIds];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'generator': generatorId,
        'effects': effectIds,
        'pattern': patternId,
        'length_steps': lengthSteps,
        'volume': volume,
        'pan': pan,
        'mute': mute,
        'solo': solo,
        'clips': [for (final c in clips) c.toJson()],
        'automation': [for (final a in automation) a.toJson()],
        if (components.isNotEmpty) 'components': [for (final c in components) c.toJson()],
        'parent': parentId, 'folder': isFolder, 'bus': busEnabled, 'collapsed': collapsed,
        if (spaceBelow > 0) 'space_below': spaceBelow,
      };

  static LayerDoc fromJson(Map<String, dynamic> j) => LayerDoc(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Layer',
        color: (j['color'] as num?)?.toInt() ?? 0,
        generatorId: j['generator'] as String?,
        effectIds: ((j['effects'] as List?) ?? const []).cast<String>().toList(),
        patternId: j['pattern'] as String?,
        lengthSteps: (j['length_steps'] as num?)?.toInt() ?? 0,
        volume: (j['volume'] as num?)?.toDouble() ?? 0.8,
        pan: (j['pan'] as num?)?.toDouble() ?? 0,
        mute: j['mute'] == true,
        solo: j['solo'] == true,
        clips: ((j['clips'] as List?) ?? const []).map((c) => ClipDoc.fromJson(c as Map<String, dynamic>)).toList(),
        automation: ((j['automation'] as List?) ?? const []).map((a) => AutomationLaneDoc.fromJson(a as Map<String, dynamic>)).toList(),
        components: ComponentUseDoc.listFromJson(j['components']),
        parentId: j['parent'] as String?, isFolder: j['folder'] == true,
        busEnabled: j['bus'] != false, collapsed: j['collapsed'] == true,
        spaceBelow: switch (j['space_below']) {
          final num v when v.isFinite => v.toDouble().clamp(0.0, maxSpaceBelow),
          _ => 0,
        },
      );
}

String _boundedProjectText(Object? raw, int maxLength) {
  if (raw is! String) return '';
  final value = raw.trim();
  return value.length > maxLength ? value.substring(0, maxLength) : value;
}

class ProjectDoc {
  ProjectDoc({
    required this.id,
    required this.name,
    this.bpm = 140,
    this.beatsPerBar = 4,
    this.loopBars = 4,
    this.key = 'A minor',
    this.seed = 0x7f3a,
    this.master = 0.7,
    this.seamCrossfade = true,
    Map<String, double>? globals,
    List<ModuleDoc>? modules,
    List<LayerDoc>? layers,
    List<ProjectAutomationLaneDoc>? automation,
    List<String>? libraryFolders,
    Map<String, String>? savedLibrarySearches,
    List<CppComponentDoc>? cppComponents,
    List<ComponentUseDoc>? masterComponents,
  })  : globals = globals ?? {},
        modules = modules ?? [],
        layers = layers ?? [],
        automation = automation ?? [],
        libraryFolders = libraryFolders ?? [],
        savedLibrarySearches = savedLibrarySearches ?? {},
        cppComponents = cppComponents ?? [],
        masterComponents = masterComponents ?? [] {
    // Keep the in-memory model canonical: a track owns clip instances, not a legacy
    // single-pattern pointer. The stable ID makes repeated saves deterministic.
    for (final layer in this.layers) {
      if (layer.clips.isNotEmpty) {
        layer.patternId = null;
        continue;
      }
      final legacyPatternId = layer.patternId;
      if (legacyPatternId == null) continue;
      final source = this.modules.where((m) => m.id == legacyPatternId).firstOrNull;
      final parsed = source == null ? null : PatternDoc.parse(source.runSource).doc;
      final inferredLength = parsed?.lengthSteps(beatsPerBar) ?? layer.lengthSteps;
      layer.clips.add(ClipDoc(
        id: 'legacy-${layer.id}',
        patternId: legacyPatternId,
        startSteps: 0,
        lengthSteps: inferredLength > 0 ? inferredLength : 64,
      ));
      layer.patternId = null;
    }
  }

  static const int fileVersion = 2;

  final String id;
  String name;
  double bpm;
  int beatsPerBar;
  int loopBars;
  String key;
  int seed;
  double master;
  bool seamCrossfade;
  Map<String, double> globals; // project-wide control values by name
  List<ModuleDoc> modules;
  List<LayerDoc> layers;
  List<ProjectAutomationLaneDoc> automation;
  List<String> libraryFolders;
  Map<String, String> savedLibrarySearches;
  List<CppComponentDoc> cppComponents;
  List<ComponentUseDoc> masterComponents; // native stereo master effects; this is not a trust grant

  int get stepsPerBar => beatsPerBar * 4;
  int get loopSteps => loopBars * stepsPerBar;
  /// A song position is the engine's 32-bit step count, so a song holds whole bars up to 2^31 - 1 steps (F7.2).
  int get maxLoopBars => 2147483647 ~/ max(4, stepsPerBar);
  int get maxArrangementSteps => maxLoopBars * max(4, stepsPerBar);

  /// Where the song ends: the loop, the last clip end or the last project automation point.
  int get arrangementEndSteps {
    final clipsEnd = layers.fold<int>(loopSteps, (end, layer) =>
        layer.clips.fold<int>(end, (value, clip) => max(value, clip.startSteps + clip.lengthSteps)));
    return automation.fold<int>(clipsEnd, (end, lane) =>
        lane.points.fold<int>(end, (value, point) => max(value, point.step.ceil())));
  }

  /// Stores what [states] reports (Engine.componentStates, per layer id; null for the master) into the
  /// component entries, so the saved project carries each effect's state. Entries it doesn't name keep theirs.
  void storeComponentStates(Map<int, ({String state, int version})> Function(String? layerId) states) {
    void store(List<ComponentUseDoc> chain, String? layerId) {
      if (chain.isEmpty) return;
      states(layerId).forEach((index, s) {
        if (index < 0 || index >= chain.length) return;
        // An empty state is no state: the component keeps nothing beyond its parameters.
        chain[index].state = s.state.isEmpty ? null : s.state;
        chain[index].stateVersion = s.version;
      });
    }

    store(masterComponents, null);
    for (final l in layers) {
      if (!l.isFolder) store(l.components, l.id);
    }
  }

  /// The loop the engine plays: whole bars reaching [arrangementEndSteps], as [toEngineJson] sends it.
  int get engineLoopSteps => min(maxLoopBars, max(loopBars, (arrangementEndSteps / stepsPerBar).ceil())) * stepsPerBar;

  /// How far automation editors reach: the song, every track automation point, and at least 64 bars to place
  /// new points in, so editing never moves a point.
  int get timelineSteps {
    final trackEnd = layers.fold<double>(0, (end, layer) => layer.automation.fold<double>(end, (e, lane) =>
        lane.points.fold<double>(e, (v, point) => max(v, point.step))));
    return min(maxArrangementSteps, max(max(64 * stepsPerBar, arrangementEndSteps), trackEnd.ceil()));
  }
  double get loopSeconds => loopSteps * 15.0 / bpm;

  /// The key as the engine's numbers: root 0..11 from C, scale 0 = major or 1 = minor (scale.* order).
  /// Null for "None", so the engine uses its default (A minor).
  (int, int)? get keyNumbers {
    const names = {'C': 0, 'C#': 1, 'Db': 1, 'D': 2, 'D#': 3, 'Eb': 3, 'E': 4, 'F': 5, 'F#': 6, 'Gb': 6, 'G': 7, //
      'G#': 8, 'Ab': 8, 'A': 9, 'A#': 10, 'Bb': 10, 'B': 11};
    final parts = key.split(' ');
    if (parts.length != 2) return null;
    final root = names[parts[0]];
    final scale = switch (parts[1]) { 'major' => 0, 'minor' => 1, _ => null };
    return root == null || scale == null ? null : (root, scale);
  }

  ModuleDoc? module(String? id) {
    for (final m in modules) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The engine's project JSON (docs/engine.md, "Project file"). Modules get the code last run, not unrun edits.
  String toEngineJson(
      {List<String>? audition, String? auditionPattern, bool auditionOnly = false, int voices = 8, String swap = 'now',
      Set<String>? playableComponents}) {
    final engineLoopBars = engineLoopSteps ~/ stepsPerBar;
    // Native components the engine hasn't loaded (awaiting trust, blocked, failed to build) are left out, so the
    // rest of the song still plays; their automation lanes go with them and the others are renumbered.
    List<ComponentUseDoc> playable(List<ComponentUseDoc> chain) =>
        playableComponents == null ? chain : [for (final c in chain) if (playableComponents.contains(c.id)) c];
    int? playableIndex(List<ComponentUseDoc> chain, int index) {
      if (playableComponents == null) return index;
      if (index < 0 || index >= chain.length || !playableComponents.contains(chain[index].id)) return null;
      return chain.take(index).where((c) => playableComponents.contains(c.id)).length;
    }
    List<ComponentUseDoc> chainOf(String? layerId) =>
        layerId == null ? masterComponents : layers.where((l) => l.id == layerId).firstOrNull?.components ?? const [];
    final engineAutomation = [
      for (final lane in automation)
        if (lane.targetType != 'component')
          lane.toJson()
        else if (playableIndex(chainOf(lane.layerId), lane.component ?? -1) case final int index)
          lane.toJson()..['component'] = index,
    ];
    final result = jsonEncode({
        'caw_project': 1,
        'name': name,
        'bpm': bpm,
        'beats_per_bar': beatsPerBar,
        'loop_bars': engineLoopBars,
        'seed': seed,
        'master': master,
        'seam_crossfade': seamCrossfade,
        'voices': voices,
        'swap': swap,
        if (keyNumbers case (final root, final scale)) ...{'key_root': root, 'key_scale': scale},
        'globals': globals,
        'automation': engineAutomation,
        'modules': [
          for (final m in modules) {'id': m.id, 'name': m.name, 'source': m.runSource, 'params': m.params},
        ],
        'master_components': [for (final c in playable(masterComponents)) c.toJson()],
        'layers': [
          for (final l in layers)
            {
              'id': l.id,
              'name': l.name,
              'chain': l.chain,
              if (playable(l.components).isNotEmpty && !l.isFolder) 'components': [for (final c in playable(l.components)) c.toJson()],
              'parent': l.parentId, 'folder': l.isFolder, 'bus': l.busEnabled,
              'automation': [for (final a in l.automation) a.toJson()],
              if (l.clips.isEmpty && l.patternId != null) 'pattern': l.patternId,
              if (l.clips.isNotEmpty) 'clips': [
                for (final clip in l.clips) {
                  'id': clip.id, 'pattern': clip.patternId, 'start_steps': clip.startSteps,
                  'length_steps': clip.lengthSteps, 'source_offset_steps': clip.sourceOffsetSteps,
                  'loop': clip.loop,
                },
              ],
              'length_steps': l.clips.isNotEmpty ? 0 : l.lengthSteps,
              'volume': l.volume,
              'pan': l.pan,
              'mute': l.mute,
              'solo': l.solo,
            },
        ],
        if (audition != null) 'audition': {'chain': audition, 'pattern': ?auditionPattern},
        'audition_only': auditionOnly && audition != null,
      });
    return result;
  }

  Map<String, dynamic> toJson() => {
        'caw_app_project': fileVersion,
        'id': id,
        'name': name,
        'bpm': bpm,
        'beats_per_bar': beatsPerBar,
        'loop_bars': loopBars,
        'key': key,
        'seed': seed,
        'master': master,
        'seam_crossfade': seamCrossfade,
        'globals': globals,
        'automation': [for (final lane in automation) lane.toJson()],
        'modules': [for (final m in modules) m.toJson()],
        'layers': [for (final l in layers) l.toJson()],
        'library_folders': libraryFolders,
        'saved_library_searches': savedLibrarySearches,
        'cpp_components': [for (final component in cppComponents) component.toJson()],
        'master_components': [for (final c in masterComponents) c.toJson()],
      };

  static ProjectDoc fromJson(Map<String, dynamic> j) {
    final project = ProjectDoc(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Untitled',
      bpm: (j['bpm'] as num?)?.toDouble() ?? 140,
      beatsPerBar: ((j['beats_per_bar'] as num?)?.toInt() ?? 4).clamp(1, 16),  // the engine's meter range
      loopBars: (j['loop_bars'] as num?)?.toInt() ?? 4,
      key: (j['key'] as String?) ?? 'A minor',
      seed: (j['seed'] as num?)?.toInt() ?? 0,
      master: (j['master'] as num?)?.toDouble() ?? 0.7,
      seamCrossfade: j['seam_crossfade'] != false,
      globals: ((j['globals'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
      automation: ((j['automation'] as List?) ?? const []).map((lane) => ProjectAutomationLaneDoc.fromJson(lane as Map<String, dynamic>)).toList(),
      modules: ((j['modules'] as List?) ?? const [])
          .map((m) => ModuleDoc.fromJson(m as Map<String, dynamic>)).toList(),
      libraryFolders: ((j['library_folders'] as List?) ?? const []).whereType<String>().take(512).toList(),
      savedLibrarySearches: {
        for (final entry in ((j['saved_library_searches'] as Map?) ?? const {}).entries.take(32))
          if (_boundedProjectText(entry.key, 64).isNotEmpty && _boundedProjectText(entry.value, 256).isNotEmpty)
            _boundedProjectText(entry.key, 64): _boundedProjectText(entry.value, 256),
      },
      cppComponents: ((j['cpp_components'] as List?) ?? const [])
          .map((component) => CppComponentDoc.fromJson(component as Map<String, dynamic>)).toList(),
      masterComponents: ComponentUseDoc.listFromJson(j['master_components']),
      layers: ((j['layers'] as List?) ?? const []).map((raw) {
        final layer = LayerDoc.fromJson(raw as Map<String, dynamic>);
        // Clips are authoritative once present; the old single-pattern pointer is only a migration source.
        if (layer.clips.isNotEmpty) layer.patternId = null;
        if (layer.clips.isEmpty && layer.patternId != null) {
          final legacyPatternId = layer.patternId!;
          final module = ((j['modules'] as List?) ?? const [])
              .whereType<Map>().where((m) => m['id'] == legacyPatternId).firstOrNull;
          final parsed = module == null ? null
              : PatternDoc.parse((module['run_source'] ?? module['source'] ?? '').toString()).doc;
          final length = parsed?.lengthSteps((j['beats_per_bar'] as num?)?.toInt() ?? 4) ?? layer.lengthSteps;
          layer.clips.add(ClipDoc(id: newId('c'), patternId: legacyPatternId,
              startSteps: 0, lengthSteps: length > 0 ? length : 64));
          layer.patternId = null;
        }
        return layer;
      }).toList(),
    );

    // Rebuild a safe, complete virtual-folder tree from both the folder list and module assignments.
    final safeFolders = <String>{};
    void addFolderPath(String raw) {
      final normalized = _normalizeProjectFolderPath(raw);
      if (normalized == null) return;
      final parts = normalized.split('/');
      for (var i = 1; i <= parts.length; i++) {
        safeFolders.add(parts.take(i).join('/'));
      }
    }
    for (final folder in project.libraryFolders) {
      addFolderPath(folder);
    }
    for (final module in project.modules) {
      final normalized = _normalizeProjectFolderPath(module.folderPath);
      if (normalized == null) {
        module.folderPath = '';
      } else {
        module.folderPath = normalized;
        addFolderPath(normalized);
      }
      module.tags = module.tags.map((tag) => _boundedProjectText(tag, 48))
          .where((tag) => tag.isNotEmpty).take(16).toList();
    }
    project.libraryFolders = safeFolders.toList()..sort();

    project.automation = project.automation.where((lane) =>
      lane.target.isNotEmpty && (lane.targetType == 'global' ||
        (lane.targetType == 'param' && lane.moduleId?.isNotEmpty == true) ||
        // A native component's parameter: its chain index (the layer is optional: absent is the master).
        (lane.targetType == 'component' && (lane.component ?? -1) >= 0 && (lane.component ?? -1) < 64)))
      .toList();
    for (final lane in project.automation) {
      lane.points = lane.points.toList()
        ..forEach((point) {
          point.step = point.step.clamp(0, project.maxArrangementSteps.toDouble()).toDouble();
          point.value = point.value.clamp(-1000000.0, 1000000.0).toDouble();
        })
        ..sort((a, b) => a.step.compareTo(b.step));
    }
    // Keep persisted positions inside what the engine's 32-bit step count can hold; nothing valid moves.
    project.loopBars = project.loopBars.clamp(1, project.maxLoopBars).toInt();
    for (final layer in project.layers) {
      for (final clip in layer.clips) {
        clip.startSteps = clip.startSteps.clamp(0, project.maxArrangementSteps - 1).toInt();
        clip.lengthSteps = clip.lengthSteps.clamp(1, project.maxArrangementSteps - clip.startSteps).toInt();
        clip.sourceOffsetSteps = clip.sourceOffsetSteps.clamp(0, project.maxArrangementSteps).toInt();
      }
      for (final lane in layer.automation) {
        lane.points = lane.points.toList()
          ..forEach((point) {
            point.step = point.step.clamp(0, project.maxArrangementSteps.toDouble()).toDouble();
            point.value = point.value.clamp(lane.target == 'volume' ? 0.0 : -1.0, 1.0).toDouble();
          })
          ..sort((a, b) => a.step.compareTo(b.step));
      }
    }
    return project;
  }
}

/// Normalizes project-local virtual folder paths; these are metadata, never OS filesystem paths.
String? _normalizeProjectFolderPath(String raw) {
  if (raw.length > 512) return null;
  final parts = raw.split('/').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty || parts.length > 32 ||
      parts.any((part) => part == '.' || part == '..' || part.length > 64 || part.contains(String.fromCharCode(92)))) {
    return null;
  }
  return parts.join('/');
}

/// Reads a header value (name, summary, kind) straight from module source, for display before it compiles.
String? headerValue(String source, String key) {
  final lines = const LineSplitter().convert(source);
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  for (final line in lines.skip(1)) {
    final t = line.trim();
    if (t == '---') break;
    final i = t.indexOf(':');
    if (i > 0 && t.substring(0, i).trim() == key) {
      var v = t.substring(i + 1);
      final hash = v.indexOf('#');
      if (hash >= 0) v = v.substring(0, hash);
      return v.trim();
    }
  }
  return null;
}

/// Layer lengths offered in the Arranger, in 16ths (0 = follow the project loop).
List<(int, String)> lengthChoices(int stepsPerBar) => [
      (0, 'Project'),
      (4, '1 beat'),
      (8, '2 beats'),
      for (final b in [1, 2, 3, 4, 5, 6, 7, 8, 16]) (b * stepsPerBar, b == 1 ? '1 bar' : '$b bars'),
    ];
