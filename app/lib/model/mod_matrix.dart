// A device's mod matrix read from and written to its `modN_src/dst/amt/bipolar` parameters (the flagship synth's layout).
import 'device_target.dart';

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

/// One used slot: [source] moves [paramId] by [amount] of its knob travel (−1..1), both ways when [bipolar].
class ModRoute {
  const ModRoute({required this.slot, required this.source, required this.paramId, required this.amount,
    required this.bipolar});
  final int slot; // 1..slotCount
  final ModSource source;
  final String paramId;
  final double amount;
  final bool bipolar;

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
      bipolar: target.value(bipolarId(slot)) >= 0.5);
  }

  List<ModRoute> get routes => [for (var s = 1; s <= slotCount; s++) ?route(s)];

  List<ModRoute> routesTo(String paramId) => [for (final r in routes) if (r.paramId == paramId) r];

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

  void remove(int slot) => target.setAll({srcId(slot): 0, dstId(slot): 0, amtId(slot): 0, bipolarId(slot): 0});

  void setAmountLive(int slot, double amount) => target.setLive(amtId(slot), amount.clamp(-1.0, 1.0));

  void setSource(int slot, ModSource source) => target.set(srcId(slot), source.value.toDouble());

  void setDestination(int slot, String paramId) {
    final i = destinations.indexOf(paramId);
    if (i >= 0) target.set(dstId(slot), i + 1.0);
  }

  void setBipolar(int slot, bool on) => target.set(bipolarId(slot), on ? 1 : 0);
}
