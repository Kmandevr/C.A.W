// A device's mod matrix read from and written to its `modN_src/dst/amt/bipolar/via` parameters (the flagship's layout), and where its routes take a knob.
import 'dart:math' as math;

import 'device_target.dart';
import 'flagship_shapes.dart';

/// The flagship's mod sources, by their `modN_src` value (engine/src/builtin_flagship.cpp, `kSources`).
enum ModSource {
  none('None', '—'),
  env1('Env 1', 'ENV 1'),
  env2('Env 2', 'ENV 2'),
  env3('Env 3', 'ENV 3'),
  lfo1('LFO 1', 'LFO 1'),
  lfo2('LFO 2', 'LFO 2'),
  lfo3('LFO 3', 'LFO 3'),
  random('Random', 'RND'),
  velocity('Velocity', 'VEL'),
  note('Note', 'NOTE'),
  bend('Pitch bend', 'BEND'),
  pressure('Pressure', 'PRES'),
  timbre('Timbre', 'TMBR'),
  modWheel('Mod wheel', 'WHEEL');

  const ModSource(this.label, this.short);
  final String label, short;

  /// The value stored in `modN_src`.
  int get value => index;

  static ModSource of(double v) {
    final i = v.round();
    return i >= 0 && i < values.length ? values[i] : none;
  }

  /// LFOs and random swing both ways, so a new route from them starts bipolar; the others start unipolar.
  bool get naturallyBipolar => this == lfo1 || this == lfo2 || this == lfo3 || this == random || this == bend;
}

/// One used slot: [source] moves [paramId] by [amount] of its knob travel (−1..1), both ways when [bipolar], its
/// amount scaled by a second source [via] (none: 1).
class ModRoute {
  const ModRoute({required this.slot, required this.source, required this.paramId, required this.amount,
    required this.bipolar, this.via = ModSource.none});
  final int slot; // 1..slotCount
  final ModSource source;
  final String paramId;
  final double amount;
  final bool bipolar;
  final ModSource via;

  /// How far this route moves the knob's travel when its source is at [u] (0..1) and its scale source at [scale]:
  /// the engine's `amount × (bipolar ? 2u − 1 : u) × scale`.
  double offset(double u, {double scale = 1}) => amount * (bipolar ? 2 * u - 1 : u) * scale;

  /// The travel this route covers around a knob at [position] (0..1), clamped: [lo, hi].
  (double, double) span(double position) {
    final lo = bipolar ? position - amount.abs() : (amount < 0 ? position + amount : position);
    final hi = bipolar ? position + amount.abs() : (amount < 0 ? position : position + amount);
    return (lo.clamp(0.0, 1.0), hi.clamp(0.0, 1.0));
  }
}

/// The matrix of [target]: a slot's `dst` value k + 1 is the descriptor's parameter k (any parameter before the
/// slots), 0 is none.
class ModMatrix {
  ModMatrix(this.target);
  final DeviceTarget target;

  static String srcId(int slot) => 'mod${slot}_src';
  static String dstId(int slot) => 'mod${slot}_dst';
  static String amtId(int slot) => 'mod${slot}_amt';
  static String bipolarId(int slot) => 'mod${slot}_bipolar';
  static String viaId(int slot) => 'mod${slot}_via';

  /// How many slots the device has (16 on the flagship; 0 when it has no matrix).
  late final int slotCount = _slots();

  int _slots() {
    final params = target.info?.parameters;
    if (params == null) return 0;
    var n = 0;
    while (params.any((p) => p.id == srcId(n + 1))) {
      n++;
    }
    return n;
  }

  /// The parameter ids a route can reach, in descriptor order (value k + 1 of `dst` is entry k).
  late final List<String> destinations = _destinations();

  List<String> _destinations() {
    final params = target.info?.parameters ?? const [];
    final first = params.indexWhere((p) => p.id == srcId(1));
    return [for (final p in params.take(first < 0 ? 0 : first)) p.id];
  }

  bool canModulate(String paramId) {
    final p = target.param(paramId);
    return p != null && p.modulatable && destinations.contains(paramId);
  }

  ModRoute? route(int slot) {
    final src = ModSource.of(target.value(srcId(slot)));
    final dst = target.value(dstId(slot)).round();
    final dests = destinations;
    if (src == ModSource.none || dst <= 0 || dst > dests.length) return null;
    return ModRoute(slot: slot, source: src, paramId: dests[dst - 1], amount: target.value(amtId(slot)),
      bipolar: target.value(bipolarId(slot)) >= 0.5,
      via: target.param(viaId(slot)) == null ? ModSource.none : ModSource.of(target.value(viaId(slot))));
  }

  List<ModRoute> get routes => [for (var s = 1; s <= slotCount; s++) ?route(s)];

  List<ModRoute> routesTo(String paramId) => [for (final r in routes) if (r.paramId == paramId) r];

  /// The route from [source] to [paramId], or null.
  ModRoute? routeOf(ModSource source, String paramId) =>
      routes.where((r) => r.source == source && r.paramId == paramId).firstOrNull;

  /// The first slot with no source or no destination, or null when all are in use.
  int? get freeSlot {
    for (var s = 1; s <= slotCount; s++) {
      if (route(s) == null) return s;
    }
    return null;
  }

  /// Routes [source] to [paramId] (one undo step). An existing route of the same pair is kept and returned.
  /// Null when the parameter can't be modulated or every slot is in use.
  int? add(ModSource source, String paramId, {double amount = 0.25, bool? bipolar}) {
    if (source == ModSource.none || !canModulate(paramId)) return null;
    for (final r in routes) {
      if (r.source == source && r.paramId == paramId) return r.slot;
    }
    final slot = freeSlot;
    if (slot == null) return null;
    target.setAll({
      srcId(slot): source.value.toDouble(),
      dstId(slot): destinations.indexOf(paramId) + 1.0,
      amtId(slot): amount,
      bipolarId(slot): (bipolar ?? source.naturallyBipolar) ? 1 : 0,
    });
    return slot;
  }

  void remove(int slot) => target.setAll({srcId(slot): 0, dstId(slot): 0, amtId(slot): 0, bipolarId(slot): 0,
    if (target.param(viaId(slot)) != null) viaId(slot): 0});

  /// Assign mode's tap: adds the route from [source] to [paramId], or removes it when there is one. Returns the new
  /// slot, 0 when a route was removed, null when nothing could be done (not modulatable, every slot in use).
  int? toggle(ModSource source, String paramId) {
    final r = routeOf(source, paramId);
    if (r != null) {
      remove(r.slot);
      return 0;
    }
    return add(source, paramId);
  }

  /// A finished amount change (one undo step).
  void setAmount(int slot, double amount) => target.set(amtId(slot), amount.clamp(-1.0, 1.0));

  void setAmountLive(int slot, double amount) => target.setLive(amtId(slot), amount.clamp(-1.0, 1.0));

  void setSource(int slot, ModSource source) => target.set(srcId(slot), source.value.toDouble());

  void setDestination(int slot, String paramId) {
    final i = destinations.indexOf(paramId);
    if (i >= 0) target.set(dstId(slot), i + 1.0);
  }

  void setBipolar(int slot, bool on) => target.set(bipolarId(slot), on ? 1 : 0);

  /// Whether the device has `modN_via` (a route's amount scaled by a second source).
  bool get hasVia => slotCount > 0 && target.param(viaId(1)) != null;

  void setVia(int slot, ModSource via) {
    if (target.param(viaId(slot)) != null) target.set(viaId(slot), via.value.toDouble());
  }

  /// Where [paramId]'s routes take its knob travel ([position], 0..1) at [seconds] on a clock, with sources drawn in
  /// Dart ([ModPreview]); null when no route has a source the preview can draw (the note's own sources).
  double? modulatedPosition(String paramId, double position, double seconds) {
    final rs = routesTo(paramId);
    if (rs.isEmpty) return null;
    final preview = ModPreview(target);
    var moved = 0.0;
    var any = false;
    for (final r in rs) {
      final u = preview.value(r.source, seconds);
      if (u == null) continue;
      any = true;
      final scale = r.via == ModSource.none ? 1.0 : (preview.value(r.via, seconds) ?? 1.0);
      moved += r.offset(u, scale: scale);
    }
    return any ? (position + moved).clamp(0.0, 1.0) : null;
  }
}

/// An APPROXIMATE value (0..1) of a mod source over time, for drawing a knob's modulated value: the LFOs from their
/// shape, rate and sync at the project's tempo; random at its rate; each envelope as if a note were held for a beat
/// every two beats. The engine's sources run per voice and from each note, so this shows the motion, not the voice.
class ModPreview {
  ModPreview(this.target);
  final DeviceTarget target;

  double get _bpm => target.state.project.bpm;

  /// The source's value at [seconds], or null when it has no shape of its own (velocity, note, bend, pressure,
  /// timbre, the mod wheel: they follow what is played).
  double? value(ModSource s, double seconds) {
    switch (s) {
      case ModSource.lfo1 || ModSource.lfo2 || ModSource.lfo3:
        final p = 'lfo${s.index - ModSource.lfo1.index + 1}_';
        final hz = lfoHz(target.value('${p}rate'), target.value('${p}sync').round(), _bpm);
        final phase = seconds * hz;
        final shape = target.value('${p}shape').round();
        return (lfoValue(shape, phase, cycle: phase.floor()) + 1) / 2;
      case ModSource.random:
        final phase = seconds * target.value('rnd_rate');
        final smooth = target.value('rnd_mode') >= 0.5;
        return (lfoValue(smooth ? 6 : 5, phase, cycle: phase.floor()) + 1) / 2;
      case ModSource.env1 || ModSource.env2 || ModSource.env3:
        final p = 'env${s.index - ModSource.env1.index + 1}_';
        return envelopeAt(seconds, attack: target.value('${p}attack'), decay: target.value('${p}decay'),
          sustain: target.value('${p}sustain'), release: target.value('${p}release'), beat: 60 / _bpm);
      default:
        return null;
    }
  }

  /// An ADSR's level at [seconds] when a note is held for one [beat] out of every two.
  static double envelopeAt(double seconds, {required double attack, required double decay, required double sustain,
      required double release, required double beat}) {
    final period = 2 * beat;
    final t = seconds % period;
    double held(double t) {
      if (t < attack) return attack <= 0 ? 1 : t / attack;
      final d = t - attack;
      if (d < decay) return 1 - (1 - sustain) * (decay <= 0 ? 1 : d / decay);
      return sustain;
    }

    if (t < beat) return held(t).clamp(0.0, 1.0);
    final from = held(beat);
    final r = t - beat;
    return release <= 0 ? 0 : (from * math.exp(-5 * r / release)).clamp(0.0, 1.0);
  }
}
