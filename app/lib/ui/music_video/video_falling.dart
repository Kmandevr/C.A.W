// The falling-notes view (owner, 2026-11-12): a piano keyboard along the bottom, notes falling onto it as long as
// they last, keys lighting in the track's colour as they play, a small burst at each note's start, bends included.
part of 'video_painter.dart';

/// The keyboard's lowest and highest key for [shot]: all 88 (A0..C8) or the range the shown tracks' notes use,
/// white keys at both ends and at least two octaves.
(int, int) videoKeyboardRange(DirectedShot shot) {
  if (shot.panel?.fullKeyboard ?? false) return (21, 108);
  var lo = (shot.pitchCenter - shot.pitchSpan / 2).floor() - 1, hi = (shot.pitchCenter + shot.pitchSpan / 2).ceil() + 1;
  if (hi - lo < 24) {
    final mid = (lo + hi) ~/ 2;
    lo = mid - 12;
    hi = mid + 12;
  }
  lo = lo.clamp(0, 127);
  hi = hi.clamp(lo, 127);
  while (lo > 0 && _isBlack(lo)) {
    lo--;
  }
  while (hi < 127 && _isBlack(hi)) {
    hi++;
  }
  return (lo, hi);
}

/// Where the keys of [lo]..[hi] sit across [width]: white keys share it evenly, a black key straddles the line
/// between its neighbours.
class VideoKeyboard {
  VideoKeyboard(this.lo, this.hi, this.width) : _below = Int32List(math.max(0, hi - lo) + 2) {
    // How many white keys lie below each key, once, so a span is a lookup.
    var n = 0;
    for (var p = lo; p <= hi; p++) {
      _below[p - lo] = n;
      if (!_isBlack(p)) n++;
    }
    _below[_below.length - 1] = n;
    whites = math.max(1, n);
    whiteWidth = width / whites;
  }
  final int lo, hi;
  final double width;
  final Int32List _below;
  late final int whites;
  late final double whiteWidth;

  int _whitesBelow(int p) => _below[(p - lo).clamp(0, _below.length - 1)];

  /// Key [p]'s left and right edges.
  (double, double) span(int p) {
    if (!_isBlack(p)) {
      final i = _whitesBelow(p);
      return (i * whiteWidth, (i + 1) * whiteWidth);
    }
    final c = _whitesBelow(p) * whiteWidth;
    return (c - whiteWidth * 0.32, c + whiteWidth * 0.32);
  }

  /// The x of a pitch's centre; a fraction (a bend) lies between its keys' centres.
  double centerX(double pitch) {
    final p = pitch.clamp(lo.toDouble(), hi.toDouble());
    final a = p.floor(), b = math.min(hi, a + 1);
    double mid(int k) {
      final (l, r) = span(k);
      return (l + r) / 2;
    }

    return a == b ? mid(a) : mid(a) + (mid(b) - mid(a)) * (p - a);
  }
}

/// A fixed hash 0..1 of two whole numbers (the bursts' sparks are the same in the preview and the render).
double _hash01(int a, int b) {
  var h = (a * 374761393 + b * 668265263) & 0xffffffff;
  h = ((h ^ (h >>> 13)) * 1274126177) & 0xffffffff;
  return (h & 0xffff) / 65535.0;
}

void _falling(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot, ShotCamera cam) {
  final s = f.scene;
  final u = _unit(size);
  final (lo, hi) = videoKeyboardRange(shot);
  final keys = VideoKeyboard(lo, hi, size.width);
  final kbH = math.min(size.height * 0.2, math.max(keys.whiteWidth * 4.5, size.height * 0.1));
  final kbTop = size.height - kbH;
  // How far ahead the fall shows: the panel's bars (the fall speed), eased by the camera's zoom.
  final ahead = math.max(1.0, shot.visibleSteps / cam.zoom);
  double y(double st) => kbTop - (st - f.step) / ahead * kbTop;
  final hidden = shot.panel?.hiddenTracks ?? const <String>{};
  bool shown(int t) => hidden.isEmpty || t < 0 || t >= s.tracks.length || !hidden.contains(s.tracks[t].id);

  // The fall: bar and beat lines, the C keys' columns.
  final fall = Rect.fromLTRB(0, 0, size.width, kbTop);
  if (_lk.grid) {
    final spb = s.stepsPerBar;
    for (var st = (f.step / 4).ceil() * 4.0; st <= f.step + ahead; st += 4) {
      final bar = st % spb == 0;
      if (!bar && ahead > spb * 4) continue;
      canvas.drawLine(Offset(0, y(st)), Offset(size.width, y(st)), Paint()
        ..color = Neon.line.withValues(alpha: bar ? 0.6 : 0.22)
        ..strokeWidth = math.max(1, u * (bar ? 0.8 : 0.5)));
    }
    for (var p = lo; p <= hi; p++) {
      if (p % 12 != 0) continue;
      final (l, _) = keys.span(p);
      canvas.drawLine(Offset(l, 0), Offset(l, kbTop), Paint()
        ..color = Neon.line.withValues(alpha: 0.3)
        ..strokeWidth = math.max(1, u * 0.5));
    }
  }

  // The notes.
  final lit = <int, Color>{};
  canvas.save();
  canvas.clipRect(fall);
  for (final i in s.notesSounding(f.step, f.step + ahead + 1e-9)) {
    final n = s.notes[i];
    if (!shown(n.track) || n.pitch < lo - 0.5 || n.pitch > hi + 0.5) continue;
    final color = _track(s, n.track);
    final on = n.start <= f.step;
    final key = n.pitch.round();
    final (l, r) = keys.span(key);
    final w = (r - l) * (_isBlack(key) ? 0.9 : 0.78);
    final cx = keys.centerX(n.pitch);
    final top = y(n.end), bottom = math.min(kbTop, y(n.start));
    final fill = on ? Color.lerp(color, Colors.white, 0.45)! : color.withValues(alpha: 0.55 + 0.4 * n.vel);
    if (on) lit[key] = color;
    if (n.bends) {
      _bentNote(canvas, n, s.bpm, (t) => Offset(cx, y(n.start + (n.end - n.start) * t)),
          (b) => Offset(keys.centerX(n.pitch + b) - cx, 0), w, fill, glow: on ? _glow(color, 6 * u) : null);
      continue;
    }
    final rect = Rect.fromLTRB(cx - w / 2, top, cx + w / 2, math.max(top + 2 * u, bottom));
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(math.min(w / 2, 3.5 * u)));
    if (on) canvas.drawRRect(rr.inflate(2 * u), _glow(color, 6 * u));
    _noteBox(canvas, rect, fill, u, (paint) => canvas.drawRRect(rr, paint));
  }
  canvas.restore();

  // The keyboard: white keys, then black keys over them; a playing key lights in its note's colour.
  canvas.drawRect(Rect.fromLTRB(0, kbTop, size.width, size.height), Paint()..color = Neon.bg);
  for (var p = lo; p <= hi; p++) {
    if (_isBlack(p)) continue;
    final (l, r) = keys.span(p);
    final key = Rect.fromLTRB(l + 0.4 * u, kbTop + u, r - 0.4 * u, size.height - u);
    final c = lit[p];
    final rr = RRect.fromRectAndCorners(key, bottomLeft: Radius.circular(2.5 * u), bottomRight: Radius.circular(2.5 * u));
    canvas.drawRRect(rr, Paint()..color = c == null ? Neon.text.withValues(alpha: 0.88) : Color.lerp(c, Colors.white, 0.25)!);
    if (c != null) canvas.drawRRect(rr, _glow(c, 5 * u, alpha: 0.5));
  }
  for (var p = lo; p <= hi; p++) {
    if (!_isBlack(p)) continue;
    final (l, r) = keys.span(p);
    final key = Rect.fromLTRB(l, kbTop + u, r, kbTop + kbH * 0.62);
    final c = lit[p];
    canvas.drawRRect(RRect.fromRectAndCorners(key, bottomLeft: Radius.circular(2 * u), bottomRight: Radius.circular(2 * u)),
        Paint()..color = c ?? Color.lerp(Neon.bg, Colors.black, 0.4)!);
  }
  // The strike line, glowing over each lit key.
  canvas.drawLine(Offset(0, kbTop), Offset(size.width, kbTop), Paint()
    ..color = Neon.line
    ..strokeWidth = math.max(1, 1.2 * u));
  for (final e in lit.entries) {
    final (l, r) = keys.span(e.key);
    canvas.drawRect(Rect.fromLTRB(l, kbTop - 3 * u, r, kbTop + u), _glow(e.value, 6 * u));
    canvas.drawRect(Rect.fromLTRB(l, kbTop - 1.2 * u, r, kbTop + 0.6 * u), Paint()..color = Color.lerp(e.value, Colors.white, 0.5)!);
  }

  // Bursts: a ring and a few sparks where each note strikes, over half a beat.
  const life = 2.0;
  for (var i = s.firstNoteFrom(f.step - life); i < s.notes.length && s.notes[i].start <= f.step; i++) {
    final n = s.notes[i];
    if (!shown(n.track) || n.pitch < lo - 0.5 || n.pitch > hi + 0.5) continue;
    final age = ((f.step - n.start) / life).clamp(0.0, 1.0);
    final color = _track(s, n.track);
    final c = Offset(keys.centerX(n.pitch), kbTop);
    final a = (1 - age) * n.vel.clamp(0.3, 1.0) * _lk.glow.clamp(0.0, 1.0);
    if (a <= 0.01) continue;
    canvas.drawCircle(c, (3 + 9 * age) * u, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, 1.4 * u * (1 - age))
      ..color = color.withValues(alpha: 0.7 * a));
    for (var k = 0; k < 6; k++) {
      final ang = -math.pi * (0.12 + 0.76 * _hash01(i, k));
      final d = (5 + (10 + 8 * _hash01(k, i)) * age) * u;
      canvas.drawCircle(c + Offset(math.cos(ang), math.sin(ang)) * d, math.max(0.5, 1.6 * u * (1 - age)),
          Paint()..color = Color.lerp(color, Colors.white, 0.5)!.withValues(alpha: a));
    }
  }
}
