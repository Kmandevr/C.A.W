// What the flagship synth's editor draws, computed in Dart: wavetable frames and warps, the unison layout, LFO shapes and
// an approximate filter response. Tables, warps, unison and LFO shapes follow the engine's recipes
// (engine/src/builtin_flagship.cpp, caw/library/unison.hpp, caw/library/lfo.hpp); the filter curve is an approximation.
import 'dart:math' as math;
import 'dart:typed_data';

const _kH = 512; // the engine's harmonics per frame (frame size 1024 / 2)

/// The tables' names and frame counts (`kTables`): the built-in ones, then User (the imported table, its frames
/// [UserWavetable.frames]; one sine frame when none is loaded), then 1.1.0's Additive (eight rule-made spectra).
const List<String> wavetableNames = ['Basic', 'Analog', 'Vocal', 'Harmonic', 'Classic', 'User', 'Additive'];
const List<int> wavetableFrames = [4, 5, 5, 16, 4, 1, 8];

/// The User table's index in [wavetableNames] (`kUserTable`).
const userTableIndex = 5;

/// The User table as the flagship saves it (its component state, "CWT1": the frame count, the frame size 2048, then
/// 16-bit samples): each frame's 2048 samples, -1..1.
class UserWavetable {
  UserWavetable(this.frames);
  final List<Float32List> frames;

  /// Frame size of the saved form.
  static const frameSize = 2048;

  /// The most frames the engine takes.
  static const maxFrames = 256;

  /// Parses the saved form; null for anything else (an import envelope, a damaged state).
  static UserWavetable? parse(Uint8List b) {
    if (b.length < 12 || b[0] != 0x43 || b[1] != 0x57 || b[2] != 0x54 || b[3] != 0x31) return null;
    final d = ByteData.sublistView(b);
    final n = d.getUint32(4, Endian.little), size = d.getUint32(8, Endian.little);
    if (n < 1 || n > maxFrames || size != frameSize || b.length != 12 + n * frameSize * 2) return null;
    return UserWavetable([
      for (var f = 0; f < n; f++)
        Float32List.fromList([for (var i = 0; i < frameSize; i++) d.getInt16(12 + 2 * (f * frameSize + i), Endian.little) / 32767]),
    ]);
  }

  /// One frame at [points] samples (linearly between the saved samples).
  Float32List frame(int f, int points) {
    final x = frames[f.clamp(0, frames.length - 1)];
    final out = Float32List(points);
    for (var i = 0; i < points; i++) {
      final p = i * frameSize / points;
      final k = p.floor(), m = p - k;
      out[i] = x[k] + (x[(k + 1) % frameSize] - x[k]) * m;
    }
    return out;
  }
}

/// The import form of the User table the flagship takes as its state: "CWTI", [split] (0: the file is 2048-sample
/// frames, the usual single-cycle table export, a shorter file one cycle; 1..256: cut into that many equal frames),
/// then the WAV file's bytes. The engine decodes and checks it (untrusted) and saves the "CWT1" form.
Uint8List wavetableImport(Uint8List wav, int split) {
  final b = Uint8List(8 + wav.length);
  b.setAll(0, const [0x43, 0x57, 0x54, 0x49]);
  ByteData.sublistView(b).setUint32(4, split, Endian.little);
  b.setAll(8, wav);
  return b;
}

/// How many frames table [table] has ([user]: the loaded User table).
int tableFrameCount(int table, UserWavetable? user) =>
    table == userTableIndex ? (user?.frames.length ?? 1) : wavetableFrames[table.clamp(0, wavetableFrames.length - 1)];

/// The first three formants (Hz) of A, E, I, O, U (caw/library/formant.hpp).
const List<List<double>> vowelFormantsHz = [
  [730, 1090, 2440],
  [530, 1840, 2480],
  [270, 2290, 3010],
  [570, 840, 2410],
  [300, 870, 2240],
];

/// One frame as harmonic amplitudes and start phases (cycles), or a direct function of the phase.
class _Frame {
  _Frame.harmonics(this.amps, [this.phases]) : fn = null;
  _Frame.function(this.fn) : amps = null, phases = null;
  final Float64List? amps;
  final Float64List? phases;
  final double Function(double)? fn;
}

double _rolloff(int h, double corner) {
  final r = h / corner, r2 = r * r;
  return 1 / math.sqrt(1 + r2 * r2);
}

Float64List _amps(int n, double Function(int h) f) {
  final a = Float64List(n);
  for (var h = 1; h <= n; h++) {
    a[h - 1] = f(h);
  }
  return a;
}

double _saw(int h) => (h.isOdd ? 2.0 : -2.0) / (math.pi * h);
double _square(int h) => h.isOdd ? 4 / (math.pi * h) : 0;
double _triangle(int h) => h.isOdd ? ((h & 3) == 1 ? 8.0 : -8.0) / (math.pi * math.pi * h * h) : 0;

void _normalize(Float64List a) {
  var sum = 0.0;
  for (final x in a) {
    sum += x * x;
  }
  final rms = math.sqrt(0.5 * sum);
  if (rms > 0) {
    for (var i = 0; i < a.length; i++) {
      a[i] *= 0.57735026918962576 / rms;
    }
  }
}

final Float64List _schroeder = () {
  final p = Float64List(_kH);
  for (var h = 1; h <= _kH; h++) {
    final c = h * (h - 1) / (2.0 * _kH);
    p[h - 1] = c - c.floorToDouble();
  }
  return p;
}();

/// The drawing keeps fewer harmonics than the engine (which keeps 512): enough for the shape at a few hundred
/// pixels. Tables are otherwise built the same way.
const int drawnHarmonics = 96;

final List<List<_Frame>> _tables = () {
  const n = drawnHarmonics;
  final cosine = Float64List(n)..fillRange(0, n, 0.25);
  final basic = [
    _Frame.harmonics(Float64List.fromList([1])),
    _Frame.harmonics(_amps(n, _saw)),
    _Frame.harmonics(_amps(n, _square)),
    _Frame.harmonics(_amps(n, (h) => 4 / (math.pi * h) * math.sin(math.pi * h * 0.25)), cosine),
  ];
  final analog = [
    _Frame.harmonics(_amps(n, _triangle)),
    _Frame.harmonics(_amps(n, (h) => _saw(h) * _rolloff(h, 14))),
    _Frame.function((p) {
      const k = 5.0;
      final full = 1 - math.exp(-k);
      return p < 0.5 ? 2 * (1 - math.exp(-k * 2 * p)) / full - 1 : 2 * math.exp(-k * 2 * (p - 0.5)) - 1;
    }),
    _Frame.harmonics(_amps(n, (h) => _square(h) * _rolloff(h, 9))),
    _Frame.harmonics(_amps(n, (h) => 4 / (math.pi * h) * math.sin(math.pi * h * 0.1) * _rolloff(h, 20)), cosine),
  ];
  final phases = Float64List.sublistView(_schroeder, 0, n);
  final vocal = [
    for (var v = 0; v < 5; v++)
      _Frame.harmonics(() {
        // Every harmonic under 12 kHz at 120 Hz is below the 100th, so the drawing keeps them all.
        final a = Float64List(_kH);
        for (var h = 1; h <= _kH; h++) {
          final hz = 120.0 * h;
          var e = 0.01;
          const width = [90.0, 120.0, 160.0], gain = [1.0, 0.6, 0.35];
          for (var f = 0; f < 3; f++) {
            final d = (hz - vowelFormantsHz[v][f]) / width[f];
            e += gain[f] / (1 + d * d);
          }
          a[h - 1] = e / math.sqrt(h.toDouble()) * (hz < 12000 ? 1 : 0);
        }
        _normalize(a);
        return Float64List.sublistView(a, 0, n);
      }(), phases),
  ];
  final sweep = [
    for (var f = 0; f < 16; f++)
      _Frame.harmonics(() {
        final a = Float64List(_kH);
        final centre = 8.0 * f / 15.0;
        for (var h = 1; h <= _kH; h++) {
          final d = (math.log(h) / math.ln2 - centre) / 0.7;
          a[h - 1] = math.exp(-0.5 * d * d) / (0.5 + 0.1 * h) * 0.6;
        }
        a[0] += 0.6;
        _normalize(a);
        return Float64List.sublistView(a, 0, n);
      }(), phases),
  ];
  // Classic: sine, triangle, saw and square (rising from 0, the saw from -1, the square at +1).
  final classic = [
    _Frame.harmonics(Float64List.fromList([1])),
    _Frame.function((p) => p < 0.25 ? 4 * p : (p < 0.75 ? 2 - 4 * p : 4 * p - 4)),
    _Frame.function((p) => 2 * p - 1),
    _Frame.function((p) => p < 0.5 ? 1.0 : -1.0),
  ];
  // User with none loaded: a sine.
  final user = [_Frame.harmonics(Float64List.fromList([1]))];
  // Additive (1.1.0): saw, square, odd-heavy, even-heavy, a comb (every third missing), drawbars, a soft bright
  // spectrum and a hollow 20 % pulse, Schroeder's phases (the engine's rules).
  const bars = [0.0, 1.0, 0.8, 0.6, 0.5, 0.0, 0.4, 0.0, 0.3];
  final additive = [
    for (var f = 0; f < 8; f++)
      _Frame.harmonics(() {
        final a = Float64List(_kH);
        for (var h = 1; h <= _kH; h++) {
          final saw = 1.0 / h;
          a[h - 1] = switch (f) {
            0 => saw,
            1 => h.isOdd ? saw : 0,
            2 => h.isOdd ? saw : saw / 3,
            3 => h == 1 || h.isEven ? saw : saw / 4,
            4 => h % 3 != 0 ? saw : 0,
            5 => h <= 8 ? bars[h] : 0,
            6 => _rolloff(h, 64) / math.sqrt(h.toDouble()),
            _ => math.sin(math.pi * h * 0.2).abs() / h,
          };
        }
        _normalize(a);
        return Float64List.sublistView(a, 0, n);
      }(), phases),
  ];
  return [basic, analog, vocal, sweep, classic, user, additive];
}();

final Map<(int, int, int), Float32List> _frameCache = {};

/// Frame [frame] of table [table], as [points] samples of one cycle (cached; [user]: the loaded User table).
Float32List wavetableFrame(int table, int frame, {int points = 256, UserWavetable? user}) {
  table = table.clamp(0, _tables.length - 1);
  if (table == userTableIndex && user != null) return user.frame(frame, points);
  frame = frame.clamp(0, _tables[table].length - 1);
  return _frameCache.putIfAbsent((table, frame, points), () {
    final f = _tables[table][frame];
    final out = Float32List(points);
    for (var i = 0; i < points; i++) {
      final t = i / points;
      if (f.fn != null) {
        out[i] = f.fn!(t);
        continue;
      }
      var v = 0.0;
      final a = f.amps!;
      for (var h = 1; h <= a.length; h++) {
        if (a[h - 1] == 0) continue;
        final p = f.phases == null ? 0.0 : f.phases![h - 1];
        v += a[h - 1] * math.sin(2 * math.pi * (h * t + p));
      }
      out[i] = v;
    }
    return out;
  });
}

/// The warp modes (`kWarps`): 1.0's, then 1.1.0's (another oscillator multiplying or syncing this one, then the
/// spectral and additive warps the engine reads from precomputed banks).
enum Warp {
  none, bend, sync, mirror, quantize, fm, fold, oscFm,
  oscRm, oscAm, oscSync, stretch, shift, oddEven, formant, smear, disperse, cut, comb
}

/// What each warp is called on screen (`kWarps`).
const List<String> warpNames = ['None', 'Bend', 'Sync', 'Mirror', 'Quantize', 'FM', 'Fold', 'Osc FM',
  'Osc RM', 'Osc AM', 'Osc sync', 'Stretch', 'Shift', 'Odd/even', 'Formant', 'Smear', 'Disperse', 'Low/high cut', 'Comb'];

/// The warps that hear another oscillator (or noise): their oscillator's `oscN_mod_src` chooses it.
const Set<Warp> sourceWarps = {Warp.oscFm, Warp.oscRm, Warp.oscAm, Warp.oscSync};

/// The oscillator (1..3) Osc FM on oscillator [osc] hears: the one before it, round the ring (`fmSource`).
int oscFmSource(int osc) => osc == 1 ? 3 : osc - 1;

/// The oscillator (1..3) a source warp on [osc] hears for `oscN_mod_src` value [modSrc] (Prev, Osc 1..3, Noise):
/// null for noise. Itself counts as Prev, as in the engine.
int? modSourceOsc(int osc, int modSrc) {
  if (modSrc >= 4) return null;
  if (modSrc <= 0 || modSrc == osc) return oscFmSource(osc);
  return modSrc;
}

/// sin(2 pi u), as the engine's FM and fold warps approximate it (`sineCycles`).
double _sineCycles(double u) {
  final x = 2 * (u - u.floorToDouble()) - 1;
  final y = 4 * x * (1 - x.abs());
  return -(y + 0.225 * (y * y.abs() - y));
}

/// The phase 0..1 the table is read at for phase [t], after warp [mode] at [amount] 0..1 (the engine's `warp`);
/// [fmRatio] is the FM warp's ratio (`oscN_fm_ratio`). The fold warp shapes the level, not the phase: [foldLevel].
/// [modulator] is Osc FM's: the modulating oscillator's sample at this phase.
double warpPhase(double t, Warp mode, double amount, {int fmRatio = 1, double modulator = 0}) {
  if (amount <= 0) return t;
  switch (mode) {
    case Warp.oscFm:
      final y = t + amount * modulator.clamp(-2.0, 2.0) + 4;
      return math.min(y - y.floorToDouble(), 0.99999994);
    case Warp.fm:
      final y = t + 0.75 * amount * _sineCycles(fmRatio.clamp(1, 16) * t) + 1;
      return math.min(y - y.floorToDouble(), 0.99999994);
    case Warp.fold:
      return t;
    case Warp.bend:
      return math.min(t * (1 + amount * (1 - t)), 0.99999994);
    case Warp.sync:
      final s = t * (1 + 7 * amount);
      return s - s.floorToDouble();
    case Warp.mirror:
      final turn = 1 - 0.5 * amount;
      final y = t < turn ? t / turn : (1 - t) / (0.5 * amount);
      return math.min(y, 0.99999994);
    case Warp.quantize:
      final steps = math.pow(2, 8 - 7 * amount).floorToDouble();
      return (t * steps).floorToDouble() / steps;
    case Warp.oscSync:
      // The drawing syncs to its own cycle (one cycle of the source): the sweep's speed-up.
      final s = t * (1 + 7 * amount);
      return s - s.floorToDouble();
    case Warp.none || Warp.oscRm || Warp.oscAm:
      return t;
    case Warp.stretch || Warp.shift || Warp.oddEven || Warp.formant || Warp.smear || Warp.disperse || Warp.cut || Warp.comb:
      return t; // the spectral warps reshape the spectrum, not the phase: drawn unwarped
  }
}

/// A table level [v] after the fold warp at [amount] 0..1 (the engine's: a sine folder, drive 1..8, blended in).
double foldLevel(double v, double amount) {
  if (amount <= 0) return v;
  final drive = 1 + 7 * amount, blend = math.min(1.0, 4 * amount);
  return v + blend * (_sineCycles(0.25 * drive * v + 64) - v);
}

/// One cycle of an oscillator as drawn: table [table] at frame [position] 0..1 (between frames, linearly),
/// through [warp] at [amount], as [points] samples. [user] is the loaded User table; [modulator] Osc FM's (the
/// modulating oscillator's cycle) and [modRatio] its pitch over this one's.
Float32List oscillatorCycle(int table, double position, Warp warp, double amount,
    {int points = 256, int fmRatio = 1, UserWavetable? user, Float32List? modulator, double modRatio = 1}) {
  table = table.clamp(0, wavetableFrames.length - 1);
  final frames = tableFrameCount(table, user);
  final pos = position.clamp(0.0, 1.0) * (frames - 1);
  final f0 = pos.floor(), mix = pos - f0;
  final a = wavetableFrame(table, f0, points: points, user: user);
  final b = wavetableFrame(table, math.min(f0 + 1, frames - 1), points: points, user: user);
  double read(Float32List x, double t) {
    final p = t * points;
    final i = p.floor() % points, j = (i + 1) % points;
    final m = p - p.floorToDouble();
    return x[i] + (x[j] - x[i]) * m;
  }

  final out = Float32List(points);
  for (var i = 0; i < points; i++) {
    final u = i / points;
    final m = modulator == null ? 0.0 : read(modulator, (u * modRatio) % 1.0);
    final t = warpPhase(u, warp, amount, fmRatio: fmRatio, modulator: m);
    final va = read(a, t);
    final v = mix > 0 ? va + (read(b, t) - va) * mix : va;
    out[i] = warp == Warp.fold ? foldLevel(v, amount) : v;
  }
  return out;
}

/// One copy of a unison stack (caw/library/unison.hpp, `UnisonVoice`).
class UnisonCopy {
  const UnisonCopy(this.semitones, this.pan, this.gain);
  final double semitones, pan, gain;
}

/// The stack modes (`kStacks`).
double _stackSemitones(int stack, int i) => switch (stack) {
      1 => i.isOdd ? 12 : 0,
      2 => 12.0 * (i % 3),
      3 => i.isOdd ? 7 : 0,
      4 => const [0.0, 4.0, 7.0][i % 3],
      5 => const [0.0, 3.0, 7.0][i % 3],
      6 => (i % 16) == 0 ? 0 : 12 * math.log(i % 16 + 1) / math.ln2,
      _ => 0,
    };

/// The engine's unison layout: [voices] copies, [detuneSemis] for the outermost, [power] −1..1, [spread] 0..1,
/// [blend] 0..1 and stack mode [stack].
List<UnisonCopy> unisonLayout(int voices, double detuneSemis, double power, double spread, double blend, int stack) {
  final n = voices.clamp(1, 16);
  power = power.clamp(-1.0, 1.0);
  spread = spread.clamp(0.0, 1.0);
  blend = blend.clamp(0.0, 1.0);
  final exponent = math.pow(4, power).toDouble();
  final centreGain = blend < 0.5 ? 1.0 : 2 * (1 - blend);
  final otherGain = blend > 0.5 ? 1.0 : 2 * blend;
  final out = <UnisonCopy>[];
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final x = n == 1 ? 0.0 : 2.0 * i / (n - 1) - 1;
    final a = x.abs();
    final curve = a == 0 ? 0.0 : (a == 1 || power == 0 ? a : math.pow(a, exponent).toDouble());
    final semis = (x < 0 ? -curve : curve) * detuneSemis + _stackSemitones(stack, i);
    final pair = math.min(i, n - 1 - i);
    final lower = i < n - 1 - i;
    final side = (pair.isEven) == lower ? -1.0 : 1.0;
    final pan = i == n - 1 - i ? 0.0 : side * spread * a;
    final centre = n == 1 || i == (n - 1) ~/ 2 || i == n ~/ 2;
    final g = n == 1 ? 1.0 : (centre ? centreGain : otherGain);
    sum += g * g;
    out.add(UnisonCopy(semis, pan, g));
  }
  final scale = sum > 0 ? 1 / math.sqrt(sum) : 0.0;
  return [for (final c in out) UnisonCopy(c.semitones, c.pan, c.gain * scale)];
}

/// The LFO shapes (`kLfoShapes`).
const List<String> lfoShapeNames = ['Sine', 'Triangle', 'Saw up', 'Saw down', 'Square', 'Sample & hold', 'Smooth random'];

double _random(int cycle) {
  // A small integer hash: the drawing's random steps, stable from frame to frame (not the engine's sequence).
  var x = (cycle * 0x9E3779B1 + 0x7F4A7C15) & 0xFFFFFFFF;
  x ^= x >> 15;
  x = (x * 0x2C1B3C6D) & 0xFFFFFFFF;
  x ^= x >> 12;
  return (x & 0xFFFF) / 32767.5 - 1;
}

/// LFO [shape] at phase [t] of cycle [cycle] (−1..1).
double lfoValue(int shape, double t, {int cycle = 0}) {
  t = t - t.floorToDouble();
  return switch (shape) {
    0 => math.sin(2 * math.pi * t),
    1 => t < 0.25 ? 4 * t : (t < 0.75 ? 2 - 4 * t : 4 * t - 4),
    2 => 2 * t - 1,
    3 => 1 - 2 * t,
    4 => t < 0.5 ? 1 : -1,
    5 => _random(cycle),
    6 => () {
        final a = _random(cycle), b = _random(cycle + 1);
        final s = t * t * (3 - 2 * t);
        return a + (b - a) * s;
      }(),
    _ => 0,
  };
}

/// The LFO sync divisions in beats (`kLfoSyncBeats`; index 0 is free-running).
const List<double> lfoSyncBeats = [0, 0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32];

/// An LFO's rate in Hz: [rateHz] when free, else one cycle per division at [bpm].
double lfoHz(double rateHz, int sync, double bpm) {
  if (sync <= 0 || sync >= lfoSyncBeats.length) return rateHz;
  return bpm / 60 / lfoSyncBeats[sync];
}

/// The filter types (`kFilterTypes`): 1.0's, then 1.1.0's models.
const List<String> filterTypeNames = ['Ladder LP', 'Ladder HP', 'Ladder BP', 'SVF LP', 'SVF HP', 'SVF BP', 'SVF notch',
  'Comb', 'Formant', 'Diode LP', 'Sallen-Key', 'Phaser', 'Neg comb', 'Vowel'];

/// An APPROXIMATE magnitude response in dB at [hz], for drawing: textbook 4-pole ladder and 2-pole state-variable
/// shapes, a feedback comb and three formant peaks. It shows where the filter cuts and rings, not the engine's
/// exact curve (drive and the engine's own resonance scaling are left out).
double filterResponseDb(double hz, {required int type, required double cutoff, required double resonance,
    double morph = 0, double mix = 1}) {
  final w = hz / cutoff.clamp(20.0, 20000.0);
  final r = resonance.clamp(0.0, 1.0);
  double mag;
  // 1.1.0's models drawn as their nearest kin: the diode as the ladder low-pass, the Sallen-Key as the SVF low-pass.
  if (type == 9) type = 0;
  if (type == 10) type = 3;
  switch (type) {
    case 11:
      // Four (or with morph, eight) first-order all-passes summed with the input: notches where they turn 180°.
      final stages = morph >= 0.5 ? 8 : 4;
      final phase = stages * 2 * math.atan(w);
      mag = (0.5 * (1 + math.cos(phase))).abs().clamp(1e-3, 1.0);
      mag = math.sqrt(mag) * (1 + 0.6 * r * math.cos(phase).abs());
    case 12:
      // A negative feedback comb: peaks at odd multiples of half the cutoff.
      final g = -(0.4 + 0.595 * r);
      final ph = 2 * math.pi * w;
      final re = 1 - g * math.cos(ph), im = g * math.sin(ph);
      mag = math.sqrt(1 - g * g) / math.sqrt(re * re + im * im);
    case 0 || 1 || 2:
      // (1 + s)^4 + k with s = jw, k up to ~3.8 (self-oscillation at 4).
      final k = 3.8 * r;
      final re1 = 1.0, im1 = w; // 1 + jw
      // (1 + jw)^2 = 1 - w^2 + 2jw; squared again:
      final re2 = re1 * re1 - im1 * im1, im2 = 2 * re1 * im1;
      final re4 = re2 * re2 - im2 * im2 + k, im4 = 2 * re2 * im2;
      final den = math.sqrt(re4 * re4 + im4 * im4);
      final shape = switch (type) { 0 => 1.0, 1 => math.pow(w, 4).toDouble(), _ => 4 * w * w };
      mag = shape * (type == 0 ? 1 + k : 1) / den;
    case 3 || 4 || 5 || 6:
      final q = 0.5 + r * 12;
      final re = 1 - w * w, im = w / q;
      final den = math.sqrt(re * re + im * im);
      mag = switch (type) {
        3 => 1 / den,
        4 => w * w / den,
        5 => (w / q) / den,
        _ => (1 - w * w).abs() / den,
      };
    case 7:
      // A feedback comb with peaks at the cutoff and its multiples; morph damps the higher peaks.
      final g = 0.15 + 0.8 * r;
      final damp = g * math.pow(1 - 0.85 * morph.clamp(0.0, 1.0), math.log(1 + w) / math.ln2).toDouble();
      final ph = 2 * math.pi * w;
      final re = 1 - damp * math.cos(ph), im = damp * math.sin(ph);
      mag = (1 - damp) / math.sqrt(re * re + im * im);
    default:
      // Three vowel peaks, the vowel set by morph (A..U), moved by the cutoff over 1 kHz (Vowel: over the dry signal).
      final v = morph.clamp(0.0, 1.0) * 4;
      final v0 = v.floor().clamp(0, 4), v1 = math.min(v0 + 1, 4), m = v - v0;
      final shift = cutoff / 1000;
      final q = 4 + 16 * r;
      mag = 0;
      const gains = [1.0, 0.6, 0.35];
      for (var f = 0; f < 3; f++) {
        final fc = (vowelFormantsHz[v0][f] * (1 - m) + vowelFormantsHz[v1][f] * m) * shift;
        final x = hz / fc;
        final re = 1 - x * x, im = x / q;
        mag += gains[f] * (x / q) / math.sqrt(re * re + im * im);
      }
      if (type == 13) mag = 0.4 + 1.2 * mag;
  }
  final m = mix.clamp(0.0, 1.0);
  final out = m * mag + (1 - m);
  return 20 * math.log(math.max(out, 1e-5)) / math.ln10;
}
