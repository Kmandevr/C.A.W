// The sample editor at the top of an audio track's Clip tab (batch 1.0.4, owner 2026-11-14): the clip's whole file in
// a big waveform with its trim edges, fade handles (a dot bends the curve), loop-point handles and Slice to MIDI's
// cut lines, and the tool row (Normalise, Reverse, Gain, Slice to MIDI, Trim). Every edit is one undo step of the
// clip's fields; the file is never changed. A double tap of an audio clip or a tap of an audio file in Files opens it.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/project.dart';
import '../../model/sample_edit.dart';
import '../frame/sections.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'audio_waveform.dart';

/// The tool panel open under the tool row.
enum _Panel { none, gain, slice }

/// What a drag on the waveform holds.
enum _Grab { none, trimLeft, trimRight, fadeIn, fadeOut, curveIn, curveOut, loopStart, loopEnd }

class SampleEditor extends StatefulWidget {
  const SampleEditor({super.key, required this.state, required this.layer, required this.clip, required this.color,
      this.height});
  final AppState state;
  final LayerDoc layer;
  final AudioClipDoc clip;
  final Color color;

  /// The waveform's height (default: 150 on a phone, 200 wider).
  final double? height;

  @override
  State<SampleEditor> createState() => SampleEditorState();
}

@visibleForTesting
class SampleEditorState extends State<SampleEditor> {
  _Panel _panel = _Panel.none;
  String? _note;
  bool _busy = false;

  // Slice to MIDI's preview.
  double _sensitivity = 0.5;
  List<double>? _cuts;
  final _latest = Latest<List<double>?>();

  // The drag in progress, in seconds of the file (or of output for a fade); null curve while none bends.
  _Grab _grab = _Grab.none;
  double _value = 0;
  FadeCurve? _curve;
  double _dy = 0;

  AppState get s => widget.state;
  AudioClipDoc get c => widget.clip;
  AudioAssetDoc? get _asset => s.project.asset(c.assetId);
  double get _file => _asset?.seconds ?? 0;
  double get _bpm => s.project.bpm;
  SourceSpan get _span => clipSourceSpan(c, bpm: _bpm, assetBpm: _asset?.bpm, fileSeconds: _file);

  /// Seconds of the file one second of the clip plays.
  double get _filePerOut {
    final out = c.lengthAt(_bpm) * 15 / _bpm;
    return out <= 0 ? 1 : c.sourceSeconds(_bpm, _asset?.bpm) / out;
  }

  @override
  void didUpdateWidget(SampleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.id != widget.clip.id) {
      _panel = _Panel.none;
      _cuts = null;
      _note = null;
      _latest.cancel();
    }
  }

  void _say(String? note) {
    if (mounted) setState(() => _note = note);
  }

  // ---------- tools ----------

  Future<void> _normalise() async {
    Haptics.tap();
    setState(() => _busy = true);
    final g = await s.normaliseAudioClip(widget.layer, c);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(g == null ? 'Nothing to normalise: the clip is silent.' : 'Normalised: gain ${gainDb(g)}.');
  }

  void _reverse() {
    Haptics.tap();
    s.reverseAudio(widget.layer, c);
    _cuts = null;
    _say(c.reverse ? 'Reversed.' : 'Forwards again.');
  }

  Future<void> _trim() async {
    Haptics.tap();
    setState(() => _busy = true);
    final done = await s.trimAudioSilence(widget.layer, c);
    if (!mounted) return;
    setState(() => _busy = false);
    _say(done ? 'Trimmed to the sound.' : c.loop || c.reverse
        ? 'Trim works on a clip that doesn\'t loop or play reversed.'
        : 'Nothing to trim: no silence at the ends.');
  }

  void _toggle(_Panel p) {
    Haptics.tap();
    setState(() {
      _panel = _panel == p ? _Panel.none : p;
      _note = null;
    });
    if (_panel == _Panel.slice) _preview();
    if (_panel != _Panel.slice) {
      _latest.cancel();
      setState(() => _cuts = null);
    }
  }

  void _preview() {
    final clip = c;
    unawaited(_latest.run(() => s.sliceCuts(clip, _sensitivity), (cuts) {
      if (mounted && _panel == _Panel.slice) setState(() => _cuts = cuts ?? const []);
    }));
  }

  void _makeSlices() {
    final cuts = _cuts;
    if (cuts == null) return;
    final track = s.sliceToMidi(widget.layer, c, cuts);
    if (track == null) {
      Haptics.error();
      _say(s.sliceBlocked(c) ?? 'The file\'s sample rate isn\'t known yet; try again once it has loaded.');
      return;
    }
    Haptics.drop();
    setState(() {
      _panel = _Panel.none;
      _cuts = null;
      _note = 'Made "${track.name}": ${track.instrument?.id == 'org.caw.drums' ? 'drum pads' : 'the sampler'} and a '
          'MIDI clip of its slices.';
    });
  }

  // ---------- drags on the waveform ----------

  void _begin(_Grab g) {
    if (c.lock) {
      Haptics.error();
      return;
    }
    Haptics.grab();
    final span = _span;
    setState(() {
      _grab = g;
      _dy = 0;
      _curve = g == _Grab.curveIn ? c.fadeInCurve : g == _Grab.curveOut ? c.fadeOutCurve : null;
      _value = switch (g) {
        _Grab.trimLeft => span.from,
        _Grab.trimRight => span.to,
        _Grab.fadeIn => c.fadeIn,
        _Grab.fadeOut => c.fadeOut,
        _Grab.loopStart => c.loopStart,
        _Grab.loopEnd => c.loopEnd > 0 ? c.loopEnd : _file,
        _ => 0,
      };
    });
  }

  void _move(Offset delta, double secPerPx) {
    if (_grab == _Grab.none) return;
    setState(() {
      switch (_grab) {
        case _Grab.trimLeft || _Grab.trimRight || _Grab.loopStart || _Grab.loopEnd:
          _value = (_value + delta.dx * secPerPx).clamp(0.0, _file).toDouble();
        case _Grab.fadeIn:
          // The fade in sits at the clip's start: the left edge, or the right one when reversed.
          _value = math.max(0.0, _value + (c.reverse ? -delta.dx : delta.dx) * secPerPx / _filePerOut);
        case _Grab.fadeOut:
          _value = math.max(0.0, _value + (c.reverse ? delta.dx : -delta.dx) * secPerPx / _filePerOut);
        case _Grab.curveIn || _Grab.curveOut:
          _dy += delta.dy;
          final now = _grab == _Grab.curveIn ? c.fadeInCurve : c.fadeOutCurve;
          final i = (FadeCurve.values.indexOf(now) - (_dy / 14).round()).clamp(0, FadeCurve.values.length - 1);
          if (FadeCurve.values[i] != _curve) Haptics.tick();
          _curve = FadeCurve.values[i];
        case _Grab.none:
          break;
      }
    });
  }

  void _end() {
    final g = _grab, v = _value, l = widget.layer;
    if (g == _Grab.none) return;
    final span = _span, per = c.sourcePerStep(_bpm, _asset?.bpm);
    switch (g) {
      case _Grab.trimLeft || _Grab.trimRight:
        if (per > 0) {
          // The file's left edge is the clip's start (its end when reversed).
          final startSide = (g == _Grab.trimLeft) != c.reverse;
          if (startSide) {
            final moved = g == _Grab.trimLeft ? v - span.from : span.to - v;
            s.trimAudioClipStart(l, c, c.startSteps + moved / per);
          } else {
            final grown = g == _Grab.trimRight ? v - span.to : span.from - v;
            s.resizeAudioClipTo(l, c, c.lengthAt(_bpm) + grown / per);
          }
        }
      case _Grab.fadeIn:
        s.setAudioFades(l, c, fadeIn: v);
      case _Grab.fadeOut:
        s.setAudioFades(l, c, fadeOut: v);
      case _Grab.curveIn:
        if (_curve != null) s.setAudioFades(l, c, inCurve: _curve);
      case _Grab.curveOut:
        if (_curve != null) s.setAudioFades(l, c, outCurve: _curve);
      case _Grab.loopStart:
        s.setAudioLoopPoints(l, c, v, c.loopEnd > 0 ? c.loopEnd : _file);
      case _Grab.loopEnd:
        s.setAudioLoopPoints(l, c, c.loopStart, v);
      case _Grab.none:
        break;
    }
    Haptics.drop();
    setState(() {
      _grab = _Grab.none;
      _curve = null;
    });
  }

  void _cycle(bool fadingIn) {
    final now = fadingIn ? c.fadeInCurve : c.fadeOutCurve;
    final next = FadeCurve.values[(FadeCurve.values.indexOf(now) + 1) % FadeCurve.values.length];
    Haptics.tick();
    fadingIn ? s.setAudioFades(widget.layer, c, inCurve: next) : s.setAudioFades(widget.layer, c, outCurve: next);
  }

  // ---------- building ----------

  @override
  Widget build(BuildContext context) {
    final asset = _asset;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final h = widget.height ?? (wide ? 200.0 : 150.0);
    final panelMotion = EditMotion.of(context, EditMotionKind.panels) ?? Duration.zero;
    return Column(key: ValueKey('sample-editor-${c.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: h, child: asset == null || _file <= 0
          ? const Center(child: Text('The file isn\'t loaded yet.', style: TextStyle(color: Neon.dim, fontSize: 12)))
          : LayoutBuilder(builder: (context, box) => _wave(context, box.maxWidth, h))),
      const SizedBox(height: 6),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        _tool('normalise', Icons.equalizer_rounded, 'Normalise', _busy || c.lock ? null : _normalise,
            tip: 'Gain up to a 0 dB peak (the file stays as it is)'),
        _tool('reverse', Icons.swap_horiz, 'Reverse', c.lock ? null : _reverse, on: c.reverse),
        _tool('gain', Icons.volume_up_outlined, 'Gain ${gainDb(c.gain)}', c.lock ? null : () => _toggle(_Panel.gain),
            on: _panel == _Panel.gain),
        _tool('slice', Icons.content_cut, 'Slice to MIDI', s.sliceBlocked(c) != null ? null : () => _toggle(_Panel.slice),
            on: _panel == _Panel.slice, tip: s.sliceBlocked(c) ?? 'Cut at the hits and play them from a new track'),
        _tool('trim', Icons.vertical_align_center, 'Trim', _busy || c.lock ? null : _trim,
            tip: 'Trim the silence off both ends'),
      ])),
      // The tool's panel grows in and out (a size animation only when motion is on: at zero it would relayout itself).
      _grow(panelMotion, AnimatedSwitcher(duration: panelMotion, switchInCurve: EditMotion.curve,
          switchOutCurve: EditMotion.exitCurve,
          child: switch (_panel) {
            _Panel.none => const SizedBox(key: ValueKey('sample-panel-none'), width: double.infinity),
            _Panel.gain => _gainPanel(),
            _Panel.slice => _slicePanel(),
          })),
      AnimatedSwitcher(duration: panelMotion, child: _note == null
          ? const SizedBox(key: ValueKey('sample-note-none'))
          : Padding(key: ValueKey('sample-note-$_note'), padding: const EdgeInsets.only(top: 4),
              child: Text(_note!, key: const ValueKey('sample-note'), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Neon.dim, fontSize: 11)))),
    ]);
  }

  Widget _grow(Duration d, Widget child) => d == Duration.zero || EditMotion.fadeOnly(context)
      ? child
      : AnimatedSize(duration: d, curve: EditMotion.curve, alignment: Alignment.topCenter, child: child);

  Widget _tool(String key, IconData icon, String label, VoidCallback? onTap, {bool on = false, String? tip}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(message: tip ?? label, child: FilterChip(
        key: ValueKey('sample-tool-$key'),
        avatar: Icon(icon, size: 16, color: onTap == null ? Neon.dim : widget.color),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: on,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        onSelected: onTap == null ? null : (_) => onTap())));

  Widget _gainPanel() => Padding(key: const ValueKey('sample-panel-gain'), padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        const SizedBox(width: 48, child: Text('Gain', style: TextStyle(fontSize: 12))),
        Expanded(child: Slider(key: const ValueKey('sample-gain-slider'), min: -60, max: 12,
            value: gainToDb(c.gain).clamp(-60.0, 12.0),
            onChanged: (db) => s.editLayer(widget.layer, (_) => c.gain = dbToGain(db)),
            onChangeEnd: (_) => s.endUndoStep())),
        SizedBox(width: 64, child: Text(gainDb(c.gain), textAlign: TextAlign.right,
            style: Neon.code(size: 11, color: Neon.text))),
      ]));

  Widget _slicePanel() {
    final cuts = _cuts;
    final n = cuts == null ? null : cuts.length + 1;
    final where = n == null ? '' : sliceTargetFor(n) == SliceTarget.drums ? 'drum pads' : 'the sampler';
    return Padding(key: const ValueKey('sample-panel-slice'), padding: const EdgeInsets.only(top: 4), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const SizedBox(width: 72, child: Text('Sensitivity', style: TextStyle(fontSize: 12))),
          Expanded(child: Slider(key: const ValueKey('sample-slice-sensitivity'), value: _sensitivity,
              onChanged: (v) {
                setState(() => _sensitivity = v);
                _preview();
              })),
        ]),
        Row(children: [
          Expanded(child: Text(n == null ? 'Finding the hits…' : '$n slices on $where',
              key: const ValueKey('sample-slice-count'), style: const TextStyle(color: Neon.dim, fontSize: 11))),
          TextButton(key: const ValueKey('sample-slice-cancel'), onPressed: () => _toggle(_Panel.slice),
              child: const Text('Cancel')),
          FilledButton.tonal(key: const ValueKey('sample-slice-make'), onPressed: n == null ? null : _makeSlices,
              child: const Text('Make MIDI track')),
        ]),
      ]));
  }

  Widget _wave(BuildContext context, double width, double h) {
    final asset = _asset!;
    final file = _file;
    final secPerPx = file / math.max(1, width);
    double x(double sec) => sec / secPerPx;
    final span = _span;
    var from = span.from, to = span.to;
    if (_grab == _Grab.trimLeft) from = math.min(_value, to - secPerPx);
    if (_grab == _Grab.trimRight) to = math.max(_value, from + secPerPx);
    final fadeIn = (_grab == _Grab.fadeIn ? _value : c.fadeIn) * _filePerOut;
    final fadeOut = (_grab == _Grab.fadeOut ? _value : c.fadeOut) * _filePerOut;
    final inCurve = _grab == _Grab.curveIn ? _curve! : c.fadeInCurve;
    final outCurve = _grab == _Grab.curveOut ? _curve! : c.fadeOutCurve;
    final loopA = _grab == _Grab.loopStart ? _value : c.loopStart;
    final loopB = _grab == _Grab.loopEnd ? _value : (c.loopEnd > 0 ? c.loopEnd : file);
    // Where each fade is on the file: the fade in at the clip's start side.
    final inAt = c.reverse ? to : from, outAt = c.reverse ? from : to;
    final inPx = math.min(x(to) - x(from), x(fadeIn)), outPx = math.min(x(to) - x(from), x(fadeOut));
    final inEdge = c.reverse ? x(inAt) - inPx : x(inAt) + inPx;
    final outEdge = c.reverse ? x(outAt) + outPx : x(outAt) - outPx;
    const top = 16.0;
    Widget handle(_Grab g, {required double left, required double topAt, required double w, required double hh,
        required Widget child, VoidCallback? onTap, bool vertical = false, MouseCursor cursor = SystemMouseCursors.resizeColumn}) =>
        // Kept inside the waveform, so a handle at the file's very end can still be grabbed.
        Positioned(left: left.clamp(0.0, math.max(0.0, width - w)).toDouble(), top: topAt, width: w, height: hh,
            child: MouseRegion(cursor: cursor, child: GestureDetector(
          key: ValueKey('sample-${g.name}-${c.id}'),
          behavior: HitTestBehavior.opaque,
          // From where the finger went down, so the handle follows it with no lag.
          dragStartBehavior: DragStartBehavior.down,
          onTap: onTap,
          onHorizontalDragStart: vertical ? null : (_) => _begin(g),
          onHorizontalDragUpdate: vertical ? null : (d) => _move(d.delta, secPerPx),
          onHorizontalDragEnd: vertical ? null : (_) => _end(),
          onHorizontalDragCancel: vertical ? null : _end,
          onVerticalDragStart: vertical ? (_) => _begin(g) : null,
          onVerticalDragUpdate: vertical ? (d) => _move(d.delta, secPerPx) : null,
          onVerticalDragEnd: vertical ? (_) => _end() : null,
          onVerticalDragCancel: vertical ? _end : null,
          child: child)));
    final color = widget.color;
    final readout = switch (_grab) {
      _Grab.trimLeft || _Grab.trimRight => '${(to - from).toStringAsFixed(2)} s of the file',
      _Grab.fadeIn || _Grab.fadeOut => '${(_value * 1000).round()} ms',
      _Grab.curveIn || _Grab.curveOut => _curve?.label,
      _Grab.loopStart || _Grab.loopEnd => 'Loop ${loopA.toStringAsFixed(2)}–${loopB.toStringAsFixed(2)} s',
      _ => null,
    };
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(6)))),
      Positioned(left: 0, right: 0, top: top, bottom: 14, child: RepaintBoundary(child: CustomPaint(
        key: const ValueKey('sample-editor-wave'),
        painter: AudioClipPainter(
          peaks: () => WaveformCache.instance.peaks(s.audioIo, asset.path, file, secPerPx),
          window: ClipWindow(offset: 0, perPixel: secPerPx, fileSeconds: file),
          color: Color.lerp(color, Neon.ink, 0.35)!.withValues(alpha: 0.9), gain: c.gain, fadeIn: 0, fadeOut: 0,
          inCurve: FadeCurve.linear, outCurve: FadeCurve.linear, path: asset.path)))),
      Positioned.fill(child: IgnorePointer(child: CustomPaint(key: const ValueKey('sample-editor-overlay'),
        painter: _Overlay(from: x(from), to: x(to), top: top, bottom: 14, color: color,
          inPx: inPx, outPx: outPx, inCurve: inCurve, outCurve: outCurve, reverse: c.reverse,
          loop: c.loop || _grab == _Grab.loopStart || _grab == _Grab.loopEnd, loopA: x(loopA), loopB: x(loopB),
          cuts: [for (final t in _cuts ?? const <double>[]) x(t)])))),
      // The trim edges: the clip's part of the file.
      handle(_Grab.trimLeft, left: x(from) - 12, topAt: top, w: 24, hh: h - top - 14,
          child: Center(child: Container(width: 3, height: 28, color: color))),
      handle(_Grab.trimRight, left: x(to) - 12, topAt: top, w: 24, hh: h - top - 14,
          child: Center(child: Container(width: 3, height: 28, color: color))),
      // The fades: a square at the top on each fade's edge, a dot in its middle bends the curve.
      handle(_Grab.fadeIn, left: inEdge - 10, topAt: 0, w: 20, hh: 18, child: _square(color)),
      handle(_Grab.fadeOut, left: outEdge - 10, topAt: 0, w: 20, hh: 18, child: _square(color)),
      if (inPx >= 14)
        handle(_Grab.curveIn, left: (x(inAt) + inEdge) / 2 - 10, topAt: top + (1 - inCurve.mid) * (h - top - 14) - 10,
            w: 20, hh: 20, vertical: true, onTap: () => _cycle(true), cursor: SystemMouseCursors.resizeRow,
            child: _dot(color)),
      if (outPx >= 14)
        handle(_Grab.curveOut, left: (x(outAt) + outEdge) / 2 - 10,
            topAt: top + (1 - outCurve.mid) * (h - top - 14) - 10,
            w: 20, hh: 20, vertical: true, onTap: () => _cycle(false), cursor: SystemMouseCursors.resizeRow,
            child: _dot(color)),
      // The loop points: flags along the bottom (dim while the loop is off; dragging one turns it on).
      handle(_Grab.loopStart, left: x(loopA) - 10, topAt: h - 16, w: 20, hh: 16,
          child: _flag(color, on: c.loop, start: true)),
      handle(_Grab.loopEnd, left: x(loopB) - 10, topAt: h - 16, w: 20, hh: 16,
          child: _flag(color, on: c.loop, start: false)),
      if (readout != null)
        Positioned(left: 0, right: 0, top: 1, child: IgnorePointer(child: Center(child: Text(readout,
            key: const ValueKey('sample-readout'),
            style: const TextStyle(color: Neon.ink, fontSize: 10, fontWeight: FontWeight.w700))))),
    ]);
  }

  Widget _square(Color color) => Center(child: Container(width: 10, height: 10, decoration: BoxDecoration(
      color: Colors.white, border: Border.all(color: color, width: 1.5), borderRadius: BorderRadius.circular(2))));

  Widget _dot(Color color) => Center(child: Container(width: 9, height: 9, decoration: BoxDecoration(
      color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.2))));

  Widget _flag(Color color, {required bool on, required bool start}) => Align(
      alignment: start ? Alignment.bottomLeft : Alignment.bottomRight,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(
          start ? Icons.first_page_rounded : Icons.last_page_rounded, size: 16,
          color: on ? Neon.blue : Neon.dim.withValues(alpha: 0.6))));
}

/// The editor's marks over the waveform: outside the clip dimmed, the fades' gain lines, the loop's span and
/// Slice to MIDI's cuts.
class _Overlay extends CustomPainter {
  _Overlay({required this.from, required this.to, required this.top, required this.bottom, required this.color,
      required this.inPx, required this.outPx, required this.inCurve, required this.outCurve, required this.reverse,
      required this.loop, required this.loopA, required this.loopB, required this.cuts});
  final double from, to, top, bottom, inPx, outPx, loopA, loopB;
  final Color color;
  final FadeCurve inCurve, outCurve;
  final bool reverse, loop;
  final List<double> cuts;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final h0 = top, h1 = size.height - bottom;
    canvas.drawRect(Rect.fromLTRB(0, h0, from.clamp(0, size.width), h1), dim);
    canvas.drawRect(Rect.fromLTRB(to.clamp(0, size.width), h0, size.width, h1), dim);
    canvas.drawRect(Rect.fromLTRB(from, h0, to, h1), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color);
    if (loop && loopB > loopA) {
      canvas.drawRect(Rect.fromLTRB(loopA, h1, loopB, h1 + 3), Paint()..color = Neon.blue.withValues(alpha: 0.8));
    }
    // A fade's gain as a line from silence to full, in its curve.
    void fade(double start, double px, FadeCurve curve, bool rising, bool leftward) {
      if (px < 1) return;
      final path = Path();
      for (var i = 0; i <= 24; i++) {
        final u = i / 24;
        final g = rising ? curve.at(u) : curve.at(1 - u);
        final xx = leftward ? start - u * px : start + u * px;
        final y = h1 - g * (h1 - h0);
        i == 0 ? path.moveTo(xx, y) : path.lineTo(xx, y);
      }
      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.85));
    }
    // Drawn from the clip's start: forwards the fade in rises from the left edge; reversed, from the right.
    fade(reverse ? to : from, inPx, inCurve, true, reverse);
    // The fade out runs to the clip's end, so it is drawn back from there as a fade in.
    fade(reverse ? from : to, outPx, outCurve, true, !reverse);
    final cut = Paint()
      ..color = Neon.pink
      ..strokeWidth = 1.5;
    for (final x in cuts) {
      canvas.drawLine(Offset(x, h0), Offset(x, h1), cut);
    }
  }

  @override
  bool shouldRepaint(_Overlay old) => old.from != from || old.to != to || old.inPx != inPx || old.outPx != outPx ||
      old.inCurve != inCurve || old.outCurve != outCurve || old.reverse != reverse || old.loop != loop ||
      old.loopA != loopA || old.loopB != loopB || old.color != color || old.cuts.length != cuts.length ||
      !_same(old.cuts, cuts);

  static bool _same(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A tap on an audio file in Files (owner, 2026-11-14): Arrange focuses the track of a clip that plays it (the
/// selected one first) with the sample editor open; a file on no track goes on a new audio track first (one undo
/// step), so there is a clip to edit.
void openSampleEditor(BuildContext context, AppState s, AudioAssetDoc asset) {
  var placed = sampleEditorClipFor(s, asset.id);
  if (placed == null) {
    final track = s.dropAudioOnNewTrack(asset.id, atStep: 0, name: asset.name);
    if (track == null) return;
    placed = (layer: track, clip: track.audioClips.last);
  }
  s.selectAudioClip(placed.layer, placed.clip);
  SectionController.maybeOf(context)?.focusClip(placed.layer.id);
}
