// The tempo map and time signatures (batch 1.0.3, #207): their project JSON with bounded parsing, beat↔seconds with
// closed-form ramps (the engine's maths, C API 31), beat↔bar.beat from the signatures, and the engine interface.
import 'dart:math' as math;

/// The most tempo points and time signatures a project keeps (the contract's limits).
const kMaxTempoPoints = 4096;
const kMaxTimeSignatures = 1024;

/// The tempo range a point can hold, in quarter notes a minute.
const kMinMapBpm = 1.0, kMaxMapBpm = 999.0;

/// The denominators a time signature can have.
const kSignatureDens = [1, 2, 4, 8, 16, 32];

/// A tempo point: from [beat] on the tempo is [bpm]. With [ramp] the tempo goes there linearly in BPM over beats from
/// the previous point, instead of jumping at [beat].
class TempoPoint {
  const TempoPoint(this.beat, this.bpm, {this.ramp = false});
  final double beat, bpm;
  final bool ramp;

  TempoPoint copyWith({double? beat, double? bpm, bool? ramp}) =>
      TempoPoint(beat ?? this.beat, bpm ?? this.bpm, ramp: ramp ?? this.ramp);

  Map<String, dynamic> toJson() => {'beat': beat, 'bpm': bpm, 'ramp': ramp};

  @override
  bool operator ==(Object other) => other is TempoPoint && other.beat == beat && other.bpm == bpm && other.ramp == ramp;
  @override
  int get hashCode => Object.hash(beat, bpm, ramp);
  @override
  String toString() => 'TempoPoint($beat, $bpm${ramp ? ', ramp' : ''})';
}

/// A time signature from bar [bar] (0-based) on, which starts at [beat]: [num] over [den].
class TimeSignature {
  const TimeSignature(this.bar, this.beat, this.num, this.den);
  final int bar;
  final double beat;
  final int num, den;

  /// A bar's length in beats (quarter notes): 4/4 is 4, 6/8 is 3, 7/16 is 1.75.
  double get barBeats => num * 4 / den;

  /// One of the signature's own beats (a [den]th note) in quarter notes.
  double get unitBeats => 4 / den;

  String get label => '$num/$den';

  Map<String, dynamic> toJson() => {'bar': bar, 'beat': beat, 'num': num, 'den': den};

  @override
  bool operator ==(Object other) =>
      other is TimeSignature && other.bar == bar && other.beat == beat && other.num == num && other.den == den;
  @override
  int get hashCode => Object.hash(bar, beat, num, den);
  @override
  String toString() => 'TimeSignature(bar $bar, beat $beat, $num/$den)';
}

/// What the engine's C API 31 binding implements (`Engine` in lib/engine/engine.dart): the app hands it the map and
/// the signatures after each project sync. An engine without it keeps the project JSON's `bpm` and `beats_per_bar`.
abstract interface class TempoEngine {
  /// `caw_engine_set_tempo_map`: [points] sorted by beat, the first at beat 0, each 1–999 BPM. False when refused.
  bool setTempoMap(List<TempoPoint> points);

  /// `caw_engine_set_time_signatures`: [signatures] sorted, the first at bar 0 and beat 0. False when refused.
  bool setTimeSignatures(List<TimeSignature> signatures);
}

double _clampBpm(num v) => v.toDouble().clamp(kMinMapBpm, kMaxMapBpm).toDouble();

/// A tempo map read from untrusted [raw] (the project's `tempo_map`): at most [kMaxTempoPoints] points, each beat
/// finite in 0..[maxBeat], each tempo held to 1–999 BPM, sorted, one point a beat (the last one read wins), and a
/// point at beat 0 ([fallbackBpm] when the file has none). Null when [raw] isn't a list.
List<TempoPoint>? tempoMapFromJson(Object? raw, {required double fallbackBpm, required double maxBeat}) {
  if (raw is! List) return null;
  final byBeat = <double, TempoPoint>{};
  for (final e in raw.take(kMaxTempoPoints)) {
    if (e is! Map) continue;
    final beat = e['beat'], bpm = e['bpm'];
    if (beat is! num || bpm is! num || !beat.isFinite || !bpm.isFinite || beat < 0 || beat > maxBeat) continue;
    byBeat[beat.toDouble()] = TempoPoint(beat.toDouble(), _clampBpm(bpm), ramp: e['ramp'] == true);
  }
  return normalizeTempoMap(byBeat.values.toList(), fallbackBpm: fallbackBpm);
}

/// [points] sorted, with a non-ramp point at beat 0 ([fallbackBpm] when there is none) and at most [kMaxTempoPoints].
List<TempoPoint> normalizeTempoMap(List<TempoPoint> points, {required double fallbackBpm}) {
  final sorted = [...points]..sort((a, b) => a.beat.compareTo(b.beat));
  final out = <TempoPoint>[];
  for (final p in sorted) {
    if (out.isNotEmpty && out.last.beat == p.beat) out.removeLast();
    out.add(p);
  }
  if (out.isEmpty || out.first.beat > 0) out.insert(0, TempoPoint(0, _clampBpm(fallbackBpm)));
  out[0] = out[0].copyWith(ramp: false);
  return out.take(kMaxTempoPoints).toList();
}

/// Time signatures read from untrusted [raw] (the project's `time_signatures`): at most [kMaxTimeSignatures], each
/// `num` 1–32 and `den` one of [kSignatureDens], sorted by bar, one a bar, the first at bar 0 ([fallbackNum]/4 when
/// the file has none), and each `beat` recomputed from the bars before it (the stored one is only a check). Null
/// when [raw] isn't a list.
List<TimeSignature>? timeSignaturesFromJson(Object? raw, {required int fallbackNum, required int maxBar}) {
  if (raw is! List) return null;
  final byBar = <int, (int, int)>{};
  for (final e in raw.take(kMaxTimeSignatures)) {
    if (e is! Map) continue;
    final bar = e['bar'], n = e['num'], d = e['den'];
    if (bar is! num || n is! num || d is! num || !bar.isFinite || bar < 0 || bar > maxBar) continue;
    if (n != n.roundToDouble() || n < 1 || n > 32 || !kSignatureDens.contains(d)) continue;
    byBar[bar.toInt()] = (n.toInt(), d.toInt());
  }
  return normalizeSignatures([for (final MapEntry(key: bar, value: (n, d)) in byBar.entries) (bar: bar, num: n, den: d)],
      fallbackNum: fallbackNum);
}

/// Signatures at [bars], sorted, one a bar, the first at bar 0, with their beats computed; a signature that repeats
/// the one before it is dropped.
List<TimeSignature> normalizeSignatures(List<({int bar, int num, int den})> bars, {int fallbackNum = 4}) {
  final sorted = [...bars]..sort((a, b) => a.bar.compareTo(b.bar));
  final out = <TimeSignature>[];
  for (final s in sorted.take(kMaxTimeSignatures)) {
    if (out.isEmpty) {
      out.add(TimeSignature(0, 0, s.bar == 0 ? s.num : fallbackNum.clamp(1, 32), s.bar == 0 ? s.den : 4));
      if (s.bar == 0) continue;
    }
    final prev = out.last;
    if (s.bar == prev.bar) {
      out[out.length - 1] = TimeSignature(prev.bar, prev.beat, s.num, s.den);
      continue;
    }
    if (s.num == prev.num && s.den == prev.den) continue;
    out.add(TimeSignature(s.bar, prev.beat + (s.bar - prev.bar) * prev.barBeats, s.num, s.den));
  }
  if (out.isEmpty) out.add(TimeSignature(0, 0, fallbackNum.clamp(1, 32), 4));
  // A repeat left by a replacement (a bar set back to the signature before it) goes too.
  for (var i = out.length - 1; i > 0; i--) {
    if (out[i].num == out[i - 1].num && out[i].den == out[i - 1].den) out.removeAt(i);
  }
  return [
    for (var i = 0; i < out.length; i++)
      i == 0 ? out[0] : TimeSignature(out[i].bar, _beatOfBar(out, i), out[i].num, out[i].den),
  ];
}

/// A signature by the beat it starts on (a MIDI file's, or one a section edit moved).
typedef SignatureAt = ({double beat, int num, int den});

/// Signatures given by the beats they start on, as bars: each lands on the nearest bar line of the one before it (at
/// least a bar after it). The first is at bar 0 whatever its beat.
List<TimeSignature> signaturesFromBeats(List<SignatureAt> at, int fallbackNum) {
  final sorted = [...at]..sort((x, y) => x.beat.compareTo(y.beat));
  final bars = <({int bar, int num, int den})>[];
  var prevBeat = 0.0, prevBar = 0, prevLen = 4.0;
  for (final s in sorted.take(kMaxTimeSignatures)) {
    if (s.num < 1 || s.num > 32 || !kSignatureDens.contains(s.den) || !s.beat.isFinite) continue;
    if (bars.isEmpty) {
      bars.add((bar: 0, num: s.num, den: s.den));
      prevLen = s.num * 4 / s.den;
      continue;
    }
    final n = math.max(1, ((s.beat - prevBeat) / prevLen).round());
    if (prevBar + n > (1 << 28)) break;
    bars.add((bar: prevBar + n, num: s.num, den: s.den));
    prevBeat += n * prevLen;
    prevBar += n;
    prevLen = s.num * 4 / s.den;
  }
  return normalizeSignatures(bars, fallbackNum: fallbackNum);
}

double _beatOfBar(List<TimeSignature> sigs, int i) {
  var beat = 0.0;
  for (var k = 1; k <= i; k++) {
    beat += (sigs[k].bar - sigs[k - 1].bar) * sigs[k - 1].barBeats;
  }
  return beat;
}

/// Beat↔seconds over a tempo map, as the engine computes it (C API 31): constant between points, and across a ramp
/// linear in BPM over beats, so `t = 60·Δbeat / (bpm1 − bpm0) · ln(bpm1 / bpm0)` exactly.
class TempoMath {
  TempoMath(List<TempoPoint> points) : points = List.unmodifiable(points) {
    assert(points.isNotEmpty && points.first.beat == 0);
    var t = 0.0;
    _sec = [0.0];
    for (var i = 1; i < points.length; i++) {
      t += _segSeconds(i, points[i].beat - points[i - 1].beat);
      _sec.add(t);
    }
  }

  final List<TempoPoint> points;
  late final List<double> _sec;

  /// One tempo all through.
  bool get constant => points.length == 1;

  /// The point in effect at [beat]: the last one at or before it.
  int indexAt(double beat) {
    var lo = 0, hi = points.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (points[mid].beat <= beat) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The tempo at [beat], in BPM: on a ramp, between its two points.
  double bpmAt(double beat) {
    final i = indexAt(beat);
    final p = points[i];
    if (i + 1 < points.length && points[i + 1].ramp) {
      final n = points[i + 1];
      return p.bpm + (n.bpm - p.bpm) * (beat - p.beat) / (n.beat - p.beat);
    }
    return p.bpm;
  }

  // Seconds from point i-1 to [d] beats after it, inside segment i (point i ramps or not).
  double _segSeconds(int i, double d) {
    final a = points[i - 1], b = points[i];
    if (!b.ramp || (b.bpm - a.bpm).abs() < 1e-12) return 60 * d / a.bpm;
    final len = b.beat - a.beat;
    final at = a.bpm + (b.bpm - a.bpm) * d / len;
    return 60 * len / (b.bpm - a.bpm) * math.log(at / a.bpm);
  }

  /// Seconds from the start to [beat] (negative beats count back at the first tempo).
  double secondsAt(double beat) {
    if (beat <= 0) return 60 * beat / points.first.bpm;
    final i = indexAt(beat);
    final d = beat - points[i].beat;
    if (i + 1 < points.length && points[i + 1].ramp) return _sec[i] + _segSeconds(i + 1, d);
    return _sec[i] + 60 * d / points[i].bpm;
  }

  /// The beat [seconds] after the start: the inverse of [secondsAt], in closed form.
  double beatAt(double seconds) {
    if (seconds <= 0) return seconds * points.first.bpm / 60;
    var lo = 0, hi = _sec.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_sec[mid] <= seconds) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final a = points[lo];
    final t = seconds - _sec[lo];
    if (lo + 1 < points.length && points[lo + 1].ramp && (points[lo + 1].bpm - a.bpm).abs() >= 1e-12) {
      final b = points[lo + 1];
      final len = b.beat - a.beat, k = (b.bpm - a.bpm) / len;
      // bpm(d) = a.bpm + k·d and t = 60/k · ln(bpm(d)/a.bpm), so d = a.bpm·(e^(k·t/60) − 1)/k.
      return a.beat + math.min(len, a.bpm * (math.exp(k * t / 60) - 1) / k);
    }
    return a.beat + t * a.bpm / 60;
  }
}

/// Bars from time signatures: where each bar starts, which bar and beat a position is in.
class BarMath {
  BarMath(List<TimeSignature> signatures) : signatures = List.unmodifiable(signatures) {
    assert(signatures.isNotEmpty && signatures.first.bar == 0);
  }

  final List<TimeSignature> signatures;

  /// One signature all through.
  bool get constant => signatures.length == 1;

  int _sigAtBeat(double beat) {
    var lo = 0, hi = signatures.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (signatures[mid].beat <= beat + 1e-9) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int _sigAtBar(int bar) {
    var lo = 0, hi = signatures.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (signatures[mid].bar <= bar) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The signature in effect at [beat].
  TimeSignature signatureAt(double beat) => signatures[_sigAtBeat(beat)];

  /// The signature in effect in bar [bar].
  TimeSignature signatureOfBar(int bar) => signatures[_sigAtBar(bar)];

  /// Where bar [bar] (0-based) starts, in beats.
  double beatOfBar(int bar) {
    if (bar <= 0) return bar * signatures.first.barBeats;
    final s = signatures[_sigAtBar(bar)];
    return s.beat + (bar - s.bar) * s.barBeats;
  }

  /// The bar (0-based) [beat] is in.
  int barAt(double beat) {
    if (beat < 0) return 0;
    final s = signatures[_sigAtBeat(beat)];
    return s.bar + ((beat - s.beat) / s.barBeats + 1e-9).floor();
  }

  /// [beat] as (bar, beat in the bar), both 0-based, the beat counted in the signature's own beats (eighths in 6/8)
  /// with its fraction.
  ({int bar, double beat}) barBeatAt(double beat) {
    final bar = barAt(beat);
    final s = signatureOfBar(bar);
    return (bar: bar, beat: math.max(0.0, (beat - beatOfBar(bar)) / s.unitBeats));
  }

  /// [beat] as "bar.beat", counting from 1 ("3.2").
  String label(double beat) {
    final bb = barBeatAt(beat);
    return '${bb.bar + 1}.${(bb.beat + 1e-9).floor() + 1}';
  }

  /// The beat of (0-based) [bar] and its (0-based, signature-unit) [beat]: the inverse of [barBeatAt].
  double beatOf(int bar, double beat) => beatOfBar(bar) + beat * signatureOfBar(bar).unitBeats;

  /// The bars that start between beats [from] and [to], at most [limit], each with its start, length in beats and
  /// whether a signature changes there. With [every] above 1, only bars whose number is a multiple of it.
  Iterable<({int bar, double beat, double length, TimeSignature? change})> bars(double from, double to,
      {int every = 1, int limit = 4096}) sync* {
    var bar = math.max(0, barAt(math.max(0, from)));
    if (every > 1) bar = bar ~/ every * every;
    var n = 0;
    while (n++ < limit) {
      final at = beatOfBar(bar);
      if (at > to) return;
      final i = _sigAtBar(bar);
      final s = signatures[i];
      yield (bar: bar, beat: at, length: s.barBeats, change: s.bar == bar ? s : null);
      bar += every;
    }
  }
}
