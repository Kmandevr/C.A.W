// The clip pitch editor's engine side: PitchClipBackend over C API 42 (caw_pitch_clip_*). Each job runs on a worker isolate that decodes the file through the engine's asset store, analyses or renders it and writes the result as a float WAV, posting its progress; the UI isolate never holds the samples.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../model/pitch_clip.dart';
import 'audio_bindings.dart';
import 'bindings.dart';
import 'engine.dart';

/// The longest clip the editor analyses (the engine's own bound): 30 minutes.
const double kMaxPitchClipSeconds = 30 * 60;

/// Frames read from the asset store per step (its peaks call reads 65,536 buckets at most; one frame a bucket).
const int _chunk = 65536;

/// What a session keeps natively: the decoded channels the clip was analysed from (render needs the same ones) and
/// the clip handle, as addresses so a worker isolate can use them.
class _Native {
  _Native(this.clip, this.left, this.right, this.frames);
  final int clip, left, right, frames;
  Future<void> busy = Future.value();
  bool released = false;
}

/// [PitchClipBackend] over the engine [engine] runs (read on every call; null: no engine, and each job fails).
class NativePitchClipBackend implements PitchClipBackend {
  NativePitchClipBackend(this.engine);
  final Engine? Function() engine;

  @override
  PitchJob<PitchClipSession> analyse(String path) => PitchJob<PitchClipSession>((job) async {
        final e = engine();
        if (e == null) throw const PitchClipError('the engine is not running');
        final cancel = calloc<Int32>();
        job.whenCancelled(() => cancel.value = 1);
        try {
          job.stage.value = 'Reading';
          final out = await e.withNative((address) => _work(job, _analyseEntry, [address, path, cancel.address]));
          if (out == null) throw const PitchClipError('the engine is not running');
          if (job.cancelled) {
            if (out is List) _free(_Native(out[1] as int, out[2] as int, out[3] as int, 0));
            return null;
          }
          if (out is String) throw PitchClipError(out);
          final r = out as List;
          final native = _Native(r[1] as int, r[2] as int, r[3] as int, r[4] as int);
          final json = jsonDecode(r[0] as String) as Map<String, dynamic>;
          final analysis = PitchAnalysis.fromJson(json,
              midi: r[5] as Float32List, voicing: r[6] as Float32List, rmsDb: r[7] as Float32List);
          final session = analysis == null ? null : PitchClipSession(analysis, channels: native.right == 0 ? 1 : 2, native: native);
          if (session == null || job.cancelled) {
            _free(native);
            if (session == null) throw PitchClipError('${json['error'] ?? 'the analysis failed'}');
            return null;
          }
          return session;
        } finally {
          // The worker has finished with the flag once its result is in.
          calloc.free(cancel);
        }
      });

  @override
  PitchJob<PitchRenderResult> render(PitchClipSession session, Map<int, PitchNoteEdit> edits, String outPath) {
    final n = session.native;
    if (n is! _Native || n.released) return PitchJob.done(null, error: const PitchClipError('the clip was closed'));
    final editsJson = jsonEncode(pitchEditsJson(edits, sampleRate: session.analysis.sampleRate));
    final rate = session.analysis.sampleRate;
    return PitchJob<PitchRenderResult>((job) async {
      job.stage.value = 'Rendering';
      job.progress.value = null;
      final run = _work(job, _renderEntry, [n.clip, n.left, n.right, n.frames, rate, editsJson, outPath]);
      n.busy = run.then((_) {}, onError: (_) {});
      final out = await run;
      if (job.cancelled || out is String) {
        try {
          File(outPath).deleteSync();
        } catch (_) {}
        if (out is String && !job.cancelled) throw PitchClipError(out);
        return null;
      }
      return PitchRenderResult(path: outPath, frames: n.frames, sampleRate: rate, channels: n.right == 0 ? 1 : 2,
          notesEdited: out as int);
    });
  }

  @override
  void release(PitchClipSession session) {
    final n = session.native;
    if (n is! _Native || n.released) return;
    n.released = true;
    // A render still running uses the clip and its channels: free them once it is done.
    n.busy.whenComplete(() => _free(n));
  }
}

void _free(_Native n) {
  final b = Bindings.instance;
  if (n.clip != 0) b.pitchClipFree(Pointer<Void>.fromAddress(n.clip));
  if (n.left != 0) malloc.free(Pointer<Float>.fromAddress(n.left));
  if (n.right != 0) malloc.free(Pointer<Float>.fromAddress(n.right));
}

/// Runs [entry] on a new isolate with [args] and a port: a double it posts is progress (0..1, or -1: can't tell), a
/// string a stage; its last message ([#done, value]) is the result. A string result is an error.
Future<Object?> _work(PitchJob<Object?> job, void Function(List<Object?>) entry, List<Object?> args) async {
  final port = ReceivePort();
  final done = Completer<Object?>();
  port.listen((m) {
    if (m is double) {
      job.progress.value = m < 0 ? null : m;
    } else if (m is String) {
      job.stage.value = m;
    } else if (m is List && m.length == 2 && m[0] == '#done') {
      done.complete(m[1]);
    } else if (m == null && !done.isCompleted) {
      done.complete('the worker stopped');
    }
  });
  try {
    await Isolate.spawn(entry, [port.sendPort, ...args], onExit: port.sendPort, onError: port.sendPort);
  } catch (e) {
    port.close();
    return '$e';
  }
  final r = await done.future;
  port.close();
  return r;
}

/// Decodes [path] through the asset store (one frame a peaks bucket: the min plus the max is the sample), then
/// analyses it. Posts [json, clip, left, right, frames, midi, voicing, rms] or an error.
void _analyseEntry(List<Object?> m) {
  final port = m[0] as SendPort;
  final engine = Pointer<Void>.fromAddress(m[1] as int);
  final path = m[2] as String;
  final cancel = Pointer<Int32>.fromAddress(m[3] as int);
  final ab = AudioBindings.instance, b = Bindings.instance;
  void finish(Object? v) => port.send(['#done', v]);
  final p = path.toNativeUtf8();
  Pointer<Float> left = nullptr, right = nullptr;
  final peaks = malloc<Float>(2 * _chunk);
  void freeAll() {
    if (left != nullptr) malloc.free(left);
    if (right != nullptr) malloc.free(right);
  }

  try {
    final info = jsonDecode(ab.take(ab.assetLoad(engine, p))) as Map<String, dynamic>;
    if (info['ok'] != true) return finish('${info['error'] ?? 'the file would not load'}');
    final frames = (info['frames'] as num).toInt(), channels = (info['channels'] as num).toInt();
    final rate = (info['sample_rate'] as num).toInt();
    if (frames <= 0 || rate <= 0) return finish('the file is empty');
    if (frames > kMaxPitchClipSeconds * rate) return finish('the clip is over 30 minutes');
    left = malloc<Float>(frames);
    if (channels > 1) right = malloc<Float>(frames);
    final total = frames * (channels > 1 ? 2 : 1);
    var read = 0;
    for (var ch = 0; ch < (channels > 1 ? 2 : 1); ch++) {
      final dst = ch == 0 ? left : right;
      for (var k = 0; k < frames; k += _chunk) {
        if (cancel.value != 0) {
          freeAll();
          return finish('cancelled');
        }
        final n = (frames - k).clamp(1, _chunk);
        // A quarter frame in, so the floor lands on frame k and k + n.
        final got = ab.assetPeaks(engine, p, (k + 0.25) / rate, (k + n + 0.25) / rate, n, ch, peaks);
        if (got != n) {
          freeAll();
          return finish('the file could not be read');
        }
        for (var i = 0; i < n; i++) {
          dst[k + i] = peaks[2 * i] + peaks[2 * i + 1];
        }
        read += n;
        port.send(0.8 * read / total);
      }
    }
    port.send('Listening');
    port.send(-1.0);
    final out = calloc<Pointer<Void>>();
    try {
      final json = b.take(b.pitchClipAnalyse(left, right, frames, rate, nullptr, out));
      final clip = out.value;
      if (clip == nullptr) {
        freeAll();
        final j = jsonDecode(json);
        return finish(j is Map ? '${j['error'] ?? 'the analysis failed'}' : 'the analysis failed');
      }
      final hops = b.pitchClipCurve(clip, nullptr, nullptr, nullptr, 0).clamp(0, kMaxPitchHops);
      final mi = malloc<Float>(hops + 1), vo = malloc<Float>(hops + 1), rm = malloc<Float>(hops + 1);
      b.pitchClipCurve(clip, mi, vo, rm, hops);
      final curves = [Float32List.fromList(mi.asTypedList(hops)), Float32List.fromList(vo.asTypedList(hops)),
        Float32List.fromList(rm.asTypedList(hops))];
      malloc.free(mi);
      malloc.free(vo);
      malloc.free(rm);
      finish([json, clip.address, left.address, right.address, frames, ...curves]);
    } finally {
      calloc.free(out);
    }
  } catch (e) {
    freeAll();
    finish('$e');
  } finally {
    calloc.free(p);
    malloc.free(peaks);
  }
}

extension on Bindings {
  String take(Pointer<Utf8> s) {
    if (s == nullptr) return '{}';
    try {
      return s.toDartString();
    } finally {
      free(s);
    }
  }
}

/// Renders the clip with the edits and writes the result to the path as a 32-bit float WAV; posts the notes edited
/// or an error.
void _renderEntry(List<Object?> m) {
  final port = m[0] as SendPort;
  final clip = Pointer<Void>.fromAddress(m[1] as int);
  final left = Pointer<Float>.fromAddress(m[2] as int), right = Pointer<Float>.fromAddress(m[3] as int);
  final frames = m[4] as int, rate = m[5] as int;
  final edits = (m[6] as String).toNativeUtf8();
  final path = m[7] as String;
  final b = Bindings.instance;
  final stereo = right != nullptr;
  final outL = malloc<Float>(frames), outR = stereo ? malloc<Float>(frames) : nullptr;
  void finish(Object? v) => port.send(['#done', v]);
  try {
    final j = jsonDecode(b.take(b.pitchClipRender(clip, left, right, frames, edits, outL, outR)));
    if (j is! Map || j['ok'] != true) return finish(j is Map ? '${j['error'] ?? 'the render failed'}' : 'the render failed');
    port.send('Writing');
    writeFloatWav(path, rate, [outL.asTypedList(frames), if (stereo) outR.asTypedList(frames)],
        onProgress: (f) => port.send(f));
    finish((j['notes_edited'] as num?)?.toInt() ?? 0);
  } catch (e) {
    finish('$e');
  } finally {
    calloc.free(edits);
    malloc.free(outL);
    if (stereo) malloc.free(outR);
  }
}

/// Writes [channels] (one or two, the same length) at [rate] to [path] as a 32-bit float WAV, a chunk at a time.
void writeFloatWav(String path, int rate, List<Float32List> channels, {void Function(double done)? onProgress}) {
  final ch = channels.length, frames = channels.first.length;
  final data = frames * ch * 4;
  final head = ByteData(58);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      head.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  head.setUint32(4, 50 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  head
    ..setUint32(16, 18, Endian.little)
    ..setUint16(20, 3, Endian.little) // IEEE float
    ..setUint16(22, ch, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * ch * 4, Endian.little)
    ..setUint16(32, ch * 4, Endian.little)
    ..setUint16(34, 32, Endian.little)
    ..setUint16(36, 0, Endian.little);
  tag(38, 'fact');
  head
    ..setUint32(42, 4, Endian.little)
    ..setUint32(46, frames, Endian.little);
  tag(50, 'data');
  head.setUint32(54, data, Endian.little);
  final f = File(path);
  f.parent.createSync(recursive: true);
  final raf = f.openSync(mode: FileMode.write);
  try {
    raf.writeFromSync(head.buffer.asUint8List());
    final buf = Float32List(_chunk * ch);
    for (var k = 0; k < frames; k += _chunk) {
      final n = (frames - k).clamp(0, _chunk);
      for (var i = 0; i < n; i++) {
        for (var c = 0; c < ch; c++) {
          buf[i * ch + c] = channels[c][k + i];
        }
      }
      raf.writeFromSync(buf.buffer.asUint8List(0, n * ch * 4));
      onProgress?.call((k + n) / frames);
    }
  } finally {
    raf.closeSync();
  }
}
