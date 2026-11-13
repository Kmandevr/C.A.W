// Waveforms of audio files for the arranger and the sampler: peaks from caw_asset_peaks, read off the UI isolate and
// cached per file, channel and zoom level, and the painter that draws a clip's part of the file with its fades.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../engine/audio_engine.dart';
import '../../model/audio_clips.dart';
import '../theme.dart';

/// One zoom level of one file: min/max pairs, [secondsPerBucket] apart.
class PeakLevel {
  const PeakLevel(this.minMax, this.secondsPerBucket);
  final Float32List minMax;
  final double secondsPerBucket;
  int get buckets => minMax.length ~/ 2;

  /// The (min, max) over [from]..[to] seconds of the file.
  (double, double) span(double from, double to) {
    if (buckets == 0) return (0, 0);
    final a = (from / secondsPerBucket).floor().clamp(0, buckets - 1);
    final b = (to / secondsPerBucket).ceil().clamp(a + 1, buckets);
    var lo = 0.0, hi = 0.0;
    for (var i = a; i < b; i++) {
      lo = math.min(lo, minMax[2 * i]);
      hi = math.max(hi, minMax[2 * i + 1]);
    }
    return (lo, hi);
  }
}

/// Peaks per (file, channel, level), the most recently used 96 kept. A level is a power of two of 1/4096 s per
/// bucket, the coarsest still finer than a pixel, so zooming steps through a few cached levels instead of reading
/// the file again at every scale.
class WaveformCache extends ChangeNotifier {
  WaveformCache._();
  static final WaveformCache instance = WaveformCache._();

  static const double _base = 1 / 4096;
  static const _maxEntries = 96;
  final LinkedHashMap<String, PeakLevel> _levels = LinkedHashMap();
  final Set<String> _loading = {};
  final Map<String, _PathNotifier> _paths = {};

  /// Fires when a level of [path] arrives, so only that file's waveforms repaint (beta plan B4.3); the cache itself
  /// still notifies for every file.
  Listenable of(String path) => _paths.putIfAbsent(path, _PathNotifier.new);

  /// The level index for [secondsPerPixel].
  static int levelFor(double secondsPerPixel) =>
      secondsPerPixel <= _base ? 0 : (math.log(secondsPerPixel / _base) / math.ln2).floor().clamp(0, 24);

  /// The peaks of [path] at about [secondsPerPixel], or null while they load (listeners hear when they arrive).
  PeakLevel? peaks(AudioIo io, String path, double fileSeconds, double secondsPerPixel, {int channel = 0}) {
    if (fileSeconds <= 0) return null;
    var level = levelFor(secondsPerPixel);
    // A long file at a fine level would pass the engine's 65,536 buckets: start where it fits.
    while (fileSeconds / (_base * math.pow(2, level)) > 65536) {
      level++;
    }
    final key = '$path|$channel|$level';
    final hit = _levels.remove(key);
    if (hit != null) {
      _levels[key] = hit;
      return hit;
    }
    // A coarser level already here stands in while this one loads.
    PeakLevel? standIn;
    for (var l = level + 1; l <= level + 6 && standIn == null; l++) {
      standIn = _levels['$path|$channel|$l'];
    }
    if (_loading.add(key)) {
      final spb = _base * math.pow(2, level);
      final buckets = (fileSeconds / spb).ceil().clamp(1, 65536);
      io.peaks(path, 0, buckets * spb, buckets, channel: channel).then((data) {
        _loading.remove(key);
        if (data == null) return;
        _levels[key] = PeakLevel(data, spb);
        while (_levels.length > _maxEntries) {
          _levels.remove(_levels.keys.first);
        }
        _paths[path]?.changed();
        notifyListeners();
      }, onError: (Object _) {
        _loading.remove(key);
      });
    }
    return standIn;
  }

  /// Forgets [path] (a file replaced).
  void forget(String path) {
    _levels.removeWhere((k, _) => k.startsWith('$path|'));
  }

  @visibleForTesting
  void clear() {
    _levels.clear();
    _loading.clear();
  }

  @visibleForTesting
  int get cachedLevels => _levels.length;
}

class _PathNotifier extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// What part of the file a clip shows: where it reads from and how fast, for [AudioClipPainter].
class ClipWindow {
  const ClipWindow({required this.offset, required this.perPixel, required this.fileSeconds, this.reverse = false,
      this.loop = false, this.loopStart = 0, this.loopEnd = 0});
  final double offset, perPixel, fileSeconds, loopStart, loopEnd;
  final bool reverse, loop;

  /// The file second under pixel [x] of the clip.
  double at(double x) {
    var t = offset + x * perPixel;
    if (loop) {
      final end = loopEnd > 0 ? loopEnd : fileSeconds;
      final span = end - loopStart;
      if (span > 0 && t >= end) t = loopStart + (t - loopStart) % span;
    }
    return reverse ? fileSeconds - t : t;
  }
}

/// Draws a clip's waveform (scaled by its gain), its fades as shaded corners with their curves, and loop seams.
/// The waveform is one batch of line segments per [WaveTiles.tile] pixels, recorded once per clip, zoom and size
/// and kept ([WaveTiles]), so a repaint replays a few pictures and the raster skips the tiles off screen (beta plan
/// B4.2). With [path], only that file's arriving peaks repaint it (B4.3).
class AudioClipPainter extends CustomPainter {
  AudioClipPainter({required this.peaks, required this.window, required this.color, required this.gain,
      required this.fadeIn, required this.fadeOut, required this.inCurve, required this.outCurve, this.top = 0,
      String? path})
      : super(repaint: path == null ? WaveformCache.instance : WaveformCache.instance.of(path));
  final PeakLevel? Function() peaks;
  final ClipWindow window;
  final Color color;
  final double gain, top;

  /// Fade lengths in pixels.
  final double fadeIn, fadeOut;
  final FadeCurve inCurve, outCurve;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height - top;
    final mid = top + h / 2;
    final p = peaks();
    if (p != null) {
      final tiles = WaveTiles.of(p, window, size, top, gain, color);
      final clip = canvas.getLocalClipBounds();
      for (var i = 0; i < tiles.length; i++) {
        final x = i * WaveTiles.tile.toDouble();
        if (x > clip.right || x + WaveTiles.tile < clip.left) continue;
        canvas.drawPicture(tiles[i]);
      }
    } else {
      canvas.drawLine(Offset(0, mid), Offset(size.width, mid), Paint()..color = color.withValues(alpha: 0.5));
    }
    // The fades: the faded-out part shaded, and the curve the gain follows.
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.32);
    final line = Paint()
      ..color = Neon.ink.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    void fade(double w, FadeCurve c, bool fadingIn) {
      if (w < 1) return;
      final curve = Path(), area = Path();
      for (var i = 0; i <= 24; i++) {
        final u = i / 24;
        final x = fadingIn ? u * w : size.width - w + u * w;
        final g = fadingIn ? c.at(u) : c.at(1 - u);
        final y = top + (1 - g) * h;
        i == 0 ? curve.moveTo(x, y) : curve.lineTo(x, y);
      }
      area
        ..addPath(curve, Offset.zero)
        ..lineTo(fadingIn ? 0 : size.width, top)
        ..close();
      canvas.drawPath(area, shade);
      canvas.drawPath(curve, line);
    }

    fade(fadeIn, inCurve, true);
    fade(fadeOut, outCurve, false);
  }

  @override
  bool shouldRepaint(covariant AudioClipPainter old) =>
      old.window.offset != window.offset || old.window.perPixel != window.perPixel || old.gain != gain ||
      old.fadeIn != fadeIn || old.fadeOut != fadeOut || old.inCurve != inCurve || old.outCurve != outCurve ||
      old.color != color || old.window.reverse != window.reverse || old.window.loop != window.loop;
}

/// The recorded waveform tiles of one clip at one zoom: [tile] pixels each, the most recently used [maxEntries]
/// clips kept. Each tile is one `drawRawPoints` batch of the per-pixel lines a clip draws.
class WaveTiles {
  static const tile = 512;
  static const maxEntries = 48;
  static final LinkedHashMap<Object, List<ui.Picture>> _cache = LinkedHashMap();

  /// Tiles recorded since the cache was last cleared (tests).
  @visibleForTesting
  static int recorded = 0;

  static List<ui.Picture> of(PeakLevel p, ClipWindow w, Size size, double top, double gain, Color color) {
    final key = (p, w.offset, w.perPixel, w.fileSeconds, w.reverse, w.loop, w.loopStart, w.loopEnd, size, top,
        gain, color);
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit;
    final h = size.height - top;
    final mid = top + h / 2;
    final scale = (h / 2 - 1) * gain.clamp(0.0, 4.0);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final tiles = <ui.Picture>[];
    final points = Float32List(tile * 4);
    for (var from = 0.0; from < size.width; from += tile) {
      var n = 0;
      for (var x = from; x < size.width && x < from + tile; x += 1) {
        final a = w.at(x), b = w.at(x + 1);
        final (lo, hi) = p.span(math.min(a, b), math.max(a, b));
        if (a < 0 || a > w.fileSeconds) continue;
        points[n++] = x + 0.5;
        points[n++] = mid - (hi * scale).clamp(-h / 2, h / 2);
        points[n++] = x + 0.5;
        points[n++] = mid - (lo * scale).clamp(-h / 2, h / 2) + 0.5;
      }
      final recorder = ui.PictureRecorder();
      if (n > 0) Canvas(recorder).drawRawPoints(ui.PointMode.lines, Float32List.sublistView(points, 0, n), paint);
      tiles.add(recorder.endRecording());
      recorded++;
    }
    _cache[key] = tiles;
    while (_cache.length > maxEntries) {
      for (final t in _cache.remove(_cache.keys.first)!) {
        t.dispose();
      }
    }
    return tiles;
  }

  @visibleForTesting
  static void clear() {
    for (final tiles in _cache.values) {
      for (final t in tiles) {
        t.dispose();
      }
    }
    _cache.clear();
    recorded = 0;
  }
}
