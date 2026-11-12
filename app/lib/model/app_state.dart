// App state: settings, the startup choice, the open project, engine sync, autosave, meters and every edit.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../engine/execution.dart';
import '../platform/audio_route.dart';
import '../platform/resource_signals.dart';
import 'latency_comp.dart';
import 'poller.dart';
import 'native_components.dart';
import 'project.dart';
import 'project_dependencies.dart';
import 'automation_writer.dart' show AutomationTarget;
import 'clip_automation.dart';
import 'default_project.dart';
import 'history.dart';
import 'mixer_fx.dart' show masterLayerId;
import 'pattern_doc.dart';
import 'playhead_clock.dart';
import 'settings.dart';
import 'storage.dart';
import 'pattern_templates.dart';
import 'templates.dart';

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
        ]},
        clipLanes = {for (final layer in project.layers) for (final clip in layer.clips) clip.id: [
          for (final lane in clip.automation) lane.copy(),
        ]};

  final List<ProjectAutomationLaneDoc> projectLanes;
  final Map<String, List<AutomationLaneDoc>> trackLanes;
  final Map<String, List<ClipAutomationLaneDoc>> clipLanes;
}

/// A request to bring the views (Arrange, an open piano roll) back to [step] (sixteenth steps): the transport's ⏮.
/// [always] (a double tap, Ctrl+Home: the project start) scrolls them there; otherwise (one tap, the loop start) a
/// view scrolls only when [step] is off its screen. [serial] tells two requests to the same place apart.
@immutable
class RevealStartRequest {
  const RevealStartRequest(this.step, {required this.always, required this.serial});
  final double step;
  final bool always;
  final int serial;
}

class AppState extends ChangeNotifier {
  AppState({Settings? settings, AudioRoute? audioRoute, int Function()? clockUs})
      : settings = settings ?? Settings(),
        _clockUs = clockUs ?? _monotonicUs {
    latency = LatencyComp(
        store: LatencyStore(this.settings.dir == null
            ? null : File('${this.settings.dir!.path}${Platform.pathSeparator}latency.json')),
        route: audioRoute ?? platformAudioRoute())
      ..outputName = (() => engine?.audioStatus().device ?? '')
      ..inputName = (() => (engine?.audioStatusJson()['input'] as Map?)?['device'] as String? ?? '')
      ..addListener(_latencyChanged);
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
    _docChanged(); // the swap timing and the voice budget are in the engine JSON
    applyAudioSettings();
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

  // ---------- latency compensation (owner, 2026-11-11; latency_comp.dart) ----------

  static final Stopwatch _clock = Stopwatch()..start();
  static int _monotonicUs() => _clock.elapsedMicroseconds;
  final int Function() _clockUs;

  /// The app's clock in microseconds (monotonic; tests pass their own).
  int get nowUs => _clockUs();

  /// The output and input latency in force: the platform's figure plus each device's offset (Settings › Audio ›
  /// Latency).
  late final LatencyComp latency;

  /// The last few seconds of meter reads, each at the time it was read, so meters show what is heard.
  final MeterTimeline meterTimeline = MeterTimeline();
  int _latencyReadUs = -1 << 62;
  int _playStartUs = 0;
  double _playStartStep = 0;

  void _latencyChanged() {
    tick.value++;
    notifyListeners();
  }

  /// How long after rendering a sample is heard, in microseconds (0 with compensation off).
  int get outputLatencyUs => (latency.outputMs * 1000).round();

  /// The meter read being heard now: the one taken an output latency ago (the newest with compensation off or
  /// nothing older kept). Peaks, playing and position all come from it.
  MeterReading get audibleReading =>
      meterAt(nowUs - outputLatencyUs) ?? MeterReading(nowUs, const EngineMeters(), const []);

  /// The meter read taken at or before [us] on [nowUs]'s clock; while compensation holds the first reads back,
  /// a silent one (nothing of them is heard yet). Null only when nothing was read at all.
  MeterReading? meterAt(int us) {
    final newest = meterTimeline.newest;
    if (newest == null) return null;
    if (us >= newest.us) return newest;
    return meterTimeline.at(us) ??
        MeterReading(us, EngineMeters(playing: false, loopLength: newest.meters.loopLength), const []);
  }

  /// The master meters as heard ([meters] is what was just rendered): what peak meters should read.
  EngineMeters get audibleMeters {
    final r = audibleReading.meters;
    final m = meters;
    // The transport's state and overloads are now's; the levels are the heard ones.
    return EngineMeters(cpu: m.cpu, peakL: r.peakL, peakR: r.peakR, playing: m.playing, overloaded: m.overloaded,
        position: r.position, loopLength: m.loopLength);
  }

  /// Each track's meter as heard ([layerMeters] is what was just rendered).
  List<LayerMeterValue> get audibleLayerMeters {
    if (outputLatencyUs <= 0) return layerMeters;
    final heard = audibleReading.layers;
    return [for (var i = 0; i < layerMeters.length; i++) i < heard.length ? heard[i] : const LayerMeterValue()];
  }

  /// The output latency in sixteenth steps at the project's tempo.
  double get outputLatencySteps => latency.outputMs / 1000 * project.bpm / 15;

  /// Where the engine renders now, in sixteenth steps (playing; [playheadStep] is where the ear is).
  double get renderStep {
    final m = meters;
    if (m.playing && m.loopLength > 0) return m.position * project.engineLoopSteps / m.loopLength;
    return pausedStep ?? 0;
  }

  /// [step] rendered now, moved back to where the ear is: an output latency earlier, wrapped back over the loop
  /// (the loop range when on, else the song) and held at where play began until the first sound is heard.
  double heardStep(double step, {int? atUs}) {
    final lat = outputLatencySteps;
    if (lat <= 0) return step;
    if ((atUs ?? nowUs) - _playStartUs < outputLatencyUs) return _playStartStep;
    final p = project;
    final (from, to) = p.loopsRange
        ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble())
        : (0.0, p.engineLoopSteps.toDouble());
    var s = step - lat;
    final span = to - from;
    if (span > 0) {
      while (s < from && step >= from) {
        s += span;
      }
    }
    return s < 0 ? 0 : s;
  }

  void _markPlayStart(double step) {
    _playStartUs = nowUs;
    _playStartStep = step;
    meterTimeline.clear();
  }

  SoundQuality? _quality;
  String? _fallbackNote;  // the audioError a fallback set, cleared when the choice opens again
  Future<void> _audioConfigured = Future.value();

  /// Completes when the last device choice has reached the engine (tests).
  @visibleForTesting
  Future<void> get audioConfigured => _audioConfigured;
  AudioBuffer? _buffer;
  bool? _bufferRecording;
  String? _deviceChoice, _clickChoice;

  /// Sends the sound quality, the device's choice (device, callback size, exclusive mode), the click's sound and the
  /// buffer mode to the engine when they (or whether a recording runs) changed. A device choice reopens a running
  /// device on a background isolate (the engine's device lock; never in the callback or on the UI isolate); when the
  /// choice doesn't open, the system default plays instead and [audioError] says so.
  void applyAudioSettings({bool? recording}) {
    final e = engine;
    if (e == null) return;
    if (_quality != settings.soundQuality) {
      _quality = settings.soundQuality;
      e.setQuality(settings.soundQuality.index);
    }
    final device =
        '${settings.audioDeviceId}|${settings.audioDevice}|${settings.bufferFrames}|${settings.exclusiveAudio}';
    if (_deviceChoice != device) {
      _deviceChoice = device;
      final name = settings.audioDevice;
      _audioConfigured = e
          .configureAudio(
              deviceId: settings.audioDeviceId,
              device: name,
              periodFrames: settings.bufferFrames,
              exclusive: settings.exclusiveAudio)
          .then((result) {
        if (_disposed || _deviceChoice != device) return;  // a newer choice will report for itself
        final before = audioError;
        audioError = switch (result) {
          AudioConfigured.ok => audioError == _fallbackNote ? null : audioError,
          AudioConfigured.fallback => _fallbackNote = 'Couldn\'t open ${name.isEmpty ? 'the chosen size or mode' : name}; '
              'using the default',
          AudioConfigured.closed => 'The audio device did not reopen with the new settings',
        };
        if (audioError != before) notifyListeners();
      }, onError: (Object _) {});
    }
    final click = '${settings.clickVolume}|${settings.clickSound.index}';
    if (_clickChoice != click) {
      _clickChoice = click;
      e.setMetronomeSound(settings.clickVolume, settings.clickSound.index);
    }
    final rec = recording ?? _bufferRecording ?? false;
    if (_buffer != settings.audioBuffer || _bufferRecording != rec) {
      _buffer = settings.audioBuffer;
      _bufferRecording = rec;
      e.setBufferMode(settings.audioBuffer.index, recording: rec);
    }
  }

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

  /// A one-line note about the project just opened (its .caw sounds were dropped); cleared by the next open.
  String? openNotice;

  /// The files the open project plays that aren't on this device (project_dependencies.dart): the banner names
  /// them with Locate… and Replace…; what needs them stays silent until they are relinked.
  List<ProjectDependency> missingFiles = const [];
  ProjectStorage? _storage;
  /// The project storage once opened (the C++ Builder's desktop build materializes sources through it).
  ProjectStorage? get storage => _storage;
  /// The pattern templates Build's examples list (bundled with the app, pattern_templates.dart).
  List<PatternTemplate> patternExamples = patternTemplates;

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

  /// Bumped on every meter poll (about 30 times a second) so meters can repaint without rebuilding screens.
  final ValueNotifier<int> tick = ValueNotifier(0);

  /// Aggregate value tick retained for diagnostics and external listeners. Workspaces use the scoped ticks below
  /// so parameter, track and master drags don't rebuild unrelated controls.
  late final ValueNotifier<int> values = ValueNotifier(0)..addListener(_docChanged);
  late final ValueNotifier<int> masterValueTick = ValueNotifier(0)..addListener(_docChanged);
  final Map<String, ValueNotifier<int>> _moduleValueTicks = {};
  final Map<String, ValueNotifier<int>> _layerValueTicks = {};
  ValueNotifier<int> moduleValueTick(String id) =>
      _moduleValueTicks.putIfAbsent(id, () => ValueNotifier(0)..addListener(_docChanged));
  ValueNotifier<int> layerValueTick(String id) =>
      _layerValueTicks.putIfAbsent(id, () => ValueNotifier(0)..addListener(_docChanged));
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
    if (!meters.playing && _heldPreviews.isEmpty && deviceNotesHeld == 0 && !(engine?.testToneSounding ?? false)) {
      engine?.stopAudio();
    }
  });

  /// Settings › Audio's test tone: opens the device if it is closed and plays 440 Hz for [seconds]; returns an error
  /// message when the device can't open.
  String? playTestTone({double seconds = 1.5}) {
    final e = engine;
    if (e == null) return engineError ?? 'The sound engine did not load';
    if (useAudioDevice && !e.audioOn) {
      final error = _openAudio(e);
      if (error != null) {
        notifyListeners();
        return error;
      }
    }
    e.testTone(seconds);
    _poller.wake();
    return null;
  }

  /// The audio device as it runs now (null without an engine).
  AudioStatus? get audioStatus => engine?.audioStatus();

  Future<void> init() async {
    await latency.load();
    _resourcePressureSubscription = ResourceSignals.changes.listen(
      (pressure) => EngineExecutionPolicy.updateRuntimeSignals(pressure: pressure),
      onError: (Object _) => EngineExecutionPolicy.updateRuntimeSignals(pressure: EnginePressure.unknown),
    );
    EngineExecutionPolicy.updateRuntimeSignals(pressure: await ResourceSignals.read());
    try {
      engine = Engine.create(sampleRate: settings.sampleRate);
      applyAudioSettings();  // before the device opens, so it opens on the chosen device at the chosen size
      hardwareProfile = EngineExecutionPolicy.hardwareProfile;
      auditionPlan = EngineExecutionPolicy.plan(workload: EngineWorkload.interactiveAudition);
      await _audioConfigured;  // the choice is in the engine before the device opens (no reopen right after)
      _openAudio(engine!);
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
  /// plan U1). On a first run, or when the last project is gone, it opens the default project ([starterProject]). New, Template
  /// and Open are in the project menu.
  Future<void> openStorage(ProjectStorage storage) async {
    _storage = storage;
    await loadDefaultProject();
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
    String? error = damaged ? 'The last project could not be read, so the default project opened instead. '
        'Its file is still in the projects folder.' : null;
    try {
      await _switchTo(last ?? starterProject(), saveCurrent: false);
    } catch (e) {
      if (last == null) rethrow;
      error = 'The last project, "${last.name}", could not be opened ($e), so the default project opened instead.';
      await _switchTo(starterProject(), saveCurrent: false);
    }
    openError = error;
  }

  /// An empty project: no modules and no layers.
  /// Settings › Projects and files sets its tempo and time signature.
  ProjectDoc blankProject() => ProjectDoc(id: newId('p'), name: 'New project')
    ..bpm = settings.newProjectBpm
    ..beatsPerBar = settings.newProjectBeatsPerBar;

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_settingsChanged);
    final pressureSubscription = _resourcePressureSubscription;
    _resourcePressureSubscription = null;
    if (pressureSubscription != null) unawaited(pressureSubscription.cancel());
    _poller.dispose();
    latency.removeListener(_latencyChanged);
    latency.dispose();
    _liveTimer?.cancel();
    _saveTimer?.cancel();
    _syncTimer?.cancel();
    _historyTimer?.cancel();
    masterValueTick.dispose();
    values.dispose();
    tick.dispose();
    revealStartRequests.dispose();
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
    _readPlayhead();
    if (before.playing != meters.playing) {
      EngineExecutionPolicy.updateRuntimeSignals(audioActive: meters.playing);
    }
    layerMeters = [for (var i = 0; i < project.layers.length; i++) e.layerMeter(i)];
    final now = nowUs;
    meterTimeline.push(MeterReading(now, meters, layerMeters));
    if (e.audioOn && now - _latencyReadUs > 3000000) {
      // The platform's figure and the route, now and then (a Bluetooth link can settle after it opens).
      _latencyReadUs = now;
      unawaited(latency.refresh());
      checkAudioDevice();
    }
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
    // Held back by the output latency, the meters keep moving until what was rendered last has been heard.
    final heardYet = outputLatencyUs <= 0 || now - _lastLoudUs > outputLatencyUs;
    final loud = meters.playing || meters.peakL > 0 || meters.peakR > 0 || layerMeters.any((m) => m.peak > 0);
    if (loud) _lastLoudUs = now;
    return loud || !heardYet;
  }

  int _lastLoudUs = 0;

  // ---------- starter content ----------

  ModuleDoc moduleFromPattern(PatternTemplate t) =>
      ModuleDoc(id: newId('m'), name: headerValue(t.source, 'name') ?? t.file.replaceAll('.caw', ''), source: t.source);

  /// The starter project: what a first run, a deleted last project and the bundled template open. A fresh copy of
  /// the owner's bundled default project ("mid tempo", 2026-11-12; [defaultProject]), read by [openStorage].
  ProjectDoc starterProject() => defaultProject();

  /// A demo project built in code, for tests and benchmarks that depend on its shape (the app's starter until
  /// 2026-11-12, "First loop"): the engine's built-in C++ instruments (#157) as kick, hats, bass, a lead, and a muted
  /// acid line and pad, each playing a pattern over the 4-bar loop; the bass, lead, acid and pad are Flagship
  /// presets (one synth, 2026-11-10). Its patterns are written here, not read from the .caw templates.
  ProjectDoc demoProject() {
    final p = ProjectDoc(id: newId('p'), name: 'First loop');
    ModuleDoc pattern(String name, String summary, String length, String notes) {
      final m = ModuleDoc(
          id: newId('m'),
          name: name,
          source: '---\ncaw: 1\nkind: pattern\nname: $name\nsummary: $summary\nlength: $length\n---\n'
              '// at = start in 16ths, len = length in 16ths, vel = 0..1\n$notes');
      p.modules.add(m);
      return m;
    }

    final kick = pattern('Kick', 'Four on the floor', '16', '0 C2 1 1\n4 C2 1 1\n8 C2 1 1\n12 C2 1 1\n');
    // F#2 is the closed hi-hat and A#2 the open one, as on a General MIDI drum kit.
    final hats = pattern('Hats', 'Hi-hats on every 16th, opening on the off-beat', '16',
        [for (var at = 0; at < 16; at++) '$at ${at % 8 == 6 ? 'A#2' : 'F#2'} 1 1\n'].join());
    final bass = pattern('Bass line', 'A minor 16th-note bass', '16',
        '0 A1 1/2 1\n2 A1 1/2 1\n3 C2 1/2 1\n4 A2 1/2 1\n6 G1 1/2 1\n8 E2 1/2 1\n9 C2 1/2 1\n11 G1 1/2 1\n'
        '12 A1 1/2 1\n15 A1 1/2 1\n');
    final lead = pattern('Lead', 'Two bars of an A minor hook', '2 bars',
        '0 E4 2 0.9\n2 A4 2 0.8\n4 C5 3 0.9\n8 B4 2 0.8\n10 A4 2 0.7\n12 G4 4 0.8\n'
        '16 E4 2 0.9\n18 A4 2 0.8\n20 C5 2 0.9\n22 D5 1 0.8 slide\n23 E5 5 0.9\n28 D5 2 0.7\n30 C5 2 0.6\n');
    final acid = pattern('Acid line', 'One bar of A minor acid with two slides, a ratchet and a note that plays half the time',
        '16',
        '// extras: slide (glide into the next note), ratchet N (repeat N times), prob P (chance it plays)\n'
        '0 A1 2 1\n2 A2 1 0.7\n3 A1 1 0.8 slide\n4 C2 2 0.9\n6 A1 1 0.6 prob 0.5\n8 E2 2 1 ratchet 2\n'
        '10 G1 1 0.7\n11 A1 1 0.8 slide\n12 A2 2 0.9\n14 G2 1 0.6\n15 E2 1 0.8\n');
    final chords = pattern('Chords', 'Four bars of A minor, F, C and G chords', '4 bars',
        '// A chord is several notes joined by commas; each note gets its own voice.\n'
        '0 A3,C4,E4 16 0.8\n16 F3,A3,C4 16 0.75\n32 C3,E3,G3 16 0.8\n48 G3,B3,D4 14 0.7\n62 G3,B3,D4 1/2 0.5 ratchet 2\n');
    var c = 0;
    void layer(String name, String instrument, ModuleDoc pattern, double vol,
        {Map<String, double> params = const {}, String? preset, List<ComponentUseDoc> effects = const [], bool mute = false}) {
      p.layers.add(LayerDoc(
          id: newId('l'),
          name: name,
          color: c++ % 4,
          instrument: ComponentUseDoc(instrument, {...params}, false, null, 1, preset),
          components: [...effects],
          clips: [ClipDoc(id: newId('c'), patternId: pattern.id, lengthSteps: p.loopSteps)],
          volume: vol,
          mute: mute));
    }

    // Both drum tracks play the 808 kit (org.caw.drums): the kick's pattern hits C2 (pad A1), the hats' F#2 and A#2.
    layer('Kick', 'org.caw.drums', kick, 0.9, preset: 'Kit: 808');
    layer('Hats', 'org.caw.drums', hats, 0.55, preset: 'Kit: 808');
    const flagship = 'org.caw.synth.flagship';
    // The filter envelope's depth: a mod slot's amount is the octaves over the cutoff knob's 9.97-octave travel.
    const cutoffOctaves = 9.965784284662087;
    layer('Bass', flagship, bass, 0.75, preset: 'Mono bass', params: {
      'flt1_cutoff': 270, 'flt1_resonance': 0.45, 'mod1_amt': 5 * 0.6 / cutoffOctaves,
      'env1_decay': 0.18, 'env2_decay': 0.18, 'env2_release': 0.18, 'env1_sustain': 0.2,
    });
    layer('Lead', flagship, lead, 0.45, preset: 'Morph pad', params: {
      'osc1_frame': 0.66, 'mod1_amt': 0.15, 'osc1_unison': 3, 'osc1_detune': 10, 'flt1_cutoff': 2600,
      'env1_attack': 0.005, 'env1_decay': 0.25, 'env1_sustain': 0.5, 'env1_release': 0.3,
    }, effects: [ComponentUseDoc('org.caw.delay.pingpong', {'sync': 3, 'mix': 0.3})]);
    // Muted to start with: the acid line plays in the bass's register and the pad under the lead. Unmute one.
    layer('Acid', flagship, acid, 0.6, preset: 'Acid 303',
        params: {'flt1_resonance': 0.8}, effects: [ComponentUseDoc('org.caw.distortion', {'drive': 3, 'mix': 0.5})], mute: true);
    layer('Pad', flagship, chords, 0.5, preset: 'Morph pad', effects: [ComponentUseDoc('org.caw.chorus')], mute: true);
    return p;
  }

  // ---------- engine sync and saving ----------

  /// The layer a pattern's note previews play on: the selected layer if it plays [patternId], else the first that
  /// does; null when no layer plays it.
  String? previewLayerFor(String patternId) {
    bool plays(LayerDoc l) => l.instrument != null && (l.patternId == patternId || l.clips.any((c) => c.patternId == patternId));
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
    if (!e.audioOn) _openAudio(e);
    e.noteOn(layerId, id, pitch, velocity);
    _heldPreviews.add(id);
    _poller.wake();
  }

  void previewPitch(int id, double pitch) => engine?.notePitch(id, pitch);

  /// Keys a MIDI device holds down now (LiveMidi counts them): the audio device stays open while any is held.
  int deviceNotesHeld = 0;

  /// MIDI from a device for [layerId]'s instrument, placed by the engine at the frame it was played ([timeNs] on the
  /// MIDI clock; caw.h API 15). MIDI 1.0 [bytes], or UMP [words]. Tests override it to watch.
  void deviceMidi(String layerId, {List<int>? bytes, List<int>? words, int timeNs = 0}) {
    final e = engine;
    if (e == null) return;
    if (!e.audioOn) _openAudio(e);
    if (words != null) e.midiUmp(layerId, words, timeNs);
    if (bytes != null) e.midiBytes(layerId, bytes, timeNs);
    _poller.wake();
  }

  /// Ends the device notes on [layerId] (null: every track), as an unplugged keyboard leaves them.
  void deviceMidiRelease([String? layerId]) => engine?.midiRelease(layerId);

  /// Where the playhead was at [timeNs] on the MIDI clock, in sixteenth steps (unwrapped: past the loop's end it
  /// counts on), or null when the engine can't tell (stopped, counting in, no engine).
  double? stepAt(int timeNs) {
    final e = engine;
    final m = meters;
    if (e == null || timeNs <= 0 || m.loopLength <= 0) return null;
    final pos = e.positionAt(timeNs);
    // What was heard then: the render position less the output latency (a take lands where it was played against
    // what you heard).
    return pos < 0 ? null : heardStep(pos * project.engineLoopSteps / m.loopLength);
  }

  /// Where the engine rendered at [timeNs] on the MIDI clock, in steps (not moved back to what was heard): the
  /// tap-along calibration compares it with the beat. Null when the engine can't tell.
  double? renderStepAt(int timeNs) {
    final e = engine;
    final m = meters;
    if (e == null || timeNs <= 0 || m.loopLength <= 0) return null;
    final pos = e.positionAt(timeNs);
    return pos < 0 ? null : pos * project.engineLoopSteps / m.loopLength;
  }

  /// The tip the latency badge shows while the output adds more than 50 ms; null otherwise.
  String? get latencyTip => latency.outputIsLate
      ? '${latency.routeInfo.output.label} adds ${latency.outputMs.round()} ms: live playing and monitoring will feel late'
      : null;

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

  /// What Solo preview plays for the selected pattern: its notes through the C++ instrument and effects of a track
  /// that plays it; null when no track with an instrument plays it.
  ({String pattern, ComponentUseDoc instrument, List<ComponentUseDoc> components})? get preview {
    final m = project.module(selectedModuleId);
    if (m == null || !isPattern(m.id)) return null;
    final layer = project.layers.where((l) =>
        !l.isFolder && l.instrument != null && l.clips.any((clip) => clip.patternId == m.id)).firstOrNull;
    if (layer == null) return null;
    return (pattern: m.id, instrument: layer.instrument!, components: layer.components);
  }

  String _engineJson({Map<String, String>? sourceOverrides}) {
    final pv = previewOnly ? preview : null;
    return project.toEngineJson(
        auditionPattern: pv?.pattern,
        auditionInstrument: pv?.instrument,
        auditionComponents: pv?.components ?? const [],
        auditionOnly: previewOnly,
        voices: settings.lightMode ? 4 : 32, // global cap; each generator chooses its own voice count
        swap: settings.swapTiming.name,
        suspendLanes: suspendedLanes,
        // The engine's built-ins (org.caw.*) are always loaded, so they play beside the project's loaded ones.
        playableComponents: nativeComponents == null ? null : {
          ...nativeComponents!.loaded,
          for (final c in [
            ...project.masterComponents,
            for (final l in project.layers) ...[...l.components, ?l.instrument],
          ])
            if (c.id.startsWith('org.caw.')) c.id,
        },
        sourceOverrides: sourceOverrides);
  }

  Future<void> _syncNow() async {
    final e = engine;
    if (e == null) return;
    _livePending = null; // the project as it is now supersedes a drag step not yet sent
    _docGen++;
    final json = _engineJson();
    final id = project.id;
    try {
      info = await e.setProject(json);
      engineError = null;
      _engineProjectId = id;
    } catch (err) {
      engineError = 'Engine error: $err';
      // The engine keeps what it had when a project is refused. That is right for an edit of this project (its last
      // good state plays on), but never for another project: its audio must not play under this one's name.
      if (_engineProjectId != id) {
        e.stop();
        _transportOn = false;
        try {
          info = await e.setProject(ProjectDoc(id: id, name: project.name).toEngineJson());
          _engineProjectId = id;
        } catch (_) {
          // Even the empty project was refused: leave the transport stopped.
        }
      }
    }
    notifyListeners();
  }

  /// The project whose state the engine holds (null before the first project loads): see [_syncNow].
  String? _engineProjectId;

  /// Automation lanes the engine leaves out while they are being written ([automationKey]s; the automation writer).
  final Set<String> suspendedLanes = {};

  /// A control moved by hand (volume, pan, a module, global or native parameter), before its value is stored: the
  /// automation writer (lib/model/automation_writer.dart) records it while Automate is on and the song plays.
  void Function(AutomationTarget target, double value)? onParamMove;

  /// Sends the project to the engine soon, with no edit (the automation writer after [suspendedLanes] changes).
  void resyncEngine() => _sync();

  ({String id, String? text})? _livePending;
  bool _liveBusy = false;

  /// A pattern edit still under the finger, heard while the song plays (#170): the project goes to the engine with
  /// [text] as pattern [moduleId]'s source, so a sounding note follows the drag. Nothing else changes: no save, no
  /// undo step, and no listener is notified (the piano roll keeps its drag in an overlay). The roll throttles calls
  /// to about 30 a second; one sent while another is still being built waits, and only the newest is sent.
  /// [text] null (a drag cancelled) sends the project as it is again.
  Future<void> livePattern(String moduleId, String? text) async {
    if (engine == null) return;
    _livePending = (id: moduleId, text: text);
    if (!_liveBusy) await _liveSend();
  }

  // A live drag step's engine JSON is the project's with one module source changed: the rest is built once, around
  // a marker, and each step only splices the new text in (#174). Any edit, value move or sync drops it.
  int _docGen = 0;
  ({int gen, ProjectDoc project, String id, String head, String tail})? _liveTemplate;
  static const _liveMarker = '\u0001caw-live-source\u0001';

  void _docChanged() => _docGen++;

  /// The engine JSON of a live drag step: the project with [text] as module [moduleId]'s source.
  @visibleForTesting
  String liveEngineJson(String moduleId, String text) {
    var t = _liveTemplate;
    if (t == null || t.gen != _docGen || !identical(t.project, project) || t.id != moduleId) {
      final json = _engineJson(sourceOverrides: {moduleId: _liveMarker});
      final marker = jsonEncode(_liveMarker);
      final at = json.indexOf(marker);
      if (at < 0 || json.indexOf(marker, at + 1) >= 0) return _engineJson(sourceOverrides: {moduleId: text});
      t = _liveTemplate = (gen: _docGen, project: project, id: moduleId, head: json.substring(0, at),
          tail: json.substring(at + marker.length));
    }
    return '${t.head}${jsonEncode(text)}${t.tail}';
  }

  Future<void> _liveSend() async {
    _liveBusy = true;
    try {
      for (var next = _livePending; next != null; next = _livePending) {
        _livePending = null;
        final e = engine;
        if (e == null || _disposed) break;
        final text = next.text;
        if (text == null) {
          _syncTimer?.cancel();
          await _syncNow();
          continue;
        }
        try {
          await e.setProject(liveEngineJson(next.id, text));
        } catch (_) {
          // A live step that fails (the engine busy or gone) is dropped: the edit is sent in full on release.
        }
      }
    } finally {
      _liveBusy = false;
    }
  }

  /// Sends the project to the engine soon (edits in quick succession are sent once).
  void _sync() {
    _docGen++;
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 40), _syncNow);
  }

  void _save() {
    _docGen++;
    _recordHistory();
    _saveTimer?.cancel();
    _saveTimer = Timer(Duration(milliseconds: settings.autosaveMs), flush);
  }

  // ---------- undo and redo (the whole project) ----------

  /// Every project edit saves, so every edit lands here: a burst of edits, until a 600 ms pause, is one step.
  final ProjectHistory history = ProjectHistory();
  Timer? _historyTimer;
  bool _restoring = false;

  // The project's JSON as last encoded: autosave writes it and the undo step that settles 100 ms later reuses it,
  // so a burst of edits encodes the project once, not twice (#174). Any edit or value move ([_docGen]) drops it.
  ({int gen, ProjectDoc project, String text})? _encoded;

  String _snapshot({bool reuse = false}) {
    final c = _encoded;
    if (reuse && c != null && c.gen == _docGen && identical(c.project, project)) return c.text;
    final text = jsonEncode(project.toJson());
    _encoded = (gen: _docGen, project: project, text: text);
    return text;
  }

  void _recordHistory() {
    if (starting || _restoring) return;
    final could = (history.canUndo, history.canRedo);
    history.begin();
    // Drags save without notifying (so they stay light); the transport's buttons still need to see a flip.
    if ((history.canUndo, history.canRedo) != could) notifyListeners();
    _historyTimer?.cancel();
    if (_historyHeld) return; // a take of automation writing: it settles when the take ends
    _historyTimer = Timer(const Duration(milliseconds: 600), () {
      final was = (history.canUndo, history.canRedo);
      history.settle(_snapshot(reuse: true));
      if ((history.canUndo, history.canRedo) != was) notifyListeners();
    });
  }

  /// Closes the burst of edits now, so a discrete action (split, glue, a clip's properties) is one undo step of its
  /// own and the next edit starts another.
  void endUndoStep() {
    if (!(_historyTimer?.isActive ?? false)) return;
    _historyTimer!.cancel();
    final was = (history.canUndo, history.canRedo);
    history.settle(_snapshot());
    if ((history.canUndo, history.canRedo) != was) notifyListeners();
  }

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;

  bool _historyHeld = false;

  /// Keeps the burst of edits open while [hold] is true, so a whole take of automation writing is one undo step;
  /// edits made before it settle first, as their own step.
  void holdHistory(bool hold) {
    if (hold == _historyHeld) return;
    _historyTimer?.cancel();
    if (!starting) history.settle(_snapshot());
    _historyHeld = hold;
    notifyListeners();
  }

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
      _layerValueTicks.removeWhere((id, _) => id != masterLayerId && project.layers.every((l) => l.id != id));
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
    if (e != null) {
      project.storeComponentStates(e.componentStates);
      _docGen++;
    }
    final storage = _storage;
    if (storage != null) await storage.save(project, json: _snapshot());
  }

  Future<bool> createRestorePoint() async {
    final storage = _storage;
    if (storage == null || starting) return false;
    await flush();
    await storage.createRestorePoint(project, keep: settings.restorePointsKept);
    return true;
  }

  Future<List<RestorePointSummary>> listRestorePoints() async =>
      await _storage?.listRestorePoints(project.id) ?? const [];

  Future<bool> restoreProjectVersion(String restorePointId) async {
    final storage = _storage;
    if (storage == null || starting) return false;
    final snapshot = await storage.loadRestorePoint(project.id, restorePointId);
    if (snapshot == null) return false;
    await storage.createRestorePoint(project, keep: settings.restorePointsKept);
    await _switchTo(snapshot);
    return true;
  }


  void _changed({bool engine = true}) {
    if (engine) _sync();
    _save();
    notifyListeners();
  }

  // ---------- transport ----------

  /// The clock tap tempo reads (tests swap in a fake one so the result doesn't depend on machine load).
  DateTime Function() tapClock = DateTime.now;

  /// Records a tempo tap; pauses over two seconds restart the measurement.
  /// [at] is injectable for deterministic tests.
  void tapTempo({DateTime? at}) {
    final now = at ?? tapClock();
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
  /// [countInBeats] (recording): starting from a stop, the engine clicks that many beats first.
  void togglePlay({int countInBeats = 0}) {
    final e = engine;
    if (e == null) return;
    if (_transportOn) {
      // Read now: the stop's short fade still moves the transport on.
      final m = e.meters();
      // Paused where the ear is, so play resumes on what was last heard.
      pausedStep = m.loopLength > 0 ? heardStep(m.position * project.engineLoopSteps / m.loopLength) : null;
      e.stop();
      _transportOn = false;
    } else {
      if (useAudioDevice && !e.audioOn) {
        if (_openAudio(e) != null) return notifyListeners(); // no sound card: the pause stays where it was
      }
      final from = pausedStep;
      _markPlayStart(from ?? 0);
      if (countInBeats > 0) {
        e.playCountIn(from ?? 0, countInBeats);
      } else {
        from == null ? e.play() : e.playAt(from);
      }
      pausedStep = null;
      _transportOn = true;
    }
    meters = e.meters();
    _readPlayhead();
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
      _readPlayhead();
      _poller.wake();
    }
    notifyListeners();
  }

  /// Moves the playhead to [step] (sixteenth steps into the song; the transport's scrub). While playing, playback
  /// jumps there; otherwise the next play starts there.
  void seekTo(double step) {
    final e = engine;
    final at = step.clamp(0.0, math.max(0, project.engineLoopSteps - 1).toDouble()).toDouble();
    if (_transportOn && e != null) {
      _markPlayStart(at);
      e.playAt(at);
      meters = e.meters();
      _readPlayhead();
      _poller.wake();
    } else {
      pausedStep = at;
    }
    notifyListeners();
  }

  /// The views' hook for ⏮ ([backToStart]): Arrange and the piano roll listen and glide to the request's step.
  final ValueNotifier<RevealStartRequest?> revealStartRequests = ValueNotifier(null);

  /// Where ⏮ goes: the loop start while a loop range plays, else the project start (sixteenth steps).
  int get startStep => project.loopsRange ? project.loopStartSteps : 0;

  /// The transport's ⏮ (Home; with [projectStart], a double tap or Ctrl+Home): moves the playhead to [startStep] or
  /// the project start. Playing, playback goes on from there; stopped, it only moves (a stop at the project start
  /// stays a stop). It also asks the views to come back ([revealStartRequests]).
  void backToStart({bool projectStart = false}) {
    final at = projectStart ? 0 : startStep;
    if (_transportOn || pausedStep != null || at != 0) {
      seekTo(at.toDouble());
    } else {
      notifyListeners();
    }
    requestRevealStart(step: at.toDouble(), always: projectStart);
  }

  /// Asks the views (Arrange, an open piano roll) to come back to [step]: with [always] they scroll there, else each
  /// scrolls only when [step] is off its screen (the view decides).
  void requestRevealStart({double step = 0, bool always = true}) {
    revealStartRequests.value =
        RevealStartRequest(step, always: always, serial: (revealStartRequests.value?.serial ?? 0) + 1);
  }

  /// Where the playhead is now, in sixteenth steps (paused: where play resumes; stopped: 0): what is heard, an output
  /// latency behind [renderStep] while compensation is on, so the playhead, follow and note highlights line up with
  /// the sound.
  double get playheadStep {
    final m = meters;
    if (m.playing && m.loopLength > 0) return heardStep(m.position * project.engineLoopSteps / m.loopLength);
    return pausedStep ?? 0;
  }

  /// The playhead between reads ([PlayheadClock]): [playheadStep] at the last engine read, run on at the tempo and
  /// settled onto each new read, for drawing it at the screen's rate. Stopped or paused it is [playheadStep] exactly.
  final PlayheadClock playheadClock = PlayheadClock();

  /// [playheadClock] now: where to draw the playhead in this frame.
  double get smoothPlayheadStep =>
      meters.playing && playheadClock.playing ? playheadClock.at(nowUs) : playheadStep;

  // Hands the read just taken to [playheadClock], over the range [heardStep] wraps in.
  void _readPlayhead() {
    final p = project;
    final (from, to) = p.loopsRange
        ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble())
        : (0.0, p.engineLoopSteps.toDouble());
    playheadClock.read(
        step: playheadStep,
        atUs: nowUs,
        playing: meters.playing && meters.loopLength > 0,
        stepsPerSecond: p.bpm / 15,
        from: from,
        to: to);
  }

  void clearOverload() {
    engine?.clearOverload();
    _poller.wake();
    notifyListeners();
  }

  /// Whether the app is in front (the lifecycle's last word): the microphone is released behind it unless a
  /// recording runs (`AudioRecorder`).
  final foreground = ValueNotifier<bool>(true);

  /// Called when the app goes to the background or returns. Playing, the output keeps running behind (nothing on
  /// this path waits on the audio thread); stopped, the device closes and reopens on return. On return a device the
  /// system stopped while away (a disconnect that could not be reopened) opens again too.
  void lifecycle({required bool foreground}) {
    _poller.setVisible(foreground);
    this.foreground.value = foreground;
    final e = engine;
    if (e == null) return;
    if (!foreground) {
      flush();
      if (!meters.playing) e.stopAudio();
    } else if (!e.audioOn || !e.audioStatus().running) {
      _openAudio(e);
      notifyListeners();
    }
  }

  /// A device the system stopped while the transport plays (miniaudio gives up on an AAudio stream it could not
  /// reopen after a disconnect, and the status then says not running) opens again; true when it had to. Called by
  /// the meter poll now and then, and by the background playback's slow check while the app is behind.
  bool checkAudioDevice() {
    final e = engine;
    if (e == null || !useAudioDevice || !e.audioOn || !_transportOn) return false;
    if (e.audioStatus().running) return false;
    _openAudio(e);
    notifyListeners();
    return true;
  }

  /// Behind the app with the transport stopped (the notification's Stop): the device closes as it does when the
  /// app goes behind stopped, and reopens on return.
  void releaseAudioBehind() {
    if (!foreground.value && !meters.playing && !_transportOn) engine?.stopAudio();
  }

  /// Opens the device: null when it runs, else why not ([audioError] either way). It may run on the system default
  /// because the chosen device didn't open: it plays, and [audioError] says so.
  String? _openAudio(Engine e) {
    final error = e.startAudio();
    if (error != null) return audioError = error;
    latency.readDevice = e.audioLatency;
    _latencyReadUs = nowUs;
    unawaited(latency.refresh());
    final st = e.audioStatus();
    if (st.fallback) {
      final name = settings.audioDevice;
      audioError = _fallbackNote =
          'Couldn\'t open ${name.isEmpty ? 'the chosen size or mode' : name}; using the default';
    } else {
      audioError = null;
    }
    return null;
  }

  // ---------- patterns (Build) ----------

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

  String addModule(PatternTemplate t) {
    final m = moduleFromPattern(t);
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

  void renameModule(String id, String name) {
    final m = project.module(id);
    if (m == null || name.trim().isEmpty) return;
    m.name = name.trim();
    _changed(engine: false);
  }

  void deleteModule(String id) {
    project.modules.removeWhere((m) => m.id == id);
    for (final l in project.layers) {
      if (l.patternId == id) l.patternId = null;
      l.clips.removeWhere((clip) => clip.patternId == id);
    }
    if (selectedModuleId == id) selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
    _pruneClipSelection();
    _changed();
  }

  void setPreviewOnly(bool on) {
    previewOnly = on;
    _changed(engine: true);
  }

  /// Whether [moduleId] is one of the project's patterns (every module is, once a project has loaded; #160).
  bool isPattern(String moduleId) {
    final m = project.module(moduleId);
    return m != null && (isPatternSource(m.runSource) || isPatternSource(m.source));
  }

  // ---------- layers (Arranger) ----------

  /// The tracks the arrangement shows, in order: every track. A collapsed folder no longer hides the tracks inside
  /// it but draws them as thin bars ([shownCollapse]; owner, 2026-11-11).
  List<LayerDoc> get visibleLayers => List.of(project.layers);

  /// How [layer]'s row shows: thin inside a collapsed folder (at any depth), else its own [LayerDoc.collapse], so
  /// opening the folder brings back each track's own state.
  TrackCollapse shownCollapse(LayerDoc layer) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
      final folder = project.layers.where((x) => x.id == parent).firstOrNull;
      if (folder == null) break;
      if (folder.collapsed) return TrackCollapse.thin;
      parent = folder.parentId;
    }
    return layer.collapse;
  }

  /// Whether [layer] is somewhere inside the folder [folderId], at any depth.
  bool isInside(LayerDoc layer, String folderId) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
      if (parent == folderId) return true;
      parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
    }
    return false;
  }

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

  /// Opens or closes [layer]'s automation lanes under it in the arrangement (REAPER's envelope button). Only the
  /// screen changes, so the engine isn't re-sent.
  void setLanesShown(LayerDoc layer, bool shown) {
    if (layer.showLanes == shown) return;
    layer.showLanes = shown;
    _changed(engine: false);
  }

  /// Sets how much of each of [layers]' rows shows (the track menu's Collapse, a header's bottom-edge drag or pinch):
  /// one undo step. With [height] (a normal row), that track's own height is set too. Only the screen changes.
  void setTrackCollapse(Iterable<LayerDoc> layers, TrackCollapse collapse, {double? height}) {
    final h = height == null || !height.isFinite ? null
        : height.clamp(LayerDoc.minHeight, LayerDoc.maxHeight).toDouble();
    endUndoStep();
    var changed = false;
    for (final l in layers) {
      if (l.collapse != collapse) {
        l.collapse = collapse;
        changed = true;
      }
      if (h != null && collapse == TrackCollapse.normal && l.height != h) {
        l.height = h;
        changed = true;
      }
    }
    if (!changed) return;
    _changed(engine: false);
    endUndoStep();
  }

  /// [layer]'s row goes back to the global default height (Settings' track height).
  void resetTrackHeight(LayerDoc layer) {
    if (layer.height == null) return;
    endUndoStep();
    layer.height = null;
    _changed(engine: false);
    endUndoStep();
  }

  /// A folder's chevron: collapsed, the tracks inside it show as thin bars ([shownCollapse]); opened, each goes back
  /// to its own state.
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
      for (final clip in layer.clips) {
        if (snapshot.clipLanes[clip.id] case final lanes?) clip.automation = [for (final lane in lanes) lane.copy()];
      }
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
      p.value = value.clamp(lane.target == 'volume' ? 0.0 : -1.0, lane.target == 'volume' ? kMaxMixGain : 1.0).toDouble();
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
          value: value.clamp(lane.target == 'volume' ? 0.0 : -1.0, lane.target == 'volume' ? kMaxMixGain : 1.0).toDouble()));
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

  /// Adds an empty track (no instrument yet: drop one on it, or pick one in its FX).
  void addLayer() {
    project.layers.add(LayerDoc(
      id: newId('l'),
      name: 'Layer ${project.layers.length + 1}',
      color: project.layers.length % LayerDoc.trackColors,
      lengthSteps: project.stepsPerBar,
      volume: 1, // 0 dB (owner, 2026-11-10)
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
    project.master = value.clamp(0.0, kMaxMixGain).toDouble();
    engine?.setMaster(project.master);
    _save();
    masterValueTick.value++;
    values.value++;
  }

  void mixLayer(LayerDoc l, {double? volume, double? pan, bool? mute, bool? solo}) {
    if (volume != null) volume = volume.clamp(0.0, kMaxMixGain).toDouble();
    if (volume != null) onParamMove?.call(AutomationTarget('track', 'volume', layerId: l.id), volume);
    if (pan != null) onParamMove?.call(AutomationTarget('track', 'pan', layerId: l.id), pan);
    if (volume != null) l.volume = volume;
    if (pan != null) l.pan = pan;
    if (mute != null) l.mute = mute;
    if (solo != null) l.solo = solo;
    // Volume and pan drags only redraw their sliders and go straight to the audio thread. Mute and solo reach
    // through folders and buses (soloing a track keeps its buses and send buses open; muting a folder without a bus
    // mutes its tracks), which the engine works out from the whole project, so they go as a project update.
    if (mute == null && solo == null) {
      engine?.setLayerMix(l.id, l.volume, l.pan, l.mute, l.solo);
      _save();
      layerValueTick(l.id).value++;
      values.value++;
    } else {
      _changed();
    }
  }

  void _pruneClipSelection() {
    final valid = {
      for (final layer in project.layers) ...[for (final clip in layer.clips) clip.id, for (final c in layer.audioClips) c.id],
    };
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
          if (clip == null) {
            // Only audio clips are selected here (lib/model/audio_edit.dart): the first of them leads.
            final audio = layer.audioClips.where((c) => selectedClipIds.contains(c.id)).firstOrNull;
            if (audio == null) continue;
            selectedLayerId = layer.id;
            selectedClipId = audio.id;
            break;
          }
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

  /// Tells the screens that [selectedClipIds] changed (Arrange's marquee, split and glue set it directly).
  void clipSelectionChanged() => notifyListeners();

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
          source: original.source, runSource: original.runSource);
      project.modules.add(copy);
      patternId = copy.id;
    }
    final next = ClipDoc(id: newId('c'), patternId: patternId,
        startSteps: start, lengthSteps: clip.lengthSteps.clamp(1, project.maxArrangementSteps - start).toInt(),
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, linked: linked, loopSteps: clip.loopSteps,
        automation: [for (final a in clip.automation) a.copy()]);
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

  /// A new folder at the end, or at the end of [parentId]'s contents: a folder inside a folder, to any depth
  /// (REAPER, UG 5.13.5).
  void addFolder({String? parentId}) {
    final parent = parentId == null ? null : project.layers.where((l) => l.id == parentId && l.isFolder).firstOrNull;
    final folder = LayerDoc(id: newId('l'), name: 'Group', color: project.layers.length % LayerDoc.trackColors,
        parentId: parent?.id, isFolder: true, busEnabled: true);
    var at = project.layers.length;
    if (parent != null) {
      at = project.layers.indexOf(parent) + 1;
      while (at < project.layers.length && isInside(project.layers[at], parent.id)) {
        at++;
      }
    }
    project.layers.insert(at, folder);
    selectedLayerId = folder.id;
    _changed();
  }

  // ---------- project settings and files ----------

  void editProject(void Function(ProjectDoc) change) {
    change(project);
    _changed();
  }

  /// Saves the music video's setup and shots ([ProjectDoc.musicVideo]) with the project; nothing the engine plays.
  void setMusicVideo(Map<String, dynamic> json) {
    project.musicVideo = json;
    _changed(engine: false);
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
    // The retired synths as Flagship presets, and presets' values into the knobs (the engine does the same when it
    // plays, so a project opened without the engine library still sounds right).
    if (engine != null) p.resolveInstruments(Engine.resolveInstrument);
    // A path the project names that isn't a plain local one (a network share, a device or URL) becomes a missing
    // file before the engine or the missing-files check could look at it (project_dependencies.dart).
    try {
      final audio = _storage?.audioDirectory(p.id).path ??
          '${Directory.systemTemp.path}${Platform.pathSeparator}caw-audio${Platform.pathSeparator}${p.id}';
      quarantineUnsafePaths(p, '$audio${Platform.pathSeparator}missing');
    } on ArgumentError {
      // An id storage refuses has no folder; its paths stay as they are and the engine refuses the project.
    }
    project = p;
    openError = null;
    openNotice = switch (p.droppedModules) {
      [] => null,
      final gone => 'C.A.W plays C++ now: ${gone.length == 1 ? 'one .caw sound was' : '${gone.length} .caw sounds were'} '
          'left out of this project (${gone.take(3).join(', ')}${gone.length > 3 ? '…' : ''}).',
    };
    _historyTimer?.cancel();
    history.reset(_snapshot());
    masterValueTick.value++;
    info = {};
    selectedModuleId = p.modules.isEmpty ? null : p.modules.first.id;
    selectedLayerId = null;
    selectedClipId = null;
    selectedClipIds.clear();
    clearTimeSelection();
    previewOnly = false;
    missingFiles = const [];
    await _storage?.setLastOpened(p.id);
    await flush();
    notifyListeners();
    await _syncNow();
    unawaited(prepareNativeComponents());
    unawaited(checkMissingFiles());
  }

  /// Looks for the open project's files on this device again ([missingFiles]).
  Future<void> checkMissingFiles() async {
    final opened = project;
    final missing = await findMissingFiles(opened);
    if (!identical(project, opened) || _disposed) return;
    final before = missingFiles.map((m) => m.key).join('|');
    missingFiles = missing;
    if (missing.map((m) => m.key).join('|') != before) notifyListeners();
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

  /// New project: the template Settings › Projects and files names, else blank (with its tempo and meter).
  Future<void> newProject() => _switchTo(newProjectDoc());

  /// New project from template [t] (the project menu's New from template).
  Future<void> newProjectFromTemplate(TemplateDoc t) => _switchTo(projectFromTemplate(t));

  Future<void> openProject(String id) async {
    final p = await _storage?.load(id);
    if (p != null) await _switchTo(p);
  }

  /// Imports a portable project as a new project ID ([id], else a fresh one) so it cannot overwrite an existing saved
  /// project. [prepare] sees the copy before it opens (a package relinks its unpacked files there).
  Future<void> importProject(ProjectDoc imported, {String? id, void Function(ProjectDoc copy)? prepare}) {
    final copy = ProjectDoc.fromJson(imported.toJson()..['id'] = id ?? newId('p'))..droppedModules = imported.droppedModules;
    prepare?.call(copy);
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
