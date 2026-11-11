// Controller learn: a hardware control's MIDI CC mapped to a knob of a track's instrument or effect, kept in the
// project, and the CC's value turned into the knob's value on its own curve.
import '../engine/component_info.dart';
import '../ui/arrange/knob.dart' show Taper;

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
}
