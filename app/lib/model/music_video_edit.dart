// The music video editor's model (owner, 2026-11-12): shots on a lane under the song's bars, each with a split layout
// of views, a look per panel and an effect stack; snapping, lane and list edits, and the versioned save format.
import 'dart:math' as math;

import 'music_video.dart';
import 'music_video_director.dart' show VideoTransition;
import 'music_video_meters.dart';
import 'music_video_overlay.dart';

// ---------------------------------------------------------------------------------------------------------------
// Snapping

/// What a lane edit snaps to: a sixteenth step, a beat (four steps) or the project's bar.
enum VideoSnap {
  step('Step'),
  beat('Beat'),
  bar('Bar');

  const VideoSnap(this.label);
  final String label;

  /// The grid in steps for a bar of [stepsPerBar].
  double grid(int stepsPerBar) => switch (this) {
        VideoSnap.step => 1,
        VideoSnap.beat => 4,
        VideoSnap.bar => math.max(1, stepsPerBar).toDouble(),
      };
}

/// [step] moved to the nearest line of [snap]'s grid (bars counted from the song's start).
double snapStep(double step, VideoSnap snap, int stepsPerBar) {
  final g = snap.grid(stepsPerBar);
  return (step / g).round() * g;
}

// ---------------------------------------------------------------------------------------------------------------
// Layouts

/// A panel's place in the frame, as fractions of its width and height.
class PanelRect {
  const PanelRect(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  double get width => right - left;
  double get height => bottom - top;

  /// Between [a] and [b] at [t] 0..1.
  static PanelRect lerp(PanelRect a, PanelRect b, double t) => PanelRect(
      a.left + (b.left - a.left) * t, a.top + (b.top - a.top) * t, a.right + (b.right - a.right) * t,
      a.bottom + (b.bottom - a.bottom) * t);

  /// The rect folded to nothing at its own right edge (a panel growing in or folding away).
  PanelRect get folded => PanelRect(right, top, right, bottom);

  @override
  bool operator ==(Object other) =>
      other is PanelRect && other.left == left && other.top == top && other.right == right && other.bottom == bottom;
  @override
  int get hashCode => Object.hash(left, top, right, bottom);
  @override
  String toString() => 'PanelRect($left, $top, $right, $bottom)';
}

/// The split presets (owner, 2026-11-12): full, top/bottom, side by side, one big view over a strip, and 2 × 2.
enum VideoLayoutPreset {
  full('Full', 1),
  topBottom('Top / bottom', 2),
  sideBySide('Side by side', 2),
  bigStrip('Big + strip', 2),
  grid('2 × 2', 4);

  const VideoLayoutPreset(this.label, this.panels);
  final String label;
  final int panels;

  /// Where its dividers sit when first chosen ([VideoLayout.split] then [VideoLayout.split2]).
  (double, double) get defaultSplits => switch (this) {
        VideoLayoutPreset.bigStrip => (0.76, 0.5),
        _ => (0.5, 0.5),
      };
}

/// A draggable divider: [vertical] lines move across x, the others across y; [index] 0 is [VideoLayout.split] and
/// 1 [VideoLayout.split2]; it runs from [from] to [to] along its length (fractions of the frame).
typedef VideoDivider = ({bool vertical, int index, double at, double from, double to});

/// A shot's layout: a preset, its dividers and one panel per place.
class VideoLayout {
  VideoLayout({this.preset = VideoLayoutPreset.full, double? split, double? split2, List<VideoPanel>? panels})
      : split = (split ?? preset.defaultSplits.$1).clamp(minSplit, maxSplit).toDouble(),
        split2 = (split2 ?? preset.defaultSplits.$2).clamp(minSplit, maxSplit).toDouble(),
        panels = _fit(preset, panels ?? const []);

  /// One view filling the frame.
  factory VideoLayout.single(VideoShot view) => VideoLayout(panels: [VideoPanel(view: view)]);

  /// How close a divider may come to the frame's edge.
  static const minSplit = 0.15, maxSplit = 0.85;

  final VideoLayoutPreset preset;

  /// The main divider (x for side by side and the grid's columns, y for the others) and the grid's rows.
  double split, split2;
  final List<VideoPanel> panels;

  /// The views a preset fills its new places with, in order (the owner's example: the arrangement big, the mixer
  /// along the bottom).
  static const _fill = [VideoShot.flythrough, VideoShot.mixer, VideoShot.pianoRoll, VideoShot.devices];

  static List<VideoPanel> _fit(VideoLayoutPreset preset, List<VideoPanel> given) {
    final out = [for (final p in given.take(preset.panels)) p];
    for (var i = out.length; i < preset.panels; i++) {
      final used = {for (final p in out) p.view};
      out.add(VideoPanel(view: _fill.firstWhere((v) => !used.contains(v), orElse: () => _fill[i % _fill.length])));
    }
    return out;
  }

  /// The same panels (in order) in [p]'s places, its dividers at their first places.
  VideoLayout withPreset(VideoLayoutPreset p) => VideoLayout(preset: p, panels: [for (final x in panels) x.copy()]);

  VideoLayout copy() =>
      VideoLayout(preset: preset, split: split, split2: split2, panels: [for (final p in panels) p.copy()]);

  /// Each panel's place, in the order of [panels].
  List<PanelRect> rects() => switch (preset) {
        VideoLayoutPreset.full => const [PanelRect(0, 0, 1, 1)],
        VideoLayoutPreset.topBottom || VideoLayoutPreset.bigStrip => [PanelRect(0, 0, 1, split), PanelRect(0, split, 1, 1)],
        VideoLayoutPreset.sideBySide => [PanelRect(0, 0, split, 1), PanelRect(split, 0, 1, 1)],
        VideoLayoutPreset.grid => [
            PanelRect(0, 0, split, split2), PanelRect(split, 0, 1, split2),
            PanelRect(0, split2, split, 1), PanelRect(split, split2, 1, 1),
          ],
      };

  /// The dividers that can be dragged.
  List<VideoDivider> dividers() => switch (preset) {
        VideoLayoutPreset.full => const [],
        VideoLayoutPreset.topBottom || VideoLayoutPreset.bigStrip => [(vertical: false, index: 0, at: split, from: 0, to: 1)],
        VideoLayoutPreset.sideBySide => [(vertical: true, index: 0, at: split, from: 0, to: 1)],
        VideoLayoutPreset.grid => [
            (vertical: true, index: 0, at: split, from: 0, to: 1),
            (vertical: false, index: 1, at: split2, from: 0, to: 1),
          ],
      };

  /// Moves divider [index] to [at] (kept off the edges).
  void setSplit(int index, double at) {
    final v = at.clamp(minSplit, maxSplit).toDouble();
    index == 0 ? split = v : split2 = v;
  }

  /// One sentence for the shot list: the preset and its views.
  String get summary => preset == VideoLayoutPreset.full
      ? panels.first.view.label
      : '${preset.label}: ${panels.map((p) => p.view.label).join(', ')}';

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        if (preset != VideoLayoutPreset.full) 'split': _r(split),
        if (preset == VideoLayoutPreset.grid) 'split2': _r(split2),
        'panels': [for (final p in panels) p.toJson()],
      };

  static VideoLayout fromJson(Object? j) {
    if (j is! Map) return VideoLayout.single(VideoShot.flythrough);
    final preset = _enum(VideoLayoutPreset.values, j['preset'], VideoLayoutPreset.full);
    return VideoLayout(
      preset: preset,
      split: _num(j['split']),
      split2: _num(j['split2']),
      panels: [for (final p in _list(j['panels']).take(preset.panels)) VideoPanel.fromJson(p)],
    );
  }
}

/// One place in a layout: the view it shows and how (owner, 2026-11-12: a view per panel, its own look).
class VideoPanel {
  VideoPanel({required this.view, VideoLook? look, this.trackId, this.bars, this.fullKeyboard = false,
      Set<String>? hiddenTracks})
      : look = look ?? VideoLook(),
        hiddenTracks = hiddenTracks ?? {};

  VideoShot view;
  VideoLook look;

  /// The track the view looks at (the piano roll's clip, the mixer's focus strip, the device), or null to let the
  /// director pick what is busiest.
  String? trackId;

  /// How many bars the view shows across (the arrangement and piano roll) or how far ahead notes fall from (falling
  /// notes: the fall speed), or null for the view's own default.
  double? bars;

  /// Falling notes: all 88 keys instead of the range the song's notes use.
  bool fullKeyboard;

  /// Falling notes: tracks switched off (their notes don't fall).
  Set<String> hiddenTracks;

  static const minBars = 0.25, maxBars = 32.0;

  VideoPanel copy() => VideoPanel(view: view, look: look.copy(), trackId: trackId, bars: bars,
      fullKeyboard: fullKeyboard, hiddenTracks: {...hiddenTracks});

  Map<String, dynamic> toJson() => {
        'view': view.name,
        if (!look.isDefault) 'look': look.toJson(),
        if (trackId != null) 'track': trackId,
        if (bars != null) 'bars': _r(bars!),
        if (fullKeyboard) 'full_keyboard': true,
        if (hiddenTracks.isNotEmpty) 'hidden_tracks': [...hiddenTracks]..sort(),
      };

  static VideoPanel fromJson(Object? j) {
    if (j is! Map) return VideoPanel(view: VideoShot.flythrough);
    final bars = _num(j['bars']);
    return VideoPanel(
      view: _enum(VideoShot.values, j['view'], VideoShot.flythrough),
      look: VideoLook.fromJson(j['look']),
      trackId: _str(j['track']),
      bars: bars?.clamp(minBars, maxBars).toDouble(),
      fullKeyboard: j['full_keyboard'] == true,
      hiddenTracks: {for (final t in _list(j['hidden_tracks']).take(kVideoMaxTracks)) ?_str(t)},
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Looks

/// The colours a panel draws notes, clips and meters in.
enum VideoPalette {
  tracks('Track colours'),
  accent('Theme accent'),
  mono('Mono'),
  warm('Warm'),
  cool('Cool');

  const VideoPalette(this.label);
  final String label;
}

/// How notes are drawn: the view's own shape, or one style for every view.
enum VideoNoteStyle {
  standard('Standard'),
  block('Blocks'),
  rounded('Rounded'),
  outline('Outline'),
  line('Lines');

  const VideoNoteStyle(this.label);
  final String label;
}

enum VideoBackground {
  theme('Theme'),
  black('Black'),
  panel('Panel'),
  gradient('Gradient');

  const VideoBackground(this.label);
  final String label;
}

/// How a panel's view looks (owner, 2026-11-12: colours or palette, note style, grid, glow, background).
class VideoLook {
  VideoLook({this.palette = VideoPalette.tracks, this.noteStyle = VideoNoteStyle.standard, this.grid = true,
      double glow = 1, this.background = VideoBackground.theme})
      : glow = glow.clamp(0.0, maxGlow).toDouble();

  VideoPalette palette;
  VideoNoteStyle noteStyle;
  bool grid;

  /// The glow's strength: 1 as the theme draws it, 0 none, up to [maxGlow].
  double glow;
  VideoBackground background;

  static const maxGlow = 2.0;

  bool get isDefault =>
      palette == VideoPalette.tracks && noteStyle == VideoNoteStyle.standard && grid && glow == 1 &&
      background == VideoBackground.theme;

  VideoLook copy() => VideoLook(palette: palette, noteStyle: noteStyle, grid: grid, glow: glow, background: background);

  Map<String, dynamic> toJson() => {
        'palette': palette.name,
        'notes': noteStyle.name,
        'grid': grid,
        'glow': _r(glow),
        'background': background.name,
      };

  static VideoLook fromJson(Object? j) {
    if (j is! Map) return VideoLook();
    return VideoLook(
      palette: _enum(VideoPalette.values, j['palette'], VideoPalette.tracks),
      noteStyle: _enum(VideoNoteStyle.values, j['notes'], VideoNoteStyle.standard),
      grid: j['grid'] != false,
      glow: _num(j['glow']) ?? 1,
      background: _enum(VideoBackground.values, j['background'], VideoBackground.theme),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Effects

/// The effects a shot's stack can hold (owner, 2026-11-12).
enum VideoEffectKind {
  glow('Glow', 'Blooms the bright parts'),
  shake('Shake', 'Jolts the frame'),
  punch('Zoom punch', 'Pushes in and springs back'),
  tint('Tint', 'Washes the frame in a colour'),
  blur('Blur', 'Softens the frame'),
  vignette('Vignette', 'Darkens the edges'),
  chroma('Chromatic shift', 'Splits red and blue apart'),
  strobe('Strobe', 'Flashes the frame');

  const VideoEffectKind(this.label, this.description);
  final String label, description;
}

/// What an effect's amount follows: held, a pulse on each beat or bar, the mix's loudness or one track's.
enum VideoDrive {
  steady('Steady'),
  beat('Beat'),
  offbeat('Off-beat'),
  bar('Bar'),
  master('Mix loudness'),
  track('Track loudness');

  const VideoDrive(this.label);
  final String label;
}

/// The tint and strobe colours: the theme's accents (the painter reads them from the theme).
enum VideoEffectColor { accent, blue, green, yellow, violet, white }

/// The effects' beat presets (owner, 2026-11-12: "pulse on every beat", "flash on the downbeat"): each sets the
/// drive, its pulse length and the amount.
enum VideoEffectPreset {
  everyBeat('Pulse on every beat', VideoDrive.beat, 0.5, 0.6),
  downbeat('Flash on the downbeat', VideoDrive.bar, 0.2, 0.8),
  offbeat('Hit the off-beat', VideoDrive.offbeat, 0.35, 0.6),
  swell('Swell over the bar', VideoDrive.bar, 1.0, 0.7),
  mix('Follow the mix', VideoDrive.master, 0.5, 0.8),
  steady('Steady', VideoDrive.steady, 0.5, 0.5);

  const VideoEffectPreset(this.label, this.drive, this.decay, this.amount);
  final String label;
  final VideoDrive drive;
  final double decay, amount;

  void apply(VideoEffect e) {
    e
      ..drive = drive
      ..decay = decay
      ..amount = amount;
  }

  /// The preset [e] matches, or null.
  static VideoEffectPreset? of(VideoEffect e) => values
      .where((p) => p.drive == e.drive && (p.decay - e.decay).abs() < 1e-6 && (p.amount - e.amount).abs() < 1e-6)
      .firstOrNull;

  /// The drives that pulse on the beat grid (the lane marks their hits).
  static bool beats(VideoDrive d) => d == VideoDrive.beat || d == VideoDrive.offbeat || d == VideoDrive.bar;
}

/// One effect in a shot's stack (like an audio FX slot: on or bypassed, an amount and its settings).
class VideoEffect {
  VideoEffect({required this.kind, double amount = 0.5, this.drive = VideoDrive.steady, this.trackId, this.on = true,
      this.color = VideoEffectColor.accent, double decay = 0.5, this.panel})
      : amount = amount.clamp(0.0, 1.0).toDouble(),
        decay = decay.clamp(0.05, 1.0).toDouble();

  VideoEffectKind kind;
  double amount;
  VideoDrive drive;

  /// The track whose loudness drives it ([VideoDrive.track]).
  String? trackId;
  bool on;
  VideoEffectColor color;

  /// How long a beat or bar pulse lasts, as a fraction of the beat or bar.
  double decay;

  /// What it applies to: null for the whole shot (the default), else one panel of the layout by index. A panel the
  /// layout no longer has means the whole shot.
  int? panel;

  /// The panel it applies to in a layout of [panels] places, or null for the whole shot.
  int? panelIn(int panels) => panel != null && panel! >= 0 && panel! < panels && panels > 1 ? panel : null;

  /// Strobe flashes the frame: the editor warns once about photosensitivity and marks it.
  bool get flashes => kind == VideoEffectKind.strobe;

  VideoEffect copy() => VideoEffect(kind: kind, amount: amount, drive: drive, trackId: trackId, on: on, color: color,
      decay: decay, panel: panel);

  /// How strongly it acts at [step] with [levels]: [amount] times its drive (0..1).
  double strength(double step, VideoLevels levels, int stepsPerBar) {
    if (!on) return 0;
    double pulseAt(double at, double period) {
      final phase = ((at % period) + period) % period / period;
      return phase >= decay ? 0 : math.pow(1 - phase / decay, 2).toDouble();
    }

    double pulse(double period) => pulseAt(step, period);
    double pulse4(double at) => pulseAt(at, 4);

    final d = switch (drive) {
      VideoDrive.steady => 1.0,
      VideoDrive.beat => pulse(4),
      VideoDrive.offbeat => pulse4(step - 2),
      VideoDrive.bar => pulse(math.max(1, stepsPerBar).toDouble()),
      VideoDrive.master => (levels.rms * 2.5).clamp(0.0, 1.0).toDouble(),
      VideoDrive.track => ((levels.tracks[trackId] ?? 0) * 1.4).clamp(0.0, 1.0).toDouble(),
    };
    return amount * d;
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'amount': _r(amount),
        if (drive != VideoDrive.steady) 'drive': drive.name,
        if (trackId != null) 'track': trackId,
        if (!on) 'on': false,
        if (color != VideoEffectColor.accent) 'color': color.name,
        if (decay != 0.5) 'decay': _r(decay),
        if (panel != null) 'panel': panel,
      };

  static VideoEffect? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = _enumOrNull(VideoEffectKind.values, j['kind']);
    if (kind == null) return null; // an effect this version doesn't know
    return VideoEffect(
      kind: kind,
      amount: _num(j['amount']) ?? 0.5,
      drive: _enum(VideoDrive.values, j['drive'], VideoDrive.steady),
      trackId: _str(j['track']),
      on: j['on'] != false,
      color: _enum(VideoEffectColor.values, j['color'], VideoEffectColor.accent),
      decay: _num(j['decay']) ?? 0.5,
      panel: switch (_num(j['panel'])) { final double p when p >= 0 && p < 4 => p.round(), _ => null },
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Shots and the lane

/// One shot on the lane: where it starts and how long it is (song steps), its layout, effects and how it begins.
class VideoCut {
  VideoCut({required this.id, required this.start, required this.length, VideoLayout? layout, List<VideoEffect>? effects,
      this.transition = VideoTransition.cut, this.transitionSteps = 0, this.animateLayout = false, this.zoom = 1,
      this.reason = '', this.camera, List<VideoText>? texts, List<VideoImageLayer>? images})
      : layout = layout ?? VideoLayout.single(VideoShot.flythrough),
        effects = effects ?? [],
        texts = texts ?? [],
        images = images ?? [];

  final String id;
  double start, length;
  VideoLayout layout;
  List<VideoEffect> effects;

  /// How the shot replaces the one before, over [transitionSteps].
  VideoTransition transition;
  double transitionSteps;

  /// A layout change from the shot before animates (the panels slide to their new places) instead of cutting.
  bool animateLayout;

  /// The camera's opening zoom (1 shows the view's own width; the camera eases to 1 through the shot).
  double zoom;

  /// Why auto-cut put the cut here (an interval, a burst, a track, a drop), or empty.
  String reason;

  /// The keyframed camera over the shot (owner, 2026-11-12), or null for the auto camera.
  VideoCameraMove? camera;

  /// Text overlays and images shown through this shot.
  List<VideoText> texts;
  List<VideoImageLayer> images;

  double get end => start + length;

  VideoCut copy({String? id}) => VideoCut(id: id ?? this.id, start: start, length: length, layout: layout.copy(),
      effects: [for (final e in effects) e.copy()], transition: transition, transitionSteps: transitionSteps,
      animateLayout: animateLayout, zoom: zoom, reason: reason, camera: camera?.copy(),
      texts: [for (final x in texts) x.copy()], images: [for (final x in images) x.copy()]);

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': _r(start),
        'length': _r(length),
        'layout': layout.toJson(),
        if (effects.isNotEmpty) 'effects': [for (final e in effects) e.toJson()],
        if (transition != VideoTransition.cut) 'transition': transition.name,
        if (transitionSteps > 0) 'transition_steps': _r(transitionSteps),
        if (animateLayout) 'animate_layout': true,
        if (zoom != 1) 'zoom': _r(zoom),
        if (reason.isNotEmpty) 'reason': reason,
        if (camera != null) 'camera': camera!.toJson(),
        if (texts.isNotEmpty) 'texts': [for (final x in texts) x.toJson()],
        if (images.isNotEmpty) 'images': [for (final x in images) x.toJson()],
      };

  static VideoCut? fromJson(Object? j, double maxStep) {
    if (j is! Map) return null;
    final start = _num(j['start']), length = _num(j['length']);
    if (start == null || length == null || length <= 0) return null;
    final s = start.clamp(0.0, maxStep).toDouble();
    return VideoCut(
      id: _str(j['id']) ?? '',
      start: s,
      length: length.clamp(kVideoMinShotSteps, math.max(kVideoMinShotSteps, maxStep - s)).toDouble(),
      layout: VideoLayout.fromJson(j['layout']),
      effects: [for (final e in _list(j['effects']).take(kVideoMaxEffects)) ?VideoEffect.fromJson(e)],
      transition: _enum(VideoTransition.values, j['transition'], VideoTransition.cut),
      transitionSteps: (_num(j['transition_steps']) ?? 0).clamp(0.0, 64.0).toDouble(),
      animateLayout: j['animate_layout'] == true,
      zoom: (_num(j['zoom']) ?? 1).clamp(0.25, 4.0).toDouble(),
      reason: _str(j['reason']) ?? '',
      camera: VideoCameraMove.fromJson(j['camera']),
      texts: _ids([for (final x in _list(j['texts']).take(kVideoMaxTexts)) ?VideoText.fromJson(x)], 't'),
      images: _ids([for (final x in _list(j['images']).take(kVideoMaxImages)) ?VideoImageLayer.fromJson(x)], 'i'),
    );
  }
}

/// [items] with every missing or repeated id replaced (`prefix` + a number), for overlays read from a file.
List<T> _ids<T>(List<T> items, String prefix) {
  String idOf(Object? x) => x is VideoText ? x.id : (x as VideoImageLayer).id;
  T withId(T x, String id) => (x is VideoText ? x.copy(id: id) : (x as VideoImageLayer).copy(id: id)) as T;
  final seen = <String>{};
  var n = 1;
  return [
    for (final x in items)
      () {
        var id = idOf(x);
        if (id.isNotEmpty && seen.add(id)) return x;
        do {
          id = '$prefix${n++}';
        } while (!seen.add(id));
        return withId(x, id);
      }(),
  ];
}

/// The shortest a shot may be (one step), and the most shots, effects and tracks a saved video holds.
const double kVideoMinShotSteps = 1;
const int kVideoMaxShots = 4096, kVideoMaxEffects = 16, kVideoMaxTracks = 1024;

/// The lane: shots in time order that never overlap (gaps are allowed: the video shows the arrangement there).
class VideoTimeline {
  VideoTimeline([List<VideoCut>? cuts]) : cuts = cuts ?? [] {
    _sort();
    for (final c in this.cuts) {
      _seen(c.id);
    }
  }

  final List<VideoCut> cuts;
  int _next = 1;

  bool get isEmpty => cuts.isEmpty;

  String newId() => 's${_next++}';

  void _seen(String id) {
    final n = id.startsWith('s') ? int.tryParse(id.substring(1)) : null;
    if (n != null && n >= _next) _next = n + 1;
  }

  void _sort() => cuts.sort((a, b) => a.start.compareTo(b.start));

  VideoTimeline copy() => VideoTimeline([for (final c in cuts) c.copy()]).._next = _next;

  /// Takes [other]'s shots (copies) in place of these (undo and redo).
  void replaceWith(VideoTimeline other) {
    cuts
      ..clear()
      ..addAll([for (final c in other.cuts) c.copy()]);
    _next = math.max(_next, other._next);
  }

  VideoCut? byId(String id) => cuts.where((c) => c.id == id).firstOrNull;
  int indexOf(String id) => cuts.indexWhere((c) => c.id == id);

  /// The shot at [step], or null in a gap.
  VideoCut? at(double step) => cuts.where((c) => c.start <= step && c.end > step).firstOrNull;

  /// Where shot [i] may reach: the end of the one before (or [lo]) and the start of the next (or [hi]).
  (double, double) _room(int i, double lo, double hi) =>
      (i > 0 ? cuts[i - 1].end : lo, i + 1 < cuts.length ? cuts[i + 1].start : hi);

  /// The empty stretches of [lo, hi).
  List<(double, double)> gaps(double lo, double hi) {
    final out = <(double, double)>[];
    var t = lo;
    for (final c in cuts) {
      if (c.end <= lo) continue;
      if (c.start >= hi) break;
      if (c.start > t) out.add((t, c.start));
      t = math.max(t, c.end);
    }
    if (t < hi) out.add((t, hi));
    return out;
  }

  /// A new shot of [view] at [at] (snapped), a bar long or as long as the gap allows; null when [at] is inside a shot.
  VideoCut? add(double at, {required VideoSnap snap, required int stepsPerBar, required double hi,
      VideoShot view = VideoShot.flythrough, double lo = 0}) {
    final g = snap.grid(stepsPerBar);
    final start = math.max(lo, (at / g).floor() * g);
    if (this.at(start) != null || start >= hi) return null;
    final next = cuts.where((c) => c.start > start).firstOrNull?.start ?? hi;
    final length = math.min(math.max(g, stepsPerBar.toDouble()), next - start);
    if (length <= 0) return null;
    final c = VideoCut(id: newId(), start: start, length: length, layout: VideoLayout.single(view));
    cuts.add(c);
    _sort();
    return c;
  }

  /// Moves shot [id] to start at [start] (snapped), keeping its length, between its neighbours and inside [lo, hi).
  bool move(String id, double start, {required VideoSnap snap, required int stepsPerBar, double lo = 0,
      required double hi}) {
    final i = indexOf(id);
    if (i < 0) return false;
    final c = cuts[i];
    final (a, b) = _room(i, lo, hi);
    final s = snapStep(start, snap, stepsPerBar).clamp(a, math.max(a, b - c.length)).toDouble();
    if (s == c.start) return false;
    c.start = s;
    return true;
  }

  /// Moves shot [id]'s start edge to [start] (snapped), its end staying put.
  bool trimStart(String id, double start, {required VideoSnap snap, required int stepsPerBar, double lo = 0,
      required double hi}) {
    final i = indexOf(id);
    if (i < 0) return false;
    final c = cuts[i];
    final (a, _) = _room(i, lo, hi);
    // No room for the edge (the shot lies before the range's start or against its neighbour): nothing to do.
    if (c.end - kVideoMinShotSteps < a) return false;
    final s = snapStep(start, snap, stepsPerBar).clamp(a, c.end - kVideoMinShotSteps).toDouble();
    if (s == c.start) return false;
    c.length = c.end - s;
    c.start = s;
    return true;
  }

  /// Moves shot [id]'s end edge to [end] (snapped).
  bool trimEnd(String id, double end, {required VideoSnap snap, required int stepsPerBar, double lo = 0,
      required double hi}) {
    final i = indexOf(id);
    if (i < 0) return false;
    final c = cuts[i];
    final (_, b) = _room(i, lo, hi);
    // No room for the edge (the shot lies at or past the range's end): nothing to do.
    if (b < c.start + kVideoMinShotSteps) return false;
    final e = snapStep(end, snap, stepsPerBar).clamp(c.start + kVideoMinShotSteps, b).toDouble();
    if (e == c.end) return false;
    c.length = e - c.start;
    return true;
  }

  /// The cut markers: each place where one shot ends and the next starts, as the index of the later shot.
  List<int> cutMarkers() => [
        for (var i = 1; i < cuts.length; i++)
          if ((cuts[i].start - cuts[i - 1].end).abs() < 1e-9) i,
      ];

  /// Moves the cut between shot [i] − 1 and shot [i] to [step] (snapped): one ends and the other starts there.
  bool moveCut(int i, double step, {required VideoSnap snap, required int stepsPerBar}) {
    if (i <= 0 || i >= cuts.length) return false;
    final a = cuts[i - 1], b = cuts[i];
    final s = snapStep(step, snap, stepsPerBar)
        .clamp(a.start + kVideoMinShotSteps, b.end - kVideoMinShotSteps)
        .toDouble();
    if (s == b.start) return false;
    final end = b.end;
    a.length = s - a.start;
    b.start = s;
    b.length = end - s;
    return true;
  }

  /// Splits shot [id] at [at] (snapped); the right part is a copy with a new id. Null when [at] isn't inside it.
  VideoCut? split(String id, double at, {required VideoSnap snap, required int stepsPerBar}) {
    final c = byId(id);
    if (c == null) return null;
    final s = snapStep(at, snap, stepsPerBar);
    if (s <= c.start || s >= c.end) return null;
    final right = c.copy(id: newId())
      ..start = s
      ..length = c.end - s
      ..transition = VideoTransition.cut
      ..transitionSteps = 0
      ..animateLayout = false
      ..reason = '';
    c.length = s - c.start;
    cuts.add(right);
    _sort();
    return right;
  }

  bool delete(String id) {
    final i = indexOf(id);
    if (i < 0) return false;
    cuts.removeAt(i);
    return true;
  }

  /// A copy of shot [id] right after it: the later shots inside the range ([c.end, hi)) move along by its length,
  /// those pushed past [hi] cut short or dropped. Shots already past [hi] stay as they are. Null when there is no
  /// room before [hi].
  VideoCut? duplicate(String id, {required double hi}) {
    final i = indexOf(id);
    if (i < 0) return null;
    final c = cuts[i];
    if (c.end >= hi) return null;
    final len = c.length;
    final pushed = [for (final x in cuts.sublist(i + 1)) if (x.start >= c.end && x.start < hi) x];
    for (final x in pushed) {
      x.start += len;
    }
    cuts.removeWhere((x) => pushed.contains(x) && x.start >= hi);
    for (final x in pushed) {
      if (x.end > hi) x.length = hi - x.start;
    }
    final dup = c.copy(id: newId())..start = c.end;
    dup.length = math.min(len, hi - dup.start);
    cuts.add(dup);
    _sort();
    return dup;
  }

  /// Sets shot [id]'s start and length from the list (snapped, inside its neighbours); false when nothing changed.
  bool setSpan(String id, {double? start, double? length, required VideoSnap snap, required int stepsPerBar,
      double lo = 0, required double hi}) {
    final c = byId(id);
    if (c == null) return false;
    var changed = false;
    if (start != null) changed = move(id, start, snap: snap, stepsPerBar: stepsPerBar, lo: lo, hi: hi);
    if (length != null) {
      changed = trimEnd(id, c.start + length, snap: snap, stepsPerBar: stepsPerBar, lo: lo, hi: hi) || changed;
    }
    return changed;
  }

  /// Replaces what lies in [lo, hi) with [fresh]: shots inside it go, a shot across an edge keeps its part
  /// outside, and shots outside it stay (auto-cut over a loop or selection range).
  void replaceRange(List<VideoCut> fresh, double lo, double hi) {
    final keep = <VideoCut>[];
    for (final c in cuts) {
      if (c.end <= lo || c.start >= hi) {
        keep.add(c);
        continue;
      }
      if (c.start < lo && lo - c.start >= kVideoMinShotSteps) keep.add(c.copy()..length = lo - c.start);
      if (c.end > hi && c.end - hi >= kVideoMinShotSteps) {
        final before = c.start < lo;
        keep.add(c.copy(id: before ? newId() : c.id)
          ..start = hi
          ..length = c.end - hi);
      }
    }
    cuts
      ..clear()
      ..addAll(keep)
      ..addAll([
        for (final f in fresh)
          if (math.min(f.end, hi) - math.max(f.start, lo) >= kVideoMinShotSteps)
            f.copy(id: newId())
              ..start = math.max(f.start, lo)
              ..length = math.min(f.end, hi) - math.max(f.start, lo),
      ]);
    _sort();
  }

  /// Replaces every shot with [fresh].
  void replaceAll(List<VideoCut> fresh) {
    cuts
      ..clear()
      ..addAll([for (final c in fresh) c.copy(id: newId())]);
    _sort();
  }

  /// Fills only the empty stretches of [lo, hi) with the parts of [fresh] that fall in them; the shots already
  /// here stay as they are. Returns how many shots were added.
  int fillGaps(List<VideoCut> fresh, double lo, double hi) {
    var added = 0;
    for (final (a, b) in gaps(lo, hi)) {
      for (final f in fresh) {
        final s = math.max(a, f.start), e = math.min(b, f.end);
        if (e - s < kVideoMinShotSteps) continue;
        cuts.add(f.copy(id: newId())
          ..start = s
          ..length = e - s);
        added++;
      }
    }
    _sort();
    return added;
  }

  List<Map<String, dynamic>> toJson() => [for (final c in cuts) c.toJson()];

  /// Reads saved shots with limits (an untrusted file): at most [kVideoMaxShots]; overlapping ones are dropped and
  /// missing or repeated ids replaced.
  static VideoTimeline fromJson(Object? j, {double maxStep = 2147483647}) {
    final read = [for (final c in _list(j).take(kVideoMaxShots)) ?VideoCut.fromJson(c, maxStep)]
      ..sort((a, b) => a.start.compareTo(b.start));
    final t = VideoTimeline();
    final ids = <String>{};
    for (final c in read) {
      if (t.cuts.isNotEmpty && c.start < t.cuts.last.end - 1e-9) continue;
      t._seen(c.id);
      t.cuts.add(c);
    }
    for (var i = 0; i < t.cuts.length; i++) {
      final c = t.cuts[i];
      if (c.id.isEmpty || !ids.add(c.id)) {
        t.cuts[i] = c.copy(id: t.newId());
        ids.add(t.cuts[i].id);
      }
    }
    return t;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Auto-cut settings

/// Auto-cut's triggers (owner, 2026-11-12: all four, each with its sensitivity or settings).
class AutoCutSettings {
  AutoCutSettings({this.interval = true, this.intervalCount = 4, this.intervalBars = true, this.bursts = true,
      double burstSensitivity = 0.5, this.tracks = true, double quietBars = 1, this.loudness = true,
      double loudnessSensitivity = 0.5, this.fromAudio = false, double minBeats = 2, this.styledTransitions = true})
      : burstSensitivity = burstSensitivity.clamp(0.0, 1.0).toDouble(),
        quietBars = quietBars.clamp(0.25, 16.0).toDouble(),
        loudnessSensitivity = loudnessSensitivity.clamp(0.0, 1.0).toDouble(),
        minBeats = minBeats.clamp(0.25, 64.0).toDouble();

  /// Every [intervalCount] bars (or beats).
  bool interval;
  int intervalCount;
  bool intervalBars;

  /// Bursts of note starts: more sensitive needs fewer notes in a beat.
  bool bursts;
  double burstSensitivity;

  /// Tracks entering or going quiet after [quietBars] of silence.
  bool tracks;
  double quietBars;

  /// Loudness jumps (drops and breakdowns): more sensitive needs a smaller jump.
  bool loudness;
  double loudnessSensitivity;

  /// Read loudness from the rendered audio (an offline render of the range) instead of the notes.
  bool fromAudio;

  /// Cuts closer than this many beats merge (the stronger trigger keeps its place).
  double minBeats;

  /// Each cut gets a transition matching the style and what made it ([styledTransition]); off, the director's.
  bool styledTransitions;

  bool get any => interval || bursts || tracks || loudness;

  /// The note starts in one beat a burst needs: 12 at the least sensitive, 3 at the most.
  int get burstNotes => (12 - 9 * burstSensitivity).round();

  /// The loudness jump in dB a cut needs: 12 dB at the least sensitive, 3 dB at the most.
  double get loudnessDb => 12 - 9 * loudnessSensitivity;

  AutoCutSettings copy() => AutoCutSettings.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'interval': interval, 'interval_count': intervalCount, 'interval_bars': intervalBars,
        'bursts': bursts, 'burst_sensitivity': _r(burstSensitivity),
        'tracks': tracks, 'quiet_bars': _r(quietBars),
        'loudness': loudness, 'loudness_sensitivity': _r(loudnessSensitivity), 'from_audio': fromAudio,
        'min_beats': _r(minBeats), 'styled_transitions': styledTransitions,
      };

  static AutoCutSettings fromJson(Object? j) {
    if (j is! Map) return AutoCutSettings();
    return AutoCutSettings(
      interval: j['interval'] != false,
      intervalCount: ((_num(j['interval_count']) ?? 4).round()).clamp(1, 64),
      intervalBars: j['interval_bars'] != false,
      bursts: j['bursts'] != false,
      burstSensitivity: _num(j['burst_sensitivity']) ?? 0.5,
      tracks: j['tracks'] != false,
      quietBars: _num(j['quiet_bars']) ?? 1,
      loudness: j['loudness'] != false,
      loudnessSensitivity: _num(j['loudness_sensitivity']) ?? 0.5,
      fromAudio: j['from_audio'] == true,
      minBeats: _num(j['min_beats']) ?? 2,
      styledTransitions: j['styled_transitions'] != false,
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The saved video

/// Everything the music video saves with its project: the setup, the shots, auto-cut's settings and the lane's snap.
class MusicVideoDoc {
  MusicVideoDoc({MusicVideoOptions? options, VideoTimeline? timeline, AutoCutSettings? autoCut,
      this.snap = VideoSnap.beat, List<VideoText>? texts, List<VideoImageAsset>? assets,
      List<VideoImageLayer>? images})
      : options = options ?? MusicVideoOptions(),
        timeline = timeline ?? VideoTimeline(),
        autoCut = autoCut ?? AutoCutSettings(),
        texts = texts ?? [],
        assets = assets ?? [],
        images = images ?? [];

  /// The format's version: 1 is the first that saves (2026-11-12); 2 adds text overlays, images, camera moves,
  /// the new transitions and drives, 24 fps and the quality (2026-11-12). A version 1 entry reads as it was (none of
  /// those); a project without a `music_video` entry (every project before it) loads as a new video.
  static const version = 2;

  MusicVideoOptions options;
  VideoTimeline timeline;
  AutoCutSettings autoCut;
  VideoSnap snap;

  /// The whole video's text overlays and image layers, and the images the video's layers use.
  List<VideoText> texts;
  List<VideoImageAsset> assets;
  List<VideoImageLayer> images;

  VideoImageAsset? asset(String id) => assets.where((a) => a.id == id).firstOrNull;

  /// The assets the whole video's and the shots' image layers use.
  Set<String> get usedAssetIds => {
        for (final x in images) x.assetId,
        for (final c in timeline.cuts) ...[for (final x in c.images) x.assetId],
      };

  /// A new overlay or layer id, not used in the video yet nor given out before (`prefix` t for texts, i for images).
  String newOverlayId(String prefix) {
    final used = {
      ..._issued,
      for (final x in texts) x.id,
      for (final x in images) x.id,
      for (final c in timeline.cuts) ...[for (final x in c.texts) x.id, for (final x in c.images) x.id],
    };
    var n = 1;
    while (used.contains('$prefix$n')) {
      n++;
    }
    _issued.add('$prefix$n');
    return '$prefix$n';
  }

  /// Ids given out that may not be in the video yet (a preset makes two before either is added).
  final Set<String> _issued = {};

  MusicVideoDoc copy() => MusicVideoDoc(options: options.copy(), timeline: timeline.copy(), autoCut: autoCut.copy(),
      snap: snap, texts: [for (final x in texts) x.copy()],
      assets: [for (final a in assets) VideoImageAsset.fromJson(a.toJson())!],
      images: [for (final x in images) x.copy()]);

  Map<String, dynamic> toJson() => {
        'version': version,
        'options': options.toJson(),
        'shots': timeline.toJson(),
        'auto_cut': autoCut.toJson(),
        'snap': snap.name,
        if (texts.isNotEmpty) 'texts': [for (final x in texts) x.toJson()],
        if (assets.isNotEmpty) 'assets': [for (final a in assets) a.toJson()],
        if (images.isNotEmpty) 'images': [for (final x in images) x.toJson()],
      };

  /// Reads [j] (the project's `music_video` entry, untrusted). A missing or unreadable entry is a new video; a newer
  /// version is read for what this version knows.
  static MusicVideoDoc fromJson(Object? j, {double maxStep = 2147483647}) {
    if (j is! Map) return MusicVideoDoc();
    return MusicVideoDoc(
      options: MusicVideoOptions.fromJson(j['options']),
      timeline: VideoTimeline.fromJson(j['shots'], maxStep: maxStep),
      autoCut: AutoCutSettings.fromJson(j['auto_cut']),
      snap: _enum(VideoSnap.values, j['snap'], VideoSnap.beat),
      texts: _ids([for (final x in _list(j['texts']).take(kVideoMaxTexts)) ?VideoText.fromJson(x)], 't'),
      assets: () {
        final seen = <String>{};
        return [
          for (final a in _list(j['assets']).take(kVideoMaxImageAssets))
            if (VideoImageAsset.fromJson(a) case final x? when seen.add(x.id)) x,
        ];
      }(),
      images: _ids([for (final x in _list(j['images']).take(kVideoMaxImages)) ?VideoImageLayer.fromJson(x)], 'i'),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Reading helpers (untrusted JSON)

double _r(double v) => (v * 1e6).roundToDouble() / 1e6;

double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

String? _str(Object? v) => v is String && v.isNotEmpty ? (v.length > 200 ? v.substring(0, 200) : v) : null;

List<Object?> _list(Object? v) => v is List ? v : const [];

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) => _enumOrNull(values, name) ?? fallback;

T? _enumOrNull<T extends Enum>(List<T> values, Object? name) =>
    name is String ? values.where((v) => v.name == name).firstOrNull : null;
