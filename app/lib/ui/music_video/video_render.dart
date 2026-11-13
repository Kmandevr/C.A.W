// Renders the music video offline and deterministically: the audio through the engine's song render (a worker-pool
// job), its meters from the files, then each frame drawn off screen at the render clock's time and streamed to the
// encoder, the next frames rasterising while one encodes; a profile of where the time went, drafts, and the one
// render that runs in the background while the user works (MusicVideoJobs).
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../model/busy_work.dart';
import '../../model/music_video.dart';
import '../../model/music_video_director.dart';
import '../../model/music_video_edit.dart';
import '../../model/music_video_meters.dart';
import '../../model/music_video_scene.dart';
import '../../model/song_export.dart';
import '../../model/music_video_autocut.dart' show audioLoudness;
import '../../platform/video_encoder.dart';
import 'video_painter.dart';

enum VideoRenderPhase {
  idle('Ready'),
  audio('Rendering the audio'),
  analysis('Reading the levels'),
  frames('Drawing frames'),
  finishing('Writing the file'),
  done('Done'),
  cancelled('Cancelled'),
  failed('Failed');

  const VideoRenderPhase(this.label);
  final String label;
}

/// The audio's sample rate (AAC at 48 kHz on both platform encoders).
const int kVideoSampleRate = 48000;

/// Where a render's time went (owner, 2026-11-12: "really slow to build the video"; profile first). Each stage's
/// time is the time spent in it; with the pipeline the frame stages overlap, so they add up to more than [wall].
class VideoRenderProfile {
  int audioUs = 0, analysisUs = 0, paintUs = 0, rasterUs = 0, readbackUs = 0, encodeUs = 0, waitUs = 0, wallUs = 0;
  int frames = 0;
  double videoSeconds = 0;

  /// Seconds of work per second of video (lower is faster; below 1 is faster than real time).
  double get secondsPerSecond => videoSeconds <= 0 ? 0 : wallUs / 1e6 / videoSeconds;

  /// The frame stages per frame, in milliseconds.
  double perFrameMs(int us) => frames == 0 ? 0 : us / 1000 / frames;

  Map<String, Object> toJson() => {
        'frames': frames, 'video_s': videoSeconds, 'wall_s': wallUs / 1e6, 's_per_s': secondsPerSecond,
        'audio_s': audioUs / 1e6, 'analysis_s': analysisUs / 1e6, 'paint_ms_frame': perFrameMs(paintUs),
        'raster_ms_frame': perFrameMs(rasterUs), 'readback_ms_frame': perFrameMs(readbackUs),
        'encode_ms_frame': perFrameMs(encodeUs), 'waiting_for_encoder_ms_frame': perFrameMs(waitUs),
      };

  /// One line for the done notice and the log.
  String get summary => '${secondsPerSecond.toStringAsFixed(2)} s per second of video '
      '(audio ${(audioUs / 1e6).toStringAsFixed(1)} s; a frame: paint ${perFrameMs(paintUs).toStringAsFixed(1)} ms, '
      'raster ${perFrameMs(rasterUs).toStringAsFixed(1)} ms, read ${perFrameMs(readbackUs).toStringAsFixed(1)} ms, '
      'encode ${perFrameMs(encodeUs).toStringAsFixed(1)} ms)';
}

/// How many frames may be rasterising or waiting for the encoder at once: up to 3, and no more than about 64 MB of
/// frames in memory (one frame at 4K is 33 MB).
int videoPipelineDepth(int width, int height) => (64 * 1024 * 1024 ~/ math.max(1, width * height * 4)).clamp(1, 3);

/// One render: [run] it once; [cancel] stops it at the next frame (or the audio render at its next block).
class MusicVideoRender extends ChangeNotifier {
  MusicVideoRender({required this.projectJson, required this.scene, required this.options, required this.startStep,
      required this.endStep, required this.encoder, required this.workDir, SongRenderStarter? audio, this.timeline,
      this.doc, this.bitmaps = const {}, this.draft = false, int? pipelineDepth})
      : _audio = audio ?? startNativeSongRender,
        pipelineDepth = pipelineDepth ?? videoPipelineDepth(options.size.$1, options.size.$2);

  /// The edited lane's shots (null or empty: the auto director's).
  final VideoTimeline? timeline;

  /// The whole video's overlays and the decoded images they and the shots use.
  final MusicVideoDoc? doc;
  final Map<String, ui.Image> bitmaps;

  /// A quick draft (low size and rate) rather than the full render.
  final bool draft;

  /// Frames in flight: 1 draws, rasterises and encodes each frame before the next (as before 2026-11-12).
  final int pipelineDepth;

  /// Where the time went, filled in as it runs.
  final profile = VideoRenderProfile();
  late final ShotPlan plan =
      planVideo(scene, options, timeline, start: startStep.toDouble(), end: endStep.toDouble());

  final String projectJson;
  final VideoScene scene;
  final MusicVideoOptions options;
  final int startStep, endStep;
  final VideoEncoder encoder;
  final Directory workDir;
  final SongRenderStarter _audio;

  VideoRenderPhase phase = VideoRenderPhase.idle;
  double progress = 0;
  String? error;
  File? output;
  int framesDrawn = 0;
  late final FrameClock clock =
      FrameClock(fps: options.fps, startStep: startStep.toDouble(), endStep: endStep.toDouble(), bpm: scene.bpm);
  int get frameCount => clock.frameCount;

  bool _cancelled = false;
  SongRenderHandle? _audioJob;

  bool get running => phase.index > VideoRenderPhase.idle.index && phase.index < VideoRenderPhase.done.index;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _audioJob?.cancel();
  }

  void _set(VideoRenderPhase p, double v) {
    phase = p;
    progress = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// The engine request for the audio: the range once through, no tail, 16-bit at 48 kHz, with track stems when a
  /// mixer view or an effect following a track wants their meters.
  Map<String, dynamic> audioRequest(String outDir) => {
        'out_dir': outDir,
        'project': 'video',
        'pattern': '{kind}_{index}',
        'mix': true,
        'tracks': planNeedsStems(plan),
        'buses': false,
        'bounds': 'selection',
        'start_steps': startStep,
        'end_steps': endStep,
        'sample_rate': kVideoSampleRate,
        'bit_depth': 16,
        'dither': true,
        'normalize': 'none',
        'tail': 'none',
      };

  /// Renders everything; the finished file (in [workDir]) or null when cancelled or failed ([error] says why).
  Future<File?> run() => BusyWork.during(_run); // no automatic update installs under a render

  Future<File?> _run() async {
    final (width, height) = options.size;
    final audioDir = Directory('${workDir.path}${Platform.pathSeparator}audio');
    var encoding = false;
    try {
      if (await workDir.exists()) await workDir.delete(recursive: true);
      await audioDir.create(recursive: true);

      final wall = Stopwatch()..start();
      // 1. The audio.
      _set(VideoRenderPhase.audio, 0);
      final job = _audio(projectJson, jsonEncode(audioRequest(audioDir.path)));
      _audioJob = job;
      final poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _set(VideoRenderPhase.audio, job.progress * 0.25));
      final String? out;
      try {
        out = await job.result;
      } finally {
        poll.cancel();
        _audioJob = null;
      }
      if (_cancelled) return await _stop();
      final parsed = out == null ? null : jsonDecode(out);
      if (parsed is! Map || parsed['ok'] != true) {
        final message = parsed is Map ? parsed['error'] as String? : out;
        if (message == 'cancelled') return await _stop();
        throw StateError(message ?? 'the audio render failed');
      }
      String? mix;
      final stems = <String, String>{};
      for (final f in (parsed['files'] as List? ?? const [])) {
        if (f is! Map || f['path'] is! String) continue;
        if (f['kind'] == 'mix') mix ??= f['path'] as String;
        if (f['kind'] == 'track' && f['layer'] is String) stems[f['layer'] as String] = f['path'] as String;
      }
      if (mix == null) throw StateError('the audio render wrote no mix');
      profile.audioUs = wall.elapsedMicroseconds;

      // 2. The meters, from the files.
      _set(VideoRenderPhase.analysis, 0.25);
      final meters = await analyzeVideoAudio(mixPath: mix, stems: stems, fps: options.fps, frames: frameCount);
      profile.analysisUs = wall.elapsedMicroseconds - profile.audioUs;
      if (_cancelled) return await _stop();

      // 3. Frames, one at a time at the render clock's time, straight into the encoder.
      final file = File('${workDir.path}${Platform.pathSeparator}video.${encoder.extension}');
      await encoder.start(VideoEncodeConfig(width: width, height: height, fps: options.fps, bitrate: options.bitrate,
          audioPath: mix, outputPath: file.path));
      encoding = true;
      _set(VideoRenderPhase.frames, 0.3);
      profile.videoSeconds = clock.durationSeconds;
      VideoFrameInput input(int n) => VideoFrameInput.forOptions(scene: scene, plan: plan, step: clock.stepAt(n),
          seconds: clock.secondsAt(n), options: options, levels: meters.levelsAt(n), doc: doc, bitmaps: bitmaps,
          rangeStart: startStep.toDouble(), rangeEnd: endStep.toDouble());
      // A frame: recorded here (Flutter records pictures only on the UI isolate), then rasterised and read back by
      // the engine's raster thread while this goes on with the next.
      Future<Uint8List> raster(int n) {
        final sw = Stopwatch()..start();
        final picture = recordVideoFrame(input(n), width, height);
        profile.paintUs += sw.elapsedMicroseconds;
        return pictureToRgba(picture, width, height, timing: (r, b) {
          profile.rasterUs += r;
          profile.readbackUs += b;
        });
      }

      Future<void> encode(Uint8List rgba) async {
        final sw = Stopwatch()..start();
        await encoder.addFrame(rgba);
        profile.encodeUs += sw.elapsedMicroseconds;
      }

      // Rasters run ahead, each held (see [heldFuture]) so one failing before its turn is thrown at its turn, in
      // frame order, not lost as an unhandled error. Only one addFrame is ever in flight: the Android encoder's
      // frame channel copies frames into two reused buffers (VideoEncoder.kt's frameHandler), so a second frame
      // sent before the last one's reply could overwrite a buffer the worker is still reading.
      final queue = Queue<Future<Uint8List> Function()>();
      Future<void> Function()? sending;
      var next = 0;
      try {
        for (var n = 0; n < frameCount; n++) {
          if (_cancelled) break;
          // Keep up to [pipelineDepth] frames rasterising ahead (1: one at a time, as before).
          while (queue.length < pipelineDepth && next < frameCount) {
            queue.add(heldFuture(raster(next++)));
          }
          final rgba = await queue.removeFirst()();
          if (sending != null) {
            final sw = Stopwatch()..start();
            await sending();
            sending = null;
            profile.waitUs += sw.elapsedMicroseconds;
          }
          if (_cancelled) break;
          sending = heldFuture(encode(rgba));
          // One at a time: the frame is encoded before the next is drawn.
          if (pipelineDepth <= 1) {
            await sending();
            sending = null;
          }
          framesDrawn = n + 1;
          profile.frames = framesDrawn;
          if (n % 2 == 0 || n == frameCount - 1) _set(VideoRenderPhase.frames, 0.3 + 0.68 * framesDrawn / frameCount);
        }
        await sending?.call();
      } finally {
        // Frames still rasterising when it stops (a cancel or a failure) are let go: their outcomes are already held.
        queue.clear();
      }
      if (_cancelled) return await _stop(encoding: true);
      profile.wallUs = wall.elapsedMicroseconds;

      // 4. The file.
      _set(VideoRenderPhase.finishing, 0.98);
      await encoder.finish();
      encoding = false;
      profile.wallUs = wall.elapsedMicroseconds;
      debugPrint('Music video ${draft ? 'draft' : 'render'}: ${profile.summary}');
      await _clean(audioDir);
      output = file;
      _set(VideoRenderPhase.done, 1);
      return file;
    } catch (e) {
      if (encoding) await encoder.cancel();
      await _clean(audioDir);
      if (_cancelled) return await _stop();
      error = e is StateError ? e.message : '$e';
      _set(VideoRenderPhase.failed, progress);
      return null;
    }
  }

  Future<File?> _stop({bool encoding = false}) async {
    if (encoding) await encoder.cancel();
    await _clean(workDir);
    _set(VideoRenderPhase.cancelled, progress);
    return null;
  }

  Future<void> _clean(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // Left for the next render, which clears the folder first.
    }
  }
}

/// [f] with its outcome caught as soon as it settles (so a failure before anyone awaits it is not an unhandled error);
/// calling the result gives the value, or throws the error with its stack trace, when the caller gets to it.
@visibleForTesting
Future<T> Function() heldFuture<T>(Future<T> f) {
  final settled = f.then<(T?, Object?, StackTrace?)>((v) => (v, null, null),
      onError: (Object e, StackTrace st) => (null, e, st));
  return () async {
    final (v, e, st) = await settled;
    if (e != null) Error.throwWithStackTrace(e, st ?? StackTrace.empty);
    return v as T;
  };
}

/// Auto-cut's loudness from the rendered audio: the range's mix through the engine's song render (a worker-pool job),
/// its meters read in a background isolate, then the RMS per beat in dB. Null when cancelled ([cancelled] is
/// polled) or when the render fails.
Future<List<double>?> analyzeSongLoudness({required String projectJson, required VideoScene scene, required int startStep,
    required int endStep, required Directory workDir, SongRenderStarter? audio, bool Function()? cancelled}) async {
  const fps = 20;
  final dir = Directory('${workDir.path}${Platform.pathSeparator}loudness');
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final job = (audio ?? startNativeSongRender)(projectJson, jsonEncode({
      'out_dir': dir.path, 'project': 'video', 'pattern': '{kind}_{index}', 'mix': true, 'tracks': false,
      'buses': false, 'bounds': 'selection', 'start_steps': startStep, 'end_steps': endStep,
      'sample_rate': kVideoSampleRate, 'bit_depth': 16, 'dither': false, 'normalize': 'none', 'tail': 'none',
    }));
    final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (cancelled?.call() ?? false) job.cancel();
    });
    final String? out;
    try {
      out = await job.result;
    } finally {
      poll.cancel();
    }
    if (cancelled?.call() ?? false) return null;
    final parsed = out == null ? null : jsonDecode(out);
    if (parsed is! Map || parsed['ok'] != true) return null;
    final mix = [for (final f in (parsed['files'] as List? ?? const [])) if (f is Map && f['kind'] == 'mix') f['path']]
        .whereType<String>()
        .firstOrNull;
    if (mix == null) return null;
    final clock = FrameClock(fps: fps, startStep: startStep.toDouble(), endStep: endStep.toDouble(), bpm: scene.bpm);
    final meters = await analyzeVideoAudio(mixPath: mix, fps: fps, frames: clock.frameCount);
    return audioLoudness(meters, fps: fps, bpm: scene.bpm, start: startStep.toDouble(), end: endStep.toDouble());
  } finally {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Left for the next analysis, which clears the folder first.
    }
  }
}

/// The music video render running in the background (one at a time) while the user works elsewhere (owner,
/// 2026-11-12): the sheet starts it, the shell's progress chip shows it, and its done notice offers Save. It runs
/// only while the app is open: no foreground service keeps it alive.
class MusicVideoJobs extends ChangeNotifier {
  MusicVideoJobs._();
  static final instance = MusicVideoJobs._();

  MusicVideoRender? _render;
  String _name = 'video';

  /// The render running or last finished (until [dismiss]).
  MusicVideoRender? get render => _render;
  bool get running => _render?.running ?? false;

  /// The project name the file is saved under.
  String get name => _name;

  /// Starts [render] (the last one must have finished) and returns its file, or null.
  Future<File?> start(MusicVideoRender render, {required String name}) async {
    if (running) throw StateError('a music video is already rendering');
    _render?.removeListener(notifyListeners);
    _render = render..addListener(notifyListeners);
    _name = name;
    notifyListeners();
    final out = await render.run();
    notifyListeners();
    return out;
  }

  /// Cancels the render running.
  void cancel() => _render?.cancel();

  /// Forgets a finished render (its notice goes).
  void dismiss() {
    if (running) return;
    _render?.removeListener(notifyListeners);
    _render = null;
    notifyListeners();
  }
}
