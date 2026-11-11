// Controller learn: a hardware control's MIDI CC mapped to a knob of a track's instrument or effect, kept in the
// project, and the CC's value turned into the knob's value on its own curve (and back, for a .mid export's lanes).
import '../engine/component_info.dart';
import '../ui/arrange/knob.dart' show Taper;
import 'project.dart' show ProjectAutomationLaneDoc;

/// CC [cc] on MIDI [channel] (0..15) moves [paramId] of the device at [slot] on track [layerId] (slot -1: its
/// instrument, as `DeviceTarget.instrumentSlot`).
class MidiCcMapping {
  const MidiCcMapping({required this.channel, required this.cc, required this.layerId, required this.slot, required this.paramId});
  final int channel, cc;
  final String layerId;
  final int slot;
  final String paramId;

  bool matches(int channel, int cc) => this.channel == channel && this.cc == cc;
  bool targets(String layerId, int slot, String paramId) =>
      this.layerId == layerId && this.slot == slot && this.paramId == paramId;

  Map<String, dynamic> toJson() => {'channel': channel, 'cc': cc, 'layer': layerId, 'slot': slot, 'param': paramId};

  static MidiCcMapping? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ch = raw['channel'], cc = raw['cc'], layer = raw['layer'], slot = raw['slot'], param = raw['param'];
    if (ch is! int || cc is! int || layer is! String || slot is! int || param is! String) return null;
    if (ch < 0 || ch > 15 || cc < 0 || cc > 127 || slot < -1 || param.isEmpty || param.length > 128) return null;
    return MidiCcMapping(channel: ch, cc: cc, layerId: layer, slot: slot, paramId: param);
  }

  /// The parameter's value for CC value [v] (0..127): a position on the knob's travel, so a CC sweeps an
  /// exponential knob as a drag does (the engine's F6.5 rule), and a choice steps through its choices.
  static double valueFor(ComponentParameterInfo p, int v) {
    final pos = (v.clamp(0, 127)) / 127;
    final x = Taper(p.min, p.max, exponential: p.exponential).value(pos);
    return p.isChoice ? x.roundToDouble().clamp(p.min, p.max) : x;
  }

  /// The CC value (0..127) that [valueFor] turns into [value]: its position on the knob's travel, so an exported lane
  /// played back through the same mapping lands on the same knob values.
  static int ccFor(ComponentParameterInfo p, double value) =>
      (Taper(p.min, p.max, exponential: p.exponential).position(value) * 127).round().clamp(0, 127);

  /// Whether this mapping moves the knob [lane] automates (a project lane on an instrument or effect parameter).
  bool movesLane(ProjectAutomationLaneDoc lane) {
    final slot = switch (lane.targetType) {
      'instrument' => -1,
      'component' => lane.component,
      _ => null,
    };
    return slot != null && lane.layerId != null && targets(lane.layerId!, slot, lane.target);
  }
}

/// The controller (and channel, 0..15) each of a track's project [lanes] goes out as in a .mid export (#11), in lane
/// order: a lane whose knob has a learned CC ([mappings]) uses that CC on the mapping's channel, so the file moves the
/// same knob when played back into C.A.W, and a mod wheel learned onto a knob makes its lane CC1; every other lane takes
/// the next number of [pool] on channel 0 that no learned CC on channel 0 uses (null once the pool runs out). A CC two
/// lanes learned goes to the first; the second takes a pool number, so no controller carries two lanes.
List<({int cc, int channel, MidiCcMapping? learned})?> automationLaneCcs(
    List<MidiCcMapping> mappings, List<ProjectAutomationLaneDoc> lanes, List<int> pool) {
  final learned = [for (final l in lanes) mappings.where((m) => m.movesLane(l)).firstOrNull];
  final used = <(int, int)>{};
  final out = List<({int cc, int channel, MidiCcMapping? learned})?>.filled(lanes.length, null);
  for (final (i, m) in learned.indexed) {
    if (m == null || !used.add((m.channel, m.cc))) continue;
    out[i] = (cc: m.cc, channel: m.channel, learned: m);
  }
  final free = [for (final cc in pool) if (!used.contains((0, cc))) cc].iterator;
  for (var i = 0; i < lanes.length; i++) {
    if (out[i] != null || !free.moveNext()) continue;
    out[i] = (cc: free.current, channel: 0, learned: null);
  }
  return out;
}
