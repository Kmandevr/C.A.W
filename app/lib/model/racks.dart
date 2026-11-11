// The racks (fx-racks): which built-in sits in each slot, the rack's whole parameter list, slot edits, and one child as a device.
import 'dart:convert';

import '../engine/component_info.dart';
import 'arrange_fx.dart';
import 'device_target.dart';

const fxRackId = 'org.caw.rack.fx';
const multibandRackId = 'org.caw.rack.multiband';

/// Whether [id] is a rack (a built-in that holds other built-ins; racks never hold racks).
bool isRackComponent(String id) => id.startsWith('org.caw.rack.');

/// A child's identity in its slot's `<slot>_fx` value: the engine's `rackChildHash` (engine/src/builtin_fx_racks.cpp),
/// 32-bit FNV-1a of the id xor-folded to 24 bits, never 0.
int rackChildHash(String id) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(id)) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }
  final folded = (h >> 24) ^ (h & 0xFFFFFF);
  return folded == 0 ? 1 : folded;
}

/// One slot of a rack: its parameter prefix (`s2`, `b3s1`), display prefix (`S2`, `B3.1`), band (0 on the FX rack) and
/// its place among the rack's slots (the child number a display read adds: docs/engine.md, Racks).
class RackSlot {
  const RackSlot(this.name, this.label, this.band, this.index);
  final String name, label;
  final int band, index;
  String get fxId => '${name}_fx';
  String get onId => '${name}_on';
  String param(String childParam) => '$name.$childParam';
}

/// The FX rack's slots in order, then the multiband rack's (5 bands of 4).
const int fxRackSlots = 8, multibandBands = 5, multibandSlotsPerBand = 4;

List<RackSlot> rackSlots(String rackId) => rackId == fxRackId
    ? [for (var s = 0; s < fxRackSlots; s++) RackSlot('s${s + 1}', 'S${s + 1}', 0, s)]
    : rackId == multibandRackId
        ? [
            for (var b = 0; b < multibandBands; b++)
              for (var s = 0; s < multibandSlotsPerBand; s++)
                RackSlot('b${b + 1}s${s + 1}', 'B${b + 1}.${s + 1}', b, b * multibandSlotsPerBand + s),
          ]
        : const [];

/// The built-in in [slot] given the rack's [params], or null for an empty slot (or one naming nothing known).
String? rackChildId(Map<String, double> params, RackSlot slot, Map<String, NativeComponentInfo> catalog) {
  final hash = (params[slot.fxId] ?? 0).round();
  if (hash == 0) return null;
  for (final id in catalog.keys) {
    if (rackChildHash(id) == hash) return id;
  }
  return null;
}

/// What can go in a slot: a built-in stereo effect (or keyed one) that is not a rack nor an instrument.
bool canGoInRack(NativeComponentInfo c) =>
    c.builtin && !isRackComponent(c.id) && !c.isInstrument && c.role != 'generator' &&
    c.ports.any((p) => p.isAudio && p.input && p.id != 'sidechain') && c.ports.any((p) => p.isAudio && !p.input);

final Map<String, NativeComponentInfo> _expanded = {};

/// The rack's whole parameter list for these values, as the engine builds it: its own parameters, each child's as
/// `<slot>.<id>` (named `<label> <name>`), then (FX rack) the routes, whose destination choices list everything
/// before them. Cached per structure.
NativeComponentInfo rackInfo(NativeComponentInfo base, Map<String, double> params, Map<String, NativeComponentInfo> catalog) {
  final slots = rackSlots(base.id);
  final children = [for (final s in slots) rackChildId(params, s, catalog)];
  final key = '${base.id}|${identityHashCode(base)}|${identityHashCode(catalog)}|${children.join(',')}';
  final hit = _expanded[key];
  if (hit != null) return hit;
  if (_expanded.length > 64) _expanded.clear();
  final firstRoute = base.parameters.indexWhere((p) => p.id == 'mod1_src');
  final own = firstRoute < 0 ? base.parameters : base.parameters.sublist(0, firstRoute);
  final out = <ComponentParameterInfo>[...own];
  for (var i = 0; i < slots.length; i++) {
    final child = children[i] == null ? null : catalog[children[i]];
    if (child == null) continue;
    for (final p in child.parameters) {
      out.add(ComponentParameterInfo(id: slots[i].param(p.id), name: '${slots[i].label} ${p.label}', unit: p.unit,
          defaultValue: p.defaultValue, min: p.min, max: p.max, step: p.step, exponential: p.exponential,
          smoothingFrames: p.smoothingFrames, automatable: p.automatable, modulatable: p.modulatable,
          midiMappable: p.midiMappable, choices: p.choices));
    }
  }
  if (firstRoute >= 0) {
    final labels = ['None', for (final p in out) p.label];
    for (final p in base.parameters.sublist(firstRoute)) {
      out.add(p.id.endsWith('_dst')
          ? ComponentParameterInfo(id: p.id, name: p.name, defaultValue: 0, min: 0, max: labels.length - 1.0, step: 1,
              automatable: p.automatable, modulatable: false, midiMappable: p.midiMappable, choices: labels)
          : p);
    }
  }
  final info = NativeComponentInfo(id: base.id, name: base.name, version: base.version, role: base.role,
      latencyFrames: base.latencyFrames, tailFrames: base.tailFrames, maxStateBytes: base.maxStateBytes,
      customUiId: base.customUiId, ports: base.ports, parameters: out, uiControls: base.uiControls,
      builtin: base.builtin, presets: base.presets);
  return _expanded[key] = info;
}

/// The rack's values with [childId] (null: empty) in [slot]: the slot's old child values go, the new child starts at
/// its defaults, switched on, and every route keeps pointing at the same knob (a route to a knob that went is cleared).
Map<String, double> rackValuesWithSlot(DeviceTarget rack, RackSlot slot, String? childId) {
  final use = rack.use, before = rack.info;
  final catalog = rack.state.componentCatalog.value;
  final base = rack.componentId == null ? null : rack.state.componentInfo(rack.componentId!);
  if (use == null || before == null || base == null) return const {};
  final values = Map<String, double>.of(use.params)..removeWhere((k, _) => k.startsWith('${slot.name}.'));
  values[slot.fxId] = childId == null ? 0 : rackChildHash(childId).toDouble();
  values[slot.onId] = 1;
  return _repointRoutes(before, rackInfo(base, values, catalog), values);
}

/// Moves the child in [from] to [to] (both on one rack), with its values; routes follow it.
Map<String, double> rackValuesMoved(DeviceTarget rack, RackSlot from, RackSlot to) {
  final use = rack.use, before = rack.info;
  final catalog = rack.state.componentCatalog.value;
  final base = rack.componentId == null ? null : rack.state.componentInfo(rack.componentId!);
  if (use == null || before == null || base == null || from.name == to.name) return use?.params ?? const {};
  final old = Map<String, double>.of(use.params);
  final values = Map<String, double>.of(old)
    ..removeWhere((k, _) => k.startsWith('${from.name}.') || k.startsWith('${to.name}.'));
  String moved(String k, RackSlot a, RackSlot b) => '${b.name}${k.substring(a.name.length)}';
  for (final e in old.entries) {
    if (e.key.startsWith('${from.name}.') || e.key == from.fxId || e.key == from.onId) values[moved(e.key, from, to)] = e.value;
    if (e.key.startsWith('${to.name}.') || e.key == to.fxId || e.key == to.onId) values[moved(e.key, to, from)] = e.value;
  }
  values.putIfAbsent(to.fxId, () => 0);
  values.putIfAbsent(from.fxId, () => 0);
  if (!old.containsKey(to.fxId)) values[from.fxId] = 0;
  if (!old.containsKey(from.fxId)) values[to.fxId] = 0;
  // Routes follow the knob to its new slot.
  final rename = <String, String>{
    for (final p in before.parameters)
      if (p.id.startsWith('${from.name}.')) p.id: moved(p.id, from, to)
      else if (p.id.startsWith('${to.name}.')) p.id: moved(p.id, to, from),
  };
  return _repointRoutes(before, rackInfo(base, values, catalog), values, rename: rename);
}

Map<String, double> _repointRoutes(NativeComponentInfo before, NativeComponentInfo after, Map<String, double> values,
    {Map<String, String> rename = const {}}) {
  List<String> dests(NativeComponentInfo i) {
    final first = i.parameters.indexWhere((p) => p.id == 'mod1_src');
    return [for (final p in i.parameters.take(first < 0 ? 0 : first)) p.id];
  }
  final was = dests(before), now = dests(after);
  for (var s = 1; values.containsKey('mod${s}_src') || before.parameters.any((p) => p.id == 'mod${s}_src'); s++) {
    final dst = (values['mod${s}_dst'] ?? 0).round();
    if (dst <= 0 || dst > was.length) continue;
    final id = rename[was[dst - 1]] ?? was[dst - 1];
    final at = now.indexOf(id);
    if (at >= 0) {
      values['mod${s}_dst'] = at + 1.0;
    } else {
      values['mod${s}_src'] = 0;
      values['mod${s}_dst'] = 0;
      values['mod${s}_amt'] = 0;
    }
  }
  return values;
}

/// Puts [values] on [rack] as they are (one undo step): structural changes rebuild the rack in the engine.
void setRackValues(DeviceTarget rack, Map<String, double> values) {
  final layer = rack.layer, use = rack.use;
  if (layer == null || use == null) return;
  rack.state.endUndoStep();
  rack.state.editLayer(layer, (_) {
    use.params = Map<String, double>.of(values);
    use.state = null;  // the children's states belonged to the old structure
    use.preset = null;
  });
  rack.state.layerValueTick(layer.id).value++;
  rack.state.endUndoStep();
}

/// One child of a rack as a device: its own parameter ids read and write the rack's `<slot>.<id>`; ids it doesn't
/// have (a route's `modN_*`) reach the rack's. Its switch is the slot's `_on`; its live display is the rack's child
/// [slot] (the engine's display index + (child + 1) × 65536).
class RackChildTarget extends DeviceTarget {
  RackChildTarget(DeviceTarget rack, this.rackSlot, this.childId) : rack = rack, super(rack.state, rack.layerId, rack.slot);
  final DeviceTarget rack;
  final RackSlot rackSlot;
  final String childId;

  @override
  String? get componentId => childId;

  @override
  NativeComponentInfo? get info => state.componentInfo(childId);

  @override
  String get label => state.componentLabel(childId);

  @override
  int get displayChild => rackSlot.index + 1;

  bool _own(String id) => info?.parameters.any((p) => p.id == id) ?? false;
  String _full(String id) => _own(id) ? rackSlot.param(id) : id;

  @override
  ComponentParameterInfo? param(String id) => _own(id) ? super.param(id) : rack.param(id);

  @override
  double value(String id) {
    if (!_own(id)) return rack.value(id);
    return rack.use?.params[_full(id)] ?? param(id)?.defaultValue ?? 0;
  }

  @override
  void setLive(String id, double v) => rack.setLive(_full(id), _own(id) && param(id) != null ? clampToParam(param(id)!, v) : v);

  @override
  void commit() => rack.commit();

  @override
  bool get bypass => rack.value(rackSlot.onId) < 0.5;

  @override
  void setBypass(bool on) => rack.set(rackSlot.onId, on ? 0 : 1);
}

/// The kind of a rack's slot list for the UI: the slots of [band] (all of them on the FX rack) with their children.
List<(RackSlot, String?)> rackChildren(DeviceTarget rack, {int? band}) {
  final id = rack.componentId, use = rack.use;
  if (id == null || use == null) return const [];
  final catalog = rack.state.componentCatalog.value;
  return [
    for (final s in rackSlots(id))
      if (band == null || s.band == band) (s, rackChildId(use.params, s, catalog)),
  ];
}
