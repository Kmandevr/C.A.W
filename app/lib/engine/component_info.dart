// Typed descriptors of loaded native components, parsed from caw_engine_components (engine/include/caw.h).
class ComponentPortInfo {
  const ComponentPortInfo({
    required this.id,
    required this.type,
    required this.input,
    required this.layout,
    required this.channels,
    this.summing = false,
  });

  final String id;
  final String type; // audio, control, modulation, event
  final bool input;
  final String layout; // none, mono, stereo, quad, 5.1, 7.1, discrete
  final int channels;
  final bool summing;

  bool get isAudio => type == 'audio';

  factory ComponentPortInfo.fromJson(Map<String, dynamic> j) => ComponentPortInfo(
        id: j['id'] as String? ?? '',
        type: j['type'] as String? ?? 'audio',
        input: j['input'] == true,
        layout: j['layout'] as String? ?? 'none',
        channels: (j['channels'] as num?)?.toInt() ?? 0,
        summing: j['summing'] == true,
      );
}

class ComponentParameterInfo {
  const ComponentParameterInfo({
    required this.id,
    this.name = '',
    this.unit = '',
    required this.defaultValue,
    required this.min,
    required this.max,
    this.step = 0,
    this.exponential = false,
    this.smoothingFrames = 0,
    this.automatable = true,
    this.modulatable = true,
    this.midiMappable = true,
    this.choices = const [],
    this.group = '',
  });

  final String id;
  final String name;
  final String unit;
  final double defaultValue, min, max, step;
  final bool exponential;
  final int smoothingFrames;
  final bool automatable, modulatable, midiMappable;
  final List<String> choices; // labels for min, min + 1, ..., max

  /// Where a built-in shows the knob, a slash path (`kit/glue`, `a1/body`); empty when the descriptor gives none.
  final String group;

  /// The name to show: the display name, or the id when there is none.
  String get label => name.isEmpty ? id : name;
  bool get isChoice => choices.isNotEmpty;

  factory ComponentParameterInfo.fromJson(Map<String, dynamic> j) => ComponentParameterInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        defaultValue: (j['default'] as num?)?.toDouble() ?? 0,
        min: (j['min'] as num?)?.toDouble() ?? 0,
        max: (j['max'] as num?)?.toDouble() ?? 1,
        step: (j['step'] as num?)?.toDouble() ?? 0,
        exponential: j['curve'] == 'exponential',
        smoothingFrames: (j['smoothing_frames'] as num?)?.toInt() ?? 0,
        automatable: j['automatable'] != false,
        modulatable: j['modulatable'] != false,
        midiMappable: j['midi_mappable'] != false,
        choices: [for (final c in (j['choices'] as List? ?? const [])) c as String],
        group: j['group'] as String? ?? '',
      );
}

class ComponentUiControlInfo {
  const ComponentUiControlInfo({
    required this.id,
    this.label = '',
    this.parameterId = '',
    required this.kind,
    required this.min,
    required this.max,
  });

  final String id, label, parameterId;
  final String kind; // slider, toggle, dropdown, xy_pad, button, curve
  final double min, max;

  factory ComponentUiControlInfo.fromJson(Map<String, dynamic> j) => ComponentUiControlInfo(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        parameterId: j['parameter_id'] as String? ?? '',
        kind: j['kind'] as String? ?? 'slider',
        min: (j['min'] as num?)?.toDouble() ?? 0,
        max: (j['max'] as num?)?.toDouble() ?? 1,
      );
}

/// A built-in preset: a name and the parameter values it sets (the others keep their defaults).
class ComponentPresetInfo {
  const ComponentPresetInfo({required this.name, this.description = '', this.params = const {}});
  final String name, description;
  final Map<String, double> params;

  factory ComponentPresetInfo.fromJson(Map<String, dynamic> j) => ComponentPresetInfo(
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        params: {
          for (final e in ((j['params'] as Map?) ?? const {}).entries)
            if (e.value is num) e.key as String: (e.value as num).toDouble(),
        },
      );
}

final _paramIndex = Expando<Map<String, ComponentParameterInfo>>('parameters by id');

class NativeComponentInfo {
  const NativeComponentInfo({
    required this.id,
    this.name = '',
    this.version = 1,
    this.role = 'unspecified',
    this.latencyFrames = 0,
    this.tailFrames,
    this.maxStateBytes = 0,
    this.customUiId = '',
    this.ports = const [],
    this.parameters = const [],
    this.uiControls = const [],
    this.builtin = false,
    this.presets = const [],
    this.domains = const ['whole'],
    this.cpuClass = 'unspecified',
  });

  final String id, name;
  final int version;
  final String role; // unspecified, instrument, generator, effect, utility, event_processor, analyzer
  final int latencyFrames;
  final int? tailFrames; // null: the output may never fall silent
  final int maxStateBytes;
  final String customUiId;
  final List<ComponentPortInfo> ports;
  final List<ComponentParameterInfo> parameters;
  final List<ComponentUiControlInfo> uiControls;

  /// Part of the engine (the Library's stereo tools): always there, no trust choice, can't be unloaded.
  final bool builtin;

  /// A built-in's named parameter sets (Flagship's "Mono bass", "Acid 303"...), in display order.
  final List<ComponentPresetInfo> presets;

  /// Where it may run (#120): "whole", "per_channel", "per_voice", "per_note". An effect with "per_note" (or
  /// "per_voice") can run once per note; an instrument with it has a voice bus, so it can host per-note effects.
  final List<String> domains;

  /// Its author's cost hint: "unspecified", "light", "medium" or "heavy" (not a measurement).
  final String cpuClass;

  bool get runsPerNote => domains.contains('per_note') || domains.contains('per_voice');

  String get label => name.isEmpty ? id : name;

  /// Parameter [id], or null. A long list is indexed on first use, so a descriptor with thousands of knobs (the
  /// drums' 10392) costs one hash lookup per knob, not a scan; a short one (or a rack's, rebuilt per read) is scanned.
  ComponentParameterInfo? param(String id) {
    if (parameters.length < 64) {
      for (final p in parameters) {
        if (p.id == id) return p;
      }
      return null;
    }
    return (_paramIndex[this] ??= {for (final p in parameters) p.id: p})[id];
  }

  /// An instrument plays a track's notes: one event input and one stereo audio output, no audio input (the engine
  /// checks the same shape; docs/native-module-sdk.md).
  bool get isInstrument =>
      ports.length == 2 &&
      ports.any((p) => p.type == 'event' && p.input) &&
      ports.any((p) => p.isAudio && !p.input && p.channels == 2);

  factory NativeComponentInfo.fromJson(Map<String, dynamic> j) => NativeComponentInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        version: (j['version'] as num?)?.toInt() ?? 1,
        role: j['role'] as String? ?? 'unspecified',
        latencyFrames: (j['latency_frames'] as num?)?.toInt() ?? 0,
        tailFrames: (j['tail_frames'] as num?)?.toInt(),
        maxStateBytes: (j['max_state_bytes'] as num?)?.toInt() ?? 0,
        customUiId: j['custom_ui_id'] as String? ?? '',
        ports: [for (final p in (j['ports'] as List? ?? const [])) ComponentPortInfo.fromJson(p as Map<String, dynamic>)],
        parameters: [
          for (final p in (j['parameters'] as List? ?? const [])) ComponentParameterInfo.fromJson(p as Map<String, dynamic>)
        ],
        uiControls: [
          for (final u in (j['ui_controls'] as List? ?? const [])) ComponentUiControlInfo.fromJson(u as Map<String, dynamic>)
        ],
        builtin: j['builtin'] == true,
        presets: [
          for (final p in (j['presets'] as List? ?? const [])) ComponentPresetInfo.fromJson(p as Map<String, dynamic>)
        ],
        domains: [for (final d in (j['domains'] as List? ?? const ['whole'])) if (d is String) d],
        cpuClass: j['cpu_class'] as String? ?? 'unspecified',
      );

  /// Parses the whole caw_engine_components result; an error result gives an empty list.
  static List<NativeComponentInfo> listFromJson(Map<String, dynamic> j) => j['ok'] == true
      ? [for (final c in (j['components'] as List? ?? const [])) NativeComponentInfo.fromJson(c as Map<String, dynamic>)]
      : const [];
}
