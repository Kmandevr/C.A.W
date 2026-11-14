// A fake of the engine's audio side (AudioIo) for the audio tests: assets with a set length, a scripted recorder,
// input peaks and a latency ping, all in memory. Also writes small WAV files for the engine-backed tests.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/engine/audio_engine.dart';

class FakeAudioIo implements AudioIo {
  /// Seconds each loaded path reports (unknown paths: 2 s, or a failure when [failUnknown]).
  final Map<String, double> seconds = {};
  bool failUnknown = false;
  final List<String> loaded = [];

  // The recorder: start returns [startResult]; stop returns [stopTakes].
  Map<String, dynamic>? lastRecordRequest;
  RecordResult startResult = const RecordResult(ok: true, recording: true);
  List<RecordedAudioTake> stopTakes = [];
  bool recording = false;
  int stops = 0;
  List<RecordedAudioTake> recovered = [];
  String? recoveredFrom;

  List<double> peaksNow = [0.5, 0.25];
  int latencyOverride = -1;
  int measured = -1;
  bool pinging = false;
  PingResult ping = const PingResult(state: 'done', ok: true, frames: 480, ms: 10, confidence: 20);

  List<({bool enabled, String id, int channels})> inputConfigs = [];
  List<InputDeviceInfo> devices = const [
    InputDeviceInfo(name: 'Built-in mic', id: 'mic', isDefault: true, channels: 1),
    InputDeviceInfo(name: 'USB interface', id: 'usb', channels: 4),
  ];

  // Tempo detection and slices (API 32): what they return, and the calls made.
  TempoEstimate tempo = const TempoEstimate(ok: true, bpm: 120, confidence: 0.8, onsets: 16);
  SliceResult sliceResult = const SliceResult(ok: true, seconds: 2, slices: [
    AudioSlice(seconds: 0, frame: 0, strength: 1),
    AudioSlice(seconds: 0.5, frame: 24000, strength: 0.8),
  ]);
  final List<String> analysed = [];

  SfzImportResult? sfz;
  final List<(String, String, bool)> sfzExports = [];

  @override
  Future<TempoEstimate> detectTempo(String path,
      {double minBpm = 70, double maxBpm = 180, double startSeconds = 0, double endSeconds = 0}) async {
    analysed.add('tempo $path');
    return tempo;
  }

  @override
  Future<SliceResult> slices(String path,
      {double sensitivity = 0.5, double startSeconds = 0, double endSeconds = 0, double minGapSeconds = 0.05,
      int maxSlices = 64}) async {
    analysed.add('slices $path $sensitivity');
    return sliceResult;
  }

  @override
  Future<AssetInfo> loadAsset(String path) async {
    loaded.add(path);
    final s = seconds[path] ?? (failUnknown ? null : 2.0);
    if (s == null) return const AssetInfo(ok: false, error: 'not an audio file');
    return AssetInfo(ok: true, path: path, frames: (s * 48000).round(), channels: 2, sampleRate: 48000,
        sourceRate: 44100, sourceChannels: 2, seconds: s);
  }

  @override
  Future<Float32List?> peaks(String path, double start, double end, int buckets, {int channel = 0}) async {
    final out = Float32List(buckets * 2);
    for (var i = 0; i < buckets; i++) {
      final v = (math.sin(i / 3) * 0.8).abs();
      out[2 * i] = -v;
      out[2 * i + 1] = v;
    }
    return out;
  }

  @override
  Future<List<InputDeviceInfo>> inputDevices() async => devices;

  @override
  Future<int> configureInput({required bool enabled, String deviceId = '', String deviceName = '', int channels = 2}) async {
    inputConfigs.add((enabled: enabled, id: deviceId, channels: channels));
    return 0;
  }

  @override
  List<double> inputPeaks() => peaksNow;

  @override
  Future<RecordResult> recordStart(Map<String, dynamic> request) async {
    lastRecordRequest = request;
    recording = startResult.ok;
    return startResult;
  }

  @override
  Future<RecordResult> recordStop() async {
    stops++;
    recording = false;
    return RecordResult(ok: true, takes: stopTakes);
  }

  @override
  RecordResult recordStatus() => RecordResult(ok: true, recording: recording);

  @override
  Future<RecordResult> recover(String dir) async {
    recoveredFrom = dir;
    return RecordResult(ok: true, takes: recovered);
  }

  @override
  void setInputLatency(int frames) => latencyOverride = frames;

  @override
  LatencyInfo inputLatency() => latencyOverride >= 0
      ? LatencyInfo(frames: latencyOverride, ms: latencyOverride / 48, source: 'override', override: latencyOverride,
          measured: measured, device: 960)
      : LatencyInfo(frames: measured >= 0 ? measured : 960, ms: (measured >= 0 ? measured : 960) / 48,
          source: measured >= 0 ? 'measured' : 'device', measured: measured, device: 960);

  @override
  bool pingStart() => pinging = true;

  @override
  PingResult pingResult() {
    if (ping.ok) measured = ping.frames;
    return ping;
  }

  @override
  Future<SfzImportResult> sfzImport(String path) async => sfz ?? const SfzImportResult(ok: false, error: 'no sfz');

  @override
  Future<SfzExportResult> sfzExport(String stateJson, String path, {bool copySamples = false}) async {
    sfzExports.add((stateJson, path, copySamples));
    return SfzExportResult(ok: true, files: [path]);
  }

  @override
  Map<String, dynamic> inputStatus() => inputStatusNow;

  /// What [inputStatus] answers: the engine's input JSON ("state": open, stalled, stopped, failed).
  Map<String, dynamic> inputStatusNow = {'enabled': true, 'running': true, 'state': 'open', 'channels': 2};
}

/// A 16-bit PCM WAV: [seconds] of a 440 Hz sine at half scale, [channels] wide.
File writeTestWav(String path, {double seconds = 1, int rate = 44100, int channels = 1}) {
  final frames = (seconds * rate).round();
  final data = ByteData(frames * channels * 2);
  for (var i = 0; i < frames; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / rate) * 16383).round();
    for (var c = 0; c < channels; c++) {
      data.setInt16((i * channels + c) * 2, v, Endian.little);
    }
  }
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + data.lengthInBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * channels * 2, Endian.little);
  h.setUint16(32, channels * 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, data.lengthInBytes, Endian.little);
  final f = File(path)..createSync(recursive: true);
  f.writeAsBytesSync([...h.buffer.asUint8List(), ...data.buffer.asUint8List()]);
  return f;
}
