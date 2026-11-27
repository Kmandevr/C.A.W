// The pattern editor's painters: the roll and drum grid, notes with their pitch curves, the Curve tool's overlay and the song's playhead.
part of '../pattern_editor.dart';

/// What a touch grabs with the Curve tool: a note's pitch point [point], its line ([line]), or the note itself.
@immutable
class _CurveHit {
  const _CurveHit(this.id, {this.point, this.line = false, this.handle});
  final int id;
  final int? point;
  final bool line;
  final int? handle; // a segment's tension handle: the segment after point [handle]

  @override
  bool operator ==(Object o) =>
      o is _CurveHit && o.id == id && o.point == point && o.line == line && o.handle == handle;
  @override
  int get hashCode => Object.hash(id, point, line, handle);
}

/// The tension handles of curve [pts] on a note [nw] px wide: one on each segment that changes pitch and is at
/// least 16 px wide, at its middle in time and on the curve there (u 0..1 along the note, v in semitones).
List<({int seg, double u, double v})> curveHandles(List<NotePoint> pts, double nw) => [
      for (var i = 0; i + 1 < pts.length; i++)
        if ((pts[i + 1].v - pts[i].v).abs() > 1e-6 && (pts[i + 1].t - pts[i].t) * nw >= 16)
          (
            seg: i,
            u: (pts[i].t + pts[i + 1].t) / 2,
            v: NoteExpression.valueAt(pts, (pts[i].t + pts[i + 1].t) / 2),
          ),
    ];

/// The bend (k, -1..1) that puts a segment from [a] to [b] through [v] at its middle in time: the curve is
/// a + (b - a) x^(4^k), so k = log4(ln f / ln 0.5) for f = (v - a) / (b - a).
double tensionThrough(double a, double b, double v) {
  final f = ((v - a) / (b - a)).clamp(0.02, 0.98);
  final k = math.log(math.log(f) / math.log(0.5)) / math.log(4);
  return (k.clamp(-1.0, 1.0) * 100).roundToDouble() / 100;
}

/// The Curve tool's overlay: what the mouse or finger would grab ([hit]), and while a drag is under way note [id]'s
/// [points] as they will be committed, [active] the one that follows the finger; [drawing]: a new point being placed.
@immutable
class _CurveView {
  const _CurveView({this.hit, this.id, this.points, this.active, this.drawing = false, this.handle});
  final _CurveHit? hit;
  final int? id;
  final List<NotePoint>? points;
  final int? active;
  final int? handle; // the tension handle being dragged
  final bool drawing;
}

/// Whether [e] bends its note away from its row (a pitch curve or vibrato): the roll then draws it as a ribbon.
bool _isBent(NoteExpression e) => e.bend.isNotEmpty || e.vibDepth > 0;

/// Whether a note [nw] px wide, [lenSec] long, draws its vibrato as a wave: only while a cycle spans at least 8 px;
/// zoomed out it would alias into spikes (#170), so the ribbon follows the bend alone inside a faint band.
bool _vibWave(NoteExpression e, double nw, double lenSec) =>
    e.vibDepth > 0 && e.vibRate > 0 && lenSec > 0 && nw / (lenSec * e.vibRate) >= 8;

/// The pitch the roll draws [px] into a note [nw] px wide (clamped to the note, so a stretch in progress holds its
/// ends): the smoothed curve ([displayCurveAt]), plus the vibrato while it is drawn as a wave. In rows above the
/// note's own; the sound follows the stored curve.
double _drawnPitch(NoteExpression e, double px, double nw, double lenSec, bool wave) {
  final u = nw > 0 ? (px / nw).clamp(0.0, 1.0) : 0.0;
  final bend = displayCurveAt(e.bend, u, nw);
  return wave ? bend + e.pitchAt(u, u * lenSec) - NoteExpression.valueAt(e.bend, u) : bend;
}

/// A bent note's ribbon at [px] into it: its centre's height above the row's middle, its [slope] on screen (px down
/// per px across) and [half] its height straight up and down there. The ribbon keeps the note's thickness across its
/// slope, so a glide stays as solid as the note; [half] grows with the slope (up to 8 times, for a near-vertical
/// jump). The painter and the note tool's hit test both use this.
({double dy, double slope, double half}) _ribbonAt(
    NoteExpression e, double px, double nw, double rowH, double lenSec, bool wave) {
  final c = _drawnPitch(e, px, nw, lenSec, wave);
  final slope = -(_drawnPitch(e, px + 1, nw, lenSec, wave) - _drawnPitch(e, px - 1, nw, lenSec, wave)) * rowH / 2;
  return (dy: c * rowH, slope: slope, half: (rowH - 2) / 2 * math.min(8.0, math.sqrt(1 + slope * slope)));
}

/// A bent note's pitch line as the roll draws it, for a note at [x] (row top [y], [nw] wide) on a grid [w] wide, its
/// ends at [left] and [right] (a stretch in progress moves one): the ribbon's centre, and [band]: draw the vibrato as
/// a faint band (zoomed out). Sampled every 2 px where it is on screen plus at its points, so it draws cleanly at any
/// zoom.
({Path line, bool band}) _pitchPath(NoteExpression e,
    {required double x, required double y, required double nw, required double w, required double rowH,
    required double lenSec, double? left, double? right}) {
  final wave = _vibWave(e, nw, lenSec);
  final l = (left ?? x) - x, r = (right ?? x + nw) - x;
  final from = math.max(l, -x), to = math.min(r, w - x);
  final xs = <double>{for (var px = (from / 2).ceil() * 2.0; px < to; px += 2) px, from, to,
    for (final q in e.bend) if (q.t * nw > from && q.t * nw < to) q.t * nw}.toList()..sort();
  final line = Path(), mid = y + rowH / 2;
  for (var i = 0; i < xs.length; i++) {
    final py = mid - _drawnPitch(e, xs[i], nw, lenSec, wave) * rowH;
    i == 0 ? line.moveTo(x + xs[i], py) : line.lineTo(x + xs[i], py);
  }
  return (line: line, band: drawsVibratoAsBand(e, nw, lenSec));
}

/// Whether the roll draws [e]'s vibrato as a faint band round the ribbon (zoomed out, a note [nw] px wide and
/// [lenSec] long) instead of as a wave.
@visibleForTesting
bool drawsVibratoAsBand(NoteExpression e, double nw, double lenSec) => e.vibDepth > 0 && !_vibWave(e, nw, lenSec);

/// One note of the roll in [box] (its row at [x], [y], [nw] wide, its stretch already applied to [box]): layer
/// colour, brighter when louder. A bent note is itself bent (owner, 2026-11-10: "the actual MIDI note itself to be
/// the one that's bent"): a ribbon of its own height whose centre follows the smoothed pitch, a bright thread
/// through its middle, and its start row kept as a faint anchor. [points] 1 shows its pitch points dim, 2 bright, on
/// their true values. White outline when [selected].
void _paintNote(Canvas canvas, PatternNote n, NoteExpression e, Rect box,
    {required double x, required double y, required double nw, required double w, required double rowH,
    required Color color, required double secPerStep, required bool selected, int points = 0}) {
  final r = RRect.fromRectAndRadius(box, const Radius.circular(3));
  final fill = color.withValues(alpha: 0.35 + 0.65 * n.vel);
  if (!_isBent(e)) {
    canvas.drawRRect(r, Paint()..color = fill);
    if (selected) {
      canvas.drawRRect(r, Paint()
        ..color = Neon.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    return;
  }
  // The anchor: the row the note is written on, faint.
  canvas.drawRRect(r, Paint()..color = fill.withValues(alpha: 0.12));
  canvas.drawRRect(r, Paint()
    ..color = fill.withValues(alpha: 0.3)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8);
  final shape = _pitchPath(e,
      x: x, y: y, nw: nw, w: w, rowH: rowH, lenSec: n.len.toDouble() * secPerStep, left: box.left, right: box.right);
  if (shape.band) {
    canvas.drawPath(shape.line, Paint()
      ..color = fill.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = rowH - 2 + 2 * e.vibDepth * rowH);
  }
  // The ribbon: the line stroked as thick as the note, square to it at its ends, in the note's colour made opaque
  // over the grid so where a tight turn folds the stroke over itself it doesn't show darker. Selected, a white
  // stroke a little wider underneath outlines it.
  final ribbon = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = rowH - 2;
  if (selected) canvas.drawPath(shape.line, ribbon..color = Neon.text..strokeWidth = rowH + 1);
  canvas.drawPath(shape.line, ribbon
    ..color = Color.alphaBlend(fill, Neon.panel)
    ..strokeWidth = rowH - 2);
  if (rowH >= 6) {
    canvas.drawPath(shape.line, Paint()
      ..color = Color.lerp(color, Neon.text, 0.55)!.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.2);
  }
  if (points > 0) {
    final dot = Paint()..color = points > 1 ? Neon.yellow : Neon.yellow.withValues(alpha: 0.55);
    for (final p in e.bend) {
      canvas.drawCircle(Offset(x + p.t * nw, y + rowH / 2 - p.v * rowH), points > 1 ? 5 : 3.5, dot);
    }
  }
}

/// The Curve tool's overlay on the roll, repainted on its own as [view] changes (a drag repaints only this, once a
/// frame): the curve under the mouse or finger lit, and a curve being dragged with its start, the point that follows
/// the finger, a guide at that point's time and its pitch as a label (`+2.0 st`).
class _CurveOverlayPainter extends CustomPainter {
  _CurveOverlayPainter({
    required this.view,
    required this.doc,
    required this.sel,
    required this.pxPerStep,
    required this.rowH,
    required this.scrollX,
    required this.scrollY,
    required this.gridH,
    required this.color,
    required this.secPerStep,
  }) : super(repaint: view);
  final ValueListenable<_CurveView> view;
  final PatternDoc doc;
  final Set<int> sel;
  final double pxPerStep, rowH, scrollX, scrollY, gridH, secPerStep;
  final Color color;

  static const keyW = _keyW, rulerH = _rulerH;

  @override
  void paint(Canvas canvas, Size size) {
    RollPaintStats.live++;
    RollPaintStats.label = null;
    RollPaintStats.anchor = null;
    final v = view.value, w = size.width - keyW;
    canvas.save();
    canvas.translate(keyW, rulerH);
    canvas.clipRect(Rect.fromLTWH(0, 0, w, gridH));
    PatternNote? note(int? id) => id == null ? null : doc.byId(id);
    double nx(PatternNote n) => n.at.toDouble() * pxPerStep - scrollX;
    double nwOf(PatternNote n) => math.max(3.0, n.len.toDouble() * pxPerStep - 1);
    double ny(PatternNote n) => (127 - n.pitch.round()) * rowH - scrollY;
    final live = note(v.id), pts = v.points;
    if (live != null && pts != null) {
      final x = nx(live), y = ny(live), nw = nwOf(live), mid = y + rowH / 2;
      final e = live.expr.copyWith(bend: pts);
      _paintNote(canvas, live, e, Rect.fromLTWH(x, y + 1, nw, rowH - 2),
          x: x, y: y, nw: nw, w: w, rowH: rowH, color: color, secPerStep: secPerStep,
          selected: sel.contains(live.id), points: 2);
      if (pts.isNotEmpty) {
        // Where the curve starts: a ring round its first point.
        final a = Offset(x + pts.first.t * nw, mid - pts.first.v * rowH);
        RollPaintStats.anchor = a;
        canvas.drawCircle(a, 8, Paint()
          ..color = Neon.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
      final i = v.active;
      if (i != null && i < pts.length) {
        final q = pts[i], at = Offset(x + q.t * nw, mid - q.v * rowH);
        // A guide at the point's time, the point itself, and its pitch.
        canvas.drawLine(Offset(at.dx, 0), Offset(at.dx, gridH), Paint()
          ..color = Neon.yellow.withValues(alpha: 0.45)
          ..strokeWidth = 1);
        canvas.drawCircle(at, 7, Paint()..color = Neon.yellow);
        canvas.drawCircle(at, 7, Paint()
          ..color = Neon.bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
        final text = bendLabel(q.v);
        RollPaintStats.label = text;
        final label = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout();
        final top = at.dy - label.height - 14;
        final lp = Offset((at.dx - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)),
            top < 0 ? at.dy + 12 : top);
        canvas.drawRRect(RRect.fromRectAndRadius((lp - const Offset(4, 1)) & Size(label.width + 8, label.height + 2),
            const Radius.circular(4)), Paint()..color = Neon.bg.withValues(alpha: 0.85));
        label.paint(canvas, lp);
      }
    }
    // Tension handles on each selected note's bent segments: a diamond on the curve at the segment's middle, and a
    // faint chord between its ends so the bend reads against a straight line.
    for (final id in sel) {
      final n = note(id);
      if (n == null) continue;
      final bend = id == v.id && pts != null ? pts : n.expr.bend;
      if (bend.length < 2) continue;
      final x = nx(n), nw = nwOf(n), mid = ny(n) + rowH / 2;
      for (final h in curveHandles(bend, nw)) {
        final a = bend[h.seg], b = bend[h.seg + 1];
        final on = id == v.id && v.handle == h.seg;
        canvas.drawLine(Offset(x + a.t * nw, mid - a.v * rowH), Offset(x + b.t * nw, mid - b.v * rowH), Paint()
          ..color = Neon.blue.withValues(alpha: on ? 0.6 : 0.3)
          ..strokeWidth = 1);
        final c = Offset(x + h.u * nw, mid - h.v * rowH), r = on ? 7.0 : 5.0;
        final diamond = Path()
          ..moveTo(c.dx, c.dy - r)
          ..lineTo(c.dx + r, c.dy)
          ..lineTo(c.dx, c.dy + r)
          ..lineTo(c.dx - r, c.dy)
          ..close();
        canvas.drawPath(diamond, Paint()..color = on ? Neon.blue : Neon.blue.withValues(alpha: 0.8));
        canvas.drawPath(diamond, Paint()
          ..color = Neon.bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
        if (on) {
          final text = 'curve ${a.k >= 0 ? '+' : ''}${a.k.toStringAsFixed(2)}';
          RollPaintStats.label = text;
          final label = TextPainter(
            text: TextSpan(text: text, style: const TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w600)),
            textDirection: TextDirection.ltr,
          )..layout();
          final lp = Offset((c.dx - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)),
              c.dy - label.height - 14 < 0 ? c.dy + 12 : c.dy - label.height - 14);
          canvas.drawRRect(RRect.fromRectAndRadius((lp - const Offset(4, 1)) & Size(label.width + 8, label.height + 2),
              const Radius.circular(4)), Paint()..color = Neon.bg.withValues(alpha: 0.85));
          label.paint(canvas, lp);
        }
      }
    }
    // What the mouse or finger would grab: its point ringed, or its line lit.
    final hit = v.hit, hn = note(hit?.id);
    if (hit != null && hn != null && v.active == null) {
      final e = hit.id == v.id && pts != null ? hn.expr.copyWith(bend: pts) : hn.expr;
      final x = nx(hn), y = ny(hn), nw = nwOf(hn);
      if (hit.handle != null) {
        for (final h in curveHandles(e.bend, nw)) {
          if (h.seg != hit.handle) continue;
          canvas.drawCircle(Offset(x + h.u * nw, y + rowH / 2 - h.v * rowH), 9, Paint()
            ..color = Neon.blue
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
        }
      } else if (hit.point != null && hit.point! < e.bend.length) {
        final q = e.bend[hit.point!];
        canvas.drawCircle(Offset(x + q.t * nw, y + rowH / 2 - q.v * rowH), 9, Paint()
          ..color = Neon.yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
      } else if (hit.line) {
        final line = _pitchPath(e, x: x, y: y, nw: nw, w: w, rowH: rowH, lenSec: hn.len.toDouble() * secPerStep);
        canvas.drawPath(line.line, Paint()
          ..color = Neon.yellow.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = rowH + 4);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CurveOverlayPainter o) =>
      !identical(o.doc, doc) ||
      o.view != view ||
      o.sel != sel ||
      o.pxPerStep != pxPerStep ||
      o.rowH != rowH ||
      o.scrollX != scrollX ||
      o.scrollY != scrollY ||
      o.gridH != gridH ||
      o.color != color ||
      o.secPerStep != secPerStep;
}

/// A pitch point's value as the Curve tool labels it: `+2.0 st`, `-1.5 st`, `0.0 st`.
String bendLabel(double v) => '${v > 0 ? '+' : v < 0 ? '-' : ''}${v.abs().toStringAsFixed(1)} st';

class _RollPainter extends CustomPainter {
  _RollPainter({
    required this.doc,
    required this.references,
    required this.sel,
    required this.length,
    required this.beatsPerBar,
    this.bars,
    this.origin = 0,
    required this.pxPerStep,
    required this.rowH,
    required this.scrollX,
    required this.scrollY,
    required this.line,
    required this.key,
    required this.color,
    required this.cursorAt,
    required this.cursorPitch,
    required this.rect,
    required this.gridRows,
    required this.focused,
    required this.velH,
    required this.xH,
    required this.gridStrength,
    required this.keyLabels,
    required this.curves,
    required this.secPerStep,
    required this.curveMode,
    this.hide,
    this.lag = 0,
    this.lagIds = const {},
    this.lagEdge = 1,
    this.lengthOf,
    this.ghost,
    this.motion,
  }) : super(repaint: motion?.anim);
  final _RollMotion? motion; // an edit animation under way
  // A stretch in progress: the notes' edge (end 1, start -1) is drawn [lag] px past its snapped place.
  final double lag;
  final Set<int> lagIds;
  final int lagEdge;
  final int? lengthOf; // the note whose length shows as a number (a stretch or a draw in progress)
  final ({Steps at, double pitch, Steps len})? ghost; // where a tap would draw
  final Map<int, LaneCurve>? curves;
  final double secPerStep; // seconds per 16th at the project tempo, for drawing vibrato
  final bool curveMode; // the Curve tool: every bent note shows its pitch points (brighter when selected)
  final int? hide; // the note the curve overlay draws while its curve is dragged
  final double velH, xH, gridStrength;
  final KeyLabels keyLabels;
  final PatternDoc doc;
  final List<PatternDoc> references;
  final Set<int> sel;
  final int beatsPerBar;

  /// Where the shade starts, in roll steps: past the clip's real end (its repeats included) when the roll is opened
  /// for a clip, past its loop in Build, else past the pattern's length (#226).
  final double length;

  /// The song's bars (#207) and the song step the roll's step 0 sits on (its clip's start less its source offset):
  /// with signature changes the bar lines and numbers follow them, numbered from the clip's first bar.
  final BarMath? bars;
  final int origin;

  /// The bars the roll draws: the song's when its meter changes or isn't n/4, else null (every [beatsPerBar]·4).
  BarMath? get _songBars => bars == null || (bars!.constant && bars!.signatures.first.den == 4) ? null : bars;

  /// The roll steps where bars start between [t0] and [t1], with their numbers (1 is the clip's first bar).
  List<(double, int)> _barsIn(double t0, double t1, {int every = 1}) {
    final b = _songBars!;
    final first = b.barAt(math.max(0, origin) / 4);
    return [
      for (final bar in b.bars((t0 + origin) / 4, (t1 + origin) / 4, every: every, limit: 512))
        (bar.beat * 4 - origin, bar.bar - first + 1),
    ];
  }

  final double pxPerStep, rowH, scrollX, scrollY, cursorPitch;
  final Steps line, cursorAt;
  final ({int root, List<int> scale})? key;
  final Color color;
  final Rect? rect;
  final List<double>? gridRows;
  final bool focused;

  static const keyW = _keyW, rulerH = _rulerH;
  static const _names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  @override
  void paint(Canvas canvas, Size size) {
    RollPaintStats.roll++;
    final w = size.width - keyW, h = size.height - velH - xH - rulerH;
    final bg = Paint()..color = Neon.bg;
    canvas.drawRect(Offset.zero & size, bg);
    canvas.save();
    canvas.translate(keyW, rulerH);
    canvas.clipRect(Rect.fromLTWH(0, 0, w, h));
    // Rows: those in the project's key are lit (owner: highlight only, no lock).
    final first = (scrollY / rowH).floor(), last = math.min(127, ((scrollY + h) / rowH).ceil());
    for (var r = first; r <= last; r++) {
      final pitch = 127 - r;
      final inKey = key == null || key!.scale.contains((pitch - key!.root) % 12);
      final y = r * rowH - scrollY;
      canvas.drawRect(Rect.fromLTWH(0, y, w, rowH),
          Paint()..color = inKey ? Neon.panel : Neon.bg.withValues(alpha: 1));
      if (pitch % 12 == 0) canvas.drawLine(Offset(0, y + rowH), Offset(w, y + rowH), Paint()..color = Neon.line);
    }
    // Adaptive grid lines: finer lines appear as you zoom in, down to the resolution.
    final lineSteps = line.toDouble();
    final bar = beatsPerBar * 4.0;
    final t0 = scrollX / pxPerStep, t1 = (scrollX + w) / pxPerStep;
    final songBars = _songBars == null ? null : {for (final (at, _) in _barsIn(t0 - 1, t1 + 1)) (at * 1e6).round()};
    // The finest lines (between the next coarser ones) fade in from 10 px apart, where the level changes, to 18 px
    // (zoomFade), so a zoom never pops a level of lines; they keep a little strength so the cells a tap lands in
    // stay visible (#228).
    final fine = 0.3 + 0.7 * zoomFade(lineSteps * pxPerStep, 10 / 0.55);
    for (var t = (t0 / lineSteps).floor() * lineSteps; t <= t1; t += lineSteps) {
      final x = t * pxPerStep - scrollX;
      final isBar = songBars != null ? songBars.contains((t * 1e6).round()) : (t % bar).abs() < 1e-9;
      final isBeat = (t % 4).abs() < 1e-9;
      final coarse = ((t / (lineSteps * 2)).round() * lineSteps * 2 - t).abs() < 1e-9;
      final c = isBar ? Neon.dim : Neon.line, a = isBar || isBeat ? 1.0 : 0.45 * (coarse ? 1 : fine);
      canvas.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = c.withValues(alpha: (c.a * a * gridStrength).clamp(0.0, 1.0)));
    }
    // Past where the clip (or pattern) ends is shaded.
    final endX = length * pxPerStep - scrollX;
    if (endX < w) canvas.drawRect(Rect.fromLTWH(endX, 0, w - endX, h), Paint()..color = const Color(0x88000000));
    // Other selected clips are faint references; the active source remains the only editable owner.
    for (final reference in references) {
      for (final n in reference.notes) {
        final x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
        if (x > w || x + nw < 0) continue;
        final y = (127 - n.pitch.round()) * rowH - scrollY;
        if (y > h || y + rowH < 0) continue;
        final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y + 1, nw, rowH - 2), const Radius.circular(3));
        canvas.drawRRect(r, Paint()..color = Neon.blue.withValues(alpha: 0.13));
        canvas.drawRRect(r, Paint()..color = Neon.blue.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke..strokeWidth = 0.8);
      }
    }
    // Notes: layer colour, brighter when louder; white outline when selected; a dot when it has extras.
    final m = motion, mt = m?.t ?? 1;
    var animated = 0;
    for (final n in doc.notes) {
      var x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
      var y = (127 - n.pitch.round()) * rowH - scrollY;
      double? alpha;
      if (m != null && mt < 1) {
        final was = m.was[n.id];
        if (m.appear.contains(n.id)) {
          animated++;
          alpha = mt;
          if (!m.fade) nw = math.max(3.0, nw * mt); // pops in from its start
        } else if (was != null && !m.fade) {
          animated++;
          final x0 = was.at * pxPerStep - scrollX, y0 = (127 - was.pitch.round()) * rowH - scrollY;
          final w0 = math.max(3.0, was.len * pxPerStep - 1);
          x = x0 + (x - x0) * mt;
          y = y0 + (y - y0) * mt;
          nw = w0 + (nw - w0) * mt;
        }
      }
      if (x > w || x + nw < 0) continue;
      final e = n.expr;
      final bent = _isBent(e);
      // A bent note can sound far from its row: keep it on screen while any of its curve is.
      final reach = bent ? (e.bend.fold(0.0, (m, p) => math.max(m, p.v.abs())) + e.vibDepth + 2) * rowH : 0.0;
      if (y - reach > h || y + rowH + reach < 0 || n.id == hide) continue;
      var box = Rect.fromLTWH(x, y + 1, nw, rowH - 2);
      if (lag != 0 && lagIds.contains(n.id)) {
        // The snapped length as a faint ghost; the note itself follows the finger.
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)),
            Paint()
              ..color = Neon.text.withValues(alpha: 0.5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
        box = lagEdge > 0
            ? Rect.fromLTRB(box.left, box.top, math.max(box.left + 3, box.right + lag), box.bottom)
            : Rect.fromLTRB(math.min(box.right - 3, box.left + lag), box.top, box.right, box.bottom);
      }
      if (alpha != null) canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0)));
      _paintNote(canvas, n, e, box,
          x: x, y: y, nw: nw, w: w, rowH: rowH, color: color, secPerStep: secPerStep, selected: sel.contains(n.id),
          points: !curveMode || !bent ? 0 : (sel.contains(n.id) ? 2 : 1));
      if (alpha != null) canvas.restore();
      if (n.prob < 1 || n.ratchet > 1 || n.slide) {
        // On the ribbon where a bent note starts.
        final lift = bent ? _drawnPitch(e, 4, nw, n.len.toDouble() * secPerStep, false) * rowH : 0.0;
        canvas.drawCircle(Offset(x + 4, y + rowH / 2 - lift), 2, Paint()..color = Neon.bg);
      }
    }
    if (m != null && mt < 1) {
      // Deleted notes shrink to their middle and fade (only fade when reduced).
      final k = 1 - m.exit;
      for (final n in m.gone) {
        final x = n.at.toDouble() * pxPerStep - scrollX, nw = math.max(3.0, n.len.toDouble() * pxPerStep - 1);
        final y = (127 - n.pitch.round()) * rowH - scrollY;
        if (x > w || x + nw < 0 || y > h || y + rowH < 0) continue;
        animated++;
        final full = Rect.fromLTWH(x, y + 1, nw, rowH - 2);
        final box = m.fade ? full : Rect.fromCenter(center: full.center, width: full.width * k, height: full.height * k);
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)),
            Paint()..color = color.withValues(alpha: (0.35 + 0.65 * n.vel) * k));
      }
    }
    RollPaintStats.edits = animated;
    final g = ghost;
    if (g != null) {
      final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(g.at.toDouble() * pxPerStep - scrollX, (127 - g.pitch) * rowH - scrollY + 1,
              math.max(3.0, g.len.toDouble() * pxPerStep - 1), rowH - 2),
          const Radius.circular(3));
      canvas.drawRRect(r, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawRRect(r, Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    final lenNote = lengthOf == null ? null : doc.byId(lengthOf!);
    if (lenNote != null) {
      // The length while it is dragged, above the note's end.
      final label = TextPainter(
        text: TextSpan(
            text: noteLengthLabel(lenNote.len),
            style: TextStyle(color: Neon.text, fontSize: 11, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final end = lenNote.end.toDouble() * pxPerStep - scrollX + (lagIds.contains(lenNote.id) && lagEdge > 0 ? lag : 0);
      // Above the note's end, where its ribbon ends if it is bent.
      final endPx = math.max(3.0, lenNote.len.toDouble() * pxPerStep - 1);
      final lift = _isBent(lenNote.expr)
          ? _drawnPitch(lenNote.expr, endPx, endPx, lenNote.len.toDouble() * secPerStep, false) * rowH
          : 0.0;
      final top = (127 - lenNote.pitch.round()) * rowH - scrollY - lift - label.height - 4;
      final at = Offset((end - label.width / 2).clamp(0.0, math.max(0.0, w - label.width)), math.max(0.0, top));
      canvas.drawRRect(RRect.fromRectAndRadius((at - const Offset(4, 1)) & Size(label.width + 8, label.height + 2),
          const Radius.circular(4)), Paint()..color = Neon.bg.withValues(alpha: 0.85));
      label.paint(canvas, at);
    }
    // The keyboard cursor.
    if (focused) {
      final cx = cursorAt.toDouble() * pxPerStep - scrollX, cy = (127 - cursorPitch) * rowH - scrollY;
      canvas.drawRect(Rect.fromLTWH(cx, cy, math.max(4, line.toDouble() * pxPerStep), rowH),
          Paint()
            ..color = Neon.blue
            ..style = PaintingStyle.stroke);
    }
    if (rect != null) {
      canvas.drawRect(rect!, Paint()..color = Neon.blue.withValues(alpha: 0.15));
    }
    canvas.restore();
    // Piano keys and ruler.
    final ts = TextPainter(textDirection: TextDirection.ltr);
    for (var r = first; r <= last; r++) {
      final pitch = 127 - r, y = rulerH + r * rowH - scrollY;
      if (y < rulerH - rowH || y > rulerH + h) continue;
      final black = const [1, 3, 6, 8, 10].contains(pitch % 12);
      canvas.drawRect(Rect.fromLTWH(0, y, keyW - 2, rowH - 1), Paint()..color = black ? Neon.bg : Neon.panelHi);
      final label = switch (keyLabels) {
        KeyLabels.none => false,
        KeyLabels.octaves => pitch % 12 == 0,
        KeyLabels.all => !black && rowH >= 11,
      };
      if (label) {
        ts.text = TextSpan(
            text: '${_names[pitch % 12]}${pitch ~/ 12 - 1}',
            style: TextStyle(color: Neon.dim, fontSize: math.min(10, rowH - 4)));
        ts.layout();
        ts.paint(canvas, Offset(4, y + 2));
      }
    }
    canvas.drawRect(Rect.fromLTWH(keyW, 0, w, rulerH), Paint()..color = Neon.panel);
    // A label every bar, or every 4, 16, 64… bars zoomed far out, so they never crowd (owner, 2026-11-11).
    var every = 1;
    final narrowest = _songBars == null ? bar
        : _songBars!.signatures.fold<double>(double.infinity, (m, g) => math.min(m, g.barBeats * 4));
    while (every * narrowest * pxPerStep < 28 && every < 1 << 20) {
      every *= 4;
    }
    // The next finer labels fade in as they get room, as Arrange's ruler's do (zoomFade), so a zoom never pops them.
    final finer = every ~/ 4;
    final fade = finer >= 1 ? zoomFade(finer * narrowest * pxPerStep, 28) : 0.0;
    final labelEvery = fade > 0 ? finer : every;
    TextStyle labelStyle(bool major) =>
        TextStyle(color: Neon.dim.withValues(alpha: Neon.dim.a * (major ? 1 : fade)), fontSize: 11);
    if (_songBars != null) {
      // Bars from the song's signatures (#207), numbered from the clip's first bar.
      final majors = {for (final (at, _) in _barsIn(t0, t1, every: every)) at};
      for (final (at, n) in _barsIn(t0, t1, every: labelEvery)) {
        final x = keyW + at * pxPerStep - scrollX;
        if (x < keyW || n < 1) continue;
        ts.text = TextSpan(text: '$n', style: labelStyle(majors.contains(at)));
        ts.layout();
        ts.paint(canvas, Offset(x + 3, 3));
      }
    }
    for (var b = (t0 / bar / labelEvery).floor() * labelEvery; _songBars == null && b * bar <= t1; b += labelEvery) {
      final x = keyW + b * bar * pxPerStep - scrollX;
      if (x < keyW) continue;
      ts.text = TextSpan(text: '${b + 1}', style: labelStyle(b % every == 0));
      ts.layout();
      ts.paint(canvas, Offset(x + 3, 3));
    }
    // Lanes: velocity, then chance (with ratchet and slide marks).
    void lane(double top, double hgt, double Function(PatternNote) value, {bool marks = false}) {
      canvas.drawRect(Rect.fromLTWH(keyW, top, w, hgt), Paint()..color = Neon.panel);
      canvas.drawLine(Offset(keyW, top), Offset(size.width, top), Paint()..color = Neon.line);
      for (final n in doc.notes) {
        final x = keyW + n.at.toDouble() * pxPerStep - scrollX;
        if (x < keyW || x > size.width) continue;
        final bh = (hgt - 6) * value(n);
        final paint = Paint()..color = sel.contains(n.id) ? Neon.text : color;
        canvas.drawRect(Rect.fromLTWH(x, top + hgt - 3 - bh, 3, bh), paint);
        if (marks && n.ratchet > 1) {
          for (var i = 1; i < n.ratchet; i++) {
            canvas.drawRect(Rect.fromLTWH(x + 4 + i * 3, top + hgt - 6, 2, 3), paint);
          }
        }
        if (marks && n.slide) canvas.drawLine(Offset(x, top + 3), Offset(x + 10, top + 3), paint);
      }
    }

    if (velH > 0) lane(rulerH + h, velH, (n) => n.vel);
    if (xH > 0) lane(rulerH + h + velH, xH, (n) => n.prob, marks: true);
    // The Curve tool's curves, over their lanes: the line, sampled every few pixels, and its points.
    void curve(LaneCurve c, double top, double hgt) {
      if (c.isEmpty) return;
      double y(double v) => top + 3 + (1 - v) * (hgt - 6);
      final path = Path();
      for (var x = keyW; x <= size.width; x += 3) {
        final v = c.valueAt((x - keyW + scrollX) / pxPerStep);
        x == keyW ? path.moveTo(x, y(v)) : path.lineTo(x, y(v));
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(keyW, top, w, hgt));
      canvas.drawPath(path, Paint()
        ..color = Neon.yellow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      for (final q in c.points) {
        canvas.drawCircle(Offset(keyW + q.at * pxPerStep - scrollX, y(q.value)), 5, Paint()..color = Neon.yellow);
      }
      canvas.restore();
    }

    final cs = curves;
    if (cs != null) {
      if (velH > 0) curve(cs[1]!, rulerH + h, velH);
      if (xH > 0) curve(cs[2]!, rulerH + h + velH, xH);
    }
  }

  @override
  bool shouldRepaint(_RollPainter o) =>
      !identical(o.doc, doc) ||
      o.length != length ||
      o.bars != bars ||
      o.origin != origin ||
      o.references != references ||
      o.sel != sel ||
      o.pxPerStep != pxPerStep ||
      o.scrollX != scrollX ||
      o.scrollY != scrollY ||
      o.line != line ||
      o.cursorAt != cursorAt ||
      o.cursorPitch != cursorPitch ||
      o.rect != rect ||
      o.focused != focused ||
      o.velH != velH ||
      o.xH != xH ||
      o.rowH != rowH ||
      o.gridStrength != gridStrength ||
      o.keyLabels != keyLabels ||
      o.curves != curves ||
      o.secPerStep != secPerStep ||
      o.curveMode != curveMode ||
      o.hide != hide ||
      o.lag != lag ||
      o.lagIds != lagIds ||
      o.lagEdge != lagEdge ||
      o.lengthOf != lengthOf ||
      o.ghost != ghost ||
      o.motion != motion ||
      o.color != color;
}

/// An edit animation on the roll: [appear] pops in from its start, [was] holds where moved or resized notes were,
/// [gone] shrinks and fades; with [fade] (Reduced motion) only opacity changes.
class _RollMotion {
  _RollMotion(this.anim, {required this.appear, required this.was, required this.gone, required this.fade,
      required this.curve});
  final Animation<double> anim;
  final Set<int> appear;
  final Map<int, ({double at, double pitch, double len})> was;
  final List<PatternNote> gone;
  final bool fade;
  final Curve curve;

  double get t => curve.transform(anim.value.clamp(0.0, 1.0));
  double get exit => EditMotion.exitCurve.transform(anim.value.clamp(0.0, 1.0));
}

/// The song's playhead down the roll's ruler and grid: a line at [step] (the roll's time; null draws nothing).
class RollPlayheadPainter extends CustomPainter {
  const RollPlayheadPainter(
      {required this.step, required this.pxPerStep, required this.scrollX, required this.left, required this.bottom,
      this.stopped = false});
  final double? step;
  final double pxPerStep, scrollX, left, bottom;

  /// Stopped: the edit cursor, where play starts, dimmer and thinner (as Arrange's).
  final bool stopped;

  /// Where the line is, in the roll's pixels; null when there is none or it is off the grid.
  double? get x {
    final st = step;
    if (st == null) return null;
    final x = left + st * pxPerStep - scrollX;
    return x < left ? null : x;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final at = x;
    if (at == null || at > size.width) return;
    canvas.drawLine(Offset(at, 0), Offset(at, bottom),
        Paint()..color = stopped ? Neon.blue.withValues(alpha: 0.45) : Neon.blue..strokeWidth = stopped ? 1.2 : 1.6);
  }

  @override
  bool shouldRepaint(covariant RollPlayheadPainter old) => old.step != step || old.pxPerStep != pxPerStep ||
      old.scrollX != scrollX || old.bottom != bottom || old.stopped != stopped;
}
