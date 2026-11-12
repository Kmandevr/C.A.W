// Draws one music-video frame at any size from the scene, the plan, the song step and the meters: the arrangement
// flythrough, mixer, piano-roll, device and falling-notes views, split layouts, looks, effects, transitions and the
// title card, text overlays, images and keyframed camera moves, in the theme. The preview and the render both draw
// through [paintVideoFrame].
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../model/music_video.dart';
import '../../model/music_video_director.dart';
import '../../model/music_video_edit.dart';
import '../../model/music_video_meters.dart';
import '../../model/music_video_overlay.dart';
import '../../model/music_video_scene.dart';
import '../theme.dart';

part 'video_falling.dart';
part 'video_effects.dart';
part 'video_overlays.dart';

/// Everything one frame depends on (no wall clock: the same input draws the same frame).
class VideoFrameInput {
  const VideoFrameInput({required this.scene, required this.plan, required this.step, required this.seconds,
      this.levels = VideoLevels.silent, this.titleCard = false, this.title = '', this.artist = '',
      this.texts = const [], this.images = const [], this.bitmaps = const {}, this.rangeStart = 0,
      this.rangeEnd = double.infinity});
  final VideoScene scene;
  final ShotPlan plan;

  /// The song position (sixteenth steps) and the seconds since the video's start.
  final double step, seconds;
  final VideoLevels levels;
  final bool titleCard;
  final String title, artist;

  /// The whole video's text overlays and image layers (each shot's own are on its [DirectedShot]).
  final List<VideoText> texts;
  final List<VideoImageLayer> images;

  /// The decoded images by asset id (an image not here yet draws nothing).
  final Map<String, ui.Image> bitmaps;

  /// The video's range (song steps): a whole-video overlay without a span shows over all of it.
  final double rangeStart, rangeEnd;

  static VideoFrameInput forOptions({required VideoScene scene, required ShotPlan plan, required double step,
          required double seconds, required MusicVideoOptions options, VideoLevels levels = VideoLevels.silent,
          MusicVideoDoc? doc, Map<String, ui.Image> bitmaps = const {}, double rangeStart = 0,
          double rangeEnd = double.infinity}) =>
      VideoFrameInput(scene: scene, plan: plan, step: step, seconds: seconds, levels: levels,
          titleCard: options.titleCard, title: options.title.trim().isEmpty ? scene.name : options.title.trim(),
          artist: options.artist.trim(), texts: doc?.texts ?? const [], images: doc?.images ?? const [],
          bitmaps: bitmaps, rangeStart: rangeStart, rangeEnd: rangeEnd);
}

/// The frame as a widget painter (the preview), drawing exactly what [paintVideoFrame] draws for the render.
class VideoFramePainter extends CustomPainter {
  VideoFramePainter(this.input, {super.repaint});
  final VideoFrameInput Function() input;

  @override
  void paint(Canvas canvas, Size size) => paintVideoFrame(canvas, size, input());

  @override
  bool shouldRepaint(VideoFramePainter oldDelegate) => true;
}

double _ease(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Paints the frame [f] into [size].
void paintVideoFrame(Canvas canvas, Size size, VideoFrameInput f) {
  final rect = Offset.zero & size;
  canvas.save();
  canvas.clipRect(rect);
  canvas.drawRect(rect, Paint()..color = Neon.bg);
  final plan = f.plan;
  final i = plan.indexAt(f.step);
  final shot = plan.shots[i];
  final into = shot.transitionSteps <= 0 ? 1.0 : (f.step - shot.start) / shot.transitionSteps;
  if (i > 0 && into < 1 && shot.transition != VideoTransition.cut) {
    _paintTransition(canvas, size, f, plan.shots[i - 1], shot, into);
  } else {
    _paintShot(canvas, size, f, shot);
  }
  _paintImages(canvas, size, f, shot, VideoImagePlacement.overlay);
  _paintHud(canvas, size, f);
  if (f.titleCard) _paintTitle(canvas, size, f);
  _paintTexts(canvas, size, f, shot);
  canvas.restore();
}

void _paintShot(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot) {
  final bg = _backgroundImage(f, shot);
  final camera = shot.camera;
  if (bg != null || camera != null) {
    final saved = _bg;
    _bg = bg;
    canvas.save();
    if (camera != null) _frameCamera(canvas, size, camera, shot, f.step);
    _paintShotBody(canvas, size, f, shot);
    canvas.restore();
    _bg = saved;
    return;
  }
  _paintShotBody(canvas, size, f, shot);
}

void _paintShotBody(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot) {
  if (!shot.edited) {
    _paintView(canvas, size, f, shot, shot);
    return;
  }
  final panels = shot.panelShots.length;
  final whole = [for (final e in shot.effects) if (e.panelIn(panels) == null) e];
  if (whole.isEmpty) {
    _paintPanels(canvas, size, f, shot);
    return;
  }
  // The shot's effect stack works on its picture: its panels drawn once, then each effect in turn.
  _withEffects(canvas, size, f, whole, (c) => _paintPanels(c, size, f, shot));
}

/// Draws what [paint] draws into [size] through [effects] in order (each redraws the picture so far once).
void _withEffects(Canvas canvas, Size size, VideoFrameInput f, List<VideoEffect> effects, void Function(Canvas) paint) {
  if (effects.isEmpty) {
    paint(canvas);
    return;
  }
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder, Offset.zero & size));
  var picture = recorder.endRecording();
  for (final e in effects) {
    final next = _applyEffect(picture, size, f, e);
    picture.dispose();
    picture = next;
  }
  canvas.save();
  canvas.clipRect(Offset.zero & size);
  canvas.drawPicture(picture);
  canvas.restore();
  picture.dispose();
}

/// The shot's panels in their places; with an animated layout change, sliding from the last shot's places over
/// the transition (a panel with no place before grows from its right edge, one with no place after folds away).
void _paintPanels(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot) {
  final layout = shot.layout;
  if (layout == null || shot.panelShots.isEmpty) {
    _paintView(canvas, size, f, shot, shot);
    return;
  }
  final rects = layout.rects();
  final i = f.plan.indexAt(shot.start);
  final prev = i > 0 && identical(f.plan.shots[i], shot) ? f.plan.shots[i - 1] : null;
  final into = shot.transitionSteps <= 0 ? 1.0 : (f.step - shot.start) / shot.transitionSteps;
  final morph = shot.animateLayout && prev != null && into < 1;
  canvas.drawRect(Offset.zero & size, Paint()..color = Neon.bg);
  void place(DirectedShot view, DirectedShot owner, PanelRect r) {
    if (r.width <= 1e-4 || r.height <= 1e-4) return;
    final rect = Rect.fromLTRB(r.left * size.width, r.top * size.height, r.right * size.width, r.bottom * size.height);
    // The effects aimed at this panel of [owner] run on the panel alone.
    final k = owner.panelShots.indexOf(view);
    final own = [for (final e in owner.effects) if (k >= 0 && e.panelIn(owner.panelShots.length) == k) e];
    canvas.save();
    canvas.translate(rect.left, rect.top);
    _withEffects(canvas, rect.size, f, own, (c) => _paintView(c, rect.size, f, view, owner));
    canvas.restore();
  }

  if (!morph) {
    for (var k = 0; k < shot.panelShots.length && k < rects.length; k++) {
      place(shot.panelShots[k], shot, rects[k]);
    }
  } else {
    final p = _ease(into);
    final before = prev.layout?.rects() ?? const [PanelRect(0, 0, 1, 1)];
    final beforeShots = prev.panelShots.isEmpty ? [prev] : prev.panelShots;
    for (var k = beforeShots.length; k-- > rects.length;) {
      if (k < before.length) place(beforeShots[k], prev, PanelRect.lerp(before[k], before[k].folded, p));
    }
    for (var k = 0; k < shot.panelShots.length && k < rects.length; k++) {
      place(shot.panelShots[k], shot, PanelRect.lerp(k < before.length ? before[k] : rects[k].folded, rects[k], p));
    }
  }
  // Hairlines between the panels, in the theme's line colour.
  final hair = Paint()
    ..color = Neon.line
    ..strokeWidth = math.max(1, _unit(size) * 0.8);
  if (!morph) {
    for (final d in layout.dividers()) {
      if (d.vertical) {
        canvas.drawLine(Offset(d.at * size.width, d.from * size.height), Offset(d.at * size.width, d.to * size.height), hair);
      } else {
        canvas.drawLine(Offset(d.from * size.width, d.at * size.height), Offset(d.to * size.width, d.at * size.height), hair);
      }
    }
  }
}

/// One view of [view]'s kind filling [size], in its panel's look, with its own camera ([owner] is the shot on the
/// plan it belongs to).
void _paintView(Canvas canvas, Size size, VideoFrameInput f, DirectedShot view, DirectedShot owner) {
  final look = _lk;
  _lk = view.panel?.look ?? _defaultLook;
  canvas.save();
  canvas.clipRect(Offset.zero & size);
  _paintBackground(canvas, size);
  final cam = f.plan.camera(view, f.step);
  switch (view.kind) {
    case VideoShot.flythrough:
      _flythrough(canvas, size, f, view, cam);
    case VideoShot.pianoRoll:
      _pianoRoll(canvas, size, f, view, cam);
    case VideoShot.mixer:
      _mixer(canvas, size, f, view, cam);
    case VideoShot.devices:
      _device(canvas, size, f, view, cam);
    case VideoShot.falling:
      _falling(canvas, size, f, view, cam);
  }
  canvas.restore();
  _lk = look;
}

/// The look being drawn. Painting is synchronous, so [_paintView] sets it around each view and puts it back.
VideoLook _lk = _defaultLook;
final VideoLook _defaultLook = VideoLook();

void _paintBackground(Canvas canvas, Size size) {
  final r = Offset.zero & size;
  if (_bg case final bg?) {
    _drawBackgroundImage(canvas, size, bg);
    return;
  }
  switch (_lk.background) {
    case VideoBackground.theme:
      canvas.drawRect(r, Paint()..color = Neon.bg);
    case VideoBackground.black:
      canvas.drawRect(r, Paint()..color = const Color(0xff000000));
    case VideoBackground.panel:
      canvas.drawRect(r, Paint()..color = Neon.panel);
    case VideoBackground.gradient:
      canvas.drawRect(r, Paint()..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter,
          [Color.lerp(Neon.bg, Neon.violet, 0.28)!, Neon.bg, Color.lerp(Neon.bg, Neon.pink, 0.18)!], [0, 0.55, 1]));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Helpers

double _unit(Size s) => math.min(s.width, s.height) / 360;

/// The steps a timeline shot (arrangement or piano roll) shows: its left edge and width. The camera's centre sits
/// at its anchor across the view, else 0.4 of the way in on the arrangement and 0.35 on the piano roll.
({double left, double visible}) videoView(DirectedShot shot, ShotCamera cam) {
  final visible = shot.visibleSteps / cam.zoom;
  final anchor = cam.anchor ?? (shot.kind == VideoShot.pianoRoll ? 0.35 : 0.4);
  return (left: cam.center - visible * anchor, visible: visible);
}

void _text(Canvas canvas, String text, Offset at, double size, Color color,
    {FontWeight weight = FontWeight.w600, double? maxWidth, TextAlign align = TextAlign.left, bool mono = false,
    double letterSpacing = 0}) {
  if (text.isEmpty || size <= 0) return;
  final tp = _layoutText(text, size, color, weight: weight, maxWidth: maxWidth, align: align, mono: mono,
      letterSpacing: letterSpacing);
  final dx = switch (align) {
    TextAlign.center => -tp.width / 2,
    TextAlign.right => -tp.width,
    _ => 0.0,
  };
  tp.paint(canvas, at + Offset(dx, 0));
}

/// Laid-out text by everything that shapes it: most labels (track names, knob names, the bar.beat) repeat frame
/// after frame, so a render lays each out once instead of every frame. Bounded; the oldest goes first.
final Map<(String, double, int, FontWeight, double?, TextAlign, bool, double), TextPainter> _texts = {};
const int _maxTexts = 512;

TextPainter _layoutText(String text, double size, Color color, {required FontWeight weight, required double? maxWidth,
    required TextAlign align, required bool mono, required double letterSpacing}) {
  final key = (text, size, color.toARGB32(), weight, maxWidth, align, mono, letterSpacing);
  final hit = _texts.remove(key);
  if (hit != null) {
    _texts[key] = hit; // most recent last
    return hit;
  }
  final tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontSize: size, color: color, fontWeight: weight,
        letterSpacing: letterSpacing, fontFamily: mono ? Neon.mono : null, fontFamilyFallback: mono ? Neon.monoFallback : null)),
    textDirection: TextDirection.ltr,
    textAlign: align,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth ?? double.infinity);
  _texts[key] = tp;
  if (_texts.length > _maxTexts) _texts.remove(_texts.keys.first)?.dispose();
  return tp;
}

/// Forgets the laid-out text (a theme change, or the tests between fonts).
void clearVideoTextCache() {
  for (final tp in [..._texts.values, ..._overlayTexts.values]) {
    tp.dispose();
  }
  _texts.clear();
  _overlayTexts.clear();
}

Paint _glow(Color c, double sigma, {double alpha = 0.8}) => Paint()
  ..color = c.withValues(alpha: (alpha * Neon.glowStrength.clamp(0.0, 1.5) / 1.5 * 1.2 * _lk.glow).clamp(0.0, 1.0))
  ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);

/// Track [t]'s colour in the look's palette.
Color _track(VideoScene s, int t) {
  final own = t >= 0 && t < s.tracks.length ? Color(s.tracks[t].color) : Neon.pink;
  final n = math.max(1, s.tracks.length - 1);
  final x = t < 0 ? 0.0 : (t / n).clamp(0.0, 1.0);
  return switch (_lk.palette) {
    VideoPalette.tracks => own,
    VideoPalette.accent => Neon.pink,
    VideoPalette.mono => Neon.text,
    VideoPalette.warm => Color.lerp(Neon.yellow, Neon.pink, x)!,
    VideoPalette.cool => Color.lerp(Neon.blue, Neon.violet, x)!,
  };
}

/// A note's block [r] in [color] in the look's note style; [standard] draws the view's own shape.
void _noteBox(Canvas canvas, Rect r, Color color, double u, void Function(Paint paint) standard) {
  final paint = Paint()..color = color;
  switch (_lk.noteStyle) {
    case VideoNoteStyle.standard:
      standard(paint);
    case VideoNoteStyle.block:
      canvas.drawRect(r, paint);
    case VideoNoteStyle.rounded:
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(math.min(r.height / 2, 5 * u))), paint);
    case VideoNoteStyle.outline:
      canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(0.6 * u), Radius.circular(2 * u)), paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, 1.2 * u));
    case VideoNoteStyle.line:
      final h = math.max(1.5 * u, r.height * 0.3);
      canvas.drawRect(Rect.fromLTRB(r.left, r.center.dy - h / 2, r.right, r.center.dy + h / 2), paint);
  }
}

/// A note whose pitch bends: a line [width] thick through its time, offset by the bend ([along] maps 0..1 through
/// the note to a point on its unbent centre line; [offset] a bend in semitones to a shift).
void _bentNote(Canvas canvas, SceneNote n, double bpm, Offset Function(double u) along, Offset Function(double semis) offset,
    double width, Color color, {Paint? glow}) {
  final path = Path();
  const steps = 24;
  for (var k = 0; k <= steps; k++) {
    final u = k / steps;
    final pt = along(u) + offset(n.bendAt(u, bpm));
    k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
  }
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;
  if (_lk.noteStyle == VideoNoteStyle.outline) line.strokeWidth = math.max(1, width * 0.25);
  if (_lk.noteStyle == VideoNoteStyle.line) line.strokeWidth = math.max(1, width * 0.3);
  if (glow != null) {
    canvas.drawPath(path, glow
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * 2
      ..strokeCap = StrokeCap.round);
  }
  canvas.drawPath(path, line);
}

String _barBeat(VideoScene s, double step) {
  final st = math.max(0.0, step);
  final bar = (st / s.stepsPerBar).floor() + 1;
  final beat = ((st % s.stepsPerBar) / 4).floor() + 1;
  return '$bar.$beat';
}

bool _isBlack(int pitch) => const [1, 3, 6, 8, 10].contains(pitch % 12);

void _grid(Canvas canvas, Rect area, VideoScene s, double left, double visible, double u, {bool beats = true}) {
  if (!_lk.grid) return;
  final spb = s.stepsPerBar;
  final x0 = (left / 4).floor() * 4;
  final bar = Paint()..color = Neon.line.withValues(alpha: 0.9)..strokeWidth = math.max(1, u * 0.8);
  final beat = Paint()..color = Neon.line.withValues(alpha: 0.35)..strokeWidth = math.max(1, u * 0.5);
  for (var st = x0.toDouble(); st <= left + visible; st += 4) {
    final x = area.left + (st - left) / visible * area.width;
    final isBar = st % spb == 0;
    if (!isBar && (!beats || visible > spb * 12)) continue;
    canvas.drawLine(Offset(x, area.top), Offset(x, area.bottom), isBar ? bar : beat);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Arrangement flythrough: the camera follows the playhead along a slightly tilted arrangement.

void _flythrough(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot, ShotCamera cam) {
  final s = f.scene;
  final u = _unit(size);
  final (:left, :visible) = videoView(shot, cam);
  final playing = <int>{for (final c in s.clips) if (c.start <= f.step && c.end > f.step) c.track};

  // The tracks with clips (up to a dozen), each a lane.
  final lanes = <int>[];
  for (var t = 0; t < s.tracks.length && lanes.length < 12; t++) {
    if (s.clips.any((c) => c.track == t)) lanes.add(t);
  }
  if (lanes.isEmpty) lanes.add(-1);

  // A gentle tilt, as if flying over the timeline: perspective about the centre.
  canvas.save();
  final cx = size.width / 2, cy = size.height / 2;
  final m = Matrix4.identity()
    ..translateByDouble(cx, cy, 0, 1)
    ..setEntry(3, 2, 0.9 / math.max(size.width, size.height))
    ..rotateX(0.32)
    ..translateByDouble(-cx, -cy, 0, 1);
  canvas.transform(m.storage);
  final area = Rect.fromLTRB(-size.width * 0.25, size.height * 0.12, size.width * 1.25, size.height * 1.02);
  final spanSteps = visible * area.width / size.width;
  final leftWide = left - visible * 0.25;
  double x(double st) => area.left + (st - leftWide) / spanSteps * area.width;

  _grid(canvas, area, s, leftWide, spanSteps, u);
  final laneH = math.min(area.height / lanes.length, size.height * 0.16);
  final lanesTop = area.top + (area.height - laneH * lanes.length) / 2;
  for (var k = 0; k < lanes.length; k++) {
    final t = lanes[k];
    final top = lanesTop + k * laneH;
    if (k.isOdd) canvas.drawRect(Rect.fromLTWH(area.left, top, area.width, laneH), Paint()..color = Neon.panel.withValues(alpha: 0.35));
    if (t < 0) continue;
    final color = _track(s, t);
    for (final c in s.clips) {
      if (c.track != t || c.end < leftWide || c.start > leftWide + spanSteps) continue;
      final r = RRect.fromRectAndRadius(Rect.fromLTRB(x(c.start), top + laneH * 0.1, x(c.end), top + laneH * 0.9),
          Radius.circular(4 * u));
      final live = c.start <= f.step && c.end > f.step;
      if (live) canvas.drawRRect(r, _glow(color, 6 * u, alpha: 0.35));
      canvas.drawRRect(r, Paint()..color = color.withValues(alpha: live ? 0.28 : 0.16));
      canvas.drawRRect(r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, u * (live ? 1.4 : 0.8))
        ..color = color.withValues(alpha: live ? 0.95 : 0.55));
      final inner = r.outerRect.deflate(laneH * 0.08);
      if (c.audio) {
        // An audio clip: a stylised wave, deterministic in its position.
        final path = Path();
        for (var px = inner.left; px <= inner.right; px += 3 * u) {
          final st = leftWide + (px - area.left) / area.width * spanSteps;
          final a = (math.sin(st * 1.7) * 0.5 + math.sin(st * 0.37) * 0.5).abs();
          path.moveTo(px, inner.center.dy - a * inner.height / 2);
          path.lineTo(px, inner.center.dy + a * inner.height / 2);
        }
        canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.6)..strokeWidth = math.max(1, u * 0.8));
        continue;
      }
      final lo = c.lowPitch, hi = math.max(c.highPitch, c.lowPitch + 1);
      for (final ni in c.notes) {
        final n = s.notes[ni];
        if (n.end < leftWide || n.start > leftWide + spanSteps) continue;
        final nh = (inner.height / (hi - lo + 1)).clamp(2 * u, 6 * u);
        final y = inner.bottom - (n.pitch - lo) / (hi - lo) * (inner.height - nh) - nh;
        final nr = Rect.fromLTRB(x(n.start), y, math.max(x(n.end) - u, x(n.start) + 2 * u), y + nh);
        final on = n.start <= f.step && n.end > f.step;
        final fill = on ? Color.lerp(color, Colors.white, 0.6)! : color.withValues(alpha: 0.7);
        if (n.bends) {
          // The note's line bends with its pitch (a semitone is the lane's pitch step).
          final semi = (inner.height - nh) / (hi - lo);
          _bentNote(canvas, n, s.bpm, (t) => Offset(nr.left + (nr.right - nr.left) * t, nr.center.dy),
              (b) => Offset(0, -b * semi), nh, fill, glow: on ? _glow(color, 4 * u) : null);
          continue;
        }
        if (on) canvas.drawRect(nr.inflate(2 * u), _glow(color, 4 * u));
        _noteBox(canvas, nr, fill, u, (paint) => canvas.drawRect(nr, paint));
      }
      _text(canvas, c.name, Offset(r.left + 4 * u, r.top + 2 * u), 7 * u, Neon.text.withValues(alpha: live ? 0.95 : 0.6),
          maxWidth: math.max(0, r.width - 8 * u));
    }
  }
  // The playhead.
  final px = x(f.step);
  canvas.drawLine(Offset(px, area.top), Offset(px, area.bottom), _glow(Neon.pink, 6 * u)..strokeWidth = 6 * u);
  canvas.drawLine(Offset(px, area.top), Offset(px, area.bottom), Paint()..color = Neon.text..strokeWidth = 1.6 * u);
  canvas.restore();

  // The ruler and section names, flat on top.
  final ruler = Rect.fromLTWH(0, 0, size.width, size.height * 0.1);
  canvas.drawRect(ruler, Paint()..color = Neon.panel.withValues(alpha: 0.9));
  for (var bar = (left / s.stepsPerBar).floor(); bar * s.stepsPerBar <= left + visible; bar++) {
    if (bar < 0) continue;
    final st = bar * s.stepsPerBar.toDouble();
    final bx = (st - left) / visible * size.width;
    if (visible > s.stepsPerBar * 10 && bar % 4 != 0) continue;
    _text(canvas, '${bar + 1}', Offset(bx + 3 * u, ruler.bottom - 13 * u), 8 * u, Neon.dim, mono: true);
  }
  for (final sec in s.sections) {
    if (sec.name.isEmpty || sec.step < left - visible || sec.step > left + visible) continue;
    final sx = (sec.step - left) / visible * size.width;
    _text(canvas, sec.name.toUpperCase(), Offset(sx + 3 * u, 4 * u), 8 * u, Neon.yellow,
        weight: FontWeight.w800, letterSpacing: 1.2 * u, maxWidth: size.width * 0.5);
  }
  final hx = (f.step - left) / visible * size.width;
  canvas.drawLine(Offset(hx, 0), Offset(hx, ruler.bottom), Paint()..color = Neon.pink..strokeWidth = 1.5 * u);
  canvas.drawLine(Offset(0, ruler.bottom), Offset(size.width, ruler.bottom), Paint()..color = Neon.line..strokeWidth = u);
  if (playing.isNotEmpty) {
    // A soft sweep of the playing tracks' colours along the bottom edge.
    final colors = [for (final t in playing.take(4)) _track(s, t).withValues(alpha: 0.25)];
    if (colors.length == 1) colors.add(colors.first);
    // More than two colours need their stops (dart:ui throws without them): spread them evenly.
    final stops = [for (var i = 0; i < colors.length; ++i) i / (colors.length - 1)];
    canvas.drawRect(Rect.fromLTWH(0, size.height * 0.94, size.width, size.height * 0.06),
        Paint()..shader = ui.Gradient.linear(Offset(0, size.height), Offset(size.width, size.height), colors, stops));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Piano-roll close-up of one clip.

void _pianoRoll(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot, ShotCamera cam) {
  final s = f.scene;
  final u = _unit(size);
  final clip = shot.clip == null ? null : s.clips[shot.clip!];
  final color = clip == null ? Neon.blue : _track(s, clip.track);
  final (:left, :visible) = videoView(shot, cam);
  final span = math.max(8.0, shot.pitchSpan / math.sqrt(cam.zoom));
  final top = shot.pitchCenter + span / 2;
  final header = size.height * 0.1;
  final keys = size.width * 0.12;
  final roll = Rect.fromLTRB(keys, header, size.width, size.height);
  final rowH = roll.height / span;
  double y(double pitch) => roll.top + (top - pitch) * rowH;
  double x(double st) => roll.left + (st - left) / visible * roll.width;

  final active = <int>{};
  if (clip != null) {
    for (final ni in clip.notes) {
      final n = s.notes[ni];
      if (n.start > f.step) break;
      if (n.end > f.step) active.add(n.pitch.round());
    }
  }
  // Rows and keys.
  for (var p = (top - span).floor(); p <= top.ceil(); p++) {
    final ry = y(p + 0.5);
    final black = _isBlack(p);
    canvas.drawRect(Rect.fromLTWH(roll.left, ry, roll.width, rowH),
        Paint()..color = black ? Colors.black.withValues(alpha: 0.22) : Neon.panel.withValues(alpha: 0.25));
    final lit = active.contains(p);
    final key = Rect.fromLTWH(0, ry, keys - u, rowH - 0.5 * u);
    canvas.drawRect(key, Paint()..color = lit ? color : (black ? Neon.bg : Neon.text.withValues(alpha: 0.82)));
    if (lit) canvas.drawRect(key, _glow(color, 5 * u));
    if (p % 12 == 0) {
      _text(canvas, 'C${p ~/ 12 - 1}', Offset(keys - 3 * u, ry + rowH / 2 - 4 * u), math.min(8 * u, rowH * 0.8),
          Neon.bg, align: TextAlign.right, mono: true);
    }
  }
  _grid(canvas, roll, s, left, visible, u);

  // Notes.
  if (clip != null) {
    final list = clip.notes;
    var lo = 0, hi = list.length;
    final from = left - 64;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (s.notes[list[mid]].start < from) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var k = lo; k < list.length; k++) {
      final n = s.notes[list[k]];
      if (n.start > left + visible) break;
      if (n.end < left) continue;
      final r = RRect.fromRectAndRadius(
          Rect.fromLTRB(x(n.start), y(n.pitch + 0.5) + u, math.max(x(n.end) - u, x(n.start) + 3 * u), y(n.pitch - 0.5) - u),
          Radius.circular(2.5 * u));
      final on = n.start <= f.step && n.end > f.step;
      final age = (f.step - n.start).clamp(0.0, 4.0) / 4;
      final fill = on ? Color.lerp(color, Colors.white, 0.55 - 0.3 * age)! : color.withValues(alpha: 0.35 + 0.55 * n.vel);
      if (n.bends) {
        final rr = r.outerRect;
        _bentNote(canvas, n, s.bpm, (t) => Offset(rr.left + (rr.right - rr.left) * t, rr.center.dy),
            (b) => Offset(0, -b * rowH), rr.height, fill, glow: on ? _glow(color, (8 - 4 * age) * u, alpha: 0.9) : null);
        continue;
      }
      if (on) canvas.drawRRect(r.inflate(3 * u), _glow(color, (8 - 4 * age) * u, alpha: 0.9));
      _noteBox(canvas, r.outerRect, fill, u, (paint) => canvas.drawRRect(r, paint));
    }
  }
  final px = x(f.step);
  canvas.drawLine(Offset(px, roll.top), Offset(px, roll.bottom), _glow(Neon.pink, 5 * u)..strokeWidth = 5 * u);
  canvas.drawLine(Offset(px, roll.top), Offset(px, roll.bottom), Paint()..color = Neon.text..strokeWidth = 1.4 * u);

  canvas.drawRect(Rect.fromLTWH(0, 0, size.width, header), Paint()..color = Neon.panel);
  canvas.drawRect(Rect.fromLTWH(0, header - 2 * u, size.width, 2 * u), Paint()..color = color);
  final track = clip == null ? '' : s.tracks[clip.track].name;
  _text(canvas, (clip?.name ?? 'Notes').toUpperCase(), Offset(10 * u, header * 0.18), 11 * u, Neon.text,
      weight: FontWeight.w800, letterSpacing: 1.4 * u, maxWidth: size.width * 0.6);
  _text(canvas, track, Offset(10 * u, header * 0.18 + 14 * u), 8 * u, color, maxWidth: size.width * 0.6);
}

// ---------------------------------------------------------------------------------------------------------------
// Mixer: channel strips with meters.

void _mixer(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot, ShotCamera cam) {
  final s = f.scene;
  final u = _unit(size);
  final wide = size.width > size.height;
  final maxStrips = wide ? 10 : 6;
  final strips = <int>[];
  for (var t = 0; t < s.tracks.length; t++) {
    if (s.tracks[t].isFolder || s.tracks[t].depth > 0) continue;
    if (s.clips.any((c) => c.track == t)) strips.add(t);
  }
  final focus = shot.track;
  if (focus != null && !strips.contains(focus)) strips.insert(0, focus);
  while (strips.length > maxStrips) {
    strips.removeAt(strips.lastIndexWhere((t) => t != focus));
  }

  // The zoom pushes in on the focus strip.
  canvas.save();
  final focusX = focus == null ? 0.5 : (strips.indexOf(focus) + 0.5) / (strips.length + 1.5);
  canvas.translate(size.width * focusX, size.height / 2);
  canvas.scale(cam.zoom);
  canvas.translate(-size.width * focusX, -size.height / 2);

  final n = strips.length + 1.5; // the master is wider
  final w = size.width / n;
  final area = Rect.fromLTRB(0, size.height * 0.06, size.width, size.height * 0.94);
  double fallbackLevel(int t) {
    // No stem for this track: its notes sounding now, as a stand-in.
    var v = 0.0;
    for (var i = s.firstNoteFrom(f.step - 16); i < s.notes.length && s.notes[i].start <= f.step; i++) {
      final nt = s.notes[i];
      if (nt.track == t && nt.end > f.step) v = math.max(v, nt.vel * (1 - (f.step - nt.start).clamp(0.0, 8.0) / 16));
    }
    return v * 0.8;
  }

  for (var k = 0; k <= strips.length; k++) {
    final master = k == strips.length;
    final t = master ? -1 : strips[k];
    final color = master ? Neon.pink : _track(s, t);
    final r = Rect.fromLTWH(k * w + 3 * u, area.top, (master ? w * 1.5 : w) - 6 * u, area.height);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(8 * u));
    canvas.drawRRect(rr, Paint()..color = Neon.panel.withValues(alpha: 0.9));
    canvas.drawRRect(rr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = u * (t == focus ? 1.6 : 0.8)
      ..color = t == focus ? color : Neon.line);
    canvas.drawRect(Rect.fromLTWH(r.left + 6 * u, r.top + 4 * u, r.width - 12 * u, 2.5 * u), Paint()..color = color);
    final name = master ? 'MASTER' : s.tracks[t].name;
    _text(canvas, name, Offset(r.center.dx, r.bottom - 14 * u), 7.5 * u, Neon.text,
        align: TextAlign.center, maxWidth: r.width - 4 * u, weight: FontWeight.w700);

    // The pan knob.
    final knobC = Offset(r.center.dx, r.top + 22 * u);
    final pan = master ? 0.0 : s.tracks[t].pan;
    _knob(canvas, knobC, math.min(10 * u, r.width * 0.3), 0.5 + pan / 2, color, u, bipolar: true);

    // Meters and the fader.
    final meter = Rect.fromLTRB(r.left + r.width * 0.18, r.top + 40 * u, r.right - r.width * 0.18, r.bottom - 22 * u);
    final levels = master
        ? [f.levels.peakL, f.levels.peakR]
        : [f.levels.tracks[s.tracks[t].id] ?? fallbackLevel(t)];
    final gap = 2 * u;
    final mw = (meter.width - gap * (levels.length - 1)) / levels.length;
    for (var c = 0; c < levels.length; c++) {
      final mr = Rect.fromLTWH(meter.left + c * (mw + gap), meter.top, mw * (master ? 1 : 0.55), meter.height);
      canvas.drawRRect(RRect.fromRectAndRadius(mr, Radius.circular(2 * u)), Paint()..color = Colors.black.withValues(alpha: 0.35));
      final db = levels[c] <= 1e-5 ? -60.0 : 20 * math.log(levels[c]) / math.ln10;
      final h = ((db + 60) / 60).clamp(0.0, 1.0) * mr.height;
      final lit = Rect.fromLTRB(mr.left, mr.bottom - h, mr.right, mr.bottom);
      final shader = ui.Gradient.linear(mr.bottomLeft, mr.topLeft, [Neon.green, Neon.yellow, Neon.pink], [0, 0.75, 1]);
      if (h > 0) {
        canvas.drawRect(lit, _glow(color, 4 * u, alpha: 0.4));
        canvas.drawRect(lit, Paint()..shader = shader);
      }
    }
    if (master) {
      final rms = f.levels.rms <= 1e-5 ? -60.0 : 20 * math.log(f.levels.rms) / math.ln10;
      final ry = meter.bottom - ((rms + 60) / 60).clamp(0.0, 1.0) * meter.height;
      canvas.drawLine(Offset(meter.left, ry), Offset(meter.right, ry), Paint()..color = Neon.text..strokeWidth = 1.2 * u);
    } else {
      final vol = s.tracks[t].volume.clamp(0.0, 1.0);
      final fx = meter.right - mw * 0.2;
      canvas.drawLine(Offset(fx, meter.top), Offset(fx, meter.bottom), Paint()..color = Neon.line..strokeWidth = 2 * u);
      final fy = meter.bottom - vol * meter.height;
      final cap = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(fx, fy), width: mw * 0.5 + 6 * u, height: 8 * u),
          Radius.circular(2 * u));
      canvas.drawRRect(cap, Paint()..color = Neon.text);
      canvas.drawRect(Rect.fromCenter(center: Offset(fx, fy), width: mw * 0.5 + 6 * u, height: u), Paint()..color = color);
    }
  }
  canvas.restore();
}

void _knob(Canvas canvas, Offset c, double r, double value, Color color, double u, {bool bipolar = false, bool hot = false}) {
  const start = math.pi * 0.75, sweep = math.pi * 1.5;
  final v = value.clamp(0.0, 1.0);
  canvas.drawCircle(c, r, Paint()..color = Neon.bg);
  final ring = Rect.fromCircle(center: c, radius: r * 0.82);
  canvas.drawArc(ring, start, sweep, false, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = r * 0.16
    ..color = Neon.line);
  final from = bipolar ? start + sweep / 2 : start;
  final to = start + sweep * v;
  final arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = r * 0.16
    ..color = color;
  if (hot) canvas.drawArc(ring, math.min(from, to), (to - from).abs(), false, _glow(color, r * 0.3)..style = PaintingStyle.stroke..strokeWidth = r * 0.4);
  canvas.drawArc(ring, math.min(from, to), (to - from).abs(), false, arc);
  final a = to;
  canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * r * 0.2, c + Offset(math.cos(a), math.sin(a)) * r * 0.62,
      Paint()..color = Neon.text..strokeWidth = math.max(1, r * 0.1)..strokeCap = StrokeCap.round);
}

// ---------------------------------------------------------------------------------------------------------------
// Device: a device's faceplate with its knobs, the automated one moving, and the lane's curve under it.

double _shown(double v) => v >= 0 && v <= 1 ? v : 0.5 + math.atan(v / 50) / math.pi;

void _device(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot, ShotCamera cam) {
  final s = f.scene;
  final u = _unit(size);
  final lane = shot.lane == null ? null : s.lanes[shot.lane!];
  final t = shot.track ?? lane?.track ?? -1;
  final color = _track(s, t);
  final track = t >= 0 && t < s.tracks.length ? s.tracks[t] : null;
  final device = track == null || track.devices.isEmpty
      ? null
      : track.devices[(lane?.device ?? 0).clamp(0, track.devices.length - 1)];

  canvas.save();
  canvas.translate(size.width / 2, size.height / 2);
  canvas.scale(cam.zoom);
  canvas.translate(-size.width / 2, -size.height / 2);

  final plate = Rect.fromLTRB(size.width * 0.06, size.height * 0.08, size.width * 0.94, size.height * 0.68);
  final rr = RRect.fromRectAndRadius(plate, Radius.circular(14 * u));
  canvas.drawRRect(rr.inflate(4 * u), _glow(color, 14 * u, alpha: 0.25));
  canvas.drawRRect(rr, Paint()..color = Color.lerp(Neon.bg, color, 0.07)!);
  canvas.drawRRect(rr, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2 * u..color = color.withValues(alpha: 0.8));
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(plate.left + 12 * u, plate.top + 10 * u, plate.width - 24 * u, 3 * u),
      Radius.circular(2 * u)), Paint()..shader = ui.Gradient.linear(plate.topLeft, plate.topRight, [color, Neon.violet]));
  final title = (device?.name ?? lane?.label ?? 'Device').toUpperCase();
  _text(canvas, title, Offset(plate.left + 14 * u, plate.top + 20 * u), 13 * u, Neon.text,
      weight: FontWeight.w800, letterSpacing: 1.6 * u, maxWidth: plate.width - 28 * u);
  _text(canvas, track?.name ?? 'Master', Offset(plate.left + 14 * u, plate.top + 38 * u), 8.5 * u, color,
      maxWidth: plate.width - 28 * u);

  // Knobs: the device's parameters (up to eight, by name), the lane's own one first and lit.
  final params = device == null ? <MapEntry<String, double>>[] : (device.params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  final knobs = <(String, double, bool)>[];
  if (lane != null) knobs.add((lane.label, lane.valueAt(f.step), true));
  for (final p in params) {
    if (knobs.length >= 8) break;
    if (lane != null && p.key == lane.label) continue;
    knobs.add((p.key, _shown(p.value), false));
  }
  if (knobs.isEmpty) knobs.add(('level', f.levels.rms.clamp(0.0, 1.0) * 2, false));
  final cols = knobs.length <= 4 ? knobs.length : 4;
  final rows = (knobs.length / cols).ceil();
  final grid = Rect.fromLTRB(plate.left + 10 * u, plate.top + 56 * u, plate.right - 10 * u, plate.bottom - 10 * u);
  final cw = grid.width / cols, ch = grid.height / rows;
  for (var k = 0; k < knobs.length; k++) {
    final (name, value, hot) = knobs[k];
    final c = Offset(grid.left + (k % cols + 0.5) * cw, grid.top + (k ~/ cols + 0.42) * ch);
    final r = math.min(cw, ch) * (hot ? 0.36 : 0.3);
    _knob(canvas, c, r, value, hot ? color : Neon.blue, u, hot: hot);
    _text(canvas, name.toUpperCase(), c + Offset(0, r + 4 * u), 7 * u, hot ? Neon.text : Neon.dim,
        align: TextAlign.center, maxWidth: cw - 6 * u, weight: FontWeight.w700);
  }
  canvas.restore();

  // The lane's curve around the playhead (two bars either side), and a scope from the levels.
  final strip = Rect.fromLTRB(size.width * 0.06, size.height * 0.74, size.width * 0.94, size.height * 0.94);
  canvas.drawRRect(RRect.fromRectAndRadius(strip, Radius.circular(10 * u)), Paint()..color = Neon.panel.withValues(alpha: 0.85));
  final window = s.stepsPerBar * 4.0;
  final from = f.step - window / 2;
  final path = Path();
  for (var k = 0; k <= 96; k++) {
    final st = from + window * k / 96;
    final v = lane?.valueAt(st) ?? (0.5 + 0.4 * math.sin(st * 0.8) * f.levels.rms.clamp(0.0, 1.0));
    final pt = Offset(strip.left + strip.width * k / 96, strip.bottom - 6 * u - v * (strip.height - 12 * u));
    k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
  }
  canvas.drawPath(path, _glow(color, 4 * u)..style = PaintingStyle.stroke..strokeWidth = 4 * u);
  canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6 * u..color = color);
  final now = lane?.valueAt(f.step) ?? 0.5;
  final dot = Offset(strip.center.dx, strip.bottom - 6 * u - now * (strip.height - 12 * u));
  canvas.drawLine(Offset(strip.center.dx, strip.top), Offset(strip.center.dx, strip.bottom), Paint()..color = Neon.pink..strokeWidth = u);
  canvas.drawCircle(dot, 4 * u, _glow(Neon.pink, 4 * u));
  canvas.drawCircle(dot, 2.5 * u, Paint()..color = Neon.text);
}

// ---------------------------------------------------------------------------------------------------------------
// The position readout and the title card.

void _paintHud(Canvas canvas, Size size, VideoFrameInput f) {
  final u = _unit(size);
  _text(canvas, _barBeat(f.scene, f.step), Offset(size.width - 8 * u, size.height - 16 * u), 8 * u,
      Neon.text.withValues(alpha: 0.7), align: TextAlign.right, mono: true);
}

void _paintTitle(Canvas canvas, Size size, VideoFrameInput f) {
  // Shown for three seconds, fading out over the last one.
  const hold = 2.0, fade = 1.0;
  if (f.seconds >= hold + fade) return;
  final a = f.seconds < hold ? 1.0 : 1 - _ease((f.seconds - hold) / fade);
  final u = _unit(size);
  canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, a));
  canvas.drawRect(Offset.zero & size, Paint()..color = Neon.bg.withValues(alpha: 0.82));
  final c = size.center(Offset.zero);
  final rise = (1 - _ease(f.seconds / 0.8)) * 12 * u;
  _text(canvas, f.title, c + Offset(0, -18 * u + rise), 26 * u, Neon.text, align: TextAlign.center,
      weight: FontWeight.w900, maxWidth: size.width * 0.9, letterSpacing: 1.0 * u);
  final bar = Rect.fromCenter(center: c + Offset(0, 16 * u), width: math.min(size.width * 0.5, 160 * u) * _ease(f.seconds / 1.2),
      height: 3 * u);
  canvas.drawRect(bar.inflate(2 * u), _glow(Neon.pink, 5 * u));
  canvas.drawRect(bar, Paint()..shader = ui.Gradient.linear(bar.centerLeft, bar.centerRight, [Neon.yellow, Neon.pink]));
  if (f.artist.isNotEmpty) {
    _text(canvas, f.artist.toUpperCase(), c + Offset(0, 26 * u), 11 * u, Neon.dim, align: TextAlign.center,
        weight: FontWeight.w700, maxWidth: size.width * 0.9, letterSpacing: 2.4 * u);
  }
  canvas.restore();
}

/// Records the frame at [width] × [height] (the part of a render that must run on the UI isolate).
ui.Picture recordVideoFrame(VideoFrameInput f, int width, int height) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  paintVideoFrame(canvas, Size(width.toDouble(), height.toDouble()), f);
  return recorder.endRecording();
}

/// [picture] rasterised (on the engine's raster thread) and read back as RGBA bytes, top row first; [timing], when
/// given, gets the microseconds spent rasterising and reading back.
Future<Uint8List> pictureToRgba(ui.Picture picture, int width, int height, {void Function(int raster, int read)? timing}) async {
  final sw = Stopwatch()..start();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final raster = sw.elapsedMicroseconds;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('the frame could not be read');
    timing?.call(raster, sw.elapsedMicroseconds - raster);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

/// Draws the frame at [width] × [height] pixels off screen and returns its RGBA bytes (top row first).
Future<Uint8List> rasterizeVideoFrame(VideoFrameInput f, int width, int height) =>
    pictureToRgba(recordVideoFrame(f, width, height), width, height);
