// The sampler (org.caw.sampler, docs/engine.md "Sampler"): its zones as the app edits them (keys and velocities,
// root, loop points, round robins), kept as the instrument entry's state JSON, and making zones from dropped files.
import 'dart:convert';
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_fx.dart';
import 'project.dart';

const samplerComponentId = 'org.caw.sampler';

/// The loop modes, as the engine and SFZ name them.
const samplerLoopModes = ['no_loop', 'one_shot', 'loop_continuous', 'loop_sustain'];

String loopModeLabel(String m) => switch (m) {
      'one_shot' => 'One shot',
      'loop_continuous' => 'Loop',
      'loop_sustain' => 'Loop while held',
      _ => 'No loop',
    };

/// One zone: a sample over a key and velocity range. Keys mirror SFZ opcodes; positions are frames of the file.
class SamplerZone {
  SamplerZone({required this.path, this.loKey = 0, this.hiKey = 127, this.root = 60, this.loVel = 1, this.hiVel = 127,
      this.tune = 0, this.transpose = 0, this.keytrack = 100, this.volume = 0, this.pan = 0, this.veltrack = 100,
      this.offset = 0, this.end = 0, this.loopMode, this.loopStart = 0, this.loopEnd = 0, this.loopCrossfade = 0,
      this.seqLength = 1, this.seqPosition = 1, this.loRand = 0, this.hiRand = 1, this.group = 0, this.offBy = 0,
      this.attack = -1, this.decay = -1, this.sustain = -1, this.release = -1});

  String path;
  int loKey, hiKey, root, loVel, hiVel, transpose;
  double tune, keytrack, volume, pan, veltrack;
  int offset, end;

  /// Null: none set (loop points then loop continuously, as in SFZ).
  String? loopMode;
  int loopStart, loopEnd;
  double loopCrossfade;
  int seqLength, seqPosition;
  double loRand, hiRand;
  int group, offBy;

  /// This zone's own envelope (-1: the instrument's).
  double attack, decay, sustain, release;

  String get name => path.split(RegExp(r'[/\\]')).last;

  /// The mode the engine plays: loop points without a mode loop.
  String get playedLoopMode => loopMode ?? (loopEnd > loopStart ? 'loop_continuous' : 'no_loop');

  bool covers(int key, int vel) => key >= loKey && key <= hiKey && vel >= loVel && vel <= hiVel;

  Map<String, dynamic> toJson() => {
        'path': path, 'lokey': loKey, 'hikey': hiKey, 'pitch_keycenter': root, 'lovel': loVel, 'hivel': hiVel,
        if (tune != 0) 'tune': tune,
        if (transpose != 0) 'transpose': transpose,
        if (keytrack != 100) 'pitch_keytrack': keytrack,
        if (volume != 0) 'volume': volume,
        if (pan != 0) 'pan': pan,
        if (veltrack != 100) 'amp_veltrack': veltrack,
        if (offset > 0) 'offset': offset,
        if (end > 0) 'end': end,
        if (loopMode != null) 'loop_mode': loopMode,
        if (loopEnd > loopStart) ...{'loop_start': loopStart, 'loop_end': loopEnd},
        if (loopCrossfade > 0) 'loop_crossfade': loopCrossfade,
        if (seqLength > 1) ...{'seq_length': seqLength, 'seq_position': seqPosition},
        if (loRand > 0 || hiRand < 1) ...{'lorand': loRand, 'hirand': hiRand},
        if (group > 0) 'group': group,
        if (offBy > 0) 'off_by': offBy,
        if (attack >= 0) 'ampeg_attack': attack,
        if (decay >= 0) 'ampeg_decay': decay,
        if (sustain >= 0) 'ampeg_sustain': sustain,
        if (release >= 0) 'ampeg_release': release,
      };

  static SamplerZone? fromJson(Object? j) {
    if (j is! Map || j['path'] is! String || (j['path'] as String).isEmpty) return null;
    int i(String k, int or, int lo, int hi) => j[k] is num && (j[k] as num).isFinite ? (j[k] as num).round().clamp(lo, hi) : or;
    double d(String k, double or, double lo, double hi) =>
        j[k] is num && (j[k] as num).isFinite ? (j[k] as num).toDouble().clamp(lo, hi) : or;
    final mode = j['loop_mode'];
    final z = SamplerZone(
      path: j['path'] as String,
      loKey: i('lokey', 0, 0, 127), hiKey: i('hikey', 127, 0, 127), root: i('pitch_keycenter', 60, 0, 127),
      loVel: i('lovel', 1, 1, 127), hiVel: i('hivel', 127, 1, 127),
      tune: d('tune', 0, -9600, 9600), transpose: i('transpose', 0, -127, 127), keytrack: d('pitch_keytrack', 100, -1200, 1200),
      volume: d('volume', 0, -144, 24), pan: d('pan', 0, -100, 100), veltrack: d('amp_veltrack', 100, -100, 100),
      offset: i('offset', 0, 0, 1 << 52), end: i('end', 0, 0, 1 << 52),
      loopMode: samplerLoopModes.contains(mode) ? mode as String : null,
      loopStart: i('loop_start', 0, 0, 1 << 52), loopEnd: i('loop_end', 0, 0, 1 << 52),
      loopCrossfade: d('loop_crossfade', 0, 0, 10),
      seqLength: i('seq_length', 1, 1, 100), seqPosition: i('seq_position', 1, 1, 100),
      loRand: d('lorand', 0, 0, 1), hiRand: d('hirand', 1, 0, 1),
      group: i('group', 0, 0, 1000000), offBy: i('off_by', 0, 0, 1000000),
      attack: d('ampeg_attack', -1, -1, 100), decay: d('ampeg_decay', -1, -1, 100),
      sustain: d('ampeg_sustain', -1, -1, 100), release: d('ampeg_release', -1, -1, 100),
    );
    z.normalize();
    return z;
  }

  /// Keeps the engine's rules: low bounds at or under high ones, a position inside its length.
  void normalize() {
    if (loKey > hiKey) {
      final k = loKey;
      loKey = hiKey;
      hiKey = k;
    }
    if (loVel > hiVel) {
      final v = loVel;
      loVel = hiVel;
      hiVel = v;
    }
    if (seqPosition > seqLength) seqPosition = seqLength;
    if (loRand > hiRand) {
      final r = loRand;
      loRand = hiRand;
      hiRand = r;
    }
  }

  SamplerZone copy() => SamplerZone.fromJson(toJson())!;
}

/// The sampler's whole state (version 1): `{"zones": [...]}`.
class SamplerState {
  SamplerState([List<SamplerZone>? zones]) : zones = zones ?? [];
  final List<SamplerZone> zones;

  static const maxZones = 4096;

  Map<String, dynamic> toJson() => {'zones': [for (final z in zones) z.toJson()]};

  static SamplerState fromJson(Map<String, dynamic> j) =>
      SamplerState([for (final z in ((j['zones'] as List?) ?? const []).take(maxZones)) ?SamplerZone.fromJson(z)]);

  /// The instrument entry's base64 state (null or unreadable: no zones).
  static SamplerState fromBase64(String? state) {
    if (state == null || state.isEmpty) return SamplerState();
    try {
      final j = jsonDecode(utf8.decode(base64Decode(state)));
      return j is Map<String, dynamic> ? fromJson(j) : SamplerState();
    } catch (_) {
      return SamplerState();
    }
  }

  String toBase64() => base64Encode(utf8.encode(jsonEncode(toJson())));

  SamplerState copy() => SamplerState([for (final z in zones) z.copy()]);

  /// The zones a note of [key] at [vel] plays (round robins and random ranges aside).
  List<int> zonesAt(int key, int vel) => [for (var i = 0; i < zones.length; i++) if (zones[i].covers(key, vel)) i];

  /// One zone per file from [key] up, each a single key with its root there (files dropped on the keyboard).
  /// With [spread] the files share the keys up to the next one's (a chromatic run of sampled notes).
  List<int> addFiles(List<String> paths, int key) {
    final made = <int>[];
    for (final (n, p) in paths.indexed) {
      final k = (key + n).clamp(0, 127);
      if (zones.length >= maxZones) break;
      zones.add(SamplerZone(path: p, loKey: k, hiKey: k, root: k));
      made.add(zones.length - 1);
    }
    return made;
  }

  /// Makes [indices] a round-robin group: each plays on its own hit, in order (SFZ seq_length/seq_position).
  void roundRobin(List<int> indices) {
    final valid = [for (final i in indices) if (i >= 0 && i < zones.length) i];
    for (final (n, i) in valid.indexed) {
      zones[i]
        ..seqLength = valid.length < 2 ? 1 : valid.length
        ..seqPosition = valid.length < 2 ? 1 : n + 1;
    }
  }

  /// Shifts zone [i] by [keys] and [vels], keeping its size and staying on the keyboard.
  void moveZone(int i, int keys, int vels) {
    final z = zones[i];
    final dk = keys.clamp(-z.loKey, 127 - z.hiKey);
    final dv = vels.clamp(1 - z.loVel, 127 - z.hiVel);
    z
      ..loKey += dk
      ..hiKey += dk
      ..root = (z.root + dk).clamp(0, 127)
      ..loVel += dv
      ..hiVel += dv;
  }
}

/// Where a key sits as a name ("C4" = 60, as the engine's SFZ reader counts).
String noteName(int key) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[key % 12]}${key ~/ 12 - 1}';
}

extension SamplerEdit on AppState {
  /// [layer]'s sampler zones (none when its instrument isn't the sampler).
  SamplerState samplerState(LayerDoc layer) =>
      layer.instrument?.id == samplerComponentId ? SamplerState.fromBase64(layer.instrument!.state) : SamplerState();

  /// Stores [zones] as the sampler's state: one undo step; the project update reloads the zones in the engine.
  void setSamplerState(LayerDoc layer, SamplerState zones) {
    final use = layer.instrument;
    if (use == null || use.id != samplerComponentId) return;
    endUndoStep();
    editLayer(layer, (_) {
      use.state = zones.toBase64();
      use.stateVersion = 1;
    });
    endUndoStep();
    layerValueTick(layer.id).value++;
  }

  /// A new track playing the sampler, with [zones] (or none).
  LayerDoc addSamplerTrack({String name = 'Sampler', SamplerState? zones}) {
    final track = addEmptyTrack(name: name);
    setNativeInstrument(track, samplerComponentId);
    if (zones != null) setSamplerState(track, zones);
    return track;
  }
}

/// The zones' key span, for fitting the keyboard: (lowest, highest), or C2..C6 for none.
(int, int) zoneSpan(SamplerState s) {
  if (s.zones.isEmpty) return (36, 84);
  return (s.zones.map((z) => z.loKey).reduce(math.min), s.zones.map((z) => z.hiKey).reduce(math.max));
}
