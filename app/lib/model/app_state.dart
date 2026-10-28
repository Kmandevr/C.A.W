// App state: settings, the startup choice, the open project, engine sync, autosave, meters and every edit.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';
import 'project.dart';
import 'settings.dart';
import 'storage.dart';

/// What the startup screen offers: the last project (if it still exists) and every saved project.
({ProjectSummary? last, List<ProjectSummary> projects}) startupChoices(String? lastId, List<ProjectSummary> projects) =>
    (last: projects.where((p) => p.id == lastId).firstOrNull, projects: projects);

class AppState extends ChangeNotifier {
  AppState({Settings? settings}) : settings = settings ?? Settings();

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
  EngineMeters meters = const EngineMeters();
  List<LayerMeterValue> layerMeters = const [];

  Timer? _saveTimer;
  Timer? _syncTimer;
  Ticker? _ticker;
  Duration _lastPoll = Duration.zero;

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
    _ticker = Ticker(_poll)..start();
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
    _ticker?.dispose();
    _saveTimer?.cancel();
    _syncTimer?.cancel();
    engine?.dispose();
    super.dispose();
  }

  void _poll(Duration elapsed) {
    if (elapsed - _lastPoll < const Duration(milliseconds: 33)) return;
    _lastPoll = elapsed;
    final e = engine;
    if (e == null) return;
    final before = meters;
    meters = e.meters();
    layerMeters = [for (var i = 0; i < project.layers.length; i++) e.layerMeter(i)];
    tick.value++;
    if (before.playing != meters.playing || before.overloaded != meters.overloaded) notifyListeners();
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
    final json = project.toEngineJson(audition: pv?.chain, auditionPattern: pv?.pattern, auditionOnly: previewOnly);
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
    notifyListeners();
  }

  void clearOverload() {
    engine?.clearOverload();
    notifyListeners();
  }

  /// Called when the app goes to the background or returns.
  void lifecycle({required bool foreground}) {
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
    m.source = source;
    _changed(engine: false);
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
    _changed(engine: false);
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
    _changed(engine: false);
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
    project.layers.remove(l);
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
    _changed(engine: false);
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
