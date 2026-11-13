// The music video's transitions (cut, crossfade, push, slide, zoom, flash, wipe, glitch), keyframed camera moves,
// text overlays and image layers, drawn by paintVideoFrame for the preview and the render alike (no wall clock).
part of 'video_painter.dart';

/// A background image being drawn behind the views of the shot being painted (set around it, as [_lk] is).
({ui.Image image, double opacity})? _bg;

/// The shot's [into] (0..1) of its transition from [prev], drawn.
void _paintTransition(Canvas canvas, Size size, VideoFrameInput f, DirectedShot prev, DirectedShot shot, double into) {
  final rect = Offset.zero & size;
  final p = _ease(into);
  final wide = size.width >= size.height;
  switch (shot.transition) {
    case VideoTransition.cut:
      _paintShot(canvas, size, f, shot);
    case VideoTransition.crossfade:
      _paintShot(canvas, size, f, prev);
      canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, p));
      _paintShot(canvas, size, f, shot);
      canvas.restore();
    case VideoTransition.push:
      // The new shot pushes the old one out (sideways on a wide frame, upwards on a tall one).
      final d = wide ? Offset(size.width * p, 0) : Offset(0, size.height * p);
      canvas.save();
      canvas.translate(-d.dx, -d.dy);
      _paintShot(canvas, size, f, prev);
      canvas.restore();
      canvas.save();
      canvas.translate(wide ? size.width - d.dx : 0, wide ? 0 : size.height - d.dy);
      _paintShot(canvas, size, f, shot);
      canvas.restore();
    case VideoTransition.slide:
      // The new shot slides in over the old one, which stays put.
      _paintShot(canvas, size, f, prev);
      canvas.save();
      canvas.translate(wide ? size.width * (1 - p) : 0, wide ? 0 : size.height * (1 - p));
      canvas.drawRect(rect, Paint()..color = Neon.bg);
      _paintShot(canvas, size, f, shot);
      canvas.restore();
      final edge = wide ? Rect.fromLTWH(size.width * (1 - p) - 2, 0, 4, size.height)
          : Rect.fromLTWH(0, size.height * (1 - p) - 2, size.width, 4);
      canvas.drawRect(edge, _glow(Neon.pink, 6 * _unit(size), alpha: 0.6));
    case VideoTransition.zoom:
      // The old shot rushes towards the viewer and fades; the new one settles in from a little further back.
      void scaled(DirectedShot s, double k, double alpha) {
        canvas.saveLayer(rect, Paint()..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0)));
        canvas.translate(size.width / 2, size.height / 2);
        canvas.scale(k);
        canvas.translate(-size.width / 2, -size.height / 2);
        _paintShot(canvas, size, f, s);
        canvas.restore();
      }
      scaled(prev, 1 + 0.45 * p, 1 - p);
      scaled(shot, 0.82 + 0.18 * p, p);
    case VideoTransition.flash:
      // A single white flash at the cut (one, not a strobe), the new shot under its peak.
      _paintShot(canvas, size, f, into < 0.5 ? prev : shot);
      final a = (1 - (2 * into - 1).abs()).clamp(0.0, 1.0);
      canvas.drawRect(rect, Paint()..color = Color.fromRGBO(255, 255, 255, 0.92 * a * a));
    case VideoTransition.wipe:
      // A bright edge sweeps across (down a tall frame), the new shot behind it.
      _paintShot(canvas, size, f, prev);
      final shown = wide ? Rect.fromLTWH(0, 0, size.width * p, size.height) : Rect.fromLTWH(0, 0, size.width, size.height * p);
      if (shown.width > 0 && shown.height > 0) {
        canvas.save();
        canvas.clipRect(shown);
        _paintShot(canvas, size, f, shot);
        canvas.restore();
      }
      final u = _unit(size);
      final line = wide ? Rect.fromLTWH(shown.right - 1.5 * u, 0, 3 * u, size.height)
          : Rect.fromLTWH(0, shown.bottom - 1.5 * u, size.width, 3 * u);
      canvas.drawRect(line.inflate(3 * u), _glow(Neon.yellow, 6 * u));
      canvas.drawRect(line, Paint()..color = Neon.yellow);
    case VideoTransition.glitch:
      // Bands of the frame jump between the shots, more of them the new one as it goes, shifted sideways and
      // split in colour (from fixed hashes of the step, so a frame is the same every time).
      ui.Picture record(DirectedShot s) {
        final rec = ui.PictureRecorder();
        _paintShot(Canvas(rec, rect), size, f, s);
        return rec.endRecording();
      }
      final a = record(prev), b = record(shot);
      const bands = 14;
      final tick = (f.step * 4).floor();
      final jolt = math.sin(into * math.pi);
      final h = size.height / bands;
      for (var k = 0; k < bands; k++) {
        final band = Rect.fromLTWH(0, k * h, size.width, h + 0.5);
        final newer = _hash01(k * 31 + tick, 7) < into;
        final dx = (_hash01(k + tick * 13, 19) * 2 - 1) * size.width * 0.08 * jolt;
        canvas.save();
        canvas.clipRect(band);
        canvas.translate(dx, 0);
        canvas.drawPicture(newer ? b : a);
        canvas.restore();
        if (_hash01(k * 7 + tick, 3) < 0.25 * jolt) {
          canvas.drawRect(band, Paint()
            ..color = (k.isEven ? Neon.pink : Neon.blue).withValues(alpha: 0.35 * jolt)
            ..blendMode = BlendMode.plus);
        }
      }
      a.dispose();
      b.dispose();
  }
}

/// The shot's keyframed framing at [step]: zoomed into its centre and moved, eased from start to end.
void _frameCamera(Canvas canvas, Size size, VideoCameraMove move, DirectedShot shot, double step) {
  final len = math.max(1e-9, shot.end - shot.start);
  final at = move.at(((step - shot.start) / len).clamp(0.0, 1.0));
  canvas.translate(size.width / 2, size.height / 2);
  canvas.scale(at.zoom);
  canvas.translate(-size.width / 2 - at.x * size.width, -size.height / 2 - at.y * size.height);
}

/// Whether whole-video [start, length] covers [step] in the range [lo, hi).
bool _spans(double? start, double? length, double step, double lo, double hi) {
  final a = start ?? lo, b = length == null ? hi : a + length;
  return step >= a && step < b;
}

/// The image layers showing at [f]'s step in [placement]: the whole video's, then the shot's own.
Iterable<VideoImageLayer> _imagesAt(VideoFrameInput f, DirectedShot shot, VideoImagePlacement placement) sync* {
  for (final l in f.images) {
    if (l.placement == placement && _spans(l.start, l.length, f.step, f.rangeStart, f.rangeEnd)) yield l;
  }
  for (final l in shot.images) {
    if (l.placement == placement) yield l;
  }
}

/// The background image behind the views now (the last one wins), or null.
({ui.Image image, double opacity})? _backgroundImage(VideoFrameInput f, DirectedShot shot) {
  ({ui.Image image, double opacity})? out;
  for (final l in _imagesAt(f, shot, VideoImagePlacement.background)) {
    final img = f.bitmaps[l.assetId];
    if (img != null) out = (image: img, opacity: l.opacity);
  }
  return out;
}

/// [bg] filling [size] (cropped to cover it) over the theme's background, at its opacity.
void _drawBackgroundImage(Canvas canvas, Size size, ({ui.Image image, double opacity}) bg) {
  final r = Offset.zero & size;
  canvas.drawRect(r, Paint()..color = Neon.bg);
  final img = bg.image;
  final iw = img.width.toDouble(), ih = img.height.toDouble();
  if (iw <= 0 || ih <= 0) return;
  final k = math.max(size.width / iw, size.height / ih);
  final src = Rect.fromCenter(center: Offset(iw / 2, ih / 2), width: size.width / k, height: size.height / k);
  canvas.drawImageRect(img, src, r, Paint()
    ..filterQuality = FilterQuality.medium
    ..color = Color.fromRGBO(0, 0, 0, bg.opacity));
}

/// The overlay images over the frame, each centred where it was put, its width a share of the short side.
void _paintImages(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot, VideoImagePlacement placement) {
  for (final l in _imagesAt(f, shot, placement)) {
    final img = f.bitmaps[l.assetId];
    if (img == null || img.width <= 0 || img.height <= 0 || l.opacity <= 0) continue;
    final w = l.size * size.shortestSide, h = w * img.height / img.width;
    final dst = Rect.fromCenter(center: Offset(l.x * size.width, l.y * size.height), width: w, height: h);
    canvas.drawImageRect(img, Offset.zero & Size(img.width.toDouble(), img.height.toDouble()), dst, Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(0, 0, 0, l.opacity));
  }
}

Color videoColor(VideoColor c) => switch (c) {
      VideoColor.white => const Color(0xffffffff),
      VideoColor.accent => Neon.pink,
      VideoColor.blue => Neon.blue,
      VideoColor.green => Neon.green,
      VideoColor.yellow => Neon.yellow,
      VideoColor.violet => Neon.violet,
    };

/// The text overlays showing now: the whole video's, then the shot's.
void _paintTexts(Canvas canvas, Size size, VideoFrameInput f, DirectedShot shot) {
  for (final t in f.texts) {
    final from = t.start ?? f.rangeStart;
    final to = t.length == null ? f.rangeEnd : from + t.length!;
    _paintText(canvas, size, f, t, from, to);
  }
  for (final t in shot.texts) {
    _paintText(canvas, size, f, t, shot.start, shot.end);
  }
}

void _paintText(Canvas canvas, Size size, VideoFrameInput f, VideoText t, double from, double to) {
  final words = t.shown(f.title, f.artist).trim();
  if (words.isEmpty) return;
  final letters = words.characters.length;
  final frame = t.frameAt(f.step, from, to, letters, stepsPerBar: f.scene.stepsPerBar);
  if (frame == null) return;
  final shown = frame.typed >= letters ? words : words.characters.take(frame.typed).toString();
  final short = size.shortestSide;
  final tp = _overlayText(shown, t.size * short, videoColor(t.color), t.bold, size.width * 0.92);
  final c = Offset(t.x * size.width, t.y * size.height + frame.dy * short);
  final layer = frame.opacity < 1;
  if (layer) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, frame.opacity));
  canvas.save();
  canvas.translate(c.dx, c.dy);
  if (frame.scale != 1) canvas.scale(frame.scale);
  tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  canvas.restore();
  if (layer) canvas.restore();
}

/// Laid-out overlay text (with its soft shadow), kept between frames like [_layoutText]'s.
final Map<(String, double, int, bool, double), TextPainter> _overlayTexts = {};

TextPainter _overlayText(String text, double size, Color color, bool bold, double maxWidth) {
  final key = (text, size, color.toARGB32(), bold, maxWidth);
  final hit = _overlayTexts.remove(key);
  if (hit != null) return _overlayTexts[key] = hit;
  final tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(fontSize: size, color: color,
        fontWeight: bold ? FontWeight.w900 : FontWeight.w500, letterSpacing: size * 0.02,
        shadows: [Shadow(color: const Color(0xcc000000), blurRadius: size * 0.18, offset: Offset(0, size * 0.04))])),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  _overlayTexts[key] = tp;
  if (_overlayTexts.length > 256) _overlayTexts.remove(_overlayTexts.keys.first)?.dispose();
  return tp;
}
