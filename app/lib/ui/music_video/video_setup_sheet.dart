// The Music video sheet (Export page and project menu): the live preview, the editor (shot lane, shot list,
// auto-cut), the director's shots, style, smooth follow, range, aspect, resolution, frame rate and title card in the
// device kit's look, and the offline render with progress, cancel and the save picker. Edits save with the project.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/music_video.dart';
import '../../model/music_video_director.dart';
import '../../model/music_video_edit.dart';
import '../../model/music_video_scene.dart';
import '../../model/project.dart';
import '../../model/song_export.dart';
import '../../platform/save_copy.dart';
import '../../platform/video_encoder.dart';
import '../arrange/track_color.dart';
import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';
import '../widgets.dart';
import 'video_editor.dart';
import 'video_preview.dart';
import 'video_kit.dart';
import 'video_render.dart';

Color get _second => Neon.violet;

/// The setup the sheet last used, for the next time it opens (this run of the app).
MusicVideoOptions? _lastOptions;

/// Opens the Music video sheet for [state]'s project. Tests pass an [encoder], an [audio] render and a [workDir].
Future<void> showMusicVideoSheet(BuildContext context, AppState state,
    {VideoEncoder? encoder, SongRenderStarter? audio, Directory? workDir}) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.94),
      child: MusicVideoPanel(state: state, encoder: encoder, audio: audio, workDir: workDir),
    ),
  );
}

/// The scene for [s]'s project, with the on-screen track colours and the native parameter ranges.
VideoScene videoSceneFor(AppState s) {
  final p = s.project;
  ({double lo, double hi})? range(String componentId, String param) {
    final info = s.componentInfo(componentId);
    final q = info?.parameters.where((x) => x.id == param).firstOrNull;
    return q == null || q.max <= q.min ? null : (lo: q.min, hi: q.max);
  }

  return buildVideoScene(
    p,
    colorOf: (l) => trackColor(s, l).toARGB32(),
    deviceName: (u) => s.componentLabel(u.id),
    paramRange: (u, param) => range(u.id, param),
    laneRange: (lane) {
      final layer = p.layers.where((l) => l.id == lane.layerId).firstOrNull;
      final ComponentUseDoc? use = lane.targetType == 'instrument'
          ? layer?.instrument
          : switch (lane.component) {
              final int c when layer != null && c >= 0 && c < layer.components.length => layer.components[c],
              final int c when layer == null && c >= 0 && c < p.masterComponents.length => p.masterComponents[c],
              _ => null,
            };
      return use == null ? null : range(use.id, lane.target);
    },
  );
}

class MusicVideoPanel extends StatefulWidget {
  const MusicVideoPanel({super.key, required this.state, this.encoder, this.audio, this.workDir});
  final AppState state;
  final VideoEncoder? encoder;
  final SongRenderStarter? audio;
  final Directory? workDir;

  @override
  State<MusicVideoPanel> createState() => _MusicVideoPanelState();
}

class _MusicVideoPanelState extends State<MusicVideoPanel> {
  /// The video as the project saved it (versioned), or a new one with the setup last used.
  late final MusicVideoDoc _doc = p.musicVideo != null
      ? MusicVideoDoc.fromJson(p.musicVideo, maxStep: p.maxArrangementSteps.toDouble())
      : MusicVideoDoc(options: _lastOptions?.copy());
  MusicVideoOptions get o => _doc.options;
  final _position = ValueNotifier<double>(0);
  final _previewKey = GlobalKey<MusicVideoPreviewState>();
  late final VideoEncoder _encoder = widget.encoder ?? platformVideoEncoder();
  VideoEncoderCaps _caps = VideoEncoderCaps.fallback;
  late bool _customAspect = !VideoAspect.presets.contains(o.aspect);
  late final _title = TextEditingController(text: o.title);
  late final _artist = TextEditingController(text: o.artist);
  late final _aw = TextEditingController(text: '${o.aspect.w}');
  late final _ah = TextEditingController(text: '${o.aspect.h}');
  late final _cw = TextEditingController(text: '${o.customWidth}');
  late final _ch = TextEditingController(text: '${o.customHeight}');
  late VideoScene _scene = videoSceneFor(s);
  MusicVideoRender? _render;
  String? _message;
  bool _messageIsError = false;

  AppState get s => widget.state;
  ProjectDoc get p => s.project;

  @override
  void initState() {
    super.initState();
    _encoder.caps().then((c) {
      if (mounted) setState(() => _caps = c);
    });
  }

  @override
  void dispose() {
    _lastOptions = o.copy();
    _render?.cancel();
    _position.dispose();
    for (final c in [_title, _artist, _aw, _ah, _cw, _ch]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _hasSelection {
    final a = s.timeSelectionStart, b = s.timeSelectionEnd;
    return a != null && b != null && a != b;
  }

  bool _rangeOk(VideoRange r) => switch (r) {
        VideoRange.song => true,
        VideoRange.loop => p.hasLoopRange,
        VideoRange.selection => _hasSelection,
      };

  VideoRange get _range => _rangeOk(o.range) ? o.range : VideoRange.song;

  (int, int) get _span => switch (_range) {
        VideoRange.song => (0, p.engineLoopSteps),
        VideoRange.loop => (p.loopStartSteps, p.loopEndSteps),
        VideoRange.selection => (
            s.timeSelectionStart! < s.timeSelectionEnd! ? s.timeSelectionStart! : s.timeSelectionEnd!,
            s.timeSelectionStart! < s.timeSelectionEnd! ? s.timeSelectionEnd! : s.timeSelectionStart!,
          ),
      };

  void _set(VoidCallback change) {
    Haptics.tap();
    setState(change);
    _store();
  }

  /// Saves the video's setup and shots with the project.
  void _store() => s.setMusicVideo(_doc.toJson());

  Future<Directory> _workDir() async => widget.workDir ??
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}music_video');

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> _start() async {
    final problem = o.problem(_caps);
    if (problem != null) {
      Haptics.error();
      setState(() {
        _message = problem;
        _messageIsError = true;
      });
      return;
    }
    o
      ..title = _title.text
      ..artist = _artist.text;
    final (a, b) = _span;
    final dir = await _workDir();
    _scene = videoSceneFor(s);
    final render = MusicVideoRender(projectJson: p.toEngineJson(), scene: _scene, options: o.copy(), startStep: a,
        endStep: b, encoder: _encoder, workDir: dir, audio: widget.audio, timeline: _doc.timeline.copy());
    render.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() {
      _render = render;
      _message = null;
    });
    Haptics.drop();
    final file = await render.run();
    if (!mounted) return;
    setState(() {
      if (file != null) {
        _message = 'Rendered ${render.frameCount} frames.';
        _messageIsError = false;
      } else if (render.phase == VideoRenderPhase.failed) {
        _message = 'The render failed: ${render.error}';
        _messageIsError = true;
      } else {
        _message = 'Cancelled.';
        _messageIsError = false;
      }
    });
    file != null ? Haptics.drop() : Haptics.error();
  }

  Future<void> _save() async {
    final file = _render?.output;
    if (file == null) return;
    final base = p.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '');
    final name = '${base.isEmpty ? 'CAW' : base}_video.${_encoder.extension}';
    try {
      final saved = await saveCopyOf(file, name: name, mimeType: _encoder.mimeType, extension: _encoder.extension);
      if (mounted) setState(() => _message = saved ? 'Saved $name' : 'Not saved (picker closed).');
      Haptics.tap();
    } catch (e) {
      Haptics.error();
      if (mounted) {
        setState(() {
          _message = 'Save failed: $e';
          _messageIsError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final (a, b) = _span;
    final plan = planVideo(_scene, o, _doc.timeline, start: a.toDouble(), end: b.toDouble());
    final (w, h) = o.size;
    final problem = o.problem(_caps);
    final render = _render;
    final busy = render?.running ?? false;
    final clock = FrameClock(fps: o.fps, startStep: a.toDouble(), endStep: b.toDouble(), bpm: p.bpm);
    final secs = clock.durationSeconds;
    final length = '${secs ~/ 60}:${(secs % 60).floor().toString().padLeft(2, '0')}';
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(12, 0, 12, 16 + MediaQuery.viewInsetsOf(context).bottom),
      children: [
        const _Header(),
        VideoSection('PREVIEW', children: [
          MusicVideoPreview(key: _previewKey, state: s, scene: _scene, plan: plan, options: o, start: a.toDouble(),
              end: b.toDouble(), position: _position),
          VideoNote(_doc.timeline.isEmpty
              ? '${plan.shots.length} shots over $length, cut by the ${o.style.label.toLowerCase()} director. '
                  'The preview draws them live with the song; the render draws every frame offline, the same.'
              : '${plan.shots.length} shots over $length from the lane (empty stretches show the arrangement). '
                  'The preview and the render draw them the same.'),
        ]),
        VideoSection('SHOT LANE', children: [
          MusicVideoEditor(
            doc: _doc, scene: _scene, start: a.toDouble(), end: b.toDouble(), aspect: w / h, enabled: !busy,
            playhead: _position,
            onSeek: (st) => _previewKey.currentState?.seek(st),
            onChanged: () => setState(() {}),
            onSave: _store,
            loudness: () async => analyzeSongLoudness(projectJson: p.toEngineJson(), scene: _scene, startStep: a,
                endStep: b, workDir: await _workDir(), audio: widget.audio, cancelled: () => !mounted),
          ),
        ]),
        VideoSection('SHOTS', children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final shot in VideoShot.values)
              VideoPill(key: ValueKey('video-shot-${shot.name}'), label: shot.label.toUpperCase(), on: o.shots.contains(shot),
                  onTap: busy ? null : () => _set(() => o.shots.contains(shot) ? o.shots.remove(shot) : o.shots.add(shot))),
          ]),
          VideoNote(o.shots.isEmpty
              ? 'Switch on at least one shot.'
              : 'The auto director and Auto-cut pick from these. ${[for (final x in o.shots) x.description].join('. ')}.'),
        ]),
        VideoSection('STYLE', children: [
          VideoTiles<VideoStyle>(keyPrefix: 'video-style', values: VideoStyle.values, selected: o.style,
              label: (v) => v.label, enabled: (_) => !busy, onPick: (v) => _set(() => o.style = v),
              icon: (v) => switch (v) {
                    VideoStyle.calm => Icons.waves,
                    VideoStyle.energetic => Icons.bolt,
                    VideoStyle.minimal => Icons.crop_square,
                  }),
          VideoNote(switch (o.style) {
            VideoStyle.calm => 'Long shots of four to eight bars, crossfades, a slow camera.',
            VideoStyle.energetic => 'Cuts on the bar and the beat, pushes at sections and drops, a quick camera.',
            VideoStyle.minimal => 'Few, long shots and slow fades.',
          }),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(alignment: Alignment.centerLeft, child: VideoPill(key: const ValueKey('video-smooth-follow'),
                label: 'SMOOTH FOLLOW', on: o.smoothFollow,
                onTap: busy ? null : () => _set(() => o.smoothFollow = !o.smoothFollow))),
          ),
          VideoReveal(switchKey: o.smoothFollow, VideoNote(o.smoothFollow
              ? 'The arrangement and piano roll hold the playhead a third of the way in and scroll the song under it; '
                  'the zoom changes only at cuts.'
              : 'Off: the camera springs after the playhead and zooms through each shot.')),
          Row(children: [
            const Text('Seed', style: TextStyle(color: Neon.dim, fontSize: 12)),
            IconButton(key: const ValueKey('video-seed-down'), onPressed: busy || o.seed <= 1 ? null : () => _set(() => o.seed--),
                icon: const Icon(Icons.remove)),
            Text('${o.seed}', style: Neon.code(size: 14, color: videoAccent)),
            IconButton(key: const ValueKey('video-seed-up'), onPressed: busy ? null : () => _set(() => o.seed++),
                icon: const Icon(Icons.add)),
            const Expanded(child: Text('Another seed cuts differently; the same seed always cuts the same.',
                style: TextStyle(color: Neon.dim, fontSize: 11))),
          ]),
        ]),
        VideoSection('RANGE', children: [
          VideoTiles<VideoRange>(keyPrefix: 'video-range', values: VideoRange.values, selected: _range, height: 40,
              label: (v) => v.label, enabled: (v) => !busy && _rangeOk(v), onPick: (v) => _set(() => o.range = v)),
          VideoNote('$length · bars ${a ~/ p.stepsPerBar + 1} to ${(b / p.stepsPerBar).ceil()}'),
        ]),
        VideoSection('ASPECT RATIO', children: [
          VideoTiles<String>(
            keyPrefix: 'video-aspect',
            values: [for (final x in VideoAspect.presets) x.label, 'Custom'],
            selected: _customAspect ? 'Custom' : o.aspect.label,
            height: 40,
            label: (v) => v,
            enabled: (_) => !busy,
            onPick: (v) => _set(() {
              _customAspect = v == 'Custom';
              if (!_customAspect) {
                o.aspect = VideoAspect.presets.firstWhere((x) => x.label == v);
                _aw.text = '${o.aspect.w}';
                _ah.text = '${o.aspect.h}';
              }
            }),
          ),
          VideoReveal(_customAspect
              ? _Pair(keyPrefix: 'video-aspect', a: _aw, b: _ah, sep: ':', onChanged: () {
                  setState(() => o.aspect = VideoAspect(_int(_aw) ?? 0, _int(_ah) ?? 0));
                  _store();
                })
              : null),
        ]),
        VideoSection('RESOLUTION', children: [
          VideoTiles<VideoResolution>(keyPrefix: 'video-res', values: VideoResolution.values, selected: o.resolution,
              height: 40, label: (v) => v.label, enabled: (_) => !busy, onPick: (v) => _set(() {
                if (v == VideoResolution.custom) {
                  final (cw, chh) = o.size;
                  o.customWidth = cw;
                  o.customHeight = chh;
                  _cw.text = '$cw';
                  _ch.text = '$chh';
                }
                o.resolution = v;
              })),
          VideoReveal(o.resolution == VideoResolution.custom
              ? _Pair(keyPrefix: 'video-size', a: _cw, b: _ch, sep: '×', onChanged: () {
                  setState(() {
                    o.customWidth = _int(_cw) ?? 0;
                    o.customHeight = _int(_ch) ?? 0;
                  });
                  _store();
                })
              : null),
          VideoReveal(problem != null && o.shots.isNotEmpty
              ? Padding(padding: const EdgeInsets.only(top: 6), child: Text(problem, key: const ValueKey('video-size-problem'),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Neon.pink, fontSize: 11)))
              : null),
          VideoNote('$w × $h · ${(o.bitrate / 1e6).toStringAsFixed(1)} Mbit/s · '
              'this encoder takes up to ${_caps.maxLong} × ${_caps.maxShort}'),
        ]),
        VideoSection('FRAME RATE', children: [
          VideoTiles<int>(keyPrefix: 'video-fps', values: MusicVideoOptions.frameRates, selected: o.fps, height: 40,
              label: (v) => '$v fps', enabled: (_) => !busy, onPick: (v) => _set(() => o.fps = v)),
          VideoNote('${clock.frameCount} frames.'),
        ]),
        VideoSection('TITLE CARD', children: [
          VideoPill(key: const ValueKey('video-title-card'), label: 'TITLE CARD', on: o.titleCard,
              onTap: busy ? null : () => _set(() => o.titleCard = !o.titleCard)),
          VideoReveal(o.titleCard
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextField(key: const ValueKey('video-title'), controller: _title, enabled: !busy,
                      decoration: InputDecoration(isDense: true, labelText: 'Title', hintText: p.name),
                      onChanged: (v) {
                        setState(() => o.title = v);
                        _store();
                      }),
                  TextField(key: const ValueKey('video-artist'), controller: _artist, enabled: !busy,
                      decoration: const InputDecoration(isDense: true, labelText: 'Artist'),
                      onChanged: (v) {
                        setState(() => o.artist = v);
                        _store();
                      }),
                ])
              : null),
          VideoNote('Three seconds over the opening shot. The video uses the current theme, ${Neon.active.name}.'),
        ]),
        const SizedBox(height: 12),
        VideoReveal(busy && render != null
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(
              '${render.phase.label}${render.phase == VideoRenderPhase.frames ? ' · ${render.framesDrawn} of ${render.frameCount}' : ''}',
              style: const TextStyle(fontSize: 12))),
            TextButton(key: const ValueKey('video-cancel'), onPressed: () {
              Haptics.tap();
              render.cancel();
            }, child: const Text('Cancel')),
          ]),
          Bar(value: render.progress, color: videoAccent, height: 6),
        ])
            : Pressable(
            glow: videoAccent,
            child: FilledButton.icon(
              key: const ValueKey('video-render'),
              style: FilledButton.styleFrom(backgroundColor: videoAccent, foregroundColor: Neon.bg,
                  minimumSize: const Size.fromHeight(52)),
              onPressed: problem == null ? _start : null,
              icon: const Icon(Icons.movie_creation_outlined),
              label: Text(platformWritesMp4 ? 'Render MP4' : 'Render frame list',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ),
          switchKey: busy),
        VideoReveal(!busy && render?.output != null
            ? Padding(padding: const EdgeInsets.only(top: 8), child: FilledButton.tonalIcon(
                key: const ValueKey('video-save'), onPressed: _save, icon: const Icon(Icons.save_alt),
                label: Text('Save .${_encoder.extension}')))
            : null),
        VideoReveal(problem != null || _message != null
            ? Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(problem ?? _message!, key: const ValueKey('video-message'), maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: problem != null || _messageIsError ? Neon.pink : Neon.green)),
              )
            : null),
        if (!platformWritesMp4)
          const VideoNote('This platform has no MP4 encoder yet: Render writes a list of frame hashes (Android and '
              'Windows write H.264 + AAC MP4).'),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.movie_filter_outlined, size: 18, color: videoAccent),
            const SizedBox(width: 8),
            const Text('MUSIC VIDEO', style: TextStyle(fontSize: 13, letterSpacing: 1.6, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Container(height: 3, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(colors: [videoAccent, _second]))),
        ]),
      );
}

/// Two whole-number fields side by side (a custom ratio or size).
class _Pair extends StatelessWidget {
  const _Pair({required this.keyPrefix, required this.a, required this.b, required this.sep, required this.onChanged});
  final String keyPrefix, sep;
  final TextEditingController a, b;
  final VoidCallback onChanged;

  Widget _field(String k, TextEditingController c) => Expanded(child: TextField(
        key: ValueKey('$keyPrefix-$k'),
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
        textAlign: TextAlign.center,
        style: Neon.code(size: 14),
        decoration: const InputDecoration(isDense: true),
        onChanged: (_) => onChanged(),
      ));

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          _field('w', a),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(sep, style: Neon.code(size: 16))),
          _field('h', b),
        ]),
      );
}

