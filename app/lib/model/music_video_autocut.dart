// Auto-cut for the music video lane (owner, 2026-11-12): cut points from four triggers (every N bars or beats, bursts
// of note starts, tracks entering or going quiet, loudness jumps), merged and snapped, then views from the director.
import 'dart:isolate';
import 'dart:math' as math;

import 'music_video.dart';
import 'music_video_director.dart';
import 'music_video_edit.dart';
import 'music_video_meters.dart';
import 'music_video_scene.dart';

/// Which trigger made a cut; a stronger one keeps its place when two land close together.
enum CutTrigger {
  interval('Interval', 0),
  burst('Note burst', 1),
  track('Track', 2),
  loudness('Loudness', 3);

  const CutTrigger(this.label, this.strength);
  final String label;
  final int strength;
}

/// One proposed cut: where (song steps) and why.
typedef CutPoint = ({double step, CutTrigger trigger, String reason});

/// Every [count] bars (or beats), on the song's grid, inside (start, end).
List<CutPoint> intervalCuts(VideoScene scene, double start, double end, {required int count, required bool bars}) {
  final len = math.max(1, count) * (bars ? scene.stepsPerBar : 4).toDouble();
  final out = <CutPoint>[];
  for (var t = ((start / len).floor() + 1) * len; t < end; t += len) {
    out.add((step: t, trigger: CutTrigger.interval, reason: 'Every $count ${bars ? 'bar' : 'beat'}${count == 1 ? '' : 's'}'));
  }
  return out;
}

/// Where the notes start to come thick and fast: [notes] or more starts within a beat, after a beat with fewer.
/// Each burst cuts once, on the beat it starts in.
List<CutPoint> burstCuts(VideoScene scene, double start, double end, {required int notes}) {
  const window = 4.0;
  final starts = [for (final n in scene.notesStartingIn(start - window, end)) n.start];
  int countIn(double a, double b) {
    var lo = 0, hi = starts.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      starts[m] < a ? lo = m + 1 : hi = m;
    }
    var k = lo;
    while (k < starts.length && starts[k] < b) {
      k++;
    }
    return k - lo;
  }

  final out = <CutPoint>[];
  var last = double.negativeInfinity;
  for (final s in starts) {
    if (s <= start || s >= end || s < last + window * 2) continue;
    if (countIn(s, s + window) >= notes && countIn(s - window, s) < notes) {
      final at = (s / 4).floor() * 4.0;
      if (at <= start) continue;
      out.add((step: at, trigger: CutTrigger.burst, reason: 'Note burst'));
      last = s;
    }
  }
  return out;
}

/// Where a track comes in after [quietBeats] of silence, or goes quiet for that long, on the beat it happens.
List<CutPoint> trackCuts(VideoScene scene, double start, double end, {required double quietBeats}) {
  final beats = (end / 4).ceil() + 1;
  final quiet = math.max(1, quietBeats.round());
  final out = <CutPoint>[];
  for (var t = 0; t < scene.tracks.length; t++) {
    final on = List<bool>.filled(beats, false);
    for (final n in scene.notes) {
      if (n.track != t) continue;
      for (var b = (n.start / 4).floor(); b < (n.end / 4).ceil() && b < beats; b++) {
        if (b >= 0) on[b] = true;
      }
    }
    for (final c in scene.clips) {
      if (c.track != t || !c.audio) continue;
      for (var b = (c.start / 4).floor(); b < (c.end / 4).ceil() && b < beats; b++) {
        if (b >= 0) on[b] = true;
      }
    }
    bool silent(int from, int to) {
      for (var b = math.max(0, from); b < math.min(beats, to); b++) {
        if (on[b]) return false;
      }
      return true;
    }

    final name = scene.tracks[t].name;
    for (var b = 1; b < beats; b++) {
      final step = b * 4.0;
      if (step <= start || step >= end) continue;
      if (on[b] && !on[b - 1] && silent(b - quiet, b)) {
        out.add((step: step, trigger: CutTrigger.track, reason: '$name comes in'));
      } else if (!on[b] && on[b - 1] && silent(b, b + quiet) && b + quiet <= beats) {
        out.add((step: step, trigger: CutTrigger.track, reason: '$name goes quiet'));
      }
    }
  }
  return out;
}

/// The loudness per beat in dB, from the notes (summed velocity of the notes sounding, a stand-in before any audio
/// is rendered).
List<double> noteLoudness(VideoScene scene, double end) {
  final beats = (end / 4).ceil() + 1;
  final e = List<double>.filled(beats, 0);
  for (final n in scene.notes) {
    for (var b = (n.start / 4).floor(); b < (n.end / 4).ceil() && b < beats; b++) {
      if (b >= 0) e[b] += n.vel * math.min(1.0, (n.end - n.start) / 4);
    }
  }
  for (final c in scene.clips) {
    if (!c.audio) continue;
    for (var b = (c.start / 4).floor(); b < (c.end / 4).ceil() && b < beats; b++) {
      if (b >= 0) e[b] += 1;
    }
  }
  return [for (final v in e) 20 * math.log(math.max(v, 1e-3)) / math.ln10];
}

/// The loudness per beat in dB from rendered audio's meters ([OfflineVideoMeters] at [fps], starting at [start]),
/// the RMS averaged over each beat.
List<double> audioLoudness(OfflineVideoMeters m, {required int fps, required double bpm, required double start,
    required double end}) {
  final beats = (end / 4).ceil() + 1;
  final out = List<double>.filled(beats, -60);
  final framesPerBeat = fps * 60 / bpm;
  for (var b = (start / 4).floor(); b < beats; b++) {
    final f0 = ((b * 4 - start) / 4 * framesPerBeat).floor(), f1 = ((b * 4 + 4 - start) / 4 * framesPerBeat).ceil();
    var sum = 0.0, n = 0;
    for (var f = math.max(0, f0); f < math.min(m.frames, f1); f++) {
      sum += m.rms[f] * m.rms[f];
      n++;
    }
    if (n > 0) out[b] = 20 * math.log(math.max(math.sqrt(sum / n), 1e-3)) / math.ln10;
  }
  return out;
}

/// Where the loudness ([perBeat] dB) jumps by [db] or more between the bar before a bar line and the bar after it:
/// a drop when it rises, a breakdown when it falls.
List<CutPoint> loudnessCuts(VideoScene scene, double start, double end, List<double> perBeat, {required double db}) {
  final spb = scene.stepsPerBar, bpb = scene.beatsPerBar;
  double mean(int from, int to) {
    var s = 0.0, n = 0;
    for (var b = math.max(0, from); b < math.min(perBeat.length, to); b++) {
      s += perBeat[b];
      n++;
    }
    return n == 0 ? -60 : s / n;
  }

  final out = <CutPoint>[];
  for (var bar = (start / spb).floor() + 1; bar * spb < end; bar++) {
    final b = bar * bpb;
    final before = mean(b - bpb, b), after = mean(b, b + bpb);
    if (after - before >= db) {
      out.add((step: bar * spb.toDouble(), trigger: CutTrigger.loudness, reason: 'Drop (+${(after - before).round()} dB)'));
    } else if (before - after >= db) {
      out.add((step: bar * spb.toDouble(), trigger: CutTrigger.loudness, reason: 'Breakdown (−${(before - after).round()} dB)'));
    }
  }
  return out;
}

/// The cuts of every trigger [settings] has on, merged: sorted, and of two closer than its minimum gap the
/// stronger trigger (then the earlier) kept.
List<CutPoint> mergeCuts(List<CutPoint> all, double start, double end, {required double minSteps}) {
  final sorted = [...all.where((c) => c.step > start && c.step < end)]
    ..sort((a, b) => a.step != b.step ? a.step.compareTo(b.step) : b.trigger.strength.compareTo(a.trigger.strength));
  final out = <CutPoint>[];
  for (final c in sorted) {
    if (c.step - start < minSteps || end - c.step < minSteps) continue;
    if (out.isNotEmpty && c.step - out.last.step < minSteps) {
      if (c.trigger.strength > out.last.trigger.strength) out[out.length - 1] = c;
      continue;
    }
    out.add(c);
  }
  return out;
}

/// The cut points for [scene] over [start, end) with [settings]; [loudness] is per-beat dB from rendered audio, else
/// the notes stand in.
List<CutPoint> autoCutPoints(VideoScene scene, AutoCutSettings settings, double start, double end,
    {List<double>? loudness}) {
  final all = <CutPoint>[
    if (settings.interval)
      ...intervalCuts(scene, start, end, count: settings.intervalCount, bars: settings.intervalBars),
    if (settings.bursts) ...burstCuts(scene, start, end, notes: settings.burstNotes),
    if (settings.tracks) ...trackCuts(scene, start, end, quietBeats: settings.quietBars * scene.beatsPerBar),
    if (settings.loudness)
      ...loudnessCuts(scene, start, end, loudness ?? noteLoudness(scene, end), db: settings.loudnessDb),
  ];
  return mergeCuts(all, start, end, minSteps: settings.minBeats * 4);
}

/// Auto-cut: shots between the cut points, each shown as the director would pick for it ([options]' shots, style
/// and seed), as full-frame lane shots ready to edit.
List<VideoCut> autoCut(VideoScene scene, AutoCutSettings settings, MusicVideoOptions options,
    {required double start, required double end, List<double>? loudness}) {
  if (end <= start) return const [];
  final points = settings.any ? autoCutPoints(scene, settings, start, end, loudness: loudness) : const <CutPoint>[];
  final steps = [start, for (final p in points) p.step, end];
  final shots = directShotsAt(scene, options, steps);
  final out = <VideoCut>[];
  for (var i = 0; i < shots.length; i++) {
    final s = shots[i];
    out.add(VideoCut(
      id: 'a$i',
      start: s.start,
      length: s.end - s.start,
      layout: VideoLayout.single(s.kind),
      transition: s.transition,
      transitionSteps: s.transitionSteps,
      zoom: s.zoomFrom,
      reason: i == 0 ? 'Start' : points[i - 1].reason,
    ));
  }
  return out;
}

/// [autoCut] in a background isolate (a long song's triggers scan every note).
Future<List<VideoCut>> autoCutInBackground(VideoScene scene, AutoCutSettings settings, MusicVideoOptions options,
    {required double start, required double end, List<double>? loudness}) {
  final s = settings.copy(), o = options.copy();
  return Isolate.run(() => [
        for (final c in autoCut(scene, s, o, start: start, end: end, loudness: loudness)) c.toJson(),
      ]).then((list) => [for (final j in list) ?VideoCut.fromJson(j, double.maxFinite)]);
}
