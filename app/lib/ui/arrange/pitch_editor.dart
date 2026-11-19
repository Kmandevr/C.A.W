// The clip pitch editor (Lark, 1.1.0; owner 2026-11-19, "note blobs"): an audio clip's notes as blobs on a piano-roll grid, each shaped by its loudness with the pitch line through it; drag a blob up or down to retune it, sideways or at its edges for timing; knobs for the chosen note's drift, vibrato and transition, and Snap; rendered off the UI isolate as a new take or in place of the clip, one undo step. One voice only (the design's patent line: no polyphonic editing).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../engine/pitch_clip_engine.dart';
import '../../model/app_state.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/pitch_clip.dart';
import '../../model/project.dart';
import '../haptics.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../theme.dart';
import 'freeze_ui.dart';
import 'knob.dart';

/// The editor's colours: Lark's (the Pitch family's pink) and its second voice.
Color get _accent => Neon.pink;
Color get _second => Neon.violet;

/// Opens the editor full screen on [clip] of [layer] (after "Unfreeze to edit?" on a frozen track).
Future<void> showPitchEditor(BuildContext context, AppState s, LayerDoc layer, AudioClipDoc clip) async {
  if (!await editableOrUnfreeze(context, s, layer) || !context.mounted) return;
  final path = s.project.asset(clip.assetId)?.path;
  if (path == null) {
    Haptics.error();
    return;
  }
  await Navigator.of(context)
      .push(panelRoute<void>(context, (_) => PitchEditorScreen(state: s, layerId: layer.id, clipId: clip.id)));
}

/// The clip [layerId]'s track holds to edit: its selected audio clip, else its first; null when it has none.
AudioClipDoc? pitchClipOf(AppState s, LayerDoc layer) =>
    layer.audioClips.where((c) => s.selectedClipIds.contains(c.id)).firstOrNull ?? layer.audioClips.firstOrNull;

class PitchEditorScreen extends StatefulWidget {
  const PitchEditorScreen({super.key, required this.state, required this.layerId, required this.clipId});
  final AppState state;
  final String layerId, clipId;

  @override
  State<PitchEditorScreen> createState() => PitchEditorState();
}

/// What a finger on the roll is doing.
enum _Grab { none, pending, pitch, time, left, right, view }

class PitchEditorState extends State<PitchEditorScreen> with SingleTickerProviderStateMixin {
  late final PitchClipBackend _backend = (pitchClipBackendFor ?? (s) => NativePitchClipBackend(() => s.engine))(
    widget.state,
  );
  PitchJob<PitchClipSession>? _analysing;
  PitchJob<PitchRenderResult>? _rendering;
  PitchClipSession? _session;
  String? _error;

  /// The edits by note, and the editor's own undo and redo (snapshots of them).
  Map<int, PitchNoteEdit> edits = {};
  final List<Map<int, PitchNoteEdit>> _undo = [], _redo = [];
  int? selected;
  bool snap = true;
  PitchRenderTarget target = PitchRenderTarget.newTake;

  // The view: seconds at the roll's left edge and per pixel, the MIDI note at its top and pixels a semitone.
  double _x0 = 0, _spp = 0.01, _top = 72, _pps = 22;
  bool _viewSet = false;
  Size _roll = Size.zero;
  static const double keyboardWidth = 34;

  // The drawn pitch offsets settle to the edits' after a discrete change (undo, a reset, a snap on release).
  late final AnimationController _settle = AnimationController(vsync: this, value: 1);
  Map<int, double> _from = {};

  // The gesture in flight.
  _Grab _grab = _Grab.none;
  int? _grabNote;
  Offset _grabStart = Offset.zero;
  PitchNoteEdit _grabEdit = PitchNoteEdit.none;
  double _grabX0 = 0, _grabTop = 0, _grabSpp = 0;
  final Map<int, ({List<double> drift, List<double> vibrato})> _residual = {};

  AppState get s => widget.state;
  LayerDoc? get _layer => s.project.layers.where((l) => l.id == widget.layerId).firstOrNull;
  AudioClipDoc? get _clip => _layer?.audioClips.where((c) => c.id == widget.clipId).firstOrNull;
  PitchAnalysis? get analysis => _session?.analysis;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final path = s.project.asset(_clip?.assetId)?.path;
    if (path == null) {
      _error = 'the clip\'s audio is missing';
      return;
    }
    final job = _backend.analyse(path);
    _analysing = job;
    _error = null;
    job.result.then(
      (v) {
        if (!mounted) {
          if (v != null) _backend.release(v);
          return;
        }
        setState(() {
          _analysing = null;
          _session = v;
          if (v == null) Navigator.of(context).maybePop();
        });
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _analysing = null;
            _error = '$e';
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _analysing?.cancel();
    _rendering?.cancel();
    if (_session case final v?) _backend.release(v);
    _settle.dispose();
    super.dispose();
  }

  // ---------- edits ----------

  PitchNoteEdit editOf(int note) => edits[note] ?? PitchNoteEdit.none;

  void _snapshot() {
    _undo.add(Map.of(edits));
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
  }

  void _setEdit(int note, PitchNoteEdit e) {
    if (e.identity) {
      edits.remove(note);
    } else {
      edits[note] = e;
    }
  }

  /// Starts a settle from the offsets drawn now to the new edits.
  void _settleFromHere() {
    final a = analysis;
    if (a == null) return;
    _from = {for (final n in a.notes) n.index: _shownPitch(n.index)};
    _settle.duration = Motion.move(Motion.standard, Motion.usabilityOf(context));
    _settle.forward(from: 0);
  }

  double _shownPitch(int note) {
    final to = editOf(note).pitch;
    final from = _from[note];
    if (from == null || _settle.value >= 1) return to;
    return ui.lerpDouble(from, to, Curves.easeOutCubic.transform(_settle.value))!;
  }

  void undo() {
    if (_undo.isEmpty) return;
    _settleFromHere();
    setState(() {
      _redo.add(Map.of(edits));
      edits = _undo.removeLast();
    });
    Haptics.tap();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _settleFromHere();
    setState(() {
      _undo.add(Map.of(edits));
      edits = _redo.removeLast();
    });
    Haptics.tap();
  }

  /// Sets the chosen note's knob edit (one undo step a turn: [start] at its first change).
  void _editSelected(PitchNoteEdit Function(PitchNoteEdit e) change, {bool start = false}) {
    final n = selected;
    if (n == null) return;
    if (start) _snapshot();
    setState(() => _setEdit(n, change(editOf(n))));
  }

  // ---------- the view ----------

  double xOf(double seconds) => keyboardWidth + (seconds - _x0) / _spp;
  double yOf(double midi) => (_top - midi) * _pps;

  void _fitView(Size size) {
    final a = analysis, clip = _clip;
    if (a == null || clip == null || size.width <= keyboardWidth) return;
    _viewSet = true;
    final asset = s.project.asset(clip.assetId);
    final start = clip.offsetSeconds.clamp(0.0, a.seconds);
    final span = clip.sourceSeconds(s.project.bpm, asset?.bpm);
    final end = (span > 0 ? start + span : a.seconds).clamp(start + 0.05, a.seconds).toDouble();
    _x0 = start;
    _spp = (end - start) / (size.width - keyboardWidth - 8);
    final pitches = [for (final n in a.notes) n.pitch];
    final lo = pitches.isEmpty ? 55.0 : pitches.reduce(math.min),
        hi = pitches.isEmpty ? 67.0 : pitches.reduce(math.max);
    _pps = (size.height / (hi - lo + 8)).clamp(12.0, 30.0);
    _top = (hi + lo) / 2 + size.height / _pps / 2;
  }

  /// A note's span on the roll (seconds) with its edit.
  (double, double) _span(PitchAnalysis a, PitchNote n, PitchNoteEdit e) {
    final s0 = (n.start + e.timeFrames) / a.sampleRate;
    return (s0, s0 + n.length * e.stretch / a.sampleRate);
  }

  /// Where note [i]'s blob centre is on screen (tests drag it).
  Offset? noteCenterGlobal(int i) {
    final a = analysis;
    final box = _rollKey.currentContext?.findRenderObject() as RenderBox?;
    if (a == null || box == null || i >= a.notes.length) return null;
    final n = a.notes[i];
    final (t0, t1) = _span(a, n, editOf(i));
    return box.localToGlobal(Offset(xOf((t0 + t1) / 2), yOf(n.pitch + editOf(i).pitch)));
  }

  /// The note under [p] and which part: the body, or its left or right edge.
  (int, _Grab)? _hit(Offset p) {
    final a = analysis;
    if (a == null || p.dx < keyboardWidth) return null;
    (int, _Grab)? best;
    var bestD = double.infinity;
    for (final n in a.notes) {
      final e = editOf(n.index);
      final (t0, t1) = _span(a, n, e);
      final x0 = xOf(t0), x1 = xOf(t1), y = yOf(n.pitch + e.pitch);
      final dy = (p.dy - y).abs();
      if (dy > math.max(_pps * 0.9, 16) || p.dx < x0 - 14 || p.dx > x1 + 14) continue;
      final edge = math.min(14.0, (x1 - x0) / 4);
      final part = p.dx < x0 + edge ? _Grab.left : (p.dx > x1 - edge ? _Grab.right : _Grab.pending);
      if (dy < bestD) {
        bestD = dy;
        best = (n.index, part);
      }
    }
    return best;
  }

  final GlobalKey _rollKey = GlobalKey();

  /// Where the last finger came down: a gesture counts from there, so a drag follows the finger from its first pixel.
  Offset? _downAt;

  void _onStart(ScaleStartDetails d) {
    final at = d.pointerCount == 1 ? (_downAt ?? d.localFocalPoint) : d.localFocalPoint;
    _grabStart = at;
    _grabX0 = _x0;
    _grabTop = _top;
    _grabSpp = _spp;
    final hit = d.pointerCount == 1 ? _hit(at) : null;
    if (hit == null) {
      _grab = _Grab.view;
      return;
    }
    _grabNote = hit.$1;
    _grab = hit.$2;
    _grabEdit = editOf(hit.$1);
    _snapshot();
    _settle.value = 1;
    Haptics.grab();
    setState(() => selected = hit.$1);
  }

  void _onUpdate(ScaleUpdateDetails d) {
    final a = analysis;
    if (a == null) return;
    final delta = d.localFocalPoint - _grabStart;
    if (_grab == _Grab.view) {
      setState(() {
        if (d.pointerCount > 1 && d.horizontalScale > 0) {
          _spp = (_grabSpp / d.horizontalScale).clamp(0.0005, math.max(0.001, a.seconds / 100));
        }
        _x0 = (_grabX0 - delta.dx * _spp).clamp(-1.0, a.seconds).toDouble();
        _top = (_grabTop + delta.dy / _pps).clamp(24.0, 120.0).toDouble();
      });
      return;
    }
    final i = _grabNote;
    if (i == null) return;
    // A body drag picks its axis once it has moved: up and down retunes, sideways moves it in time.
    if (_grab == _Grab.pending) {
      if (delta.distance < 6) return;
      _grab = delta.dy.abs() >= delta.dx.abs() ? _Grab.pitch : _Grab.time;
    }
    final n = a.notes[i];
    final frames = (delta.dx * _spp * a.sampleRate).round();
    final limit = 10 * a.sampleRate;
    PitchNoteEdit next;
    switch (_grab) {
      case _Grab.pitch:
        var p = _grabEdit.pitch - delta.dy / _pps;
        if (snap) p = snapPitchOffset(n.pitch, p);
        next = _grabEdit.copyWith(pitch: p);
        if ((n.pitch + next.pitch).round() != (n.pitch + editOf(i).pitch).round()) Haptics.tick();
      case _Grab.time:
        next = _grabEdit.copyWith(timeFrames: (_grabEdit.timeFrames + frames).clamp(-limit, limit));
      case _Grab.left:
        // The start moves, the end stays: the move and the stretch together.
        final len = n.length * _grabEdit.stretch;
        final st = ((len - frames) / n.length).clamp(PitchNoteEdit.minStretch, PitchNoteEdit.maxStretch);
        final moved = (len - st * n.length).round();
        next = _grabEdit.copyWith(stretch: st, timeFrames: (_grabEdit.timeFrames + moved).clamp(-limit, limit));
      case _Grab.right:
        next = _grabEdit.copyWith(stretch: (n.length * _grabEdit.stretch + frames) / n.length);
      default:
        return;
    }
    setState(() => _setEdit(i, next));
  }

  void _onEnd(ScaleEndDetails d) {
    if (_grabNote case final i? when _grab != _Grab.view) {
      if (editOf(i) == _grabEdit) _undo.removeLast();
      Haptics.drop();
    }
    _grab = _Grab.none;
    _grabNote = null;
  }

  void _onTap(TapUpDetails d) {
    final hit = _hit(d.localPosition);
    setState(() => selected = hit?.$1);
    if (hit != null) Haptics.tap();
  }

  /// A double tap on a note puts it back as it was sung.
  void _onDoubleTap(TapDownDetails d) {
    final hit = _hit(d.localPosition);
    if (hit == null || editOf(hit.$1).identity) return;
    _snapshot();
    _settleFromHere();
    setState(() => edits.remove(hit.$1));
    Haptics.tap();
  }

  // ---------- render ----------

  Future<void> render() async {
    final session = _session, layer = _layer, clip = _clip;
    if (session == null || layer == null || clip == null || _rendering != null) return;
    final job = _backend.render(session, Map.of(edits), s.pitchRenderPath(clip));
    setState(() {
      _rendering = job;
      _error = null;
    });
    try {
      final r = await job.result;
      if (!mounted) return;
      setState(() => _rendering = null);
      if (r == null) return;
      final asset = s.applyPitchRender(layer, clip, r, target: target);
      if (asset == null) {
        setState(() => _error = 'the clip changed or its track is frozen; nothing was changed');
        return;
      }
      Haptics.drop();
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            target == PitchRenderTarget.newTake
                ? 'Pitch edits rendered as a new take'
                : 'Pitch edits rendered into the clip',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _rendering = null;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _close() async {
    if (edits.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard pitch edits?'),
        content: const Text('They are not rendered yet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
          TextButton(
            key: const ValueKey('pitch-discard'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (go == true && mounted) Navigator.of(context).pop();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final clip = _clip;
    final name = clip == null ? 'Clip' : s.audioClipName(clip);
    return PopScope(
      canPop: edits.isEmpty,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _close();
      },
      child: Scaffold(
        key: const ValueKey('pitch-editor'),
        backgroundColor: Neon.bg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: _close),
          titleSpacing: 0,
          title: Text(
            'Edit pitch · $name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16),
          ),
          actions: [
            IconButton(
              key: const ValueKey('pitch-undo'),
              icon: const Icon(Icons.undo),
              tooltip: 'Undo',
              onPressed: _undo.isEmpty ? null : undo,
            ),
            IconButton(
              key: const ValueKey('pitch-redo'),
              icon: const Icon(Icons.redo),
              tooltip: 'Redo',
              onPressed: _redo.isEmpty ? null : redo,
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _rollArea()),
              AnimatedSwitcher(
                duration: Motion.fade(Motion.standard, Motion.of(context)),
                child: _error == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(_error),
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                        child: Text(
                          _error!,
                          key: const ValueKey('pitch-error'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Neon.layers[7], fontSize: 12),
                        ),
                      ),
              ),
              _notePanel(),
              _renderBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rollArea() {
    final a = analysis;
    final job = _analysing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: Neon.ramp([Color.lerp(Neon.bg, _accent, 0.08)!, Color.lerp(Neon.bg, _accent, 0.02)!]),
            ),
            border: Border.all(color: _accent.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final size = Size(box.maxWidth, box.maxHeight);
              if (size != _roll) {
                _roll = size;
                _viewSet = false;
              }
              if (a != null && !_viewSet) _fitView(size);
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (a != null)
                    Listener(
                      onPointerDown: (e) => _downAt = e.localPosition,
                      child: GestureDetector(
                        key: const ValueKey('pitch-roll'),
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _onStart,
                        onScaleUpdate: _onUpdate,
                        onScaleEnd: _onEnd,
                        onTapUp: _onTap,
                        onDoubleTapDown: _onDoubleTap,
                        onDoubleTap: () {},
                        child: AnimatedBuilder(
                          animation: _settle,
                          builder: (context, _) => CustomPaint(
                            key: _rollKey,
                            size: size,
                            painter: PitchRollPainter(
                              analysis: a,
                              edits: {for (final n in a.notes) n.index: editOf(n.index)},
                              shownPitch: {for (final n in a.notes) n.index: _shownPitch(n.index)},
                              residual: _residualOf,
                              selected: selected,
                              x0: _x0,
                              spp: _spp,
                              top: _top,
                              pps: _pps,
                              window: _window(),
                              accent: _accent,
                              second: _second,
                              keyboard: keyboardWidth,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (a != null && a.notes.isEmpty)
                    const Center(
                      child: Text('No sung notes found in this clip', style: TextStyle(color: Neon.dim)),
                    ),
                  AnimatedSwitcher(
                    duration: Motion.fade(Motion.standard, Motion.of(context)),
                    child: job == null
                        ? const SizedBox.shrink()
                        : _progress(
                            job,
                            key: const ValueKey('pitch-progress'),
                            onCancel: () {
                              job.cancel();
                              Navigator.of(context).maybePop();
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The clip's window onto the file (seconds): the part it plays.
  (double, double)? _window() {
    final clip = _clip, a = analysis;
    if (clip == null || a == null) return null;
    final span = clip.sourceSeconds(s.project.bpm, s.project.asset(clip.assetId)?.bpm);
    return (clip.offsetSeconds, clip.offsetSeconds + (span > 0 ? span : a.seconds));
  }

  ({List<double> drift, List<double> vibrato}) _residualOf(PitchNote n) => _residual.putIfAbsent(n.index, () {
    final r = pitchResidual(analysis!, n);
    return (drift: r.drift, vibrato: r.vibrato);
  });

  Widget _progress(PitchJob<Object?> job, {required Key key, required VoidCallback onCancel}) => Center(
    key: key,
    child: Container(
      width: 260,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ValueListenableBuilder<String>(
            valueListenable: job.stage,
            builder: (_, st, _) =>
                Text(st.isEmpty ? 'Starting…' : '$st…', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<double?>(
            valueListenable: job.progress,
            builder: (_, p, _) => LinearProgressIndicator(value: p, color: _accent, backgroundColor: Neon.line),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(key: const ValueKey('pitch-cancel'), onPressed: onCancel, child: const Text('Cancel')),
          ),
        ],
      ),
    ),
  );

  Widget _notePanel() {
    final a = analysis;
    final i = selected;
    final n = a == null || i == null || i >= a.notes.length ? null : a.notes[i];
    final e = n == null ? PitchNoteEdit.none : editOf(n.index);
    final on = n != null;
    final readout = n == null
        ? 'Tap a note to shape it · drag it to retune or move'
        : '${pitchNoteName(n.pitch)} ${pitchCentsLabel(n.pitch)}  →  ${pitchNoteName(n.pitch + e.pitch)} '
              '${pitchCentsLabel(n.pitch + e.pitch)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            child: Text(
              readout,
              key: ValueKey(readout),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Neon.code(size: 11, color: on ? Neon.text : Neon.dim),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.spaceEvenly,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              AnimatedOpacity(
                opacity: on ? 1 : 0.45,
                duration: Motion.fade(Motion.standard, Motion.of(context)),
                child: Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _knob(
                      'pitch-drift',
                      'Drift',
                      e.drift * 100,
                      0,
                      100,
                      100,
                      (v) => '${v.round()}%',
                      (e, v) => e.copyWith(drift: v / 100),
                      on,
                    ),
                    _knob(
                      'pitch-vibrato',
                      'Vibrato',
                      e.vibrato * 100,
                      0,
                      200,
                      100,
                      (v) => '${v.round()}%',
                      (e, v) => e.copyWith(vibrato: v / 100),
                      on,
                    ),
                    _knob(
                      'pitch-transition',
                      'Transition',
                      e.transitionMs,
                      0,
                      500,
                      30,
                      (v) => '${v.round()} ms',
                      (e, v) => e.copyWith(transitionMs: v),
                      on,
                    ),
                  ],
                ),
              ),
              // Snap is the drags' setting: it works with no note chosen.
              FilterChip(
                key: const ValueKey('pitch-snap'),
                label: const Text('Snap'),
                avatar: Icon(Icons.straighten, size: 16, color: snap ? _accent : Neon.dim),
                selected: snap,
                showCheckmark: false,
                selectedColor: _accent.withValues(alpha: 0.2),
                tooltip: 'Drags land on whole semitones',
                onSelected: (v) {
                  Haptics.tap();
                  setState(() => snap = v);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _turning = false;

  Widget _knob(
    String key,
    String label,
    double value,
    double min,
    double max,
    double def,
    String Function(double) text,
    PitchNoteEdit Function(PitchNoteEdit e, double v) change,
    bool on,
  ) => Knob(
    key: ValueKey(key),
    value: value.clamp(min, max),
    min: min,
    max: max,
    defaultValue: def,
    label: label,
    size: 40,
    color: _accent,
    enabled: on,
    valueText: text,
    onChanged: (v) {
      _knob2(change, v);
    },
    onChangeEnd: () => _turning = false,
  );

  void _knob2(PitchNoteEdit Function(PitchNoteEdit e, double v) change, double v) {
    _editSelected((e) => change(e, v), start: !_turning);
    _turning = true;
  }

  Widget _renderBar() {
    final job = _rendering;
    final ready = _session != null && edits.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: AnimatedSwitcher(
        duration: Motion.fade(Motion.standard, Motion.of(context)),
        child: job != null
            ? Row(
                key: const ValueKey('pitch-rendering'),
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ValueListenableBuilder<String>(
                          valueListenable: job.stage,
                          builder: (_, st, _) =>
                              Text(st.isEmpty ? 'Rendering…' : '$st…', style: const TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(height: 4),
                        ValueListenableBuilder<double?>(
                          valueListenable: job.progress,
                          builder: (_, p, _) =>
                              LinearProgressIndicator(value: p, color: _accent, backgroundColor: Neon.line),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    key: const ValueKey('pitch-render-cancel'),
                    onPressed: () {
                      job.cancel();
                      setState(() => _rendering = null);
                    },
                    child: const Text('Cancel'),
                  ),
                ],
              )
            : Row(
                key: const ValueKey('pitch-render-row'),
                children: [
                  Expanded(
                    child: SegmentedButton<PitchRenderTarget>(
                      key: const ValueKey('pitch-target'),
                      showSelectedIcon: false,
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: const [
                        ButtonSegment(
                          value: PitchRenderTarget.newTake,
                          label: Text('New take'),
                          icon: Icon(Icons.layers_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: PitchRenderTarget.replace,
                          label: Text('Replace'),
                          icon: Icon(Icons.swap_vert, size: 16),
                        ),
                      ],
                      selected: {target},
                      onSelectionChanged: (v) => setState(() => target = v.first),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    key: const ValueKey('pitch-render'),
                    style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Neon.bg),
                    onPressed: ready ? render : null,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Render'),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The roll: the keyboard down the left, semitone rows (the black keys darker), seconds across, the part of the
/// file the clip doesn't play dimmed; each note a blob as thick as it is loud, where its edit puts it (the sung
/// place a faint outline behind a moved one), the pitch line through it (its drift and vibrato scaled as the edit
/// says, ≈), and a lark perched on the chosen note.
class PitchRollPainter extends CustomPainter {
  PitchRollPainter({
    required this.analysis,
    required this.edits,
    required this.shownPitch,
    required this.residual,
    required this.selected,
    required this.x0,
    required this.spp,
    required this.top,
    required this.pps,
    required this.window,
    required this.accent,
    required this.second,
    required this.keyboard,
  });
  final PitchAnalysis analysis;
  final Map<int, PitchNoteEdit> edits;
  final Map<int, double> shownPitch;
  final ({List<double> drift, List<double> vibrato}) Function(PitchNote n) residual;
  final int? selected;
  final double x0, spp, top, pps, keyboard;
  final (double, double)? window;
  final Color accent, second;

  static const _black = {1, 3, 6, 8, 10};

  double _x(double seconds) => keyboard + (seconds - x0) / spp;
  double _y(double midi) => (top - midi) * pps;

  /// Where the lark perches: on top of note [n]'s blob, near its start ([left], [y] its top edge).
  static Offset larkPerch(double left, double right, double y) =>
      Offset(math.min(left + 14, (left + right) / 2), y - 1);

  @override
  void paint(Canvas canvas, Size size) {
    final a = analysis;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Rows.
    final lo = (top - size.height / pps).floor() - 1, hi = top.ceil() + 1;
    for (var m = lo; m <= hi; m++) {
      final y0 = _y(m + 0.5), y1 = _y(m - 0.5);
      if (_black.contains(m % 12)) {
        canvas.drawRect(Rect.fromLTRB(keyboard, y0, size.width, y1), Paint()..color = Neon.ink.withAlpha(0x0a));
      }
      canvas.drawLine(
        Offset(keyboard, y1),
        Offset(size.width, y1),
        Paint()..color = Neon.ink.withAlpha(m % 12 == 0 ? 0x22 : 0x0c),
      );
    }
    // Seconds.
    final step = _niceStep(spp * 90);
    for (var t = (x0 / step).floor() * step; _x(t) < size.width; t += step) {
      final x = _x(t);
      if (x < keyboard) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = Neon.ink.withAlpha(0x10));
      _label(
        canvas,
        step < 1 ? '${t.toStringAsFixed(step < 0.5 ? 2 : 1)}s' : '${t.round()}s',
        Offset(x + 3, size.height - 10),
        Neon.dim,
        8,
      );
    }
    // The clip's window: what it doesn't play is dimmed.
    if (window case (final w0, final w1)) {
      final dim = Paint()..color = Neon.bg.withValues(alpha: 0.55);
      if (_x(w0) > keyboard) canvas.drawRect(Rect.fromLTRB(keyboard, 0, _x(w0), size.height), dim);
      if (_x(w1) < size.width) {
        canvas.drawRect(Rect.fromLTRB(math.max(keyboard, _x(w1)), 0, size.width, size.height), dim);
      }
    }
    // The curve where no note is (breaths, slides): faint.
    final rate = a.sampleRate, hop = a.hopFrames;
    final h0 = a.hopAt(x0 * rate), h1 = a.hopAt((x0 + (size.width - keyboard) * spp) * rate);
    final inNote = List<bool>.filled(h1 - h0 + 1, false);
    for (final n in a.notes) {
      for (var h = math.max(h0, a.hopAt(n.start.toDouble())); h <= math.min(h1, a.hopAt(n.end.toDouble())); h++) {
        inNote[h - h0] = true;
      }
    }
    final loose = Path();
    var pen = false;
    for (var h = h0; h <= h1; h++) {
      final m = a.midi[h];
      if (m <= 0 || inNote[h - h0]) {
        pen = false;
        continue;
      }
      final p = Offset(_x(h * hop / rate), _y(m));
      pen ? loose.lineTo(p.dx, p.dy) : loose.moveTo(p.dx, p.dy);
      pen = true;
    }
    canvas.drawPath(
      loose,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Neon.dim.withValues(alpha: 0.5),
    );
    // The notes.
    Rect? perch;
    for (final n in a.notes) {
      final e = edits[n.index] ?? PitchNoteEdit.none;
      final t0 = (n.start + e.timeFrames) / rate, t1 = t0 + n.length * e.stretch / rate;
      if (_x(t1) < keyboard - 20 || _x(t0) > size.width + 20) continue;
      final sel = n.index == selected;
      final centre = n.pitch + (shownPitch[n.index] ?? e.pitch);
      if (!e.identity) _blob(canvas, a, n, n.start / rate, n.end / rate, n.pitch, ghost: true);
      final r = _blob(canvas, a, n, t0, t1, centre, selected: sel);
      _line(canvas, a, n, e, t0, t1, centre - n.pitch, sel);
      if (sel || (selected == null && perch == null)) perch = r;
    }
    if (perch != null) _lark(canvas, larkPerch(perch.left, perch.right, perch.top));
    canvas.restore();
    _keyboard(canvas, size, lo, hi);
  }

  /// A note's blob from [t0] to [t1] seconds around [centre]: its loudness per hop sets the thickness.
  Rect _blob(
    Canvas canvas,
    PitchAnalysis a,
    PitchNote n,
    double t0,
    double t1,
    double centre, {
    bool selected = false,
    bool ghost = false,
  }) {
    final hA = a.hopAt(n.start.toDouble()), hB = math.max(hA + 1, a.hopAt(n.end.toDouble()));
    final y = _y(centre);
    final topEdge = <Offset>[], bottomEdge = <Offset>[];
    final count = hB - hA;
    final every = math.max(1, (count / 160).ceil());
    for (var h = hA; h <= hB; h += every) {
      final u = (h - hA) / count;
      final loud = ((a.rmsDb[h.clamp(0, a.hops - 1)] + 60) / 60).clamp(0.0, 1.0);
      // Rounded ends: the swell is held to a half-ellipse over the first and last tenth.
      final ends = math.sqrt(math.max(0.0, 1 - math.pow((u - 0.5).abs() * 2, 8).toDouble()));
      final half = pps * (0.18 + 0.5 * loud) * (0.35 + 0.65 * ends);
      final x = _x(t0 + u * (t1 - t0));
      topEdge.add(Offset(x, y - half));
      bottomEdge.add(Offset(x, y + half));
    }
    final path = Path()..moveTo(topEdge.first.dx, topEdge.first.dy);
    for (final p in topEdge.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    for (final p in bottomEdge.reversed) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();
    final bounds = path.getBounds();
    if (ghost) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Neon.dim.withValues(alpha: 0.45),
      );
      return bounds;
    }
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: Neon.ramp([
            accent.withValues(alpha: selected ? 0.55 : 0.32),
            second.withValues(alpha: selected ? 0.4 : 0.2),
          ]),
        ).createShader(bounds.inflate(1)),
    );
    if (selected && !Neon.flat) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = accent.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 1.6 : 1
        ..color = accent.withValues(alpha: selected ? 0.95 : 0.6),
    );
    // The edges, where a finger stretches it.
    if (selected) {
      for (final x in [bounds.left, bounds.right]) {
        canvas.drawLine(
          Offset(x, y - 6),
          Offset(x, y + 6),
          Paint()
            ..color = Neon.text
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    return bounds;
  }

  /// The pitch line through a note as its edit renders it (≈): moved by the offset, its drift and vibrato scaled.
  void _line(
    Canvas canvas,
    PitchAnalysis a,
    PitchNote n,
    PitchNoteEdit e,
    double t0,
    double t1,
    double offset,
    bool sel,
  ) {
    final res = residual(n);
    final hA = a.hopAt(n.start.toDouble());
    final path = Path();
    var pen = false;
    for (var k = 0; k < res.drift.length; k++) {
      final h = hA + k;
      if (h >= a.hops) break;
      final m = a.midi[h];
      if (m <= 0) {
        pen = false;
        continue;
      }
      final u = ((h * a.hopFrames - n.start) / n.length).clamp(0.0, 1.0);
      final v = n.pitch + offset + res.drift[k] * e.drift + res.vibrato[k] * e.vibrato;
      final p = Offset(_x(t0 + u * (t1 - t0)), _y(v));
      pen ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      pen = true;
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sel ? 1.8 : 1.3
        ..strokeJoin = StrokeJoin.round
        ..color = Neon.text.withValues(alpha: sel ? 0.95 : 0.7),
    );
  }

  /// A small lark (a crested songbird, side on, facing right) standing at [at] (its feet).
  void _lark(Canvas canvas, Offset at) {
    final c = Neon.text.withValues(alpha: 0.5);
    final p = Paint()..color = c;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    final body = Path()
      ..moveTo(-8, -5) // tail tip
      ..lineTo(-3.5, -5.5)
      ..quadraticBezierTo(-1, -9.5, 3.5, -8.5) // back to the nape
      ..lineTo(3.2, -10.6) // the crest
      ..lineTo(5, -9.4)
      ..quadraticBezierTo(6.4, -9, 6.6, -7.6) // crown to the bill
      ..lineTo(9, -7.1) // the bill
      ..lineTo(6.4, -6.6)
      ..quadraticBezierTo(5, -3, 0.5, -2.6) // throat and breast
      ..quadraticBezierTo(-3, -2.6, -4.5, -4.3)
      ..close();
    canvas.drawPath(body, p);
    canvas.drawLine(
      const Offset(0.5, -2.8),
      const Offset(0, 0),
      Paint()
        ..color = c
        ..strokeWidth = 0.8,
    );
    canvas.drawLine(
      const Offset(2, -2.8),
      const Offset(2.3, 0),
      Paint()
        ..color = c
        ..strokeWidth = 0.8,
    );
    canvas.drawCircle(const Offset(5.2, -8), 0.6, Paint()..color = Neon.bg);
    canvas.restore();
  }

  void _keyboard(Canvas canvas, Size size, int lo, int hi) {
    canvas.drawRect(Rect.fromLTWH(0, 0, keyboard, size.height), Paint()..color = Neon.panel);
    for (var m = lo; m <= hi; m++) {
      final y0 = _y(m + 0.5), y1 = _y(m - 0.5);
      final black = _black.contains(m % 12);
      canvas.drawRect(
        Rect.fromLTRB(0, y0 + 0.5, black ? keyboard * 0.62 : keyboard, y1 - 0.5),
        Paint()..color = black ? Neon.bg : Neon.panelHi,
      );
      if (m % 12 == 0 && pps >= 10) {
        _label(canvas, 'C${m ~/ 12 - 1}', Offset(keyboard - 18, (y0 + y1) / 2 - 4), Neon.dim, 8);
      }
    }
    canvas.drawLine(
      Offset(keyboard, 0),
      Offset(keyboard, size.height),
      Paint()..color = accent.withValues(alpha: 0.35),
    );
  }

  static double _niceStep(double seconds) {
    for (final s in const [0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0]) {
      if (s >= seconds) return s;
    }
    return 120;
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: Neon.code(size: size, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(PitchRollPainter o) => true;
}
