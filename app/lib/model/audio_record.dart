// Recording audio (API 18): the input choice and latency kept app-wide, opening the input after the microphone
// permission, recording the armed tracks with the transport's Record, takes placed as clips (a loop's passes stacked
// as takes), punch in/out, input meters, the latency ping and crash recovery.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/audio_engine.dart';
import '../platform/mic_permission.dart';
import 'app_state.dart';
import 'audio_clips.dart';
import 'audio_edit.dart';
import 'project.dart';
import 'atomic_file.dart';

/// Where punch in/out comes from: none, the loop range, or the time selection.
enum PunchMode { off, loop, selection }

/// The audio input choices, kept in `audio-input.json` beside settings.json (in memory without a folder).
class AudioInputPrefs {
  AudioInputPrefs([this.file]);
  final File? file;

  bool enabled = false;
  String deviceId = '', deviceName = '';

  /// How many device channels to open (1..32).
  int channels = 2;

  /// The latency in frames the user typed (-1: the ping's, else the device's).
  int latencyOverride = -1;
  PunchMode punch = PunchMode.off;

  /// 32 (float) or 24.
  int bits = 32;

  /// The user read the ping's warning once.
  bool pingWarned = false;

  Map<String, dynamic> toJson() => {
        'enabled': enabled, 'device_id': deviceId, 'device_name': deviceName, 'channels': channels,
        'latency_override': latencyOverride, 'punch': punch.name, 'bits': bits, 'ping_warned': pingWarned,
      };

  void fromJson(Map<String, dynamic> j) {
    enabled = j['enabled'] == true;
    deviceId = j['device_id'] is String ? (j['device_id'] as String) : '';
    deviceName = j['device_name'] is String ? (j['device_name'] as String) : '';
    channels = j['channels'] is num ? (j['channels'] as num).round().clamp(1, 32) : 2;
    latencyOverride = j['latency_override'] is num ? (j['latency_override'] as num).round().clamp(-1, 192000) : -1;
    punch = PunchMode.values.where((m) => m.name == j['punch']).firstOrNull ?? PunchMode.off;
    bits = j['bits'] == 24 ? 24 : 32;
    pingWarned = j['ping_warned'] == true;
  }

  Future<void> load() async {
    try {
      final f = file;
      if (f != null && await f.exists()) fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Unreadable: the defaults.
    }
  }

  Future<void> save() async {
    final f = file;
    if (f == null) return;
    try {
      await writeFileAtomically(f, jsonEncode(toJson()));
    } catch (_) {
      // A full disk keeps the choice for this session only.
    }
  }
}

/// What a finished recording did, for the toast (and its Undo).
class AudioRecording {
  const AudioRecording({required this.clipIds, required this.assetIds, required this.takes, this.droppedFrames = 0,
      this.error = '', this.recovered = false});
  final List<String> clipIds, assetIds;
  final int takes, droppedFrames;
  final String error;
  final bool recovered;
}

/// Records the armed audio tracks while the transport records (one per app, [current]).
class AudioRecorder extends ChangeNotifier {
  AudioRecorder(this.state, {MicPermission? permission, AudioInputPrefs? prefs})
      : permission = permission ?? const NoMicPrompt(),
        prefs = prefs ?? AudioInputPrefs(state.settings.dir == null
            ? null : File('${state.settings.dir!.path}${Platform.pathSeparator}audio-input.json')) {
    state.tick.addListener(_poll);
    state.latency.addListener(_applyLatency);
    state.addListener(_onState);
    state.foreground.addListener(_onState);
    micBusy.addListener(notifyListeners);
  }

  static AudioRecorder? current;

  final AppState state;
  final MicPermission permission;
  final AudioInputPrefs prefs;
  AudioIo get io => state.audioIo;

  bool _recording = false;
  bool get recording => _recording;

  /// Whether the input is open on the engine (it needs the permission, a device and something that uses it).
  bool inputOpen = false;

  /// Another app has the microphone (or the input stopped delivering): the output plays on, the input is silence,
  /// and the input is tried again quietly every [retryEvery] until it delivers (docs/app.md, Audio input).
  final micBusy = ValueNotifier<bool>(false);

  /// How often a busy input is checked and tried again.
  static Duration retryEvery = const Duration(seconds: 2);
  Timer? _health;
  bool _pinging = false;
  bool _wanted = false;
  bool _disposed = false;
  Future<void>? _inputQueue;  // the opens and closes in order; null until the first (made in the caller's zone)

  /// The last problem, in one line (permission refused, no input, a failed write), or null.
  final message = ValueNotifier<String?>(null);

  /// The last recording's result, for the "Keep take?" toast.
  final lastRecording = ValueNotifier<AudioRecording?>(null);

  /// Each input channel's level now (0..1+), refreshed with the meters while a track is armed.
  final levels = ValueNotifier<List<double>>(const []);
  final List<double> _hold = [];

  Future<void> load() async {
    await prefs.load();
    if (prefs.latencyOverride >= 0) io.setInputLatency(prefs.latencyOverride);
    _applyLatency();
  }

  // ---------- the input ----------

  /// Whether something uses the microphone now: an armed track, a track monitoring its input ("on"), a recording
  /// or the latency ping. Only then is it open (owner, 2026-11-12: never compete with other apps for it).
  bool get inputNeeded =>
      _recording || _starting || _pinging ||
      state.project.layers.any((l) => !l.isFolder && l.input != null && (l.input!.armed || l.input!.monitor == 'on'));

  /// Open while the input is on, something uses it and the app is in front (a recording keeps it in the
  /// background too; Android gives a background app silence anyway).
  bool get _wantInput => prefs.enabled && inputNeeded && (state.foreground.value || _recording);

  /// Turns audio input on (asking for the microphone first, on Android) and opens it if something uses it now
  /// ([force]: the caller is about to). False when refused or when it did not open; [message] says why.
  Future<bool> openInput({bool force = false}) async {
    if (!await permission.request()) {
      message.value = 'Microphone permission refused: audio input stays off (allow it in the system settings).';
      inputOpen = false;
      notifyListeners();
      return false;
    }
    if (!prefs.enabled) {
      prefs.enabled = true;
      unawaited(prefs.save());
    }
    if (!force && !inputNeeded) {
      _wanted = _wantInput;
      notifyListeners();
      return true;  // on, and it opens when a track is armed or monitors
    }
    final ok = await _open();
    _wanted = _wantInput || force;
    notifyListeners();
    return ok;
  }

  // Opens the engine's input (the permission is granted). True when it opened, or when only the microphone is busy
  // (it is tried again quietly); false, with [message], otherwise.
  Future<bool> _open() async {
    final r = await io.configureInput(enabled: true, deviceId: prefs.deviceId, deviceName: prefs.deviceName,
        channels: prefs.channels);
    if (prefs.latencyOverride >= 0) io.setInputLatency(prefs.latencyOverride);
    _compensated = -1; // a reopened input: the round trip is worked out again
    unawaited(state.latency.refresh().then((_) => _applyLatency()));
    inputOpen = r != 1;
    final status = io.inputStatus();
    final failed = status.isNotEmpty && status['running'] == false && state.engine?.audioOn == true;
    if (failed) {
      // With the permission granted, an input that does not open is held by another app (or gone): the output
      // plays on, and it is tried again quietly. [inputOpen] stays true, as the engine keeps it asked for.
      micBusy.value = true;
    } else {
      await _checkHealth(retry: false);
    }
    _watchHealth();
    return inputOpen;
  }

  // Closes the engine's input; audio input stays on (it opens again when something uses it).
  Future<void> _release() async {
    _health?.cancel();
    _health = null;
    micBusy.value = false;
    if (!inputOpen) return;
    await io.configureInput(enabled: false);
    inputOpen = false;
    if (!_disposed) notifyListeners();
  }

  /// Turns audio input off (Settings › Audio): the microphone closes and arming asks again.
  Future<void> closeInput() async {
    await _release();
    await io.configureInput(enabled: false);
    inputOpen = false;
    prefs.enabled = false;
    _wanted = false;
    unawaited(prefs.save());
    notifyListeners();
  }

  // The project, the transport or the lifecycle changed: open the input when something starts using it (only
  // with the permission already granted, so this never asks) and close it when nothing does.
  void _onState() {
    final want = _wantInput;
    if (want == _wanted) return;
    _wanted = want;
    final before = _inputQueue;
    _inputQueue = () async {
      if (before != null) await before;
      if (_disposed) return;
      if (_wantInput && !inputOpen) {
        if (await permission.granted()) await _open();
        notifyListeners();
      } else if (!_wantInput && inputOpen && !_recording && !_pinging) {
        await _release();
      }
    }();
  }

  /// Settles pending opens and closes (tests).
  Future<void> settled() => _inputQueue ?? Future<void>.value();

  void _watchHealth() {
    if (_health != null || !inputOpen) return;
    _health = Timer.periodic(retryEvery, (_) => unawaited(_checkHealth(retry: true)));
  }

  // Whether the input delivers: the engine's state ("stalled", "stopped", "failed": another app has the
  // microphone, or it was disconnected) or Android saying our capture is silenced. Busy and [retry]: asked again,
  // which reopens only the input (the output is never touched).
  bool _checking = false;
  Future<void> _checkHealth({required bool retry}) async {
    if (_checking || !inputOpen) return;
    _checking = true;
    try {
      if (_disposed) return;
      final st = io.inputStatus()['state'];
      final engineBusy = st == 'stalled' || st == 'stopped' || st == 'failed';
      final silenced = state.foreground.value && await permission.inputSilenced();
      if (_disposed) return;
      if (engineBusy && retry && state.foreground.value) {
        await io.configureInput(enabled: true, deviceId: prefs.deviceId, deviceName: prefs.deviceName,
            channels: prefs.channels);
        if (_disposed) return;
        final again = io.inputStatus()['state'];
        micBusy.value = again != 'open' || silenced;
      } else {
        micBusy.value = engineBusy || silenced;
      }
    } finally {
      _checking = false;
    }
  }

  /// A new input choice (Settings › Audio): saved, and the input reopens on it when it is on.
  Future<void> chooseInput({String? deviceId, String? deviceName, int? channels}) async {
    if (deviceId != null) prefs.deviceId = deviceId;
    if (deviceName != null) prefs.deviceName = deviceName;
    if (channels != null) prefs.channels = channels.clamp(1, 32);
    await prefs.save();
    if (prefs.enabled && inputOpen) await _open();
    notifyListeners();
  }

  /// Arms or disarms [layer] (an audio track): arming opens the input first, with the permission.
  Future<bool> arm(LayerDoc layer, bool on) async {
    if (on && !inputOpen && !await openInput(force: true)) return false;
    state.setAudioArmed(layer, on);
    notifyListeners();
    return true;
  }

  /// After the app made a new engine (start-up, a rate change) the input opens on it again: only when it was on
  /// and the permission is already granted, so start-up never asks.
  Future<void> reapply() async {
    _health?.cancel();
    _health = null;
    _wanted = _wantInput;
    if (_wanted && await permission.granted()) await _open();
    notifyListeners();
  }

  Object? _engine;

  void _poll() {
    final e = state.engine;
    if (!identical(e, _engine)) {
      _engine = e;
      inputOpen = false;
      if (e != null) unawaited(reapply());
    }
    if (state.armedAudioTracks.isEmpty && !_recording) {
      if (levels.value.isNotEmpty) levels.value = const [];
      return;
    }
    final now = io.inputPeaks();
    // A short hold, so a peak stays visible for a few frames.
    while (_hold.length < now.length) {
      _hold.add(0);
    }
    for (var i = 0; i < now.length; i++) {
      _hold[i] = math.max(now[i], _hold[i] * 0.85);
    }
    levels.value = List.unmodifiable(_hold.take(now.length));
  }

  /// [layer]'s input level (the louder of its channels).
  double levelOf(LayerDoc layer) {
    final i = layer.input;
    final l = levels.value;
    if (i == null || i.channel >= l.length) return 0;
    return i.channels == 2 && i.channel + 1 < l.length ? math.max(l[i.channel], l[i.channel + 1]) : l[i.channel];
  }

  // ---------- recording ----------

  /// The punch range in steps from [prefs.punch], or null.
  (double, double)? get punchRange {
    final p = state.project;
    switch (prefs.punch) {
      case PunchMode.off:
        return null;
      case PunchMode.loop:
        return p.hasLoopRange ? (p.loopStartSteps.toDouble(), p.loopEndSteps.toDouble()) : null;
      case PunchMode.selection:
        final a = state.timeSelectionStart, b = state.timeSelectionEnd;
        if (a == null || b == null || a == b) return null;
        return (math.min(a, b).toDouble(), math.max(a, b).toDouble());
    }
  }

  /// The engine's request for the armed tracks (docs/engine.md "Audio input and recording").
  Map<String, dynamic> request(Directory dir) => {
        'dir': dir.path,
        'bpm': state.project.bpm,
        'bits': prefs.bits,
        'tracks': [
          for (final l in state.armedAudioTracks) {'layer': l.id, 'channel': l.input!.channel, 'channels': l.input!.channels},
        ],
        if (punchRange case (final a, final b)) ...{'punch_in_steps': a, 'punch_out_steps': b},
      };

  /// Starts recording the armed audio tracks (the transport's Record calls it). False when none is armed or the
  /// engine refused; [message] says why.
  Future<bool> start() async {
    if (_recording || state.armedAudioTracks.isEmpty) return false;
    if (!inputOpen && !await openInput(force: true)) return false;
    final dir = state.recordingsDirectory;
    await dir.create(recursive: true);
    final r = await io.recordStart(request(dir));
    if (!r.ok) {
      message.value = 'Recording did not start: ${r.error}';
      return false;
    }
    _recording = true;
    notifyListeners();
    return true;
  }

  /// Stops recording and places the takes. Returns what it placed.
  Future<AudioRecording?> stop() async {
    if (!_recording) return null;
    _recording = false;
    notifyListeners();
    final r = await io.recordStop();
    final placed = placeTakes(r.takes, droppedFrames: r.droppedFrames, error: r.error);
    lastRecording.value = placed;
    if (r.droppedFrames > 0) {
      message.value = '${r.droppedFrames} frames were dropped while recording (filled with silence; the device was busy).';
    }
    return placed;
  }

  /// Follows the transport's Record button ([LiveMidi]): starts with it and stops with it.
  void follow(Listenable transport, bool Function() isRecording) {
    transport.addListener(() {
      final on = isRecording();
      if (on && !_recording && !_starting) {
        _starting = true;
        start().whenComplete(() => _starting = false);
      } else if (!on && _recording) {
        unawaited(stop());
      }
    });
  }

  bool _starting = false;

  /// Takes as clips on their tracks: the passes of a loop recording (several takes of a track at one start) become
  /// one clip whose takes they are, playing the newest; others a clip each. A take the latency put before the
  /// song's start is trimmed to start at 0. One undo step.
  AudioRecording placeTakes(List<RecordedAudioTake> takes, {int droppedFrames = 0, String error = '', bool recovered = false}) {
    final p = state.project;
    final clipIds = <String>[], assetIds = <String>[];
    final byLayer = <String, List<RecordedAudioTake>>{};
    for (final t in takes) {
      if (t.frames <= 0 && t.seconds <= 0) continue;
      byLayer.putIfAbsent(t.layer, () => []).add(t);
    }
    if (byLayer.isEmpty) return AudioRecording(clipIds: const [], assetIds: const [], takes: 0, error: error);
    state.endUndoStep();
    state.editProject((_) {
      for (final MapEntry(key: layerId, value: list) in byLayer.entries) {
        list.sort((a, b) => a.take.compareTo(b.take));
        var layer = p.layers.where((l) => l.id == layerId && !l.isFolder).firstOrNull;
        if (layer == null) {
          layer = LayerDoc(id: newId('l'), name: 'Recovered audio', color: p.layers.length % LayerDoc.trackColors,
              volume: 1, input: AudioInputDoc());
          p.layers.add(layer);
        }
        final made = <(RecordedAudioTake, AudioAssetDoc)>[];
        for (final t in list) {
          final asset = AudioAssetDoc(id: newId('a'), path: t.path, name: '${layer.name} take ${t.take}',
              seconds: t.seconds > 0 ? t.seconds : (t.sampleRate > 0 ? t.frames / t.sampleRate : 0),
              channels: t.channels, sourceRate: t.sampleRate, recorded: true);
          p.assets.add(asset);
          assetIds.add(asset.id);
          made.add((t, asset));
        }
        // Takes that start at the same place are passes of one loop: one clip, its takes.
        final groups = <int, List<(RecordedAudioTake, AudioAssetDoc)>>{};
        for (final m in made) {
          groups.putIfAbsent(m.$1.startFrame, () => []).add(m);
        }
        for (final g in groups.values) {
          final (t, a) = g.last;
          final clip = clipForTake(id: newId('ac'), assetId: a.id, startSteps: t.startSteps, seconds: a.seconds,
              bpm: t.bpm > 0 ? t.bpm : p.bpm);
          if (g.length > 1) clip.takes = [for (final (_, x) in g) x.id];
          layer.audioClips.add(clip);
          clipIds.add(clip.id);
        }
      }
    });
    state.endUndoStep();
    return AudioRecording(clipIds: clipIds, assetIds: assetIds, takes: takes.length, droppedFrames: droppedFrames,
        error: error, recovered: recovered);
  }

  /// The toast's Undo: the recording's clips and assets go (their files stay until the project is deleted).
  void discard(AudioRecording r) {
    state.editProject((p) {
      for (final l in p.layers) {
        l.audioClips.removeWhere((c) => r.clipIds.contains(c.id));
      }
      p.assets.removeWhere((a) => r.assetIds.contains(a.id));
    });
    if (identical(lastRecording.value, r)) lastRecording.value = null;
  }

  /// Takes a crash left unfinished in the project's recordings folder, fixed up by the engine; empty when none.
  Future<List<RecordedAudioTake>> recover() async {
    final dir = state.recordingsDirectory;
    if (!dir.existsSync()) return const [];
    final r = await io.recover(dir.path);
    final known = {for (final a in state.project.assets) a.path};
    return [for (final t in r.takes) if (!known.contains(t.path)) t];
  }

  // ---------- latency ----------

  /// The round trip takes are placed by. "compensated": the output's latency (Bluetooth included, Settings › Audio ›
  /// Latency) plus the input's, sent because it says more than the engine's own estimate.
  LatencyInfo get latency {
    final l = io.inputLatency();
    if (_compensated < 0 || prefs.latencyOverride >= 0) return l;
    return LatencyInfo(frames: l.frames, ms: l.ms, source: 'compensated', override: -1, measured: l.measured,
        device: l.device);
  }

  int _compensated = -1;

  /// Sends the round trip recordings are placed by: a typed one stands; a ping made through the output in use
  /// stands (it heard the whole trip); else the output latency plus the input latency (Settings › Audio › Latency),
  /// when that is more than the engine's estimate of its buffers (a Bluetooth output or microphone).
  void _applyLatency() {
    if (prefs.latencyOverride >= 0) return;
    final comp = state.latency;
    final l = io.inputLatency();
    final measured = l.measured >= 0;
    final pinged = measured && comp.pingOutputKey == comp.routeInfo.output.key;
    final frames = comp.framesOf(comp.roundTripMs, state.engine?.sampleRate ?? 48000);
    final own = l.device;
    final use = comp.enabled && !pinged && (measured || frames > own);
    if (!use) {
      if (_compensated >= 0) {
        _compensated = -1;
        io.setInputLatency(-1);
        notifyListeners();
      }
      return;
    }
    final f = math.max(frames, 0);
    if (f == _compensated) return;
    _compensated = f;
    io.setInputLatency(f);
    notifyListeners();
  }

  /// A typed latency in milliseconds (null: back to the ping's, else the device's).
  void setLatencyMs(double? ms) {
    final rate = state.engine?.sampleRate ?? 48000;
    prefs.latencyOverride = ms == null ? -1 : (ms * rate / 1000).round().clamp(0, rate * 2);
    io.setInputLatency(prefs.latencyOverride);
    _compensated = -1;
    _applyLatency();
    unawaited(prefs.save());
    notifyListeners();
  }

  /// Plays the ping and waits for its answer (about a second). Null when it couldn't start.
  Future<PingResult?> ping({Duration poll = const Duration(milliseconds: 150), int tries = 20}) async {
    _pinging = true;
    try {
      return await _ping(poll, tries);
    } finally {
      _pinging = false;
      _onState();  // nothing else uses it: the microphone closes again
    }
  }

  Future<PingResult?> _ping(Duration poll, int tries) async {
    if (!inputOpen && !await openInput(force: true)) return null;
    if (!io.pingStart()) return null;
    for (var i = 0; i < tries; i++) {
      await Future<void>.delayed(poll);
      final r = io.pingResult();
      if (r.done) {
        // A good ping becomes the latency in use unless one is typed in; what the output's latency does not explain
        // of it is the input's (Settings › Audio › Latency).
        if (r.ok) {
          state.latency.splitPing(r.ms);
          _applyLatency();
        }
        notifyListeners();
        return r;
      }
    }
    return const PingResult(state: 'done', ok: false);
  }

  @override
  void dispose() {
    state.tick.removeListener(_poll);
    state.latency.removeListener(_applyLatency);
    state.removeListener(_onState);
    state.foreground.removeListener(_onState);
    _disposed = true;
    _health?.cancel();
    micBusy.dispose();
    message.dispose();
    lastRecording.dispose();
    levels.dispose();
    super.dispose();
  }
}
