// A merged device's variant change (FX consolidation, 1.0.8): one undo step that resets the knobs the new variant doesn't share.
import '../engine/component_info.dart';
import 'app_state.dart';
import 'arrange_fx.dart';
import 'device_target.dart';
import 'merged_devices.dart';
import 'mixer_fx.dart';
import 'racks.dart';

/// Whether [a] and [b] are the same knob in the same units: id, range, step, unit, name, taper and choices. Only
/// such a knob keeps its value (and its lanes, links and MIDI mappings) across a variant change; Drive's `drive` and
/// `output` and Delay's `sync` share an id but not their meaning, so they reset.
bool sameKnob(ComponentParameterInfo a, ComponentParameterInfo b) =>
    a.id == b.id && a.min == b.min && a.max == b.max && a.step == b.step && a.unit == b.unit && a.name == b.name &&
    a.exponential == b.exponential && a.choices.length == b.choices.length &&
    [for (var i = 0; i < a.choices.length; i++) a.choices[i] == b.choices[i]].every((x) => x);

/// [values] (one device's, without a prefix) for [to] after [from]: `variant` set to [variant], each value kept only
/// when [from] and [to] both declare it as the [sameKnob]; every other value goes, so the new variant's knobs start at
/// their defaults and another variant's leftovers are not kept. Returns the kept ids too.
({Map<String, double> values, Set<String> kept}) valuesForVariant(
    Map<String, double> values, NativeComponentInfo from, NativeComponentInfo to, int variant) {
  final kept = <String>{};
  final out = <String, double>{};
  for (final e in values.entries) {
    if (e.key == variantParam) continue;
    final a = from.param(e.key), b = to.param(e.key);
    if (a != null && b != null && sameKnob(a, b)) {
      out[e.key] = e.value;
      kept.add(e.key);
    }
  }
  // Knobs left at their defaults are shared too when they are the same knob (their lanes stay).
  for (final p in to.parameters) {
    final a = from.param(p.id);
    if (p.id != variantParam && a != null && sameKnob(a, p)) kept.add(p.id);
  }
  out[variantParam] = variant.toDouble();
  return (values: out, kept: kept);
}

extension VariantEdit on AppState {
  /// Puts device [t] (a merged device or instrument, or a merged device in a rack's slot) on [variant] as one undo step. The knobs
  /// the new variant doesn't share with the old one reset ([valuesForVariant]); lanes, modulation links and MIDI
  /// mappings on them go (their units changed). The engine rebuilds the device, crossfaded. [also] sets knobs of the
  /// new variant in the same step (a filter model picked from a strip: the variant and its type at once). False when
  /// [t] is no merged device or already plays [variant].
  bool setDeviceVariant(DeviceTarget t, int variant, {Map<String, double> also = const {}}) {
    final id = t.componentId, layer = t.layer;
    final base = id == null ? null : componentInfo(id);
    if (id == null || layer == null || base == null || base.variants.length < 2) return false;
    if (variant < 0 || variant >= base.variants.length) return false;
    if (t is RackChildTarget) {
      final rack = t.rack, use = rack.use;
      if (use == null) return false;
      final prefix = '${t.rackSlot.name}.';
      final own = {
        for (final e in use.params.entries)
          if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
      };
      final from = base.forValues(own);
      if (from.variantIndex == variant) return false;
      final next = valuesForVariant(own, from, base.variants[variant], variant);
      next.values.addAll(_known(base.variants[variant], also));
      setRackValues(rack, rackValuesWithChildValues(rack, t.rackSlot, next.values, kept: next.kept));
      return true;
    }
    final use = t.use;
    if (use == null) return false;
    final from = base.forValues(use.params);
    if (from.variantIndex == variant) return false;
    final next = valuesForVariant(use.params, from, base.variants[variant], variant);
    next.values.addAll(_known(base.variants[variant], also));
    final laneLayer = engineLayerId(layer), mappingLayer = t.layerId, slot = t.slot;
    // A merged instrument (Starling's, Nightingale's... models) has its lanes and links as the track's instrument's, not a slot's.
    final inst = t.isInstrument;
    final type = inst ? 'instrument' : 'component';
    bool mine(int? component) => inst || component == slot;
    endUndoStep();
    editProject((p) {
      use.params = next.values;
      use.state = null;  // the old variant's saved state is another class's
      use.preset = null;
      p.automation.removeWhere((lane) =>
          lane.targetType == type && lane.layerId == laneLayer && mine(lane.component) && !next.kept.contains(lane.target));
      if (laneLayer != null) {
        for (final clip in layer.clips) {
          clip.automation.removeWhere(
              (lane) => lane.targetType == type && mine(lane.component) && !next.kept.contains(lane.target));
        }
      }
      p.modLinks.removeWhere((l) =>
          l.target.type == type && l.target.layerId == laneLayer && mine(l.target.index) &&
          !next.kept.contains(l.target.param));
      p.midiMappings.removeWhere((m) => m.layerId == mappingLayer && m.slot == slot && !next.kept.contains(m.paramId));
    });
    layerValueTick(layer.id).value++;
    endUndoStep();
    return true;
  }

  /// [values] that [info] declares (never `variant`).
  static Map<String, double> _known(NativeComponentInfo info, Map<String, double> values) => {
        for (final e in values.entries)
          if (e.key != variantParam && info.param(e.key) != null && e.value.isFinite) e.key: e.value,
      };
}
