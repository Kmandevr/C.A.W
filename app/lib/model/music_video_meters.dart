// The music video's meters for an offline render: per-frame peak and RMS of the rendered mix and track stems,
// read from their WAV files a chunk at a time in a background isolate (live meters don't exist offline).
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// One frame's levels, 0..1 (linear): the master's left and right peak and RMS, and each track's peak by id.
class VideoLevels {
  const VideoLevels({this.peakL = 0, this.peakR = 0, this.rms = 0, this.tracks = const {}});
  final double peakL, peakR, rms;
  final Map<String, double> tracks;

  static const silent = VideoLevels();
}

/// What a frame's meters show, from the live engine (the preview) or the rendered audio (the render).
abstract class VideoMeterSource {
  VideoLevels levelsAt(int frame);
}

/// The rendered audio's levels per frame, with a meter's fall (peaks hold and fall over about 300 ms).
class OfflineVideoMeters implements VideoMeterSource {
  OfflineVideoMeters({required this.frames, required this.peakL, required this.peakR, required this.rms,
      required this.tracks});
  final int frames;
  final Float32List peakL, peakR, rms;
  final Map<String, Float32List> tracks;

  @override
  VideoLevels levelsAt(int frame) {
    if (frames == 0) return VideoLevels.silent;
    final i = frame.clamp(0, frames - 1);
    return VideoLevels(peakL: peakL[i], peakR: peakR[i], rms: rms[i],
        tracks: {for (final e in tracks.entries) e.key: e.value[i]});
  }
}

/// A WAV file's format and where its samples are.
class WavInfo {
  const WavInfo({required this.sampleRate, required this.channels, required this.bits, required this.float,
      required this.dataOffset, required this.dataBytes});
  final int sampleRate, channels, bits;
  final bool float;
  final int dataOffset, dataBytes;

  int get frameBytes => channels * bits ~/ 8;
  int get frames => frameBytes == 0 ? 0 : dataBytes ~/ frameBytes;
  double get seconds => sampleRate == 0 ? 0 : frames / sampleRate;
}

/// Reads a WAV header (PCM 16, 24 or 32 bit, or 32-bit float; `WAVE_FORMAT_EXTENSIBLE` too); null when it isn't one.
WavInfo? readWavInfo(RandomAccessFile f) {
  f.setPositionSync(0);
  final head = f.readSync(12);
  if (head.length < 12 || String.fromCharCodes(head, 0, 4) != 'RIFF' || String.fromCharCodes(head, 8, 12) != 'WAVE') {
    return null;
  }
  var pos = 12;
  int? rate, channels, bits;
  var float = false;
  final length = f.lengthSync();
  while (pos + 8 <= length) {
    f.setPositionSync(pos);
    final h = f.readSync(8);
    if (h.length < 8) break;
    final id = String.fromCharCodes(h, 0, 4);
    final size = ByteData.sublistView(h).getUint32(4, Endian.little);
    if (id == 'fmt ') {
      final b = ByteData.sublistView(f.readSync(math.min(size, 40)));
      var format = b.getUint16(0, Endian.little);
      channels = b.getUint16(2, Endian.little);
      rate = b.getUint32(4, Endian.little);
      bits = b.getUint16(14, Endian.little);
      if (format == 0xFFFE && b.lengthInBytes >= 26) format = b.getUint16(24, Endian.little);
      float = format == 3;
      if (format != 1 && format != 3) return null;
    } else if (id == 'data') {
      if (rate == null || channels == null || bits == null) return null;
      return WavInfo(sampleRate: rate, channels: channels, bits: bits, float: float, dataOffset: pos + 8,
          dataBytes: math.min(size, length - pos - 8));
    }
    pos += 8 + size + (size & 1);
  }
  return null;
}

/// Writes a 16-bit stereo PCM WAV of [frames] frames from [sample] (frame, channel) → −1..1; tests and the fake render use it.
void writeTestWav(File file, {required int sampleRate, required int frames, double Function(int frame, int ch)? sample}) {
  final data = ByteData(frames * 4);
  for (var i = 0; i < frames; i++) {
    for (var c = 0; c < 2; c++) {
      final v = (sample?.call(i, c) ?? 0).clamp(-1.0, 1.0);
      data.setInt16(i * 4 + c * 2, (v * 32767).round(), Endian.little);
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
  h.setUint16(22, 2, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 4, Endian.little);
  h.setUint16(32, 4, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, data.lengthInBytes, Endian.little);
  file.writeAsBytesSync([...h.buffer.asUint8List(), ...data.buffer.asUint8List()], flush: true);
}

/// Per-frame levels of one file: left peak, right peak, RMS (of both sides), after a meter's fall.
(Float32List, Float32List, Float32List) _analyzeFile(String path, int fps, int frames) {
  final l = Float32List(frames), r = Float32List(frames), rms = Float32List(frames);
  final f = File(path).openSync();
  try {
    final info = readWavInfo(f);
    if (info == null || info.channels == 0 || frames == 0) return (l, r, rms);
    final bytes = info.bits ~/ 8;
    final sumSq = Float64List(frames), counts = Int32List(frames);
    const chunkFrames = 1 << 15;
    var done = 0;
    while (done < info.frames) {
      final n = math.min(chunkFrames, info.frames - done);
      f.setPositionSync(info.dataOffset + done * info.frameBytes);
      final raw = f.readSync(n * info.frameBytes);
      final b = ByteData.sublistView(raw);
      final got = raw.length ~/ info.frameBytes;
      for (var i = 0; i < got; i++) {
        final frame = ((done + i) * fps ~/ info.sampleRate);
        if (frame >= frames) break;
        for (var c = 0; c < math.min(2, info.channels); c++) {
          final at = i * info.frameBytes + c * bytes;
          final double v = switch ((info.float, info.bits)) {
            (true, 32) => b.getFloat32(at, Endian.little),
            (_, 16) => b.getInt16(at, Endian.little) / 32768.0,
            (_, 24) => ((b.getUint8(at) | b.getUint8(at + 1) << 8 | b.getInt8(at + 2) << 16)) / 8388608.0,
            (_, 32) => b.getInt32(at, Endian.little) / 2147483648.0,
            _ => 0.0,
          };
          final a = v.abs();
          if (c == 0) {
            if (a > l[frame]) l[frame] = a;
            if (info.channels == 1 && a > r[frame]) r[frame] = a;
          } else if (a > r[frame]) {
            r[frame] = a;
          }
          sumSq[frame] += v * v;
          counts[frame]++;
        }
      }
      if (got == 0) break;
      done += got;
    }
    // A meter's fall: a level holds and falls by about 20 dB in 300 ms, frame by frame, so it doesn't flicker.
    final fall = math.pow(0.1, 1 / (0.3 * fps)).toDouble();
    for (var i = 0; i < frames; i++) {
      rms[i] = counts[i] == 0 ? 0 : math.sqrt(sumSq[i] / counts[i]);
      if (i > 0) {
        l[i] = math.max(l[i], l[i - 1] * fall);
        r[i] = math.max(r[i], r[i - 1] * fall);
        rms[i] = math.max(rms[i], rms[i - 1] * fall);
      }
    }
  } finally {
    f.closeSync();
  }
  return (l, r, rms);
}

/// Analyses the mix at [mixPath] and the stems in [stems] (track id → WAV path) for [frames] frames at [fps], in a
/// background isolate.
Future<OfflineVideoMeters> analyzeVideoAudio({required String mixPath, Map<String, String> stems = const {},
    required int fps, required int frames}) {
  return Isolate.run(() {
    final (l, r, rms) = _analyzeFile(mixPath, fps, frames);
    final tracks = <String, Float32List>{};
    for (final e in stems.entries) {
      final (sl, sr, _) = _analyzeFile(e.value, fps, frames);
      final peak = Float32List(frames);
      for (var i = 0; i < frames; i++) {
        peak[i] = math.max(sl[i], sr[i]);
      }
      tracks[e.key] = peak;
    }
    return OfflineVideoMeters(frames: frames, peakL: l, peakR: r, rms: rms, tracks: tracks);
  });
}
