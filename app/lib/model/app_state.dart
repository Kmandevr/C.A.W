// App state: settings, the startup choice, the open project, engine sync, autosave, meters and every edit.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../engine/execution.dart';
import '../platform/resource_signals.dart';
import 'poller.dart';
import 'native_components.dart';
import 'project.dart';
import 'history.dart';
import 'pattern_doc.dart';
import 'settings.dart';
import 'storage.dart';

class _LibrarySnapshot {
  _LibrarySnapshot(ProjectDoc project)
      : folders = List.of(project.libraryFolders),
        searches = Map.of(project.savedLibrarySearches),
        moduleFolders = {for (final module in project.modules) module.id: module.folderPath},
        moduleTags = {for (final module in project.modules) module.id: List.of(module.tags)};

  final List<String> folders;
  final Map<String, String> searches;
  final Map<String, String> moduleFolders;
  final Map<String, List<String>> moduleTags;
}

class _AutomationSnapshot {
  _AutomationSnapshot(ProjectDoc project)
      : projectLanes = [for (final lane in project.automation)
          ProjectAutomationLaneDoc.fromJson(lane.toJson())],
        trackLanes = {for (final layer in project.layers) layer.id: [
          for (final lane in layer.automation) AutomationLaneDoc.fromJson(lane.toJson()),
        ]};

  final List<ProjectAutomationLaneDoc> projectLanes;
  final Map<String, List<AutomationLaneDoc>> trackLanes;
}

class AppState extends ChangeNotifier {
  AppState({Settings? settings}) : settings = settings ?? Settings() {
    _light = this.settings.lightMode;
    _performanceMode = this.settings.performanceMode;
    _density = this.settings.density;
    _lookRevision = this.settings.lookRevision;
    this.settings.addListener(_settingsChanged);
  }

  late bool _light;
  late PerformanceMode _performanceMode;
  late Density _density;
  late int _lookRevision;

  // Lightweight/Minimal change the engine's voice budget; UI meter cadence stays fixed.
  void _settingsChanged() {
    final nextMode = settings.performanceMode;
    final nextDensity = settings.density;
    final nextLook = settings.lookRevision;
    final modeChanged = nextMode != _performanceMode;
    if (!modeChanged && nextDensity == _density && nextLook == _lookRevision) return;
    final voiceBudgetChanged = settings.lightMode != _light;
    _performanceMode = nextMode;
    _density = nextDensity;
    _lookRevision = nextLook;
    _light = settings.lightMode;
    // Visual profiles never lower meter cadence; editing and meter feedback stay at 30 Hz.
    if (voiceBudgetChanged) _sync();
    notifyListeners();
  }

  /// App-wide settings (theme, density, live coding).
  final Settings settings;

  Engine? engine;
  /// The project's C++ effects: the in-app build and trust rules (null without an in-app compiler).
  NativeComponentManager? nativeComponents;
  NativeComponentsStatus? nativeStatus;
  EngineHardwareProfile? hardwareProfile;
  EngineExecutionPlan? auditionPlan;
  StreamSubscription<EnginePressure>? _resourcePressureSubscription;
  bool _disposed = false;
  final Map<String, String> _lastGoodRunSources = {};
  String? engineError;
  String? audioError;

  /// Why the last project didn't open on launch (the template opened instead); cleared by opening another.
  String? openError;
  ProjectStorage? _storage;
  List<Template> templates = const [];

  ProjectDoc project = ProjectDoc(id: newId('p'), name: 'Untitled');
  Map<String, ModuleInfo> info = {};
  String? selectedModuleId;
  final List<_LibrarySnapshot> _libraryUndo = [];
  final List<_LibrarySnapshot> _libraryRedo = [];
  final List<_AutomationSnapshot> _automationUndo = [];
  final List<_AutomationSnapshot> _automationRedo = [];

  bool get canUndoLibrary => _libraryUndo.isNotEmpty;

  // Shared tap history keeps the toolbar and keyboard action on the same tempo measurement.
  final List<DateTime> _tempoTaps = [];
  int get tempoTapCount => _tempoTaps.length;
  bool get canRedoLibrary => _libraryRedo.isNotEmpty;

  void _recordLibraryUndo() {
    _libraryUndo.add(_LibrarySnapshot(project));
    if (_libraryUndo.length > 50) _libraryUndo.removeAt(0);
    _libraryRedo.clear();
  }

  void _restoreLibrarySnapshot(_LibrarySnapshot snapshot) {
    project.libraryFolders = List.of(snapshot.folders);
    project.savedLibrarySearches = Map.of(snapshot.searches);
    for (final module in project.modules) {
      final folder = snapshot.moduleFolders[module.id];
      if (folder != null) module.folderPath = folder;
      final tags = snapshot.moduleTags[module.id];
      if (tags != null) module.tags = List.of(tags);
    }
  }

  bool undoLibraryOperation() {
    if (_libraryUndo.isEmpty) return false;
    _libraryRedo.add(_LibrarySnapshot(project));
    _restoreLibrarySnapshot(_libraryUndo.removeLast());
    _changed(engine: false);
    return true;
  }

  bool redoLibraryOperation() {
    if (_libraryRedo.isEmpty) return false;
    _libraryUndo.add(_LibrarySnapshot(project));
    _restoreLibrarySnapshot(_libraryRedo.removeLast());
    _changed(engine: false);
    return true;
  }
  String? selectedLayerId;
  String? selectedClipId;
  final Set<String> selectedClipIds = {};
  int? timeSelectionStart, timeSelectionEnd, timeSelectionAnchor;
  int arrangementSnapSteps = 1;
  bool previewOnly = false;
  bool ready = false;

  /// True until the first project opens (the last one, or the template on a first run); nothing is saved before.
  bool starting = true;
  String? lastProjectId;
  List<ProjectSummary> savedProjects = const [];

  /// The kind picked for a blank new module, so the editor can hint until the file has a header (not saved).
  final Map<String, String> blankKinds = {};

  /// Bumped on every meter poll (about 30 times a second) so meters can repaint without rebuilding screens.
  final ValueNotifier<int> tick = ValueNotifier(0);

  /// Aggregate value tick retained for diagnostics and external listeners. Workspaces use the scoped ticks below
  /// so parameter, track and master drags don't rebuild unrelated controls.
  final ValueNotifier<int> values = ValueNotifier(0);
  final ValueNotifier<int> masterValueTick = ValueNotifier(0);
  final Map<String, ValueNotifier<int>> _moduleValueTicks = {};
  final Map<String, ValueNotifier<int>> _layerValueTicks = {};
  ValueNotifier<int> moduleValueTick(String id) => _moduleValueTicks.putIfAbsent(id, () => ValueNotifier(0));
  ValueNotifier<int> layerValueTick(String id) => _layerValueTicks.putIfAbsent(id, () => ValueNotifier(0));
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
      interval: const Duration(milliseconds: 33),
      onIdle: () {
    if (!meters.playing && _heldPreviews.isEmpty) engine?.stopAudio();
  });

  Future<void> init() async {
    _resourcePressureSubscription = ResourceSignals.changes.listen(
      (pressure) => EngineExecutionPolicy.updateRuntimeSignals(pressure: pressure),
      onError: (Object _) => EngineExecutionPolicy.updateRuntimeSignals(pressure: EnginePressure.unknown),
    );
    EngineExecutionPolicy.updateRuntimeSignals(pressure: await ResourceSignals.read());
    try {
      engine = Engine.create();
      hardwareProfile = EngineExecutionPolicy.hardwareProfile;
      auditionPlan = EngineExecutionPolicy.plan(workload: EngineWorkload.interactiveAudition);
      templates = Engine.templates();
      audioError = engine!.startAudio();
    } catch (e) {
      engineError = 'The sound engine did not load: $e';
    }
    try {
      await openStorage(await ProjectStorage.open());
    } catch (e) {
      // Never stuck on the logo: show the app with whatever opened, and say why.
      openError = 'Projects could not be opened: $e';
      starting = false;
    } finally {
      ready = true;
      notifyListeners();
      _poller.wake();
    }
  }

  /// Reads the saved projects from [storage] and opens straight into the last one: the arrangement is home (UI
  /// plan U1). On a first run, or when the last project is gone, it opens the "First loop" template. New, Template
  /// and Open are in the project menu.
  Future<void> openStorage(ProjectStorage storage) async {
    _storage = storage;
    final e = engine;
    if (e != null) {
      try {
        nativeComponents = await deviceNativeComponentManager(e, storage);
      } catch (_) {
        nativeComponents = null;  // no compiler on this device: projects play without their C++ effects
      }
    }
    lastProjectId = await storage.lastOpened();
    savedProjects = await listProjects();
    final id = lastProjectId;
    final last = id == null ? null : await storage.load(id);
    // A damaged file reads as null too; it stays on disk, and the app says so instead of replacing it silently.
    final damaged = id != null && last == null && await storage.has(id);
    starting = false;
    String? error = damaged ? 'The last project could not be read, so the First loop template opened instead. '
        'Its file is still in the projects folder.' : null;
    try {
      await _switchTo(last ?? starterProject(), saveCurrent: false);
    } catch (e) {
      if (last == null) rethrow;
      error = 'The last project, "${last.name}", could not be opened ($e), so the First loop template opened instead.';
      await _switchTo(starterProject(), saveCurrent: false);
    }
    openError = error;
  }

  /// An empty project: no modules and no layers.
  ProjectDoc blankProject() => ProjectDoc(id: newId('p'), name: 'New project');

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_settingsChanged);
    final pressureSubscription = _resourcePressureSubscription;
    _resourcePressureSubscription = null;
    if (pressureSubscription != null) unawaited(pressureSubscription.cancel());
    _poller.dispose();
    _liveTimer?.cancel();
    _saveTimer?.cancel();
    _syncTimer?.cancel();
    _historyTimer?.cancel();
    masterValueTick.dispose();
    values.dispose();
    tick.dispose();
    for (final notifier in _moduleValueTicks.values) { notifier.dispose(); }
    for (final notifier in _layerValueTicks.values) { notifier.dispose(); }
    engine?.dispose();
    super.dispose();
  }

  /// One meter read; returns whether anything is still moving.
  bool _poll() {
    final e = engine;
    if (e == null) return false;
    final before = meters;
    meters = e.meters();
    if (before.playing != meters.playing) {
      EngineExecutionPolicy.updateRuntimeSignals(audioActive: meters.playing);
    }
    layerMeters = [for (var i = 0; i < project.layers.length; i++) e.layerMeter(i)];
    tick.value++;
    if (meters.overloaded > before.overloaded && settings.lightAuto && !settings.lightMode) {
      // The device can't keep up: Lightweight turns on by itself once (the user can choose another profile).
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
      final patternDoc = pattern == null ? null : PatternDoc.parse(pattern.runSource).doc;
      final clipLength = patternDoc?.lengthSteps(p.beatsPerBar) ?? (steps > 0 ? steps : p.stepsPerBar);
      p.layers.add(LayerDoc(
          id: newId('l'),
          name: name,
          color: c++ % 4,
          generatorId: gen.id,
          effectIds: [for (final f in fx) if (f != null) f.id],
          clips: pattern == null ? [] : [
            ClipDoc(id: newId('c'), patternId: pattern.id, lengthSteps: clipLength),
          ],
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

  /// The layer a pattern's note previews play on: the selected layer if it plays [patternId], else the first that
  /// does; null when no layer plays it.
  String? previewLayerFor(String patternId) {
    bool plays(LayerDoc l) => l.generatorId != null && (l.patternId == patternId || l.clips.any((c) => c.patternId == patternId));
    final selected = project.layers.where((l) => l.id == selectedLayerId && plays(l)).firstOrNull;
    return (selected ?? project.layers.where(plays).firstOrNull)?.id;
  }

  int _previewIds = 0;

  /// A fresh note-preview id, unique across every roll on screen.
  int nextPreviewId() => ++_previewIds;

  final Set<int> _heldPreviews = {};

  /// Note previews on the engine (tests override these to watch them). A preview reopens the audio device if it was
  /// closed while idle, and keeps it open while any note is held.
  void previewOn(String layerId, int id, double pitch, double velocity) {
    final e = engine;
    if (e == null) return;
    if (!e.audioOn) audioError = e.startAudio();
    e.noteOn(layerId, id, pitch, velocity);
    _heldPreviews.add(id);
    _poller.wake();
  }

  void previewPitch(int id, double pitch) => engine?.notePitch(id, pitch);

  void previewOff(int id) {
    final e = engine;
    if (e == null) return;
    e.noteOff(id);
    _heldPreviews.remove(id);
    if (_heldPreviews.isEmpty) {
      e.notesOff(); // a backstop: an off dropped by a full command queue can't leave a note stuck
      _poller.wake(); // the idle countdown starts again
    }
  }

  /// What Solo preview plays for the selected module: a generator alone, an effect after a generator that uses it,
  /// or a pattern through the sound of a layer that plays it. Each plays the pattern of its layer, if it has one.
  ({List<String> chain, String? pattern})? get preview {
    final m = project.module(selectedModuleId);
    if (m == null || isLibrary(m.id)) return null;
    String? firstGenerator() => project.modules.where((x) => isGenerator(x.id)).map((x) => x.id).firstOrNull;
    if (isPattern(m.id)) {
      final layer = project.layers.where((l) => l.clips.any((clip) => clip.patternId == m.id) && l.generatorId != null).firstOrNull;
      final gen = layer?.generatorId ?? firstGenerator();
      return gen == null ? null : (chain: layer?.chain ?? [gen], pattern: m.id);
    }
    if (!isEffect(m.id)) {
      final layer = project.layers.where((l) => l.generatorId == m.id).firstOrNull;
      return (chain: [m.id], pattern: layer?.clips.firstOrNull?.patternId ?? layer?.patternId);
    }
    final layer = project.layers.where((l) => l.effectIds.contains(m.id) && l.generatorId != null).lastOrNull;
    final gen = layer?.generatorId ?? firstGenerator();
    return (chain: [?gen, m.id], pattern: layer?.clips.firstOrNull?.patternId ?? layer?.patternId);
  }

  Future<void> _syncNow() async {
    final e = engine;
    if (e == null) return;
    final pv = previewOnly ? preview : null;
    final json = project.toEngineJson(
        audition: pv?.chain,
        auditionPattern: pv?.pattern,
        auditionOnly: previewOnly,
        voices: settings.lightMode ? 4 : 32, // global cap; each generator chooses its own voice count
        swap: settings.swapTiming.name,
        playableComponents: nativeComponents?.loaded);
    try {
      info = await e.setProject(json);
      engineError = null;
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
    _recordHistory();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), flush);
  }

  // ---------- undo and redo (the whole project) ----------

  /// Every project edit saves, so every edit lands here: a burst of edits, until a 600 ms pause, is one step.
  final ProjectHistory history = ProjectHistory();
  Timer? _historyTimer;
  bool _restoring = false;

  String _snapshot() => jsonEncode(project.toJson());

  void _recordHistory() {
    if (starting || _restoring) return;
    final could = (history.canUndo, history.canRedo);
    history.begin();
    // Drags save without notifying (so they stay light); the transport's buttons still need to see a flip.
    if ((history.canUndo, history.canRedo) != could) notifyListeners();
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 600), () {
      final was = (history.canUndo, history.canRedo);
      history.settle(_snapshot());
      if ((history.canUndo, history.canRedo) != was) notifyListeners();
    });
  }

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;

  /// Goes back one step of project edits (the transport's undo, Ctrl+Z outside an editor with its own).
  bool undo() => _restore(history.undo(_snapshot()));

  bool redo() => _restore(history.redo(_snapshot()));

  bool _restore(String? snapshot) {
    _historyTimer?.cancel();
    if (snapshot == null) return false;
    _restoring = true;
    try {
      project = ProjectDoc.fromJson(jsonDecode(snapshot) as Map<String, dynamic>);
      // The other undo stacks and the last good Run sources describe the project before the restore.
      _lastGoodRunSources.clear();
      _libraryUndo.clear();
      _libraryRedo.clear();
      _automationUndo.clear();
      _automationRedo.clear();
      masterValueTick.value++;
      // Ticks of modules and layers the restore removed are dropped (left to their widgets, which go with them).
      _moduleValueTicks.removeWhere((id, _) => project.module(id) == null);
      _layerValueTicks.removeWhere((id, _) => project.layers.every((l) => l.id != id));
      for (final n in _moduleValueTicks.values) { n.value++; }
      for (final n in _layerValueTicks.values) { n.value++; }
      timeSelectionStart = timeSelectionEnd = timeSelectionAnchor = null;
      previewOnly = false;
      if (project.layers.every((l) => l.id != selectedLayerId)) selectedLayerId = null;
      if (project.module(selectedModuleId) == null) {
        selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
      }
      selectedClipId = null;
      selectedClipIds.clear();
      _changed();
    } finally {
      _restoring = false;
    }
    return true;
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    if (starting) return; // the placeholder before the first project opens is never saved
    // Native effects' running state (save_state) goes into the project, so a reload or an export starts from it.
    final e = engine;
    if (e != null) project.storeComponentStates(e.componentStates);
    await _storage?.save(project);
  }

  Future<bool> createRestorePoint() async {
    final storage = _storage;
    if (storage == null || starting) return false;
    await flush();
    await storage.createRestorePoint(project);
    return true;
  }

  Future<List<RestorePointSummary>> listRestorePoints() async =>
      await _storage?.listRestorePoints(project.id) ?? const [];

  Future<bool> restoreProjectVersion(String restorePointId) async {
    final storage = _storage;
    if (storage == null || starting) return false;
    final snapshot = await storage.loadRestorePoint(project.id, restorePointId);
    if (snapshot == null) return false;
    await storage.createRestorePoint(project);
    await _switchTo(snapshot);
    return true;
  }


  void _changed({bool engine = true}) {
    if (engine) _sync();
    _save();
    notifyListeners();
  }

  // ---------- transport ----------

  /// Records a tempo tap; pauses over two seconds restart the measurement.
  /// [at] is injectable for deterministic tests.
  void tapTempo({DateTime? at}) {
    final now = at ?? DateTime.now();
    if (_tempoTaps.isNotEmpty && now.difference(_tempoTaps.last) > const Duration(seconds: 2)) {
      _tempoTaps.clear();
    }
    if (_tempoTaps.isNotEmpty && !now.isAfter(_tempoTaps.last)) return;
    _tempoTaps.add(now);
    if (_tempoTaps.length > 5) _tempoTaps.removeAt(0);
    if (_tempoTaps.length >= 2) {
      final elapsed = now.difference(_tempoTaps.first).inMicroseconds;
      final intervals = _tempoTaps.length - 1;
      if (elapsed > 0) {
        final bpm = (60000000.0 * intervals / elapsed).clamp(20.0, 400.0);
        editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
        return;
      }
    }
    notifyListeners();
  }

  /// Where a pause left the transport, in sixteenth steps of the engine's loop (so a tempo change while paused still
  /// resumes on the same beat); null when stopped at the start.
  double? pausedStep;

  /// Whether the transport was last told to play. Play and stop reach the engine at its next audio block, so the
  /// meters lag; Space and Stop go by this, so a quick second press still pauses or stops.
  bool get transportOn => _transportOn;
  bool _transportOn = false;

  /// Off in tests that play the engine with no sound card (they pull its audio themselves).
  @visibleForTesting
  bool useAudioDevice = true;

  /// Play and pause (Space, the transport's play button): a pause keeps the position and the next play resumes there.
  void togglePlay() {
    final e = engine;
    if (e == null) return;
    if (_transportOn) {
      // Read now: the stop's short fade still moves the transport on.
      final m = e.meters();
      pausedStep = m.loopLength > 0 ? m.position * project.engineLoopSteps / m.loopLength : null;
      e.stop();
      _transportOn = false;
    } else {
      if (useAudioDevice && !e.audioOn) {
        audioError = e.startAudio();
        if (audioError != null) return notifyListeners(); // no sound card: the pause stays where it was
      }
      final from = pausedStep;
      from == null ? e.play() : e.playAt(from);
      pausedStep = null;
      _transportOn = true;
    }
    meters = e.meters();
    _poller.wake();
    notifyListeners();
  }

  /// Stop (Shift+Space, the transport's stop button): the next play starts from the beginning.
  void stopPlayback() {
    final e = engine;
    pausedStep = null;
    _transportOn = false;
    if (e != null) {
      e.stop(); // the engine ignores a stop when it isn't playing
      meters = e.meters();
      _poller.wake();
    }
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

  /// Selects a channel for shared workspace inspectors without changing its processing state.
  void selectLayer(LayerDoc layer) {
    selectedLayerId = layer.id;
    selectedClipId = null;
    selectedClipIds.clear();
    selectedModuleId = layer.generatorId ?? layer.effectIds.firstOrNull;
    if (previewOnly && selectedModuleId != null) _sync();
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
    _liveTimer = Timer(Duration(milliseconds: settings.liveDelayMs), () async {
      final m = project.module(id);
      if (_disposed || m == null || !m.edited || (settings.lightMode && meters.playing)) return;
      // The project compile is the check; avoid compiling the same source twice.
      await run(id);
    });
  }

  /// Run: hot-swap valid code; on failure keep the last good engine source and expose the module error.
  Future<ModuleInfo?> run(String id) async {
    final m = project.module(id);
    if (m == null || engine == null) return null;
    final source = m.source;
    final key = '${project.id}:$id';
    final lastGoodSource = _lastGoodRunSources[key] ?? m.runSource;
    m.runSource = source;
    _syncTimer?.cancel();
    await _syncNow();

    final result = info[id];
    final current = project.module(id);
    if (engineError == null && result?.ok == true) {
      _lastGoodRunSources[key] = source;
      if (current != null && current.source == source) {
        final name = headerValue(source, 'name');
        if (name != null && name.isNotEmpty) current.name = name;
      }
    } else if (current != null && current.runSource == source) {
      // Keep invalid editor text pending while the engine continues with the previous good source.
      current.runSource = lastGoodSource;
    }
    _save();
    notifyListeners();
    return result;
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

  String _normalizeLibraryPath(String path) {
    if (path.length > 512) throw ArgumentError.value(path, 'path', 'Folder path is too long.');
    final parts = path.split('/').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
    if (parts.length > 32 || parts.any((part) => part == '.' || part == '..' || part.length > 64 || part.contains(String.fromCharCode(92)))) {
      throw ArgumentError.value(path, 'path', 'Folder paths cannot contain traversal segments.');
    }
    return parts.join('/');
  }

  /// Creates a user-named virtual library folder and any missing parents.
  bool createLibraryFolder(String path) {
    final normalized = _normalizeLibraryPath(path);
    if (normalized.isEmpty) return false;
    final parts = normalized.split('/');
    if (parts.asMap().entries.every((entry) => project.libraryFolders.contains(parts.take(entry.key + 1).join('/')))) {
      return false;
    }
    _recordLibraryUndo();
    var changed = false;
    for (var i = 1; i <= parts.length; i++) {
      final parent = parts.take(i).join('/');
      if (!project.libraryFolders.contains(parent)) {
        project.libraryFolders.add(parent);
        changed = true;
      }
    }
    if (changed) {
      project.libraryFolders.sort();
      _changed(engine: false);
    }
    return changed;
  }

  /// Renames a folder and all descendants without moving or deleting their modules.
  bool renameLibraryFolder(String oldPath, String newPath) {
    final oldValue = _normalizeLibraryPath(oldPath);
    final newValue = _normalizeLibraryPath(newPath);
    if (oldValue.isEmpty || newValue.isEmpty || !project.libraryFolders.contains(oldValue)) return false;
    if (oldValue == newValue) return true;
    if (newValue.startsWith('$oldValue/') || project.libraryFolders.contains(newValue)) return false;
    _recordLibraryUndo();
    project.libraryFolders = project.libraryFolders.map((path) =>
      path == oldValue ? newValue : path.startsWith('$oldValue/') ? '$newValue${path.substring(oldValue.length)}' : path
    ).toSet().toList();
    final newParts = newValue.split('/');
    for (var i = 1; i < newParts.length; i++) {
      final parentPath = newParts.take(i).join('/');
      if (!project.libraryFolders.contains(parentPath)) project.libraryFolders.add(parentPath);
    }
    project.libraryFolders.sort();
    for (final module in project.modules) {
      if (module.folderPath == oldValue) {
        module.folderPath = newValue;
      } else if (module.folderPath.startsWith('$oldValue/')) {
        module.folderPath = '$newValue${module.folderPath.substring(oldValue.length)}';
      }
    }
    _changed(engine: false);
    return true;
  }

  /// Deletes a folder node and returns its modules/children to its parent folder.
  bool deleteLibraryFolder(String path) {
    final normalized = _normalizeLibraryPath(path);
    if (normalized.isEmpty || !project.libraryFolders.contains(normalized)) return false;
    final parent = normalized.contains('/') ? normalized.substring(0, normalized.lastIndexOf('/')) : '';
    _recordLibraryUndo();
    project.libraryFolders.removeWhere((folder) => folder == normalized || folder.startsWith('$normalized/'));
    for (final module in project.modules) {
      if (module.folderPath == normalized || module.folderPath.startsWith('$normalized/')) {
        module.folderPath = parent;
      }
    }
    _changed(engine: false);
    return true;
  }

  /// Moves a module into a user-owned library folder; an empty path means the project root.
  bool moveModuleToFolder(String moduleId, String folderPath) {
    final module = project.module(moduleId);
    if (module == null) return false;
    final normalized = _normalizeLibraryPath(folderPath);
    if (normalized.isNotEmpty && !project.libraryFolders.contains(normalized)) return false;
    if (module.folderPath == normalized) return true;
    _recordLibraryUndo();
    module.folderPath = normalized;
    _changed(engine: false);
    return true;
  }

  bool moveModulesToFolder(Iterable<String> moduleIds, String folderPath) {
    final normalized = _normalizeLibraryPath(folderPath);
    if (normalized.isNotEmpty && !project.libraryFolders.contains(normalized)) return false;
    final ids = moduleIds.toSet();
    final targets = project.modules.where((module) => ids.contains(module.id) && module.folderPath != normalized).toList();
    if (targets.isEmpty) return false;
    _recordLibraryUndo();
    var changed = false;
    for (final module in project.modules) {
      if (ids.contains(module.id) && module.folderPath != normalized) {
        module.folderPath = normalized;
        changed = true;
      }
    }
    if (changed) _changed(engine: false);
    return changed;
  }

  void setModuleTags(String moduleId, List<String> tags) => setModulesTags([moduleId], tags);

  /// Applies one tag set to multiple modules as a single undoable library operation.
  bool setModulesTags(Iterable<String> moduleIds, List<String> tags) {
    final ids = moduleIds.toSet();
    final seen = <String>{};
    final nextTags = [
      for (final raw in tags)
        if (raw.trim().isNotEmpty && raw.trim().length <= 48 && seen.add(raw.trim().toLowerCase()))
          raw.trim(),
    ].take(16).toList();
    final targets = project.modules.where((module) => ids.contains(module.id) &&
        !listEquals(module.tags, nextTags)).toList();
    if (targets.isEmpty) return false;
    _recordLibraryUndo();
    for (final module in targets) {
      module.tags = List.of(nextTags);
    }
    _changed(engine: false);
    return true;
  }

  bool saveLibrarySearch(String name, String query) {
    final key = name.trim();
    final value = query.trim();
    if (key.isEmpty || value.isEmpty || key.length > 64 || value.length > 256) return false;
    if (!project.savedLibrarySearches.containsKey(key) && project.savedLibrarySearches.length >= 32) return false;
    if (project.savedLibrarySearches[key] == value) return true;
    _recordLibraryUndo();
    project.savedLibrarySearches[key] = value;
    _changed(engine: false);
    return true;
  }

  void deleteLibrarySearch(String name) {
    if (!project.savedLibrarySearches.containsKey(name)) return;
    _recordLibraryUndo();
    project.savedLibrarySearches.remove(name);
    _changed(engine: false);
  }

  /// Imports an ordinary .caw module as a new project item; existing modules are never overwritten.
  String importModuleSource(String source, {String fileName = 'Imported.caw', String folderPath = ''}) {
    final folder = _normalizeLibraryPath(folderPath);
    if (folder.isNotEmpty && !project.libraryFolders.contains(folder)) createLibraryFolder(folder);
    final module = moduleFromTemplate(Template(fileName, source));
    module.name = _freeModuleName(module.name);
    module.folderPath = folder;
    project.modules.add(module);
    selectedModuleId = module.id;
    _changed();
    return module.id;
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
      l.clips.removeWhere((clip) => clip.patternId == id);
      l.effectIds.remove(id);
    }
    if (selectedModuleId == id) selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
    _pruneClipSelection();
    _changed();
  }

  void setParam(String moduleId, String name, double value) {
    final m = project.module(moduleId);
    if (m == null) return;
    m.params[name] = value;
    engine?.setParam(moduleId, name, value);
    _save();
    moduleValueTick(moduleId).value++;
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
    for (final module in project.modules) {
      if ((info[module.id]?.params ?? const <ParamInfo>[]).any((param) => param.global && param.name == name)) {
        moduleValueTick(module.id).value++;
      }
    }
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
    final emptyHint = m.source.isEmpty ? blankKinds[moduleId] : null;
    return info[moduleId]?.kind ?? headerValue(m.runSource, 'kind') ?? emptyHint ?? 'generator';
  }

  bool isEffect(String moduleId) => kindOf(moduleId) == 'effect';
  bool isLibrary(String moduleId) => kindOf(moduleId) == 'library';
  bool isPattern(String moduleId) => kindOf(moduleId) == 'pattern';
  /// A sound a track can play: a generator or a synth patch played as one instrument.
  bool isGenerator(String moduleId) => const {'generator', 'synth'}.contains(kindOf(moduleId));

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

  /// Sets the visual spacer under [layer] (0 removes it). The engine never sees it, so nothing is re-sent.
  void setSpaceBelow(LayerDoc layer, double px) {
    final v = px.isFinite ? px.clamp(0.0, LayerDoc.maxSpaceBelow).toDouble() : 0.0;
    if (v == layer.spaceBelow) return;
    layer.spaceBelow = v;
    _changed(engine: false);
  }

  void setFolderCollapsed(LayerDoc folder, bool collapsed) {
    if (!folder.isFolder) return;
    editLayer(folder, (l) => l.collapsed = collapsed);
  }

  void addAutomationLane(LayerDoc layer, String target) {
    if (target != 'volume' && target != 'pan') return;
    if (layer.automation.any((a) => a.target == target)) return;
    _pushAutomationUndo();
    final end = project.arrangementEndSteps.clamp(1, project.maxArrangementSteps).toInt();
    editLayer(layer, (l) => l.automation.add(AutomationLaneDoc(target: target,
      points: [AutomationPointDoc(step: 0, value: target == 'volume' ? l.volume : l.pan),
        AutomationPointDoc(step: end.toDouble(), value: target == 'volume' ? l.volume : l.pan)])));
  }

  bool _automationGestureOpen = false;

  void beginAutomationGesture() {
    if (_automationGestureOpen) return;
    _pushAutomationUndo();
    _automationGestureOpen = true;
  }

  void endAutomationGesture() => _automationGestureOpen = false;

  void _pushAutomationUndo() {
    if (_automationGestureOpen) return;
    _automationUndo.add(_AutomationSnapshot(project));
    if (_automationUndo.length > 64) _automationUndo.removeAt(0);
    _automationRedo.clear();
  }

  void _restoreAutomationSnapshot(_AutomationSnapshot snapshot) {
    project.automation = snapshot.projectLanes;
    for (final layer in project.layers) {
      layer.automation = snapshot.trackLanes[layer.id] ?? [];
    }
  }

  bool get canUndoAutomation => _automationUndo.isNotEmpty;
  bool get canRedoAutomation => _automationRedo.isNotEmpty;

  bool undoAutomation() {
    if (_automationUndo.isEmpty) return false;
    _automationRedo.add(_AutomationSnapshot(project));
    _restoreAutomationSnapshot(_automationUndo.removeLast());
    _changed();
    return true;
  }

  bool redoAutomation() {
    if (_automationRedo.isEmpty) return false;
    _automationUndo.add(_AutomationSnapshot(project));
    _restoreAutomationSnapshot(_automationRedo.removeLast());
    _changed();
    return true;
  }

  void addProjectAutomationLane(String targetType, String target, [String? moduleId]) {
    if (target.isEmpty) return;
    if (targetType != 'global' && targetType != 'param') return;
    if (targetType == 'param' && (moduleId == null || moduleId.isEmpty)) return;
    if (project.automation.any((lane) => lane.targetType == targetType &&
        lane.target == target && lane.moduleId == moduleId)) {
      return;
    }
    _pushAutomationUndo();
    final end = project.layers.fold<int>(project.loopSteps, (value, layer) =>
      layer.clips.fold<int>(value, (current, clip) =>
        current > clip.startSteps + clip.lengthSteps ? current : clip.startSteps + clip.lengthSteps)).toDouble();
    final definition = targetType == 'global'
        ? info.values.expand((module) => module.params).where((param) => param.global && param.name == target).firstOrNull
        : info[moduleId]?.params.where((param) => param.name == target).firstOrNull;
    final value = targetType == 'global'
        ? (project.globals[target] ?? definition?.defaultValue ?? 0.0)
        : (project.module(moduleId)?.params[target] ?? definition?.defaultValue ?? 0.0);
    project.automation.add(ProjectAutomationLaneDoc(targetType: targetType, target: target,
      moduleId: moduleId, points: [AutomationPointDoc(step: 0, value: value),
        AutomationPointDoc(step: end, value: value)]));
    _changed();
  }

  void updateProjectAutomationPoint(ProjectAutomationLaneDoc lane, int index, double step, double value) {
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    final point = lane.points[index];
    final ordered = [...lane.points]..sort((a, b) => a.step.compareTo(b.step));
    final position = ordered.indexOf(point);
    final lower = position > 0 ? ordered[position - 1].step + 0.01 : 0.0;
    final upper = position < ordered.length - 1
        ? ordered[position + 1].step - 0.01 : project.maxArrangementSteps.toDouble();
    point.step = step.clamp(lower, math.max(lower, upper)).toDouble();
    point.value = value.clamp(-1000000.0, 1000000.0).toDouble();
    _changed();
  }

  void addProjectAutomationPoint(ProjectAutomationLaneDoc lane, double step, double value) {
    _pushAutomationUndo();
    final at = step.clamp(0.0, project.maxArrangementSteps.toDouble()).toDouble();
    if (lane.points.any((point) => (point.step - at).abs() < 0.01)) return;
    lane.points.add(AutomationPointDoc(step: at, value: value));
    lane.points.sort((a, b) => a.step.compareTo(b.step));
    _changed();
  }

  void removeProjectAutomationPoint(ProjectAutomationLaneDoc lane, int index) {
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    lane.points.removeAt(index);
    _changed();
  }

  void removeProjectAutomationLane(ProjectAutomationLaneDoc lane) {
    _pushAutomationUndo();
    project.automation.remove(lane);
    _changed();
  }

  void removeAutomationLane(LayerDoc layer, AutomationLaneDoc lane) {
    _pushAutomationUndo();
    editLayer(layer, (l) => l.automation.remove(lane));
  }

  void removeAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, int index) {
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    editLayer(layer, (l) {
      l.automation.firstWhere((a) => a.target == lane.target).points.removeAt(index);
    });
  }

  void updateAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, int index, double step, double value) {
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    editLayer(layer, (l) {
      final p = lane.points[index];
      final sorted = [...lane.points]..sort((a, b) => a.step.compareTo(b.step));
      final position = sorted.indexOf(p);
      final lower = position > 0 ? sorted[position - 1].step + 0.01 : 0.0;
      final upper = position >= 0 && position < sorted.length - 1 ? sorted[position + 1].step - 0.01 : project.maxArrangementSteps.toDouble();
      p.step = step.clamp(lower, math.min(upper, project.maxArrangementSteps.toDouble())).toDouble();
      p.value = value.clamp(lane.target == 'volume' ? 0.0 : -1.0, 1.0).toDouble();
      // Clamp to neighboring points instead of reordering during a drag; the dragged handle stays stable.
    });
  }

  void addAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, double step, double value) {
    _pushAutomationUndo();
    final at = step.clamp(0, project.maxArrangementSteps.toDouble()).toDouble();
    if (lane.points.any((p) => (p.step - at).abs() < 0.01)) return;
    editLayer(layer, (l) {
      l.automation.firstWhere((a) => a.target == lane.target).points.add(
        AutomationPointDoc(step: at,
          value: value.clamp(lane.target == 'volume' ? 0.0 : -1.0, 1.0).toDouble()));
      l.automation.firstWhere((a) => a.target == lane.target).points.sort((a, b) => a.step.compareTo(b.step));
    });
  }

  void beginTimeSelection(int step) {
    timeSelectionAnchor = step.clamp(0, project.maxArrangementSteps).toInt();
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
    timeSelectionStart = start.clamp(0, project.maxArrangementSteps).toInt();
    timeSelectionEnd = end.clamp(0, project.maxArrangementSteps).toInt();
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


  /// Adds a track using [soundId], the first available sound, or no sound when [empty] is true.
  void addLayer({String? soundId, bool empty = false}) {
    final gen = empty ? null : project.module(soundId) ?? project.modules.where((m) => isGenerator(m.id)).firstOrNull;
    project.layers.add(LayerDoc(
      id: newId('l'),
      name: gen?.name ?? 'Layer ${project.layers.length + 1}',
      color: project.layers.length % LayerDoc.trackColors,
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
    _pruneClipSelection();
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
  /// Master gain shares the same project/engine state but updates only value listeners during a drag.
  void setMaster(double value) {
    project.master = value.clamp(0.0, 1.0).toDouble();
    engine?.setMaster(project.master);
    _save();
    masterValueTick.value++;
    values.value++;
  }

  void mixLayer(LayerDoc l, {double? volume, double? pan, bool? mute, bool? solo}) {
    if (volume != null) l.volume = volume;
    if (pan != null) l.pan = pan;
    if (mute != null) l.mute = mute;
    if (solo != null) l.solo = solo;
    engine?.setLayerMix(l.id, l.volume, l.pan, l.mute, l.solo);
    // Volume and pan drags only redraw their sliders; mute and solo change how the whole layer list looks.
    if (mute == null && solo == null) {
      _save();
      layerValueTick(l.id).value++;
      values.value++;
    } else {
      _changed(engine: false);
    }
  }

  void _pruneClipSelection() {
    final valid = {for (final layer in project.layers) for (final clip in layer.clips) clip.id};
    selectedClipIds.removeWhere((id) => !valid.contains(id));
    if (selectedClipId == null || !selectedClipIds.contains(selectedClipId)) {
      if (selectedClipIds.isEmpty) {
        selectedClipId = null;
        selectedLayerId = null;
        if (selectedModuleId != null && !project.modules.any((m) => m.id == selectedModuleId)) {
          selectedModuleId = project.modules.firstOrNull?.id;
        }
      } else {
        for (final layer in project.layers) {
          final clip = layer.clips.where((c) => selectedClipIds.contains(c.id)).firstOrNull;
          if (clip == null) continue;
          selectedLayerId = layer.id;
          selectedClipId = clip.id;
          selectedModuleId = clip.patternId;
          break;
        }
      }
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
    final requestedStart = startSteps ?? end;
    if (requestedStart >= project.maxArrangementSteps) return;
    final at = requestedStart.clamp(0, project.maxArrangementSteps - 1).toInt();
    final clip = ClipDoc(id: newId('c'), patternId: patternId,
        startSteps: at, lengthSteps: length.clamp(1, project.maxArrangementSteps - at).toInt());
    editLayer(layer, (l) => l.clips.add(clip));
    selectClip(layer, clip);
  }

  void duplicateClip(LayerDoc layer, ClipDoc clip, {bool linked = false}) {
    final start = clip.startSteps + clip.lengthSteps;
    if (start >= project.maxArrangementSteps) return;
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
        startSteps: start, lengthSteps: clip.lengthSteps.clamp(1, project.maxArrangementSteps - start).toInt(),
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, linked: linked);
    editLayer(layer, (l) => l.clips.add(next));
    selectClip(layer, next);
  }

  void moveClip(LayerDoc layer, ClipDoc clip, int startSteps) {
    editLayer(layer, (l) => clip.startSteps = startSteps.clamp(0, project.maxArrangementSteps - clip.lengthSteps).toInt());
  }

  void resizeClip(LayerDoc layer, ClipDoc clip, int lengthSteps) {
    editLayer(layer, (l) => clip.lengthSteps = lengthSteps.clamp(1, project.maxArrangementSteps - clip.startSteps).toInt());
  }

  void shiftClipSource(LayerDoc layer, ClipDoc clip, int deltaSteps) {
    editLayer(layer, (l) => clip.sourceOffsetSteps = (clip.sourceOffsetSteps + deltaSteps).clamp(0, project.maxArrangementSteps).toInt());
  }

  void removeClip(LayerDoc layer, ClipDoc clip) {
    editLayer(layer, (l) => l.clips.remove(clip));
    selectedClipIds.remove(clip.id);
    _pruneClipSelection();
    notifyListeners();
  }

  void addFolder({String? parentId}) {
    final folder = LayerDoc(id: newId('l'), name: 'Group', color: project.layers.length % LayerDoc.trackColors,
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
    pausedStep = null;
    _transportOn = false;
    _lastGoodRunSources.clear();
    _libraryUndo.clear();
    _libraryRedo.clear();
    _automationUndo.clear();
    _automationRedo.clear();
    for (final notifier in _moduleValueTicks.values) { notifier.dispose(); }
    for (final notifier in _layerValueTicks.values) { notifier.dispose(); }
    _moduleValueTicks.clear();
    _layerValueTicks.clear();
    project = p;
    openError = null;
    _historyTimer?.cancel();
    history.reset(_snapshot());
    masterValueTick.value++;
    info = {};
    blankKinds.clear();
    selectedModuleId = p.modules.isEmpty ? null : p.modules.first.id;
    selectedLayerId = null;
    selectedClipId = null;
    selectedClipIds.clear();
    clearTimeSelection();
    previewOnly = false;
    await _storage?.setLastOpened(p.id);
    await flush();
    notifyListeners();
    await _syncNow();
    unawaited(prepareNativeComponents());
  }

  /// Builds (or reuses a build of) and loads the project's C++ effects under the trust rules, then sends the
  /// project again so they play. Runs after the project opens, so the rest of it plays at once. Code from elsewhere
  /// waits in [nativeStatus.needsTrust] for the user's Trust or Block.
  Future<void> prepareNativeComponents() async {
    final manager = nativeComponents;
    if (manager == null || project.cppComponents.isEmpty) return;
    final opened = project;
    final status = await manager.prepare(opened);
    if (!identical(project, opened) || _disposed) return;  // another project opened meanwhile
    nativeStatus = status;
    notifyListeners();
    if (status.loaded.isNotEmpty) await _syncNow();
  }

  Future<void> newProject() => _switchTo(blankProject());

  Future<void> newProjectFromTemplate() => _switchTo(starterProject());

  Future<void> openProject(String id) async {
    final p = await _storage?.load(id);
    if (p != null) await _switchTo(p);
  }

  /// Imports a portable project as a new project ID so it cannot overwrite an existing saved project.
  Future<void> importProject(ProjectDoc imported) {
    final copy = ProjectDoc.fromJson(imported.toJson()..['id'] = newId('p'));
    return _switchTo(copy);
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
