// What a clip shows inside its body on the timeline (REAPER-style): a MIDI clip's notes as thin lines at their pitch,
// a mini piano roll at every zoom (a drum clip: a tick per hit), cached as a picture per pattern and zoom.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../model/pattern_doc.dart';
import '../../model/project.dart';
import '../note_expression.dart' show displayCurveAt;

/// Draws a clip's content into its body, `size` being the clip's whole visible box (time runs left to right from
/// the clip's start). One implementation per kind of clip: [MidiClipPreview] now, [WaveformClipPreview] once audio
/// clips exist.
abstract class ClipPreview {
  const ClipPreview();

  void paint(Canvas canvas, Size size);

  /// Whether [other] would paint the same thing (the painter skips a repaint then).
  bool sameAs(ClipPreview other);
}

/// Paints a [ClipPreview]; it repaints only when the preview changes.
class ClipPreviewPainter extends CustomPainter {
  const ClipPreviewPainter(this.preview);
  final ClipPreview preview;

  @override
  void paint(Canvas canvas, Size size) => preview.paint(canvas, size);

  @override
  bool shouldRepaint(covariant ClipPreviewPainter old) => !preview.sameAs(old.preview);
}

/// How thick a note line is drawn, in logical pixels (owner, 2026-11-12, "Thin note lines": never blocks).
const kNoteLineMin = 1.0, kNoteLineMax = 2.0;

/// The least gap between two pitch lines: closer pitches share a line rather than merge into a block.
const kNoteLineGap = 1.0;

/// A drum hit's tick: its height (a short upright mark at the hit's start).
const kDrumTickHeight = 4.0;

/// Where a pattern's note lines sit in a body [height] high over pitches [lo]..[hi]: the line's [thickness] and the
/// distance between neighbouring [rows] (at least the thickness plus [kNoteLineGap]; pitches closer than that are
/// gathered onto one line), and the [top] of the highest. Pure, for tests.
({double thickness, double row, double top, int perLine}) noteLineLayout(double lo, double hi, double height) {
  final pitches = (hi - lo).ceil() + 1;
  final fit = height / pitches;
  final thickness = (fit * 0.6).clamp(kNoteLineMin, kNoteLineMax).toDouble();
  final step = thickness + kNoteLineGap;
  // Pitches per line: 1 while each has room, else as many as it takes to keep the gap.
  final per = fit >= step ? 1 : (step / math.max(1e-6, fit)).ceil();
  final lines = (pitches / per).ceil();
  final row = lines <= 1 ? 0.0 : math.min(math.max(fit * per, step), (height - thickness) / (lines - 1));
  final span = row * (lines - 1) + thickness;
  return (thickness: thickness, row: row, top: math.max(0.0, (height - span) / 2), perLine: per);
}

/// A pattern parsed once per source text: its notes, loop length and pitch range (bends included).
class ParsedPattern {
  ParsedPattern(this.source, this.beatsPerBar, this.doc, this.lengthSteps, this.lo, this.hi);
  final String source;
  final int beatsPerBar;
  final PatternDoc? doc;
  final int lengthSteps;
  final double lo, hi;
}

/// The pictures of the patterns on screen, one per pattern, source text, zoom, height, colour and view. Clips that
/// share a pattern share its picture; a pattern edit or a zoom records a new one, nothing else does. Bounded (least
/// recently used go first).
class ClipPictureCache {
  ClipPictureCache({this.capacity = 192});
  static final instance = ClipPictureCache();

  final int capacity;
  final LinkedHashMap<String, (String, ui.Picture)> _pictures = LinkedHashMap();
  final Map<String, ParsedPattern> _parsed = {};

  /// How many pictures were recorded (tests read it to see a picture reused).
  int recorded = 0;

  int get length => _pictures.length;

  void clear() {
    for (final p in _pictures.values) {
      p.$2.dispose();
    }
    _pictures.clear();
    _parsed.clear();
  }

  ParsedPattern parsed(String patternId, String source, String runSource, int beatsPerBar) {
    final hit = _parsed[patternId];
    if (hit != null && hit.beatsPerBar == beatsPerBar && (identical(hit.source, source) || hit.source == source)) {
      return hit;
    }
    final doc = PatternDoc.parse(source).doc ?? PatternDoc.parse(runSource).doc;
    var lo = double.infinity, hi = -double.infinity;
    for (final n in doc?.notes ?? const <PatternNote>[]) {
      var a = n.pitch, b = n.pitch;
      for (final p in n.expr.bend) {
        a = math.min(a, n.pitch + p.v);
        b = math.max(b, n.pitch + p.v);
      }
      lo = math.min(lo, a - n.expr.vibDepth);
      hi = math.max(hi, b + n.expr.vibDepth);
    }
    if (lo > hi) (lo, hi) = (60, 60);
    final p = ParsedPattern(source, beatsPerBar, doc, math.max(1, doc?.lengthSteps(beatsPerBar) ?? 16), lo, hi);
    if (_parsed.length > capacity) _parsed.clear();
    return _parsed[patternId] = p;
  }

  /// The picture of one cycle of the pattern, [stepW] px per step and [height] high: recorded once per key.
  ui.Picture picture(String patternId, ParsedPattern p, {required double stepW, required double height, required Color color,
      bool drums = false}) {
    final key = '$patternId|${p.lengthSteps}|${stepW.toStringAsFixed(3)}|${height.toStringAsFixed(1)}|${color.toARGB32()}|$drums';
    final hit = _pictures.remove(key);
    if (hit != null && (identical(hit.$1, p.source) || hit.$1 == p.source)) {
      _pictures[key] = hit; // most recently used last
      return hit.$2;
    }
    hit?.$2.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintNotes(canvas, p, stepW, height, color, drums: drums);
    final picture = recorder.endRecording();
    recorded++;
    _pictures[key] = (p.source, picture);
    while (_pictures.length > capacity) {
      final first = _pictures.keys.first;
      _pictures.remove(first)!.$2.dispose();
    }
    return picture;
  }

  /// The notes as thin lines at their pitch across the pattern's own range, fitted to [height] ([noteLineLayout]):
  /// one path, one draw. A bent note's line follows its bend (smoothed as the piano roll draws it); a drum clip draws
  /// a short tick at each hit instead. Nothing depends on the zoom but the x positions, so zooming changes it
  /// smoothly; a note narrower than a pixel stays a pixel wide.
  @visibleForTesting
  static void paintNotes(Canvas canvas, ParsedPattern p, double stepW, double height, Color color, {bool drums = false}) {
    final notes = p.doc?.notes ?? const <PatternNote>[];
    if (notes.isEmpty) return;
    final l = noteLineLayout(p.lo, p.hi, height);
    final t = l.thickness;
    double yOf(double pitch) => l.top + ((p.hi - pitch) / l.perLine).floorToDouble() * l.row;
    double yBent(double pitch) => l.top + (p.hi - pitch) / l.perLine * l.row;
    final path = Path();
    for (final n in notes) {
      final x0 = n.at.toDouble() * stepW;
      if (drums) {
        final y = (yOf(n.pitch) + t / 2 - kDrumTickHeight / 2).clamp(0.0, math.max(0.0, height - kDrumTickHeight));
        path.addRect(Rect.fromLTWH(x0, y.toDouble(), math.min(kNoteLineMax, math.max(kNoteLineMin, stepW * 0.5)),
            math.min(kDrumTickHeight, height)));
        continue;
      }
      final w = math.max(1.0, n.len.toDouble() * stepW - (stepW >= 4 ? 0.5 : 0));
      if (n.expr.bend.isEmpty) {
        path.addRect(Rect.fromLTWH(x0, yOf(n.pitch), w, t));
        continue;
      }
      final top = <Offset>[], bottom = <Offset>[];
      final samples = math.max(2, math.min(48, (w / 2).ceil()));
      for (var i = 0; i <= samples; i++) {
        final u = i / samples;
        final y = yBent(n.pitch + displayCurveAt(n.expr.bend, u, w));
        top.add(Offset(x0 + u * w, y));
        bottom.add(Offset(x0 + u * w, y + t));
      }
      path.addPolygon([...top, ...bottom.reversed], true);
    }
    canvas.drawPath(path, Paint()..color = color);
  }
}

/// A MIDI clip's notes, REAPER-style: one cycle of its pattern from the source offset, repeated while it loops
/// (a faint line where each repeat starts), clipped to the clip, in a lighter shade of the clip's colour.
class MidiClipPreview extends ClipPreview {
  MidiClipPreview({required this.patternId, required this.source, required this.runSource, required this.beatsPerBar,
      required this.sourceOffsetSteps, required this.loop, required this.stepW, required this.top, required this.color,
      ClipPictureCache? cache, this.loopSteps, this.drums = false})
      : cache = cache ?? ClipPictureCache.instance;

  /// The preview of [clip] from its pattern in [project], or null when the pattern is gone. [trim]: the clip's start
  /// moved by this many steps while its left edge is dragged, so the notes stay where they are on the timeline.
  static MidiClipPreview? of(ProjectDoc project, ClipDoc clip, {required double stepW, required double top,
      required Color color, ClipPictureCache? cache, int trim = 0, bool drums = false}) {
    final m = project.module(clip.patternId);
    if (m == null) return null;
    return MidiClipPreview(patternId: m.id, source: m.source, runSource: m.runSource, beatsPerBar: project.beatsPerBar,
        sourceOffsetSteps: clip.sourceOffsetSteps + trim, loop: clip.loop, stepW: stepW, top: top, color: color, cache: cache,
        loopSteps: clip.loopSteps, drums: drums);
  }

  final String patternId, source, runSource;
  final int beatsPerBar, sourceOffsetSteps;
  final bool loop;
  final double stepW;

  /// The clip's own loop point (null: its pattern's length): each repeat starts there, cut to it.
  final int? loopSteps;

  /// Where the notes start below the clip's top (its name sits above them when there is room).
  final double top;
  final Color color;
  final ClipPictureCache cache;

  /// A drum or percussion clip (its track plays the drums): a tick per hit instead of note lines.
  final bool drums;

  @override
  void paint(Canvas canvas, Size size) {
    final p = cache.parsed(patternId, source, runSource, beatsPerBar);
    if (p.doc == null || p.doc!.notes.isEmpty || size.width <= 0) return;
    final h = size.height - top - 2;
    if (h <= 2) return;
    final picture = cache.picture(patternId, p, stepW: stepW, height: h, color: color, drums: drums);
    final loopLength = (loopSteps ?? 0) > 0 ? loopSteps! : p.lengthSteps;
    final cycle = loopLength * stepW;
    // A loop narrower than a pixel or so shows nothing a line could: its repeats aren't drawn one by one.
    if (loop && cycle < 1.5 && size.width / cycle > 64) return;
    final cut = loopLength < p.lengthSteps; // notes past the loop point never play
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    var x = -(loop ? sourceOffsetSteps % loopLength : sourceOffsetSteps) * stepW;
    final edge = Paint()..color = color.withValues(alpha: color.a * 0.35)..strokeWidth = 1;
    for (var first = true; x < size.width; x += cycle, first = false) {
      if (x + cycle > 0) {
        canvas.save();
        canvas.translate(x, top);
        if (cut) canvas.clipRect(Rect.fromLTWH(0, -top, cycle, size.height));
        canvas.drawPicture(picture);
        canvas.restore();
        if (!first && x > 0 && cycle >= 8) canvas.drawLine(Offset(x, top), Offset(x, size.height - 2), edge);
      }
      if (!loop) break;
    }
    canvas.restore();
  }

  @override
  bool sameAs(ClipPreview other) =>
      other is MidiClipPreview && other.patternId == patternId && identical(other.source, source) &&
      other.beatsPerBar == beatsPerBar && other.sourceOffsetSteps == sourceOffsetSteps && other.loop == loop &&
      other.stepW == stepW && other.top == top && other.color == color && other.loopSteps == loopSteps &&
      other.drums == drums;
}

/// An audio clip's waveform from peak data: [peaks] holds a (min, max) pair per bucket, -1..1, each bucket
/// [stepsPerBucket] 16th steps long, from the source's start.
///
/// TODO(audio clips, Stage 3): C.A.W has no audio clips yet. When they exist, the engine (or a file reader off the
/// UI isolate) computes these peaks once per source and zoom band, and the arranger picks this preview for an audio
/// clip the way it picks [MidiClipPreview] for a MIDI one.
class WaveformClipPreview extends ClipPreview {
  const WaveformClipPreview({required this.peaks, required this.stepsPerBucket, required this.stepW,
      required this.color, this.sourceOffsetSteps = 0, this.top = 0});
  final Float32List peaks;
  final double stepsPerBucket, stepW, sourceOffsetSteps, top;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final buckets = peaks.length ~/ 2;
    if (buckets == 0 || stepsPerBucket <= 0 || stepW <= 0) return;
    final h = size.height - top, mid = top + h / 2;
    final path = Path();
    final upper = <Offset>[], lower = <Offset>[];
    // One column per pixel: the widest peak among the buckets under it.
    for (var x = 0.0; x <= size.width; x += 1) {
      final from = ((x / stepW + sourceOffsetSteps) / stepsPerBucket).floor();
      final to = math.max(from + 1, (((x + 1) / stepW + sourceOffsetSteps) / stepsPerBucket).ceil());
      if (from >= buckets) break;
      var lo = 0.0, hi = 0.0;
      for (var b = math.max(0, from); b < math.min(buckets, to); b++) {
        lo = math.min(lo, peaks[2 * b]);
        hi = math.max(hi, peaks[2 * b + 1]);
      }
      upper.add(Offset(x, mid - hi * h / 2));
      lower.add(Offset(x, mid - lo * h / 2));
    }
    if (upper.isEmpty) return;
    path.addPolygon([...upper, ...lower.reversed], true);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool sameAs(ClipPreview other) =>
      other is WaveformClipPreview && identical(other.peaks, peaks) && other.stepsPerBucket == stepsPerBucket &&
      other.stepW == stepW && other.color == color && other.sourceOffsetSteps == sourceOffsetSteps && other.top == top;
}
