// Device presets (Init, the engine's list when it offers one, starter lists in Dart) and the header's A/B compare snapshots.
import '../../../engine/component_info.dart';
import '../../../model/device_target.dart';

/// A named set of values for a device; parameters it leaves out go to their defaults.
class DevicePreset {
  const DevicePreset(this.name, this.values, {this.category = ''});
  final String name, category;
  final Map<String, double> values;

  /// Every parameter of [info]: this preset's value, else the default.
  Map<String, double> resolve(NativeComponentInfo info) =>
      {for (final p in info.parameters) p.id: values[p.id] ?? p.defaultValue};
}

/// Where a device's presets come from: "Init" (the defaults) first, then the engine's list for the component when
/// [engine] is set (the seam for the engine's preset list API), then any list registered in Dart for its id.
class DevicePresets {
  DevicePresets._();

  static final Map<String, List<DevicePreset>> _byId = {};

  /// The engine's presets for a component (its descriptor's "presets", caw_engine_components): Flagship's Morph pad,
  /// Mono bass, Acid 303 and Basic. The engine's "Init" is Flagship's defaults, the same as the browser's own.
  static List<DevicePreset>? Function(DeviceTarget target)? engine = fromDescriptor;

  static List<DevicePreset> fromDescriptor(DeviceTarget target) => [
        for (final p in target.info?.presets ?? const <ComponentPresetInfo>[])
          if (p.name != 'Init') DevicePreset(p.name, p.params, category: 'Factory'),
      ];

  static void register(String componentId, List<DevicePreset> presets) => _byId[componentId] = presets;

  static List<DevicePreset> of(DeviceTarget target) {
    final id = target.componentId;
    if (id == null) return const [];
    final fromEngine = engine?.call(target) ?? const <DevicePreset>[];
    final names = {for (final p in fromEngine) p.name};
    return [
      const DevicePreset('Init', {}, category: 'Init'),
      ...fromEngine,
      for (final p in _byId[id] ?? const <DevicePreset>[]) if (!names.contains(p.name)) p,
    ];
  }

  static final Map<String, String> _current = {};

  static String _key(DeviceTarget t) => '${t.layerId}\u0000${t.slot}\u0000${t.componentId}';

  /// Loads [preset] into the device (one undo step) and remembers its name.
  static void apply(DeviceTarget target, DevicePreset preset) {
    final info = target.info;
    if (info == null) return;
    target.setAll(preset.resolve(info));
    _current[_key(target)] = preset.name;
    target.use?.preset = null;  // every value is set now: the entry no longer starts from a preset
  }

  /// The name the header shows: the preset last loaded, with "*" when a value has changed since; "Init" while every
  /// value is the default.
  static String label(DeviceTarget target) {
    final info = target.info;
    if (info == null) return '';
    final name = _current[_key(target)] ?? target.use?.preset;  // a track that opened on a preset shows its name
    final preset = name == null ? null : of(target).where((p) => p.name == name).firstOrNull;
    if (preset != null) return matches(target, preset) ? preset.name : '${preset.name} *';
    return matches(target, const DevicePreset('Init', {})) ? 'Init' : 'Custom';
  }

  static bool matches(DeviceTarget target, DevicePreset preset) {
    final info = target.info;
    if (info == null) return false;
    for (final p in info.parameters) {
      if ((target.value(p.id) - (preset.values[p.id] ?? p.defaultValue)).abs() > 1e-6) return false;
    }
    return true;
  }
}

/// The header's A/B compare: two snapshots of one device's values; switching keeps the side being left and loads the
/// other (a copy of the first, the first time), as one undo step.
class DeviceAB {
  DeviceAB._();
  static final Map<String, (bool, Map<String, double>?)> _state = {};

  static String _key(DeviceTarget t) => '${t.layerId}\u0000${t.slot}\u0000${t.componentId}';

  /// True while side B is loaded.
  static bool isB(DeviceTarget t) => _state[_key(t)]?.$1 ?? false;

  static void select(DeviceTarget t, bool b) {
    final info = t.info;
    if (info == null || isB(t) == b) return;
    final now = {for (final p in info.parameters) p.id: t.value(p.id)};
    final other = _state[_key(t)]?.$2;
    _state[_key(t)] = (b, now);
    if (other != null) t.setAll(other);
  }
}
