// The music video's auto director: a deterministic shot list from the arrangement (cuts on bars, beats and sections,
// shots weighted by what plays, moves and is loud), style transitions, and a critically damped spring camera (or,
// with smooth follow, a camera locked to the playhead).
import 'dart:math' as math;

import 'music_video.dart';
import 'music_video_edit.dart';
import 'music_video_overlay.dart';
import 'music_video_scene.dart';

/// How a shot replaces the one before (owner, 2026-11-12: crossfade, slide, zoom, flash, wipe and glitch join the
/// cut, crossfade and push the director uses). Saved by name.
enum VideoTransition {
  cut('Cut'),
  crossfade('Crossfade'),
  push('Push'),
  slide('Slide'),
  zoom('Zoom'),
  flash('Flash'),
  wipe('Wipe'),
  glitch('Glitch');

  const VideoTransition(this.label);
  final String label;
}

/// One shot: what it shows, from [start] to [end] (song steps), how it begins and where its camera goes.
class DirectedShot {
  const DirectedShot({required this.kind, required this.start, required this.end, this.clip, this.track, this.lane,
      this.transition = VideoTransition.cut, this.transitionSteps = 0, this.zoomFrom = 1, this.zoomTo = 1,
      this.visibleSteps = 64, this.leadSteps = 0, this.pitchCenter = 60, this.pitchSpan = 24, this.section = false,
      this.panel, this.layout, this.panelShots = const [], this.effects = const [], this.animateLayout = false,
      this.camera, this.texts = const [], this.images = const []});
  final VideoShot kind;
  final double start, end;

  /// The piano roll's clip, the device or mixer focus track, the device shot's lane (indexes into the scene).
  final int? clip, track, lane;

  /// How this shot replaces the one before, over [transitionSteps] from [start].
  final VideoTransition transition;
  final double transitionSteps;

  /// The camera: its zoom springs from [zoomFrom] to [zoomTo] (1 shows [visibleSteps]); the pan starts [leadSteps]
  /// behind the playhead and springs after it.
  final double zoomFrom, zoomTo, visibleSteps, leadSteps;

  /// The piano roll's pitch window.
  final double pitchCenter, pitchSpan;

  /// The shot starts at a section or a drop.
  final bool section;

  /// The panel this view draws as (its look, the falling keyboard's range and hidden tracks), or null for defaults.
  final VideoPanel? panel;

  /// An edited shot's split layout: [panelShots] draw in its places, one each, in order. Null (the director's own
  /// shots) draws this shot's [kind] across the frame.
  final VideoLayout? layout;
  final List<DirectedShot> panelShots;

  /// The shot's effect stack, in order, over everything its panels draw.
  final List<VideoEffect> effects;

  /// A layout change from the shot before animates over the transition instead of cutting.
  final bool animateLayout;

  /// The shot's keyframed camera over the whole frame, or null for the auto camera alone.
  final VideoCameraMove? camera;

  /// The shot's own text overlays and image layers (the whole video's are on the plan's input).
  final List<VideoText> texts;
  final List<VideoImageLayer> images;

  /// Whether it draws more than one view or applies any effect (else it draws exactly as a director's shot).
  bool get edited => (layout != null && panelShots.length > 1) || effects.isNotEmpty || animateLayout || camera != null;

  @override
  String toString() => '${kind.name}[$start..$end ${transition.name}]';
}

/// A style's numbers: shot lengths (steps), the grid cuts snap to, transitions and the camera's stiffness.
class _StyleRules {
  const _StyleRules({required this.lengths, required this.minSteps, required this.grid, required this.transition,
      required this.transitionSteps, required this.sectionTransition, required this.omega, required this.bars,
      required this.zoomFrom, required this.rollBars});
  final List<int> lengths; // in bars, chosen from at random; a negative entry is beats
  final int minSteps; // the shortest shot, in steps
  final bool grid; // true: cuts land on bars; false: on beats
  final VideoTransition transition, sectionTransition;
  final double transitionSteps, omega, bars, zoomFrom, rollBars;
}

_StyleRules _rules(VideoStyle s) => switch (s) {
      VideoStyle.calm => const _StyleRules(lengths: [4, 4, 8], minSteps: 0, grid: true,
          transition: VideoTransition.crossfade, transitionSteps: 4, sectionTransition: VideoTransition.push,
          omega: 2.5, bars: 8, zoomFrom: 1.25, rollBars: 2),
      VideoStyle.energetic => const _StyleRules(lengths: [1, 1, 2, -2], minSteps: 0, grid: false,
          transition: VideoTransition.cut, transitionSteps: 0, sectionTransition: VideoTransition.push,
          omega: 7, bars: 4, zoomFrom: 0.7, rollBars: 1),
      VideoStyle.minimal => const _StyleRules(lengths: [8, 8, 16], minSteps: 0, grid: true,
          transition: VideoTransition.crossfade, transitionSteps: 8, sectionTransition: VideoTransition.cut,
          omega: 1.6, bars: 16, zoomFrom: 1.1, rollBars: 4),
    };

/// A small fixed PRNG (mulberry32), so a seed gives the same shots on every platform and Dart version.
class _Rng {
  _Rng(int seed) : _s = seed & 0xffffffff;
  int _s;
  double next() {
    _s = (_s + 0x6D2B79F5) & 0xffffffff;
    var t = _s;
    t = _imul(t ^ (t >>> 15), t | 1);
    t ^= (t + _imul(t ^ (t >>> 7), t | 61)) & 0xffffffff;
    return ((t ^ (t >>> 14)) & 0xffffffff) / 4294967296.0;
  }

  static int _imul(int a, int b) => (a * b) & 0xffffffff;
}

/// The shot list for [scene] over [start, end) (song steps).
class ShotPlan {
  ShotPlan(this.shots, {required this.omega, required this.bpm, this.smoothFollow = false});
  final List<DirectedShot> shots;

  /// Smooth follow: the arrangement and piano-roll cameras lock to the playhead (see [MusicVideoOptions.smoothFollow]).
  final bool smoothFollow;

  /// Where a locked camera holds the playhead, as a fraction of the view's width from its left edge.
  static const lockedAnchor = 1 / 3;

  /// How long a locked camera takes to ease its zoom after a cut from a shot of the same kind (steps; one beat).
  static const lockedZoomSteps = 4.0;

  /// The camera springs' natural frequency (radians per second).
  final double omega;
  final double bpm;

  /// The index of the shot at [step] (the first before the start, the last after the end).
  int indexAt(double step) {
    var lo = 0, hi = shots.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (shots[mid].start <= step) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  DirectedShot at(double step) => shots[indexAt(step)];

  /// The camera of [shot] at [step].
  ShotCamera camera(DirectedShot shot, double step) {
    if (smoothFollow && locks(shot.kind)) return _locked(shot, step);
    final t = math.max(0.0, (step - shot.start) * 15 / bpm);
    final zoom = springTo(t, from: shot.zoomFrom, velocity: 0, target: shot.zoomTo, omega: omega).$1;
    // The pan follows the playhead (moving at bpm/15 steps a second): it starts at rest, [leadSteps] behind.
    final v = bpm / 15;
    final x = springFollow(t, x0: shot.start - shot.leadSteps, u0: 0, a: shot.start, v: v, omega: omega).$1;
    return ShotCamera(center: x, zoom: zoom);
  }

  /// Whether smooth follow locks [kind]'s camera to the playhead.
  static bool locks(VideoShot kind) => kind == VideoShot.flythrough || kind == VideoShot.pianoRoll;

  /// The locked camera: on the playhead, at the shot's own zoom held all through it. A cut from a shot of the same
  /// kind eases from that shot's zoom over [lockedZoomSteps] (smoothstep), the playhead staying where it is.
  ShotCamera _locked(DirectedShot shot, double step) {
    var zoom = shot.zoomFrom;
    final i = indexAt(shot.start);
    if (i > 0 && identical(shots[i], shot) && shots[i - 1].kind == shot.kind) {
      final ease = math.min(lockedZoomSteps, (shot.end - shot.start) / 2);
      final x = ease <= 0 ? 1.0 : ((step - shot.start) / ease).clamp(0.0, 1.0);
      final p = x * x * (3 - 2 * x);
      zoom = shots[i - 1].zoomFrom + (shot.zoomFrom - shots[i - 1].zoomFrom) * p;
    }
    return ShotCamera(center: step, zoom: zoom, anchor: lockedAnchor);
  }
}

class ShotCamera {
  const ShotCamera({required this.center, required this.zoom, this.anchor});

  /// The step the view centres on, and the zoom (1 shows the shot's visible steps; above 1 shows fewer).
  final double center, zoom;

  /// Where [center] sits across the view (0 the left edge, 1 the right), or null for the shot's own framing.
  final double? anchor;
}

/// A critically damped spring after a fixed target: position and velocity [t] seconds after it was at [from]
/// moving at [velocity].
(double, double) springTo(double t, {required double from, required double velocity, required double target,
        required double omega}) =>
    springFollow(t, x0: from, u0: velocity, a: target, v: 0, omega: omega);

/// A critically damped spring after a target moving as a + v·t, in closed form (so any time can be asked for
/// directly, as a scrub or a render frame does): x'' = −2ω(x' − v) − ω²(x − a − v·t). The gap e = x − a − v·t obeys
/// e'' + 2ωe' + ω²e = 0, so e = (e0 + (e0' + ωe0)t)·e^−ωt: it closes without overshoot and the camera then rides the target.
(double, double) springFollow(double t, {required double x0, required double u0, required double a, required double v,
    required double omega}) {
  final e0 = x0 - a, e1 = u0 - v;
  final decay = math.exp(-omega * t);
  final e = (e0 + (e1 + omega * e0) * t) * decay;
  final de = (e1 - omega * (e1 + omega * e0) * t) * decay;
  return (a + v * t + e, v + de);
}

/// Plans the shots for [scene] over [start, end) with [options]' shots, style and seed.
ShotPlan directVideo(VideoScene scene, MusicVideoOptions options, {required double start, required double end,
    List<double>? cutsAt}) {
  final spb = scene.stepsPerBar;
  final rules = _rules(options.style);
  final rng = _Rng(options.seed * 2654435761 + 12345);
  final enabled = [for (final s in VideoShot.values) if (options.shots.contains(s)) s];
  if (enabled.isEmpty) enabled.add(VideoShot.flythrough);
  final gridSteps = rules.grid ? spb.toDouble() : 4.0;
  final minSteps = math.max(rules.minSteps.toDouble(), rules.grid ? spb.toDouble() : 8.0);
  final sections = [for (final s in scene.sections) if (s.step > start && s.step < end) s];

  // Cut points: a chosen length, snapped onto the grid; a section inside the shot (past its shortest) cuts there.
  final cuts = cutsAt ?? <double>[start];
  var t = cutsAt == null ? start : end;
  while (t < end) {
    final pick = rules.lengths[(rng.next() * rules.lengths.length).floor().clamp(0, rules.lengths.length - 1)];
    final len = pick > 0 ? pick * spb.toDouble() : -pick * 4.0;
    var next = ((t + len) / gridSteps).round() * gridSteps;
    if (next < t + minSteps * 0.5) next = t + gridSteps * math.max(1, (minSteps / gridSteps).ceil());
    final section = sections.where((s) => s.step > t + math.min(minSteps, len) * 0.5 && s.step <= next).firstOrNull;
    if (section != null) next = section.step;
    if (end - next < minSteps * 0.5) next = end;
    cuts.add(math.min(next, end));
    t = next;
  }

  final shots = <DirectedShot>[];
  VideoShot? prevKind;
  final step = scene.stepsPerBar.toDouble();
  for (var i = 0; i + 1 < cuts.length; i++) {
    final a = cuts[i], b = cuts[i + 1];
    final atSection = i > 0 && scene.sectionAt(a) != null;
    final drop = scene.sectionAt(a)?.drop ?? false;
    final energy = scene.energy(a, b);
    final busiest = scene.busiestClip(a, b);
    final noteCount = scene.notesStartingIn(a, b).length;
    final moving = scene.movingLane(a, b);
    final density = math.min(1.0, noteCount / math.max(1.0, (b - a) / step) / 16);

    final weights = <VideoShot, double>{};
    for (final k in enabled) {
      weights[k] = switch (k) {
        VideoShot.flythrough => 1.0 + (atSection ? 4.0 : 0) + (drop ? 4.0 : 0),
        VideoShot.pianoRoll => busiest == null ? 0 : 0.6 + 2.5 * density,
        VideoShot.devices => moving != null ? 2.0 + 2.0 * moving.$2 : (scene.tracks.any((x) => x.devices.isNotEmpty) ? 0.25 : 0),
        VideoShot.mixer => scene.tracks.isEmpty ? 0 : 0.5 + 3.0 * energy * energy,
        VideoShot.falling => noteCount == 0 ? 0 : 0.5 + 2.0 * density,
      };
      if (k == prevKind && enabled.length > 1) weights[k] = weights[k]! * 0.25;
    }
    if (weights.values.every((w) => w <= 0)) weights[enabled.first] = 1;
    final total = weights.values.fold(0.0, (s, w) => s + w);
    var r = rng.next() * total;
    var kind = enabled.first;
    for (final k in enabled) {
      final w = weights[k]!;
      if (w <= 0) continue;
      kind = k;
      if (r < w) break;
      r -= w;
    }

    final focus = shotFocus(scene, kind, a, b, busiest: busiest, moving: moving);
    final first = i == 0;
    final transition = first
        ? VideoTransition.cut
        : (atSection || drop) ? rules.sectionTransition : rules.transition;
    final tSteps = transition == VideoTransition.cut ? 0.0 : math.min((b - a) / 2, transition == VideoTransition.push ? 4.0 : rules.transitionSteps);
    final zoomFrom = options.style == VideoStyle.energetic
        ? (rng.next() < 0.5 ? rules.zoomFrom : 1 / rules.zoomFrom)
        : rules.zoomFrom;
    shots.add(DirectedShot(
      kind: kind, start: a, end: b, clip: focus.clip, track: focus.track, lane: focus.lane, transition: transition,
      transitionSteps: tSteps, zoomFrom: drop ? 0.6 : zoomFrom, zoomTo: 1,
      visibleSteps: _visibleSteps(kind, rules, spb),
      leadSteps: kind == VideoShot.flythrough || kind == VideoShot.pianoRoll ? spb * (first ? 0.0 : 0.5) : 0,
      pitchCenter: focus.pitchCenter, pitchSpan: focus.pitchSpan, section: atSection || drop,
    ));
    prevKind = kind;
  }
  if (shots.isEmpty) {
    shots.add(DirectedShot(kind: enabled.first, start: start, end: math.max(end, start + 1)));
  }
  return ShotPlan(shots, omega: rules.omega, bpm: scene.bpm, smoothFollow: options.smoothFollow);
}


/// How many steps a view shows across by default (the falling notes' look-ahead is two bars).
double _visibleSteps(VideoShot kind, _StyleRules rules, int spb) => switch (kind) {
      VideoShot.pianoRoll => rules.rollBars * spb,
      VideoShot.falling => 2.0 * spb,
      _ => rules.bars * spb,
    };

/// What a shot of [kind] over [a, b) looks at: the piano roll's clip and pitch window, the device's lane and track,
/// the mixer's focus track, the falling keyboard's pitch range. [trackId] keeps it to that track's clips;
/// [hidden] leaves tracks out of the falling notes' range.
({int? clip, int? track, int? lane, double pitchCenter, double pitchSpan}) shotFocus(VideoScene scene, VideoShot kind,
    double a, double b, {int? busiest, (int, double)? moving, String? trackId, Set<String> hidden = const {}}) {
  final only = trackId == null ? null : scene.tracks.indexWhere((t) => t.id == trackId);
  if (only != null && only >= 0) {
    busiest = scene.busiestClip(a, b, track: only) ??
        scene.clips.indexWhere((c) => c.track == only && !c.audio && c.end > a && c.start < b);
    if (busiest < 0) busiest = scene.clips.indexWhere((c) => c.track == only && !c.audio);
    if (busiest < 0) busiest = null;
    moving = scene.movingLane(a, b, track: only);
  } else {
    busiest ??= scene.busiestClip(a, b);
    moving ??= scene.movingLane(a, b);
  }
  int? clip, track, lane;
  var pitchCenter = 60.0, pitchSpan = 24.0;
  switch (kind) {
    case VideoShot.pianoRoll:
      clip = busiest;
      if (clip != null) {
        final notes = scene.notesStartingIn(a, b).where((n) => n.clip == clip).toList();
        final lo = notes.isEmpty ? scene.clips[clip].lowPitch : notes.map((n) => n.pitch).reduce(math.min);
        final hi = notes.isEmpty ? scene.clips[clip].highPitch : notes.map((n) => n.pitch).reduce(math.max);
        pitchCenter = (lo + hi) / 2;
        pitchSpan = math.max(12.0, hi - lo + 6);
        track = scene.clips[clip].track;
      }
    case VideoShot.devices:
      if (moving != null) {
        lane = moving.$1;
        track = scene.lanes[lane].track;
      } else {
        // No automation moves: the busiest track that has a device, its knobs at rest.
        final c = only != null && only >= 0 ? only : (busiest == null ? null : scene.clips[busiest].track);
        track = c != null && scene.tracks[c].devices.isNotEmpty ? c : scene.tracks.indexWhere((x) => x.devices.isNotEmpty);
        if (track < 0) track = null;
      }
    case VideoShot.mixer:
      track = only != null && only >= 0 ? only : (busiest == null ? null : scene.clips[busiest].track);
    case VideoShot.falling:
      // The keyboard spans every note the shown tracks play in the whole song, so it never jumps at a cut.
      final (lo, hi) = scene.pitchRange(hidden: hidden);
      pitchCenter = (lo + hi) / 2;
      pitchSpan = hi - lo;
    case VideoShot.flythrough:
      break;
  }
  return (clip: clip, track: track, lane: lane, pitchCenter: pitchCenter, pitchSpan: pitchSpan);
}

/// The shots the edited lane [timeline] gives over [start, end): each shot clipped to the range, its panels as
/// shots of their own, and the gaps shown as the arrangement (owner's lane; [directVideo] is used while it is empty).
ShotPlan planFromTimeline(VideoScene scene, VideoTimeline timeline, MusicVideoOptions options,
    {required double start, required double end}) {
  final rules = _rules(options.style);
  final spb = scene.stepsPerBar;
  DirectedShot panelShot(VideoPanel p, double a, double b, double zoom) {
    final f = shotFocus(scene, p.view, a, b, trackId: p.trackId, hidden: p.hiddenTracks);
    final visible = p.bars != null ? p.bars! * spb : _visibleSteps(p.view, rules, spb);
    return DirectedShot(kind: p.view, start: a, end: b, clip: f.clip, track: f.track, lane: f.lane, zoomFrom: zoom,
        zoomTo: 1, visibleSteps: visible, pitchCenter: f.pitchCenter, pitchSpan: f.pitchSpan, panel: p);
  }

  final shots = <DirectedShot>[];
  void gap(double a, double b) {
    if (b - a <= 1e-9) return;
    shots.add(DirectedShot(kind: VideoShot.flythrough, start: a, end: b, visibleSteps: rules.bars * spb));
  }

  var t = start;
  for (final c in timeline.cuts) {
    final a = math.max(c.start, start), b = math.min(c.end, end);
    if (b <= a) continue;
    gap(t, a);
    // A keyframed camera frames the whole shot; the views then keep their own width (no opening zoom).
    final zoom = c.camera != null ? 1.0 : c.zoom;
    final panels = [for (final p in c.layout.panels) panelShot(p, a, b, zoom)];
    final first = panels.first;
    final tSteps = c.transition == VideoTransition.cut && !c.animateLayout
        ? 0.0
        : math.min((b - a) / 2, c.transitionSteps > 0 ? c.transitionSteps : 4.0);
    shots.add(DirectedShot(
      kind: first.kind, start: a, end: b, clip: first.clip, track: first.track, lane: first.lane,
      transition: c.transition, transitionSteps: tSteps, zoomFrom: zoom, zoomTo: 1,
      visibleSteps: first.visibleSteps, pitchCenter: first.pitchCenter, pitchSpan: first.pitchSpan,
      panel: first.panel, layout: c.layout, panelShots: panels, effects: [for (final e in c.effects) if (e.on) e],
      animateLayout: c.animateLayout, camera: c.camera, texts: c.texts, images: c.images,
    ));
    t = b;
  }
  gap(t, end);
  if (shots.isEmpty) shots.add(DirectedShot(kind: VideoShot.flythrough, start: start, end: math.max(end, start + 1)));
  return ShotPlan(shots, omega: rules.omega, bpm: scene.bpm, smoothFollow: options.smoothFollow);
}

/// The plan the preview and the render draw: the edited lane's shots, or the auto director's while it is empty.
ShotPlan planVideo(VideoScene scene, MusicVideoOptions options, VideoTimeline? timeline,
        {required double start, required double end}) =>
    timeline == null || timeline.isEmpty
        ? directVideo(scene, options, start: start, end: end)
        : planFromTimeline(scene, timeline, options, start: start, end: end);

/// Whether drawing [plan] needs a meter per track from the render (a mixer view, or an effect that follows a track).
bool planNeedsStems(ShotPlan plan) => plan.shots.any((s) =>
    s.kind == VideoShot.mixer ||
    s.panelShots.any((p) => p.kind == VideoShot.mixer) ||
    s.effects.any((e) => e.drive == VideoDrive.track));

/// The views the auto director gives [cuts] (song steps, in order; [start] first and the end last), weighted by
/// what plays as [directVideo]'s are, with [options]' shots, style and seed.
List<DirectedShot> directShotsAt(VideoScene scene, MusicVideoOptions options, List<double> cuts) {
  final probe = directVideo(scene, options, start: cuts.first, end: cuts.last, cutsAt: cuts);
  return probe.shots;
}
