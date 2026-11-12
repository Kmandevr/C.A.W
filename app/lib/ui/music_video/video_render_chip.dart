// The background music video render's chip over the app (owner, 2026-11-12): while it renders, its progress (a tap
// opens the sheet, × cancels); when it is done, a notice with Save; when it fails, why. Animated in and out through the
// motion tokens. Rendering goes on only while the app is open.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../platform/video_encoder.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'video_kit.dart';
import 'video_render.dart';
import 'video_setup_sheet.dart';

/// [child] with the render chip over its bottom right, above the phone's section bar.
class VideoRenderOverlay extends StatelessWidget {
  const VideoRenderOverlay({super.key, required this.state, required this.child, this.jobs});
  final AppState state;
  final Widget child;

  /// The jobs to show (tests pass their own; the app has one).
  final MusicVideoJobs? jobs;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Stack(children: [
      Positioned.fill(child: child),
      Positioned(right: 12, bottom: bottom + 112, child: VideoRenderChip(state: state, jobs: jobs ?? MusicVideoJobs.instance)),
    ]);
  }
}

class VideoRenderChip extends StatefulWidget {
  const VideoRenderChip({super.key, required this.state, required this.jobs});
  final AppState state;
  final MusicVideoJobs jobs;

  @override
  State<VideoRenderChip> createState() => _VideoRenderChipState();
}

class _VideoRenderChipState extends State<VideoRenderChip> {
  String? _saved;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.jobs,
        builder: (context, _) {
          final level = Motion.of(context);
          final r = widget.jobs.render;
          // Shown while a render runs and once it ends (until dismissed); not while the sheet itself is open over it.
          final show = r != null && r.phase != VideoRenderPhase.idle;
          final Widget body = !show ? const SizedBox.shrink(key: ValueKey('none')) : _body(context, r);
          return AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, level),
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: level == MotionLevel.full
                ? ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(a), child: c)
                : c),
            child: body,
          );
        },
      );

  Widget _body(BuildContext context, MusicVideoRender r) {
    final running = r.running;
    final failed = r.phase == VideoRenderPhase.failed;
    final done = r.output != null && !running;
    final color = failed ? Neon.pink : (done ? Neon.green : videoAccent);
    final label = running
        ? '${r.draft ? 'Draft' : 'Video'} ${(r.progress * 100).round()}%'
        : done
            ? (_saved ?? '${r.draft ? 'Draft' : 'Video'} ready')
            : failed
                ? 'Video failed'
                : 'Video cancelled';
    return Material(
      key: ValueKey(running ? 'running' : (done ? 'done' : 'ended')),
      color: Colors.transparent,
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: Neon.panel.withValues(alpha: 0.95),
          border: Border.all(color: color),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 12)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            key: const ValueKey('video-chip'),
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              Haptics.tap();
              showMusicVideoSheet(context, widget.state);
            },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (running)
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(value: r.progress, strokeWidth: 2.4, color: color))
              else
                Icon(done ? Icons.check_circle : Icons.error_outline, size: 18, color: color),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: Motion.fade(Motion.small, Motion.of(context)),
                child: Text(label, key: ValueKey(label), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
          if (done && _saved == null)
            TextButton(key: const ValueKey('video-chip-save'), onPressed: () async {
              final (_, line) = await saveMusicVideo(r, widget.jobs.name, platformVideoEncoder());
              if (mounted) setState(() => _saved = line.length > 28 ? '${line.substring(0, 27)}…' : line);
            }, child: const Text('Save')),
          IconButton(
            key: const ValueKey('video-chip-close'),
            tooltip: running ? 'Cancel the render' : 'Dismiss',
            iconSize: 16,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            onPressed: () {
              Haptics.tap();
              if (running) {
                widget.jobs.cancel();
              } else {
                _saved = null;
                widget.jobs.dismiss();
              }
            },
            icon: const Icon(Icons.close),
          ),
        ]),
      ),
    );
  }
}
