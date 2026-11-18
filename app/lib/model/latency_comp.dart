// Output and input latency compensation (owner, 2026-11-11; #236): the platform's figure plus a saved offset per
// device (preset by its kind, typed in, slid while listening, tapped along, found by the loopback ping series or
// learned from takes and accepted), the tap-along median, and a timeline of meter reads shown when they are heard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../platform/audio_route.dart';
import 'atomic_file.dart';

/// What a device of each kind is expected to add in all, in ms, before anything is measured. [Assumption] typical
/// figures, not measured on the owner's devices: A2DP Bluetooth about 150 to 250 ms (published phone tests range
/// from about 150 to over 400 ms; docs/decisions.md), Bluetooth LE Audio less, HDMI a TV's processing, casting
/// most of a second; a phone's speaker, a wired jack and USB are what the platform reports.
double presetOutputMs(AudioDeviceKind kind) => switch (kind) {
      AudioDeviceKind.bluetooth => 200,
      AudioDeviceKind.bluetoothLe => 100,
      AudioDeviceKind.hdmi => 60,
      AudioDeviceKind.remote => 800,
      AudioDeviceKind.usb => 10,
      _ => 0,
    };

/// The same for inputs. [Assumption] a Bluetooth headset's microphone (SCO or LE) about 100 to 200 ms.
double presetInputMs(AudioDeviceKind kind) => switch (kind) {
      AudioDeviceKind.bluetooth => 150,
      AudioDeviceKind.bluetoothLe => 100,
      AudioDeviceKind.usb => 10,
      _ => 0,
    };

/// How a saved offset was set.
enum OffsetSource { preset, typed, slider, tapped, loopback, learned }

/// The least an offset may be: below what the platform reports (a platform figure that counts too much), to
/// [maxOffsetMs] above it.
const minOffsetMs = -500.0, maxOffsetMs = 2000.0;

/// One device's offset: the ms it adds on top of what the platform reports, and that figure when it was set
/// ([platformMs]; null for an older file), so a platform figure that moves a lot since asks for a check, and where
/// that figure came from ([platformSource]: SideLatency.source, "timestamp", "buffers" or "none"; null for an older
/// file).
class DeviceOffset {
  const DeviceOffset(this.extraMs, this.source, {this.platformMs, this.platformSource});
  final double extraMs;
  final OffsetSource source;
  final double? platformMs;
  final String? platformSource;

  /// Set over a figure that was only an estimate (the queued buffers before the first timestamp, or no device
  /// running): what it adds is not known, so the total heard as right is what stands (#241).
  bool get overEstimate => platformMs != null && platformSource != null && platformSource != 'timestamp';

  Map<String, dynamic> toJson() => {'extra_ms': extraMs, 'source': source.name,
        if (platformMs != null) 'platform_ms': platformMs, if (platformSource != null) 'platform_source': platformSource};

  static DeviceOffset? fromJson(Object? o) {
    if (o is! Map || o['extra_ms'] is! num || !(o['extra_ms'] as num).isFinite) return null;
    final p = o['platform_ms'], ps = o['platform_source'];
    return DeviceOffset((o['extra_ms'] as num).toDouble().clamp(minOffsetMs, maxOffsetMs).toDouble(),
        OffsetSource.values.where((s) => s.name == o['source']).firstOrNull ?? OffsetSource.typed,
        platformMs: p is num && p.isFinite ? p.toDouble().clamp(0, maxOffsetMs).toDouble() : null,
        platformSource: const {'timestamp', 'buffers', 'none'}.contains(ps) ? ps as String : null);
  }
}

/// How far a device's recorded notes landed from the beat, in ms (positive: late), over its takes: the evidence
/// a suggested correction rests on. At most [cap] deviations are kept, the newest.
class TimingEvidence {
  TimingEvidence();
  static const cap = 256;
  int takes = 0;
  final List<double> ms = [];

  void add(List<double> deviations) {
    if (deviations.isEmpty) return;
    takes++;
    ms.addAll(deviations.where((d) => d.isFinite));
    if (ms.length > cap) ms.removeRange(0, ms.length - cap);
  }

  Map<String, dynamic> toJson() => {'takes': takes, 'ms': ms};

  static TimingEvidence? fromJson(Object? o) {
    if (o is! Map || o['takes'] is! num || o['ms'] is! List) return null;
    final e = TimingEvidence()..takes = (o['takes'] as num).toInt().clamp(0, 1 << 20);
    for (final v in (o['ms'] as List).take(cap)) {
      if (v is num && v.isFinite) e.ms.add(v.toDouble().clamp(-1000, 1000).toDouble());
    }
    return e;
  }
}

/// The saved offsets, per output and input device key (AudioEndpoint.key), in `latency.json` beside settings.json
/// (in memory without a folder).
class LatencyStore {
  LatencyStore([this.file]);
  final File? file;

  bool enabled = true;
  final Map<String, DeviceOffset> outputs = {}, inputs = {};

  /// Per output device: how its takes landed against the beat (learning from recordings).
  final Map<String, TimingEvidence> evidence = {};

  Map<String, dynamic> toJson() => {
        'version': 1,
        'enabled': enabled,
        'outputs': {for (final e in outputs.entries) e.key: e.value.toJson()},
        'inputs': {for (final e in inputs.entries) e.key: e.value.toJson()},
        'evidence': {for (final e in evidence.entries) e.key: e.value.toJson()},
      };

  void fromJson(Map<String, dynamic> j) {
    enabled = j['enabled'] != false;
    void read(Object? o, Map<String, DeviceOffset> into) {
      into.clear();
      if (o is! Map) return;
      for (final e in o.entries) {
        final v = DeviceOffset.fromJson(e.value);
        if (e.key is String && v != null && into.length < 256) into[e.key as String] = v;
      }
    }

    read(j['outputs'], outputs);
    read(j['inputs'], inputs);
    evidence.clear();
    final ev = j['evidence'];
    if (ev is Map) {
      for (final e in ev.entries) {
        final v = TimingEvidence.fromJson(e.value);
        if (e.key is String && v != null && evidence.length < 64) evidence[e.key as String] = v;
      }
    }
  }

  Future<void> load() async {
    try {
      final f = file;
      if (f != null && await f.exists()) fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Unreadable: the presets.
    }
  }

  // Saves run one after another: two writes sharing the temporary file could interleave and leave a broken or
  // older file behind. Each queued save writes the offsets as they are when its turn comes, so the last wins.
  Future<void> _saving = Future.value();

  Future<void> save() => _saving = _saving.then((_) => _write());

  Future<void> _write() async {
    final f = file;
    if (f == null) return;
    try {
      await writeFileAtomically(f, jsonEncode(toJson()));
    } catch (_) {
      // A full disk keeps the offsets for this session only.
    }
  }
}

/// The median of [values] (null when empty).
double? median(List<double> values) {
  if (values.isEmpty) return null;
  final s = [...values]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// Tap-along: each tap's render position in sixteenth steps (where the engine was when the finger came down, from
/// caw_engine_position_at) against the beat it answers. The beat was rendered on a whole beat and heard the output
/// latency later, so a tap's lead past its beat is that latency. A tap up to a quarter beat early still counts as
/// answering the beat after it. Returns the median in ms at [bpm] (null with fewer than [minTaps]).
double? tapAlongMs(List<double> tapSteps, {required double bpm, double stepsPerBeat = 4, int minTaps = 4}) {
  if (tapSteps.length < minTaps || bpm <= 0) return null;
  final msPerStep = 15000 / bpm;
  final lead = [
    for (final t in tapSteps)
      () {
        var phase = t % stepsPerBeat;
        if (phase > stepsPerBeat * 0.75) phase -= stepsPerBeat;
        return phase * msPerStep;
      }(),
  ];
  return median(lead);
}

/// The loopback ping series' verdict: reliable when at least [minHeard] of the runs were heard and every heard one
/// lies within the tolerance of their median ([toleranceMs], or [toleranceShare] of the median when that is more).
class PingSeries {
  const PingSeries({required this.runs, required this.heard, this.ms, this.spreadMs = 0, this.reliable = false,
      this.toleranceMs = 0});
  final int runs, heard;

  /// The median round trip of the heard runs (null: none heard).
  final double? ms;

  /// The farthest a heard run lay from the median, and how far it was allowed to.
  final double spreadMs, toleranceMs;
  final bool reliable;
}

/// How many pings a measurement plays, and the agreement asked of them (#236: several runs that must agree).
/// **[Assumption]** a cable or a quiet room repeats within a couple of ms; Bluetooth's link wanders more, which the
/// share allows for (9 ms at 300 ms).
const pingRuns = 5, pingMinHeard = 4, pingToleranceMs = 3.0, pingToleranceShare = 0.03;

/// Judges a series of ping results in ms (null: that run was not heard clearly).
PingSeries judgePings(List<double?> results,
    {int minHeard = pingMinHeard, double toleranceMs = pingToleranceMs, double toleranceShare = pingToleranceShare}) {
  final heard = [for (final r in results) if (r != null && r.isFinite && r >= 0) r];
  final m = median(heard);
  if (m == null) return PingSeries(runs: results.length, heard: 0);
  final spread = heard.map((v) => (v - m).abs()).reduce(math.max);
  final tol = math.max(toleranceMs, m * toleranceShare);
  return PingSeries(runs: results.length, heard: heard.length, ms: m, spreadMs: spread, toleranceMs: tol,
      reliable: heard.length >= minHeard && spread <= tol);
}

/// What went wrong with an unreliable series, in one line for the user.
String pingSeriesProblem(PingSeries p) => p.heard < math.min(pingMinHeard, p.runs)
    ? 'Unreliable: only ${p.heard} of ${p.runs} pings were heard clearly. Nothing was saved; try again, louder, '
        'or with a cable.'
    : 'Unreliable: the pings disagreed by up to ${p.spreadMs.toStringAsFixed(1)} ms (allowed '
        '${p.toleranceMs.toStringAsFixed(1)}). Nothing was saved; try a quieter room or a cable.';

/// How far each recorded note start in [onsetSteps] (sixteenth steps on the song) lies from its nearest beat (a
/// quarter note, where the click sounds), in ms at the tempo there ([bpmAt] of the step); only notes within
/// [windowMs] of a beat count (off-beat notes say nothing about the beat). Positive: late.
List<double> beatDeviationsMs(Iterable<double> onsetSteps, {required double Function(double step) bpmAt,
    double windowMs = 60}) {
  final out = <double>[];
  for (final s in onsetSteps) {
    if (!s.isFinite) continue;
    final bpm = bpmAt(s);
    if (!(bpm > 0)) continue;
    final ms = (s - (s / 4).round() * 4) * 15000 / bpm;
    if (ms.abs() <= windowMs) out.add(ms);
  }
  return out;
}

/// A correction the takes suggest for the routed output: its total output latency would become [totalMs] (now
/// [fromMs]), from [onsets] notes over [takes] takes landing a median [shiftMs] off the beat.
class LatencySuggestion {
  const LatencySuggestion({required this.fromMs, required this.totalMs, required this.shiftMs, required this.onsets,
      required this.takes});
  final double fromMs, totalMs, shiftMs;
  final int onsets, takes;
}

/// What counts as enough evidence (#236: suggest after enough evidence, never apply silently). **[Assumption]**
/// a player's own spread is 10 to 30 ms; a median shift of 8 ms or more over 24 notes from 3 takes, with at least
/// 70 % of them on the same side, is more than playing style.
const learnMinTakes = 3, learnMinOnsets = 24, learnMinShiftMs = 8.0, learnAgreeShare = 0.7;

/// The suggestion [e] supports for an output at [currentMs] in all, or null when the evidence is not enough.
LatencySuggestion? suggestFrom(TimingEvidence? e, double currentMs) {
  if (e == null || e.takes < learnMinTakes || e.ms.length < learnMinOnsets) return null;
  final m = median(e.ms)!;
  if (m.abs() < learnMinShiftMs) return null;
  final agree = e.ms.where((v) => v.sign == m.sign).length / e.ms.length;
  if (agree < learnAgreeShare) return null;
  final shift = m.roundToDouble();
  return LatencySuggestion(fromMs: currentMs, totalMs: math.max(0, currentMs + shift), shiftMs: shift,
      onsets: e.ms.length, takes: e.takes);
}

/// One meter read, at [us] on the app's clock.
class MeterReading {
  const MeterReading(this.us, this.meters, this.layers);
  final int us;
  final EngineMeters meters;
  final List<LayerMeterValue> layers;
}

/// The last few seconds of meter readings, so a meter can show the one that is being heard now.
class MeterTimeline {
  MeterTimeline({this.capacity = 256});
  final int capacity;
  final List<MeterReading> _r = [];

  void push(MeterReading r) {
    if (_r.isNotEmpty && r.us < _r.last.us) _r.clear(); // the clock went back (tests): start again
    _r.add(r);
    if (_r.length > capacity) _r.removeRange(0, _r.length - capacity);
  }

  void clear() => _r.clear();

  MeterReading? get newest => _r.lastOrNull;

  /// The newest reading taken at or before [us]; null when every reading is newer (nothing of them heard yet).
  MeterReading? at(int us) {
    for (var i = _r.length - 1; i >= 0; i--) {
      if (_r[i].us <= us) return _r[i];
    }
    return null;
  }

  /// The reading whose span holds [us]: a read stands for what was rendered since the read before it, so this is
  /// the first one taken at or after [us] (the newest when [us] is past it). Null when [us] lies before the first
  /// kept read's span (taken as [spanUs] long): nothing of it is heard yet.
  MeterReading? covering(int us, {int spanUs = 33000}) {
    if (_r.isEmpty) return null;
    if (us >= _r.last.us) return _r.last;
    var lo = 0, hi = _r.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_r[mid].us >= us) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    if (lo == 0 && us <= _r.first.us - spanUs) return null;
    return _r[lo];
  }
}

/// The compensation in force: the routed devices, the platform's figure for each side and each device's offset.
class LatencyComp extends ChangeNotifier {
  LatencyComp({LatencyStore? store, AudioRoute? route, this.readDevice, this.recheckDelay = const Duration(seconds: 2)})
      : store = store ?? LatencyStore(),
        route = route ?? const NamedAudioRoute() {
    _sub = this.route.changes.listen((_) => unawaited(_routeMoved()));
  }

  /// After a device change, how long until the platform's figure is read again (a Bluetooth link settles after it
  /// connects).
  final Duration recheckDelay;
  Timer? _recheck;

  Future<void> _routeMoved() async {
    await refresh();
    _recheck?.cancel();
    _recheck = Timer(recheckDelay, () => unawaited(refresh()));
  }

  final LatencyStore store;
  final AudioRoute route;

  /// The running device's latency (the engine's caw_audio_latency); null without an engine.
  DeviceLatency Function()? readDevice;

  /// The names the engine's device opened with (desktop routes go by them).
  String Function()? outputName, inputName;

  /// The output's callback size in frames (caw_audio_status' period_frames; null or 0: not known).
  int Function()? callbackFrames;

  // The last few timestamp figures for the routed output (ms), and the callback size then.
  final List<double> _stamps = [];
  int _frames = 0;

  /// How many timestamp figures the system figure is the median of.
  static const stampRuns = 9;

  StreamSubscription<void>? _sub;
  AudioRouteInfo routeInfo = const AudioRouteInfo();
  DeviceLatency device = const DeviceLatency();

  /// The output device the last loopback ping was made through (the ping's split holds for it).
  String? pingOutputKey;

  /// The output before the last device change while sound ran (the slider sheet says what changed); null at first.
  AudioEndpoint? previousOutput;

  Future<void> load() async {
    await store.load();
    notifyListeners();
  }

  /// Reads the platform's figure and the route again: after the device opens, on a route change and now and then
  /// while playing.
  Future<void> refresh() async {
    final d = readDevice?.call() ?? const DeviceLatency();
    final info = await route.current(AudioRouteHint(outputId: d.output.deviceId, inputId: d.input.deviceId,
        outputName: outputName?.call() ?? '', inputName: inputName?.call() ?? '', outputKind: d.output.kind,
        inputKind: d.input.kind));
    if (info.output.key != routeInfo.output.key && device.running) previousOutput = routeInfo.output;
    // A timestamp figure is read at a random point of the callback's cycle (#241), so it moves by up to a callback
    // from one read to the next: the median of the last few stands, started again on a new device or source.
    final frames = callbackFrames?.call() ?? 0;
    if (info.output.key != routeInfo.output.key || d.output.source != 'timestamp' || !d.output.running ||
        frames != _frames) {
      _stamps.clear();
    }
    _frames = frames;
    // A jump past a callback's jitter is a real change (a new codec, a reroute): it counts from now.
    final jitterMs = (d.sampleRate > 0 ? frames * 1000 / d.sampleRate : 0) + 5;
    if (_stamps.isNotEmpty && (d.output.ms - median(_stamps)!).abs() > jitterMs) _stamps.clear();
    if (d.output.source == 'timestamp' && d.output.running) {
      _stamps.add(d.output.ms);
      if (_stamps.length > stampRuns) _stamps.removeAt(0);
    }
    final changed = info.output != routeInfo.output || info.input != routeInfo.input ||
        (d.output.frames - device.output.frames).abs() > 48 || (d.input.frames - device.input.frames).abs() > 48 ||
        d.running != device.running;
    device = d;
    routeInfo = info;
    if (changed) notifyListeners();
  }

  bool get enabled => store.enabled;
  set enabled(bool on) {
    if (on == store.enabled) return;
    store.enabled = on;
    unawaited(store.save());
    notifyListeners();
  }

  /// The system's output figure in ms. From AAudio's timestamps it is how far the next frame to be written lies
  /// from the moment of the read, which comes at a random point between two callbacks: the median of the last few
  /// reads, less half a callback, is the delay from the moment a callback renders (what the playhead and
  /// recordings count from: caw_engine_position_at), with no callback's jitter in it (#241).
  double get platformOutputMs {
    final o = device.output;
    if (o.source != 'timestamp' || _stamps.isEmpty) return o.ms;
    final half = _frames > 0 && device.sampleRate > 0 ? _frames / 2 * 1000 / device.sampleRate : 0.0;
    return math.max(0.0, median(_stamps)! - half);
  }
  double get platformInputMs => device.input.running ? device.input.ms : 0;

  /// Where the platform's output figure comes from now (SideLatency.source; "none" with no device).
  String get platformOutputSource => device.output.running ? device.output.source : 'none';

  /// The offset saved for the routed output, else its kind's preset (what the preset expects beyond the platform).
  /// An offset set over an estimate keeps its total once the system's timestamps give the real figure: adding it to
  /// that figure would count the delay twice (#241: set to 200 ms while the buffers said 21, it read 300 once the
  /// timestamps said 121). Set over a timestamp it rides on the figure (a new codec), and the re-check asks.
  DeviceOffset get outputOffset {
    final o = store.outputs[routeInfo.output.key];
    if (o == null) {
      return DeviceOffset(math.max(0, presetOutputMs(routeInfo.output.kind) - platformOutputMs), OffsetSource.preset);
    }
    if (o.overEstimate && platformOutputSource == 'timestamp') {
      return DeviceOffset(_extra(o.platformMs! + o.extraMs, platformOutputMs), o.source,
          platformMs: o.platformMs, platformSource: o.platformSource);
    }
    return o;
  }
  DeviceOffset get inputOffset => store.inputs[routeInfo.input.key] ??
      DeviceOffset(math.max(0, presetInputMs(routeInfo.input.kind) - platformInputMs), OffsetSource.preset);

  /// What the routed output adds in all, compensation on or off (the slider's value).
  double get outputTotalMs => math.max(0, platformOutputMs + outputOffset.extraMs);

  /// From a sample leaving the engine to the ear, in ms (0 with compensation off).
  double get outputMs => enabled ? outputTotalMs : 0;

  /// From the microphone to the engine reading it, in ms (0 with compensation off or no input).
  double get inputMs => enabled ? math.max(0, platformInputMs + inputOffset.extraMs) : 0;

  /// The routed output is Bluetooth: it adds a delay of its own that no app can remove.
  bool get outputIsBluetooth => routeInfo.output.kind.isBluetooth;

  /// How far the platform's figure for the routed output may move from what it was when its offset was set before
  /// the offset asks for a check (a new codec or link mode changes the delay). **[Assumption]** 15 ms.
  static const recheckMs = 15.0;

  /// The routed output's saved offset was set while the platform reported a figure more than [recheckMs] away
  /// from today's: its total may be off now.
  bool get outputNeedsCheck {
    final o = store.outputs[routeInfo.output.key];
    final then = o?.platformMs;
    if (o == null || then == null || !device.output.running) return false;
    // Set over an estimate, the total stands: only a real figure set over a real figure asks.
    if (o.overEstimate) return false;
    return (platformOutputMs - then).abs() > recheckMs;
  }

  int framesOf(double ms, int sampleRate) => (ms * sampleRate / 1000).round();

  /// The badge: the output adds more than 50 ms, so playing live and monitoring will feel late.
  bool get outputIsLate => enabled && outputMs > 50;

  static double _extra(double totalMs, double platformMs) =>
      (totalMs.clamp(0, maxOffsetMs) - platformMs).clamp(minOffsetMs, maxOffsetMs).toDouble();

  /// Sets what the routed output adds in all (ms heard after the engine renders), keeping the platform's part;
  /// [save] false keeps it in memory (a slider drag saves once it ends, [saveNow]).
  void setOutputTotalMs(double totalMs, {OffsetSource source = OffsetSource.typed, bool save = true}) {
    if (!totalMs.isFinite) return;
    store.outputs[routeInfo.output.key] = DeviceOffset(_extra(totalMs, platformOutputMs), source,
        platformMs: platformOutputMs, platformSource: platformOutputSource);
    if (save) unawaited(store.save());
    notifyListeners();
  }

  /// Moves the routed output's total by [deltaMs] (the slider sheet's ±1 ms).
  void nudgeOutput(double deltaMs) =>
      setOutputTotalMs((outputTotalMs + deltaMs).roundToDouble(), source: OffsetSource.slider);

  /// Saves the offsets now (after a slider drag).
  Future<void> saveNow() => store.save();

  void setInputTotalMs(double totalMs, {OffsetSource source = OffsetSource.typed}) {
    if (!totalMs.isFinite) return;
    store.inputs[routeInfo.input.key] =
        DeviceOffset(_extra(totalMs, platformInputMs), source, platformMs: platformInputMs);
    unawaited(store.save());
    notifyListeners();
  }

  /// Back to the kind's preset.
  void resetOutput() {
    if (store.outputs.remove(routeInfo.output.key) != null) unawaited(store.save());
    notifyListeners();
  }

  void resetInput() {
    if (store.inputs.remove(routeInfo.input.key) != null) unawaited(store.save());
    notifyListeners();
  }

  /// A good loopback ping of [roundTripMs] (speaker to microphone through the engine): what the output's offset
  /// does not explain is the input's.
  void splitPing(double roundTripMs) {
    pingOutputKey = routeInfo.output.key;
    setInputTotalMs(math.max(0, roundTripMs - outputTotalMs), source: OffsetSource.loopback);
  }

  /// A finished ping series: a reliable one is split as [splitPing] does, from its median (the engine's own
  /// measurement is its last run, so the app's round trip, the median, is what recordings use: [pingOutputKey]
  /// stays clear); an unreliable one is not saved, and an earlier ping through this output no longer stands.
  void applyPingSeries(PingSeries p) {
    pingOutputKey = null;
    if (p.reliable && p.ms != null) {
      setInputTotalMs(math.max(0, p.ms! - outputTotalMs), source: OffsetSource.loopback);
    } else {
      notifyListeners();
    }
  }

  /// Learning from recordings: the deviations of one take's notes from the beat ([beatDeviationsMs]), kept for
  /// the routed output. Nothing changes until the user accepts [outputSuggestion].
  void learnFromTake(List<double> deviationsMs) {
    if (deviationsMs.isEmpty) return;
    (store.evidence[routeInfo.output.key] ??= TimingEvidence()).add(deviationsMs);
    unawaited(store.save());
    notifyListeners();
  }

  /// The correction the routed output's takes suggest, once there is enough evidence (with compensation on).
  LatencySuggestion? get outputSuggestion => enabled ? suggestFrom(store.evidence[routeInfo.output.key], outputTotalMs) : null;

  /// Takes the suggestion: the output's total moves by its shift, and the evidence starts again.
  void acceptSuggestion() {
    final s = outputSuggestion;
    if (s == null) return;
    store.evidence.remove(routeInfo.output.key);
    setOutputTotalMs(s.totalMs, source: OffsetSource.learned);
  }

  /// Not now: the evidence starts again (a suggestion comes back only if new takes show it again).
  void dismissSuggestion() {
    if (store.evidence.remove(routeInfo.output.key) == null) return;
    unawaited(store.save());
    notifyListeners();
  }

  /// The round trip a recording is placed by: what you heard plus how late the microphone is.
  double get roundTripMs => outputMs + inputMs;

  @override
  void dispose() {
    _recheck?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
