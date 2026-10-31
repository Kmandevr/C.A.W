// The project as the app stores it (modules, layers, settings) and its translation to the engine's project JSON.
import 'dart:convert';
import 'dart:math';

import 'pattern_doc.dart';

String newId(String prefix) {
  final r = Random.secure();
  return '$prefix${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

/// A sound module: its code in the editor, and the code last sent to the engine with Run.
class ModuleDoc {
  ModuleDoc({required this.id, required this.name, required this.source, String? runSource, Map<String, double>? params})
      : runSource = runSource ?? source,
        params = params ?? {};

  final String id;
  String name;
  String source;
  String runSource;
  Map<String, double> params;

  bool get edited => source != runSource;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'source': source, 'run_source': runSource, 'params': params};

  static ModuleDoc fromJson(Map<String, dynamic> j) => ModuleDoc(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Module',
        source: (j['source'] as String?) ?? '',
        runSource: j['run_source'] as String?,
        params: ((j['params'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
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
    this.parentId,
    this.isFolder = false,
    this.busEnabled = true,
    this.collapsed = false,
  }) : effectIds = effectIds ?? [], clips = clips ?? [];

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
  String? parentId;
  bool isFolder, busEnabled, collapsed;

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
        'parent': parentId, 'folder': isFolder, 'bus': busEnabled, 'collapsed': collapsed,
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
        parentId: j['parent'] as String?, isFolder: j['folder'] == true,
        busEnabled: j['bus'] != false, collapsed: j['collapsed'] == true,
      );
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
  })  : globals = globals ?? {},
        modules = modules ?? [],
        layers = layers ?? [];

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

  int get stepsPerBar => beatsPerBar * 4;
  int get loopSteps => loopBars * stepsPerBar;
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
      {List<String>? audition, String? auditionPattern, bool auditionOnly = false, int voices = 8, String swap = 'now'}) {
    final arrangementEnd = layers.fold<int>(loopSteps, (end, l) =>
        max(end, l.clips.fold<int>(0, (e, clip) => max(e, clip.startSteps + clip.lengthSteps))));
    final engineLoopBars = min(64, max(loopBars, (arrangementEnd / stepsPerBar).ceil()));
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
        'modules': [
          for (final m in modules) {'id': m.id, 'name': m.name, 'source': m.runSource, 'params': m.params},
        ],
        'layers': [
          for (final l in layers)
            {
              'id': l.id,
              'name': l.name,
              'chain': l.chain,
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
        'modules': [for (final m in modules) m.toJson()],
        'layers': [for (final l in layers) l.toJson()],
      };

  static ProjectDoc fromJson(Map<String, dynamic> j) => ProjectDoc(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Untitled',
        bpm: (j['bpm'] as num?)?.toDouble() ?? 140,
        beatsPerBar: (j['beats_per_bar'] as num?)?.toInt() ?? 4,
        loopBars: (j['loop_bars'] as num?)?.toInt() ?? 4,
        key: (j['key'] as String?) ?? 'A minor',
        seed: (j['seed'] as num?)?.toInt() ?? 0,
        master: (j['master'] as num?)?.toDouble() ?? 0.7,
        seamCrossfade: j['seam_crossfade'] != false,
        globals: ((j['globals'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        modules: ((j['modules'] as List?) ?? const [])
            .map((m) => ModuleDoc.fromJson(m as Map<String, dynamic>))
            .toList(),
        layers: ((j['layers'] as List?) ?? const [])
            .map((raw) {
              final layer = LayerDoc.fromJson(raw as Map<String, dynamic>);
              if (((j['caw_app_project'] as num?)?.toInt() ?? 1) < fileVersion && layer.clips.isEmpty && layer.patternId != null) {
                final module = ((j['modules'] as List?) ?? const [])
                    .whereType<Map>().where((m) => m['id'] == layer.patternId).firstOrNull;
                final parsed = module == null ? null : PatternDoc.parse((module['run_source'] ?? module['source'] ?? '').toString()).doc;
                final length = parsed?.lengthSteps((j['beats_per_bar'] as num?)?.toInt() ?? 4) ?? layer.lengthSteps;
                layer.clips.add(ClipDoc(id: newId('c'), patternId: layer.patternId!, startSteps: 0,
                    lengthSteps: length > 0 ? length : 64));
              }
              return layer;
            }).toList(),
      );
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
