// App state: settings, the startup choice, the open project, engine sync, autosave, meters and every edit.
import 'output_watch.dart';
import 'track_defaults.dart';
import 'merged_devices.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';
import '../engine/execution.dart';
import '../platform/audio_route.dart';
import '../platform/resource_signals.dart';
import 'audio_devices.dart';
import 'av_sync.dart';
import 'latency_comp.dart';
import 'poller.dart';
import 'native_components.dart';
import 'project.dart';
import 'tempo_map.dart';
import 'vca.dart';
import 'project_dependencies.dart';
import 'sample_use.dart' show SampleUse;
import 'automation_writer.dart' show AutomationTarget;
import 'clip_automation.dart';
import 'default_project.dart';
import 'device_slot_audio.dart';
import 'engine_slot_audio.dart';
import 'freeze.dart';
import 'freeze_hint.dart';
import 'history.dart';
import 'mixer_fx.dart' show masterLayerId;
import 'pattern_doc.dart';
import 'playhead_clock.dart';
import 'settings.dart';
import 'project_library.dart' show TrashBatch;
import 'storage.dart';
import 'startup_progress.dart';
import 'stress_runner.dart' show StressHost;
import 'pattern_templates.dart';
import 'templates.dart';
import 'easter_eggs.dart';
import 'project_names.dart';
import 'collab/project_ops.dart';

part 'app_state/playback.dart';
part 'app_state/engine_sync.dart';
part 'app_state/projects.dart';
part 'app_state/library.dart';
part 'app_state/arrange.dart';

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

class AppState extends ChangeNotifier implements StressHost {
  AppState({Settings? settings, AudioRoute? audioRoute, int Function()? clockUs})
      : settings = settings ?? Settings(),
        _clockUs = clockUs ?? _monotonicUs {
    latency = LatencyComp(
        store: LatencyStore(this.settings.dir == null
            ? null : File('${this.settings.dir!.path}${Platform.pathSeparator}latency.json')),
        route: audioRoute ?? platformAudioRoute())
      ..outputName = (() => engine?.audioStatus().device ?? '')
      ..callbackFrames = (() => engine?.audioStatus().periodFrames ?? 0)
      ..inputName = (() => (engine?.audioStatusJson()['input'] as Map?)?['device'] as String? ?? '')
      ..addListener(_latencyChanged);
    _light = this.settings.lightMode;
    _performanceMode = this.settings.performanceMode;
    _density = this.settings.density;
    _lookRevision = this.settings.lookRevision;
    this.settings.addListener(_settingsChanged);
    outputWatch = OutputWatch(this);
    addListener(outputWatch.update);
    foreground.addListener(outputWatch.update);
  }

  /// Pause when unplugged and Keep the screen awake (#244, output_watch.dart).
  late final OutputWatch outputWatch;

  late bool _light;
  late PerformanceMode _performanceMode;
  late Density _density;
  late int _lookRevision;

  // Lightweight/Minimal change the engine's voice budget; UI meter cadence stays fixed.
  void _settingsChanged() {
    _docChanged(); // the swap timing and the voice budget are in the engine JSON
    applyAudioSettings();
    outputWatch.update();
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

  /// The output and input latency in force: the platform's figure plus each device's offset (Settings › Sound ›
  /// Latency).
  late final LatencyComp latency;

  /// The last few seconds of meter reads, each at the time it was read, so meters show what is heard.
  final MeterTimeline meterTimeline = MeterTimeline();
  int _latencyReadUs = -1 << 62;
  int _tuneReadUs = -1 << 62;
  int _deviceCheckUs = -1 << 62;

  /// The output's dropouts while playing (the platform's underruns), for the smart-freeze hint (1.1.2).
  final DropoutWatch dropouts = DropoutWatch();

  int _playStartUs = 0;
  double _playStartStep = 0;

  void _latencyChanged() {
    tick.value++;
    notifyListeners();
  }

  /// The screen's lead over the sound (av_sync.dart, #236 "lean early"): the frame's display latency plus a small
  /// early bias. The app hands in the rate it draws at (main.dart).
  final AvSync avSync = AvSync();

  /// How far ahead what follows the audio is drawn, in µs (0 with compensation off: it shows what was rendered).
  int get visualLeadUs => latency.enabled ? avSync.leadUs : 0;

  /// The meter read being heard when this frame lights up: the one whose span holds that moment less the output
  /// latency (the newest with compensation off). Peaks, playing and position all come from it.
  MeterReading get audibleReading =>
      meterAt(meterRenderUs(nowUs: nowUs, leadUs: visualLeadUs, outputLatencyUs: outputLatencyUs)) ??
      MeterReading(nowUs, const EngineMeters(), const []);

  SoundQuality? _quality;
  String? _fallbackNote;  // the audioError a fallback set, cleared when the choice opens again
  Future<void> _audioConfigured = Future.value();

  AudioBuffer? _buffer;
  bool? _bufferRecording;
  String? _deviceChoice, _clickChoice;
  (bool, bool)? _safetyChoice;

  /// The engine id the last device choice opened ([engineDeviceId]: a platform choice by its id now).
  String? _openedDeviceId;
  StreamSubscription<void>? _routeSub;

  Engine? engine;

  /// The engine's tempo map and signatures (C API 31): the engine itself once its binding implements [TempoEngine],
  /// or a fake a test sets here. Null: the engine has only the project JSON's `bpm` and `beats_per_bar`.
  TempoEngine? tempoEngine;
  /// What [pushTempo] last sent, so an unchanged map isn't sent again.
  (List<TempoPoint>, List<TimeSignature>)? _tempoSent;

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

  /// Timber's id (removed in 1.1.3) and the note shown when a project that played it opens. Once: the project is
  /// saved with the new instruments, so it never names Timber again.
  static const timberId = 'org.caw.timber';
  static const timberNotice = 'Timber was split into Starling, Nightingale, Curlew, Bittern and Woodpecker; '
      "this project's instruments moved.";

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

  // Shared tap history keeps the toolbar and keyboard action on the same tempo measurement.
  final List<DateTime> _tempoTaps = [];
  String? selectedLayerId;
  String? selectedClipId;
  final Set<String> selectedClipIds = {};
  int? timeSelectionStart, timeSelectionEnd, timeSelectionAnchor;
  int arrangementSnapSteps = 1;
  bool previewOnly = false;
  bool ready = false;

  /// True until the first project opens (the last one, or the template on a first run); nothing is saved before.
  bool starting = true;

  /// The loading steps as [init] runs them, for the startup screen.
  final StartupProgress startup = StartupProgress();

  /// How [init] reads the platform's thermal and power signals and makes the engine (tests replace them). The engine
  /// is made on a background isolate (loading the library and building the engine take tens of milliseconds).
  @visibleForTesting
  Future<EnginePressure> Function() readPressure = ResourceSignals.read;
  @visibleForTesting
  Future<Engine> Function(int sampleRate) createEngine = (rate) => Engine.createOffThread(sampleRate: rate);
  String? lastProjectId;
  List<ProjectSummary> savedProjects = const [];

  /// Bumped on every meter poll (about 30 times a second) so meters can repaint without rebuilding screens.
  final ValueNotifier<int> tick = ValueNotifier(0);

  /// Whether the engine is sounding: playing, or a meter not yet back to silence (a preview, a held note, a test
  /// tone, a tail still to be heard). Stopped and silent, the engine runs no component or modulator, so device
  /// motion that shows them holds still (MotionClock, lib/ui/devices/kit/hero.dart).
  final ValueNotifier<bool> sounding = ValueNotifier(false);

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

  /// Smart freeze (1.1.0): the one-time suggestion to freeze the heaviest track when the CPU stays near the limit.
  final FreezeHint freezeHint = FreezeHint();

  /// The platform's thermal and power state as it last reported it (the heat banner reads it; nothing changes a
  /// setting on it).
  final ValueNotifier<EnginePressure> pressure = ValueNotifier(EnginePressure.unknown);

  /// The platform's thermal headroom forecast 10 s ahead (1.0: severe throttling starts; null unknown), read about
  /// every 10 s from launch (1.1.2): information for the Performance sheet only, never an action (the owner: the
  /// system throttles, not the app).
  final ValueNotifier<double?> thermalHeadroom = ValueNotifier(null);
  Timer? _headroomTimer;
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
    if (!meters.playing && _heldPreviews.isEmpty && deviceNotesHeld == 0 && !(engine?.testToneSounding ?? false) &&
        !samplePreviewing) {
      engine?.stopAudio();
    }
  });

  /// The sample browser's preview sounds (sample_use.dart): the audio device stays open meanwhile.
  bool samplePreviewing = false;

  /// Settings › Sound's test tone: opens the device if it is closed and plays 440 Hz for [seconds]; returns an error
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

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_settingsChanged);
    outputWatch.dispose();
    final pressureSubscription = _resourcePressureSubscription;
    _resourcePressureSubscription = null;
    if (pressureSubscription != null) unawaited(pressureSubscription.cancel());
    _poller.dispose();
    latency.removeListener(_latencyChanged);
    unawaited(_routeSub?.cancel());
    latency.dispose();
    _liveTimer?.cancel();
    _saveTimer?.cancel();
    _syncTimer?.cancel();
    _historyTimer?.cancel();
    masterValueTick.dispose();
    freezeHint.dispose();
    _headroomTimer?.cancel();
    thermalHeadroom.dispose();
    pressure.dispose();
    values.dispose();
    tick.dispose();
    startup.dispose();
    sounding.dispose();
    revealStartRequests.dispose();
    for (final notifier in _moduleValueTicks.values) { notifier.dispose(); }
    for (final notifier in _layerValueTicks.values) { notifier.dispose(); }
    if (engine != null && identical(DeviceSlotAudio.current, EngineSlotAudio.instance)) DeviceSlotAudio.current = null;
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
    layerMeters = e.layerMeters(project.layers.length); // one C API call for every track (beta plan B4.8)
    final now = nowUs;
    meterTimeline.push(MeterReading(now, meters, layerMeters));
    outputWatch.poll(now, playing: meters.playing);  // a removed output, where the platform sends no event (#244)
    if (settings.bufferTuning && e.audioOn && meters.playing && now - _tuneReadUs > 1000000) _tuneBuffer(e, now);
    if (e.audioOn && now - _latencyReadUs > 3000000) {
      // The platform's figure and the route, now and then (a Bluetooth link can settle after it opens).
      _latencyReadUs = now;
      unawaited(latency.refresh());
    }
    // A device the system stopped under the playing transport opens again within a second (1.1.2: it was looked at
    // every 3 s and only while the app still thought it open, so a stopped stream could leave Play stalled).
    if (_transportOn && now - _deviceCheckUs > 1000000) {
      _deviceCheckUs = now;
      checkAudioDevice();
    }
    dropouts.poll(now, playing: meters.playing, read: () => _outputDropouts(e));
    tick.value++;
    freezeHint.poll(now, playing: meters.playing, dropouts: dropouts.count, overloaded: meters.overloaded > 0,
        tracks: () => freezeCandidates(this), share: (l) => measuredTrackShare(this, l),
        hint: (l) => hintedTrackCost(this, l));
    if (meters.overloaded > before.overloaded && settings.lightAuto && !settings.lightMode) {
      // The device can't keep up: Lightweight turns on by itself once (the user can choose another profile).
      lightTurnedOnBySelf = true;
      settings.update((s) {
        s.lightMode = true;
        s.lightAuto = false;
        s.lightBySelf = true;
      });
    }
    if (before.playing != meters.playing || before.overloaded != meters.overloaded) notifyListeners();
    // Held back by the output latency, the meters keep moving until what was rendered last has been heard.
    final heardYet = outputLatencyUs <= 0 || now - _lastLoudUs > outputLatencyUs;
    final loud = meters.playing || meters.peakL > 0 || meters.peakR > 0 || layerMeters.any((m) => m.peak > 0);
    if (loud) _lastLoudUs = now;
    sounding.value = loud || !heardYet;
    return loud || !heardYet;
  }

  int _lastLoudUs = 0;

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
    return pos < 0 ? null : heardStep(project.stepAtLoopFraction(pos / m.loopLength));
  }

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

  /// Freeze (1.0.5): called when an edit reaches a frozen track ([guardFrozen]); the screens ask "Unfreeze to edit?".
  void Function(LayerDoc layer)? onFrozenEdit;

  /// The project whose state the engine holds (null before the first project loads): see [_syncNow].
  String? _engineProjectId;

  /// Automation lanes the engine leaves out while they are being written ([automationKey]s; the automation writer).
  final Set<String> suspendedLanes = {};

  /// A control moved by hand (volume, pan, a module, global or native parameter), before its value is stored: the
  /// automation writer (lib/model/automation_writer.dart) records it while Automate is on and the song plays.
  void Function(AutomationTarget target, double value)? onParamMove;

  ({String id, String? text})? _livePending;
  bool _liveBusy = false;

  // A live drag step's engine JSON is the project's with one module source changed: the rest is built once, around
  // a marker, and each step only splices the new text in (#174). Any edit, value move or sync drops it.
  int _docGen = 0;
  ({int gen, ProjectDoc project, String id, String head, String tail})? _liveTemplate;
  void _docChanged() => _docGen++;

  // ---------- undo and redo (the whole project) ----------

  /// Every project edit saves, so every edit lands here: a burst of edits, until a 600 ms pause, is one step.
  final ProjectHistory history = ProjectHistory();
  Timer? _historyTimer;
  bool _restoring = false;

  // The project's JSON as last encoded: autosave writes it and the undo step that settles 100 ms later reuses it,
  // so a burst of edits encodes the project once, not twice (#174). Any edit or value move ([_docGen]) drops it.
  ({int gen, ProjectDoc project, String text})? _encoded;

  /// Closes the burst of edits now, so a discrete action (split, glue, a clip's properties) is one undo step of its
  /// own and the next edit starts another.
  void endUndoStep() {
    if (!(_historyTimer?.isActive ?? false)) return;
    _historyTimer!.cancel();
    final was = (history.canUndo, history.canRedo);
    history.settle(_snapshot());
    if ((history.canUndo, history.canRedo) != was) notifyListeners();
  }

  /// How many holds keep the history open now (an automation take, a preset preview): they can overlap, and the
  /// burst settles only when the last one ends.
  int _historyHolds = 0;
  /// Keeps the burst of edits open while held, so a whole take of automation writing (or a preset preview) is one
  /// undo step; edits made before the first hold settle first, as their own step. Each `holdHistory(true)` is
  /// ended by one `holdHistory(false)`; while holds overlap, their edits end as one step when the last one ends.
  void holdHistory(bool hold) {
    if (!hold && _historyHolds == 0) return;
    _historyHolds += hold ? 1 : -1;
    if (_historyHolds > (hold ? 1 : 0)) return;  // another hold keeps it open
    _historyTimer?.cancel();
    if (!starting) history.settle(_snapshot());
    notifyListeners();
  }

  /// Time with the project open and the app in front (the card's "time spent" in Files), counted from here.
  final Stopwatch _spent = Stopwatch();

  // ---------- transport ----------

  /// The clock tap tempo reads (tests swap in a fake one so the result doesn't depend on machine load).
  DateTime Function() tapClock = DateTime.now;

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
  /// [countInBars] (recording): starting from a stop, the engine clicks that many bars of the signature first.
  void togglePlay({int countInBars = 0}) {
    final e = engine;
    if (e == null) return;
    if (_transportOn) {
      // Read now: the stop's short fade still moves the transport on.
      final m = e.meters();
      // Paused where the ear is, so play resumes on what was last heard.
      pausedStep = m.loopLength > 0 ? heardStep(meterStep(m)) : null;
      e.stop();
      _transportOn = false;
    } else {
      if (useAudioDevice && !e.audioOn) {
        if (_openAudio(e) != null) return notifyListeners(); // no sound card: the pause stays where it was
      }
      final from = pausedStep;
      _markPlayStart(from ?? 0);
      if (countInBars > 0) {
        e.playCountInBars(from ?? 0, countInBars);
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

  /// Where the playhead is now, in sixteenth steps (paused: where play resumes; stopped: 0): what is heard, an output
  /// latency behind [renderStep] while compensation is on, so the playhead, follow and note highlights line up with
  /// the sound.
  double get playheadStep {
    final m = meters;
    if (m.playing && m.loopLength > 0) return heardStep(meterStep(m));
    return pausedStep ?? 0;
  }

  /// The playhead between reads ([PlayheadClock]): [playheadStep] at the last engine read, run on at the tempo and
  /// settled onto each new read, for drawing it at the screen's rate. Stopped or paused it is [playheadStep] exactly.
  final PlayheadClock playheadClock = PlayheadClock();

  /// [playheadClock] now: where to draw the playhead in this frame (for the moment it lights up, [visualLeadUs]).
  double get smoothPlayheadStep =>
      meters.playing && playheadClock.playing ? playheadClock.at(drawUs + visualLeadUs) : playheadStep;

  /// The playhead for something drawn only on the engine's reads (the piano roll under Smooth follow): where the
  /// line is half a read interval on, plus the lead, so it is as early as late between reads.
  double get heldPlayheadStep => meters.playing && playheadClock.playing
      ? playheadClock.at(heldDrawUs(nowUs: drawUs, leadUs: visualLeadUs, readIntervalUs: _poller.interval.inMicroseconds))
      : playheadStep;

  final FrameTime _frameTime = FrameTime();

  /// The moment this frame is drawn for ([FrameTime]): its vsync on [nowUs]'s clock inside a frame, else now. Tests
  /// with their own clock get their clock (their frames' times are not on it).
  int get drawUs {
    final now = nowUs;
    if (!identical(_clockUs, _monotonicUs)) return now;
    final b = SchedulerBinding.instance;
    final inFrame = b.schedulerPhase == SchedulerPhase.transientCallbacks ||
        b.schedulerPhase == SchedulerPhase.midFrameMicrotasks || b.schedulerPhase == SchedulerPhase.persistentCallbacks;
    return _frameTime.at(nowUs: now, vsyncUs: inFrame ? b.currentSystemFrameTimeStamp.inMicroseconds : null);
  }

  bool _stressSuspended = false;
  double? _stressPosition;

  /// The Benchmark starts: stops the transport (keeping where it was) and closes the audio device.
  @override
  void suspendForStress() {
    if (_stressSuspended) return;
    final e = engine;
    if (_transportOn) togglePlay(); // a pause: pausedStep keeps where it was heard
    _stressPosition = pausedStep;
    _stressSuspended = true;
    e?.notesOff();
    e?.stopAudio();
    notifyListeners();
  }

  /// The Benchmark ended: the position comes back with the transport stopped; Play reopens the device.
  @override
  void resumeAfterStress() {
    if (!_stressSuspended) return;
    _stressSuspended = false;
    pausedStep = _stressPosition;
    _stressPosition = null;
    _transportOn = false;
    _poller.wake();
    notifyListeners();
  }

  /// Remember zoom per project (#244): the arranger hands its view out through [readArrangeView] and takes one
  /// back through [applyArrangeView] (both null while no arranger is built). The view is kept in the settings by
  /// project id, never in the project file, so it is no edit and no undo step.
  ArrangeView? Function()? readArrangeView;
  void Function(ArrangeView view)? applyArrangeView;

  /// Whether the app is in front (the lifecycle's last word): the microphone is released behind it unless a
  /// recording runs (`AudioRecorder`).
  final foreground = ValueNotifier<bool>(true);

  bool _automationGestureOpen = false;

  /// The end of an edit [ProjectOps.apply] made: [sync] sends the project to the engine (after its debounce), every
  /// edit autosaves and opens an undo burst, and [notify] redraws the screens. The edit methods and the ops call it;
  /// screens edit through them.
  void finishEdit({bool sync = true, bool notify = true}) {
    if (sync) _sync();
    _save();
    if (notify) notifyListeners();
  }

  /// Structural layer changes (modules, length) go through a project sync.
  void editLayer(LayerDoc l, void Function(LayerDoc) change) {
    change(l);
    _changed();
  }

  // ---------- project settings and files ----------

  void editProject(void Function(ProjectDoc) change) {
    change(project);
    _changed();
  }

  Future<void> _switchTo(ProjectDoc p, {bool saveCurrent = true}) async {
    rememberArrangeView();  // the project being left keeps its zoom and scroll (#244)
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
    // Timber (removed in 1.1.3) as its new instruments: said once, in the notice line, when such a project opens.
    final hadTimber = p.layers.any((l) => l.instrument?.id == timberId);
    if (engine != null) p.resolveInstruments(Engine.resolveInstrument);
    // The retired effect ids as their merged devices (FX consolidation, 1.0.8), with their lanes, links and MIDI
    // mappings: one load step, not an undo step, like the instruments above.
    if (engine != null) p.resolveComponents(Engine.resolveComponent);
    // A path the project names that isn't a plain local one (a network share, a device or URL) becomes a missing
    // file before the engine or the missing-files check could look at it (project_dependencies.dart).
    try {
      final audio = _storage?.audioDirectory(p.id).path ??
          '${Directory.systemTemp.path}${Platform.pathSeparator}caw-audio${Platform.pathSeparator}${p.id}';
      quarantineUnsafePaths(p, '$audio${Platform.pathSeparator}missing');
    } on ArgumentError {
      // An id storage refuses has no folder; its paths stay as they are and the engine refuses the project.
    }
    // A project with no file yet is being made now: it records when (an old one without the field stays unknown).
    if (p.created == null && !(await _storage?.has(p.id) ?? true)) p.created = DateTime.now().toUtc();
    dropMissingFreezes(p);
    _spent
      ..reset()
      ..start();
    EasterEggs.instance.streakBroken();
    project = p;
    openError = null;
    openNotice = switch (p.droppedModules) {
      [] => hadTimber ? timberNotice : null,
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
    if (savedArrangeView case final view?) applyArrangeView?.call(view);
    await _syncNow();
    unawaited(prepareNativeComponents());
    // Linked sample files first (their paths on this device), then what is still missing (sample_use.dart).
    unawaited(resolveLinkedSamples().catchError((_) {}).then((_) => checkMissingFiles()));
    unawaited(purgeFrozenAudio());
  }
}
