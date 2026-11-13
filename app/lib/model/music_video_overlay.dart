// The music video's layers over and under the views (owner, 2026-11-12): text overlays with in and out animations
// that can sync to the beat, the user's images (cover art, logo, watermark) as an overlay or a background, keyframed
// camera moves per shot, and the effects' beat presets. Pure data with bounded readers for the saved project.
import 'dart:math' as math;

// ---------------------------------------------------------------------------------------------------------------
// Shared colours

/// The colours text and some effects pick from: the theme's accents and white (the painter reads them from the
/// theme, so a video follows it).
enum VideoColor {
  white('White'),
  accent('Accent'),
  blue('Blue'),
  green('Green'),
  yellow('Yellow'),
  violet('Violet');

  const VideoColor(this.label);
  final String label;
}

/// How a camera move or an animation eases between its ends.
enum VideoEase {
  linear('Linear'),
  easeIn('Ease in'),
  easeOut('Ease out'),
  easeInOut('Ease in-out');

  const VideoEase(this.label);
  final String label;

  /// [t] (0..1, clamped) through the curve.
  double apply(double t) {
    final x = t.clamp(0.0, 1.0);
    return switch (this) {
      VideoEase.linear => x,
      VideoEase.easeIn => x * x * x,
      VideoEase.easeOut => 1 - math.pow(1 - x, 3).toDouble(),
      VideoEase.easeInOut => x < 0.5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3).toDouble() / 2,
    };
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Text overlays

/// What a text overlay says: the video's title or artist (from the setup, so one change updates every overlay) or
/// its own text.
enum VideoTextKind {
  title('Title'),
  artist('Artist'),
  free('Text');

  const VideoTextKind(this.label);
  final String label;
}

/// How a text overlay comes in and goes out.
enum VideoTextAnim {
  none('None'),
  fade('Fade'),
  slide('Slide'),
  pop('Pop'),
  typewriter('Typewriter');

  const VideoTextAnim(this.label);
  final String label;
}

/// One line of text over the video: for one shot (it shows through the shot) or for the whole video (it shows
/// from [start] for [length] steps, or the whole range when they are null).
class VideoText {
  VideoText({required this.id, this.kind = VideoTextKind.free, this.text = '', double size = 0.08, double x = 0.5,
      double y = 0.5, this.color = VideoColor.white, this.bold = true, this.animIn = VideoTextAnim.fade,
      this.animOut = VideoTextAnim.fade, double inBeats = 1, double outBeats = 1, this.beatSync = true, double? start,
      double? length})
      : size = size.clamp(minSize, maxSize).toDouble(),
        x = x.clamp(0.0, 1.0).toDouble(),
        y = y.clamp(0.0, 1.0).toDouble(),
        inBeats = inBeats.clamp(0.0, maxBeats).toDouble(),
        outBeats = outBeats.clamp(0.0, maxBeats).toDouble(),
        start = start == null ? null : math.max(0.0, start),
        length = length == null ? null : math.max(1.0, length);

  final String id;
  VideoTextKind kind;

  /// The text of a [VideoTextKind.free] overlay (title and artist come from the setup).
  String text;

  /// The letters' height as a fraction of the frame's short side.
  double size;

  /// Where the text's centre sits, as fractions of the frame's width and height.
  double x, y;
  VideoColor color;
  bool bold;
  VideoTextAnim animIn, animOut;

  /// How long the in and out animations last, in beats.
  double inBeats, outBeats;

  /// On the beat: the text comes in on the first beat of its span, pops on every beat it shows, and types a letter
  /// a sixteenth.
  bool beatSync;

  /// A whole-video overlay's span (song steps); null shows it over the whole range. Unused in a shot.
  double? start, length;

  static const minSize = 0.02, maxSize = 0.3, maxBeats = 16.0;

  /// The words it shows, with [title] and [artist] from the setup.
  String shown(String title, String artist) => switch (kind) {
        VideoTextKind.title => title,
        VideoTextKind.artist => artist,
        VideoTextKind.free => text,
      };

  VideoText copy({String? id}) => VideoText(id: id ?? this.id, kind: kind, text: text, size: size, x: x, y: y,
      color: color, bold: bold, animIn: animIn, animOut: animOut, inBeats: inBeats, outBeats: outBeats,
      beatSync: beatSync, start: start, length: length);

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        if (text.isNotEmpty) 'text': text,
        'size': _r(size),
        'x': _r(x),
        'y': _r(y),
        if (color != VideoColor.white) 'color': color.name,
        if (!bold) 'bold': false,
        'in': animIn.name,
        'out': animOut.name,
        'in_beats': _r(inBeats),
        'out_beats': _r(outBeats),
        if (!beatSync) 'beat_sync': false,
        if (start != null) 'start': _r(start!),
        if (length != null) 'length': _r(length!),
      };

  static VideoText? fromJson(Object? j) {
    if (j is! Map) return null;
    return VideoText(
      id: videoStr(j['id']) ?? '',
      kind: videoEnum(VideoTextKind.values, j['kind'], VideoTextKind.free),
      text: videoStr(j['text']) ?? '',
      size: videoNum(j['size']) ?? 0.08,
      x: videoNum(j['x']) ?? 0.5,
      y: videoNum(j['y']) ?? 0.5,
      color: videoEnum(VideoColor.values, j['color'], VideoColor.white),
      bold: j['bold'] != false,
      animIn: videoEnum(VideoTextAnim.values, j['in'], VideoTextAnim.fade),
      animOut: videoEnum(VideoTextAnim.values, j['out'], VideoTextAnim.fade),
      inBeats: videoNum(j['in_beats']) ?? 1,
      outBeats: videoNum(j['out_beats']) ?? 1,
      beatSync: j['beat_sync'] != false,
      start: videoNum(j['start'])?.clamp(0.0, 2147483647.0).toDouble(),
      length: videoNum(j['length'])?.clamp(1.0, 2147483647.0).toDouble(),
    );
  }

  /// How a text over [from, to) (song steps) shows at [step]: its opacity, offset (fractions of the short side),
  /// scale and how many of its [letters] are typed. Null when it doesn't show.
  VideoTextFrame? frameAt(double step, double from, double to, int letters, {int stepsPerBar = 16}) {
    if (step < from || step >= to) return null;
    // On the beat, it comes in on the first beat of its span.
    final begin = beatSync ? math.min((from / 4).ceil() * 4.0, to) : from;
    if (step < begin) return null;
    final inLen = math.min(inBeats * 4, (to - begin) / 2), outLen = math.min(outBeats * 4, (to - begin) / 2);
    final pIn = animIn == VideoTextAnim.none || inLen <= 0 ? 1.0 : ((step - begin) / inLen).clamp(0.0, 1.0);
    final pOut = animOut == VideoTextAnim.none || outLen <= 0 ? 1.0 : ((to - step) / outLen).clamp(0.0, 1.0);
    var opacity = 1.0, dy = 0.0, scale = 1.0, typed = letters;
    void apply(VideoTextAnim a, double p, {required bool coming}) {
      final e = VideoEase.easeOut.apply(p);
      switch (a) {
        case VideoTextAnim.none:
          break;
        case VideoTextAnim.fade:
          opacity *= e;
        case VideoTextAnim.slide:
          opacity *= e;
          dy += (coming ? 1 : -1) * (1 - e) * 0.12;
        case VideoTextAnim.pop:
          opacity *= math.min(1.0, p * 3);
          // Overshoots a little and settles (a spring's first swing).
          scale *= p >= 1 ? 1 : 0.4 + 0.6 * e + math.sin(p * math.pi) * 0.18;
        case VideoTextAnim.typewriter:
          if (coming) {
            typed = beatSync
                ? math.min(letters, (step - begin).floor() + 1)
                : math.min(letters, (p * letters).ceil());
            if (p >= 1) typed = letters;
          } else {
            typed = math.min(typed, (p * letters).ceil());
          }
      }
    }

    apply(animIn, pIn, coming: true);
    apply(animOut, pOut, coming: false);
    // On the beat, a text that pops in pulses on every beat it shows.
    if (beatSync && animIn == VideoTextAnim.pop && pIn >= 1) {
      final phase = ((step - begin) % 4) / 4;
      scale *= 1 + 0.06 * math.pow(1 - phase, 3);
    }
    if (opacity <= 1e-3 || typed <= 0) return null;
    return VideoTextFrame(opacity: opacity.clamp(0.0, 1.0), dy: dy, scale: scale, typed: typed);
  }
}

/// A text overlay's state in one frame.
class VideoTextFrame {
  const VideoTextFrame({required this.opacity, required this.dy, required this.scale, required this.typed});
  final double opacity, dy, scale;
  final int typed;
}

/// The text presets the Text tab adds (the setup's Title card is the first; it stays a switch of its own).
enum VideoTextPreset {
  title('Title', 'The video\'s title, large in the middle'),
  artist('Artist', 'The artist under the middle'),
  lowerThird('Lower third', 'Title and artist low on the left'),
  free('Text', 'Your own words');

  const VideoTextPreset(this.label, this.description);
  final String label, description;

  /// The overlays it adds (ids from [newId]).
  List<VideoText> make(String Function() newId) => switch (this) {
        VideoTextPreset.title => [VideoText(id: newId(), kind: VideoTextKind.title, size: 0.11, y: 0.45,
            animIn: VideoTextAnim.pop, animOut: VideoTextAnim.fade)],
        VideoTextPreset.artist => [VideoText(id: newId(), kind: VideoTextKind.artist, size: 0.05, y: 0.56,
            bold: false, animIn: VideoTextAnim.slide, animOut: VideoTextAnim.fade)],
        VideoTextPreset.lowerThird => [
            VideoText(id: newId(), kind: VideoTextKind.title, size: 0.06, x: 0.3, y: 0.82, animIn: VideoTextAnim.slide,
                animOut: VideoTextAnim.slide),
            VideoText(id: newId(), kind: VideoTextKind.artist, size: 0.04, x: 0.3, y: 0.88, bold: false,
                color: VideoColor.accent, animIn: VideoTextAnim.typewriter, animOut: VideoTextAnim.fade),
          ],
        VideoTextPreset.free => [VideoText(id: newId(), text: 'Your text', size: 0.07, y: 0.3)],
      };
}

// ---------------------------------------------------------------------------------------------------------------
// Images

/// An image the user picked, copied into the project's video assets ([file] is its name there, never a path, so a
/// downloaded project can't point the app at other files). [width] and [height] are as decoded (after the limits).
class VideoImageAsset {
  VideoImageAsset({required this.id, required this.file, required this.name, this.width = 0, this.height = 0});
  final String id, file;
  String name;
  int width, height;

  /// The file names the assets folder takes: an id and an image extension.
  static final fileName = RegExp(r'^[A-Za-z0-9_-]{1,64}\.(png|jpg|jpeg|webp|gif|bmp)$');

  /// The image types the picker offers.
  static const extensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];

  /// The largest file read (bytes), the largest side and pixel count decoded, and the long side kept in memory.
  /// [maxPixelsFullDecode] is the pixel count for formats decoded at full size before scaling (PNG, GIF, BMP):
  /// 16 MP is 64 MB for a moment.
  static const maxBytes = 24 << 20, maxSide = 8192, maxPixels = 40000000, maxPixelsFullDecode = 16000000,
      keepSide = 2048;

  Map<String, dynamic> toJson() =>
      {'id': id, 'file': file, 'name': name, if (width > 0) 'width': width, if (height > 0) 'height': height};

  static VideoImageAsset? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = videoStr(j['id']), file = videoStr(j['file']);
    if (id == null || file == null || !fileName.hasMatch(file)) return null;
    int side(Object? v) => (videoNum(v) ?? 0).round().clamp(0, maxSide);
    return VideoImageAsset(id: id, file: file, name: videoStr(j['name']) ?? file, width: side(j['width']),
        height: side(j['height']));
  }
}

/// Where an image goes: over the views (a logo, a watermark) or behind them (cover art), filling the frame.
enum VideoImagePlacement {
  overlay('Overlay'),
  background('Background');

  const VideoImagePlacement(this.label);
  final String label;
}

/// One use of an image asset: for one shot, or for the whole video from [start] for [length] steps (the whole
/// range when null).
class VideoImageLayer {
  VideoImageLayer({required this.id, required this.assetId, this.placement = VideoImagePlacement.overlay,
      double x = 0.85, double y = 0.1, double size = 0.22, double opacity = 1, double? start, double? length})
      : x = x.clamp(0.0, 1.0).toDouble(),
        y = y.clamp(0.0, 1.0).toDouble(),
        size = size.clamp(0.04, 1.0).toDouble(),
        opacity = opacity.clamp(0.0, 1.0).toDouble(),
        start = start == null ? null : math.max(0.0, start),
        length = length == null ? null : math.max(1.0, length);

  final String id;
  String assetId;
  VideoImagePlacement placement;

  /// An overlay's centre (fractions of the frame) and width (a fraction of the frame's short side).
  double x, y, size;

  /// How strongly it shows (a background's views draw over it).
  double opacity;
  double? start, length;

  VideoImageLayer copy({String? id}) => VideoImageLayer(id: id ?? this.id, assetId: assetId, placement: placement,
      x: x, y: y, size: size, opacity: opacity, start: start, length: length);

  Map<String, dynamic> toJson() => {
        'id': id,
        'asset': assetId,
        'placement': placement.name,
        'x': _r(x),
        'y': _r(y),
        'size': _r(size),
        if (opacity != 1) 'opacity': _r(opacity),
        if (start != null) 'start': _r(start!),
        if (length != null) 'length': _r(length!),
      };

  static VideoImageLayer? fromJson(Object? j) {
    if (j is! Map) return null;
    final asset = videoStr(j['asset']);
    if (asset == null) return null;
    return VideoImageLayer(
      id: videoStr(j['id']) ?? '',
      assetId: asset,
      placement: videoEnum(VideoImagePlacement.values, j['placement'], VideoImagePlacement.overlay),
      x: videoNum(j['x']) ?? 0.85,
      y: videoNum(j['y']) ?? 0.1,
      size: videoNum(j['size']) ?? 0.22,
      opacity: videoNum(j['opacity']) ?? 1,
      start: videoNum(j['start'])?.clamp(0.0, 2147483647.0).toDouble(),
      length: videoNum(j['length'])?.clamp(1.0, 2147483647.0).toDouble(),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Camera moves

/// A framing: how far in (1 the whole frame) and where its centre is, as fractions of the frame from its middle.
class VideoFraming {
  const VideoFraming({this.zoom = 1, this.x = 0, this.y = 0});
  final double zoom, x, y;

  static const minZoom = 1.0, maxZoom = 3.0;

  /// Kept in range: zoomed in from 1 to 3, the centre only as far as the frame still covers the picture.
  VideoFraming get clamped {
    final z = zoom.clamp(minZoom, maxZoom).toDouble();
    final room = (1 - 1 / z) / 2;
    return VideoFraming(zoom: z, x: x.clamp(-room, room).toDouble(), y: y.clamp(-room, room).toDouble());
  }

  static VideoFraming lerp(VideoFraming a, VideoFraming b, double t) =>
      VideoFraming(zoom: a.zoom + (b.zoom - a.zoom) * t, x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t);

  Map<String, dynamic> toJson() => {'zoom': _r(zoom), 'x': _r(x), 'y': _r(y)};

  static VideoFraming fromJson(Object? j, VideoFraming fallback) => j is Map
      ? VideoFraming(zoom: videoNum(j['zoom']) ?? fallback.zoom, x: videoNum(j['x']) ?? fallback.x,
              y: videoNum(j['y']) ?? fallback.y)
          .clamped
      : fallback;

  @override
  bool operator ==(Object other) => other is VideoFraming && other.zoom == zoom && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(zoom, x, y);
}

/// A shot's keyframed camera (owner, 2026-11-12): from [from] at the shot's start to [to] at its end, eased. With
/// none, the auto camera moves the views as before.
class VideoCameraMove {
  VideoCameraMove({VideoFraming from = const VideoFraming(), VideoFraming to = const VideoFraming(zoom: 1.3),
      this.ease = VideoEase.easeInOut})
      : from = from.clamped,
        to = to.clamped;

  VideoFraming from, to;
  VideoEase ease;

  /// The framing a fraction [t] (0..1) through the shot.
  VideoFraming at(double t) => VideoFraming.lerp(from, to, ease.apply(t)).clamped;

  /// The presets the editor offers.
  static final presets = <String, VideoCameraMove Function()>{
    'Push in': () => VideoCameraMove(from: const VideoFraming(), to: const VideoFraming(zoom: 1.35)),
    'Pull out': () => VideoCameraMove(from: const VideoFraming(zoom: 1.35), to: const VideoFraming()),
    'Pan right': () =>
        VideoCameraMove(from: const VideoFraming(zoom: 1.3, x: -0.11), to: const VideoFraming(zoom: 1.3, x: 0.11)),
    'Pan left': () =>
        VideoCameraMove(from: const VideoFraming(zoom: 1.3, x: 0.11), to: const VideoFraming(zoom: 1.3, x: -0.11)),
    'Rise': () =>
        VideoCameraMove(from: const VideoFraming(zoom: 1.3, y: 0.11), to: const VideoFraming(zoom: 1.3, y: -0.11)),
  };

  VideoCameraMove copy() => VideoCameraMove(from: from, to: to, ease: ease);

  Map<String, dynamic> toJson() => {'from': from.toJson(), 'to': to.toJson(), 'ease': ease.name};

  static VideoCameraMove? fromJson(Object? j) {
    if (j is! Map) return null;
    return VideoCameraMove(
      from: VideoFraming.fromJson(j['from'], const VideoFraming()),
      to: VideoFraming.fromJson(j['to'], const VideoFraming(zoom: 1.3)),
      ease: videoEnum(VideoEase.values, j['ease'], VideoEase.easeInOut),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Reading helpers (untrusted JSON), shared with music_video_edit.dart

double _r(double v) => (v * 1e6).roundToDouble() / 1e6;

double? videoNum(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

String? videoStr(Object? v) => v is String && v.isNotEmpty ? (v.length > 200 ? v.substring(0, 200) : v) : null;

T videoEnum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    (name is String ? values.where((v) => v.name == name).firstOrNull : null) ?? fallback;

/// The most text overlays and image layers a shot or the whole video holds, and image assets a video keeps.
const int kVideoMaxTexts = 32, kVideoMaxImages = 16, kVideoMaxImageAssets = 32;
