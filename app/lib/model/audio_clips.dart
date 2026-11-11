// Audio on tracks (API 18, docs/engine.md "Audio clips"): the project's audio files, a track's input and its audio
// clips, their engine JSON, and the pure edits (split, trim, fades, takes placed with latency compensation).
import 'dart:math' as math;

/// A fade's shape, as the engine names it.
enum FadeCurve {
  slow('slow', 'Slow'),
  sCurve('s_curve', 'S-curve'),
  linear('linear', 'Linear'),
  equalPower('equal_power', 'Equal power'),
  fast('fast', 'Fast');

  const FadeCurve(this.json, this.label);
  final String json, label;

  static FadeCurve parse(Object? v) => values.where((c) => c.json == v).firstOrNull ?? FadeCurve.linear;

  /// How high the fade stands halfway through (0..1): the curve handle sits there.
  double get mid => switch (this) {
        FadeCurve.slow => 0.25,
        FadeCurve.sCurve => 0.5,
        FadeCurve.linear => 0.5,
        FadeCurve.equalPower => math.sin(math.pi / 4),
        FadeCurve.fast => 0.75,
      };

  /// The gain at [u] (0..1 through a fade in), as the engine plays it.
  double at(double u) {
    final x = u.clamp(0.0, 1.0);
    return switch (this) {
      FadeCurve.linear => x,
      FadeCurve.equalPower => math.sin(x * math.pi / 2),
      FadeCurve.sCurve => 0.5 - 0.5 * math.cos(x * math.pi),
      FadeCurve.fast => 1 - (1 - x) * (1 - x),
      FadeCurve.slow => x * x,
    };
  }
}

/// How a clip follows the tempo: [fixed] plays at the file's speed (seconds), [musical] stays locked to the bars.
enum AudioClipMode { fixed, musical }

/// How a clip changes speed: [wsola] keeps pitch, [varispeed] resamples (pitch moves with speed).
enum AudioStretch { wsola, varispeed }

/// One audio file the project uses: copied into the project's storage on import, referenced by absolute path.
class AudioAssetDoc {
  AudioAssetDoc({required this.id, required this.path, required this.name, this.bpm, this.seconds = 0,
      this.channels = 0, this.sourceRate = 0, this.recorded = false});
  final String id;
  String path, name;

  /// The source tempo musical clips default to (null: none known).
  double? bpm;

  /// What the engine read at import (0: not loaded yet).
  double seconds;
  int channels, sourceRate;

  /// A take recorded in the app (Files lists it under Recordings).
  bool recorded;

  Map<String, dynamic> toJson() => {
        'id': id, 'path': path, 'name': name,
        if (bpm != null) 'bpm': bpm,
        if (seconds > 0) 'seconds': seconds,
        if (channels > 0) 'channels': channels,
        if (sourceRate > 0) 'source_rate': sourceRate,
        if (recorded) 'recorded': true,
      };

  Map<String, dynamic> toEngineJson() => {'id': id, 'path': path, if (bpm != null) 'bpm': bpm};

  static AudioAssetDoc? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _text(j['id'], 64), path = _text(j['path'], 4096);
    if (id.isEmpty || path.isEmpty) return null;
    final bpm = j['bpm'];
    return AudioAssetDoc(id: id, path: path, name: _text(j['name'], 128).isEmpty ? _baseName(path) : _text(j['name'], 128),
        bpm: bpm is num && bpm.isFinite && bpm > 0 ? bpm.toDouble().clamp(20.0, 999.0) : null,
        seconds: _num(j['seconds'], 0, 0, 3 * 3600), channels: _num(j['channels'], 0, 0, 2).round(),
        sourceRate: _num(j['source_rate'], 0, 0, 768000).round(), recorded: j['recorded'] == true);
  }
}

/// A track's audio input: which device channels it records and hears, and whether it is armed.
class AudioInputDoc {
  AudioInputDoc({this.channel = 0, this.channels = 1, this.monitor = 'auto', this.armed = false});

  /// The first device channel, from 0.
  int channel;

  /// 1 (mono, heard in both sides) or 2.
  int channels;

  /// off, on (always) or auto (while armed and stopped, or armed while recording).
  String monitor;
  bool armed;

  static const monitors = ['off', 'auto', 'on'];

  Map<String, dynamic> toJson() => {'channel': channel, 'channels': channels, 'monitor': monitor, 'armed': armed};

  static AudioInputDoc? fromJson(Object? j) {
    if (j is! Map) return null;
    final monitor = j['monitor'];
    return AudioInputDoc(channel: _num(j['channel'], 0, 0, 31).round(), channels: j['channels'] == 2 ? 2 : 1,
        monitor: monitors.contains(monitor) ? monitor as String : 'auto', armed: j['armed'] == true);
  }

  AudioInputDoc copy() => AudioInputDoc(channel: channel, channels: channels, monitor: monitor, armed: armed);

  /// "In 1", "In 1+2".
  String get label => channels == 2 ? 'In ${channel + 1}+${channel + 2}' : 'In ${channel + 1}';
}

/// An audio clip on a track: a window onto an asset, placed in steps (fractional: a take lands off the grid).
class AudioClipDoc {
  AudioClipDoc({
    required this.id,
    required this.assetId,
    this.startSteps = 0,
    double lengthSteps = 16,
    this.lengthSeconds = 0,
    this.offsetSeconds = 0,
    this.gain = 1,
    this.fadeIn = 0,
    this.fadeInCurve = FadeCurve.linear,
    this.fadeOut = 0,
    this.fadeOutCurve = FadeCurve.linear,
    this.reverse = false,
    this.loop = false,
    this.loopStart = 0,
    this.loopEnd = 0,
    this.pitch = 0,
    this.mode = AudioClipMode.fixed,
    this.stretch = AudioStretch.wsola,
    this.sourceBpm,
    this.mute = false,
    this.lock = false,
    this.name,
    this.color,
    List<String>? takes,
  })  : _lengthSteps = lengthSteps, // ignore: prefer_initializing_formals
        takes = takes ?? [];

  final String id;
  String assetId;
  double startSteps;
  double _lengthSteps;

  /// A fixed clip's length in seconds of output: it keeps its time at any tempo ([lengthAt]).
  double lengthSeconds;
  double offsetSeconds;

  /// Linear 0..[maxGain].
  double gain;
  double fadeIn, fadeOut;
  FadeCurve fadeInCurve, fadeOutCurve;
  bool reverse, loop;
  double loopStart, loopEnd;

  /// Semitones −48..48.
  double pitch;
  AudioClipMode mode;
  AudioStretch stretch;
  double? sourceBpm;
  bool mute, lock;
  String? name;
  int? color;

  /// Loop-recorded takes (asset ids, oldest first): the clip plays [assetId], one of them.
  List<String> takes;

  static const double maxGain = 3.9810717055349722; // +12 dB
  static const double minLengthSteps = 1 / 16;

  bool get fixed => mode == AudioClipMode.fixed;

  /// The clip's length in steps at [bpm]: a fixed clip's seconds at that tempo, a musical one's own steps.
  double lengthAt(double bpm) => fixed ? lengthSeconds * bpm / 15 : _lengthSteps;

  double endAt(double bpm) => startSteps + lengthAt(bpm);

  void setLength(double steps, double bpm) {
    final s = math.max(minLengthSteps, steps);
    if (fixed) {
      lengthSeconds = s * 15 / bpm;
    } else {
      _lengthSteps = s;
    }
  }

  /// How fast the source is read beside its own speed because of [pitch] (varispeed only).
  double get pitchRate => stretch == AudioStretch.varispeed ? math.pow(2, pitch / 12).toDouble() : 1;

  /// The source tempo a musical clip follows: its own, else the asset's, else the project's.
  double sourceTempo(double bpm, double? assetBpm) => sourceBpm ?? assetBpm ?? bpm;

  /// Seconds of the file one step of the clip reads at [bpm].
  double sourcePerStep(double bpm, double? assetBpm) =>
      (fixed ? 15 / bpm : 15 / sourceTempo(bpm, assetBpm)) * pitchRate;

  /// How much of the file the clip reads, in seconds.
  double sourceSeconds(double bpm, double? assetBpm) => lengthAt(bpm) * sourcePerStep(bpm, assetBpm);

  String get gainLabel => gainDb(gain);

  Map<String, dynamic> toJson() => {
        'id': id, 'asset': assetId, 'start_steps': startSteps, 'length_steps': _lengthSteps,
        if (fixed) 'length_seconds': lengthSeconds,
        'offset_seconds': offsetSeconds, 'gain': gain,
        'fade_in_seconds': fadeIn, 'fade_in_curve': fadeInCurve.json,
        'fade_out_seconds': fadeOut, 'fade_out_curve': fadeOutCurve.json,
        'reverse': reverse, 'loop': loop, 'loop_start_seconds': loopStart, 'loop_end_seconds': loopEnd,
        'pitch': pitch, 'mode': mode.name, 'stretch': stretch.name,
        if (sourceBpm != null) 'source_bpm': sourceBpm,
        'mute': mute,
        if (lock) 'lock': true,
        if (name != null) 'name': name,
        if (color != null) 'color': color,
        if (takes.isNotEmpty) 'takes': takes,
      };

  /// The engine's clip at [bpm] (docs/engine.md "Audio clips"); a fixed clip's length in steps comes from its
  /// seconds at that tempo, so a tempo change never changes how long it plays.
  Map<String, dynamic> toEngineJson(double bpm) => {
        'id': id, 'asset': assetId, 'start_steps': startSteps, 'length_steps': lengthAt(bpm),
        'offset_seconds': offsetSeconds, 'gain': gain,
        'fade_in_seconds': fadeIn, 'fade_in_curve': fadeInCurve.json,
        'fade_out_seconds': fadeOut, 'fade_out_curve': fadeOutCurve.json,
        'reverse': reverse, 'loop': loop, 'loop_start_seconds': loopStart, 'loop_end_seconds': loopEnd,
        'pitch': pitch, 'mode': mode.name, 'stretch': stretch.name,
        if (sourceBpm != null) 'source_bpm': sourceBpm,
        'mute': mute,
      };

  static AudioClipDoc? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = _text(j['id'], 64), asset = _text(j['asset'], 64);
    if (id.isEmpty || asset.isEmpty) return null;
    final bpm = j['source_bpm'];
    final mode = j['mode'] == 'musical' ? AudioClipMode.musical : AudioClipMode.fixed;
    return AudioClipDoc(
      id: id,
      assetId: asset,
      startSteps: _num(j['start_steps'], 0, -1e9, 2147483647),
      lengthSteps: _num(j['length_steps'], 16, minLengthSteps, 2147483647),
      lengthSeconds: _num(j['length_seconds'], 0, 0, 3 * 3600 * 4),
      offsetSeconds: _num(j['offset_seconds'], 0, 0, 3 * 3600),
      gain: _num(j['gain'], 1, 0, maxGain),
      fadeIn: _num(j['fade_in_seconds'], 0, 0, 3600),
      fadeInCurve: FadeCurve.parse(j['fade_in_curve']),
      fadeOut: _num(j['fade_out_seconds'], 0, 0, 3600),
      fadeOutCurve: FadeCurve.parse(j['fade_out_curve']),
      reverse: j['reverse'] == true,
      loop: j['loop'] == true,
      loopStart: _num(j['loop_start_seconds'], 0, 0, 3 * 3600),
      loopEnd: _num(j['loop_end_seconds'], 0, 0, 3 * 3600),
      pitch: _num(j['pitch'], 0, -48, 48),
      mode: mode,
      stretch: j['stretch'] == 'varispeed' ? AudioStretch.varispeed : AudioStretch.wsola,
      sourceBpm: bpm is num && bpm.isFinite && bpm > 0 ? bpm.toDouble().clamp(20.0, 999.0) : null,
      mute: j['mute'] == true,
      lock: j['lock'] == true,
      name: switch (_text(j['name'], 128)) { '' => null, final n => n },
      color: switch (j['color']) { final int c when c >= 0 && c < 8 => c, _ => null },
      takes: [for (final t in (j['takes'] as List?) ?? const []) if (t is String && t.isNotEmpty) t].take(64).toList(),
    );
  }

  /// A fixed clip saved without its seconds (written by hand, or by an older build) takes them from the steps it
  /// saved, at [bpm] (the project's tempo when read).
  void ensureSeconds(double bpm) {
    if (fixed && lengthSeconds <= 0) lengthSeconds = _lengthSteps * 15 / bpm;
  }

  AudioClipDoc copyWith({required String id, double? startSteps}) =>
      AudioClipDoc.fromJson({...toJson(), 'id': id, 'start_steps': startSteps ?? this.startSteps})!
        ..lengthSeconds = lengthSeconds;
}

/// dB text for a linear gain: "-inf", "0.0 dB", "+3.5 dB".
String gainDb(double gain) {
  if (gain <= 0.000001) return '-inf dB';
  final db = 20 * math.log(gain) / math.ln10;
  return '${db > 0.05 ? '+' : ''}${db.toStringAsFixed(1)} dB';
}

double dbToGain(double db) => db <= -60 ? 0 : math.pow(10, db / 20).toDouble();
double gainToDb(double gain) => gain <= 0.000001 ? -60 : 20 * math.log(gain) / math.ln10;

// ---------- pure edits: the model and the tests share them ----------

/// Splits [clip] at song step [at]: [clip] keeps the left part (its fade in), the returned clip is the right part
/// (its fade out), reading on from where the left one stopped. Null when [at] is not inside the clip.
AudioClipDoc? splitAudioClip(AudioClipDoc clip, double at, String newId,
    {required double bpm, double? assetBpm, double assetSeconds = 0}) {
  final len = clip.lengthAt(bpm);
  final left = at - clip.startSteps;
  if (left <= AudioClipDoc.minLengthSteps / 2 || len - left <= AudioClipDoc.minLengthSteps / 2) return null;
  final right = clip.copyWith(id: newId, startSteps: at);
  right.offsetSeconds = wrapOffset(clip, clip.offsetSeconds + left * clip.sourcePerStep(bpm, assetBpm), assetSeconds);
  right.setLength(len - left, bpm);
  right.fadeIn = 0;
  right.takes = List.of(clip.takes);
  clip.setLength(left, bpm);
  clip.fadeOut = 0;
  final secondsLeft = left * 15 / bpm, secondsRight = (len - left) * 15 / bpm;
  clip.fadeIn = math.min(clip.fadeIn, secondsLeft);
  right.fadeOut = math.min(right.fadeOut, secondsRight);
  return right;
}

/// A source position past a looping clip's loop end comes back into the loop (the engine reads the file there).
double wrapOffset(AudioClipDoc clip, double offset, double assetSeconds) {
  if (!clip.loop) return offset;
  final end = clip.loopEnd > 0 ? clip.loopEnd : assetSeconds;
  final span = end - clip.loopStart;
  if (span <= 0 || offset < end) return offset;
  return clip.loopStart + (offset - clip.loopStart) % span;
}

/// Moves [clip]'s left edge to [newStart] (steps), keeping the audio where it is in the song: the offset moves by
/// as much source. A clip can't start before its file (unless it loops) or reach past its end.
void trimAudioStart(AudioClipDoc clip, double newStart, {required double bpm, double? assetBpm}) {
  final per = clip.sourcePerStep(bpm, assetBpm);
  final end = clip.endAt(bpm);
  var start = math.min(newStart, end - AudioClipDoc.minLengthSteps);
  if (!clip.loop && per > 0) start = math.max(start, clip.startSteps - clip.offsetSeconds / per);
  final moved = start - clip.startSteps;
  clip.offsetSeconds = math.max(0, clip.offsetSeconds + moved * per);
  clip.startSteps = start;
  clip.setLength(end - start, bpm);
}

/// The longest [clip] can be without looping: the rest of the file from its offset (0 when unknown).
double maxUnloopedSteps(AudioClipDoc clip, double assetSeconds, {required double bpm, double? assetBpm}) {
  final per = clip.sourcePerStep(bpm, assetBpm);
  if (assetSeconds <= 0 || per <= 0) return 0;
  return math.max(0, (assetSeconds - clip.offsetSeconds) / per);
}

/// Sets [clip]'s right edge to [newLength] steps. Past the file's end it loops the file (REAPER's loop extend);
/// without a known length it just takes the length.
void resizeAudioClip(AudioClipDoc clip, double newLength, double assetSeconds, {required double bpm, double? assetBpm}) {
  final max = maxUnloopedSteps(clip, assetSeconds, bpm: bpm, assetBpm: assetBpm);
  final len = math.max(AudioClipDoc.minLengthSteps, newLength);
  if (!clip.loop && max > 0 && len > max + 1e-6) {
    clip.loop = true;
    clip.loopStart = 0;
    clip.loopEnd = 0;
  }
  clip.setLength(len, bpm);
  final secs = len * 15 / bpm;
  clip.fadeIn = math.min(clip.fadeIn, secs);
  clip.fadeOut = math.min(clip.fadeOut, secs - clip.fadeIn);
}

/// Turns [clip] around: it reads the file backwards over the same part of it (offsets then count from the end).
void reverseAudioClip(AudioClipDoc clip, double assetSeconds, {required double bpm, double? assetBpm}) {
  if (!clip.loop && assetSeconds > 0) {
    final used = clip.sourceSeconds(bpm, assetBpm);
    clip.offsetSeconds = math.max(0, assetSeconds - (clip.offsetSeconds + used));
  }
  clip.reverse = !clip.reverse;
  final (a, ac, b, bc) = (clip.fadeIn, clip.fadeInCurve, clip.fadeOut, clip.fadeOutCurve);
  clip.fadeIn = b;
  clip.fadeInCurve = bc;
  clip.fadeOut = a;
  clip.fadeOutCurve = ac;
}

/// Switches [clip] between fixed and musical, so it sounds the same at the tempo now.
void setAudioClipMode(AudioClipDoc clip, AudioClipMode mode, {required double bpm, double? assetBpm}) {
  if (clip.mode == mode) return;
  final steps = clip.lengthAt(bpm);
  if (mode == AudioClipMode.musical) {
    clip.sourceBpm ??= assetBpm ?? bpm;
    clip.mode = mode;
    // As loud and as long as before: the file now moves bpm / source tempo times real time.
    clip.setLength(steps * bpm / clip.sourceTempo(bpm, assetBpm), bpm);
  } else {
    final source = clip.sourceSeconds(bpm, assetBpm);
    clip.mode = mode;
    clip.lengthSeconds = source / clip.pitchRate;
  }
}

/// Changes [clip]'s pitch. A fixed varispeed clip reads faster or slower, so its length follows (engine docs).
void setAudioClipPitch(AudioClipDoc clip, double semitones) {
  final before = clip.pitchRate;
  clip.pitch = semitones.clamp(-48.0, 48.0).toDouble();
  if (clip.fixed && clip.stretch == AudioStretch.varispeed) clip.lengthSeconds *= before / clip.pitchRate;
}

/// A recorded take as a clip at its song position. A take whose start the latency put before the song's start
/// begins at 0 with that much trimmed off its offset.
AudioClipDoc clipForTake({required String id, required String assetId, required double startSteps,
    required double seconds, required double bpm}) {
  var start = startSteps, offset = 0.0;
  if (start < 0) {
    offset = -start * 15 / bpm;
    start = 0;
  }
  return AudioClipDoc(id: id, assetId: assetId, startSteps: start,
      lengthSeconds: math.max(0.001, seconds - offset), offsetSeconds: math.min(offset, math.max(0, seconds)));
}

String _text(Object? raw, int max) {
  if (raw is! String) return '';
  final v = raw.trim();
  return v.length > max ? v.substring(0, max) : v;
}

double _num(Object? v, double or, double lo, double hi) =>
    v is num && v.isFinite ? v.toDouble().clamp(lo, hi).toDouble() : or;

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;
