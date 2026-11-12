// The music video's quick preview: the plan's shots (the lane's, or the director's) drawn live in a fixed-size frame while the song plays
// (the engine's playhead and meters), with play/stop and a scrub; nothing is rendered or saved.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../model/app_state.dart';
import '../../model/music_video.dart';
import '../../model/music_video_director.dart';
import '../../model/music_video_meters.dart';
import '../../model/music_video_scene.dart';
import '../haptics.dart';
import '../theme.dart';
import 'video_painter.dart';

/// The preview's frame: the target's aspect ratio at this many logical pixels on the short side, scaled to fit.
const double kPreviewShortSide = 360;

class MusicVideoPreview extends StatefulWidget {
  const MusicVideoPreview({super.key, required this.state, required this.scene, required this.plan,
      required this.options, required this.start, required this.end, this.position});
  final AppState state;
  final VideoScene scene;
  final ShotPlan plan;
  final MusicVideoOptions options;
  final double start, end;

  /// Where the preview is (song steps), for the shot lane's playhead.
  final ValueNotifier<double>? position;

  @override
  State<MusicVideoPreview> createState() => MusicVideoPreviewState();
}

class MusicVideoPreviewState extends State<MusicVideoPreview> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late double _step = widget.start;
  bool _playing = false;

  // With the engine: its playhead. Without one (no sound card, tests): a silent clock from where play started.
  bool _live = false;
  final Stopwatch _silent = Stopwatch();
  double _silentFrom = 0;
  VideoLevels _levels = VideoLevels.silent;

  bool get playing => _playing;
  double get step => _step;

  AppState get s => widget.state;

  @override
  void didUpdateWidget(MusicVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_step < widget.start || _step > widget.end) _step = widget.start;
    _repaint.value++;
  }

  @override
  void dispose() {
    if (_playing) _stopTransport();
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void play() {
    if (_playing) return;
    Haptics.tap();
    if (_step >= widget.end - 0.01) _step = widget.start;
    _live = s.engine != null;
    if (_live) {
      s.seekTo(_step);
      if (!s.transportOn) s.togglePlay();
      _live = s.transportOn;
    }
    _silentFrom = _step;
    _silent
      ..reset()
      ..start();
    setState(() => _playing = true);
    if (!_ticker.isActive) _ticker.start();
  }

  void stop() {
    if (!_playing) return;
    Haptics.tap();
    _stopTransport();
    setState(() => _playing = false);
  }

  void _stopTransport() {
    _ticker.stop();
    _silent.stop();
    if (_live && s.transportOn) s.togglePlay(); // a pause, so the song stays where the preview was
    _live = false;
  }

  /// Moves the preview to [v] (the lane's cursor), playing on from there if it plays.
  void seek(double v) => _scrub(v.clamp(widget.start, widget.end).toDouble());

  void _scrub(double v) {
    setState(() => _step = v);
    widget.position?.value = v;
    if (_playing) {
      if (_live) s.seekTo(v);
      _silentFrom = v;
      _silent
        ..reset()
        ..start();
    }
    _repaint.value++;
  }

  void _tick(Duration _) {
    if (!_playing) return;
    final st = _live ? s.playheadStep : _silentFrom + _silent.elapsedMicroseconds / 1e6 * widget.scene.bpm / 15;
    // Live meters, held and falling as the render's are.
    if (_live) {
      final m = s.audibleMeters;
      final heard = s.audibleLayerMeters;
      final tracks = <String, double>{};
      for (var i = 0; i < heard.length && i < s.project.layers.length; i++) {
        tracks[s.project.layers[i].id] = math.max(heard[i].peak, (_levels.tracks[s.project.layers[i].id] ?? 0) * 0.9);
      }
      _levels = VideoLevels(peakL: math.max(m.peakL, _levels.peakL * 0.9), peakR: math.max(m.peakR, _levels.peakR * 0.9),
          rms: math.max((m.peakL + m.peakR) * 0.35, _levels.rms * 0.9), tracks: tracks);
    }
    if (st >= widget.end || (_live && !s.transportOn)) {
      _step = math.min(st, widget.end);
      stop();
      return;
    }
    setState(() => _step = math.max(widget.start, st));
    widget.position?.value = _step;
    _repaint.value++;
  }

  VideoFrameInput _input() => VideoFrameInput.forOptions(scene: widget.scene, plan: widget.plan, step: _step,
      seconds: (_step - widget.start) * 15 / widget.scene.bpm, options: widget.options, levels: _levels);

  @override
  Widget build(BuildContext context) {
    final (w, h) = widget.options.size;
    final ratio = w / h;
    final logical = ratio >= 1
        ? Size(kPreviewShortSide * ratio, kPreviewShortSide)
        : Size(kPreviewShortSide, kPreviewShortSide / ratio);
    final shot = widget.plan.at(_step);
    final label = shot.panelShots.length > 1 ? shot.layout!.preset.label : shot.kind.label;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: Center(child: AspectRatio(
          aspectRatio: ratio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: FittedBox(fit: BoxFit.contain, child: SizedBox.fromSize(
              size: logical,
              child: RepaintBoundary(child: CustomPaint(
                key: const ValueKey('video-preview-frame'),
                painter: VideoFramePainter(_input, repaint: _repaint),
                size: logical,
              )),
            )),
          ),
        )),
      ),
      const SizedBox(height: 6),
      Row(children: [
        IconButton.filledTonal(
          key: const ValueKey('video-preview-play'),
          tooltip: _playing ? 'Stop the preview' : 'Play the preview',
          onPressed: _playing ? stop : play,
          icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
        ),
        Expanded(child: Slider(
          key: const ValueKey('video-preview-scrub'),
          min: widget.start,
          max: math.max(widget.start + 1, widget.end),
          value: _step.clamp(widget.start, math.max(widget.start + 1, widget.end)).toDouble(),
          onChanged: _scrub,
        )),
        SizedBox(width: 92, child: Text(
          '${label.toUpperCase()} · ${widget.plan.indexAt(_step) + 1}/${widget.plan.shots.length}',
          maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right,
          style: const TextStyle(color: Neon.dim, fontSize: 10),
        )),
      ]),
    ]);
  }
}
