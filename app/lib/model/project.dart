// The project as the app stores it (patterns, layers, settings) and its translation to the engine's project JSON.
import 'dart:convert';
import 'dart:math';

import 'cpp_component.dart';
import 'midi_mapping.dart';
import 'modulation.dart';
import 'pattern_doc.dart';
import 'routing.dart';

String newId(String prefix) {
  final r = Random.secure();
  return '$prefix${List.generate(8, (_) => r.nextInt(36).toRadixString(36)).join()}';
}

/// A pattern (a note clip's notes as text, #158): its text in the editor, and the text last sent to the engine with
/// Run. The .caw sound modules that shared this type are gone (#160): a project loads with them dropped.
class ModuleDoc {
  ModuleDoc({
    required this.id,
    required this.name,
    required this.source,
    String? runSource,
    this.folderPath = '',
    List<String>? tags,
  })  : runSource = runSource ?? source,
        tags = tags ?? [];

  final String id;
  String name;
  String source;
  String runSource;
  String folderPath;
  List<String> tags;

  bool get edited => source != runSource;

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'source': source, 'run_source': runSource,
    'folder_path': folderPath, 'tags': tags,
  };

  static ModuleDoc fromJson(Map<String, dynamic> j) => ModuleDoc(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? 'Module',
    source: (j['source'] as String?) ?? '',
    runSource: j['run_source'] as String?,
    folderPath: (j['folder_path'] as String?) ?? '',
    tags: ((j['tags'] as List?) ?? const []).whereType<String>().take(16)
        .map((tag) => _boundedProjectText(tag, 48)).where((tag) => tag.isNotEmpty).toList(),
  );
}

class ClipDoc {
  ClipDoc({required this.id, required this.patternId, this.startSteps = 0, this.lengthSteps = 64, this.sourceOffsetSteps = 0,
    this.loop = true, this.linked = false, this.name, this.color, this.mute = false, this.lock = false, List<String>? takes})
      : takes = takes ?? [];
  final String id;
  String patternId;

  /// Loop-recorded takes (pattern ids, oldest first; empty for an ordinary clip): the clip plays one of them,
  /// [patternId], and the clip's Takes picker switches between them (lib/model/live_midi.dart).
  List<String> takes;
  int startSteps;
  int lengthSteps;
  int sourceOffsetSteps;
  bool loop;
  bool linked;

  /// The clip's own name (its Properties); null shows its pattern's name.
  String? name;

  /// The clip's own colour, a track-colour index; null takes its track's colour.
  int? color;

  /// A muted clip stays on the timeline but isn't sent to the engine (REAPER's item mute, UG 7.8).
  bool mute;

  /// A locked clip can't be moved, trimmed, split, glued or deleted until it is unlocked (REAPER's item lock).
  bool lock;

  Map<String, dynamic> toJson() => {
        'id': id, 'pattern': patternId, 'start_steps': startSteps,
        'length_steps': lengthSteps, 'source_offset_steps': sourceOffsetSteps, 'loop': loop, 'linked': linked,
        if (name != null) 'name': name,
        if (color != null) 'color': color,
        if (mute) 'mute': true,
        if (lock) 'lock': true,
        if (takes.isNotEmpty) 'takes': takes,
      };

  static ClipDoc fromJson(Map<String, dynamic> j) => ClipDoc(
        id: j['id'] as String,
        patternId: j['pattern'] as String,
        startSteps: (j['start_steps'] as num?)?.toInt() ?? 0,
        lengthSteps: (j['length_steps'] as num?)?.toInt() ?? 64,
        sourceOffsetSteps: (j['source_offset_steps'] as num?)?.toInt() ?? 0,
        loop: j['loop'] != false,
        linked: j['linked'] == true,
        name: switch (_boundedProjectText(j['name'], 128)) { '' => null, final n => n },
        color: switch (j['color']) { final int c when c >= 0 && c < LayerDoc.trackColors => c, _ => null },
        mute: j['mute'] == true,
        lock: j['lock'] == true,
        takes: [for (final t in (j['takes'] as List?) ?? const []) if (t is String) t].take(64).toList(),
      );
}

/// The one name of an automation lane's target, for track lanes (`track`) and project lanes alike: the automation
/// writer (lib/model/automation_writer.dart) and [ProjectDoc.toEngineJson]'s `suspendLanes` use it.
String automationKey(String type, String target, {String? layerId, String? moduleId, int? component}) =>
    '$type|${layerId ?? ''}|${moduleId ?? ''}|${component ?? ''}|$target';

class AutomationPointDoc {
  AutomationPointDoc({required this.step, required this.value});
  double step, value;
  Map<String, dynamic> toJson() => {'step': step, 'value': value};
  static AutomationPointDoc fromJson(Map<String, dynamic> j) => AutomationPointDoc(
    step: (j['step'] as num?)?.toDouble() ?? 0, value: (j['value'] as num?)?.toDouble() ?? 0);
}

class AutomationLaneDoc {
  AutomationLaneDoc({required this.target, List<AutomationPointDoc>? points, this.armed = true}) : points = points ?? [];
  String target;
  List<AutomationPointDoc> points;

  /// Written by the Automate button (REAPER's envelope arm, UG 18.5); a disarmed lane only plays.
  bool armed;
  Map<String, dynamic> toJson() => {'target': target, 'points': [for (final p in points) p.toJson()], if (!armed) 'armed': false};
  static AutomationLaneDoc fromJson(Map<String, dynamic> j) => AutomationLaneDoc(
    target: j['target'] as String, armed: j['armed'] != false, points: ((j['points'] as List?) ?? const [])
      .map((p) => AutomationPointDoc.fromJson(p as Map<String, dynamic>)).toList());
}

/// A project-level automation lane: a native instrument's parameter (`instrument`, on track [layerId]) or a native
/// component's parameter (`component`: [layerId] null for the master chain, [component] its index in that chain).
class ProjectAutomationLaneDoc {
  ProjectAutomationLaneDoc(
      {required this.targetType, required this.target, this.moduleId, this.layerId, this.component, List<AutomationPointDoc>? points,
      this.armed = true})
      : points = points ?? [];
  String targetType;
  String target;
  String? moduleId;
  String? layerId;
  int? component;
  List<AutomationPointDoc> points;

  /// Written by the Automate button (REAPER's envelope arm); a disarmed lane only plays.
  bool armed;

  String get key => automationKey(targetType, target, layerId: layerId, moduleId: moduleId, component: component);

  Map<String, dynamic> toJson() => {
        'target_type': targetType,
        'target': target,
        if (moduleId != null) 'module': moduleId,
        if (layerId != null) 'layer': layerId,
        if (component != null) 'component': component,
        'points': [for (final p in points) p.toJson()],
        if (!armed) 'armed': false,
      };

  static ProjectAutomationLaneDoc fromJson(Map<String, dynamic> j) => ProjectAutomationLaneDoc(
        targetType: j['target_type'] as String? ?? '',
        target: j['target'] as String? ?? '',
        moduleId: j['module'] as String?,
        layerId: j['layer'] as String?,
        component: (j['component'] as num?)?.toInt(),
        armed: j['armed'] != false,
        points: ((j['points'] as List?) ?? const []).map((p) => AutomationPointDoc.fromJson(p as Map<String, dynamic>)).toList(),
      );
}

/// A native C++ component placed in a chain (a track's inserts or the master's), with the parameter
/// values the project sets. Placing one is not a trust grant: the component must be loaded first.
class ComponentUseDoc {
  ComponentUseDoc(this.id, [Map<String, double>? params, this.bypass = false, this.state, this.stateVersion = 1, this.preset])
      : params = params ?? {};

  /// The synths that became Flagship presets (one synth, 2026-11-10) and the drums that became org.caw.drums (one drum
  /// instrument, 2026-11-11): a project naming one plays the successor with its values mapped
  /// ([ProjectDoc.resolveInstruments]).
  static const retiredInstruments = {
    'org.caw.synth.morph', 'org.caw.bass', 'org.caw.synth.acid', 'org.caw.synth.basic',
    'org.caw.drum.kick', 'org.caw.drum.snare', 'org.caw.drum.hats', 'org.caw.drum.kit',
  };

  /// The built-in preset the values start from (Flagship's "Mono bass"...), or null. The engine puts the preset's
  /// values under [params]; [ProjectDoc.resolveInstruments] fills them in so the knobs show them.
  String? preset;

  final String id;
  Map<String, double> params;

  /// Passes its input through and is not run.
  bool bypass;

  /// What the component's save_state wrote, base64 (`Engine.componentStates`), so a reload or an export starts
  /// from it; null for none.
  String? state;
  int stateVersion;

  /// Where a component with a sidechain input (the ducker, a keyed compressor or gate) hears its key; null: none.
  ComponentKeyDoc? key;

  /// The samples its slots play (the drums' Sample layer: slot n is pad n), by reference; the engine decodes them.
  List<ComponentSampleDoc> samples = [];

  /// The most parameter values an entry keeps: every knob of the largest built-in (the drums' 10392) with room.
  static const maxParams = 16384;

  /// A bare id when nothing else is set, as older projects stored it. [withKey] false leaves the key out (the
  /// engine's copy, when the key would make a loop or names a layer that is gone: [RoutingPlan]).
  Object toJson({bool withKey = true}) => params.isEmpty && !bypass && state == null && preset == null &&
          (key == null || !withKey) && samples.isEmpty
      ? id
      : {
          'id': id,
          if (preset != null) 'preset': preset,
          if (params.isNotEmpty) 'params': params,
          if (bypass) 'bypass': true,
          if (state != null) ...{'state': state, 'state_version': stateVersion},
          if (key != null && withKey) 'key': key!.toJson(),
          if (samples.isNotEmpty) 'samples': [for (final x in samples) x.toJson()],
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
      for (final entry in raw.entries.take(maxParams)) {
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
      switch (_boundedProjectText(j['preset'], 64)) { '' => null, final name => name },
    )
      ..key = ComponentKeyDoc.fromJson(j['key'])
      ..samples = ComponentSampleDoc.listFromJson(j['samples']);
  }

  static List<ComponentUseDoc> listFromJson(Object? raw) => [
        for (final entry in ((raw as List?) ?? const []).take(64)) ?ComponentUseDoc.fromJson(entry),
      ];
}

/// One sample slot of a component (the drums' pads): a file the app keeps ([path]) or a built-in pack sound
/// ([builtin]), never both. The engine's limits (engine/src/project.cpp): 256 entries, slot 0..65535.
class ComponentSampleDoc {
  const ComponentSampleDoc(this.slot, {this.path, this.builtin});
  final int slot;
  final String? path, builtin;

  String get label => builtin ?? (path ?? '').split(RegExp(r'[/\\]')).last;

  Map<String, dynamic> toJson() => {'slot': slot, if (path != null) 'path': path, if (builtin != null) 'builtin': builtin};

  static ComponentSampleDoc? fromJson(Object? j) {
    if (j is! Map) return null;
    final slot = j['slot'];
    final path = _boundedProjectText(j['path'], 4096), builtin = _boundedProjectText(j['builtin'], 256);
    if (slot is! int || slot < 0 || slot > 65535 || path.isEmpty == builtin.isEmpty) return null;
    return ComponentSampleDoc(slot, path: path.isEmpty ? null : path, builtin: builtin.isEmpty ? null : builtin);
  }

  /// One entry per slot (the last wins), at most 256.
  static List<ComponentSampleDoc> listFromJson(Object? raw) {
    final bySlot = <int, ComponentSampleDoc>{};
    for (final e in ((raw is List) ? raw : const []).take(256)) {
      if (fromJson(e) case final s?) bySlot[s.slot] = s;
    }
    return bySlot.values.toList()..sort((a, b) => a.slot.compareTo(b.slot));
  }
}

/// A marker (a named, coloured point in the song) or, with [endSteps], a region (a named span: a verse, a chorus).
/// Stored in the project and shown on the ruler; the engine never sees them.
class MarkerDoc {
  MarkerDoc({required this.id, required this.name, required this.startSteps, this.endSteps, this.color = 0});
  final String id;
  String name;
  int startSteps;

  /// Where a region ends (after [startSteps]); null for a marker.
  int? endSteps;

  /// A track-colour index.
  int color;

  bool get isRegion => endSteps != null;

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'start_steps': startSteps,
        if (endSteps != null) 'end_steps': endSteps,
        'color': color,
      };

  /// Null for an entry without an id or a start.
  static MarkerDoc? fromJson(Object? raw, int maxSteps) {
    if (raw is! Map) return null;
    final id = _boundedProjectText(raw['id'], 64);
    final start = raw['start_steps'];
    if (id.isEmpty || start is! num || !start.isFinite) return null;
    final at = start.toInt().clamp(0, maxSteps - 1).toInt();
    final end = raw['end_steps'];
    return MarkerDoc(
      id: id,
      name: _boundedProjectText(raw['name'], 64),
      startSteps: at,
      endSteps: end is num && end.isFinite && end.toInt() > at ? end.toInt().clamp(at + 1, maxSteps).toInt() : null,
      color: switch (raw['color']) { final int c when c >= 0 && c < LayerDoc.trackColors => c, _ => 0 },
    );
  }
}

/// The most a track or the master gains: +12 dB, 10^(12/20) (owner, 2026-11-10: faders like REAPER's). The engine
/// holds gains to the same range.
const double kMaxMixGain = 3.9810717055349722;

/// An imported MIDI file: its name and the pattern modules its parts became, in the file's order.
class MidiFileDoc {
  MidiFileDoc({required this.id, required this.name, required this.parts});
  final String id;
  String name;
  final List<String> parts;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'parts': parts};

  static MidiFileDoc? fromJson(Map<String, dynamic> j) {
    final id = j['id'], name = j['name'], parts = j['parts'];
    if (id is! String || name is! String || parts is! List) return null;
    return MidiFileDoc(id: id, name: _boundedProjectText(name, 128), parts: parts.whereType<String>().take(256).toList());
  }
}

class LayerDoc {
  LayerDoc({
    required this.id,
    required this.name,
    required this.color,
    this.patternId,
    this.lengthSteps = 0,
    this.volume = 0.8,
    this.pan = 0,
    this.mute = false,
    this.solo = false,
    List<ClipDoc>? clips,
    List<AutomationLaneDoc>? automation,
    List<ComponentUseDoc>? components,
    List<ComponentUseDoc>? noteComponents,
    this.noteVoices = defaultNoteVoices,
    List<SendDoc>? sends,
    this.instrument,
    this.parentId,
    this.isFolder = false,
    this.busEnabled = true,
    this.collapsed = false,
    this.spaceBelow = 0,
    this.ownColor = false,
    this.showLanes = false,
  }) : clips = clips ?? [], automation = automation ?? [], components = components ?? [],
        noteComponents = noteComponents ?? [], sends = sends ?? [];

  /// Per-note FX voices (#127): slots a track's per-note effects run in, 1..[maxNoteVoices].
  static const defaultNoteVoices = 8;
  static const maxNoteVoices = 16;

  /// The tallest visual spacer under a track, in logical pixels.
  static const maxSpaceBelow = 160.0;

  /// How many track colours the themes define (`layer1`..`layer8`); [color] indexes them, wrapping.
  static const trackColors = 8;

  final String id;
  String name;
  int color;

  /// The user chose [color] for this track; without it a track in a folder takes a shade of the folder's colour.
  bool ownColor;

  /// The track's automation lanes are open under it in the arrangement (its envelope button; hidden by default).
  /// Saved with the project, never sent to the engine.
  bool showLanes;
  String? patternId; // a legacy single pattern (migrated to a clip at load); it sets the layer's length
  int lengthSteps; // 16ths; 0 follows the project loop
  double volume, pan;
  bool mute, solo;
  List<ClipDoc> clips;
  List<AutomationLaneDoc> automation;
  List<ComponentUseDoc> components; // native C++ effects after the instrument, before volume and pan (a bus folder's too)

  /// Per-note FX (#127): effects run once per note, between the instrument's voices and its own effects, before
  /// [components]. Only an instrument with a voice bus (its descriptor's per-note domain) can run them.
  List<ComponentUseDoc> noteComponents;

  /// How many notes get their own per-note slot (1..16, default 8); more share one overflow chain.
  int noteVoices;

  /// Copies of the track's sound into bus folders (a reverb bus, a delay bus), beside its route to its folder's bus
  /// or the master; at most [SendDoc.maxSends].
  List<SendDoc> sends;

  /// The native C++ instrument (a built-in or one of the project's) playing the track's notes ([setInstrument]).
  ComponentUseDoc? instrument;
  String? parentId;
  bool isFolder, busEnabled, collapsed;

  /// A spacer drawn under the track in the arrangement, in logical pixels (0: none). It only separates tracks on
  /// screen: it is saved with the project but never sent to the engine.
  double spaceBelow;

  /// Whether the track's sound can differ between left and right before its pan (a native instrument or effect,
  /// or a folder's bus summing its tracks): its meters then show each side. An empty track has one meter.
  bool get isStereo => isFolder || instrument != null || components.isNotEmpty;

  /// Makes [componentId] the track's instrument (null: none). The same id keeps its values; another one starts
  /// from its defaults.
  void setInstrument(String? componentId) {
    if (componentId == null) {
      instrument = null;
      return;
    }
    if (instrument?.id != componentId) instrument = ComponentUseDoc(componentId);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'pattern': patternId,
        'length_steps': lengthSteps,
        'volume': volume,
        'pan': pan,
        'mute': mute,
        'solo': solo,
        'clips': [for (final c in clips) c.toJson()],
        'automation': [for (final a in automation) a.toJson()],
        if (components.isNotEmpty) 'components': [for (final c in components) c.toJson()],
        if (noteComponents.isNotEmpty) 'noteComponents': [for (final c in noteComponents) c.toJson()],
        if (noteVoices != defaultNoteVoices) 'noteVoices': noteVoices,
        if (sends.isNotEmpty) 'sends': [for (final s in sends) s.toJson()],
        if (instrument != null) 'instrument': instrument!.toJson(),
        'parent': parentId, 'folder': isFolder, 'bus': busEnabled, 'collapsed': collapsed,
        if (spaceBelow > 0) 'space_below': spaceBelow,
        if (ownColor) 'own_color': true,
        if (showLanes) 'show_lanes': true,
      };

  static LayerDoc fromJson(Map<String, dynamic> j) => LayerDoc(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Layer',
        color: (j['color'] as num?)?.toInt() ?? 0,
        patternId: j['pattern'] as String?,
        lengthSteps: (j['length_steps'] as num?)?.toInt() ?? 0,
        volume: (j['volume'] as num?)?.toDouble() ?? 0.8,
        pan: (j['pan'] as num?)?.toDouble() ?? 0,
        mute: j['mute'] == true,
        solo: j['solo'] == true,
        clips: ((j['clips'] as List?) ?? const []).map((c) => ClipDoc.fromJson(c as Map<String, dynamic>)).toList(),
        automation: ((j['automation'] as List?) ?? const []).map((a) => AutomationLaneDoc.fromJson(a as Map<String, dynamic>)).toList(),
        components: ComponentUseDoc.listFromJson(j['components']),
        noteComponents: j['folder'] == true ? null : ComponentUseDoc.listFromJson(j['noteComponents']),
        noteVoices: switch (j['noteVoices']) {
          final num v when v.isFinite => v.round().clamp(1, maxNoteVoices),
          _ => defaultNoteVoices,
        },
        sends: SendDoc.listFromJson(j['sends']),
        instrument: j['folder'] == true ? null : ComponentUseDoc.fromJson(j['instrument']),
        parentId: j['parent'] as String?, isFolder: j['folder'] == true,
        busEnabled: j['bus'] != false, collapsed: j['collapsed'] == true,
        spaceBelow: switch (j['space_below']) {
          final num v when v.isFinite => v.toDouble().clamp(0.0, maxSpaceBelow),
          _ => 0,
        },
        ownColor: j['own_color'] == true,
        showLanes: j['show_lanes'] == true,
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
    List<ModuleDoc>? modules,
    List<LayerDoc>? layers,
    List<ProjectAutomationLaneDoc>? automation,
    List<String>? libraryFolders,
    Map<String, String>? savedLibrarySearches,
    List<CppComponentDoc>? cppComponents,
    List<ComponentUseDoc>? masterComponents,
    List<MidiFileDoc>? midiFiles,
    this.loopRange = false,
    this.loopStartSteps = 0,
    this.loopEndSteps = 0,
    List<MarkerDoc>? markers,
  })  : midiFiles = midiFiles ?? [],
        markers = markers ?? [],
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
  List<ModuleDoc> modules; // the patterns

  /// The names of the .caw sound modules dropped when this project was read ([fromJson]; never saved): the app
  /// says so once. Old .caw projects are not converted (owner, 2026-11-10).
  List<String> droppedModules = const [];
  List<LayerDoc> layers;
  List<ProjectAutomationLaneDoc> automation;
  List<String> libraryFolders;
  Map<String, String> savedLibrarySearches;
  List<CppComponentDoc> cppComponents;
  List<ComponentUseDoc> masterComponents; // native stereo master effects; this is not a trust grant

  /// The MIDI files imported into the project, listed in Files (Audio & MIDI): each names the pattern modules its
  /// parts became, so it can be dragged onto a track again. The notes live in those patterns only.
  List<MidiFileDoc> midiFiles;

  /// The loop range (REAPER's loop points, drawn on the ruler): while [loopRange] is on and it has a length,
  /// playback loops from [loopEndSteps] back to [loopStartSteps]; off, the whole song loops, as it always did.
  bool loopRange;
  int loopStartSteps, loopEndSteps;

  /// The range has a length (it was drawn), whether or not it is on.
  bool get hasLoopRange => loopEndSteps > loopStartSteps;

  /// Playback loops over the range now.
  bool get loopsRange => loopRange && hasLoopRange;

  /// Markers and regions on the ruler, in no particular order.
  List<MarkerDoc> markers;

  /// Controller learn: hardware CCs mapped to knobs (Settings › MIDI lists them).
  List<MidiCcMapping> midiMappings = [];

  /// Project modulation (#161, modulation.dart): modulators and the links from their outputs to any knob.
  List<ModulatorDoc> modulators = [];
  List<ModLinkDoc> modLinks = [];

  int get stepsPerBar => beatsPerBar * 4;
  int get loopSteps => loopBars * stepsPerBar;
  /// A song position is the engine's 32-bit step count, so a song holds whole bars up to 2^31 - 1 steps (F7.2).
  int get maxLoopBars => 2147483647 ~/ max(4, stepsPerBar);
  int get maxArrangementSteps => maxLoopBars * max(4, stepsPerBar);

  /// Where the song ends: the loop, the last clip end, the last project automation point, or the loop range's end
  /// while it is on (the engine reaches it too).
  int get arrangementEndSteps {
    final clipsEnd = layers.fold<int>(loopsRange ? max(loopSteps, loopEndSteps) : loopSteps, (end, layer) =>
        layer.clips.fold<int>(end, (value, clip) => max(value, clip.startSteps + clip.lengthSteps)));
    return automation.fold<int>(clipsEnd, (end, lane) =>
        lane.points.fold<int>(end, (value, point) => max(value, point.step.ceil())));
  }

  /// The component index the engine gives a layer's native instrument (CAW_INSTRUMENT_INDEX in caw.h).
  static const instrumentIndex = 0xFFFFFFFF;

  /// Stores what [states] reports (Engine.componentStates, per layer id; null for the master) into the
  /// component entries, so the saved project carries each effect's state. Entries it doesn't name keep theirs.
  void storeComponentStates(Map<int, ({String state, int version})> Function(String? layerId) states) {
    void store(List<ComponentUseDoc> chain, String? layerId, [ComponentUseDoc? instrument]) {
      if (chain.isEmpty && instrument == null) return;
      states(layerId).forEach((index, s) {
        final use = index == instrumentIndex ? instrument : (index >= 0 && index < chain.length ? chain[index] : null);
        if (use == null) return;
        // An empty state is no state: the component keeps nothing beyond its parameters.
        use.state = s.state.isEmpty ? null : s.state;
        use.stateVersion = s.version;
      });
    }

    store(masterComponents, null);
    for (final l in layers) {
      if (!l.isFolder) store(l.components, l.id, l.instrument);
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
  /// How long the song plays before it loops back: [engineLoopSteps] at the tempo.
  double get songSeconds => engineLoopSteps * 15.0 / bpm;

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

  /// The engine's project JSON (docs/engine.md, "Project file"). Patterns get the text last run, not unrun edits.
  String toEngineJson(
      {String? auditionPattern, bool auditionOnly = false, int voices = 8, String swap = 'now',
      ComponentUseDoc? auditionInstrument, List<ComponentUseDoc> auditionComponents = const [],
      Set<String>? playableComponents, Map<String, String>? sourceOverrides, Set<String> suspendLanes = const {}}) {
    final engineLoopBars = engineLoopSteps ~/ stepsPerBar;
    // Native components the engine hasn't loaded (awaiting trust, blocked, failed to build) are left out, so the
    // rest of the song still plays; their automation lanes go with them and the others are renumbered.
    final routing = RoutingPlan.of(this);
    List<ComponentUseDoc> playable(List<ComponentUseDoc> chain) =>
        playableComponents == null ? chain : [for (final c in chain) if (playableComponents.contains(c.id)) c];
    int? playableIndex(List<ComponentUseDoc> chain, int index) {
      if (playableComponents == null) return index;
      if (index < 0 || index >= chain.length || !playableComponents.contains(chain[index].id)) return null;
      return chain.take(index).where((c) => playableComponents.contains(c.id)).length;
    }
    List<ComponentUseDoc> chainOf(String? layerId) =>
        layerId == null ? masterComponents : layers.where((l) => l.id == layerId).firstOrNull?.components ?? const [];
    bool instrumentPlays(LayerDoc l) =>
        !l.isFolder && l.instrument != null && (playableComponents == null || playableComponents.contains(l.instrument!.id));
    // Lanes being written (automation Write and Touch, [automationKey]) are left out: the control's live value plays.
    final engineAutomation = [
      for (final lane in automation)
        if (suspendLanes.contains(lane.key)) ...[]
        else if (lane.targetType == 'instrument') ...[
          if (layers.where((l) => l.id == lane.layerId).firstOrNull case final LayerDoc l when instrumentPlays(l)) lane.toJson(),
        ] else if (lane.targetType != 'component')
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
        if (loopsRange) ...{'loop_range': true, 'loop_start_steps': loopStartSteps, 'loop_end_steps': loopEndSteps},
        'seed': seed,
        'master': master,
        'seam_crossfade': seamCrossfade,
        'voices': voices,
        'swap': swap,
        if (keyNumbers case (final root, final scale)) ...{'key_root': root, 'key_scale': scale},
        'automation': engineAutomation,
        'modules': [
          for (final m in modules)
            {'id': m.id, 'name': m.name, 'source': sourceOverrides?[m.id] ?? m.runSource},
        ],
        'master_components': [for (final c in playable(masterComponents)) c.toJson()],
        'layers': [
          for (final l in layers)
            {
              'id': l.id,
              'name': l.name,
              // A bus folder runs its own effects (a reverb bus); a folder without a bus has none.
              if (playable(l.components).isNotEmpty && (!l.isFolder || l.busEnabled))
                'components': [for (final c in playable(l.components)) c.toJson(withKey: routing.keyPlays(l, c))],
              if (routing.sendsOf(l) case final sends when sends.isNotEmpty) 'sends': [for (final s in sends) s.toJson()],
              // A C++ instrument not loaded yet (awaiting trust, building) is left out: the track is silent until it is.
              if (instrumentPlays(l)) 'instrument': l.instrument!.toJson(),
              // Per-note FX (#127) run inside the instrument, so only with it.
              if (instrumentPlays(l) && playable(l.noteComponents).isNotEmpty) ...{
                'noteComponents': [for (final c in playable(l.noteComponents)) c.toJson()],
                'noteVoices': l.noteVoices,
              },
              'parent': l.parentId, 'folder': l.isFolder, 'bus': l.busEnabled,
              'automation': [
                for (final a in l.automation)
                  if (!suspendLanes.contains(automationKey('track', a.target, layerId: l.id))) a.toJson(),
              ],
              if (l.clips.isEmpty && l.patternId != null) 'pattern': l.patternId,
              if (l.clips.isNotEmpty) 'clips': [
                for (final clip in l.clips) {
                  'id': clip.id, 'pattern': clip.patternId, 'start_steps': clip.startSteps,
                  'length_steps': clip.lengthSteps, 'source_offset_steps': clip.sourceOffsetSteps,
                  'loop': clip.loop,
                  if (clip.mute) 'mute': true,
                },
              ],
              'length_steps': l.clips.isNotEmpty ? 0 : l.lengthSteps,
              'volume': l.volume,
              'pan': l.pan,
              'mute': l.mute,
              'solo': l.solo,
            },
        ],
        // The preview: a C++ instrument and its effects (left out while not loaded) playing a pattern, as a track does.
        if (auditionInstrument != null) 'audition': {
          'pattern': ?auditionPattern,
          if (playableComponents?.contains(auditionInstrument.id) ?? true) 'instrument': auditionInstrument.toJson(),
          if (playable(auditionComponents).isNotEmpty) 'components': [for (final c in playable(auditionComponents)) c.toJson()],
        },
        'audition_only': auditionOnly && auditionInstrument != null,
        // Project modulation (#161): what can play of it (modulation.dart).
        ...engineModulationFields(routing, playableComponents: playableComponents,
            engineIndex: (layerId, index) => playableIndex(chainOf(layerId), index), instrumentPlays: instrumentPlays),
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
        'automation': [for (final lane in automation) lane.toJson()],
        'modules': [for (final m in modules) m.toJson()],
        'layers': [for (final l in layers) l.toJson()],
        'library_folders': libraryFolders,
        'saved_library_searches': savedLibrarySearches,
        'cpp_components': [for (final component in cppComponents) component.toJson()],
        'master_components': [for (final c in masterComponents) c.toJson()],
        if (midiFiles.isNotEmpty) 'midi_files': [for (final f in midiFiles) f.toJson()],
        if (hasLoopRange) ...{'loop_range': loopRange, 'loop_start_steps': loopStartSteps, 'loop_end_steps': loopEndSteps},
        if (markers.isNotEmpty) 'markers': [for (final m in markers) m.toJson()],
        if (midiMappings.isNotEmpty) 'midi_mappings': [for (final m in midiMappings) m.toJson()],
        if (modulators.isNotEmpty) 'modulators': [for (final m in modulators) m.toJson()],
        if (modLinks.isNotEmpty) 'modulation': [for (final l in modLinks) l.toJson()],
      };

  /// Brings each track's instrument up to what the engine plays, with [resolve] (`Engine.resolveInstrument`): a
  /// retired synth (one synth, 2026-11-10) becomes Flagship with the matching preset and its knobs mapped, its
  /// lanes moved to the knobs they map to (and dropped when there is none), and an instrument naming a preset gets
  /// the preset's values under its own so its knobs show them. Returns whether anything changed.
  bool resolveInstruments(Map<String, dynamic>? Function(Map<String, dynamic> entry) resolve) {
    var changed = false;
    for (final l in layers) {
      final use = l.instrument;
      if (l.isFolder || use == null) continue;
      final retired = ComponentUseDoc.retiredInstruments.contains(use.id);
      if (!retired && use.preset == null) continue;
      final r = resolve({'id': use.id, 'params': use.params, if (use.preset != null) 'preset': use.preset});
      if (r == null) continue;
      final params = <String, double>{
        for (final e in ((r['params'] as Map?) ?? const {}).entries)
          if (e.value is num) e.key as String: (e.value as num).toDouble(),
      };
      if (r['migrated'] == true) {
        final lanes = (r['lanes'] as Map?) ?? const {};
        automation.removeWhere((lane) {
          if (lane.targetType != 'instrument' || lane.layerId != l.id) return false;
          final to = lanes[lane.target];
          if (to is! String) return true;  // an old knob with no Flagship knob in its units
          lane.target = to;
          return false;
        });
        l.instrument = ComponentUseDoc(r['id'] as String, params, use.bypass, null, 1, r['preset'] as String?)
          ..samples = use.samples;
        changed = true;
      } else if (params.length != use.params.length || params.entries.any((e) => use.params[e.key] != e.value)) {
        use.params = params;
        changed = true;
      }
    }
    return changed;
  }

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
      automation: ((j['automation'] as List?) ?? const []).map((lane) => ProjectAutomationLaneDoc.fromJson(lane as Map<String, dynamic>)).toList(),
      modules: [
        for (final m in ((j['modules'] as List?) ?? const []).map((m) => ModuleDoc.fromJson(m as Map<String, dynamic>)))
          if (isPatternSource(m.source) || isPatternSource(m.runSource)) m,
      ],
      libraryFolders: ((j['library_folders'] as List?) ?? const []).whereType<String>().take(512).toList(),
      savedLibrarySearches: {
        for (final entry in ((j['saved_library_searches'] as Map?) ?? const {}).entries.take(32))
          if (_boundedProjectText(entry.key, 64).isNotEmpty && _boundedProjectText(entry.value, 256).isNotEmpty)
            _boundedProjectText(entry.key, 64): _boundedProjectText(entry.value, 256),
      },
      cppComponents: ((j['cpp_components'] as List?) ?? const [])
          .map((component) => CppComponentDoc.fromJson(component as Map<String, dynamic>)).toList(),
      masterComponents: ComponentUseDoc.listFromJson(j['master_components']),
      midiFiles: [
        for (final raw in ((j['midi_files'] as List?) ?? const []).take(512))
          if (raw is Map<String, dynamic>) ?MidiFileDoc.fromJson(raw),
      ],
      loopRange: j['loop_range'] == true,
      loopStartSteps: (j['loop_start_steps'] as num?)?.toInt() ?? 0,
      loopEndSteps: (j['loop_end_steps'] as num?)?.toInt() ?? 0,
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

    // .caw sound modules are gone (#160): the project loads without them and says which went.
    project.droppedModules = [
      for (final raw in ((j['modules'] as List?) ?? const []).whereType<Map>())
        if (!project.modules.any((m) => m.id == raw['id'])) (raw['name'] as String?) ?? 'Module',
    ];

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
      lane.target.isNotEmpty && (
        // A native instrument's parameter, on its track (the Automate button writes these).
        (lane.targetType == 'instrument' && lane.layerId?.isNotEmpty == true) ||
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
    project.loopStartSteps = project.loopStartSteps.clamp(0, project.maxArrangementSteps - 1).toInt();
    project.loopEndSteps = project.loopEndSteps.clamp(0, project.maxArrangementSteps).toInt();
    if (!project.hasLoopRange) project.loopRange = false;
    project.midiMappings = [
      for (final raw in ((j['midi_mappings'] as List?) ?? const []).take(1024)) ?MidiCcMapping.fromJson(raw),
    ];
    project.modulators = [
      for (final raw in ((j['modulators'] as List?) ?? const []).take(kMaxModulators)) ?ModulatorDoc.fromJson(raw),
    ];
    project.modLinks = [
      for (final raw in ((j['modulation'] as List?) ?? const []).take(kMaxModLinks)) ?ModLinkDoc.fromJson(raw),
    ];
    project.markers = [
      for (final raw in ((j['markers'] as List?) ?? const []).take(1024)) ?MarkerDoc.fromJson(raw, project.maxArrangementSteps),
    ];
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
            point.value = point.value.clamp(lane.target == 'volume' ? 0.0 : -1.0, lane.target == 'volume' ? kMaxMixGain : 1.0).toDouble();
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

/// Whether [source] is a pattern's text (its header says `kind: pattern`), the one kind of module the app keeps.
bool isPatternSource(String source) => headerValue(source, 'kind') == 'pattern';

/// Reads a header value (name, summary, kind) straight from a pattern's text, for display before it compiles.
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
