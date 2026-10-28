// App state: the open project, engine sync, autosave, meters polling and every edit the screens make.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';
import 'project.dart';
import 'storage.dart';

class AppState extends ChangeNotifier {
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
    final last = await _storage!.lastOpened();
    final loaded = last == null ? null : await _storage!.load(last);
    project = loaded ?? starterProject();
    selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
    ready = true;
    notifyListeners();
    await _storage!.setLastOpened(project.id);
    await _syncNow();
    _ticker = Ticker(_poll)..start();
  }

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
    var c = 0;
    void layer(String name, ModuleDoc? gen, int steps, double vol, [List<ModuleDoc?> fx = const []]) {
      if (gen == null) return;
      p.layers.add(LayerDoc(
          id: newId('l'),
          name: name,
          color: c++ % 4,
          generatorId: gen.id,
          effectIds: [for (final f in fx) if (f != null) f.id],
          lengthSteps: steps,
          volume: vol));
    }

    layer('Kick', kick, 16, 0.9);
    layer('Bass', bass, 16, 0.7);
    layer('Hats', hats, 16, 0.5);
    layer('Byte lead', byte, 48, 0.35, [crush]);
    return p;
  }

  // ---------- engine sync and saving ----------

  List<String>? get previewChain {
    final m = project.module(selectedModuleId);
    if (m == null) return null;
    if (!(info[m.id]?.isEffect ?? headerValue(m.runSource, 'kind') == 'effect')) return [m.id];
    String? gen;
    for (final l in project.layers) {
      if (l.effectIds.contains(m.id) && l.generatorId != null) gen = l.generatorId;
    }
    gen ??= project.modules
        .where((x) => !(info[x.id]?.isEffect ?? headerValue(x.runSource, 'kind') == 'effect'))
        .map((x) => x.id)
        .firstOrNull;
    return [?gen, m.id];
  }

  Future<void> _syncNow() async {
    final e = engine;
    if (e == null) return;
    final json = project.toEngineJson(audition: previewOnly ? previewChain : null, auditionOnly: previewOnly);
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

  String addModule(Template t) {
    final m = moduleFromTemplate(t);
    var name = m.name;
    var n = 2;
    while (project.modules.any((x) => x.name == name)) {
      name = '${m.name} ${n++}';
    }
    m.name = name;
    project.modules.add(m);
    selectedModuleId = m.id;
    _changed();
    return m.id;
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

  bool isEffect(String moduleId) {
    final m = project.module(moduleId);
    if (m == null) return false;
    return info[moduleId]?.isEffect ?? headerValue(m.runSource, 'kind') == 'effect';
  }

  // ---------- layers (Arranger) ----------

  void addLayer() {
    final gen = project.modules.where((m) => !isEffect(m.id)).firstOrNull;
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

  Future<void> _switchTo(ProjectDoc p) async {
    await flush();
    engine?.stop();
    project = p;
    info = {};
    selectedModuleId = p.modules.isEmpty ? null : p.modules.first.id;
    previewOnly = false;
    await _storage?.setLastOpened(p.id);
    await flush();
    notifyListeners();
    await _syncNow();
  }

  Future<void> newProject() => _switchTo(starterProject()..name = 'New loop');

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
