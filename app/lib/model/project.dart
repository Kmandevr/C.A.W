// The project as the app stores it (modules, layers, settings) and its translation to the engine's project JSON.
import 'dart:convert';
import 'dart:math';

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

class LayerDoc {
  LayerDoc({
    required this.id,
    required this.name,
    required this.color,
    this.generatorId,
    List<String>? effectIds,
    this.lengthSteps = 0,
    this.volume = 0.8,
    this.pan = 0,
    this.mute = false,
    this.solo = false,
  }) : effectIds = effectIds ?? [];

  final String id;
  String name;
  int color;
  String? generatorId;
  List<String> effectIds;
  int lengthSteps; // 16ths; 0 follows the project loop
  double volume, pan;
  bool mute, solo;

  List<String> get chain => [?generatorId, ...effectIds];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'generator': generatorId,
        'effects': effectIds,
        'length_steps': lengthSteps,
        'volume': volume,
        'pan': pan,
        'mute': mute,
        'solo': solo,
      };

  static LayerDoc fromJson(Map<String, dynamic> j) => LayerDoc(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Layer',
        color: (j['color'] as num?)?.toInt() ?? 0,
        generatorId: j['generator'] as String?,
        effectIds: ((j['effects'] as List?) ?? const []).cast<String>().toList(),
        lengthSteps: (j['length_steps'] as num?)?.toInt() ?? 0,
        volume: (j['volume'] as num?)?.toDouble() ?? 0.8,
        pan: (j['pan'] as num?)?.toDouble() ?? 0,
        mute: j['mute'] == true,
        solo: j['solo'] == true,
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
    List<ModuleDoc>? modules,
    List<LayerDoc>? layers,
  })  : modules = modules ?? [],
        layers = layers ?? [];

  static const int fileVersion = 1;

  final String id;
  String name;
  double bpm;
  int beatsPerBar;
  int loopBars;
  String key;
  int seed;
  double master;
  bool seamCrossfade;
  List<ModuleDoc> modules;
  List<LayerDoc> layers;

  int get stepsPerBar => beatsPerBar * 4;
  int get loopSteps => loopBars * stepsPerBar;
  double get loopSeconds => loopSteps * 15.0 / bpm;

  ModuleDoc? module(String? id) {
    for (final m in modules) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The engine's project JSON (docs/engine.md, "Project file"). Modules get the code last run, not unrun edits.
  String toEngineJson({List<String>? audition, bool auditionOnly = false}) => jsonEncode({
        'caw_project': 1,
        'name': name,
        'bpm': bpm,
        'beats_per_bar': beatsPerBar,
        'loop_bars': loopBars,
        'seed': seed,
        'master': master,
        'seam_crossfade': seamCrossfade,
        'modules': [
          for (final m in modules) {'id': m.id, 'source': m.runSource, 'params': m.params},
        ],
        'layers': [
          for (final l in layers)
            {
              'id': l.id,
              'name': l.name,
              'chain': l.chain,
              'length_steps': l.lengthSteps,
              'volume': l.volume,
              'pan': l.pan,
              'mute': l.mute,
              'solo': l.solo,
            },
        ],
        if (audition != null) 'audition': {'chain': audition},
        'audition_only': auditionOnly && audition != null,
      });

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
        modules: ((j['modules'] as List?) ?? const [])
            .map((m) => ModuleDoc.fromJson(m as Map<String, dynamic>))
            .toList(),
        layers: ((j['layers'] as List?) ?? const [])
            .map((l) => LayerDoc.fromJson(l as Map<String, dynamic>))
            .toList(),
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
