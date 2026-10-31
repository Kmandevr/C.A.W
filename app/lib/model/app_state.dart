// App state: settings, the startup choice, the open project, engine sync, autosave, meters and every edit.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import 'poller.dart';
import 'project.dart';
import 'pattern_doc.dart';
import 'settings.dart';
import 'storage.dart';

/// What the startup screen offers: the last project (if it still exists) and every saved project.
({ProjectSummary? last, List<ProjectSummary> projects}) startupChoices(String? lastId, List<ProjectSummary> projects) =>
    (last: projects.where((p) => p.id == lastId).firstOrNull, projects: projects);

class AppState extends ChangeNotifier {
  AppState({Settings? settings}) : settings = settings ?? Settings() {
    _light = this.settings.lightMode;
    this.settings.addListener(_settingsChanged);
  }

  late bool _light;

  // Light mode changes the engine's voice count and the meter rate.
  void _settingsChanged() {
    if (settings.lightMode == _light) return;
    _light = settings.lightMode;
    _poller.interval = Duration(milliseconds: _light ? 66 : 33);
    _sync();
  }

  /// App-wide settings (theme, density, live coding).
  final Settings settings;

  Engine? engine;
  String? engineError;
  String? audioError;
  ProjectStorage? _storage;
  List<Template> templates = const [];

  ProjectDoc project = ProjectDoc(id: newId('p'), name: 'Untitled');
  Map<String, ModuleInfo> info = {};
  String? selectedModuleId;
  String? selectedLayerId;
  String? selectedClipId;
  final Set<String> selectedClipIds = {};
  int? timeSelectionStart, timeSelectionEnd, timeSelectionAnchor;
  int arrangementSnapSteps = 1;
  bool previewOnly = false;
  bool ready = false;

  /// True until the startup screen's choice opens a project.
  bool starting = true;
  String? lastProjectId;
  List<ProjectSummary> savedProjects = const [];

  /// The kind picked for a blank new module, so the editor can hint until the file has a header (not saved).
  final Map<String, String> blankKinds = {};

  /// Bumped on every meter poll (about 30 times a second) so meters can repaint without rebuilding screens.
  final ValueNotifier<int> tick = ValueNotifier(0);

  /// Bumped when a param, global, volume or pan changes. Only the controls showing those values listen, so a slider
  /// drag doesn't rebuild the whole app (it rebuilt about 3,500 widgets per step before).
  final ValueNotifier<int> values = ValueNotifier(0);
  EngineMeters meters = const EngineMeters();

  /// Set when an overload switched light mode on, so the app can say so once.
  bool lightTurnedOnBySelf = false;
  List<LayerMeterValue> layerMeters = const [];

  Timer? _saveTimer;
  Timer? _syncTimer;
  Timer? _liveTimer;
  // Meters are read only while something moves; stopped and settled, the app does no work and closes the audio
  // device after a while (Play reopens it).
  late final Poller _poller = Poller(
      poll: _poll,
      interval: Duration(milliseconds: settings.lightMode ? 66 : 33),
      onIdle: () {
    if (!meters.playing) engine?.stopAudio();
  });

  Future<void> init() async {
    try {
      engine = Engine.create();
      templates = Engine.templates();
      audioError = engine!.startAudio();
    } catch (e) {
      engineError = 'The sound engine did not load: $e';
    }
    _storage = await ProjectStorage.open();
    lastProjectId = await _storage!.lastOpened();
    savedProjects = await listProjects();
    ready = true;
    notifyListeners();
    _poller.wake();
  }

  /// The startup screen's choice: opens [p] without saving the placeholder project shown before it.
  Future<void> start(ProjectDoc p) async {
    starting = false;
    await _switchTo(p, saveCurrent: false);
  }

  Future<void> startLast() async {
    final p = lastProjectId == null ? null : await _storage?.load(lastProjectId!);
    await start(p ?? starterProject());
  }

  Future<void> startProject(String id) async {
    final p = await _storage?.load(id);
    if (p != null) await start(p);
  }

  /// An empty project: no modules and no layers.
  ProjectDoc blankProject() => ProjectDoc(id: newId('p'), name: 'New project');

  @override
  void dispose() {
    settings.removeListener(_settingsChanged);
    _poller.dispose();
    _liveTimer?.cancel();
    _saveTimer?.cancel();
    _syncTimer?.cancel();
    engine?.dispose();
    super.dispose();
  }

  /// One meter read; returns whether anything is still moving.
  bool _poll() {
    final e = engine;
    if (e == null) return false;
    final before = meters;
    meters = e.meters();
    layerMeters = [for (var i = 0; i < project.layers.length; i++) e.layerMeter(i)];
    tick.value++;
    if (meters.overloaded > before.overloaded && settings.lightAuto && !settings.lightMode) {
      // The device can't keep up: light mode turns on by itself, once (the setting can turn it back off).
      lightTurnedOnBySelf = true;
      settings.update((s) {
        s.lightMode = true;
        s.lightAuto = false;
      });
    }
    if (before.playing != meters.playing || before.overloaded != meters.overloaded) notifyListeners();
    return meters.playing || meters.peakL > 0 || meters.peakR > 0 || layerMeters.any((m) => m.peak > 0);
  }

  // ---------- starter content ----------

  Template? template(String file) {
    for (final t in templates) {
      if (t.file == file) return t;
    }
    return null;
  }

  ModuleDoc moduleFromTemplate(Template t) =>
      ModuleDoc(id: newId('m'), name: headerValue(t.source, 'name') ?? t.file.replaceAll('.caw', ''), source: t.source);

  /// A first project that shows the idea: layers of different lengths over one 4-bar loop.
  ProjectDoc starterProject() {
    final p = ProjectDoc(id: newId('p'), name: 'First loop');
    ModuleDoc? add(String file) {
      final t = template(file);
      if (t == null) return null;
      final m = moduleFromTemplate(t);
      p.modules.add(m);
      return m;
    }

    final kick = add('kick.caw');
    final bass = add('bass.caw');
    final hats = add('hats.caw');
    final byte = add('bytebeat-loop.caw');
    final crush = add('bitcrush.caw');
    add('glitch-fx.caw');
    add('fold.caw');
    final acid = add('acid-synth.caw');
    final line = add('acid-line.caw');
    add('chords.caw');
    var c = 0;
    void layer(String name, ModuleDoc? gen, int steps, double vol,
        [List<ModuleDoc?> fx = const [], ModuleDoc? pattern, bool mute = false]) {
      if (gen == null) return;
      p.layers.add(LayerDoc(
          id: newId('l'),
          name: name,
          color: c++ % 4,
          generatorId: gen.id,
          effectIds: [for (final f in fx) if (f != null) f.id],
          patternId: pattern?.id,
          lengthSteps: steps,
          volume: vol,
          mute: mute));
    }

    layer('Kick', kick, 16, 0.9);
    layer('Bass', bass, 16, 0.7);
    layer('Hats', hats, 16, 0.5);
    layer('Byte lead', byte, 48, 0.35, [crush]);
    // Muted to start with: unmute it to hear a sound played from a pattern's notes.
    layer('Acid', acid, 0, 0.6, const [], line, true);
    return p;
  }

  // ---------- engine sync and saving ----------

  /// What Solo preview plays for the selected module: a generator alone, an effect after a generator that uses it,
  /// or a pattern through the sound of a layer that plays it. Each plays the pattern of its layer, if it has one.
  ({List<String> chain, String? pattern})? get preview {
    final m = project.module(selectedModuleId);
    if (m == null || isLibrary(m.id)) return null;
    String? firstGenerator() => project.modules.where((x) => isGenerator(x.id)).map((x) => x.id).firstOrNull;
    if (isPattern(m.id)) {
      final layer = project.layers.where((l) => l.patternId == m.id && l.generatorId != null).firstOrNull;
      final gen = layer?.generatorId ?? firstGenerator();
      return gen == null ? null : (chain: layer?.chain ?? [gen], pattern: m.id);
    }
    if (!isEffect(m.id)) {
      final layer = project.layers.where((l) => l.generatorId == m.id).firstOrNull;
      return (chain: [m.id], pattern: layer?.patternId);
    }
    final layer = project.layers.where((l) => l.effectIds.contains(m.id) && l.generatorId != null).lastOrNull;
    final gen = layer?.generatorId ?? firstGenerator();
    return (chain: [?gen, m.id], pattern: layer?.patternId);
  }

  Future<void> _syncNow() async {
    final e = engine;
    if (e == null) return;
    final pv = previewOnly ? preview : null;
    final json = project.toEngineJson(
        audition: pv?.chain,
        auditionPattern: pv?.pattern,
        auditionOnly: previewOnly,
        voices: settings.lightMode ? 4 : 8,
        swap: settings.swapTiming.name);
    try {
      info = await e.setProject(json);
    } catch (err) {
      engineError = 'Engine error: $err';
    }
    notifyListeners();
  }

  /// Sends the project to the engine soon (edits in quick succession are sent once).
  void _sync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 40), _syncNow);
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    if (starting) return; // the placeholder shown behind the startup screen is never saved
    await _storage?.save(project);
  }

  void _changed({bool engine = true}) {
    if (engine) _sync();
    _save();
    notifyListeners();
  }

  // ---------- transport ----------

  void togglePlay() {
    final e = engine;
    if (e == null) return;
    if (meters.playing) {
      e.stop();
    } else {
      if (!e.audioOn) audioError = e.startAudio();
      e.play();
    }
    meters = e.meters();
    _poller.wake();
    notifyListeners();
  }

  void clearOverload() {
    engine?.clearOverload();
    _poller.wake();
    notifyListeners();
  }

  /// Called when the app goes to the background or returns.
  void lifecycle({required bool foreground}) {
    _poller.setVisible(foreground);
    final e = engine;
    if (e == null) return;
    if (!foreground) {
      flush();
      if (!meters.playing) e.stopAudio();
    } else if (!e.audioOn) {
      audioError = e.startAudio();
      notifyListeners();
    }
  }

  // ---------- modules (Builder) ----------

  void selectModule(String id) {
    selectedModuleId = id;
    if (previewOnly) _sync();
    notifyListeners();
  }

  void editSource(String id, String source) {
    final m = project.module(id);
    if (m == null || m.source == source) return;
    final wasEdited = m.edited;
    m.source = source;
    // The text lives in the editor; the rest of the app only shows whether the module has unrun edits.
    if (m.edited != wasEdited) {
      _changed(engine: false);
    } else {
      _save();
    }
    _scheduleLive(id);
  }

  /// Auto-update: after the pause set in the settings, code that compiles swaps in by itself (at the swap timing).
  /// Code with an error waits for the next edit; light mode waits while playing, so swaps then happen on Run only.
  void _scheduleLive(String id) {
    _liveTimer?.cancel();
    if (!settings.liveUpdate || engine == null) return;
    _liveTimer = Timer(Duration(milliseconds: settings.liveDelayMs), () {
      final m = project.module(id);
      if (m == null || !m.edited || (settings.lightMode && meters.playing)) return;
      try {
        if (!Engine.check(m.source).ok) return;
      } catch (_) {
        return;
      }
      run(id);
    });
  }

  /// Run: the editor's code goes to the engine and hot-swaps. If it fails, the last good code keeps playing.
  Future<ModuleInfo?> run(String id) async {
    final m = project.module(id);
    if (m == null) return null;
    m.runSource = m.source;
    final name = headerValue(m.source, 'name');
    if (name != null && name.isNotEmpty) m.name = name;
    _save();
    _syncTimer?.cancel();
    await _syncNow();
    return info[id];
  }

  String _freeModuleName(String base) {
    var name = base;
    var n = 2;
    while (project.modules.any((x) => x.name == name)) {
      name = '$base ${n++}';
    }
    return name;
  }

  String addModule(Template t) {
    final m = moduleFromTemplate(t);
    m.name = _freeModuleName(m.name);
    project.modules.add(m);
    selectedModuleId = m.id;
    _changed();
    return m.id;
  }

  /// A new, truly empty module. Until it has a header it compiles as a byte-mode generator, so the picked [kind]
  /// (generator, effect, pattern or library) is remembered only for the editor's hint and badge.
  String addBlankModule(String kind) {
    final label = switch (kind) { 'effect' => 'Effect', 'pattern' => 'Pattern', 'library' => 'Library', _ => 'Sound' };
    final m = ModuleDoc(id: newId('m'), name: _freeModuleName(label), source: '');
    project.modules.add(m);
    blankKinds[m.id] = kind;
    selectedModuleId = m.id;
    _changed();
    return m.id;
  }

  /// The kind to hint for an empty module (null once it has any text).
  String? hintKindOf(String moduleId) {
    final m = project.module(moduleId);
    if (m == null || m.source.isNotEmpty) return null;
    return blankKinds[moduleId] ?? 'generator';
  }

  void renameModule(String id, String name) {
    final m = project.module(id);
    if (m == null || name.trim().isEmpty) return;
    m.name = name.trim();
    _changed(engine: false);
  }

  void deleteModule(String id) {
    project.modules.removeWhere((m) => m.id == id);
    for (final l in project.layers) {
      if (l.generatorId == id) l.generatorId = null;
      if (l.patternId == id) l.patternId = null;
      l.effectIds.remove(id);
    }
    if (selectedModuleId == id) selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
    _changed();
  }

  void setParam(String moduleId, String name, double value) {
    final m = project.module(moduleId);
    if (m == null) return;
    m.params[name] = value;
    engine?.setParam(moduleId, name, value);
    _save();
    values.value++;
  }

  /// Every `global` declared by the project's modules, once each (the first declaration wins).
  List<ParamInfo> get globalDefs {
    final seen = <String>{};
    final out = <ParamInfo>[];
    for (final m in project.modules) {
      for (final p in info[m.id]?.params ?? const <ParamInfo>[]) {
        if (p.global && seen.add(p.name)) out.add(p);
      }
    }
    return out;
  }

  double globalValue(ParamInfo p) => project.globals[p.name] ?? p.defaultValue;

  void setGlobal(String name, double value) {
    project.globals[name] = value;
    engine?.setGlobal(name, value);
    _save();
    values.value++;
  }

  void setPreviewOnly(bool on) {
    previewOnly = on;
    _changed(engine: true);
  }

  /// generator, effect or library: from the last check, or the header before the module has compiled.
  String kindOf(String moduleId) {
    final m = project.module(moduleId);
    if (m == null) return 'generator';
    return info[moduleId]?.kind ?? headerValue(m.runSource, 'kind') ?? 'generator';
  }

  bool isEffect(String moduleId) => kindOf(moduleId) == 'effect';
  bool isLibrary(String moduleId) => kindOf(moduleId) == 'library';
  bool isPattern(String moduleId) => kindOf(moduleId) == 'pattern';
  bool isGenerator(String moduleId) => kindOf(moduleId) == 'generator';

  // ---------- layers (Arranger) ----------

  List<LayerDoc> get visibleLayers => project.layers.where((layer) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
      final folder = project.layers.where((x) => x.id == parent).firstOrNull;
      if (folder == null) break;
      if (folder.collapsed) return false;
      parent = folder.parentId;
    }
    return true;
  }).toList();

  int folderDepth(LayerDoc layer) {
    var depth = 0, parent = layer.parentId;
    final seen = <String>{layer.id};
    while (parent != null && seen.add(parent)) {
      final folder = project.layers.where((x) => x.id == parent).firstOrNull;
      if (folder == null) break;
      depth++;
      parent = folder.parentId;
    }
    return depth;
  }

  bool moveLayerIntoFolder(LayerDoc layer, String? folderId) {
    if (folderId == layer.id) return false;
    if (folderId != null) {
      final folder = project.layers.where((x) => x.id == folderId).firstOrNull;
      if (folder == null || !folder.isFolder) return false;
      var parent = folder.parentId;
      for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
        if (parent == layer.id) return false;
        parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
      }
    }
    bool inSubtree(LayerDoc candidate, String root) {
      var parent = candidate.parentId;
      for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
        if (parent == root) return true;
        parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
      }
      return false;
    }
    final subtree = project.layers.where((candidate) =>
      candidate.id == layer.id || inSubtree(candidate, layer.id)).toList();
    project.layers.removeWhere((candidate) => subtree.contains(candidate));
    layer.parentId = folderId;
    if (folderId == null) {
      project.layers.addAll(subtree);
    } else {
      var insertAt = project.layers.indexWhere((x) => x.id == folderId) + 1;
      while (insertAt < project.layers.length && inSubtree(project.layers[insertAt], folderId)) {
        insertAt++;
      }
      project.layers.insertAll(insertAt, subtree);
    }
    _changed();
    return true;
  }

  void setFolderBus(LayerDoc folder, bool enabled) {
    if (!folder.isFolder) return;
    editLayer(folder, (l) => l.busEnabled = enabled);
  }

  void setFolderCollapsed(LayerDoc folder, bool collapsed) {
    if (!folder.isFolder) return;
    editLayer(folder, (l) => l.collapsed = collapsed);
  }

  void addAutomationLane(LayerDoc layer, String target) {
    if (target != 'volume' && target != 'pan') return;
    if (layer.automation.any((a) => a.target == target)) return;
    editLayer(layer, (l) => l.automation.add(AutomationLaneDoc(target: target,
      points: [AutomationPointDoc(step: 0, value: target == 'volume' ? l.volume : l.pan),
        AutomationPointDoc(step: project.loopSteps.toDouble(), value: target == 'volume' ? l.volume : l.pan)])));
  }

  void removeAutomationLane(LayerDoc layer, AutomationLaneDoc lane) {
    editLayer(layer, (l) => l.automation.remove(lane));
  }

  void updateAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, int index, double step, double value) {
    if (index < 0 || index >= lane.points.length) return;
    editLayer(layer, (l) {
      final p = lane.points[index];
      final sorted = [...lane.points]..sort((a, b) => a.step.compareTo(b.step));
      final position = sorted.indexOf(p);
      final lower = position > 0 ? sorted[position - 1].step + 0.01 : 0.0;
      final upper = position >= 0 && position < sorted.length - 1 ? sorted[position + 1].step - 0.01 : 4096.0;
      p.step = step.clamp(lower, upper).toDouble();
      p.value = value.clamp(lane.target == 'volume' ? 0.0 : -1.0, 1.0).toDouble();
      // Clamp to neighboring points instead of reordering during a drag; the dragged handle stays stable.
    });
  }

  void addAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, double step, double value) {
    editLayer(layer, (l) {
      l.automation.firstWhere((a) => a.target == lane.target).points.add(
        AutomationPointDoc(step: step.clamp(0, 4096).toDouble(),
          value: value.clamp(lane.target == 'volume' ? 0.0 : -1.0, 1.0).toDouble()));
      l.automation.firstWhere((a) => a.target == lane.target).points.sort((a, b) => a.step.compareTo(b.step));
    });
  }

  void beginTimeSelection(int step) {
    timeSelectionAnchor = step.clamp(0, 4096).toInt();
    setTimeSelection(step, step);
  }

  void updateTimeSelection(int step) {
    final anchor = timeSelectionAnchor ?? timeSelectionStart ?? step;
    setTimeSelection(anchor, step);
  }

  void endTimeSelection() {
    timeSelectionAnchor = null;
  }

  void setTimeSelection(int start, int end) {
    timeSelectionStart = start.clamp(0, 4096).toInt();
    timeSelectionEnd = end.clamp(0, 4096).toInt();
    notifyListeners();
  }

  void clearTimeSelection() {
    timeSelectionStart = timeSelectionEnd = timeSelectionAnchor = null;
    notifyListeners();
  }

  void splitClipAt(LayerDoc layer, ClipDoc clip, int atStep) {
    final offset = atStep - clip.startSteps;
    if (offset <= 0 || offset >= clip.lengthSteps) return;
    final right = ClipDoc(id: newId('c'), patternId: clip.patternId,
      startSteps: atStep, lengthSteps: clip.lengthSteps - offset,
      sourceOffsetSteps: clip.sourceOffsetSteps + offset, loop: clip.loop, linked: true);
    editLayer(layer, (l) {
      clip.lengthSteps = offset;
      l.clips.add(right);
    });
    selectClip(layer, right);
  }


  void addLayer() {
    final gen = project.modules.where((m) => isGenerator(m.id)).firstOrNull;
    project.layers.add(LayerDoc(
      id: newId('l'),
      name: gen?.name ?? 'Layer ${project.layers.length + 1}',
      color: project.layers.length % 4,
      generatorId: gen?.id,
      lengthSteps: project.stepsPerBar,
    ));
    _changed();
  }

  void removeLayer(LayerDoc l) {
    for (final child in project.layers.where((x) => x.parentId == l.id)) {
      child.parentId = l.parentId;
    }
    project.layers.remove(l);
    if (selectedLayerId == l.id) selectedLayerId = null;
    _changed();
  }

  void moveLayer(int from, int to) {
    if (to > from) to--;
    final l = project.layers.removeAt(from);
    project.layers.insert(to, l);
    _changed();
  }

  /// Structural layer changes (modules, length) go through a project sync.
  void editLayer(LayerDoc l, void Function(LayerDoc) change) {
    change(l);
    _changed();
  }

  /// Volume, pan, mute and solo go straight to the audio thread.
  void mixLayer(LayerDoc l, {double? volume, double? pan, bool? mute, bool? solo}) {
    if (volume != null) l.volume = volume;
    if (pan != null) l.pan = pan;
    if (mute != null) l.mute = mute;
    if (solo != null) l.solo = solo;
    engine?.setLayerMix(l.id, l.volume, l.pan, l.mute, l.solo);
    // Volume and pan drags only redraw their sliders; mute and solo change how the whole layer list looks.
    if (mute == null && solo == null) {
      _save();
      values.value++;
    } else {
      _changed(engine: false);
    }
  }

  bool get canMultiEditSelectedClips {
    if (selectedClipIds.length < 2) return false;
    final ids = <String>{};
    for (final layer in project.layers) {
      for (final clip in layer.clips) {
        if (selectedClipIds.contains(clip.id)) ids.add(clip.patternId);
      }
    }
    return ids.length == 1;
  }

  Set<String> get selectedPatternModuleIds => {
    for (final layer in project.layers)
      for (final clip in layer.clips)
        if (selectedClipIds.contains(clip.id)) clip.patternId,
  };

  List<PatternDoc> get selectedPatternReferences {
    final active = selectedModuleId;
    final refs = <PatternDoc>[];
    final seen = <String>{};
    for (final layer in project.layers) {
      for (final clip in layer.clips) {
        if (!selectedClipIds.contains(clip.id) || clip.patternId == active || !seen.add(clip.patternId)) continue;
        final module = project.module(clip.patternId);
        if (module == null) continue;
        final parsed = PatternDoc.parse(module.runSource);
        if (parsed.ok && parsed.doc != null) refs.add(parsed.doc!);
      }
    }
    return refs;
  }

  void activateClip(LayerDoc layer, ClipDoc clip) {
    selectedLayerId = layer.id;
    selectedClipId = clip.id;
    selectedModuleId = clip.patternId;
    selectedClipIds.add(clip.id);
    notifyListeners();
  }

  void selectClip(LayerDoc layer, ClipDoc clip, {bool additive = false}) {
    if (!additive) selectedClipIds.clear();
    if (additive && selectedClipIds.contains(clip.id)) {
      selectedClipIds.remove(clip.id);
      if (selectedClipIds.isEmpty) {
        selectedClipId = null;
        selectedLayerId = null;
        selectedModuleId = null;
      } else {
        final next = project.layers.expand((l) => l.clips.map((c) => (l, c)))
            .where((entry) => selectedClipIds.contains(entry.$2.id)).first;
        selectedLayerId = next.$1.id;
        selectedClipId = next.$2.id;
        selectedModuleId = next.$2.patternId;
      }
    } else {
      selectedClipIds.add(clip.id);
      selectedLayerId = layer.id;
      selectedClipId = clip.id;
      selectedModuleId = clip.patternId;
    }
    notifyListeners();
  }

  void addClip(LayerDoc layer, String patternId, {int? startSteps}) {
    final module = project.module(patternId);
    if (module == null || !isPattern(patternId)) return;
    final doc = PatternDoc.parse(module.runSource).doc;
    final length = doc?.lengthSteps(project.beatsPerBar) ?? project.stepsPerBar;
    final end = layer.clips.fold<int>(0, (v, c) => v > c.startSteps + c.lengthSteps ? v : c.startSteps + c.lengthSteps);
    final clip = ClipDoc(id: newId('c'), patternId: patternId,
        startSteps: startSteps ?? end, lengthSteps: length);
    editLayer(layer, (l) => l.clips.add(clip));
    selectClip(layer, clip);
  }

  void duplicateClip(LayerDoc layer, ClipDoc clip, {bool linked = false}) {
    var patternId = clip.patternId;
    if (!linked) {
      final original = project.module(patternId);
      if (original == null) return;
      final copy = ModuleDoc(id: newId('m'), name: '${original.name} copy',
          source: original.source, runSource: original.runSource, params: Map.of(original.params));
      project.modules.add(copy);
      patternId = copy.id;
    }
    final next = ClipDoc(id: newId('c'), patternId: patternId,
        startSteps: clip.startSteps + clip.lengthSteps, lengthSteps: clip.lengthSteps,
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, linked: linked);
    editLayer(layer, (l) => l.clips.add(next));
    selectClip(layer, next);
  }

  void moveClip(LayerDoc layer, ClipDoc clip, int startSteps) {
    editLayer(layer, (l) => clip.startSteps = startSteps.clamp(0, 4096 - clip.lengthSteps));
  }

  void resizeClip(LayerDoc layer, ClipDoc clip, int lengthSteps) {
    editLayer(layer, (l) => clip.lengthSteps = lengthSteps.clamp(1, 4096 - clip.startSteps));
  }

  void shiftClipSource(LayerDoc layer, ClipDoc clip, int deltaSteps) {
    editLayer(layer, (l) => clip.sourceOffsetSteps = (clip.sourceOffsetSteps + deltaSteps).clamp(0, 4096));
  }

  void removeClip(LayerDoc layer, ClipDoc clip) {
    editLayer(layer, (l) => l.clips.remove(clip));
    selectedClipIds.remove(clip.id);
    if (selectedClipId == clip.id) {
      selectedClipId = null;
      selectedModuleId = null;
      notifyListeners();
    }
  }

  void addFolder({String? parentId}) {
    final folder = LayerDoc(id: newId('l'), name: 'Group', color: project.layers.length % 4,
        parentId: parentId, isFolder: true, busEnabled: true);
    project.layers.add(folder);
    selectedLayerId = folder.id;
    _changed();
  }

  // ---------- project settings and files ----------

  void editProject(void Function(ProjectDoc) change) {
    change(project);
    _changed();
  }

  Future<List<ProjectSummary>> listProjects() async => await _storage?.list() ?? const [];

  Future<void> _switchTo(ProjectDoc p, {bool saveCurrent = true}) async {
    if (saveCurrent) await flush();
    engine?.stop();
    project = p;
    info = {};
    blankKinds.clear();
    selectedModuleId = p.modules.isEmpty ? null : p.modules.first.id;
    previewOnly = false;
    await _storage?.setLastOpened(p.id);
    await flush();
    notifyListeners();
    await _syncNow();
  }

  Future<void> newProject() => _switchTo(blankProject());

  Future<void> newProjectFromTemplate() => _switchTo(starterProject());

  Future<void> openProject(String id) async {
    final p = await _storage?.load(id);
    if (p != null) await _switchTo(p);
  }

  Future<void> duplicateProject() async {
    final copy = ProjectDoc.fromJson(project.toJson()..['id'] = newId('p'));
    copy.name = '${project.name} copy';
    await _switchTo(copy);
  }

  Future<void> deleteProject(String id) async {
    await _storage?.delete(id);
    if (id == project.id) {
      final rest = await listProjects();
      final next = rest.isEmpty ? null : await _storage?.load(rest.first.id);
      await _switchTo(next ?? starterProject());
    }
  }
}
