// The app's view of the engine's audio side (API 18, 32): assets, peaks, tempo and slices, SFZ, input, recording, latency. AudioIo is the
// interface the model talks to; EngineAudioIo calls the C API, long calls on a worker isolate.
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'audio_bindings.dart';
import 'engine.dart';

Map<String, dynamic> _map(String text) {
  try {
    final j = jsonDecode(text);
    return j is Map<String, dynamic> ? j : const {};
  } catch (_) {
    return const {};
  }
}

double _d(Object? v, [double or = 0]) => v is num && v.isFinite ? v.toDouble() : or;
int _i(Object? v, [int or = 0]) => v is num && v.isFinite ? v.toInt() : or;
String _s(Object? v) => v is String ? v : '';

/// What `caw_asset_load` reported about a file.
class AssetInfo {
  const AssetInfo({required this.ok, this.error = '', this.path = '', this.frames = 0, this.channels = 0,
      this.sampleRate = 0, this.sourceRate = 0, this.sourceChannels = 0, this.seconds = 0});
  final bool ok;
  final String error, path;
  final int frames, channels, sampleRate, sourceRate, sourceChannels;
  final double seconds;

  static AssetInfo fromJson(Map<String, dynamic> j) => AssetInfo(
        ok: j['ok'] == true, error: _s(j['error']), path: _s(j['path']), frames: _i(j['frames']),
        channels: _i(j['channels']), sampleRate: _i(j['sample_rate']), sourceRate: _i(j['source_rate']),
        sourceChannels: _i(j['source_channels']), seconds: _d(j['seconds']));
}

/// One capture device (`caw_audio_input_devices`).
class InputDeviceInfo {
  const InputDeviceInfo({required this.name, this.id = '', this.isDefault = false, this.channels = 0});
  final String name, id;
  final bool isDefault;

  /// The most channels it offers (0: unknown).
  final int channels;

  static List<InputDeviceInfo> listFromJson(Map<String, dynamic> j) => [
        for (final d in (j['devices'] as List? ?? const []))
          if (d is Map && d['name'] is String)
            InputDeviceInfo(name: d['name'] as String, id: _s(d['id']), isDefault: d['default'] == true,
                channels: _i(d['channels'])),
      ];
}

/// One recorded take as the engine lists it (a WAV, its placement and whether it finished).
class RecordedAudioTake {
  const RecordedAudioTake({required this.layer, required this.path, this.take = 0, this.startFrame = 0,
      this.startSteps = 0, this.frames = 0, this.seconds = 0, this.channels = 1, this.sampleRate = 0, this.bpm = 0,
      this.complete = true, this.error = '', this.recovered = false});
  final String layer, path, error;
  final int take, startFrame, frames, channels, sampleRate;

  /// Where frame 0 of the take lands in the song, in steps: before 0 when the latency reached back past the start.
  final double startSteps;
  final double seconds, bpm;
  final bool complete, recovered;

  static RecordedAudioTake? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final layer = _s(raw['layer']), path = _s(raw['path']);
    if (path.isEmpty) return null;
    return RecordedAudioTake(layer: layer, path: path, take: _i(raw['take']), startFrame: _i(raw['start_frame']),
        startSteps: _d(raw['start_steps']), frames: _i(raw['frames']), seconds: _d(raw['seconds']),
        channels: _i(raw['channels'], 1), sampleRate: _i(raw['sample_rate']), bpm: _d(raw['bpm']),
        complete: raw['complete'] != false, error: _s(raw['error']), recovered: raw['recovered'] == true);
  }
}

/// What `caw_record_start`, `_stop` and `_status` answer.
class RecordResult {
  const RecordResult({required this.ok, this.error = '', this.recording = false, this.droppedFrames = 0,
      this.takes = const []});
  final bool ok, recording;
  final String error;
  final int droppedFrames;
  final List<RecordedAudioTake> takes;

  static RecordResult fromJson(Map<String, dynamic> j) => RecordResult(
        ok: j['ok'] != false && (j['error'] == null || _s(j['error']).isEmpty), error: _s(j['error']),
        recording: j['recording'] == true, droppedFrames: _i(j['dropped_frames']),
        takes: [for (final t in (j['takes'] as List? ?? const [])) ?RecordedAudioTake.fromJson(t)]);
}

/// The recording latency in use (`caw_engine_input_latency`).
class LatencyInfo {
  const LatencyInfo({this.frames = 0, this.ms = 0, this.source = 'device', this.override = -1, this.measured = -1,
      this.device = 0});
  final int frames, override, measured, device;
  final double ms;

  /// override, measured or device.
  final String source;

  static LatencyInfo fromJson(Map<String, dynamic> j) => LatencyInfo(frames: _i(j['frames']), ms: _d(j['ms']),
      source: _s(j['source']).isEmpty ? 'device' : _s(j['source']), override: _i(j['override'], -1),
      measured: _i(j['measured'], -1), device: _i(j['device']));
}

/// A latency ping's state: running, idle, or done with a result.
class PingResult {
  const PingResult({this.state = 'idle', this.ok = false, this.frames = 0, this.ms = 0, this.confidence = 0});
  final String state;
  final bool ok;
  final int frames;
  final double ms, confidence;
  bool get done => state == 'done';

  static PingResult fromJson(Map<String, dynamic> j) => PingResult(state: _s(j['state']).isEmpty ? 'idle' : _s(j['state']),
      ok: j['ok'] == true, frames: _i(j['frames']), ms: _d(j['ms']), confidence: _d(j['confidence']));
}

/// `caw_sfz_import`: the sampler's state and what was left out.
class SfzImportResult {
  const SfzImportResult({required this.ok, this.error = '', this.zones = 0, this.warnings = const [], this.state});
  final bool ok;
  final String error;
  final int zones;
  final List<String> warnings;
  final Map<String, dynamic>? state;

  static SfzImportResult fromJson(Map<String, dynamic> j) => SfzImportResult(
        ok: j['ok'] == true, error: _s(j['error']), zones: _i(j['zones']),
        warnings: [for (final w in (j['warnings'] as List? ?? const [])) if (w is String) w],
        state: j['state'] is Map<String, dynamic> ? j['state'] as Map<String, dynamic> : null);
}

/// `caw_sfz_export`: the files written.
class SfzExportResult {
  const SfzExportResult({required this.ok, this.error = '', this.files = const []});
  final bool ok;
  final String error;
  final List<String> files;

  static SfzExportResult fromJson(Map<String, dynamic> j) => SfzExportResult(ok: j['ok'] == true, error: _s(j['error']),
      files: [for (final f in (j['files'] as List? ?? const [])) if (f is String) f]);
}

/// `caw_asset_tempo` (API 32): the file's tempo from its onsets. [bpm] is null when the engine is unsure: ask the user.
class TempoEstimate {
  const TempoEstimate({required this.ok, this.error = '', this.bpm, this.confidence = 0, this.onsets = 0,
      this.candidates = const []});
  final bool ok;
  final String error;
  final double? bpm;
  final double confidence;
  final int onsets;
  final List<({double bpm, double score})> candidates;

  static TempoEstimate fromJson(Map<String, dynamic> j) {
    final bpm = j['bpm'];
    return TempoEstimate(
        ok: j['ok'] == true,
        error: _s(j['error']),
        bpm: bpm is num && bpm.isFinite && bpm > 0 ? bpm.toDouble() : null,
        confidence: _d(j['confidence']),
        onsets: _i(j['onsets']),
        candidates: [
          for (final c in (j['candidates'] as List? ?? const []))
            if (c is Map) (bpm: _d(c['bpm']), score: _d(c['score'])),
        ]);
  }
}

/// One transient from `caw_asset_slices`: seconds from the file's start (its own speed), the frame at its own rate.
class AudioSlice {
  const AudioSlice({required this.seconds, required this.frame, this.strength = 0});
  final double seconds;
  final int frame;
  final double strength;
}

/// `caw_asset_slices` (API 32): transient starts in time order, for Slice to MIDI.
class SliceResult {
  const SliceResult({required this.ok, this.error = '', this.seconds = 0, this.slices = const []});
  final bool ok;
  final String error;

  /// The analysed range's length.
  final double seconds;
  final List<AudioSlice> slices;

  static SliceResult fromJson(Map<String, dynamic> j) => SliceResult(
      ok: j['ok'] == true,
      error: _s(j['error']),
      seconds: _d(j['seconds']),
      slices: [
        for (final s in (j['slices'] as List? ?? const []))
          if (s is Map) AudioSlice(seconds: _d(s['seconds']), frame: _i(s['frame']), strength: _d(s['strength'])),
      ]);
}

/// The engine's audio side as the model uses it. Tests give a fake.
abstract class AudioIo {
  /// Decodes [path] into the asset store (slow for a long file: a worker isolate).
  Future<AssetInfo> loadAsset(String path);

  /// Min/max pairs of [buckets] equal parts of [start]..[end] seconds of [channel]; null when the file won't load.
  Future<Float32List?> peaks(String path, double start, double end, int buckets, {int channel = 0});

  /// The tempo of [path] from its onsets, searched in [minBpm]..[maxBpm] (a worker isolate).
  Future<TempoEstimate> detectTempo(String path,
      {double minBpm = 70, double maxBpm = 180, double startSeconds = 0, double endSeconds = 0});

  /// Transients of [path] in [startSeconds]..[endSeconds] (0: the file's end); higher [sensitivity] finds more.
  Future<SliceResult> slices(String path,
      {double sensitivity = 0.5, double startSeconds = 0, double endSeconds = 0, double minGapSeconds = 0.05,
      int maxSlices = 64});

  Future<List<InputDeviceInfo>> inputDevices();

  /// Opens or closes the input (0 ok, 2 fallback, 1 closed).
  Future<int> configureInput({required bool enabled, String deviceId = '', String deviceName = '', int channels = 2});

  /// Each input channel's peak since the last call.
  List<double> inputPeaks();

  Future<RecordResult> recordStart(Map<String, dynamic> request);
  Future<RecordResult> recordStop();
  RecordResult recordStatus();

  /// Finalises takes a crash left in [dir].
  Future<RecordResult> recover(String dir);

  /// [frames] >= 0 overrides the latency; -1 uses the ping's, else the device's.
  void setInputLatency(int frames);
  LatencyInfo inputLatency();
  bool pingStart();
  PingResult pingResult();

  Future<SfzImportResult> sfzImport(String path);
  Future<SfzExportResult> sfzExport(String stateJson, String path, {bool copySamples = false});

  /// The device's `caw_audio_status` "input" object (empty when none).
  Map<String, dynamic> inputStatus();
}

/// [AudioIo] over the engine the app runs ([engine] is read on every call: the app makes a new one on a rate change).
class EngineAudioIo implements AudioIo {
  EngineAudioIo(this.engine);
  final Engine? Function() engine;

  AudioBindings get _b => AudioBindings.instance;

  Future<T?> _off<T>(Future<T> Function(int address) op) async {
    final e = engine();
    if (e == null) return null;
    return e.withNative(op);
  }

  @override
  Future<AssetInfo> loadAsset(String path) async =>
      await _off((a) => _loadAsset(a, path)) ?? const AssetInfo(ok: false, error: 'no engine');

  @override
  Future<Float32List?> peaks(String path, double start, double end, int buckets, {int channel = 0}) =>
      _off((a) => _peaks(a, path, start, end, buckets, channel)).then((v) => v);

  @override
  Future<TempoEstimate> detectTempo(String path,
          {double minBpm = 70, double maxBpm = 180, double startSeconds = 0, double endSeconds = 0}) async =>
      TempoEstimate.fromJson(await _off((a) => _analyse(a, path, false, jsonEncode({
                'min_bpm': minBpm, 'max_bpm': maxBpm, 'start_seconds': startSeconds, 'end_seconds': endSeconds,
              }))) ??
          const {'ok': false, 'error': 'no engine'});

  @override
  Future<SliceResult> slices(String path,
          {double sensitivity = 0.5, double startSeconds = 0, double endSeconds = 0, double minGapSeconds = 0.05,
          int maxSlices = 64}) async =>
      SliceResult.fromJson(await _off((a) => _analyse(a, path, true, jsonEncode({
                'sensitivity': sensitivity, 'start_seconds': startSeconds, 'end_seconds': endSeconds,
                'min_gap_seconds': minGapSeconds, 'max_slices': maxSlices,
              }))) ??
          const {'ok': false, 'error': 'no engine'});

  @override
  Future<List<InputDeviceInfo>> inputDevices() => Isolate.run(() {
        final b = AudioBindings.instance;
        return InputDeviceInfo.listFromJson(_map(b.take(b.inputDevices())));
      });

  @override
  Future<int> configureInput({required bool enabled, String deviceId = '', String deviceName = '', int channels = 2}) async =>
      await _off((a) => Isolate.run(() {
            final b = AudioBindings.instance;
            final id = deviceId.toNativeUtf8(), name = deviceName.toNativeUtf8();
            try {
              return b.configureInput(Pointer<Void>.fromAddress(a), enabled ? 1 : 0, id, name, channels);
            } finally {
              calloc.free(id);
              calloc.free(name);
            }
          })) ??
      1;

  final Pointer<Float> _peakBuf = calloc<Float>(32);

  @override
  List<double> inputPeaks() {
    final a = engine()?.nativeAddress;
    if (a == null) return const [];
    final n = _b.inputPeaks(Pointer<Void>.fromAddress(a), _peakBuf, 32);
    return [for (var i = 0; i < n; i++) _peakBuf[i]];
  }

  String _sync(Pointer<Utf8> Function(Pointer<Void>) call) {
    final a = engine()?.nativeAddress;
    if (a == null) return '{}';
    return _b.take(call(Pointer<Void>.fromAddress(a)));
  }

  @override
  Future<RecordResult> recordStart(Map<String, dynamic> request) async {
    final text = jsonEncode(request);
    final r = await _off((a) => Isolate.run(() {
          final b = AudioBindings.instance;
          final req = text.toNativeUtf8();
          try {
            return b.take(b.recordStart(Pointer<Void>.fromAddress(a), req));
          } finally {
            calloc.free(req);
          }
        }));
    return r == null ? const RecordResult(ok: false, error: 'no engine') : RecordResult.fromJson(_map(r));
  }

  @override
  Future<RecordResult> recordStop() async {
    // Stopping waits for the writer to finish the files: off the UI isolate.
    final r = await _off((a) => Isolate.run(() {
          final b = AudioBindings.instance;
          return b.take(b.recordStop(Pointer<Void>.fromAddress(a)));
        }));
    return r == null ? const RecordResult(ok: false, error: 'no engine') : RecordResult.fromJson(_map(r));
  }

  @override
  RecordResult recordStatus() => RecordResult.fromJson(_map(_sync(_b.recordStatus)));

  @override
  Future<RecordResult> recover(String dir) async => RecordResult.fromJson(_map(await Isolate.run(() {
        final b = AudioBindings.instance;
        final d = dir.toNativeUtf8();
        try {
          return b.take(b.recordRecover(d));
        } finally {
          calloc.free(d);
        }
      })));

  @override
  void setInputLatency(int frames) {
    final a = engine()?.nativeAddress;
    if (a != null) _b.setInputLatency(Pointer<Void>.fromAddress(a), frames);
  }

  @override
  LatencyInfo inputLatency() => LatencyInfo.fromJson(_map(_sync(_b.inputLatency)));

  @override
  bool pingStart() {
    final a = engine()?.nativeAddress;
    return a != null && _b.pingStart(Pointer<Void>.fromAddress(a)) != 0;
  }

  @override
  PingResult pingResult() => PingResult.fromJson(_map(_sync(_b.pingResult)));

  @override
  Future<SfzImportResult> sfzImport(String path) async => SfzImportResult.fromJson(_map(await Isolate.run(() {
        final b = AudioBindings.instance;
        final p = path.toNativeUtf8();
        try {
          return b.take(b.sfzImport(p));
        } finally {
          calloc.free(p);
        }
      })));

  @override
  Future<SfzExportResult> sfzExport(String stateJson, String path, {bool copySamples = false}) async =>
      SfzExportResult.fromJson(_map(await Isolate.run(() {
        final b = AudioBindings.instance;
        final s = stateJson.toNativeUtf8(), p = path.toNativeUtf8();
        try {
          return b.take(b.sfzExport(s, p, copySamples ? 1 : 0));
        } finally {
          calloc.free(s);
          calloc.free(p);
        }
      })));

  @override
  Map<String, dynamic> inputStatus() {
    final e = engine();
    if (e == null || e.nativeAddress == null) return const {};
    final raw = e.audioStatusJson();
    final input = raw['input'];
    return input is Map<String, dynamic> ? input : const {};
  }
}

// Top-level, so the isolate's closure carries only sendable values.
Future<AssetInfo> _loadAsset(int address, String path) => Isolate.run(() {
      final b = AudioBindings.instance;
      final p = path.toNativeUtf8();
      try {
        return AssetInfo.fromJson(_map(b.take(b.assetLoad(Pointer<Void>.fromAddress(address), p))));
      } finally {
        calloc.free(p);
      }
    });

Future<Map<String, dynamic>> _analyse(int address, String path, bool slices, String options) => Isolate.run(() {
      final b = AudioBindings.instance;
      final p = path.toNativeUtf8();
      final o = options.toNativeUtf8();
      try {
        final e = Pointer<Void>.fromAddress(address);
        return _map(b.take(slices ? b.assetSlices(e, p, o) : b.assetTempo(e, p, o)));
      } finally {
        calloc.free(p);
        calloc.free(o);
      }
    });

Future<Float32List?> _peaks(int address, String path, double start, double end, int buckets, int channel) =>
    Isolate.run(() {
      final b = AudioBindings.instance;
      final n = buckets.clamp(1, 65536);
      final p = path.toNativeUtf8();
      final out = calloc<Float>(2 * n);
      try {
        final got = b.assetPeaks(Pointer<Void>.fromAddress(address), p, start, end, n, channel, out);
        if (got < 0) return null;
        return Float32List.fromList(out.asTypedList(2 * got));
      } finally {
        calloc.free(p);
        calloc.free(out);
      }
    });
