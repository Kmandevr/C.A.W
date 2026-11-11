// Device presets (Init, the engine's list when it offers one, starter lists in Dart, the user's own) and the header's A/B compare snapshots.
import '../../../engine/component_info.dart';
import '../../../model/device_target.dart';
import '../../../model/user_presets.dart';

/// A named set of values for a device; parameters it leaves out go to their defaults, and values for parameters
/// the device doesn't have are ignored. A user preset ([userId]) may carry the component's saved [state].
class DevicePreset {
  const DevicePreset(this.name, this.values, {this.category = '', this.userId, this.state, this.stateVersion = 1});
  final String name, category;
  final Map<String, double> values;

  /// The user preset's id in the library; null for a factory preset (Init, the engine's, Dart starters).
  final String? userId;
  final String? state;
  final int stateVersion;

  bool get isUser => userId != null;

  /// What the header remembers it by: a user preset's id (it survives a rename), else its name.
  String get key => userId == null ? name : 'user:$userId';

  /// The favourites key in the library: `user:ID`, or `factory:COMPONENT/NAME`.
  String favouriteKey(String componentId) => userId == null ? 'factory:$componentId/$name' : 'user:$userId';

  /// A device preset from the user's library.
  factory DevicePreset.user(UserPreset p) => DevicePreset(p.name, p.device?.params ?? const {},
      category: p.category, userId: p.id, state: p.device?.state, stateVersion: p.device?.stateVersion ?? 1);

  /// Every parameter of [info]: this preset's value, else the default.
  Map<String, double> resolve(NativeComponentInfo info) =>
      {for (final p in info.parameters) p.id: values[p.id] ?? p.defaultValue};
}

/// Where a device's presets come from: "Init" (the defaults) first, then the engine's list for the component when
/// [engine] is set (the seam for the engine's preset list API), then any list registered in Dart for its id (these
/// are the Factory group), then the user's own from the app-wide library ("My presets").
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

  static List<DevicePreset> of(DeviceTarget target) => [...factory(target), ...user(target)];

  /// Init, the engine's presets and the Dart starters.
  static List<DevicePreset> factory(DeviceTarget target) {
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

  /// The user's presets for the device's component, by name.
  static List<DevicePreset> user(DeviceTarget target) {
    final id = target.componentId;
    if (id == null) return const [];
    return [for (final p in target.state.userPresets.forComponent(id)) DevicePreset.user(p)];
  }

  /// What was loaded last, per device: the preset's [DevicePreset.key] and name.
  static final Map<String, (String, String)> _current = {};

  static String _key(DeviceTarget t) => '${t.layerId}\u0000${t.slot}\u0000${t.componentId}';

  /// Loads [preset] into the device (one undo step, its saved state included) and remembers it.
  static void apply(DeviceTarget target, DevicePreset preset) {
    final info = target.info;
    final use = target.use;
    if (info == null || use == null) return;
    target.state.endUndoStep();  // edits before it are a step of their own
    if (preset.state != null) {
      use.state = preset.state;
      use.stateVersion = preset.stateVersion;
    }
    remember(target, preset);
    use.preset = null;  // every value is set now: the entry no longer starts from a preset
    target.setAll(preset.resolve(info));
    target.state.endUndoStep();
  }

  /// Makes [preset] the device's current one without loading it (just saved from its values).
  static void remember(DeviceTarget target, DevicePreset preset) => _current[_key(target)] = (preset.key, preset.name);

  /// The user preset loaded last into the device, while it is still in the library; null otherwise.
  static UserPreset? currentUser(DeviceTarget target) {
    final key = _current[_key(target)]?.$1;
    if (key == null || !key.startsWith('user:')) return null;
    final p = target.state.userPresets.byId(key.substring(5));
    return p?.componentId == target.componentId ? p : null;
  }

  /// The device's current preset when it is one of [of]'s (a user preset by id, else by name), or null.
  static DevicePreset? current(DeviceTarget target) {
    final remembered = _current[_key(target)];
    final key = remembered?.$1, name = remembered?.$2 ?? target.use?.preset;
    final all = of(target);
    if (key != null) {
      final byKey = all.where((p) => p.key == key).firstOrNull;
      if (byKey != null || key.startsWith('user:')) return byKey;
    }
    return name == null ? null : all.where((p) => !p.isUser && p.name == name).firstOrNull;
  }

  /// True when the device's values differ from its current preset's.
  static bool modified(DeviceTarget target) {
    final p = current(target);
    return p != null && !matches(target, p);
  }

  /// The name the header shows: the preset last loaded, with "*" when a value has changed since; "Init" while every
  /// value is the default.
  static String label(DeviceTarget target) {
    final info = target.info;
    if (info == null) return '';
    // A track that opened on a preset shows its name; a user preset is found by its id, so a rename shows.
    final preset = current(target);
    if (preset != null) return matches(target, preset) ? preset.name : '${preset.name} *';
    // A preset the list doesn't hold (the engine's list not loaded yet, a deleted user preset): still its name.
    final name = _current[_key(target)]?.$2 ?? target.use?.preset;
    if (name != null && name != 'Init') return name;
    return matches(target, const DevicePreset('Init', {})) ? 'Init' : 'Custom';
  }

  /// Parameters that pick what an editor shows, not how the device sounds (the drums' shown pad): an edit of them
  /// leaves the preset's name as it was.
  static const viewOnly = {'view_pad'};

  static bool matches(DeviceTarget target, DevicePreset preset) {
    final info = target.info;
    if (info == null) return false;
    for (final p in info.parameters) {
      if (viewOnly.contains(p.id)) continue;
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
