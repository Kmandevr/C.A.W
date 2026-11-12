// The arrangement music video's setup (docs/decisions.md "Arrangement music video"): shots, style, smooth follow,
// range, aspect ratio, resolution, frame rate and title card, the checks on them, and the frame clock that ties a frame to song time.
import 'dart:math' as math;

/// The shots the director can cut between; each can be switched off.
enum VideoShot {
  flythrough('Arrangement', 'The camera flies along the arrangement with the playhead; notes light up'),
  mixer('Mixer', 'Channel strips with meters from the rendered audio'),
  pianoRoll('Piano roll', 'Close-ups of the busiest clip, its notes glowing as they play'),
  devices('Devices', 'A device with its knobs moving to the automation');

  const VideoShot(this.label, this.description);
  final String label, description;
}

/// How the director cuts: how often, how shots change and how the camera moves.
enum VideoStyle {
  calm('Calm'),
  energetic('Energetic'),
  minimal('Minimal');

  const VideoStyle(this.label);
  final String label;
}

/// What part of the song the video covers.
enum VideoRange {
  song('Whole song'),
  loop('Loop range'),
  selection('Time selection');

  const VideoRange(this.label);
  final String label;
}

/// An aspect ratio, width to height (reduced).
class VideoAspect {
  factory VideoAspect(int w, int h) {
    final g = _gcd(w.abs(), h.abs());
    return VideoAspect._(g == 0 ? w : w ~/ g, g == 0 ? h : h ~/ g);
  }
  const VideoAspect._(this.w, this.h);
  final int w, h;

  static const portrait = VideoAspect._(9, 16);
  static const landscape = VideoAspect._(16, 9);
  static const square = VideoAspect._(1, 1);
  static const feed = VideoAspect._(4, 5);
  static const presets = [portrait, landscape, square, feed];

  /// Width over height.
  double get ratio => w / h;
  String get label => '$w:$h';
  bool get valid => w > 0 && h > 0 && w <= maxTerm && h <= maxTerm && ratio <= 4 && ratio >= 0.25;

  /// The largest term a custom ratio may use, and the widest it may be (4:1 either way).
  static const maxTerm = 64;

  @override
  bool operator ==(Object other) => other is VideoAspect && other.w == w && other.h == h;
  @override
  int get hashCode => Object.hash(w, h);
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// The resolution presets, named by the frame's short side (so 1080p is 1920×1080 at 16:9 and 1080×1920 at 9:16).
enum VideoResolution {
  p720('720p', 720),
  p1080('1080p', 1080),
  p1440('1440p', 1440),
  p2160('4K', 2160),
  custom('Custom', 0);

  const VideoResolution(this.label, this.shortSide);
  final String label;
  final int shortSide;
}

/// What the platform's H.264 encoder can take: the largest long and short sides.
class VideoEncoderCaps {
  const VideoEncoderCaps({required this.maxLong, required this.maxShort});
  final int maxLong, maxShort;

  /// [Assumption] used until the encoder answers: 4K UHD either way round.
  static const fallback = VideoEncoderCaps(maxLong: 3840, maxShort: 2160);
}

/// The smallest side a frame may have.
const int kVideoMinSide = 128;

/// [n] rounded to the nearest even number (H.264 with 4:2:0 colour needs even sides), at least 2.
int evenSide(num n) => math.max(2, (n / 2).round() * 2);

/// The frame size a preset gives for [aspect]: the short side as named, the long side from the ratio, both even.
(int, int) presetSize(VideoAspect aspect, VideoResolution res) {
  final short = res.shortSide;
  if (aspect.ratio >= 1) return (evenSide(short * aspect.ratio), evenSide(short));
  return (evenSide(short), evenSide(short / aspect.ratio));
}

/// Why [width] × [height] can't be encoded, or null when it can.
String? validateVideoSize(int width, int height, VideoEncoderCaps caps) {
  if (width <= 0 || height <= 0) return 'Width and height must be above 0.';
  if (width.isOdd || height.isOdd) return 'Width and height must be even numbers.';
  if (math.min(width, height) < kVideoMinSide) return 'Each side must be at least $kVideoMinSide pixels.';
  final long = math.max(width, height), short = math.min(width, height);
  if (long > caps.maxLong || short > caps.maxShort) {
    return "This device's encoder takes at most ${caps.maxLong} × ${caps.maxShort}.";
  }
  return null;
}

/// The whole setup.
class MusicVideoOptions {
  MusicVideoOptions({
    Set<VideoShot>? shots,
    this.style = VideoStyle.energetic,
    this.range = VideoRange.song,
    VideoAspect? aspect,
    this.resolution = VideoResolution.p1080,
    this.customWidth = 1080,
    this.customHeight = 1920,
    this.fps = 30,
    this.titleCard = true,
    this.title = '',
    this.artist = '',
    this.seed = 1,
    this.smoothFollow = false,
  })  : shots = shots ?? {...VideoShot.values},
        aspect = aspect ?? VideoAspect.portrait;

  static const frameRates = [30, 60];

  Set<VideoShot> shots;
  VideoStyle style;
  VideoRange range;
  VideoAspect aspect;
  VideoResolution resolution;
  int customWidth, customHeight;
  int fps;
  bool titleCard;
  String title, artist;

  /// The director's seed: the same seed and song always give the same video.
  int seed;

  /// Smooth follow (owner, 2026-11-11; off by default): the arrangement and piano-roll shots hold the playhead a
  /// third of the way in and scroll the song under it, their zoom held through each shot and eased only at a cut.
  /// Off keeps the spring camera.
  bool smoothFollow;

  MusicVideoOptions copy() => MusicVideoOptions(
        shots: {...shots}, style: style, range: range, aspect: aspect, resolution: resolution,
        customWidth: customWidth, customHeight: customHeight, fps: fps, titleCard: titleCard, title: title,
        artist: artist, seed: seed, smoothFollow: smoothFollow);

  /// The frame's width and height.
  (int, int) get size => resolution == VideoResolution.custom ? (customWidth, customHeight) : presetSize(aspect, resolution);

  /// Why these options can't render, or null when they can.
  String? problem(VideoEncoderCaps caps) {
    if (shots.isEmpty) return 'Switch on at least one shot.';
    if (!frameRates.contains(fps)) return 'The frame rate must be 30 or 60.';
    if (resolution != VideoResolution.custom && !aspect.valid) {
      return 'The ratio must be whole numbers up to ${VideoAspect.maxTerm}, at most 4:1 either way.';
    }
    final (w, h) = size;
    return validateVideoSize(w, h, caps);
  }

  /// A sensible bitrate for the size and frame rate (about 0.1 bit per pixel per frame), in bits per second.
  int get bitrate {
    final (w, h) = size;
    return (w * h * fps * 0.1).round().clamp(2000000, 80000000);
  }
}

/// Ties frames to song time: frame N shows N / fps seconds after the range's start (never wall time).
class FrameClock {
  const FrameClock({required this.fps, required this.startStep, required this.endStep, required this.bpm});
  final int fps;
  final double startStep, endStep, bpm;

  /// Seconds per sixteenth step at the project's tempo.
  double get secondsPerStep => 15.0 / bpm;
  double get durationSeconds => (endStep - startStep) * secondsPerStep;

  /// Frames in the range (the last frame starts before its end).
  int get frameCount => math.max(1, (durationSeconds * fps - 1e-9).ceil());

  double secondsAt(int frame) => frame / fps;
  double stepAt(int frame) => startStep + secondsAt(frame) / secondsPerStep;
  double stepAtSeconds(double s) => startStep + s / secondsPerStep;
  double secondsAtStep(double step) => (step - startStep) * secondsPerStep;
}
