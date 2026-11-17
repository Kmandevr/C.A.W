// Comping (1.0.5, #209; owner 2026-11-17: take lanes under the track): a clip's takes, the parts of them swiped into
// the comp the clip plays (MIDI: one pattern built from the parts; audio: the parts sent as clips with short
// crossfades at the joins), a whole take, a join moved, and Flatten. Each edit is one undo step.
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_edit.dart' show clipNotes, kClipEditMaxNotes;
import 'audio_clips.dart';
import 'audio_edit.dart';
import 'clip_automation.dart';
import 'freeze.dart';
import 'pattern_doc.dart';
import 'project.dart';

/// The most parts a comp holds (a file's comp with more is read as none).
const kMaxCompParts = 256;

/// How long the crossfade at each join of an audio comp is, in seconds of output (shorter where a part is short).
const double kCompCrossfadeSeconds = 0.01;

/// One part of a comp: from [from] on the clip plays take [take], until the next part's [from]. MIDI clips count
/// [from] in steps of the pattern (whole steps, so the comp loops with the clip); audio clips in seconds of the file
/// as the clip reads it from its offset (unwrapped: past a loop's end it keeps counting), so a trim, a stretch or a
/// tempo change keeps each part on its audio.
class CompPartDoc {
  const CompPartDoc(this.take, this.from);
  final String take;
  final double from;

  Map<String, dynamic> toJson() => {'take': take, 'from': from};

  @override
  bool operator ==(Object other) => other is CompPartDoc && other.take == take && other.from == from;

  @override
  int get hashCode => Object.hash(take, from);

  @override
  String toString() => '$take@$from';
}

/// A comp from untrusted JSON: parts naming one of [takes] at a finite [from] ≥ 0, at most [kMaxCompParts], put in
/// order ([normalizeComp]); empty when it holds fewer than two parts or anything else.
List<CompPartDoc> compFromJson(Object? raw, List<String> takes, {bool whole = false}) {
  if (raw is! List || raw.length > kMaxCompParts) return [];
  final parts = <CompPartDoc>[];
  for (final p in raw) {
    if (p is! Map) return [];
    final take = p['take'], from = p['from'];
    if (take is! String || !takes.contains(take) || from is! num || !from.isFinite || from < 0) return [];
    parts.add(CompPartDoc(take, whole ? from.roundToDouble() : from.toDouble()));
  }
  final out = normalizeComp(parts);
  return out.length < 2 ? [] : out;
}

/// [parts] in order of [CompPartDoc.from] (of two at one place the later wins), neighbours on one take merged, and
/// the first starting at 0.
List<CompPartDoc> normalizeComp(Iterable<CompPartDoc> parts) {
  final indexed = [
    for (final (i, p) in parts.indexed) (i, CompPartDoc(p.take, p.from.isFinite ? math.max(0.0, p.from) : 0.0)),
  ]..sort((a, b) => a.$2.from != b.$2.from ? a.$2.from.compareTo(b.$2.from) : a.$1.compareTo(b.$1));
  final out = <CompPartDoc>[];
  for (final (_, p) in indexed) {
    if (out.isNotEmpty && out.last.from == p.from) out.removeLast();
    if (out.isNotEmpty && out.last.take == p.take) continue;
    out.add(p);
  }
  if (out.isNotEmpty && out.first.from != 0) out[0] = CompPartDoc(out.first.take, 0);
  return out;
}

/// The take [parts] play at [at].
String compTakeAt(List<CompPartDoc> parts, double at) {
  var take = parts.first.take;
  for (final p in parts) {
    if (p.from > at) break;
    take = p.take;
  }
  return take;
}

/// [parts] with [take] swiped over [from]..[to]: that range plays [take], the rest as before.
List<CompPartDoc> swipeComp(List<CompPartDoc> parts, String take, double from, double to) {
  if (!(to > from) || parts.isEmpty) return parts;
  final after = compTakeAt(parts, to);
  return normalizeComp([
    for (final p in parts) if (p.from < from) p,
    CompPartDoc(take, from),
    CompPartDoc(after, to),
    for (final p in parts) if (p.from > to) p,
  ]);
}

/// [parts]' ranges up to [end]: (take, from, to), empty ones left out.
List<({String take, double from, double to})> compRanges(List<CompPartDoc> parts, double end) => [
      for (final (i, p) in parts.indexed)
        if (p.from < end && (i + 1 < parts.length ? math.min(parts[i + 1].from, end) : end) > p.from)
          (take: p.take, from: p.from, to: i + 1 < parts.length ? math.min(parts[i + 1].from, end) : end),
    ];

/// The comp a MIDI clip plays: its own, else its take whole.
List<CompPartDoc> midiComp(ClipDoc c) => c.comp.isNotEmpty ? c.comp : [CompPartDoc(c.patternId, 0)];

/// The comp an audio clip plays: its own, else its take whole.
List<CompPartDoc> audioComp(AudioClipDoc c) => c.comp.isNotEmpty ? c.comp : [CompPartDoc(c.assetId, 0)];

/// The pattern text a MIDI comp plays: each part's notes from its take (those that start in the part, cut at its
/// end, as a split cuts them), as long as the longest take. Null when a take is gone or doesn't parse, or past
/// [kClipEditMaxNotes] notes.
String? midiCompText(ProjectDoc p, List<CompPartDoc> comp, String name) {
  final docs = <String, PatternDoc>{};
  for (final part in comp) {
    final m = p.module(part.take);
    final doc = m == null ? null : PatternDoc.parse(m.runSource).doc;
    if (doc == null) return null;
    docs[part.take] = doc;
  }
  final length = docs.values.map((d) => d.lengthSteps(p.beatsPerBar)).fold<int>(1, math.max)
      .clamp(1, kPatternMaxSteps).toInt();
  final notes = <PatternNote>[];
  for (final r in compRanges(comp, length.toDouble())) {
    final a = r.from.round(), b = r.to.round();
    if (b <= a) continue;
    final take = ClipDoc(id: '', patternId: r.take, startSteps: 0, lengthSteps: length, loop: false);
    final part = clipNotes(docs[r.take]!, take, p.beatsPerBar, from: a, to: b, tails: false,
        limit: kClipEditMaxNotes - notes.length);
    if (part == null) return null;
    notes.addAll([for (final n in part) n.copyWith(at: n.at + Steps(a))]);
  }
  var doc = PatternDoc.blank(name: name, steps: length);
  if (notes.isNotEmpty) doc = doc.paste(PatternClip(notes, notes.map((n) => n.end).reduce(Steps.max)), Steps.zero).doc;
  return doc.serialize();
}

/// Where in a MIDI clip's pattern song step [step] falls (the clip's offset and loop applied).
double midiCompAt(ProjectDoc p, ClipDoc c, double step) {
  final rel = step - c.startSteps + c.sourceOffsetSteps;
  if (!c.loop) return rel;
  final loop = p.clipLoopSteps(c);
  return loop <= 0 ? rel : rel % loop;
}

// ---------- audio: where a clip reads ----------

double? _assetBpm(ProjectDoc p, AudioClipDoc c) => p.asset(c.assetId)?.bpm;

/// The second of the file (unwrapped) [c] reads at song step [step]: a fixed clip by the tempo map's seconds, a
/// musical one by its steps, as the engine plays them.
double audioSourceAt(ProjectDoc p, AudioClipDoc c, double step) {
  if (c.fixed) {
    return c.offsetSeconds +
        (p.tempo.secondsAt(step / 4) - p.tempo.secondsAt(c.startSteps / 4)) * c.pitchRate / c.stretchRatio;
  }
  return c.offsetSeconds + (step - c.startSteps) * c.sourcePerStep(p.bpm, _assetBpm(p, c));
}

/// The song step at which [c] reads second [at] of the file (unwrapped): [audioSourceAt]'s inverse.
double audioStepAt(ProjectDoc p, AudioClipDoc c, double at) {
  if (c.fixed) {
    return p.tempo.beatAt(p.tempo.secondsAt(c.startSteps / 4) + (at - c.offsetSeconds) * c.stretchRatio / c.pitchRate) * 4;
  }
  final per = c.sourcePerStep(p.bpm, _assetBpm(p, c));
  return per <= 0 ? c.startSteps : c.startSteps + (at - c.offsetSeconds) / per;
}

/// The second of the file (unwrapped) where [c] stops reading.
double audioSourceEnd(ProjectDoc p, AudioClipDoc c) => c.fixed
    ? c.offsetSeconds + c.lengthSeconds * c.pitchRate / c.stretchRatio
    : c.offsetSeconds + c.lengthAt(p.bpm) * c.sourcePerStep(p.bpm, _assetBpm(p, c));

/// What audio comp [c] plays, as plain clips: one per part (in order, ids `<clip>~<n>`), each reading its take
/// where the clip reads it, overlapping its neighbours by a crossfade ([kCompCrossfadeSeconds], equal power, at most
/// half the shorter part) centred on the join; the first keeps the clip's fade in, the last its fade out. A clip
/// without a comp is itself; parts whose file the project doesn't list are left out (silence there).
List<AudioClipDoc> compAudioParts(ProjectDoc p, AudioClipDoc c) {
  if (c.comp.length < 2) return [c];
  final u0 = c.offsetSeconds, u1 = audioSourceEnd(p, c);
  final ranges = [
    for (final r in compRanges(c.comp, u1))
      if (r.to > u0 && p.asset(r.take) != null) (take: r.take, from: math.max(r.from, u0), to: r.to),
  ];
  if (ranges.isEmpty) return const [];
  // Seconds of the file one second of output reads.
  final perOut = c.fixed ? c.pitchRate / c.stretchRatio : c.sourcePerStep(p.bpm, _assetBpm(p, c)) * p.bpm / 15;
  // Half a crossfade at each join (join i is before range i), in seconds of the file; 0 where ranges don't meet.
  final half = [
    for (var i = 0; i < ranges.length; i++)
      i == 0 || ranges[i - 1].to != ranges[i].from ? 0.0
          : [kCompCrossfadeSeconds / 2 * perOut, (ranges[i - 1].to - ranges[i - 1].from) / 2,
              (ranges[i].to - ranges[i].from) / 2].reduce(math.min),
  ];
  final out = <AudioClipDoc>[];
  for (final (i, r) in ranges.indexed) {
    final last = i == ranges.length - 1;
    final a = r.from - half[i], b = r.to + (last ? 0 : half[i + 1]);
    final part = c.copyWith(id: '${c.id}~$i', startSteps: audioStepAt(p, c, a))
      ..assetId = r.take
      ..offsetSeconds = wrapOffset(c, a, p.asset(r.take)!.seconds)
      ..comp = []
      ..takes = [];
    if (c.fixed) {
      part.lengthSeconds = (b - a) / perOut;
    } else {
      part.sourceBpm = c.sourceTempo(p.bpm, _assetBpm(p, c));
      part.setLength((b - a) / c.sourcePerStep(p.bpm, _assetBpm(p, c)), p.bpm);
    }
    final seconds = (b - a) / perOut;
    if (i == 0) {
      part.fadeIn = math.min(c.fadeIn, seconds);
    } else {
      part
        ..fadeIn = 2 * half[i] / perOut
        ..fadeInCurve = FadeCurve.equalPower;
    }
    if (last) {
      part.fadeOut = math.min(c.fadeOut, seconds - part.fadeIn);
    } else {
      part
        ..fadeOut = 2 * half[i + 1] / perOut
        ..fadeOutCurve = FadeCurve.equalPower;
    }
    out.add(part);
  }
  return out;
}

/// A clip with takes to comp, MIDI ([midi]) or audio ([audio]): the take lanes' rows show one of these each.
class TakeClip {
  const TakeClip.midi(ClipDoc this.midi) : audio = null;
  const TakeClip.audio(AudioClipDoc this.audio) : midi = null;
  final ClipDoc? midi;
  final AudioClipDoc? audio;

  String get id => midi?.id ?? audio!.id;
  List<String> get takes => midi?.takes ?? audio!.takes;
  List<CompPartDoc> get comp => midi != null ? midiComp(midi!) : audioComp(audio!);
  bool get comped => (midi?.comp ?? audio!.comp).isNotEmpty;
  bool get locked => midi?.lock ?? audio!.lock;
  double get start => midi?.startSteps.toDouble() ?? audio!.startSteps;
  double end(ProjectDoc p) => midi != null ? (midi!.startSteps + midi!.lengthSteps).toDouble()
      : audio!.startSteps + audio!.spanSteps(p.tempo);

  /// Where song step [step] falls in the comp's units (pattern steps or file seconds).
  double compAt(ProjectDoc p, double step) => midi != null ? midiCompAt(p, midi!, step) : audioSourceAt(p, audio!, step);

  /// The song steps where [comp]'s joins fall in the clip (a MIDI clip's at every pass of its loop).
  List<double> joins(ProjectDoc p) {
    final parts = comp;
    if (parts.length < 2) return const [];
    if (audio != null) {
      final u0 = audio!.offsetSeconds, u1 = audioSourceEnd(p, audio!);
      return [for (final j in parts.skip(1)) if (j.from > u0 && j.from < u1) audioStepAt(p, audio!, j.from)];
    }
    final c = midi!;
    final loop = c.loop ? p.clipLoopSteps(c) : 1 << 30;
    final out = <double>[];
    final end = c.startSteps + c.lengthSteps;
    for (var pass = 0; pass < 4096; pass++) {
      final base = c.startSteps - c.sourceOffsetSteps + pass * loop;
      if (base >= end) break;
      for (final j in parts.skip(1)) {
        final at = base + j.from;
        if (at > c.startSteps && at < end) out.add(at);
      }
      if (!c.loop) break;
    }
    return out;
  }
}

/// The clips on [l] with two or more takes, MIDI then audio, each in time order: the take lanes' clips.
List<TakeClip> takeClips(LayerDoc l) => [
      for (final c in [...l.clips]..sort((a, b) => a.startSteps.compareTo(b.startSteps)))
        if (c.takes.length > 1) TakeClip.midi(c),
      for (final c in [...l.audioClips]..sort((a, b) => a.startSteps.compareTo(b.startSteps)))
        if (c.takes.length > 1) TakeClip.audio(c),
    ];

/// How many take lanes [l] has: its clips' most takes (0 under two).
int takeLaneCount(LayerDoc l) => takeClips(l).fold<int>(0, (n, c) => math.max(n, c.takes.length));

extension Comping on AppState {
  /// Plays [parts] on [c] (one undo step): a MIDI clip a comp pattern built from them (its own, made the first
  /// time), an audio clip its parts with crossfades; one part plays that take whole. False when nothing changed
  /// (a frozen track asks "Unfreeze to edit?" first, a take that doesn't read, a locked clip).
  bool setComp(LayerDoc layer, TakeClip c, List<CompPartDoc> parts) {
    final next = normalizeComp(parts);
    if (next.isEmpty || next.length > kMaxCompParts || c.locked) return false;
    if (next.any((x) => !c.takes.contains(x.take))) return false;
    if (guardFrozen(layer)) return false;
    final current = c.comped ? c.comp : const <CompPartDoc>[];
    if (next.length < 2 ? !c.comped && c.comp.first.take == next.first.take : _same(current, next)) return false;
    if (c.audio case final a?) {
      editAudioClip(layer, a, (x) {
        if (next.length < 2) {
          x
            ..comp = []
            ..assetId = next.single.take;
        } else {
          x.comp = next;
        }
      });
      return true;
    }
    final clip = c.midi!;
    String? text;
    if (next.length >= 2) {
      text = midiCompText(project, next, 'Comp');
      if (text == null) return false;
    }
    endUndoStep();
    editProject((p) {
      final old = clip.patternId;
      final own = clip.comp.isNotEmpty && !clip.takes.contains(old) ? p.module(old) : null;
      if (text == null) {
        clip
          ..comp = []
          ..patternId = next.single.take;
        if (own != null) _dropUnused(p, {own.id});
        return;
      }
      if (own != null && _users(p, own.id) == 1) {
        own
          ..source = text
          ..runSource = text;
      } else {
        final m = ModuleDoc(id: newId('m'), name: _uniqueModuleName(p, 'Comp'), source: text);
        p.modules.add(m);
        clip.patternId = m.id;
      }
      clip.comp = next;
    });
    endUndoStep();
    return true;
  }

  /// A swipe across take [take]'s lane over song steps [from]..[to] (either way round): that range of [c] plays
  /// [take]. A MIDI comp's ends are whole steps of its pattern.
  bool swipeTake(LayerDoc layer, TakeClip c, String take, double from, double to) {
    final lo = math.max(math.min(from, to), c.start), hi = math.min(math.max(from, to), c.end(project));
    if (hi <= lo) return false;
    var a = c.compAt(project, lo), b = a + (c.audio != null ? c.compAt(project, hi) - a : hi - lo);
    if (c.midi case final m?) {
      if (m.loop) b = math.min(b, project.clipLoopSteps(m).toDouble());
      a = a.roundToDouble();
      b = b.roundToDouble();
    }
    if (b <= a) return false;
    return setComp(layer, c, swipeComp(c.comp, take, a, b));
  }

  /// [c] plays [take] whole (a take lane's double tap).
  bool useWholeTake(LayerDoc layer, TakeClip c, String take) => setComp(layer, c, [CompPartDoc(take, 0)]);

  /// Moves join [index] of [c]'s comp (the start of its part [index]) to song step [step], between its neighbours.
  bool moveCompJoin(LayerDoc layer, TakeClip c, int index, double step) {
    final parts = c.comp;
    if (index <= 0 || index >= parts.length) return false;
    var at = c.compAt(project, step);
    if (c.midi != null) at = at.roundToDouble();
    final lo = parts[index - 1].from, hi = index + 1 < parts.length ? parts[index + 1].from : double.infinity;
    if (!(at > lo && at < hi) || at == parts[index].from) return false;
    return setComp(layer, c, [for (final (i, p) in parts.indexed) i == index ? CompPartDoc(p.take, at) : p]);
  }

  /// Flatten (one undo step): each of [clips] on [layer] becomes ordinary clips playing what it plays now (a MIDI
  /// clip keeps its comp pattern; an audio comp becomes a clip per part, crossfades as fades) and the takes nothing
  /// plays any more leave the project. False when there was nothing to flatten.
  bool flattenTakes(LayerDoc layer, List<TakeClip> clips) {
    final chosen = [for (final c in clips) if (c.takes.length > 1 && !c.locked) c];
    if (chosen.isEmpty || guardFrozen(layer)) return false;
    endUndoStep();
    editProject((p) {
      final modules = <String>{}, assets = <String>{};
      for (final c in chosen) {
        if (c.midi case final m?) {
          modules.addAll(m.takes);
          m
            ..takes = []
            ..comp = [];
        } else {
          final a = c.audio!;
          assets.addAll(a.takes);
          final parts = compAudioParts(p, a);
          if (a.comp.length >= 2) {
            final at = layer.audioClips.indexOf(a);
            layer.audioClips
              ..removeAt(at)
              ..insertAll(at, [
                for (final x in parts)
                  x.copyWith(id: newId('ac'))
                    ..takes = []
                    ..comp = [],
              ]);
          } else {
            a.takes = [];
          }
        }
      }
      _dropUnused(p, modules);
      for (final id in assets) {
        final used = p.layers.any((l) => l.frozenAsset == id ||
            l.audioClips.any((c) => c.assetId == id || c.takes.contains(id)));
        if (!used) p.assets.removeWhere((x) => x.id == id);
      }
    });
    endUndoStep();
    return true;
  }

  static bool _same(List<CompPartDoc> a, List<CompPartDoc> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// How many clips play or keep module [id] (as their pattern or a take).
  static int _users(ProjectDoc p, String id) => p.layers.fold(0, (n, l) =>
      n + l.clips.where((c) => c.patternId == id || c.takes.contains(id)).length + (l.patternId == id ? 1 : 0));

  /// Takes the modules [ids] out of [p] where no clip or track plays or keeps them any more.
  static void _dropUnused(ProjectDoc p, Set<String> ids) =>
      p.modules.removeWhere((m) => ids.contains(m.id) && _users(p, m.id) == 0);

  static String _uniqueModuleName(ProjectDoc p, String base) {
    if (p.modules.every((m) => m.name != base)) return base;
    var n = 2;
    while (p.modules.any((m) => m.name == '$base $n')) {
      n++;
    }
    return '$base $n';
  }
}
