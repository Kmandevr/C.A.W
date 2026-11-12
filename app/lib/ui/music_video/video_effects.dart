// The music video's per-shot effect stack (owner, 2026-11-12): each effect redraws the shot's picture once, so the
// live preview and the offline render (both through paintVideoFrame) look the same.
part of 'video_painter.dart';

/// Smooth fixed noise, −1..1, for the shake (no wall clock and no random state).
double _noise(double x, int seed) {
  final i = x.floor();
  double h(int n) => _hash01(n, seed) * 2 - 1;
  final t = x - i;
  final s = t * t * (3 - 2 * t);
  return h(i) + (h(i + 1) - h(i)) * s;
}

Color _effectColor(VideoEffectColor c) => switch (c) {
      VideoEffectColor.accent => Neon.pink,
      VideoEffectColor.blue => Neon.blue,
      VideoEffectColor.green => Neon.green,
      VideoEffectColor.yellow => Neon.yellow,
      VideoEffectColor.violet => Neon.violet,
      VideoEffectColor.white => const Color(0xffffffff),
    };

/// One channel of a colour matrix (0 red, 1 green, 2 blue), the others dropped.
ColorFilter _channel(int c) => ColorFilter.matrix([
      for (var row = 0; row < 4; row++)
        for (var col = 0; col < 5; col++) (row == col && (row == c || row == 3)) ? 1.0 : 0.0,
    ]);

/// [src] (the shot so far, [size]) with effect [e] applied at [f]'s step and levels, as a new picture.
ui.Picture _applyEffect(ui.Picture src, Size size, VideoFrameInput f, VideoEffect e) {
  final rec = ui.PictureRecorder();
  final r = Offset.zero & size;
  final c = Canvas(rec, r);
  final u = _unit(size);
  var k = e.strength(f.step, f.levels, f.scene.stepsPerBar);
  // A held strobe flashes on its own, every eighth note.
  if (e.kind == VideoEffectKind.strobe && e.drive == VideoDrive.steady && (f.step * 2).floor().isOdd) k = 0;
  if (k <= 1e-4) {
    c.drawPicture(src);
    return rec.endRecording();
  }
  switch (e.kind) {
    case VideoEffectKind.glow:
      c.drawPicture(src);
      final sigma = (3 + 12 * k) * u;
      c.saveLayer(r, Paint()
        ..blendMode = BlendMode.plus
        ..color = Color.fromRGBO(0, 0, 0, (0.95 * k).clamp(0.0, 1.0))
        ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal));
      c.drawPicture(src);
      c.restore();
    case VideoEffectKind.shake:
      final amp = 16 * u * k;
      c.drawRect(r, Paint()..color = Neon.bg);
      c.translate(_noise(f.step * 2.5, 11) * amp, _noise(f.step * 2.5, 23) * amp);
      c.drawPicture(src);
    case VideoEffectKind.punch:
      final scale = 1 + 0.2 * k;
      c.translate(size.width / 2, size.height / 2);
      c.scale(scale);
      c.translate(-size.width / 2, -size.height / 2);
      c.drawPicture(src);
    case VideoEffectKind.tint:
      c.drawPicture(src);
      c.drawRect(r, Paint()
        ..color = _effectColor(e.color).withValues(alpha: (0.6 * k).clamp(0.0, 1.0))
        ..blendMode = BlendMode.color);
    case VideoEffectKind.blur:
      final sigma = 10 * u * k;
      c.saveLayer(r, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp));
      c.drawPicture(src);
      c.restore();
    case VideoEffectKind.vignette:
      c.drawPicture(src);
      c.drawRect(r, Paint()
        ..shader = ui.Gradient.radial(r.center, size.longestSide * 0.72,
            [const Color(0x00000000), Color.fromRGBO(0, 0, 0, (0.92 * k).clamp(0.0, 1.0))], [0.42, 1]));
    case VideoEffectKind.chroma:
      final dx = 7 * u * k;
      c.drawRect(r, Paint()..color = const Color(0xff000000));
      for (final (ch, off) in [(0, -dx), (1, 0.0), (2, dx)]) {
        c.saveLayer(r, Paint()
          ..blendMode = BlendMode.plus
          ..colorFilter = _channel(ch));
        c.translate(off, 0);
        c.drawPicture(src);
        c.restore();
      }
    case VideoEffectKind.strobe:
      c.drawPicture(src);
      c.drawRect(r, Paint()..color = _effectColor(e.color).withValues(alpha: (0.85 * k).clamp(0.0, 1.0)));
  }
  return rec.endRecording();
}
