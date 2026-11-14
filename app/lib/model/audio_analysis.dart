// What the sample editor and import ask of a file (batch 1.0.4): its tempo from onsets, transients for Slice to MIDI
// and its peak for Normalise. AudioAnalysis is the interface (the C API 32 binding implements it; tests give a fake);
// PeaksAudioAnalysis answers from the engine's waveform peaks (API 18), so the tools work before it.
import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/audio_engine.dart';

/// The most slices Slice to MIDI makes (the sampler takes them from C2 up; 16 fit one bank of drum pads).
const kMaxSlices = 64;

/// A tempo estimate: [bpm] and how sure it is, 0..1.
class TempoEstimate {
  const TempoEstimate(this.bpm, this.confidence);
  final double bpm, confidence;

  @override
  String toString() => 'TempoEstimate($bpm, $confidence)';
}

/// The analysis calls, positions in seconds of the file at its own speed.
abstract interface class AudioAnalysis {
  /// The tempo of [path] from its onsets, or null when unsure (the clip tab then asks for it).
  Future<TempoEstimate?> detectTempo(String path, {required double seconds});

  /// Where transients start in [start]..[end] of [path] (seconds, sorted, after [start] and before [end]), more of
  /// them as [sensitivity] (0..1) rises; at most [maxSlices] − 1. Null when the file won't load.
  Future<List<double>?> slicePoints(String path,
      {required double start, required double end, required double sensitivity, int maxSlices = kMaxSlices});

  /// The highest sample level (linear, 0..) in [start]..[end] of [path] over its channels; null when it won't load.
  Future<double?> peak(String path, {required double start, required double end, int channels = 2});
}

/// `caw_asset_tempo`'s options in, its JSON out (C API 32; the contract's Engine notes), off the UI isolate.
typedef AssetTempoCall = Future<Map<String, dynamic>?> Function(String path, {double startSeconds, double endSeconds});

/// `caw_asset_slices`'s options in, its JSON out (C API 32), off the UI isolate.
typedef AssetSlicesCall = Future<Map<String, dynamic>?> Function(String path,
    {double sensitivity, double startSeconds, double endSeconds, int maxSlices});

/// [AudioAnalysis] over the engine's C API 32 calls ([tempo], [slices]); the peak (Normalise, Trim) comes from
/// [peaks], which reads `caw_asset_peaks`. The binding hands its two calls in:
/// `EngineAudioAnalysis(tempo: engine.assetTempo, slices: engine.assetSlices, peaks: PeaksAudioAnalysis(io))`.
class EngineAudioAnalysis implements AudioAnalysis {
  EngineAudioAnalysis({required this.tempo, required this.slices, required this.peaks});
  final AssetTempoCall tempo;
  final AssetSlicesCall slices;
  final AudioAnalysis peaks;

  @override
  Future<TempoEstimate?> detectTempo(String path, {required double seconds}) async =>
      tempoFromJson(await tempo(path, startSeconds: 0, endSeconds: 0));

  @override
  Future<List<double>?> slicePoints(String path,
      {required double start, required double end, required double sensitivity, int maxSlices = kMaxSlices}) async =>
      slicesFromJson(await slices(path, sensitivity: sensitivity.clamp(0.0, 1.0), startSeconds: start, endSeconds: end,
          maxSlices: maxSlices.clamp(1, 256)), start: start, end: end, maxSlices: maxSlices);

  @override
  Future<double?> peak(String path, {required double start, required double end, int channels = 2}) =>
      peaks.peak(path, start: start, end: end, channels: channels);
}

/// `caw_asset_tempo`'s answer as an estimate: null unless ok with a finite `bpm` (null there means unsure).
TempoEstimate? tempoFromJson(Map<String, dynamic>? j) {
  if (j == null || j['ok'] != true) return null;
  final bpm = j['bpm'], conf = j['confidence'];
  if (bpm is! num || !bpm.isFinite || bpm <= 0) return null;
  return TempoEstimate(bpm.toDouble().clamp(20.0, 999.0), conf is num && conf.isFinite ? conf.toDouble().clamp(0.0, 1.0) : 0);
}

/// `caw_asset_slices`'s answer as cut points (seconds of the file): finite, inside [start]..[end], sorted, no repeats,
/// at most [maxSlices] − 1 (an untrusted list is read only that far); null unless ok.
List<double>? slicesFromJson(Map<String, dynamic>? j, {required double start, required double end, int maxSlices = kMaxSlices}) {
  if (j == null || j['ok'] != true || j['slices'] is! List) return null;
  final out = <double>{};
  for (final e in (j['slices'] as List).take(4096)) {
    final t = e is Map ? e['seconds'] : null;
    if (t is num && t.isFinite && t > start && t < end) out.add(t.toDouble());
  }
  return (out.toList()..sort()).take(math.max(0, maxSlices - 1)).toList();
}

/// [AudioAnalysis] from `caw_asset_peaks` min/max buckets: an envelope at [resolution] seconds a bucket.
class PeaksAudioAnalysis implements AudioAnalysis {
  PeaksAudioAnalysis(this.io, {this.resolution = 0.005});
  final AudioIo io;
  final double resolution;

  /// The most buckets one read asks for.
  static const maxBuckets = 1 << 16;

  Future<Float64List?> _envelope(String path, double start, double end, {int channels = 1}) async {
    if (!(end > start)) return null;
    final n = ((end - start) / resolution).ceil().clamp(1, maxBuckets);
    Float64List? env;
    for (var ch = 0; ch < channels; ch++) {
      final p = await io.peaks(path, start, end, n, channel: ch);
      if (p == null) return ch == 0 ? null : env;
      env ??= Float64List(n);
      for (var i = 0; i < n && 2 * i + 1 < p.length; i++) {
        env[i] = math.max(env[i], math.max(p[2 * i].abs(), p[2 * i + 1].abs()).toDouble());
      }
    }
    return env;
  }

  @override
  Future<double?> peak(String path, {required double start, required double end, int channels = 2}) async {
    final env = await _envelope(path, start, end, channels: math.max(1, channels));
    return env?.fold<double>(0, (m, v) => math.max(m, v));
  }

  @override
  Future<List<double>?> slicePoints(String path,
      {required double start, required double end, required double sensitivity, int maxSlices = kMaxSlices}) async {
    final env = await _envelope(path, start, end);
    if (env == null) return null;
    return [for (final i in onsetBuckets(env, sensitivity, resolution, maxOnsets: maxSlices - 1)) start + i * resolution];
  }

  @override
  Future<TempoEstimate?> detectTempo(String path, {required double seconds}) async {
    final span = math.min(seconds, 60.0);
    final env = await _envelope(path, 0, span);
    if (env == null) return null;
    return tempoFromEnvelope(env, resolution);
  }
}

/// The buckets of [env] where a transient starts: the level jumps above [sensitivity]'s multiple of the level just
/// before it and above a floor, at least a gap apart (shorter as [sensitivity] rises). Bucket 0 never counts (the
/// slice there is the start). The strongest [maxOnsets] are kept, in order.
List<int> onsetBuckets(List<double> env, double sensitivity, double resolution, {int maxOnsets = kMaxSlices - 1}) {
  final s = sensitivity.clamp(0.0, 1.0);
  final top = env.fold<double>(0, (m, v) => math.max(m, v));
  if (top <= 0 || env.length < 3) return const [];
  final ratio = 4.0 - 2.8 * s; // how many times louder than just before: 4× at 0, 1.2× at 1
  final floor = top * (0.25 - 0.23 * s); // and how loud against the loudest part
  final gap = math.max(1, ((0.12 - 0.09 * s) / resolution).round());
  final look = math.max(1, (0.02 / resolution).round());
  final found = <(int, double)>[];
  var last = -gap;
  for (var i = 1; i < env.length; i++) {
    var before = 0.0;
    for (var k = math.max(0, i - look); k < i; k++) {
      before += env[k];
    }
    before /= math.max(1, i - math.max(0, i - look));
    final v = env[i];
    if (v >= floor && v > before * ratio + top * 0.01 && i - last >= gap) {
      found.add((i, v - before));
      last = i;
    }
  }
  if (found.length > maxOnsets) {
    found.sort((a, b) => b.$2.compareTo(a.$2));
    found.removeRange(maxOnsets, found.length);
  }
  return [for (final f in found) f.$1]..sort();
}

/// A tempo from an envelope's onsets: the beat period whose comb best lines up with them, 60–180 BPM, rounded to a
/// tenth. Null when there are too few onsets or no period stands out (the user types it in).
TempoEstimate? tempoFromEnvelope(List<double> env, double resolution) {
  final onsets = onsetBuckets(env, 0.6, resolution, maxOnsets: 512);
  if (onsets.length < 4) return null;
  final times = [for (final o in onsets) o * resolution];
  double score(double bpm) {
    final beat = 60 / bpm;
    var sum = 0.0;
    for (final t in times) {
      final phase = (t - times.first) / beat * 2; // eighths count too, half as much
      final d = (phase - phase.roundToDouble()).abs();
      sum += math.exp(-d * d / 0.005) * (phase.round().isEven ? 1 : 0.5);
    }
    return sum / times.length;
  }
  var best = 0.0, bestBpm = 0.0;
  final all = <double>[];
  for (var bpm = 60.0; bpm <= 180.0; bpm += 0.5) {
    final v = score(bpm);
    all.add(v);
    if (v > best + 1e-9) {
      best = v;
      bestBpm = bpm;
    }
  }
  if (best <= 0) return null;
  // Refine around the best half-BPM to a tenth.
  for (var bpm = bestBpm - 0.5; bpm <= bestBpm + 0.5; bpm += 0.1) {
    final v = score(bpm);
    if (v > best + 1e-9) {
      best = v;
      bestBpm = bpm;
    }
  }
  all.sort();
  final median = all[all.length ~/ 2];
  final confidence = ((best - median) / best).clamp(0.0, 1.0);
  if (confidence < 0.3) return null;
  return TempoEstimate((bestBpm * 10).round() / 10, confidence);
}
