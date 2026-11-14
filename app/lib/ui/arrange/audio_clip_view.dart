// An audio clip in the arranger, REAPER-style: its waveform; drag the body to move it (onto another track too), the
// edges to trim (the right one past the file's end loops it), the top corners for fades (their dot bends the curve)
// the top-middle handle for gain and, on a clip that doesn't follow the tempo, the stretch notch in its top-right
// corner (batch 1.0.4, owner 2026-11-14: drag it to time-stretch, with the new length shown). As a MIDI clip (owner, 2026-11-12): a tap selects, a double tap opens its
// editor (the Clip tab), a hold or right-click opens its menu, and a hold that moves picks it up whole.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/arrange_edit.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/project.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../pointer_input.dart';
import '../theme.dart';
import 'arrange_drag.dart';
import 'audio_waveform.dart';
import '../../model/sample_edit.dart';
import 'edit_cues.dart';
import 'long_press_menu.dart';
import 'take_chip.dart';
import 'track_color.dart';

/// What an in-progress gesture on the clip changes; the clip draws it at once and the project takes it on release.
enum _Grab { none, move, trimStart, trimEnd, fadeIn, fadeOut, curveIn, curveOut, gain, stretch }

class AudioClipView extends StatefulWidget {
  const AudioClipView({super.key, required this.state, required this.layer, required this.clip, required this.stepW,
      required this.height, required this.color, required this.selected, this.drag, this.onOpen, this.selectMode,
      this.guides});
  final AppState state;
  final LayerDoc layer;
  final AudioClipDoc clip;
  final double stepW, height;
  final Color color;
  final bool selected;
  final ArrangeDrag? drag;

  /// Opens the clip's inspector (the focus view's Clip tab).
  final VoidCallback? onOpen;

  /// Whether Select mode is on (a tap adds or removes the clip).
  final bool Function()? selectMode;

  /// The arranger's drag guides: the clip's span while it moves or an edge trims (owner, 2026-11-12).
  final ValueNotifier<ClipGuide?>? guides;

  @override
  State<AudioClipView> createState() => AudioClipViewState();
}

@visibleForTesting
class AudioClipViewState extends State<AudioClipView> {
  _Grab _grab = _Grab.none;
  Offset _delta = Offset.zero;
  Offset _from = Offset.zero;
  double? _value; // the fade (seconds), gain (linear) or curve being dragged
  FadeCurve? _curve;
  int? _lastSnap;
  bool _ignored = false;

  /// The move began with a long press (owner, 2026-11-11): the clip is picked up whole, edges included, and a resting
  /// second finger frees it from the grid.
  bool _lifted = false;

  AppState get s => widget.state;
  AudioClipDoc get c => widget.clip;
  double get bpm => s.project.bpm;
  double get _secPerPx => 15 / bpm / widget.stepW * _k;

  /// The steps the clip spans as drawn: its true width on the tempo map (#208).
  double get _span => c.spanSteps(s.project.tempo);

  /// Steps at the first tempo ([AudioClipDoc.lengthAt]) per drawn step: 1 without tempo changes.
  double get _k {
    final span = _span;
    return c.fixed && span > 0 ? c.lengthAt(bpm) / span : 1;
  }

  /// Seconds of output from song step [from] to [to], on the tempo map.
  double _secondsBetween(double from, double to) =>
      s.project.tempo.secondsAt(to / 4) - s.project.tempo.secondsAt(from / 4);
  bool get _free => HardwareKeyboard.instance.isShiftPressed || (_lifted && (widget.drag?.free.value ?? false));
  int get _snap => s.arrangementSnapSteps;
  AudioAssetDoc? get _asset => s.project.asset(c.assetId);

  double _snapped(double steps) => _free ? steps : (steps / _snap).round() * _snap.toDouble();

  void _tick(double at) {
    final k = (at * 1000).round();
    if (_lastSnap != null && _lastSnap != k) Motion.tick();
    _lastSnap = k;
  }

  // ---------- what the clip looks like mid-gesture ----------

  double get _shownStart => switch (_grab) {
        _Grab.move => math.max(0, _snapped(c.startSteps + _delta.dx / widget.stepW)),
        _Grab.trimStart => _trimTarget(),
        _ => c.startSteps,
      };

  double get _shownLength => switch (_grab) {
        _Grab.trimStart => c.startSteps + _span - _trimTarget(),
        _Grab.trimEnd => _resizeTarget(),
        _Grab.stretch => _stretchTarget(),
        _ => _span,
      };

  double _trimTarget() {
    final per = c.sourcePerStep(bpm, _asset?.bpm);
    var t = _snapped(c.startSteps + _delta.dx / widget.stepW);
    if (!c.loop && per > 0) t = math.max(t, c.startSteps - c.offsetSeconds / per);
    return t.clamp(0.0, c.startSteps + _span - AudioClipDoc.minLengthSteps).toDouble();
  }

  double _resizeTarget() => math.max(AudioClipDoc.minLengthSteps,
      _snapped(c.startSteps + _span + _delta.dx / widget.stepW) - c.startSteps);

  /// The notch's length in drawn steps: the end snapped, the stretch held to a quarter..four times the file part.
  double _stretchTarget() {
    final (lo, hi) = stretchLimits(c);
    var len = math.max(AudioClipDoc.minLengthSteps, _snapped(c.startSteps + _span + _delta.dx / widget.stepW) - c.startSteps);
    final secs = _secondsBetween(c.startSteps, c.startSteps + len);
    if (secs < lo || secs > hi) {
      final want = secs.clamp(lo, hi).toDouble();
      final t = s.project.tempo;
      len = t.beatAt(t.secondsAt(c.startSteps / 4) + want) * 4 - c.startSteps;
    }
    return len;
  }

  /// The notch's readout: the new length and the stretch.
  String _stretchLabel() {
    final secs = _secondsBetween(c.startSteps, c.startSteps + _stretchTarget());
    final ratio = c.stretchRatio * secs / math.max(1e-9, c.lengthSeconds);
    return '${secs.toStringAsFixed(2)} s · ×${ratio.toStringAsFixed(2)}';
  }

  // ---------- gestures ----------

  final _hold = HoldToMove();

  /// The last pointer down on the clip: the finger a hold follows.
  int _downPointer = 0;

  @override
  void dispose() {
    _hold.stop();
    super.dispose();
  }

  /// A hold opens the clip's menu (owner, 2026-11-12); moving past the touch slop closes it and picks the clip up,
  /// carried in time and across tracks from where the finger went down.
  void _lift(LongPressStartDetails d) {
    if ((widget.drag?.pinching ?? false) || _grab != _Grab.none) return;
    _hold.start(_downPointer, d.globalPosition,
      begin: (from) {
        if (!mounted || c.lock) return;
        Motion.tick();
        _begin(_Grab.move, from, lift: true);
      },
      move: (at) { if (_lifted) _update(at); },
      end: (cancel) {
        if (!_lifted) return;
        cancel ? _cancel() : _end();
      });
    showAudioClipMenu(context, s, widget.layer, c, d.globalPosition, onOpen: widget.onOpen);
  }

  /// The guides for the move or trim in progress, or none.
  void _guide() {
    final g = widget.guides;
    if (g == null) return;
    final shows = _grab == _Grab.move || _grab == _Grab.trimStart || _grab == _Grab.trimEnd || _grab == _Grab.stretch;
    g.value = shows ? ClipGuide(_shownStart, _shownStart + _shownLength, widget.color) : null;
  }

  void _freeChanged() {
    if (mounted && _grab == _Grab.move) setState(() {});
  }

  void _begin(_Grab g, Offset at, {bool lift = false}) {
    _ignored = c.lock && g != _Grab.none || (widget.drag?.pinching ?? false);
    if (_ignored) {
      if (c.lock) Haptics.error();
      return;
    }
    Haptics.grab();
    setState(() {
      _grab = g;
      _from = at;
      _delta = Offset.zero;
      _lastSnap = null;
      _value = switch (g) {
        _Grab.fadeIn => c.fadeIn,
        _Grab.fadeOut => c.fadeOut,
        _Grab.gain => c.gain,
        _ => null,
      };
      _curve = g == _Grab.curveIn ? c.fadeInCurve : g == _Grab.curveOut ? c.fadeOutCurve : null;
    });
    _lifted = lift && g == _Grab.move;
    _guide();
    if (g == _Grab.move) {
      widget.drag?.begin(onScroll: () => setState(() {}), onCancel: _cancel, lift: _lifted);
      widget.drag?.free.addListener(_freeChanged);
    }
  }

  void _update(Offset global) {
    if (_ignored || _grab == _Grab.none) return;
    final d = global - _from;
    setState(() {
      final step = d - _delta;
      _delta = d;
      switch (_grab) {
        case _Grab.move:
          _tick(_shownStart);
          final drag = widget.drag;
          if (drag != null) {
            drag.point(global);
            drag.hover.value = drag.spotAt(global);
          }
        case _Grab.trimStart:
          _tick(_trimTarget());
        case _Grab.trimEnd:
          _tick(_resizeTarget());
        case _Grab.stretch:
          _tick(_stretchTarget());
        case _Grab.fadeIn:
          _value = math.max(0.0, (_value ?? 0) + step.dx * _secPerPx);
        case _Grab.fadeOut:
          _value = math.max(0.0, (_value ?? 0) - step.dx * _secPerPx);
        case _Grab.gain:
          // 2 px a quarter dB, up louder; the dB stays between silence (-60) and +12.
          final db = (gainToDb(_value ?? 1) - step.dy / 8).clamp(-60.0, 12.0);
          _value = dbToGain(db);
          _tick((db * 2).roundToDouble());
        case _Grab.curveIn || _Grab.curveOut:
          // Every 14 px up or down bends the curve one shape.
          final i = (FadeCurve.values.indexOf(_grab == _Grab.curveIn ? c.fadeInCurve : c.fadeOutCurve) -
                  (d.dy / 14).round())
              .clamp(0, FadeCurve.values.length - 1);
          if (FadeCurve.values[i] != _curve) Haptics.tick();
          _curve = FadeCurve.values[i];
        case _Grab.none:
          break;
      }
    });
    _guide();
  }

  void _end() {
    if (_ignored || _grab == _Grab.none) return _reset();
    final l = widget.layer;
    switch (_grab) {
      case _Grab.move:
        final drag = widget.drag;
        final spot = drag?.hover.value;
        final copy = HardwareKeyboard.instance.isControlPressed || (drag?.copy.value ?? false);
        final target = spot == null || spot.newTrack
            ? null
            : s.project.layers.where((x) => x.id == spot.layerId).firstOrNull;
        if (spot != null && (spot.newTrack || (target != null && target.id != l.id)) || copy) {
          s.moveAudioClipTo(l, c, spot?.newTrack ?? false ? null : target ?? l, _shownStart, copy: copy);
        } else if (_shownStart != c.startSteps) {
          s.moveAudioClip(l, c, _shownStart);
        }
      case _Grab.trimStart:
        s.trimAudioClipStart(l, c, _trimTarget());
      case _Grab.trimEnd:
        s.resizeAudioClipTo(l, c, _resizeTarget() * _k);
      case _Grab.stretch:
        s.stretchAudioClipTo(l, c, _secondsBetween(c.startSteps, c.startSteps + _stretchTarget()));
      case _Grab.fadeIn:
        s.setAudioFades(l, c, fadeIn: _value);
      case _Grab.fadeOut:
        s.setAudioFades(l, c, fadeOut: _value);
      case _Grab.curveIn:
        if (_curve != null) s.setAudioFades(l, c, inCurve: _curve);
      case _Grab.curveOut:
        if (_curve != null) s.setAudioFades(l, c, outCurve: _curve);
      case _Grab.gain:
        if (_value != null) s.setAudioGain(l, c, _value!);
      case _Grab.none:
        break;
    }
    Haptics.drop();
    _reset();
  }

  void _cancel() => _reset();

  void _reset() {
    if (_grab != _Grab.none) widget.guides?.value = null;
    if (_grab == _Grab.move) {
      widget.drag?.free.removeListener(_freeChanged);
      widget.drag?.end();
    }
    _lifted = false;
    if (mounted) setState(() { _grab = _Grab.none; _delta = Offset.zero; _value = null; _curve = null; });
    _ignored = false;
  }

  final _clicks = ClickCounter();

  void _tap() {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl || (widget.selectMode?.call() ?? false)) {
      s.selectAudioClip(widget.layer, c, additive: true);
    } else {
      s.selectAudioClip(widget.layer, c);
    }
    Haptics.tap();
  }

  Widget _handle(_Grab g, {required Widget child, double? left, double? right, double? top, double? bottom,
      required double width, double? height, String? key, VoidCallback? onTap, VoidCallback? onDoubleTap,
      MouseCursor cursor = SystemMouseCursors.grab}) =>
      Positioned(left: left, right: right, top: top, bottom: bottom, width: width, height: height,
        child: MouseRegion(cursor: cursor, child: GestureDetector(
          key: key == null ? null : ValueKey('$key-${c.id}'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          // A long press on an edge picks the whole clip up too: it never trims.
          onLongPressStart: g == _Grab.trimStart || g == _Grab.trimEnd ? _lift : null,
          // Along one axis, so the handle wins its drag before the scroll views do (they take a drag on the same
          // slop; a pan would need twice as far).
          onHorizontalDragStart: _vertical(g) ? null : (d) => _begin(g, d.globalPosition),
          onHorizontalDragUpdate: _vertical(g) ? null : (d) => _update(d.globalPosition),
          onHorizontalDragEnd: _vertical(g) ? null : (_) => _end(),
          onHorizontalDragCancel: _vertical(g) ? null : _cancel,
          onVerticalDragStart: _vertical(g) ? (d) => _begin(g, d.globalPosition) : null,
          onVerticalDragUpdate: _vertical(g) ? (d) => _update(d.globalPosition) : null,
          onVerticalDragEnd: _vertical(g) ? (_) => _end() : null,
          onVerticalDragCancel: _vertical(g) ? _cancel : null,
          child: child)));

  static bool _vertical(_Grab g) => g == _Grab.gain || g == _Grab.curveIn || g == _Grab.curveOut;

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final start = _shownStart, length = _shownLength;
    final width = math.max(12.0, length * widget.stepW);
    final h = widget.height;
    final asset = _asset;
    final fileSeconds = asset?.seconds ?? 0;
    final k = _k;
    // Seconds of the file a pixel shows: while the notch stretches, the same part of the file fills the new width.
    final per = c.sourcePerStep(bpm, asset?.bpm) * k / widget.stepW * (_grab == _Grab.stretch ? _span / length : 1);
    var offset = c.offsetSeconds;
    if (_grab == _Grab.trimStart) offset = math.max(0, offset + (start - c.startSteps) * c.sourcePerStep(bpm, asset?.bpm));
    final fadeIn = _grab == _Grab.fadeIn ? _value! : c.fadeIn;
    final fadeOut = _grab == _Grab.fadeOut ? _value! : c.fadeOut;
    final gain = _grab == _Grab.gain ? _value! : c.gain;
    final inCurve = _grab == _Grab.curveIn ? _curve! : c.fadeInCurve;
    final outCurve = _grab == _Grab.curveOut ? _curve! : c.fadeOutCurve;
    final pxPerSec = widget.stepW * bpm / 15 / k;
    final fadeInPx = math.min(width, fadeIn * pxPerSec), fadeOutPx = math.min(width, fadeOut * pxPerSec);
    final top = h >= 34 ? 14.0 : 0.0;
    final wave = Color.lerp(color, Neon.ink, 0.35)!.withValues(alpha: 0.9);
    final dragShift = _grab == _Grab.move && widget.drag != null ? _delta.dy : 0.0;
    final name = s.audioClipName(c);
    final showHandles = widget.selected && !c.lock && width >= 40 && h >= 26;
    // The stretch notch (owner, 2026-11-14): on every clip that plays at its own speed, wide enough to hold it.
    final showNotch = c.fixed && !c.lock && width >= 40 && h >= 20;
    const notch = 16.0;
    final body = Container(
      key: ValueKey('audio-clip-box-${c.id}'),
      width: width,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: color.withValues(alpha: Glass.active ? (widget.selected ? .30 : .18) : (widget.selected ? .42 : .23)),
        boxShadow: widget.selected ? [BoxShadow(color: color.withValues(alpha: .35), blurRadius: 8)] : null,
        border: Border.all(color: widget.selected ? color : color.withValues(alpha: .7), width: widget.selected ? 1.6 : 1)),
      child: ClipRRect(borderRadius: BorderRadius.circular(5), child: Stack(children: [
        Positioned.fill(child: RepaintBoundary(child: CustomPaint(
          key: ValueKey('audio-wave-${c.id}'),
          painter: AudioClipPainter(
            peaks: () => asset == null ? null
                : WaveformCache.instance.peaks(s.audioIo, asset.path, fileSeconds, per.abs()),
            window: ClipWindow(offset: offset, perPixel: per, fileSeconds: fileSeconds, reverse: c.reverse,
                loop: c.loop, loopStart: c.loopStart, loopEnd: c.loopEnd),
            color: wave, gain: gain, fadeIn: fadeInPx, fadeOut: fadeOutPx, inCurve: inCurve, outCurve: outCurve,
            top: top, path: asset?.path)))),
        if (top > 0) Positioned(left: 12, right: 12, top: 1, height: 13, child: Row(children: [
          if (c.lock) Icon(Icons.lock, key: ValueKey('audio-locked-${c.id}'), size: 9, color: color),
          if (c.mute) Icon(Icons.volume_off, key: ValueKey('audio-muted-${c.id}'), size: 9, color: color),
          if (c.reverse) Icon(Icons.swap_horiz, size: 10, color: color),
          if (c.loop) Icon(Icons.loop, size: 9, color: color),
          if (!c.fixed) Icon(Icons.music_note, size: 9, color: color),
          Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800))),
        ])),
        if (_grab == _Grab.gain || (showHandles && gain != 1))
          Positioned(left: 0, right: 0, top: top + 2, child: Center(child: Text(gainDb(gain),
              key: ValueKey('audio-gain-label-${c.id}'),
              style: const TextStyle(color: Neon.ink, fontSize: 9, fontWeight: FontWeight.w700)))),
        if (_grab == _Grab.fadeIn || _grab == _Grab.fadeOut)
          Positioned(left: 0, right: 0, bottom: 2, child: Center(child: Text(
              '${((_grab == _Grab.fadeIn ? fadeIn : fadeOut) * 1000).round()} ms',
              style: const TextStyle(color: Neon.ink, fontSize: 9, fontWeight: FontWeight.w700)))),
        if (_grab == _Grab.stretch)
          Positioned(left: 0, right: 0, bottom: 2, child: Center(child: Text(_stretchLabel(),
              key: ValueKey('audio-stretch-readout-${c.id}'),
              style: const TextStyle(color: Neon.ink, fontSize: 9, fontWeight: FontWeight.w700)))),
        if (_curve != null)
          Positioned(left: 0, right: 0, bottom: 2, child: Center(child: Text(_curve!.label,
              style: const TextStyle(color: Neon.ink, fontSize: 9, fontWeight: FontWeight.w700)))),
      ])),
    );
    final mq = MediaQuery.of(context);
    return Opacity(opacity: c.mute ? 0.45 : 1, child: Transform.translate(
      offset: Offset((start - c.startSteps) * widget.stepW, dragShift),
      child: OverflowBox(alignment: Alignment.topLeft, minWidth: width, maxWidth: width, minHeight: h, maxHeight: h,
        child: Listener(onPointerDown: (e) => _downPointer = e.pointer, child: Stack(clipBehavior: Clip.none, children: [
          // The body: select, open, menu and move (from the first few pixels, before the scroll views take it).
          Positioned.fill(child: MediaQuery(
            data: mq.copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: kTouchSlop / 2)),
            // A tap selects at once; a quick second tap or a double-click opens its editor, the Clip tab (owner,
            // 2026-11-12). A hold opens the menu, as a right-click does; a hold that moves lifts the clip.
            child: Listener(onPointerDown: _clicks.down, onPointerUp: _clicks.up, child: GestureDetector(
              key: ValueKey('audio-clip-${c.id}'),
              onTap: () {
                if (_clicks.twice && widget.onOpen != null) {
                  widget.onOpen!();
                } else {
                  _tap();
                }
              },
              onLongPressStart: _lift,
              onSecondaryTapUp: (d) => showAudioClipMenu(context, s, widget.layer, c, d.globalPosition, onOpen: widget.onOpen),
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: (d) => _begin(_Grab.move, d.globalPosition),
              onPanUpdate: (d) { if (!_lifted) _update(d.globalPosition); },
              onPanEnd: (_) { if (!_lifted) _end(); },
              onPanCancel: () { if (_grab != _Grab.none && !_lifted) _cancel(); },
              child: body)))),
          if (c.takes.length > 1 && width >= 100 && h >= 26)
            Positioned(top: 2, right: 14, child: TakeChip.audio(state: s, layer: widget.layer, audio: c, color: color)),
          // The edges trim: the left keeps the audio in place, the right past the file's end loops it.
          if (!c.lock) ...[
            _handle(_Grab.trimStart, key: 'audio-start', left: 0, top: top, bottom: 0, width: 12,
                cursor: SystemMouseCursors.resizeColumn,
                child: Center(child: Container(width: 2, height: 22, color: color))),
            _handle(_Grab.trimEnd, key: 'audio-end', right: 0, top: top, bottom: 0, width: 12,
                cursor: SystemMouseCursors.resizeColumn,
                child: Center(child: Container(width: 2, height: 22, color: color))),
          ],
          // The selected clip's fade corners, curve dots and gain handle (REAPER's item handles).
          if (showHandles) ...[
            _handle(_Grab.fadeIn, key: 'audio-fade-in', left: (fadeInPx - 9).clamp(0.0, math.max(0.0, width - 18)), top: 0, width: 18, height: 18,
                child: _corner(color, left: true)),
            // Left of the notch, so the corner stays the notch's.
            _handle(_Grab.fadeOut, key: 'audio-fade-out',
                left: (width - fadeOutPx - 9).clamp(0.0, math.max(0.0, width - 18 - (showNotch ? notch : 0))), top: 0,
                width: 18, height: 18,
                child: _corner(color, left: false)),
            if (fadeInPx >= 14)
              _handle(_Grab.curveIn, key: 'audio-curve-in', left: fadeInPx / 2 - 9,
                  top: top + (1 - inCurve.mid) * (h - top) - 9, width: 18, height: 18,
                  onTap: () => _cycle(true), child: _dot(color)),
            if (fadeOutPx >= 14)
              _handle(_Grab.curveOut, key: 'audio-curve-out', left: width - fadeOutPx / 2 - 9,
                  top: top + (1 - outCurve.mid) * (h - top) - 9, width: 18, height: 18,
                  onTap: () => _cycle(false), child: _dot(color)),
            _handle(_Grab.gain, key: 'audio-gain', left: width / 2 - 16, top: top - 4, width: 32, height: 16,
                cursor: SystemMouseCursors.resizeRow,
                onDoubleTap: () => s.setAudioGain(widget.layer, c, 1),
                child: Center(child: Container(width: 22, height: 3, decoration: BoxDecoration(
                    color: Neon.ink.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(2))))),
          ],
          // The stretch notch, last so it wins its corner over the edge.
          if (showNotch)
            _handle(_Grab.stretch, key: 'audio-stretch', right: 0, top: 0, width: notch, height: math.min(notch, h / 2),
                cursor: SystemMouseCursors.resizeLeftRight,
                child: CustomPaint(painter: _NotchPainter(color, active: _grab == _Grab.stretch || c.stretchRatio != 1))),
        ])),
      ),
    ));
  }

  /// A tap on a curve dot steps to the next shape.
  void _cycle(bool fadingIn) {
    final now = fadingIn ? c.fadeInCurve : c.fadeOutCurve;
    final next = FadeCurve.values[(FadeCurve.values.indexOf(now) + 1) % FadeCurve.values.length];
    Haptics.tick();
    fadingIn ? s.setAudioFades(widget.layer, c, inCurve: next) : s.setAudioFades(widget.layer, c, outCurve: next);
  }

  Widget _corner(Color color, {required bool left}) => Align(
      alignment: left ? Alignment.topLeft : Alignment.topRight,
      child: Padding(padding: const EdgeInsets.all(4), child: Container(width: 9, height: 9, decoration: BoxDecoration(
          color: Colors.white, border: Border.all(color: color, width: 1.5), borderRadius: BorderRadius.circular(2)))));

  Widget _dot(Color color) => Center(child: Container(width: 8, height: 8, decoration: BoxDecoration(
      color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.2))));
}

/// The stretch notch: a small triangle in the clip's top-right corner, filled once the clip is stretched or while
/// it is dragged.
class _NotchPainter extends CustomPainter {
  _NotchPainter(this.color, {required this.active});
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width - 11, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, 11)
      ..close();
    canvas.drawPath(path, Paint()..color = active ? Colors.white : color);
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = active ? color : Colors.white.withValues(alpha: 0.8));
  }

  @override
  bool shouldRepaint(_NotchPainter old) => old.color != color || old.active != active;
}

/// An audio clip's menu: split, duplicate, reverse, loop, mute, lock, mode and stretch, takes, the inspector, delete.
Future<void> showAudioClipMenu(BuildContext context, AppState s, LayerDoc layer, AudioClipDoc clip, Offset at,
    {VoidCallback? onOpen}) async {
  final step = s.editStep.toDouble();
  final canSplit = !clip.lock && step > clip.startSteps && step < clip.endAt(s.project.bpm);
  final v = await showLongPressMenu<String>(context, at: at, title: s.audioClipName(clip), style: s.settings.longPressMenu,
      actions: [
        if (onOpen != null) const MenuAction('open', 'Clip settings…', Icons.tune),
        if (canSplit) const MenuAction('split', 'Split at the playhead', Icons.content_cut),
        const MenuAction('duplicate', 'Duplicate', Icons.copy),
        MenuAction('reverse', 'Reverse', Icons.swap_horiz, checked: clip.reverse),
        MenuAction('loop', 'Loop the file', Icons.loop, checked: clip.loop),
        MenuAction('mode', 'Follows tempo', Icons.music_note, checked: clip.followsTempo),
        MenuAction('mute', clip.mute ? 'Unmute' : 'Mute', Icons.volume_off, checked: clip.mute),
        MenuAction('lock', clip.lock ? 'Unlock' : 'Lock', Icons.lock, checked: clip.lock),
        if (clip.takes.length > 1) MenuAction('takes', 'Next take (${clip.takes.length})', Icons.layers_outlined),
        if (!clip.lock) const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true),
      ]);
  if (v == null) return;
  switch (v) {
    case 'open':
      s.selectAudioClip(layer, clip);
      onOpen?.call();
    case 'split':
      s.selectAudioClip(layer, clip);
      s.splitAudioClips(step);
    case 'duplicate':
      s.duplicateAudioClip(layer, clip);
    case 'reverse':
      s.reverseAudio(layer, clip);
    case 'loop':
      s.setAudioLoop(layer, clip, !clip.loop);
    case 'mode':
      // Off until the clip's tempo is known (its Clip tab says so and sets it).
      if (!s.setAudioFollowsTempo(layer, clip, !clip.followsTempo)) {
        Haptics.error();
        onOpen?.call();
        return;
      }
    case 'mute':
      s.toggleAudioMute(layer, clip);
    case 'lock':
      s.toggleAudioLock(layer, clip);
    case 'takes':
      s.stepAudioTake(layer, clip, 1);
    case 'delete':
      s.removeAudioClip(layer, clip);
  }
  Haptics.tap();
}

/// The colour an audio clip draws in: its own, else its track's.
Color audioClipColor(AppState s, LayerDoc layer, AudioClipDoc clip) =>
    clip.color == null ? trackColor(s, layer) : Neon.layer(clip.color!);
