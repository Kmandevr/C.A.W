// The Music video sheet (Export page and project menu) and its full-screen page (owner, 2026-11-12: clear sections,
// the preview kept in sight, a pinned export bar): the live preview and the shot lane on top, four tabs under them
// (Shots: the toolbar, the list and the auto director; Look: the chosen shot's looks and effects; Text & media: the
// title card, text overlays and images; Export: range, ratio, size, frame rate and quality), and the export bar with
// Draft and Render, which run in the background (MusicVideoJobs) while the user works. Edits save with the project.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/music_video.dart';
import '../../model/music_video_director.dart';
import '../../model/music_video_edit.dart';
import '../../model/music_video_overlay.dart';
import '../../model/music_video_scene.dart';
import '../../model/project.dart';
import '../../model/song_export.dart';
import '../../platform/save_copy.dart';
import '../../platform/video_encoder.dart';
import '../arrange/track_color.dart';
import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart';
import 'video_editor.dart';
import 'video_editor_page.dart';
import 'video_images.dart';
import 'video_media_editor.dart';
import 'video_preview.dart';
import 'video_kit.dart';
import 'video_render.dart';
import 'video_shot_list.dart';

Color get _second => Neon.violet;

/// The setup the sheet last used, and the tab it showed, for the next time it opens (this run of the app).
MusicVideoOptions? _lastOptions;
VideoTab _lastTab = VideoTab.shots;

/// Forgets the setup and tab the sheet last used (tests start each from a new sheet).
@visibleForTesting
void resetMusicVideoSheet() {
  _lastOptions = null;
  _lastTab = VideoTab.shots;
}

/// The sheet's tabs (owner, 2026-11-12).
enum VideoTab {
  shots('Shots', Icons.view_timeline_outlined),
  look('Look', Icons.auto_fix_high),
  media('Text & media', Icons.text_fields),
  export('Export', Icons.movie_creation_outlined);

  const VideoTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

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
  const MusicVideoPanel({super.key, required this.state, this.encoder, this.audio, this.workDir, this.doc,
      this.fullScreen = false, this.runner, this.onClose});
  final AppState state;
  final VideoEncoder? encoder;
  final SongRenderStarter? audio;
  final Directory? workDir;

  /// The video to edit (the full-screen page shares the sheet's); null reads the project's.
  final MusicVideoDoc? doc;

  /// The full-screen page: a close button instead of the full-screen one, and from [wideFrom] the preview and lane
  /// beside the tabs.
  final bool fullScreen;
  final AutoCutRunner? runner;
  final VoidCallback? onClose;

  /// From this width the full-screen page puts the preview and lane beside the tabs.
  static const wideFrom = 900.0;

  @override
  State<MusicVideoPanel> createState() => _MusicVideoPanelState();
}

class _MusicVideoPanelState extends State<MusicVideoPanel> {
  /// The video as the project saved it (versioned), or a new one with the setup last used.
  late final MusicVideoDoc _doc = widget.doc ??
      (p.musicVideo != null
          ? MusicVideoDoc.fromJson(p.musicVideo, maxStep: p.maxArrangementSteps.toDouble())
          // A new video: the setup last used this run, its shots the defaults with Falling notes when the song has
          // notes (owner's go-ahead, 2026-11-12).
          : MusicVideoDoc(options: (_lastOptions?.copy() ?? MusicVideoOptions())
            ..shots = VideoShot.forNewVideo(hasNotes: _scene.notes.isNotEmpty)));
  MusicVideoOptions get o => _doc.options;
  final _position = ValueNotifier<double>(0);
  final _previewKey = GlobalKey<MusicVideoPreviewState>();
  final _editorKey = GlobalKey<MusicVideoEditorState>();
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
  late final VideoImageStore _images = VideoImageStore(videoAssetsDir(s));
  VideoTab _tab = _lastTab;
  String? _message;
  bool _messageIsError = false;
  bool _starting = false;
  MusicVideoJobs get _jobs => MusicVideoJobs.instance;

  AppState get s => widget.state;
  ProjectDoc get p => s.project;

  @override
  void initState() {
    super.initState();
    _encoder.caps().then((c) {
      if (mounted) setState(() => _caps = c);
    });
    _jobs.addListener(_onJobs);
    _images.addListener(_onJobs);
    _loadImages();
  }

  /// Decodes the images the video's layers use (and lets the others go).
  Future<void> _loadImages() => _images.load(_doc.assets, used: _doc.usedAssetIds);

  void _onJobs() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _lastOptions = o.copy();
    _lastTab = _tab;
    // A render keeps going in the background (the shell's chip shows it); only the preview stops.
    _jobs.removeListener(_onJobs);
    _images.removeListener(_onJobs);
    _images.dispose();
    // Image files whose asset is gone (removed, or undone away) are deleted once editing ends. Only the panel that
    // owns the video does it: the full-screen page shares the sheet's video, whose undo can still bring one back.
    if (widget.doc == null) sweepVideoAssets(_images.dir, [..._doc.assets]);
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

  void _pickTab(VideoTab t) {
    if (t == _tab) return;
    Haptics.tap();
    setState(() => _tab = t);
  }

  /// Auto-cut's loudness from the range's rendered audio.
  Future<List<double>?> Function() _loudness(int a, int b) => () async => analyzeSongLoudness(projectJson:
      p.toEngineJson(), scene: _scene, startStep: a, endStep: b, workDir: await _workDir(), audio: widget.audio,
      cancelled: () => !mounted);

  /// Saves the video's setup and shots with the project.
  void _store() => s.setMusicVideo(_doc.toJson());

  Future<Directory> _workDir() async => widget.workDir ??
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}music_video');

  int? _int(TextEditingController c) => int.tryParse(c.text.trim());

  /// Renders the video (or its quick draft) in the background: the sheet can close and the user work on.
  Future<void> _start({bool draft = false}) async {
    final problem = o.problem(_caps);
    if (problem != null) {
      Haptics.error();
      setState(() {
        _message = problem;
        _messageIsError = true;
      });
      return;
    }
    // A second tap (Draft, then Render) while the work folder is looked up is let go: [_starting] covers the wait,
    // and the jobs are asked again after it.
    if (_jobs.running || _starting) return;
    _starting = true;
    final Directory base;
    try {
      base = await _workDir();
      // Images just put in use finish decoding first, so the render has them.
      await _loadImages();
    } finally {
      _starting = false;
    }
    if (!mounted || _jobs.running) return;
    o
      ..title = _title.text
      ..artist = _artist.text;
    final (a, b) = _span;
    final dir = Directory('${base.path}${Platform.pathSeparator}${draft ? 'draft' : 'full'}');
    _scene = videoSceneFor(s);
    // The render's own handles on the images, so closing the sheet (which lets its own go) can't pull them away.
    final bitmaps = <String, ui.Image>{for (final e in _images.images.entries) e.key: e.value.clone()};
    final render = MusicVideoRender(projectJson: p.toEngineJson(), scene: _scene, options: draft ? o.draft() : o.copy(),
        startStep: a, endStep: b, encoder: _encoder, workDir: dir, audio: widget.audio, timeline: _doc.timeline.copy(),
        doc: _doc.copy(), bitmaps: bitmaps, draft: draft);
    setState(() => _message = null);
    Haptics.drop();
    final File? file;
    try {
      file = await _jobs.start(render, name: p.name);
    } on StateError catch (e) {
      // Another render started first (from another sheet): this one is not run.
      _say('Not started: ${e.message}.');
      return;
    } finally {
      for (final i in bitmaps.values) {
        i.dispose();
      }
    }
    if (!mounted) return;
    setState(() {
      if (file != null) {
        _message = '${draft ? 'Draft' : 'Rendered'}: ${render.frameCount} frames · ${render.profile.secondsPerSecond.toStringAsFixed(1)} s '
            'per second of video.';
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
    final render = _jobs.render;
    final file = render?.output;
    if (render == null || file == null) return;
    final saved = await saveMusicVideo(render, _jobs.name, _encoder);
    if (!mounted) return;
    setState(() {
      _message = saved.$2;
      _messageIsError = !saved.$1 && saved.$2.startsWith('Save failed');
    });
  }

  /// Copies a picked image into the project and decodes it; its asset id, or null.
  Future<String?> _importImage() async {
    final path = await pickVideoImage();
    if (path == null || !mounted) return null;
    if (_doc.assets.length >= kVideoMaxImageAssets) {
      _say('At most $kVideoMaxImageAssets images a video.');
      return null;
    }
    try {
      final id = await nextVideoAssetId(_doc.assets, _images.dir);
      final (asset, image) = await importVideoImage(path, _images.dir, id);
      if (!mounted) {
        image.dispose();
        return null;
      }
      _doc.assets.add(asset);
      _images.put(asset.id, image);
      return asset.id;
    } catch (e) {
      _say(e is FormatException ? e.message : 'The image could not be added: $e');
      return null;
    }
  }

  void _say(String m) {
    Haptics.error();
    if (mounted) {
      setState(() {
        _message = m;
        _messageIsError = true;
      });
    }
  }

  Future<void> _openFullScreen(double a, double b) async {
    await openMusicVideoEditorPage(context, state: s, doc: _doc, encoder: _encoder, audio: widget.audio,
        workDir: widget.workDir, runner: widget.runner);
    if (mounted) {
      _loadImages();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final (a, b) = _span;
    final plan = planVideo(_scene, o, _doc.timeline, start: a.toDouble(), end: b.toDouble());
    final (w, h) = o.size;
    return LayoutBuilder(builder: (context, box) {
      final wide = widget.fullScreen && box.maxWidth >= MusicVideoPanel.wideFrom;
      final previewMax = wide ? 520.0 : (box.maxHeight.isFinite ? box.maxHeight * 0.27 : 220.0).clamp(120.0, 360.0);
      final preview = MusicVideoPreview(key: _previewKey, state: s, scene: _scene, plan: plan, options: o, start: a.toDouble(),
          end: b.toDouble(), position: _position, doc: _doc, bitmaps: _images.images, maxHeight: previewMax);
      return MusicVideoEditor(
        key: _editorKey,
        doc: _doc, scene: _scene, start: a.toDouble(), end: b.toDouble(), aspect: w / h, 
        playhead: _position,
        onSeek: (st) => _previewKey.currentState?.seek(st),
        onChanged: () {
          _loadImages();
          setState(() {});
        },
        onSave: _store,
        loudness: _loudness(a, b),
        runner: widget.runner,
        settings: s.settings,
        fullScreen: widget.fullScreen,
        onFullScreen: widget.fullScreen ? (widget.onClose ?? () => Navigator.of(context).maybePop()) : () => _openFullScreen(a.toDouble(), b.toDouble()),
        listParts: ShotPart.shots,
        frame: (context, ed, parts) {
          final header = _Header(fullScreen: widget.fullScreen,
              onFullScreen: widget.fullScreen ? (widget.onClose ?? () => Navigator.of(context).maybePop())
                  : () => _openFullScreen(a.toDouble(), b.toDouble()));
          final tabs = _TabBar(selected: _tab, onPick: _pickTab, selectedShot: ed.selected != null);
          final content = _TabBody(tab: _tab, child: ListView(
            key: PageStorageKey('video-tab-${_tab.name}'),
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
            children: _tabChildren(ed, parts, plan, a, b),
          ));
          final bar = _exportBar(a, b);
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(flex: 6, child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 8, 16), children: [
                header, preview, const SizedBox(height: 8), parts.lane, parts.message,
              ])),
              const VerticalDivider(width: 1, color: Neon.line),
              Expanded(flex: 4, child: Padding(padding: const EdgeInsets.fromLTRB(8, 8, 12, 8), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch, children: [tabs, Expanded(child: content), bar]))),
            ]);
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 8 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              header,
              preview,
              const SizedBox(height: 4),
              parts.lane,
              parts.message,
              const SizedBox(height: 6),
              tabs,
              Expanded(child: content),
              bar,
            ]),
          );
        },
      );
    });
  }

  List<Widget> _tabChildren(MusicVideoEditorState ed, VideoEditorParts parts, ShotPlan plan, int a, int b) {
    final cut = ed.selected == null ? null : _doc.timeline.byId(ed.selected!);
    final (w, h) = o.size;
    final spb = p.stepsPerBar;
    switch (_tab) {
      case VideoTab.shots:
        final secs = FrameClock(fps: o.fps, startStep: a.toDouble(), endStep: b.toDouble(), bpm: p.bpm).durationSeconds;
        return [
          parts.toolbar,
          parts.snap,
          const SizedBox(height: 8),
          VideoNote(_doc.timeline.isEmpty
              ? '${plan.shots.length} shots over ${_clock(secs)}, cut by the ${o.style.label.toLowerCase()} director. '
                  'Auto-cut puts shots on the lane to edit; a tap on a cut marker picks its transition.'
              : '${plan.shots.length} shots over ${_clock(secs)} from the lane (empty stretches show the arrangement). '
                  'A tap on a cut marker picks its transition.'),
          const SizedBox(height: 6),
          parts.list,
          ..._director(),
        ];
      case VideoTab.look:
        if (cut == null) {
          return [
            const VideoNote('Pick a shot on the lane to change its look and effects. Looks are per panel; effects run '
                'over the whole shot or one panel, steady, with the mix, or on the beat.'),
            if (_doc.timeline.isEmpty)
              Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerLeft,
                  child: TextButton.icon(key: const ValueKey('video-look-autocut'), onPressed: ed.openAutoCut,
                      icon: Icon(Icons.auto_awesome, size: 18, color: videoAccent),
                      label: Text('Auto-cut the lane first', style: TextStyle(color: videoAccent))))),
          ];
        }
        return [
          VideoNote('Shot ${_doc.timeline.indexOf(cut.id) + 1} · ${cut.layout.summary}'),
          ShotEditor(key: ValueKey('video-look-${cut.id}'), cut: cut, timeline: _doc.timeline, scene: _scene,
              snap: _doc.snap, host: ed, aspect: w / h, start: a.toDouble(), end: b.toDouble(),
              parts: const {ShotPart.look, ShotPart.effects}),
        ];
      case VideoTab.media:
        final thumbs = <String, Object>{
          for (final e in _images.images.entries) e.key: RawImage(image: e.value, fit: BoxFit.cover),
        };
        return [
          VideoSection('TITLE CARD', children: [
            VideoPill(key: const ValueKey('video-title-card'), label: 'TITLE CARD', on: o.titleCard,
                onTap: () => _set(() => o.titleCard = !o.titleCard)),
            TextField(key: const ValueKey('video-title'), controller: _title, 
                decoration: InputDecoration(isDense: true, labelText: 'Title', hintText: p.name),
                onChanged: (v) {
                  setState(() => o.title = v);
                  _store();
                }),
            TextField(key: const ValueKey('video-artist'), controller: _artist, 
                decoration: const InputDecoration(isDense: true, labelText: 'Artist'),
                onChanged: (v) {
                  setState(() => o.artist = v);
                  _store();
                }),
            VideoNote(o.titleCard
                ? 'The title card shows over the first three seconds. Title and Artist also fill the text overlays '
                    'of those kinds. The video uses the current theme, ${Neon.active.name}.'
                : 'Off. Title and Artist still fill the text overlays of those kinds.'),
          ]),
          VideoSection('TEXT · WHOLE VIDEO', children: [
            VideoTextList(texts: _doc.texts, doc: _doc, host: ed, stepsPerBar: spb, wholeVideo: true,
                start: a.toDouble(), end: b.toDouble(), keyPrefix: 'video-vtext'),
          ]),
          VideoSection('IMAGES · WHOLE VIDEO', children: [
            VideoImageList(layers: _doc.images, doc: _doc, host: ed, thumbs: thumbs, problems: _images.problems,
                onImport: _importImage, keyPrefix: 'video-vimage'),
          ]),
          VideoReveal(switchKey: cut?.id, cut == null
              ? const VideoNote('Pick a shot on the lane to give it text and images of its own.')
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  VideoSection('TEXT · SHOT ${_doc.timeline.indexOf(cut.id) + 1}', children: [
                    VideoTextList(texts: cut.texts, doc: _doc, host: ed, stepsPerBar: spb, keyPrefix: 'video-stext'),
                  ]),
                  VideoSection('IMAGES · SHOT ${_doc.timeline.indexOf(cut.id) + 1}', children: [
                    VideoImageList(layers: cut.images, doc: _doc, host: ed, thumbs: thumbs, problems: _images.problems,
                        onImport: _importImage, keyPrefix: 'video-simage'),
                  ]),
                ])),
        ];
      case VideoTab.export:
        return _exportSettings(a, b);
    }
  }

  static String _clock(double secs) => '${secs ~/ 60}:${(secs % 60).floor().toString().padLeft(2, '0')}';

  List<Widget> _director() => [
        VideoSection('AUTO DIRECTOR', children: [
          const VideoNote('The director cuts the video while the lane is empty; Auto-cut uses its shots, style and seed.'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final shot in VideoShot.values)
              VideoPill(key: ValueKey('video-shot-${shot.name}'), label: shot.label.toUpperCase(), on: o.shots.contains(shot),
                  onTap: () => _set(() => o.shots.contains(shot) ? o.shots.remove(shot) : o.shots.add(shot))),
          ]),
          VideoNote(o.shots.isEmpty
              ? 'Switch on at least one shot.'
              : [for (final x in o.shots) x.description].join('. ')),
          const SizedBox(height: 8),
          VideoTiles<VideoStyle>(keyPrefix: 'video-style', values: VideoStyle.values, selected: o.style,
              label: (v) => v.label,  onPick: (v) => _set(() => o.style = v),
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
                onTap: () => _set(() => o.smoothFollow = !o.smoothFollow))),
          ),
          VideoReveal(switchKey: o.smoothFollow, VideoNote(o.smoothFollow
              ? 'The arrangement and piano roll hold the playhead a third of the way in and scroll the song under it; '
                  'the zoom changes only at cuts.'
              : 'Off: the camera springs after the playhead and zooms through each shot.')),
          Row(children: [
            const Text('Seed', style: TextStyle(color: Neon.dim, fontSize: 12)),
            IconButton(key: const ValueKey('video-seed-down'), onPressed: o.seed <= 1 ? null : () => _set(() => o.seed--),
                icon: const Icon(Icons.remove)),
            Text('${o.seed}', style: Neon.code(size: 14, color: videoAccent)),
            IconButton(key: const ValueKey('video-seed-up'), onPressed: () => _set(() => o.seed++),
                icon: const Icon(Icons.add)),
            const Expanded(child: Text('Another seed cuts differently; the same seed always cuts the same.',
                style: TextStyle(color: Neon.dim, fontSize: 11))),
          ]),
        ]),
      ];

  List<Widget> _exportSettings(int a, int b) {
    final (w, h) = o.size;
    final problem = o.problem(_caps);
    final clock = FrameClock(fps: o.fps, startStep: a.toDouble(), endStep: b.toDouble(), bpm: p.bpm);
    final secs = clock.durationSeconds;
    final beat = _beatSummary();
    return [
      VideoSection('RANGE', children: [
        VideoTiles<VideoRange>(keyPrefix: 'video-range', values: VideoRange.values, selected: _range, height: 40,
            label: (v) => v.label, enabled: _rangeOk, onPick: (v) => _set(() => o.range = v)),
        VideoNote('${_clock(secs)} · bars ${a ~/ p.stepsPerBar + 1} to ${(b / p.stepsPerBar).ceil()}'),
      ]),
      VideoSection('ASPECT RATIO', children: [
        VideoTiles<String>(
          keyPrefix: 'video-aspect',
          values: [for (final x in VideoAspect.presets) x.label, 'Custom'],
          selected: _customAspect ? 'Custom' : o.aspect.label,
          height: 40,
          label: (v) => v,
          
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
            height: 40, label: (v) => v.label,  onPick: (v) => _set(() {
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
        VideoNote('$w × $h · this encoder takes up to ${_caps.maxLong} × ${_caps.maxShort}'),
      ]),
      VideoSection('FRAME RATE', children: [
        VideoTiles<int>(keyPrefix: 'video-fps', values: MusicVideoOptions.frameRates, selected: o.fps, height: 40,
            label: (v) => '$v fps',  onPick: (v) => _set(() => o.fps = v)),
        VideoNote('${clock.frameCount} frames${o.fps == 24 ? ' · 24 fps: the film look' : ''}.'),
      ]),
      VideoSection('QUALITY', children: [
        VideoTiles<VideoQuality>(keyPrefix: 'video-quality', values: VideoQuality.values, selected: o.quality, height: 54,
            label: (v) => v.label,  onPick: (v) => _set(() => o.quality = v),
            icon: (v) => switch (v) {
                  VideoQuality.small => Icons.compress,
                  VideoQuality.balanced => Icons.balance,
                  VideoQuality.high => Icons.hd_outlined,
                }),
        VideoNote('${_mbit(o.bitrate)} picture + ${kVideoAudioBitrate ~/ 1000} kbit/s sound · '
            '≈ ${_mb(o.estimatedBytes(secs))} for ${_clock(secs)}', key: const ValueKey('video-quality-note')),
      ]),
      VideoSection('ON THE BEAT', children: [
        VideoNote(beat, key: const ValueKey('video-beat-summary')),
      ]),
      if (!platformWritesMp4)
        const VideoNote('This platform has no MP4 encoder yet: Render writes a list of frame hashes (Android and '
            'Windows write H.264 + AAC MP4).'),
    ];
  }

  /// What the export draws on the beat: every frame is drawn at its song time, so these land on the beat in the file.
  String _beatSummary() {
    final cuts = _doc.timeline.cuts;
    final transitions = cuts.where((c) => c.transition != VideoTransition.cut).length;
    final effects = [for (final c in cuts) ...c.effects.where((e) => e.on && VideoEffectPreset.beats(e.drive))].length;
    final texts = [..._doc.texts, for (final c in cuts) ...c.texts].where((t) => t.beatSync).length;
    final parts = [
      if (transitions > 0) '$transitions transition${transitions == 1 ? '' : 's'} timed in beats',
      if (effects > 0) '$effects effect${effects == 1 ? '' : 's'} pulsing on the beat',
      if (texts > 0) '$texts text${texts == 1 ? '' : 's'} on the beat',
    ];
    return '${parts.isEmpty ? 'Nothing is set to the beat yet' : parts.join(', ')}. Every frame is drawn at its own '
        'song time, so cuts, transitions, beat effects and text land on the beat in the file, exactly as in the '
        'preview.';
  }

  static String _mbit(int bps) => '${(bps / 1e6).toStringAsFixed(bps < 10e6 ? 1 : 0)} Mbit/s';
  static String _mb(int bytes) => bytes < 1e6 ? '${(bytes / 1e3).round()} KB' : '${(bytes / 1e6).toStringAsFixed(bytes < 1e8 ? 1 : 0)} MB';

  /// The pinned bar under the tabs: the size and rate, Draft and Render; the progress and Cancel while it renders;
  /// Save when it is done.
  Widget _exportBar(int a, int b) {
    final render = _jobs.render;
    final busy = _jobs.running;
    final problem = o.problem(_caps);
    final (w, h) = o.size;
    final secs = FrameClock(fps: o.fps, startStep: a.toDouble(), endStep: b.toDouble(), bpm: p.bpm).durationSeconds;
    final done = !busy && render?.output != null;
    final Widget body;
    final String state;
    if (busy && render != null) {
      state = 'busy';
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(
            '${render.draft ? 'Draft · ' : ''}${render.phase.label}'
            '${render.phase == VideoRenderPhase.frames ? ' · ${render.framesDrawn} of ${render.frameCount}' : ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
          Text('${(render.progress * 100).round()}%', style: Neon.code(size: 11, color: Neon.dim)),
          TextButton(key: const ValueKey('video-cancel'), onPressed: () {
            Haptics.tap();
            _jobs.cancel();
          }, child: const Text('Cancel')),
        ]),
        Bar(value: render.progress, color: videoAccent, height: 6),
        const VideoNote('Keeps going if you close this; the chip shows it while the app is open.'),
      ]);
    } else {
      state = done ? 'done' : 'idle';
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('$w × $h · ${o.fps} fps · ${o.quality.label} ${_mbit(o.bitrate)} · ≈ ${_mb(o.estimatedBytes(secs))}',
              key: const ValueKey('video-export-summary'), maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: Neon.dim))),
          if (done) ...[
            const SizedBox(width: 6),
            FilledButton.tonalIcon(key: const ValueKey('video-save'), onPressed: _save, icon: const Icon(Icons.save_alt, size: 18),
                label: Text(render!.draft ? 'Save draft' : 'Save .${_encoder.extension}')),
          ],
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(flex: 2, child: OutlinedButton.icon(
            key: const ValueKey('video-draft'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            onPressed: problem == null ? () => _start(draft: true) : null,
            icon: const Icon(Icons.speed, size: 18),
            label: const Text('Draft', style: TextStyle(fontWeight: FontWeight.w700)),
          )),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: Pressable(glow: videoAccent, child: FilledButton.icon(
            key: const ValueKey('video-render'),
            style: FilledButton.styleFrom(backgroundColor: videoAccent, foregroundColor: Neon.bg,
                minimumSize: const Size.fromHeight(46)),
            onPressed: problem == null ? _start : null,
            icon: const Icon(Icons.movie_creation_outlined),
            label: Text(platformWritesMp4 ? 'Render MP4' : 'Render frames',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ))),
        ]),
      ]);
    }
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Neon.panel.withValues(alpha: 0.85),
        border: Border.all(color: Neon.line),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        VideoReveal(body, switchKey: state),
        VideoReveal(problem != null || _message != null
            ? Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(problem ?? _message!, key: const ValueKey('video-message'), maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: problem != null || _messageIsError ? Neon.pink : Neon.green)),
              )
            : null, switchKey: problem ?? _message),
      ]),
    );
  }
}

/// Saves a finished render through the system save picker: whether it was saved, and a line to show.
Future<(bool, String)> saveMusicVideo(MusicVideoRender render, String projectName, VideoEncoder encoder) async {
  final file = render.output;
  if (file == null) return (false, 'Nothing to save.');
  final base = projectName.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '');
  final name = '${base.isEmpty ? 'CAW' : base}_video${render.draft ? '_draft' : ''}.${encoder.extension}';
  try {
    final saved = await saveCopyOf(file, name: name, mimeType: encoder.mimeType, extension: encoder.extension);
    Haptics.tap();
    return (saved, saved ? 'Saved $name' : 'Not saved (picker closed).');
  } catch (e) {
    Haptics.error();
    return (false, 'Save failed: $e');
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.fullScreen, required this.onFullScreen});
  final bool fullScreen;
  final VoidCallback? onFullScreen;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 36, child: Row(children: [
            if (fullScreen)
              IconButton(key: const ValueKey('video-editor-close'), tooltip: 'Close (Esc)', onPressed: onFullScreen,
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  icon: const Icon(Icons.arrow_back)),
            Icon(Icons.movie_filter_outlined, size: 18, color: videoAccent),
            const SizedBox(width: 8),
            Expanded(child: Text(fullScreen ? 'MUSIC VIDEO EDITOR' : 'MUSIC VIDEO', maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, letterSpacing: 1.6, fontWeight: FontWeight.w800))),
            if (!fullScreen)
              IconButton(
                key: const ValueKey('video-editor-full-screen'),
                tooltip: 'Full screen (F11)',
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: onFullScreen,
                icon: const Icon(Icons.open_in_full),
              ),
          ])),
          Container(height: 3, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(colors: [videoAccent, _second]))),
        ]),
      );
}

/// The four tabs in the device kit's pill style: the chosen one lit, the change animated.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.selected, required this.onPick, required this.selectedShot});
  final VideoTab selected;
  final ValueChanged<VideoTab> onPick;

  /// A shot is chosen on the lane (Look and Text & media show a dot: they edit it).
  final bool selectedShot;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => _bar(context, box.maxWidth < 420));

  Widget _bar(BuildContext context, bool narrow) {
    final level = Motion.of(context);
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: Neon.line)),
      child: Row(children: [
        for (final t in VideoTab.values)
          Expanded(child: Semantics(
            button: true,
            selected: t == selected,
            label: t.label,
            child: GestureDetector(
              key: ValueKey('video-tab-${t.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onPick(t),
              child: Pressable(glow: videoAccent, child: AnimatedContainer(
                duration: Motion.fade(Motion.standard, level),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  color: t == selected ? videoAccent.withValues(alpha: 0.2) : Colors.transparent,
                  border: Border.all(color: t == selected ? videoAccent : Colors.transparent, width: 1.2),
                  boxShadow: t == selected ? [BoxShadow(color: videoAccent.withValues(alpha: 0.25), blurRadius: 10)] : null,
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  // A phone gives the words the room; wider screens show the tab's icon too.
                  if (!narrow) ...[
                    Icon(t.icon, size: 15, color: t == selected ? videoAccent : Neon.dim),
                    const SizedBox(width: 4),
                  ],
                  // The whole word, a little smaller under a large text size, clear of the next tab.
                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(t.label.toUpperCase(), maxLines: 1,
                      style: TextStyle(fontSize: 9.5, letterSpacing: narrow ? 0.1 : 0.4, fontWeight: FontWeight.w800,
                          color: t == selected ? Neon.text : Neon.dim)))),
                  AnimatedOpacity(
                    duration: Motion.fade(Motion.small, level),
                    opacity: selectedShot && (t == VideoTab.look || t == VideoTab.media) ? 1 : 0,
                    child: Padding(padding: const EdgeInsets.only(left: 3), child: Container(width: 5, height: 5,
                        decoration: BoxDecoration(color: Neon.yellow, shape: BoxShape.circle))),
                  ),
                ]),
              )),
            ),
          )),
      ]),
    );
  }
}

/// A tab's content, faded and slid a little as the tab changes (instant with motion Off).
class _TabBody extends StatelessWidget {
  const _TabBody({required this.tab, required this.child});
  final VideoTab tab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    return AnimatedSwitcher(
      duration: Motion.fade(Motion.standard, level),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: level == MotionLevel.full
          ? SlideTransition(position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(anim), child: child)
          : child),
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
      child: KeyedSubtree(key: ValueKey(tab), child: child),
    );
  }
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

