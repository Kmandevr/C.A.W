// The music video editor (owner, 2026-11-12), in the setup sheet and full screen: the shot lane and list with
// Auto-cut, Add, Split, Duplicate, Delete, undo and redo, the snap, the keymap's `video.*` keys on top, the Strobe
// warning, and the auto-cut sheet (its triggers' settings; re-running asks before it replaces edits, or fills only
// the empty space).
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../model/music_video.dart';
import '../../model/music_video_autocut.dart';
import '../../model/music_video_edit.dart';
import '../../model/music_video_overlay.dart';
import '../../actions/actions.dart';
import '../../model/music_video_scene.dart';
import '../../model/settings.dart';
import '../glass.dart';
import '../haptics.dart';
import '../keyboard/key_area.dart';
import '../theme.dart';
import 'video_kit.dart';
import 'video_shot_lane.dart';
import 'video_shot_list.dart';

/// Runs auto-cut (off the UI isolate by default; tests run it in place).
typedef AutoCutRunner = Future<List<VideoCut>> Function(VideoScene scene, AutoCutSettings settings,
    MusicVideoOptions options, {required double start, required double end, List<double>? loudness});

/// What re-running auto-cut does with shots already on the lane.
enum AutoCutMode { replace, fillGaps }

/// The editor's pieces, for a layout that places them apart (the tabbed sheet): the toolbar, the lane, the snap
/// and zoom row, the one-line message and the shot list.
typedef VideoEditorParts = ({Widget toolbar, Widget lane, Widget snap, Widget message, Widget list});

class MusicVideoEditor extends StatefulWidget {
  const MusicVideoEditor({super.key, required this.doc, required this.scene, required this.start, required this.end,
      required this.aspect, required this.onChanged, required this.onSave, this.playhead, this.onSeek, this.loudness,
      this.runner, this.enabled = true, this.onFullScreen, this.fullScreen = false, this.settings, this.side,
      this.frame, this.listParts = ShotPart.all});

  final MusicVideoDoc doc;
  final VideoScene scene;
  final double start, end, aspect;

  /// The shots moved (redraw the preview), and a change finished (save it with the project).
  final VoidCallback onChanged, onSave;
  final ValueListenable<double>? playhead;
  final ValueChanged<double>? onSeek;

  /// Auto-cut's loudness from rendered audio (per beat, dB), or null when it can't be had.
  final Future<List<double>?> Function()? loudness;
  final AutoCutRunner? runner;
  final bool enabled;

  /// Opens (or, on the full-screen page, closes) the full-screen editor.
  final VoidCallback? onFullScreen;
  final bool fullScreen;

  /// Where the photosensitivity warning is remembered (shown once); null keeps it for this editor only.
  final Settings? settings;

  /// Lays the editor's two parts out side by side (the full-screen page on a wide screen): the toolbar and lane,
  /// and the shot list. Null stacks them.
  final Widget Function(Widget lane, Widget list)? side;

  /// Lays the editor's pieces out freely (the tabbed sheet); it wins over [side].
  final Widget Function(BuildContext context, MusicVideoEditorState editor, VideoEditorParts parts)? frame;

  /// What a shot's row in the list opens (all of it by default; the tabbed sheet shows the shot's look, effects
  /// and text on their own tabs).
  final Set<ShotPart> listParts;

  @override
  State<MusicVideoEditor> createState() => MusicVideoEditorState();
}

class MusicVideoEditorState extends State<MusicVideoEditor> implements VideoEditHost {
  final List<_Snapshot> _undo = [], _redo = [];
  static const _maxUndo = 100;
  String? selected;
  late double cursor = widget.start;
  bool _busy = false;
  String? _message;
  final _laneKey = GlobalKey<ShotLaneState>();
  final _focus = FocusNode(debugLabel: 'music video editor');

  MusicVideoDoc get d => widget.doc;
  VideoTimeline get t => d.timeline;
  int get spb => widget.scene.stepsPerBar;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Auto-cut (or its loudness render) is running.
  bool get busy => _busy;

  /// Whether edits land now: not while auto-cut or a render runs.
  bool get canEdit => widget.enabled && !_busy;

  // VideoEditHost: every change is one undo step, saved when it ends; a change that changed nothing leaves none.
  bool _open = false;
  String _before = '';
  List<_Snapshot> _redoBefore = const [];

  @override
  void begin() {
    if (_open) return;
    _open = true;
    _before = _state();
    _redoBefore = [..._redo];
    _undo.add(_Snapshot.of(d));
    if (_undo.length > _maxUndo) _undo.removeAt(0);
    _redo.clear();
  }

  @override
  void live(VoidCallback change) {
    change();
    setState(() {});
    widget.onChanged();
  }

  @override
  void end() {
    if (!_open) return;
    _open = false;
    if (_state() == _before) {
      // Nothing changed: drop the step and keep what redo had.
      _undo.removeLast();
      _redo
        ..clear()
        ..addAll(_redoBefore);
      setState(() {});
      return;
    }
    setState(() {});
    widget.onChanged();
    widget.onSave();
  }

  @override
  void edit(VoidCallback change) {
    Haptics.tap();
    begin();
    change();
    end();
  }

  void undo() {
    if (_undo.isEmpty || !canEdit) return;
    Haptics.tap();
    _redo.add(_Snapshot.of(d));
    _restore(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty || !canEdit) return;
    Haptics.tap();
    _undo.add(_Snapshot.of(d));
    _restore(_redo.removeLast());
  }

  /// What an undo step covers, as text (to tell whether a change changed anything): the lane and the whole video's
  /// texts and images.
  String _state() => jsonEncode([t.toJson(), for (final x in d.texts) x.toJson(), for (final x in d.images) x.toJson(),
      for (final a in d.assets) a.toJson()]);

  void _restore(_Snapshot from) {
    t.replaceWith(from.timeline);
    d
      ..texts = from.texts
      ..images = from.images
      ..assets = from.assets;
    if (selected != null && t.byId(selected!) == null) selected = null;
    setState(() {});
    widget.onChanged();
    widget.onSave();
  }

  void select(String? id) => setState(() => selected = id);

  void setCursor(double step) {
    setState(() => cursor = step);
    widget.onSeek?.call(step);
  }

  void add() {
    if (!canEdit) return;
    VideoCut? made;
    edit(() => made = t.add(cursor, snap: d.snap, stepsPerBar: spb, lo: widget.start, hi: widget.end));
    if (made == null) {
      _say('The cursor is inside a shot: Split cuts it there.');
    } else {
      setState(() => selected = made!.id);
    }
  }

  @override
  void split() {
    if (!canEdit) return;
    final id = selected ?? t.at(cursor)?.id;
    if (id == null) return _say('Put the cursor inside a shot to split it.');
    final c = t.byId(id)!;
    final at = snapStep(cursor, d.snap, spb);
    if (at <= c.start || at >= c.end) return _say('Put the cursor inside the shot to split it.');
    VideoCut? right;
    edit(() => right = t.split(id, cursor, snap: d.snap, stepsPerBar: spb));
    setState(() => selected = right?.id ?? id);
  }

  @override
  void duplicate() {
    final id = selected;
    if (id == null || !canEdit) return;
    if ((t.byId(id)?.end ?? widget.end) >= widget.end) return _say('No room after it before the end.');
    VideoCut? dup;
    edit(() => dup = t.duplicate(id, hi: widget.end));
    setState(() => selected = dup?.id ?? id);
  }

  @override
  void delete() {
    final id = selected;
    if (id == null || !canEdit) return;
    edit(() => t.delete(id));
    setState(() => selected = null);
  }

  void nudge(int dir) {
    final c = selected == null ? null : t.byId(selected!);
    if (c == null || !canEdit) return;
    edit(() => t.move(c.id, c.start + dir * d.snap.grid(spb), snap: d.snap, stepsPerBar: spb, lo: widget.start,
        hi: widget.end));
  }

  void _selectNext(int dir) {
    if (t.isEmpty) return;
    final i = selected == null ? (dir > 0 ? -1 : t.cuts.length) : t.indexOf(selected!);
    final k = (i + dir).clamp(0, t.cuts.length - 1);
    select(t.cuts[k].id);
  }

  void _say(String m) {
    Haptics.error();
    setState(() => _message = m);
  }

  /// Opens the auto-cut sheet and, on Cut, fills the lane (asking first when it already has shots).
  Future<void> openAutoCut() async {
    final settings = await showGlassSheet<AutoCutSettings>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => AutoCutPanel(settings: d.autoCut.copy(), canUseAudio: widget.loudness != null),
    );
    if (settings == null || !mounted) return;
    var mode = AutoCutMode.replace;
    if (!t.isEmpty) {
      final pick = await showDialog<AutoCutMode>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Replace your shots?'),
          content: const Text('Auto-cut can replace every shot on the lane, or fill only the empty space and keep yours.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(key: const ValueKey('video-autocut-fill'), onPressed: () => Navigator.pop(c, AutoCutMode.fillGaps),
                child: const Text('Fill empty space')),
            FilledButton(key: const ValueKey('video-autocut-replace'), onPressed: () => Navigator.pop(c, AutoCutMode.replace),
                child: const Text('Replace')),
          ],
        ),
      );
      if (pick == null || !mounted) return;
      mode = pick;
    }
    await runAutoCut(settings, mode);
  }

  /// Runs auto-cut with [settings] and puts its shots on the lane by [mode].
  Future<void> runAutoCut(AutoCutSettings settings, AutoCutMode mode) async {
    d.autoCut = settings;
    setState(() {
      _busy = true;
      _message = settings.fromAudio ? 'Rendering the audio to read its loudness…' : 'Cutting…';
    });
    String? failed;
    List<VideoCut>? cuts;
    try {
      List<double>? loudness;
      if (settings.fromAudio && widget.loudness != null) {
        loudness = await widget.loudness!();
        if (!mounted) return;
        if (loudness == null) setState(() => _message = 'The audio could not be read; the notes stand in for loudness.');
      }
      final run = widget.runner ?? autoCutInBackground;
      cuts = await run(widget.scene, settings, d.options, start: widget.start, end: widget.end, loudness: loudness);
    } catch (e) {
      failed = e is StateError ? e.message : '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (cuts == null) {
      _say('Auto-cut failed: ${failed ?? 'no result'}'.split('\n').first);
      return;
    }
    final fresh = cuts;
    var added = fresh.length;
    edit(() {
      if (mode == AutoCutMode.replace) {
        // Only the range: shots outside a loop or selection range stay.
        t.replaceRange(fresh, widget.start, widget.end);
      } else {
        added = t.fillGaps(fresh, widget.start, widget.end);
      }
    });
    setState(() {
      selected = null;
      _message = mode == AutoCutMode.replace ? 'Auto-cut made $added shots.' : 'Auto-cut filled the empty space with $added shots.';
    });
    Haptics.drop();
  }

  /// Runs one of the editor's actions (the catalogue's `video.*`, from the keymap: Settings › Keys rebinds them).
  bool runAction(String id) {
    if (!canEdit && id != 'video.fullScreen' && id != 'video.previous' && id != 'video.following') return false;
    switch (id) {
      case 'video.add':
        add();
      case 'video.split':
        split();
      case 'video.duplicate':
        duplicate();
      case 'video.delete':
        delete();
      case 'video.undo':
        undo();
      case 'video.redo':
        redo();
      case 'video.nudgeLeft':
        nudge(-1);
      case 'video.nudgeRight':
        nudge(1);
      case 'video.previous':
        _selectNext(-1);
      case 'video.following':
        _selectNext(1);
      case 'video.autocut':
        openAutoCut();
      case 'video.fullScreen':
        if (widget.onFullScreen == null) return false;
        widget.onFullScreen!();
      default:
        return false;
    }
    return true;
  }

  /// The cut marker before shot [index] was tapped: its transition and length (owner, 2026-11-12: cut marker →
  /// transition picker).
  Future<void> pickTransition(int index) async {
    if (!canEdit || index <= 0 || index >= t.cuts.length) return;
    final c = t.cuts[index];
    select(c.id);
    Haptics.tap();
    await showGlassSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.compare_arrows, size: 18, color: videoAccent),
            const SizedBox(width: 8),
            Expanded(child: Text('INTO SHOT ${index + 1} · ${videoBarBeat(c.start, spb)}',
                style: const TextStyle(fontSize: 13, letterSpacing: 1.4, fontWeight: FontWeight.w800))),
          ]),
          TransitionPicker(cut: c, stepsPerBar: spb, host: this, onChanged: () => setSheet(() {})),
        ]),
      )),
    );
  }

  @override
  Future<void> addEffect(List<VideoEffect> effects, VideoEffectKind kind) async {
    if (!canEdit) return;
    final settings = widget.settings;
    if (kind == VideoEffectKind.strobe && !(settings?.strobeWarned ?? _strobeWarnedHere)) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: Neon.yellow),
          title: const Text('Strobe flashes the whole frame'),
          content: const Text('Flashing light can trigger seizures in people with photosensitive epilepsy. Keep it '
              'gentle (a low amount, slow pulses), and warn your viewers if the video flashes. This shows once.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('video-strobe-ok'), onPressed: () => Navigator.pop(c, true),
                child: const Text('Add Strobe')),
          ],
        ),
      );
      if (go != true || !mounted) return;
      _strobeWarnedHere = true;
      if (settings != null) {
        settings.strobeWarned = true;
        settings.save();
      }
    }
    edit(() => effects.add(VideoEffect(kind: kind)));
  }

  bool _strobeWarnedHere = false;

  @override
  Widget build(BuildContext context) {
    final enabled = canEdit;
    final lane = ShotLane(
      key: _laneKey, timeline: t, stepsPerBar: spb, start: widget.start, end: widget.end, snap: d.snap,
      selected: selected, cursor: cursor, playhead: widget.playhead, onSelect: select, onCursor: setCursor,
      onBeginEdit: begin, onEdit: () => live(() {}), onEndEdit: end, enabled: enabled, onCutTap: pickTransition,
    );
    Widget tool(String key, String tip, IconData icon, VoidCallback? on, {Color? color}) => IconButton(
          key: ValueKey(key), tooltip: tip, iconSize: 20, color: color ?? Neon.dim, onPressed: enabled ? on : null,
          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), icon: Icon(icon));
    final toolbar = Row(children: [
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          TextButton.icon(
            key: const ValueKey('video-autocut'),
            onPressed: enabled ? openAutoCut : null,
            icon: Icon(Icons.auto_awesome, size: 18, color: videoAccent),
            label: Text('Auto-cut', style: TextStyle(color: videoAccent, fontWeight: FontWeight.w800)),
          ),
          tool('video-add', 'Add a shot at the cursor (A)', Icons.add_box_outlined, add, color: Neon.green),
          tool('video-split', 'Split at the cursor (S)', Icons.content_cut, split),
          tool('video-duplicate', 'Duplicate (Ctrl+D)', Icons.copy_all_outlined, selected == null ? null : duplicate),
          tool('video-delete', 'Delete (Del)', Icons.delete_outline, selected == null ? null : delete),
          tool('video-undo', 'Undo (Ctrl+Z)', Icons.undo, canUndo ? undo : null),
          tool('video-redo', 'Redo (Ctrl+Shift+Z)', Icons.redo, canRedo ? redo : null),
        ]))),
        if (widget.onFullScreen != null && widget.frame == null)
          IconButton(
            key: const ValueKey('video-editor-full-screen'),
            tooltip: widget.fullScreen ? 'Leave full screen (Esc)' : 'Full screen (F11)',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            onPressed: widget.enabled ? widget.onFullScreen : null,
            icon: Icon(widget.fullScreen ? Icons.close_fullscreen : Icons.open_in_full),
          ),
      ]);
    final busyBar = VideoReveal(_busy ? const Padding(padding: EdgeInsets.only(bottom: 4), child: LinearProgressIndicator(minHeight: 3)) : null);
    final snapRow = Row(children: [
        const Text('Snap', style: TextStyle(color: Neon.dim, fontSize: 11)),
        const SizedBox(width: 8),
        Expanded(child: VideoTiles<VideoSnap>(keyPrefix: 'video-snap', values: VideoSnap.values, selected: d.snap,
            height: 32, label: (v) => v.label, onPick: (v) {
              Haptics.tap();
              setState(() => d.snap = v);
              widget.onSave();
            })),
        IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            key: const ValueKey('video-lane-zoom-out'), tooltip: 'Zoom out', iconSize: 18,
            onPressed: () => _laneKey.currentState?.zoom(0.5, _fitPx(context)), icon: const Icon(Icons.zoom_out)),
        IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            key: const ValueKey('video-lane-zoom-in'), tooltip: 'Zoom in', iconSize: 18,
            onPressed: () => _laneKey.currentState?.zoom(2, _fitPx(context)), icon: const Icon(Icons.zoom_in)),
      ]);
    final message = VideoReveal(_message == null ? null : Padding(padding: const EdgeInsets.only(top: 6), child: Text(_message!,
          key: const ValueKey('video-editor-message'), maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Neon.dim))), switchKey: _message);
    final top = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      toolbar, busyBar, lane, const SizedBox(height: 6), snapRow, message,
    ]);
    final list = AbsorbPointer(absorbing: !enabled, child: ShotList(timeline: t, scene: widget.scene, snap: d.snap,
        selected: selected, onSelect: select, host: this, aspect: widget.aspect, start: widget.start, end: widget.end,
        parts: widget.listParts));
    return KeyArea(
      area: Area.video,
      label: 'Music video editor',
      focusNode: _focus,
      onAction: (id, count, arg) => runAction(id),
      child: Listener(
          // Any touch or click in the editor gives it the keyboard (its keys).
          onPointerDown: (_) {
            if (!_focus.hasFocus) _focus.requestFocus();
          },
          child: widget.frame != null
              ? widget.frame!(context, this, (toolbar: toolbar, lane: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min, children: [busyBar, lane]), snap: snapRow, message: message, list: list))
              : widget.side == null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [top, const SizedBox(height: 8), list])
                  : widget.side!(top, list),
      ),
    );
  }

  double _fitPx(BuildContext context) {
    final w = (context.findRenderObject() as RenderBox?)?.size.width ?? 320;
    final span = (widget.end - widget.start).clamp(1.0, double.infinity);
    return ((w - 16) / span).clamp(28.0 / spb, double.infinity);
  }
}

/// An undo step: the lane and the whole video's texts, images and image assets.
class _Snapshot {
  _Snapshot(this.timeline, this.texts, this.images, this.assets);
  factory _Snapshot.of(MusicVideoDoc d) => _Snapshot(d.timeline.copy(), [for (final x in d.texts) x.copy()],
      [for (final x in d.images) x.copy()], [for (final a in d.assets) VideoImageAsset.fromJson(a.toJson())!]);
  final VideoTimeline timeline;
  final List<VideoText> texts;
  final List<VideoImageLayer> images;
  final List<VideoImageAsset> assets;
}

/// Auto-cut's settings: the four triggers, each with its sensitivity or settings, and the shortest gap between cuts.
class AutoCutPanel extends StatefulWidget {
  const AutoCutPanel({super.key, required this.settings, this.canUseAudio = true});
  final AutoCutSettings settings;
  final bool canUseAudio;

  @override
  State<AutoCutPanel> createState() => _AutoCutPanelState();
}

class _AutoCutPanelState extends State<AutoCutPanel> {
  AutoCutSettings get a => widget.settings;

  void _set(VoidCallback f) {
    Haptics.tap();
    setState(f);
  }

  Widget _slider(String key, String label, double value, double min, double max, String text, ValueChanged<double> on,
          {int? divisions}) =>
      Row(children: [
        SizedBox(width: 92, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
        Expanded(child: Slider(key: ValueKey(key), value: value.clamp(min, max).toDouble(), min: min, max: max,
            divisions: divisions, onChanged: (v) => setState(() => on(v)))),
        SizedBox(width: 70, child: Text(text, textAlign: TextAlign.right, style: Neon.code(size: 10, color: Neon.text))),
      ]);

  @override
  Widget build(BuildContext context) => ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(12, 0, 12, 16 + MediaQuery.viewInsetsOf(context).bottom),
        children: [
          Row(children: [
            Icon(Icons.auto_awesome, size: 18, color: videoAccent),
            const SizedBox(width: 8),
            const Text('AUTO-CUT', style: TextStyle(fontSize: 13, letterSpacing: 1.6, fontWeight: FontWeight.w800)),
          ]),
          const VideoNote('Cuts where the triggers fire, then picks a view for each shot by the style and seed. '
              'You edit from there.'),
          VideoSection('EVERY N BARS OR BEATS', children: [
            VideoPill(key: const ValueKey('autocut-interval'), label: 'INTERVAL', on: a.interval, onTap: () => _set(() => a.interval = !a.interval)),
            VideoReveal(a.interval ? Column(children: [
              _slider('autocut-interval-count', 'Every', a.intervalCount.toDouble(), 1, 16,
                  '${a.intervalCount} ${a.intervalBars ? 'bar' : 'beat'}${a.intervalCount == 1 ? '' : 's'}',
                  (v) => a.intervalCount = v.round(), divisions: 15),
              VideoTiles<bool>(keyPrefix: 'autocut-interval-unit', values: const [true, false], selected: a.intervalBars,
                  height: 34, label: (v) => v ? 'Bars' : 'Beats', onPick: (v) => _set(() => a.intervalBars = v)),
            ]) : null),
          ]),
          VideoSection('NOTE BURSTS', children: [
            VideoPill(key: const ValueKey('autocut-bursts'), label: 'BURSTS', on: a.bursts, onTap: () => _set(() => a.bursts = !a.bursts)),
            VideoReveal(a.bursts ? _slider('autocut-burst-sens', 'Sensitivity', a.burstSensitivity, 0, 1,
                '${a.burstNotes} in a beat', (v) => a.burstSensitivity = v, divisions: 9) : null),
          ]),
          VideoSection('TRACKS ENTERING OR GOING QUIET', children: [
            VideoPill(key: const ValueKey('autocut-tracks'), label: 'TRACKS', on: a.tracks, onTap: () => _set(() => a.tracks = !a.tracks)),
            VideoReveal(a.tracks ? _slider('autocut-quiet', 'Quiet for', a.quietBars, 0.25, 8,
                '${a.quietBars.toStringAsFixed(2)} bars', (v) => a.quietBars = v, divisions: 31) : null),
          ]),
          VideoSection('LOUDNESS JUMPS', children: [
            VideoPill(key: const ValueKey('autocut-loudness'), label: 'DROPS AND BREAKDOWNS', on: a.loudness,
                onTap: () => _set(() => a.loudness = !a.loudness)),
            VideoReveal(a.loudness ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _slider('autocut-loud-sens', 'Sensitivity', a.loudnessSensitivity, 0, 1,
                  '${a.loudnessDb.toStringAsFixed(1)} dB', (v) => a.loudnessSensitivity = v, divisions: 18),
              VideoTiles<bool>(keyPrefix: 'autocut-loud-source', values: const [false, true], selected: a.fromAudio,
                  height: 34, enabled: (v) => !v || widget.canUseAudio,
                  label: (v) => v ? 'Rendered audio' : 'Notes', onPick: (v) => _set(() => a.fromAudio = v)),
              VideoNote(a.fromAudio
                  ? 'Renders the range offline first (a worker job) and reads its loudness per beat.'
                  : 'Reads loudness from the notes playing, at once, without rendering.'),
            ]) : null),
          ]),
          VideoSection('SPACING', children: [
            _slider('autocut-min', 'At least', a.minBeats, 0.5, 16, '${a.minBeats.toStringAsFixed(1)} beats',
                (v) => a.minBeats = v, divisions: 31),
            const VideoNote('Closer cuts merge; the stronger trigger keeps its place (loudness, then tracks, bursts, interval).'),
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('autocut-run'),
            style: FilledButton.styleFrom(backgroundColor: videoAccent, foregroundColor: Neon.bg,
                minimumSize: const Size.fromHeight(48)),
            onPressed: () {
              Haptics.drop();
              Navigator.pop(context, a);
            },
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Cut', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          VideoReveal(a.any ? null : const VideoNote('No trigger on: one shot covers the whole range.')),
        ],
      );
}
