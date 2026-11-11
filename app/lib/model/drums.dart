// The drums instrument (org.caw.drums) as the app sees it: pads and layers from the descriptor, the display layout v2, the pitch shape, randomize, mutate, copy, clear, samples and explode to tracks.
import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/component_info.dart';
import '../engine/engine.dart';
import 'app_state.dart';
import 'device_display.dart';
import 'device_target.dart';
import 'pattern_doc.dart';
import 'project.dart';

const drumsComponentId = 'org.caw.drums';

/// 4 banks (A..D) of 16 pads (docs/engine.md, "Drums").
const drumBanks = 4, drumPadsPerBank = 16, drumPadCount = 64;

/// Pad [i]'s id prefix (`a1` .. `d16`).
String padId(int i) => '${'abcd'[i ~/ drumPadsPerBank]}${i % drumPadsPerBank + 1}';

/// Pad [i] as shown (`A1`).
String padLabel(int i) => padId(i).toUpperCase();

/// The bank letter of bank [b].
String bankLabel(int b) => 'ABCD'[b];

/// One layer of every pad: its id (`body`), display name and parameter suffixes (`body_on`, `body_freq`, ...).
class DrumLayer {
  const DrumLayer(this.id, this.name, this.suffixes);
  final String id, name;
  final List<String> suffixes;

  /// The suffix of its on switch: `body_on`, or the choice whose first value is Off (`drive_type`, `flt`); null when
  /// the layer has none (its knobs at their neutral values leave the sound alone).
  String? get power => switch (id) {
        'body' || 'sub' || 'click' || 'noise' || 'metal' || 'res' || 'smp' => '${id}_on',
        'drive' => 'drive_type',
        'filter' => 'flt',
        _ => null,
      };
}

/// The layers' display names, as `caw_drums_info` gives them (the CAW_LIB test checks they agree).
const drumLayerNames = {
  'pad': 'Pad', 'press': 'Pressure', 'body': 'Body', 'penv': 'Pitch shape', 'sub': 'Sub', 'click': 'Click',
  'noise': 'Noise', 'metal': 'Metal', 'res': 'Resonator', 'smp': 'Sample', 'drive': 'Drive', 'filter': 'Filter',
  'eq': 'EQ', 'dyn': 'Dynamics', 'space': 'Space', 'macro': 'Character', 'var': 'Variation',
};

/// The layers that make sound (a pad with all of them off is empty and costs nothing).
const drumSoundLayers = ['body', 'sub', 'click', 'noise', 'metal', 'res', 'smp'];

/// The Character macros' suffixes, in the strip's order.
const drumMacros = ['punch', 'tone', 'snap', 'length', 'dirt', 'pitch'];

/// Where each pad's parameters are, read once from the descriptor's groups and kept per descriptor.
class DrumsLayout {
  DrumsLayout._(this.layers, this.kitGroups, this.emptyPad, this._ids);

  /// The pad layers in the engine's order.
  final List<DrumLayer> layers;

  /// The kit-wide ids by group (`main`, `glue`, `drive`, `room`, `eq`, `clip`), in descriptor order.
  final Map<String, List<String>> kitGroups;

  /// Each suffix's value on an empty pad (bank B's defaults: every layer off).
  final Map<String, double> emptyPad;

  final List<Map<String, String>> _ids;

  late final Map<String, DrumLayer> byId = {for (final l in layers) l.id: l};

  /// Every suffix of a pad, in order.
  late final List<String> suffixes = [for (final l in layers) ...l.suffixes];

  static final _cache = Expando<DrumsLayout>('drums layout');

  /// The layout of [info] (a Drums descriptor), built on first use.
  static DrumsLayout of(NativeComponentInfo info) => _cache[info] ??= _build(info);

  static DrumsLayout _build(NativeComponentInfo info) {
    final order = <String>[];
    final suffixes = <String, List<String>>{};
    final kit = <String, List<String>>{};
    final empty = <String, double>{};
    for (final p in info.parameters) {
      final g = p.group;
      if (g.startsWith('kit/')) {
        (kit[g.substring(4)] ??= []).add(p.id);
      } else if (g.startsWith('a1/')) {
        final layer = g.substring(3);
        if (!suffixes.containsKey(layer)) order.add(layer);
        (suffixes[layer] ??= []).add(p.id.substring(3));
      } else if (g.startsWith('b1/')) {
        empty[p.id.substring(3)] = p.defaultValue;
      }
    }
    final layers = [for (final id in order) DrumLayer(id, drumLayerNames[id] ?? id, suffixes[id]!)];
    final all = [for (final l in layers) ...l.suffixes];
    final ids = [for (var i = 0; i < drumPadCount; i++) {for (final s in all) s: '${padId(i)}_$s'}];
    return DrumsLayout._(layers, kit, empty, ids);
  }

  /// The id of pad [pad]'s [suffix] (`a1_body_freq`), from a table built once.
  String id(int pad, String suffix) => _ids[pad][suffix] ?? '${padId(pad)}_$suffix';
}

/// Pad [pad] of drums [t] as the editor reads it; every read is a lookup in the project's values.
class DrumPadView {
  DrumPadView(this.t, this.layout, this.pad);
  final DeviceTarget t;
  final DrumsLayout layout;
  final int pad;

  String id(String suffix) => layout.id(pad, suffix);
  double v(String suffix) => t.value(id(suffix));
  bool on(String suffix) => v(suffix) >= 0.5;

  /// Whether layer [layer] of the pad is switched on (always for a layer without a switch).
  bool layerOn(DrumLayer layer) => layer.power == null || v(layer.power!) >= 0.5;

  /// It makes sound: a sound layer on and its level above −60 dB.
  bool get used => v('level') > -60 && drumSoundLayers.any((l) => on('${l}_on'));

  /// Its drum type's name (Kick, Snare, ...).
  String get typeName => formatChoice(t.param(id('type')), v('type'));

  int get choke => v('choke').round();
}

String formatChoice(ComponentParameterInfo? p, double v) {
  if (p == null || !p.isChoice) return '';
  return p.choices[(v - p.min).round().clamp(0, p.choices.length - 1)];
}

/// MIDI note [n] as a name (C2 is 36, C4 60, as the descriptor's note choices).
String noteName(int n) => '${const ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'][n % 12]}${n ~/ 12 - 1}';

/// The `note` value that maps a pad to MIDI note [key] (Auto 0, Off 1, Any other 2, then the keys).
double noteValueFor(int key) => 3.0 + key.clamp(0, 127);

/// Pad [pad]'s note in Kit mode: its own, Auto (`base_note` + index), or null for Off and Any other.
int? padNote(DeviceTarget t, DrumsLayout layout, int pad) {
  final v = t.value(layout.id(pad, 'note')).round();
  if (v == 0) return (t.value('base_note').round() + pad).clamp(0, 127);
  return v >= 3 ? (v - 3).clamp(0, 127) : null;
}

/// The note that plays pad [pad] from the editor: Single mode plays A1 at its root; Kit mode plays the pad's note,
/// and a pad on Any other a note no other pad takes. Null when tapping it can't sound (Off, or not A1 in Single).
int? auditionNote(DeviceTarget t, DrumsLayout layout, int pad) {
  if (t.value('mode').round() == 1) return pad == 0 ? t.value(layout.id(0, 'root')).round().clamp(0, 127) : null;
  final v = t.value(layout.id(pad, 'note')).round();
  if (v == 1) return null;
  if (v != 2) return padNote(t, layout, pad);
  final taken = {for (var i = 0; i < drumPadCount; i++) ?padNote(t, layout, i)};
  for (var k = 0; k < 128; k++) {
    if (!taken.contains(k)) return k;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------------------------
// Display data, layout version 2 (docs/engine.md, "Display data of the drums")

/// One display frame of the drums, decoded.
class DrumsDisplayFrame extends DeviceDisplayFrame {
  DrumsDisplayFrame({
    required this.mode, required this.shownPad, required this.glueGr, required this.padGr, required this.waveSeconds,
    required this.pitchSpan, required this.voices, required this.lastPad, required this.lastNote,
    required this.lastChannel, required this.lastVelocity, required this.noteCount, required this.penvMode,
    required this.peaks, required this.waveMax, required this.waveMin, required this.pitch,
  }) : super(gainReductionDb: -glueGr);

  final int mode, shownPad, voices, lastPad, lastNote, lastChannel, noteCount, penvMode;
  final double glueGr, padGr, waveSeconds, pitchSpan, lastVelocity;

  /// Each pad's peak since the last frame (0 silent), the shown pad's waveform bins (max, min) and its pitch in Hz.
  final Float32List peaks, waveMax, waveMin, pitch;

  static const version = 2, floats = 656;

  /// Null unless [f] holds a whole version 2 frame.
  static DrumsDisplayFrame? decode(List<double> f, int n) {
    if (n < floats || f[0].round() != version) return null;
    Float32List part(int from, int count) => Float32List.fromList(f.sublist(from, from + count));
    return DrumsDisplayFrame(
      mode: f[1].round(), shownPad: f[2].round(), glueGr: f[3], padGr: f[4], waveSeconds: f[5], pitchSpan: f[8],
      voices: f[9].round(), lastPad: f[10].round(), lastNote: f[11].round(), lastChannel: f[12].round(),
      lastVelocity: f[13], noteCount: f[14].round(), penvMode: f[15].round(),
      peaks: part(16, 64), waveMax: part(80, 256), waveMin: part(336, 256), pitch: part(592, 64));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The pitch shape and a drawn sound, computed from the knobs (the engine's formulas, docs/engine.md)

/// The body's pitch over time as a full-velocity hit plays it, with the Punch and Pitch macros.
class DrumPitchShape {
  DrumPitchShape(DrumPadView p)
      : points = p.v('penv_mode').round() == 1,
        fEnd = p.v('body_freq') * math.pow(2, (p.v('tune') + 12 * p.v('pitch')) / 12),
        depth = p.v('body_pitch') + 12 * p.v('punch'),
        timeScale = math.pow(2, -0.7 * p.v('punch')).toDouble(),
        ptime = p.v('body_ptime'),
        pcurve = p.v('body_pcurve'),
        t = [for (var i = 1; i <= 4; i++) p.v('penv_t$i')],
        st = [for (var i = 1; i <= 4; i++) p.v('penv_p$i')],
        c = [for (var i = 1; i <= 4; i++) p.v('penv_c$i')];

  final bool points;
  final double fEnd, depth, timeScale, ptime, pcurve;
  final List<double> t, st, c;

  /// How long the shape takes: three pitch times (Curve) or 1.15 × the four segments (Points).
  double get span => points ? 1.15 * timeScale * t.fold(0.0, (a, b) => a + b) : 3 * ptime * timeScale;

  /// When point [i] (0..3) is reached.
  double pointTime(int i) => timeScale * t.take(i + 1).fold(0.0, (a, b) => a + b);

  /// Semitones over the settled pitch at [s] seconds.
  double semitones(double s) {
    if (!points) {
      final fStart = fEnd * math.pow(2, depth / 12);
      final f = fEnd + (fStart - fEnd) * _env(s / math.max(1e-6, ptime * timeScale), pcurve);
      return 12 * math.log(f / fEnd) / math.ln2;
    }
    var from = depth, at = 0.0;
    for (var i = 0; i < 4; i++) {
      final len = t[i] * timeScale;
      if (s < at + len) return from + (st[i] - from) * segmentCurve((s - at) / math.max(1e-9, len), c[i]);
      at += len;
      from = st[i];
    }
    return st[3];
  }

  double hz(double s) => fEnd * math.pow(2, semitones(s) / 12);

  /// A Points segment's progress at [u] 0..1 for curve [c]: straight at 0, fast then slow above, slow then fast below.
  static double segmentCurve(double u, double c) {
    final k = 1 + 7 * c.abs();
    final x = u.clamp(0.0, 1.0);
    if (c > 0) return 1 - math.pow(1 - x, k).toDouble();
    if (c < 0) return math.pow(x, k).toDouble();
    return x;
  }
}

/// An envelope falling 60 dB over x = 1 with curve [c]: + blends in one six times as fast, − a straight line.
double _env(double x, double c) {
  if (x <= 0) return 1;
  final e = math.exp(-6.9 * x);
  if (c >= 0) return (1 - c) * e + c * math.exp(-6.9 * 6 * x);
  return (1 + c) * e + (-c) * math.max(0.0, 1 - x);
}

double _db(double db) => math.pow(10, db / 20).toDouble();

/// The pad's sound drawn from its knobs (≈, for a pad the engine hasn't played yet): [bins] maxima and minima over
/// [seconds], and the knob a sideways drag on the hero sets (the main layer's decay).
class DrumSketch {
  DrumSketch._(this.seconds, this.max, this.min, this.decayId);
  final double seconds;
  final Float32List max, min;
  final String? decayId;

  static final Map<String, DrumSketch> _cache = {};

  /// The sketch of [p], kept while its knobs don't change (the hero redraws it on every edit elsewhere).
  factory DrumSketch.of(DrumPadView p, {int bins = 256}) {
    final key = '${p.pad}|$bins|${[for (final s in p.layout.suffixes) p.v(s)].join(',')}';
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 32) _cache.clear();
    return _cache[key] = DrumSketch._draw(p, bins);
  }

  factory DrumSketch._draw(DrumPadView p, int bins) {
    final lengthScale = math.pow(2, 2 * p.v('length')).toDouble();
    final layers = <({double level, double attack, double hold, double decay, double curve, double Function(double s, int i) wave})>[];
    final shape = DrumPitchShape(p);
    var phase = 0.0, lastS = 0.0;
    var seed = 7 + p.pad;
    double noise() {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      return seed / 0x7FFFFFFF * 2 - 1;
    }
    double bodyWave(double s, int _) {
      phase += 2 * math.pi * shape.hz(s) * (s - lastS);
      lastS = s;
      return math.sin(phase);
    }
    String? decayId;
    void add(String l, double level, String decay, double Function(double s, int i) wave,
        {String? attack, String? hold, String? curve, double scale = 1}) {
      if (!p.on('${l}_on')) return;
      decayId ??= p.id(decay);
      layers.add((level: level, attack: attack == null ? 0.0 : p.v(attack), hold: hold == null ? 0.0 : p.v(hold),
        decay: p.v(decay) * lengthScale * scale, curve: curve == null ? 0.0 : p.v(curve), wave: wave));
    }
    add('body', _db(p.v('body_level')), 'body_decay', bodyWave, attack: 'body_attack', hold: 'body_hold', curve: 'body_dcurve');
    add('noise', _db(p.v('noise_level')), 'noise_decay', (s, i) => noise(), attack: 'noise_attack', curve: 'noise_dcurve');
    add('metal', _db(p.v('metal_level')), 'metal_decay', (s, i) => noise() * 0.8 + (i.isEven ? 0.2 : -0.2),
        attack: 'metal_attack', curve: 'metal_dcurve', scale: 1 + 15 * math.pow(p.v('metal_open'), 2).toDouble());
    add('res', _db(p.v('res_level')), 'res_decay', (s, i) => math.sin(2 * math.pi * p.v('res_freq') * s));
    add('smp', _db(p.v('smp_level')), 'smp_decay', (s, i) => noise() * 0.6, attack: 'smp_attack');
    add('sub', _db(p.v('sub_level')), 'sub_decay', (s, i) => math.sin(2 * math.pi * shape.fEnd / 2 * s),
        attack: 'sub_attack', hold: 'sub_hold', curve: 'sub_dcurve');
    final click = p.on('click_on') ? p.v('click_level') * math.pow(2, 1.5 * p.v('punch') + p.v('snap')) : 0.0;
    final clickLen = p.v('click_length');
    if (p.on('click_on')) decayId ??= p.id('click_length');
    var longest = 0.05;
    for (final l in layers) {
      longest = math.max(longest, l.attack + l.hold + l.decay);
    }
    if (click > 0) longest = math.max(longest, clickLen * 2);
    final seconds = longest.clamp(0.05, 4.0).toDouble();
    final mx = Float32List(bins), mn = Float32List(bins);
    const sub = 16;
    for (var b = 0; b < bins; b++) {
      var hi = 0.0, lo = 0.0;
      for (var k = 0; k < sub; k++) {
        final s = seconds * (b * sub + k) / (bins * sub);
        var y = 0.0;
        for (final l in layers) {
          final a = s < l.attack ? s / math.max(1e-6, l.attack) : 1.0;
          final d = s < l.attack + l.hold ? 1.0 : _env((s - l.attack - l.hold) / math.max(1e-6, l.decay), l.curve);
          y += l.level * a * d * l.wave(s, b * sub + k);
        }
        if (click > 0 && s < clickLen) y += click * noise() * (1 - s / clickLen);
        hi = math.max(hi, y);
        lo = math.min(lo, y);
      }
      mx[b] = hi;
      mn[b] = lo;
    }
    // Scaled so the loudest bin reaches about full height, as the engine's bins of a hit peaking near −1 dBFS.
    var peak = 1e-6;
    for (var b = 0; b < bins; b++) {
      peak = math.max(peak, math.max(mx[b], -mn[b]));
    }
    final g = 0.9 / peak;
    for (var b = 0; b < bins; b++) {
      mx[b] *= g;
      mn[b] *= g;
    }
    return DrumSketch._(seconds, mx, mn, decayId);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// The engine's drums calls, behind an interface (tests give their own)

abstract class DrumsApi {
  const DrumsApi();

  /// `caw_drums_randomize`: all 162 of pad [pad]'s values as `{"<pad>_<suffix>": value}`, or null.
  Map<String, double>? randomize(int type, int seed, double amount, int pad, Map<String, double>? current);

  /// `caw_drums_explode`: `{"tracks": [...], "kit": {...}}`, or null.
  Map<String, dynamic>? explode(Map<String, dynamic> entry);

  /// The built-in pack's sample names (null: unknown, the engine isn't loaded).
  List<String>? builtinSamples();

  /// The library's sounds as pad values by suffix (`caw_drums_info`'s `sounds`), or null.
  List<({String name, int type, Map<String, double> params})>? sounds();

  static DrumsApi current = const EngineDrumsApi();
}

/// The engine library's drums calls; each gives null when the library can't be loaded.
class EngineDrumsApi extends DrumsApi {
  const EngineDrumsApi();

  static Map<String, dynamic>? _info;
  static bool _infoTried = false;

  static Map<String, dynamic>? get info {
    if (!_infoTried) {
      _infoTried = true;
      try {
        _info = Engine.drumsInfo();
      } catch (_) {
        _info = null;
      }
    }
    return _info;
  }

  static Map<String, double> _numbers(Object? m) => {
        for (final e in ((m as Map?) ?? const {}).entries)
          if (e.value is num) e.key as String: (e.value as num).toDouble(),
      };

  @override
  Map<String, double>? randomize(int type, int seed, double amount, int pad, Map<String, double>? current) {
    try {
      final r = Engine.drumsRandomize(type, seed, amount, pad, current == null ? null : {'params': current});
      return r == null ? null : _numbers(r['params']);
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, dynamic>? explode(Map<String, dynamic> entry) {
    try {
      return Engine.drumsExplode(entry);
    } catch (_) {
      return null;
    }
  }

  @override
  List<String>? builtinSamples() => [for (final s in (info?['samples'] as List?) ?? const []) if (s is String) s];

  @override
  List<({String name, int type, Map<String, double> params})>? sounds() {
    final list = info?['sounds'] as List?;
    if (list == null) return null;
    return [
      for (final s in list.whereType<Map>())
        (name: s['name'] as String? ?? '', type: (s['type'] as num?)?.toInt() ?? 0, params: _numbers(s['params'])),
    ];
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Pad actions

/// Pad [pad]'s values by suffix.
Map<String, double> padValues(DeviceTarget t, DrumsLayout layout, int pad) =>
    {for (final s in layout.suffixes) s: t.value(layout.id(pad, s))};

/// What Copy took: a pad's sound and its sample.
class DrumPadClip {
  const DrumPadClip(this.values, this.sample);
  final Map<String, double> values;
  final ComponentSampleDoc? sample;
}

/// The pad clipboard, app-wide (so a pad can be pasted onto another track's drums).
class DrumsClipboard {
  DrumsClipboard._();
  static DrumPadClip? pad;
}

/// The suffixes a sound change leaves alone: where the pad sits in the note map.
const _keepOnSound = {'note', 'chan'};

ComponentSampleDoc? padSample(DeviceTarget t, int pad) => t.use?.samples.where((s) => s.slot == pad).firstOrNull;

void copyPad(DeviceTarget t, DrumsLayout layout, int pad) =>
    DrumsClipboard.pad = DrumPadClip(padValues(t, layout, pad), padSample(t, pad));

/// Writes [values] (by suffix) onto pad [pad] as one undo step, keeping its note and channel; [sample] (when given)
/// replaces its sample slot, null clears it.
void writePad(DeviceTarget t, DrumsLayout layout, int pad, Map<String, double> values,
    {bool setSample = false, ComponentSampleDoc? sample}) {
  final l = t.layer, use = t.use;
  if (l == null || use == null) return;
  if (setSample) {
    use.samples = [
      for (final s in use.samples) if (s.slot != pad) s,
      if (sample != null) ComponentSampleDoc(pad, path: sample.path, builtin: sample.builtin),
    ]..sort((a, b) => a.slot.compareTo(b.slot));
  }
  for (final e in values.entries) {
    if (!_keepOnSound.contains(e.key)) t.setLive(layout.id(pad, e.key), e.value);
  }
  t.state.editLayer(l, (_) {});
}

bool pastePad(DeviceTarget t, DrumsLayout layout, int pad) {
  final clip = DrumsClipboard.pad;
  if (clip == null) return false;
  writePad(t, layout, pad, clip.values, setSample: true, sample: clip.sample);
  return true;
}

/// Pad [pad] back to an empty pad (every layer off), its note and channel kept, its sample cleared.
void clearPad(DeviceTarget t, DrumsLayout layout, int pad) =>
    writePad(t, layout, pad, layout.emptyPad, setSample: true);

/// Loads the library's sound [values] (by suffix, those not at the empty pad's default) onto pad [pad].
void loadSound(DeviceTarget t, DrumsLayout layout, int pad, Map<String, double> values) =>
    writePad(t, layout, pad, {...layout.emptyPad, ...values});

/// Puts [sample] in pad [pad]'s slot and turns its Sample layer on (one undo step).
void setPadSample(DeviceTarget t, DrumsLayout layout, int pad, ComponentSampleDoc sample) =>
    writePad(t, layout, pad, {'smp_on': 1}, setSample: true, sample: sample);

final _random = math.Random();

/// A new sound of the pad's type ([layer]: only that layer's knobs take it), from the engine. False when the
/// engine gave nothing.
bool randomizePad(DeviceTarget t, DrumsLayout layout, int pad, {DrumLayer? layer, int? seed, DrumsApi? api}) {
  final type = t.value(layout.id(pad, 'type')).round();
  final r = (api ?? DrumsApi.current).randomize(type, seed ?? _random.nextInt(1 << 31), 1, pad, null);
  return _apply(t, layout, pad, r, layer);
}

/// The pad's sound moved [amount] of the way toward a random one of its type ([layer]: only that layer).
bool mutatePad(DeviceTarget t, DrumsLayout layout, int pad, {DrumLayer? layer, double amount = 0.3, int? seed,
    DrumsApi? api}) {
  final r = (api ?? DrumsApi.current).randomize(-1, seed ?? _random.nextInt(1 << 31), amount, pad, padValues(t, layout, pad));
  return _apply(t, layout, pad, r, layer);
}

bool _apply(DeviceTarget t, DrumsLayout layout, int pad, Map<String, double>? r, DrumLayer? layer) {
  if (r == null || r.isEmpty) return false;
  final prefix = '${padId(pad)}_';
  final only = layer?.suffixes.toSet();
  final values = <String, double>{
    for (final e in r.entries)
      if (e.key.startsWith(prefix) && (only == null || only.contains(e.key.substring(prefix.length))))
        e.key.substring(prefix.length): e.value,
  };
  if (values.isEmpty) return false;
  writePad(t, layout, pad, values);
  return true;
}

// ---------------------------------------------------------------------------------------------------------------
// Explode to tracks

/// Whether pattern note [pitch] is in an explode track's `notes` ([key] list, "other", "all", {"channel": n});
/// [listed] holds every key some track names, for "other". Pattern notes play on channel 1. **[Assumption]**
bool _takes(Object? notes, int pitch, Set<int> listed) => switch (notes) {
      final List l => l.contains(pitch),
      'other' => !listed.contains(pitch),
      'all' => true,
      {'channel': final int n} => n == 1,
      _ => false,
    };

/// Explodes [layer]'s Drums into one track per used pad, right after it (in its folder), each a Single-mode Drums
/// with the pad's sound, and moves the notes each pad answers out of [layer]'s clips into clips on its track at the
/// same places (a clip's pattern shared elsewhere is copied, never changed in place). One undo step. Returns how
/// many tracks were made, or null when the engine gave nothing.
int? explodeDrums(AppState s, LayerDoc layer, {DrumsApi? api}) {
  final use = layer.instrument;
  if (use == null || use.id != drumsComponentId) return null;
  final r = (api ?? DrumsApi.current).explode({
    'id': use.id, 'params': use.params, if (use.samples.isNotEmpty) 'samples': [for (final x in use.samples) x.toJson()],
  });
  final tracks = [for (final t in (r?['tracks'] as List?) ?? const []) if (t is Map) t];
  if (r == null || tracks.isEmpty) return null;
  final listed = {for (final t in tracks) if (t['notes'] is List) ...(t['notes'] as List).whereType<int>()};
  s.endUndoStep();
  s.editProject((p) {
    final at = p.layers.indexOf(layer);
    final made = <LayerDoc>[];
    final moved = <int, List<ClipDoc>>{}; // track index → its clips
    // Each source clip once: its notes split between the tracks, the rest staying.
    for (final clip in List.of(layer.clips)) {
      final module = p.module(clip.patternId);
      final doc = module == null ? null : PatternDoc.parse(module.runSource).doc;
      if (module == null || doc == null) continue;
      final taken = <int>{};
      for (final (i, tr) in tracks.indexed) {
        final mine = [for (final n in doc.notes) if (!taken.contains(n.id) && _takes(tr['notes'], n.pitch.round(), listed)) n];
        if (mine.isEmpty) continue;
        taken.addAll(mine.map((n) => n.id));
        final keep = {for (final n in mine) n.id};
        final part = doc.delete({for (final n in doc.notes) if (!keep.contains(n.id)) n.id})
            .setName('${tr['name'] ?? 'Pad'} ${module.name}');
        final m = ModuleDoc(id: newId('m'), name: '${tr['name'] ?? 'Pad'} · ${module.name}', source: part.serialize());
        p.modules.add(m);
        (moved[i] ??= []).add(ClipDoc(id: newId('c'), patternId: m.id, startSteps: clip.startSteps,
            lengthSteps: clip.lengthSteps, sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, mute: clip.mute));
      }
      if (taken.isEmpty) continue;
      final rest = doc.delete(taken);
      final m = ModuleDoc(id: newId('m'), name: '${module.name} (rest)', source: rest.serialize());
      p.modules.add(m);
      clip.patternId = m.id;
      clip.linked = false;
    }
    for (final (i, tr) in tracks.indexed) {
      final inst = tr['instrument'] as Map? ?? const {};
      final pad = tr['pad'] as String? ?? '';
      final sourcePad = RegExp(r'^([a-d])(\d+)$').firstMatch(pad);
      final slot = sourcePad == null ? -1 : 'abcd'.indexOf(sourcePad[1]!) * 16 + int.parse(sourcePad[2]!) - 1;
      made.add(LayerDoc(
        id: newId('l'),
        name: tr['name'] as String? ?? 'Pad',
        color: (layer.color + 1 + i) % LayerDoc.trackColors,
        lengthSteps: layer.lengthSteps,
        volume: layer.volume,
        pan: layer.pan,
        parentId: layer.parentId,
        clips: moved[i] ?? [],
        instrument: ComponentUseDoc(inst['id'] as String? ?? drumsComponentId, {
          for (final e in ((inst['params'] as Map?) ?? const {}).entries)
            if (e.value is num) e.key as String: (e.value as num).toDouble(),
        })
          ..samples = ComponentSampleDoc.listFromJson(inst['samples'] ??
              [for (final x in use.samples) if (x.slot == slot) {...x.toJson(), 'slot': 0}]),
      ));
    }
    p.layers.insertAll(at + 1, made);
  });
  s.endUndoStep();
  return tracks.length;
}
