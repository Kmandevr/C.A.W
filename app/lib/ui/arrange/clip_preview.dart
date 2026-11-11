// What a clip shows inside its body on the timeline (REAPER-style): a MIDI clip's notes as a mini piano roll, cached
// as a picture per pattern and zoom; a waveform painter waits for audio clips.
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

/// Below this many pixels per 16th step, or this body height, a clip shows its notes' density instead of the notes.
const kPreviewMinStepPx = 2.0, kPreviewMinHeight = 14.0;

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
      required bool density}) {
    final key = '$patternId|${p.lengthSteps}|${stepW.toStringAsFixed(3)}|${height.toStringAsFixed(1)}|${color.toARGB32()}|$density';
    final hit = _pictures.remove(key);
    if (hit != null && (identical(hit.$1, p.source) || hit.$1 == p.source)) {
      _pictures[key] = hit; // most recently used last
      return hit.$2;
    }
    hit?.$2.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    density ? _paintDensity(canvas, p, stepW, height, color) : _paintNotes(canvas, p, stepW, height, color);
    final picture = recorder.endRecording();
    recorded++;
    _pictures[key] = (p.source, picture);
    while (_pictures.length > capacity) {
      final first = _pictures.keys.first;
      _pictures.remove(first)!.$2.dispose();
    }
    return picture;
  }

  /// The notes as bars across the pattern's own pitch range; a bent note is a ribbon whose centre follows its bend
  /// (smoothed as the piano roll draws it).
  static void _paintNotes(Canvas canvas, ParsedPattern p, double stepW, double height, Color color) {
    final notes = p.doc?.notes ?? const <PatternNote>[];
    final rows = p.hi - p.lo + 1;
    final rowH = (height / rows).clamp(1.5, 7.0).toDouble();
    // The range sits in the middle when it doesn't fill the height.
    final top = (height - rowH * rows) / 2;
    double yOf(double pitch) => top + (p.hi - pitch) * rowH;
    final fill = Paint()..color = color;
    for (final n in notes) {
      final x0 = n.at.toDouble() * stepW, w = math.max(1.0, n.len.toDouble() * stepW - 0.5);
      if (n.expr.bend.isEmpty) {
        canvas.drawRect(Rect.fromLTWH(x0, yOf(n.pitch), w, math.max(1.0, rowH - 0.5)), fill);
        continue;
      }
      final top = <Offset>[], bottom = <Offset>[];
      final samples = math.max(2, (w / 2).ceil());
      for (var i = 0; i <= samples; i++) {
        final u = i / samples;
        final y = yOf(n.pitch + displayCurveAt(n.expr.bend, u, w));
        top.add(Offset(x0 + u * w, y));
        bottom.add(Offset(x0 + u * w, y + math.max(1.0, rowH - 0.5)));
      }
      canvas.drawPath(Path()..addPolygon([...top, ...bottom.reversed], true), fill);
    }
  }

  /// Zoomed out or thin: how many notes sound in each few pixels, as bars from the bottom.
  static void _paintDensity(Canvas canvas, ParsedPattern p, double stepW, double height, Color color) {
    final notes = p.doc?.notes ?? const <PatternNote>[];
    final width = p.lengthSteps * stepW;
    if (notes.isEmpty || width <= 0) return;
    const bucketPx = 3.0;
    final buckets = Int32List(math.max(1, (width / bucketPx).ceil()));
    for (final n in notes) {
      final a = (n.at.toDouble() * stepW / bucketPx).floor();
      final b = ((n.end.toDouble() * stepW) / bucketPx).ceil();
      for (var i = math.max(0, a); i < math.min(buckets.length, math.max(a + 1, b)); i++) {
        buckets[i]++;
      }
    }
    final most = buckets.fold<int>(1, math.max);
    final fill = Paint()..color = color.withValues(alpha: color.a * 0.8);
    for (var i = 0; i < buckets.length; i++) {
      if (buckets[i] == 0) continue;
      final h = math.max(1.5, height * buckets[i] / most);
      canvas.drawRect(Rect.fromLTWH(i * bucketPx, height - h, bucketPx - 0.5, h), fill);
    }
  }
}

/// A MIDI clip's notes, REAPER-style: one cycle of its pattern from the source offset, repeated while it loops
/// (a faint line where each repeat starts), clipped to the clip, in a lighter shade of the clip's colour.
class MidiClipPreview extends ClipPreview {
  MidiClipPreview({required this.patternId, required this.source, required this.runSource, required this.beatsPerBar,
      required this.sourceOffsetSteps, required this.loop, required this.stepW, required this.top, required this.color,
      ClipPictureCache? cache, this.loopSteps})
      : cache = cache ?? ClipPictureCache.instance;

  /// The preview of [clip] from its pattern in [project], or null when the pattern is gone.
  static MidiClipPreview? of(ProjectDoc project, ClipDoc clip, {required double stepW, required double top,
      required Color color, ClipPictureCache? cache}) {
    final m = project.module(clip.patternId);
    if (m == null) return null;
    return MidiClipPreview(patternId: m.id, source: m.source, runSource: m.runSource, beatsPerBar: project.beatsPerBar,
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, stepW: stepW, top: top, color: color, cache: cache,
        loopSteps: clip.loopSteps);
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

  /// Whether a clip [height] high shows the density view at this zoom.
  bool density(double height) => stepW < kPreviewMinStepPx || height - top < kPreviewMinHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final p = cache.parsed(patternId, source, runSource, beatsPerBar);
    if (p.doc == null || p.doc!.notes.isEmpty || size.width <= 0) return;
    final h = size.height - top - 2;
    if (h <= 2) return;
    final picture = cache.picture(patternId, p, stepW: stepW, height: h, color: color, density: density(size.height));
    final loopLength = (loopSteps ?? 0) > 0 ? loopSteps! : p.lengthSteps;
    final cycle = loopLength * stepW;
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
        if (!first && x > 0) canvas.drawLine(Offset(x, top), Offset(x, size.height - 2), edge);
      }
      if (!loop) break;
    }
    canvas.restore();
  }

  @override
  bool sameAs(ClipPreview other) =>
      other is MidiClipPreview && other.patternId == patternId && identical(other.source, source) &&
      other.beatsPerBar == beatsPerBar && other.sourceOffsetSteps == sourceOffsetSteps && other.loop == loop &&
      other.stepW == stepW && other.top == top && other.color == color && other.loopSteps == loopSteps;
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
