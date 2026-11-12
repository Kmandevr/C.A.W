// Renders the music video offline and deterministically: the audio through the engine's song render (a worker-pool
// job), its meters from the files, then each frame drawn off screen at the render clock's time and streamed to the encoder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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

/// One render: [run] it once; [cancel] stops it at the next frame (or the audio render at its next block).
class MusicVideoRender extends ChangeNotifier {
  MusicVideoRender({required this.projectJson, required this.scene, required this.options, required this.startStep,
      required this.endStep, required this.encoder, required this.workDir, SongRenderStarter? audio, this.timeline})
      : _audio = audio ?? startNativeSongRender;

  /// The edited lane's shots (null or empty: the auto director's).
  final VideoTimeline? timeline;
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
  Future<File?> run() async {
    final (width, height) = options.size;
    final audioDir = Directory('${workDir.path}${Platform.pathSeparator}audio');
    var encoding = false;
    try {
      if (await workDir.exists()) await workDir.delete(recursive: true);
      await audioDir.create(recursive: true);

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

      // 2. The meters, from the files.
      _set(VideoRenderPhase.analysis, 0.25);
      final meters = await analyzeVideoAudio(mixPath: mix, stems: stems, fps: options.fps, frames: frameCount);
      if (_cancelled) return await _stop();

      // 3. Frames, one at a time at the render clock's time, straight into the encoder.
      final file = File('${workDir.path}${Platform.pathSeparator}video.${encoder.extension}');
      await encoder.start(VideoEncodeConfig(width: width, height: height, fps: options.fps, bitrate: options.bitrate,
          audioPath: mix, outputPath: file.path));
      encoding = true;
      _set(VideoRenderPhase.frames, 0.3);
      for (var n = 0; n < frameCount; n++) {
        if (_cancelled) return await _stop(encoding: true);
        final input = VideoFrameInput.forOptions(scene: scene, plan: plan, step: clock.stepAt(n),
            seconds: clock.secondsAt(n), options: options, levels: meters.levelsAt(n));
        final rgba = await rasterizeVideoFrame(input, width, height);
        await encoder.addFrame(rgba);
        framesDrawn = n + 1;
        if (n % 2 == 0 || n == frameCount - 1) _set(VideoRenderPhase.frames, 0.3 + 0.68 * framesDrawn / frameCount);
      }
      if (_cancelled) return await _stop(encoding: true);

      // 4. The file.
      _set(VideoRenderPhase.finishing, 0.98);
      await encoder.finish();
      encoding = false;
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
