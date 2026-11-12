// Output and input latency compensation (owner, 2026-11-11): the platform's figure plus a saved offset per device
// (preset by its kind, typed in, tapped along or found by the loopback ping), the tap-along median, and a short
// timeline of meter readings so what the screen shows can be read at the time it is heard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../platform/audio_route.dart';

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
enum OffsetSource { preset, typed, tapped, loopback }

/// One device's offset: the ms it adds on top of what the platform reports.
class DeviceOffset {
  const DeviceOffset(this.extraMs, this.source);
  final double extraMs;
  final OffsetSource source;

  Map<String, dynamic> toJson() => {'extra_ms': extraMs, 'source': source.name};

  static DeviceOffset? fromJson(Object? o) {
    if (o is! Map || o['extra_ms'] is! num) return null;
    return DeviceOffset((o['extra_ms'] as num).toDouble().clamp(0, 2000).toDouble(),
        OffsetSource.values.where((s) => s.name == o['source']).firstOrNull ?? OffsetSource.typed);
  }
}

/// The saved offsets, per output and input device key (AudioEndpoint.key), in `latency.json` beside settings.json
/// (in memory without a folder).
class LatencyStore {
  LatencyStore([this.file]);
  final File? file;

  bool enabled = true;
  final Map<String, DeviceOffset> outputs = {}, inputs = {};

  Map<String, dynamic> toJson() => {
        'version': 1,
        'enabled': enabled,
        'outputs': {for (final e in outputs.entries) e.key: e.value.toJson()},
        'inputs': {for (final e in inputs.entries) e.key: e.value.toJson()},
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
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      await tmp.rename(f.path);
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
}

/// The compensation in force: the routed devices, the platform's figure for each side and each device's offset.
class LatencyComp extends ChangeNotifier {
  LatencyComp({LatencyStore? store, AudioRoute? route, this.readDevice})
      : store = store ?? LatencyStore(),
        route = route ?? const NamedAudioRoute() {
    _sub = this.route.changes.listen((_) => unawaited(refresh()));
  }

  final LatencyStore store;
  final AudioRoute route;

  /// The running device's latency (the engine's caw_audio_latency); null without an engine.
  DeviceLatency Function()? readDevice;

  /// The names the engine's device opened with (desktop routes go by them).
  String Function()? outputName, inputName;

  StreamSubscription<void>? _sub;
  AudioRouteInfo routeInfo = const AudioRouteInfo();
  DeviceLatency device = const DeviceLatency();

  /// The output device the last loopback ping was made through (the ping's split holds for it).
  String? pingOutputKey;

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

  double get platformOutputMs => device.output.ms;
  double get platformInputMs => device.input.running ? device.input.ms : 0;

  /// The offset saved for the routed output, else its kind's preset (what the preset expects beyond the platform).
  DeviceOffset get outputOffset => store.outputs[routeInfo.output.key] ??
      DeviceOffset(math.max(0, presetOutputMs(routeInfo.output.kind) - platformOutputMs), OffsetSource.preset);
  DeviceOffset get inputOffset => store.inputs[routeInfo.input.key] ??
      DeviceOffset(math.max(0, presetInputMs(routeInfo.input.kind) - platformInputMs), OffsetSource.preset);

  /// From a sample leaving the engine to the ear, in ms (0 with compensation off).
  double get outputMs => enabled ? platformOutputMs + outputOffset.extraMs : 0;

  /// From the microphone to the engine reading it, in ms (0 with compensation off or no input).
  double get inputMs => enabled ? platformInputMs + inputOffset.extraMs : 0;

  int framesOf(double ms, int sampleRate) => (ms * sampleRate / 1000).round();

  /// The badge: the output adds more than 50 ms, so playing live and monitoring will feel late.
  bool get outputIsLate => enabled && outputMs > 50;

  /// Sets what the routed output adds in all (ms heard after the engine renders), keeping the platform's part.
  void setOutputTotalMs(double totalMs, {OffsetSource source = OffsetSource.typed}) {
    store.outputs[routeInfo.output.key] =
        DeviceOffset(math.max(0, totalMs - platformOutputMs).clamp(0, 2000).toDouble(), source);
    unawaited(store.save());
    notifyListeners();
  }

  void setInputTotalMs(double totalMs, {OffsetSource source = OffsetSource.typed}) {
    store.inputs[routeInfo.input.key] =
        DeviceOffset(math.max(0, totalMs - platformInputMs).clamp(0, 2000).toDouble(), source);
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
    final out = enabled ? outputMs : platformOutputMs + outputOffset.extraMs;
    setInputTotalMs(math.max(0, roundTripMs - out), source: OffsetSource.loopback);
  }

  /// The round trip a recording is placed by: what you heard plus how late the microphone is.
  double get roundTripMs => outputMs + inputMs;

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
