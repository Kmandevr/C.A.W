// The dead-knob gate (with CAW_LIB): every knob of the 1.1.3 instruments, each variant, moved from its minimum to its maximum through the app's own live set path on a running engine, must change the sound measurably.
//
// Each knob goes through DeviceTarget.setLive, as a knob's drag does (AppState.setInstrumentParamLive, the bindings,
// caw_engine_set_component_param), while the engine plays the same struck-and-released chord before and after the
// move; the two renders are compared by level, loudness-normalised 1/3-octave band energy, spectral centroid, the
// loudness envelope and stereo width. A knob is dead when no measure moves past both a fixed audibility threshold and
// three times the distance between two renders at the same setting (an instrument's own randomness).
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/engine/bindings.dart';
import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// The instruments this gate covers (owner, 2026-11-25: the dead knobs were on 1.1.3's new instruments).
const _instruments = ['org.caw.starling', 'org.caw.nightingale', 'org.caw.curlew', 'org.caw.bittern', 'org.caw.woodpecker'];

const _rate = 48000;
const _fineBins = 342;  // up to 8 kHz at 2048 points
const _block = 256;

/// A chord across the instruments' ranges (a note outside one's range is silent, the others carry it).
const _chord = [36, 43, 48, 55, 60, 64, 67, 72, 79, 84];

/// The knobs a gated sweep leaves at their defaults: they set how much and how long, not what is heard.
const _kept = {'level', 'voices', 'release', 'space'};

/// Settings held still while the other knobs are measured: a random sway would hide what they do (Bittern's
/// living wind). Each is measured itself from there.
const _steady = {
  'org.caw.bittern': {'wind': 0.0},
};

/// Played at a medium velocity, where a velocity-sensitivity knob moves the level most.
const _velocity = 0.4;

/// Thresholds a listener hears (dB, octaves); each is also raised to 3x the same-setting distance.
const _minLevelDb = 1.0, _minBandsDb = 1.0, _minCentroidOct = 0.08, _minEnvelopeDb = 1.5, _minSideDb = 2.0,
    _minOnsetMs = 4.0, _minFineDb = 2.0, _minWobbleDb = 0.4,
    _minRateOct = 0.5;

/// The measures of one render.
class _Features {
  _Features(this.levelDb, this.bandsDb, this.centroid, this.envelopeDb, this.sideDb, this.onsetMs, this.fineDb,
      this.wobbleDb, this.rateHz);
  final double levelDb, centroid, sideDb, onsetMs;

  /// How much the held chord's loudness swings around its own slow course (a tremolo, a tremulant, a motor), dB.
  final double wobbleDb;

  /// The swing's rate: the centroid of the held loudness's modulation spectrum, 1.5-15 Hz.
  final double rateHz;
  final List<double> bandsDb, envelopeDb;

  /// Each frame's spectrum, bin by bin, in dB under the take's loudest bin (floored 50 dB down): what a vibrato,
  /// a beating or a detune moves while the bands stay put.
  final List<Float64List> fineDb;
}

/// How far apart two renders are, per measure.
class _Distance {
  _Distance(this.level, this.bands, this.centroid, this.envelope, this.side, this.onset, this.fine, this.wobble,
      this.rate);
  final double level, bands, centroid, envelope, side, onset, fine, wobble, rate;

  static _Distance between(_Features a, _Features b) {
    // Bands normalised by each render's own level, over the bands either render has within 40 dB of its loudest.
    final na = [for (final x in a.bandsDb) x - a.levelDb], nb = [for (final x in b.bandsDb) x - b.levelDb];
    final topA = na.reduce(math.max), topB = nb.reduce(math.max);
    var sum = 0.0, n = 0;
    for (var i = 0; i < na.length; i++) {
      if (na[i] < topA - 40 && nb[i] < topB - 40) continue;
      final d = math.max(na[i], topA - 40) - math.max(nb[i], topB - 40);
      sum += d * d;
      n++;
    }
    var env = 0.0;
    final m = math.min(a.envelopeDb.length, b.envelopeDb.length);
    for (var i = 0; i < m; i++) {
      env += ((a.envelopeDb[i] - a.levelDb) - (b.envelopeDb[i] - b.levelDb)).abs();
    }
    return _Distance(
      (a.levelDb - b.levelDb).abs(),
      n == 0 ? 0 : math.sqrt(sum / n),
      a.centroid <= 0 || b.centroid <= 0 ? 0 : (math.log(a.centroid / b.centroid) / math.ln2).abs(),
      m == 0 ? 0 : env / m,
      (a.sideDb - b.sideDb).abs(),
      (a.onsetMs - b.onsetMs).abs(),
      _fineDistance(a.fineDb, b.fineDb),
      (a.wobbleDb - b.wobbleDb).abs(),
      // Only between two takes that both swing clearly enough to have a rate.
      a.wobbleDb < 0.5 || b.wobbleDb < 0.5 || a.rateHz <= 0 || b.rateHz <= 0
          ? 0
          : (math.log(a.rateHz / b.rateHz) / math.ln2).abs(),
    );
  }

  /// Each measure's largest over [all].
  static _Distance largest(List<_Distance> all) {
    double top(double Function(_Distance d) f) => all.map(f).reduce(math.max);
    return _Distance(top((d) => d.level), top((d) => d.bands), top((d) => d.centroid), top((d) => d.envelope),
        top((d) => d.side), top((d) => d.onset), top((d) => d.fine), top((d) => d.wobble), top((d) => d.rate));
  }

  /// Each measure's smallest over [all].
  static _Distance smallest(List<_Distance> all) {
    double low(double Function(_Distance d) f) => all.map(f).reduce(math.min);
    return _Distance(low((d) => d.level), low((d) => d.bands), low((d) => d.centroid), low((d) => d.envelope),
        low((d) => d.side), low((d) => d.onset), low((d) => d.fine), low((d) => d.wobble), low((d) => d.rate));
  }

  /// Whether this is beyond what a listener hears and beyond [floor] (the same-setting distance) [factor] times.
  bool audible(_Distance floor, [double factor = 3]) =>
      level > math.max(_minLevelDb, factor * floor.level) ||
      bands > math.max(_minBandsDb, factor * floor.bands) ||
      centroid > math.max(_minCentroidOct, factor * floor.centroid) ||
      envelope > math.max(_minEnvelopeDb, factor * floor.envelope) ||
      side > math.max(_minSideDb, factor * floor.side) ||
      onset > math.max(_minOnsetMs, factor * floor.onset) ||
      fine > math.max(_minFineDb, factor * floor.fine) ||
      wobble > math.max(_minWobbleDb, factor * floor.wobble) ||
      rate > math.max(_minRateOct, factor * floor.rate);

  /// Whether every measure is (nearly) zero: two takes at one setting gave the same sound.
  bool get still => level < 0.01 && bands < 0.01 && fine < 0.05 && envelope < 0.01;

  @override
  String toString() => 'level ${level.toStringAsFixed(2)} dB, bands ${bands.toStringAsFixed(2)} dB, centroid '
      '${centroid.toStringAsFixed(3)} oct, envelope ${envelope.toStringAsFixed(2)} dB, side ${side.toStringAsFixed(2)} dB, onset '
      '${onset.toStringAsFixed(1)} ms, fine ${fine.toStringAsFixed(2)} dB, wobble '
      '${wobble.toStringAsFixed(2)} dB, rate ${rate.toStringAsFixed(2)} oct';
}

/// In-place radix-2 FFT of [re] and [im] (length a power of two).
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i], ti = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = tr;
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len, wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ar = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
        final ai = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
        re[i + k + len ~/ 2] = re[i + k] - ar;
        im[i + k + len ~/ 2] = im[i + k] - ai;
        re[i + k] += ar;
        im[i + k] += ai;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}

/// The mean distance of two takes' frame spectra, over the bins either has above its floor.
double _fineDistance(List<Float64List> a, List<Float64List> b) {
  var sum = 0.0, n = 0;
  for (var f = 0; f < math.min(a.length, b.length); f++) {
    for (var k = 0; k < a[f].length; k++) {
      if (a[f][k] <= -50 && b[f][k] <= -50) continue;
      sum += (a[f][k] - b[f][k]).abs();
      n++;
    }
  }
  return n == 0 ? 0 : sum / n;
}

/// The centroid (Hz) of the loudness's modulation spectrum over the held part after its first 0.25 s, 1.5-15 Hz.
double _modulationRate(Float32List left, Float32List right, int heldFrames) {
  const hop = 256, frameRate = _rate / hop;
  final env = <double>[];
  for (var at = _rate ~/ 4; at + hop <= math.min(heldFrames, left.length); at += hop) {
    var e = 0.0;
    for (var i = at; i < at + hop; i++) {
      e += left[i] * left[i] + right[i] * right[i];
    }
    env.add(_db(e / hop));
  }
  final n = env.length;
  if (n < 16) return 0;
  // Detrended (a least-squares line out), so a decay is not read as a slow swing.
  var mx = 0.0, my = 0.0;
  for (var i = 0; i < n; i++) {
    mx += i;
    my += env[i];
  }
  mx /= n;
  my /= n;
  var sxy = 0.0, sxx = 0.0;
  for (var i = 0; i < n; i++) {
    sxy += (i - mx) * (env[i] - my);
    sxx += (i - mx) * (i - mx);
  }
  final slope = sxx == 0 ? 0 : sxy / sxx;
  var weighted = 0.0, power = 0.0;
  for (var f = 1.5; f <= 15; f += 0.25) {
    var re = 0.0, im = 0.0;
    for (var i = 0; i < n; i++) {
      final x = env[i] - my - slope * (i - mx), w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      re += x * w * math.cos(2 * math.pi * f * i / frameRate);
      im -= x * w * math.sin(2 * math.pi * f * i / frameRate);
    }
    final pw = re * re + im * im;
    weighted += f * pw;
    power += pw;
  }
  return power <= 0 ? 0 : weighted / power;
}

double _db(double energy) => 10 * math.log(math.max(energy, 1e-20)) / math.ln10;

/// The measures of a stereo render.
_Features _measure(Float32List left, Float32List right, int heldFrames) {
  const size = 2048, hop = 1024;
  final window = Float64List(size);
  for (var i = 0; i < size; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / size);
  }
  // 1/3-octave bands from 40 Hz to 16 kHz.
  final edges = <double>[];
  for (var f = 40 / math.pow(2, 1 / 6); f < 18000; f *= math.pow(2, 1 / 3)) {
    edges.add(f);
  }
  final bands = Float64List(edges.length - 1);
  final envelope = <double>[];
  final spectra = <Float64List>[];
  var total = 0.0, side = 0.0, weighted = 0.0, power = 0.0;
  final re = Float64List(size), im = Float64List(size);
  for (var start = 0; start + size <= left.length; start += hop) {
    var frame = 0.0;
    for (var i = 0; i < size; i++) {
      final l = left[start + i], r = right[start + i];
      final mid = 0.5 * (l + r), s = 0.5 * (l - r);
      re[i] = mid * window[i];
      im[i] = 0;
      if (i < hop) {
        frame += l * l + r * r;
        side += s * s;
      }
    }
    total += frame;
    envelope.add(_db(frame / hop));
    _fft(re, im);
    final fine = Float64List(_fineBins);
    spectra.add(fine);
    for (var k = 1; k < size ~/ 2; k++) {
      final f = k * _rate / size, e = re[k] * re[k] + im[k] * im[k];
      if (k < _fineBins) fine[k] = _db(e);
      weighted += f * e;
      power += e;
      for (var b = 0; b < bands.length; b++) {
        if (f >= edges[b] && f < edges[b + 1]) {
          bands[b] += e;
          break;
        }
      }
    }
  }
  // The onset: the first sample 40 dB under the take's peak.
  var peak = 0.0;
  for (var i = 0; i < left.length; i++) {
    peak = math.max(peak, math.max(left[i].abs(), right[i].abs()));
  }
  var onset = left.length;
  for (var i = 0; i < left.length; i++) {
    if (math.max(left[i].abs(), right[i].abs()) > peak * 0.01) {
      onset = i;
      break;
    }
  }
  final frames = math.max(1, envelope.length);
  // The envelope floored 40 dB under its loudest frame: what happens in the near-silence below is not heard.
  final loudest = envelope.isEmpty ? 0.0 : envelope.reduce(math.max);
  for (var i = 0; i < envelope.length; i++) {
    envelope[i] = math.max(envelope[i], loudest - 40);
  }
  // The wobble: over the held chord after its attack, each frame against the mean of the nine around it.
  final held = math.min(envelope.length, heldFrames ~/ hop);
  var wobble = 0.0, wobbleN = 0;
  for (var i = 12; i < held - 4; i++) {
    var mean = 0.0;
    for (var j = i - 4; j <= i + 4; j++) {
      mean += envelope[j];
    }
    final d = envelope[i] - mean / 9;
    wobble += d * d;
    wobbleN++;
  }
  // The fine spectra relative to the take's loudest bin, under the 8 kHz the bins below reach (bin 341 of 2048).
  var top = -400.0;
  for (final f in spectra) {
    for (var k = 1; k < f.length; k++) {
      top = math.max(top, f[k]);
    }
  }
  for (final f in spectra) {
    for (var k = 0; k < f.length; k++) {
      f[k] = math.max(-50, f[k] - top);
    }
  }
  return _Features(_db(total / (frames * hop)), [for (final b in bands) _db(b / frames)],
      power <= 0 ? 0 : weighted / power, envelope, _db(side) - _db(total / 2 + 1e-20), onset * 1000 / _rate, spectra,
      wobbleN == 0 ? 0 : math.sqrt(wobble / wobbleN), _modulationRate(left, right, heldFrames));
}

/// Renders the engine's output in blocks into [into] from [at] for [frames] frames.
void _render(Pointer<Void> h, Pointer<Float> l, Pointer<Float> r, Float32List intoL, Float32List intoR, int at, int frames) {
  final b = Bindings.instance;
  for (var done = 0; done < frames; done += _block) {
    final n = math.min(_block, frames - done);
    b.process(h, l, r, n);
    for (var i = 0; i < n; i++) {
      if (at + done + i < intoL.length) {
        intoL[at + done + i] = l[i];
        intoR[at + done + i] = r[i];
      }
    }
  }
}

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final noLib = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  testWidgets('every knob of the 1.1.3 instruments, each variant, changes the sound when moved live', (tester) async {
    // One app state for every device: disposing it disposes its engine.
    final e = Engine.create();
    final s = AppState(settings: Settings());
    s.engine = e;
    final h = Pointer<Void>.fromAddress(e.nativeAddress!);
    final catalog = await tester.runAsync(() => e.nativeComponents());
    s.componentCatalog.set(catalog!);
    final infos = {for (final c in catalog) c.id: c};
    final left = calloc<Float>(_block), right = calloc<Float>(_block);
    final dead = <String>[], gated = <String>[];
    final report = StringBuffer();
    var noteId = 1;

    // One take: the chord struck, held 0.8 s, released and heard 0.6 s, after a 0.5 s gap that lets a moved value
    // settle and the last take's tail fade.
    const gap = _rate ~/ 2, hold = _rate * 8 ~/ 10, tail = _rate * 6 ~/ 10;
    _Features take(String layer) {
      final l = Float32List(hold + tail), r = Float32List(hold + tail);
      final scratchL = Float32List(0), scratchR = Float32List(0);
      _render(h, left, right, scratchL, scratchR, 0, gap);
      final ids = <int>[];
      for (final p in _chord) {
        ids.add(noteId);
        e.noteOn(layer, noteId++, p.toDouble(), _velocity);
      }
      _render(h, left, right, l, r, 0, hold);
      for (final id in ids) {
        e.noteOff(id);
      }
      _render(h, left, right, l, r, hold, tail);
      return _measure(l, r, hold);
    }

    try {
      final only = Platform.environment['CAW_KNOB_ONLY'];
      for (final id in only == null || only.isEmpty ? _instruments : only.split(',')) {
        final base = infos[id];
        expect(base, isNotNull, reason: '$id is a built-in');
        final variants = base!.variants.isEmpty ? [base] : base.variants;
        for (var v = 0; v < variants.length; v++) {
          s.project = ProjectDoc(id: 'p', name: 'Gate', bpm: 120, modules: [], layers: [
            LayerDoc(id: 't', name: 'Instrument', color: 2)
              ..instrument = ComponentUseDoc(id, {if (base.variants.isNotEmpty) 'variant': v.toDouble()}),
          ]);
          s.starting = false;
          await tester.runAsync(() => e.setProject(s.project.toEngineJson()));
          e.play();
          final target = DeviceTarget(s, 't', DeviceTarget.instrumentSlot);
          final info = target.info!;
          final steady = _steady[id] ?? const <String, double>{};
          double home(ComponentParameterInfo p) => steady[p.id] ?? p.defaultValue;
          steady.forEach(target.setLive);
          final choices = base.param('variant')?.choices ?? const <String>[];
          final name = base.variants.isEmpty ? id : '$id #$v ${v < choices.length ? choices[v] : ''}'.trim();
          // Warm up (recordings load on first use), then the same-setting distance.
          take('t');
          take('t');
          // The same-setting distance: the largest between three takes in a row.
          final f1 = take('t'), f2 = take('t'), f3 = take('t');
          final floor = _Distance.largest([_Distance.between(f1, f2), _Distance.between(f2, f3), _Distance.between(f1, f3)]);
          report.writeln('$name: same-setting $floor');
          // Each measured take follows a take at the knob's default, so both ends hear the same tail before them.
          // A device whose takes differ at one setting (a random wind, a room) is heard three times at each end:
          // the knob is heard when the nearest of its min-max pairs is further apart than the furthest same-end
          // pair (1.5x) and the device's own floor.
          final random = !floor.still;
          bool heard(String id, double lo, double hi, double def, void Function(_Distance d) show) {
            final lows = <_Features>[], highs = <_Features>[];
            for (var k = 0; k < (random ? 3 : 1); k++) {
              target.setLive(id, def);
              take('t');
              target.setLive(id, lo);
              lows.add(take('t'));
              target.setLive(id, def);
              take('t');
              target.setLive(id, hi);
              highs.add(take('t'));
            }
            target.setLive(id, def);
            final d = _Distance.smallest([for (final a in lows) for (final b in highs) _Distance.between(a, b)]);
            show(d);
            if (!random) return d.audible(floor);
            final same = _Distance.largest([
              for (final end in [lows, highs])
                for (var a = 0; a < end.length; a++)
                  for (var b = a + 1; b < end.length; b++) _Distance.between(end[a], end[b]),
              floor,
            ]);
            return d.audible(same, 1.5);
          }
          for (final p in info.knobs) {
            if (p.max <= p.min) continue;
            // The quality tier trades CPU for detail and is meant to sound alike: not a sound knob.
            if (p.id == 'tier') {
              report.writeln('  tier ${p.id}: a CPU setting, not checked');
              continue;
            }
            late _Distance d;
            final ok = heard(p.id, p.min, p.max, home(p), (x) => d = x);
            var line = '  ${ok ? 'ok  ' : 'DEAD'} ${p.id} (${p.min}..${p.max}): $d';
            if (!ok) {
              // Gated by another setting? The sweep again with every other sound knob at its maximum (the level,
              // voices, release and room at their defaults).
              final others = {
                for (final o in info.knobs)
                  if (o.id != p.id && !_kept.contains(o.id) && o.max > o.min) o.id: o.max,
              };
              others.forEach(target.setLive);
              late _Distance g;
              final gate = heard(p.id, p.min, p.max, home(p), (x) => g = x);
              for (final o in info.knobs) {
                target.setLive(o.id, home(o));
              }
              if (gate) {
                line = '  GATE ${p.id} (${p.min}..${p.max}): heard only with other knobs moved: $g';
                gated.add('$name ${p.id} ("${p.name}")');
              } else {
                dead.add('$name ${p.id} ("${p.name}"): $d');
              }
            }
            report.writeln(line);
            if (!ok) stderr.writeln('$name$line');
          }
          e.notesOff();
        }
      }
    } finally {
      calloc.free(left);
      calloc.free(right);
      s.dispose();
      final out = Platform.environment['CAW_KNOB_REPORT'];
      if (out != null && out.isNotEmpty) File(out).writeAsStringSync(report.toString());
    }
    if (gated.isNotEmpty) stderr.writeln('heard only with another setting (a page dims them with what they need):\n${gated.join('\n')}');
    expect(dead, isEmpty, reason: 'knobs that move but change nothing heard:\n${dead.join('\n')}');
  }, skip: noLib != null, timeout: const Timeout(Duration(minutes: 30)));
}
