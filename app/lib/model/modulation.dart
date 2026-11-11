// Project modulation (#161) in the app: modulators, links from any modulator output to any knob, volume, pan or send, their engine JSON and edits.
import 'package:flutter/foundation.dart';

import '../engine/component_info.dart';
import 'app_state.dart';
import 'arrange_fx.dart';
import 'device_target.dart';
import 'mixer_fx.dart';
import 'project.dart';
import 'routing.dart';
import 'routing_edit.dart';

/// The engine's built-in modulators (engine/src/builtin_modulators.cpp), in the order the Add menu shows them.
class ModulatorKinds {
  ModulatorKinds._();
  static const lfo = 'org.caw.mod.lfo';
  static const envelope = 'org.caw.mod.envelope';
  static const follower = 'org.caw.mod.follower';
  static const steps = 'org.caw.mod.steps';
  static const random = 'org.caw.mod.random';
  static const macros = 'org.caw.mod.macros';
  static const midi = 'org.caw.mod.midi';
  static const builtins = [lfo, envelope, follower, steps, random, macros, midi];

  /// A short name before the descriptor arrives, and the name a new one gets ("LFO 2").
  static String label(String id) => switch (id) {
        lfo => 'LFO',
        envelope => 'Envelope',
        follower => 'Follower',
        steps => 'Steps',
        random => 'Random',
        macros => 'Macros',
        midi => 'MIDI to CV',
        _ => id.split('.').last,
      };

  /// Its outputs' names before the descriptor arrives (the descriptor's modulation ports, in order).
  static List<String> outputs(String id) => switch (id) {
        macros => const ['M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'M7', 'M8'],
        midi => const ['Pitch', 'Velocity', 'Gate', 'Pressure'],
        _ => const ['Out'],
      };

  /// What it listens to by default: notes (an envelope, MIDI to CV, a retriggered LFO), audio (a follower) or none.
  static String hears(String id) => switch (id) {
        follower => 'audio',
        envelope || midi || lfo => 'notes',
        _ => 'none',
      };
}

/// Whether a component is a modulator: modulation outputs only, with at most one event and one audio input (the
/// engine's `ComponentChain::isModulator`). It goes in a project's modulators, never on a chain.
bool isModulatorInfo(NativeComponentInfo info) =>
    info.ports.any((p) => p.type == 'modulation' && !p.input) &&
    info.ports.every((p) => (p.type == 'modulation' && !p.input) || (p.input && (p.type == 'event' || p.isAudio)));

/// One project modulator (engine "modulators"): its component and values, the track it is shown on ([layerId], null
/// for the project's own, shown on the master) and the track whose notes or audio it hears ([inputId]).
class ModulatorDoc {
  ModulatorDoc({required this.id, required this.name, required this.componentId, Map<String, double>? params,
    this.layerId, this.inputId, this.hears = 'notes', this.post = false, this.bypass = false})
      : params = params ?? {};

  final String id;
  String name;
  final String componentId;
  Map<String, double> params;
  String? layerId, inputId;
  String hears; // notes, audio, both, none
  bool post, bypass;

  bool get hearsAudio => hears == 'audio' || hears == 'both';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'component': componentId,
        if (params.isNotEmpty) 'params': params,
        'layer': ?layerId,
        'input': ?inputId,
        if (hears != 'notes') 'hears': hears,
        if (post) 'post': true,
        if (bypass) 'bypass': true,
      };

  static ModulatorDoc? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['component'] is! String) return null;
    final hears = j['hears'];
    return ModulatorDoc(
      id: j['id'] as String,
      name: j['name'] is String ? j['name'] as String : ModulatorKinds.label(j['component'] as String),
      componentId: j['component'] as String,
      params: {
        for (final e in ((j['params'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is num && (e.value as num).isFinite) e.key as String: (e.value as num).toDouble(),
      },
      layerId: j['layer'] as String?,
      inputId: j['input'] as String?,
      hears: hears is String && const ['notes', 'audio', 'both', 'none'].contains(hears) ? hears : 'notes',
      post: j['post'] == true,
      bypass: j['bypass'] == true,
    );
  }
}

/// What a link moves: a parameter of a track's (or, [layerId] null, the master's) component [index] or instrument,
/// of another modulator ([layerId] is its id), or a track's volume, pan or send [index].
@immutable
class ModTarget {
  const ModTarget._(this.type, this.layerId, this.index, this.param);
  const ModTarget.component(String? layerId, int index, String param) : this._('component', layerId, index, param);
  const ModTarget.instrument(String layerId, String param) : this._('instrument', layerId, -1, param);
  const ModTarget.modulator(String modulatorId, String param) : this._('modulator', modulatorId, -1, param);
  const ModTarget.volume(String layerId) : this._('volume', layerId, -1, '');
  const ModTarget.pan(String layerId) : this._('pan', layerId, -1, '');
  const ModTarget.send(String layerId, int index) : this._('send', layerId, index, '');

  final String type;
  final String? layerId;
  final int index;
  final String param;

  bool get isMix => type == 'volume' || type == 'pan' || type == 'send';

  /// The knob a device editor shows for [paramId] of [t] (a component, an instrument or a modulator).
  static ModTarget ofDevice(DeviceTarget t, String paramId) {
    if (t is ModulatorDeviceTarget) return ModTarget.modulator(t.modulatorId, paramId);
    if (t.isInstrument) return ModTarget.instrument(t.layerId, paramId);
    return ModTarget.component(t.layerId == masterLayerId ? null : t.layerId, t.slot, paramId);
  }

  Map<String, dynamic> toJson() => {'type': type, 'layer': ?layerId, if (index >= 0) 'index': index, if (param.isNotEmpty) 'param': param};

  static ModTarget? fromJson(Object? j) {
    if (j is! Map || j['type'] is! String) return null;
    final layer = j['layer'] is String ? j['layer'] as String : null;
    final index = j['index'] is num ? (j['index'] as num).toInt() : -1;
    final param = j['param'] is String ? j['param'] as String : '';
    return switch (j['type']) {
      'component' when index >= 0 && param.isNotEmpty => ModTarget.component(layer, index, param),
      'instrument' when layer != null && param.isNotEmpty => ModTarget.instrument(layer, param),
      'modulator' when layer != null && param.isNotEmpty => ModTarget.modulator(layer, param),
      'volume' when layer != null => ModTarget.volume(layer),
      'pan' when layer != null => ModTarget.pan(layer),
      'send' when layer != null && index >= 0 => ModTarget.send(layer, index),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ModTarget && other.type == type && other.layerId == layerId && other.index == index && other.param == param;

  @override
  int get hashCode => Object.hash(type, layerId, index, param);

  @override
  String toString() => 'ModTarget($type, $layerId, $index, $param)';
}

/// A modulator output, as a drag or assign mode carries it.
@immutable
class ModSourceRef {
  const ModSourceRef(this.modulatorId, this.output);
  final String modulatorId;
  final int output;

  @override
  bool operator ==(Object other) => other is ModSourceRef && other.modulatorId == modulatorId && other.output == output;

  @override
  int get hashCode => Object.hash(modulatorId, output);
}

/// One link: the same route record as a device's `modN_*` slots ([amount] of the target's travel, −1..1, both ways
/// when [bipolar]) plus a response [curve] (−1..1, 0 straight), at project level. Links into one target add up.
class ModLinkDoc {
  ModLinkDoc({required this.id, required this.source, this.output = 0, required this.target, this.amount = 0.25,
    this.bipolar = false, this.curve = 0});

  final int id;
  final String source;
  final int output;
  ModTarget target;
  double amount, curve;
  bool bipolar;

  ModSourceRef get ref => ModSourceRef(source, output);

  /// The travel this link covers around a knob at [position] (0..1), clamped (as [ModRoute.span]).
  (double, double) span(double position) {
    final lo = bipolar ? position - amount.abs() : (amount < 0 ? position + amount : position);
    final hi = bipolar ? position + amount.abs() : (amount < 0 ? position : position + amount);
    return (lo.clamp(0.0, 1.0), hi.clamp(0.0, 1.0));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source,
        if (output != 0) 'output': output,
        'target': target.toJson(),
        'amount': amount,
        if (bipolar) 'bipolar': true,
        if (curve != 0) 'curve': curve,
      };

  static ModLinkDoc? fromJson(Object? j) {
    if (j is! Map || j['id'] is! num || j['source'] is! String) return null;
    final target = ModTarget.fromJson(j['target']);
    if (target == null) return null;
    double unit(Object? v) => v is num && v.isFinite ? v.toDouble().clamp(-1.0, 1.0) : 0;
    return ModLinkDoc(
      id: (j['id'] as num).toInt(),
      source: j['source'] as String,
      output: j['output'] is num ? (j['output'] as num).toInt().clamp(0, 7) : 0,
      target: target,
      amount: unit(j['amount']),
      bipolar: j['bipolar'] == true,
      curve: unit(j['curve']),
    );
  }
}

/// The engine's budgets (engine/src/modulation_links.h).
const kMaxModulators = 64, kMaxModLinks = 256, kMaxLinksPerTarget = 32;

extension ProjectModulation on ProjectDoc {
  ModulatorDoc? modulator(String? id) => modulators.where((m) => m.id == id).firstOrNull;

  List<ModLinkDoc> linksTo(ModTarget t) => [for (final l in modLinks) if (l.target == t) l];
  List<ModLinkDoc> linksFrom(String modulatorId) => [for (final l in modLinks) if (l.source == modulatorId) l];
  List<ModLinkDoc> linksOnLayer(String layerId) => [
        for (final l in modLinks)
          if (l.target.type != 'modulator' && (l.target.layerId ?? masterLayerId) == layerId) l,
      ];

  /// Modulators shown on [layerId] ([masterLayerId]: the project's own).
  List<ModulatorDoc> modulatorsOn(String layerId) =>
      [for (final m in modulators) if ((m.layerId ?? masterLayerId) == layerId) m];

  int get nextModLinkId => modLinks.fold<int>(0, (m, l) => l.id > m ? l.id : m) + 1;

  String newModulatorId() {
    var n = modulators.length + 1;
    while (modulators.any((m) => m.id == 'mod$n')) {
      n++;
    }
    return 'mod$n';
  }

  /// Whether a link from [source] to [target] would make a loop: one modulator moving another that (through others)
  /// moves it, or a modulator hearing a track's audio that moves that track, or one feeding it through buses, sends
  /// and keys. The engine refuses a project with one.
  bool modulationLoops(String source, ModTarget target) {
    if (target.type == 'modulator') {
      if (target.layerId == source) return true;
      // Does the target modulator reach the source through modulator links?
      final seen = <String>{target.layerId!};
      final stack = [target.layerId!];
      while (stack.isNotEmpty) {
        final x = stack.removeLast();
        for (final l in modLinks) {
          if (l.source != x || l.target.type != 'modulator') continue;
          if (l.target.layerId == source) return true;
          if (seen.add(l.target.layerId!)) stack.add(l.target.layerId!);
        }
      }
    }
    final trial = [...modLinks, ModLinkDoc(id: -1, source: source, target: target)];
    return _audioEdges(trial, RoutingPlan.of(this)).loops.contains(-1);
  }

  /// The routing edges audio-hearing modulators add (input track → each track its links reach), in link order, each
  /// kept only if it closes no loop with the routes already kept; [loops] holds the links left out.
  ({Set<int> loops}) _audioEdges(List<ModLinkDoc> links, RoutingPlan plan) {
    final loops = <int>{};
    for (final l in links) {
      // The audio-hearing modulators upstream of this link's source (itself included).
      final from = <ModulatorDoc>[];
      for (final m in modulators) {
        if (!m.hearsAudio || m.inputId == null) continue;
        if (m.id == l.source || _reachesModulator(m.id, l.source, links)) from.add(m);
      }
      final to = l.target.type == 'modulator' ? null : l.target.layerId;
      if (to == null) continue;
      for (final m in from) {
        final input = m.inputId!;
        if (input == to || plan.reaches(to, input)) {
          loops.add(l.id);
        } else {
          plan.addEdge(input, to);
        }
      }
    }
    return (loops: loops);
  }

  bool _reachesModulator(String from, String to, List<ModLinkDoc> links) {
    final seen = <String>{from};
    final stack = [from];
    while (stack.isNotEmpty) {
      final x = stack.removeLast();
      for (final l in links) {
        if (l.source != x || l.target.type != 'modulator') continue;
        if (l.target.layerId == to) return true;
        if (seen.add(l.target.layerId!)) stack.add(l.target.layerId!);
      }
    }
    return false;
  }

  /// The engine's "modulators" and "modulation" (docs/engine.md, Modulation), with what can't play left out: a
  /// modulator whose component isn't loaded, a link to a track that is gone or a component that isn't playing (its
  /// index renumbered as the chain the engine gets), a send the engine doesn't get, and a link that would make a loop.
  Map<String, Object> engineModulationFields(RoutingPlan plan,
      {Set<String>? playableComponents, required int? Function(String? layerId, int index) engineIndex,
      required bool Function(LayerDoc layer) instrumentPlays}) {
    if (modulators.isEmpty) return const {};
    bool plays(String id) => playableComponents == null || playableComponents.contains(id);
    final layerIds = {for (final l in layers) l.id};
    final mods = [for (final m in modulators) if (plays(m.componentId)) m];
    final ids = {for (final m in mods) m.id};
    final links = <Map<String, dynamic>>[];
    final kept = <ModLinkDoc>[];
    for (final l in modLinks) {
      if (!ids.contains(l.source) || kept.length >= kMaxModLinks) continue;
      final t = l.target;
      Map<String, dynamic>? target;
      switch (t.type) {
        case 'modulator':
          if (ids.contains(t.layerId)) target = t.toJson();
        case 'component':
          if (t.layerId == null || layerIds.contains(t.layerId)) {
            final i = engineIndex(t.layerId, t.index);
            if (i != null) target = t.toJson()..['index'] = i;
          }
        case 'instrument':
          final layer = layers.where((x) => x.id == t.layerId).firstOrNull;
          if (layer != null && instrumentPlays(layer)) target = t.toJson();
        case 'volume' || 'pan':
          if (layerIds.contains(t.layerId)) target = t.toJson();
        case 'send':
          final layer = layers.where((x) => x.id == t.layerId).firstOrNull;
          if (layer != null && t.index < layer.sends.length && plan.sendPlays(layer, t.index)) {
            var at = 0;
            for (var i = 0; i < t.index; i++) {
              if (plan.sendPlays(layer, i)) at++;
            }
            target = t.toJson()..['index'] = at;
          }
      }
      if (target == null) continue;
      kept.add(l);
      links.add({...l.toJson(), 'target': target});
    }
    final loops = _audioEdges(kept, plan).loops;
    // The engine refuses modulators hearing a track that is gone: they hear nothing instead.
    return {
      'modulators': [
        for (final m in mods)
          {
            'id': m.id,
            'name': m.name,
            'layer': ?m.layerId,
            if (m.inputId != null && layerIds.contains(m.inputId) && m.hears != 'none') 'input': m.inputId,
            if (m.hears != 'none') 'hears': m.hears,
            if (m.post) 'tap': 'post',
            'component': {'id': m.componentId, 'params': m.params, if (m.bypass) 'bypass': true},
          },
      ],
      'modulation': [for (final j in links) if (!loops.contains(j['id'])) j],
    };
  }

  /// Keeps links to a chain's components on their component after the chain of [layerId] (null: the master)
  /// changed from [before] to its current order, as `followComponentLanes` keeps lanes.
  void followComponentLinks(String? layerId, List<ComponentUseDoc> before) {
    final after = layerId == null ? masterComponents : layers.where((l) => l.id == layerId).firstOrNull?.components;
    modLinks.removeWhere((link) {
      final t = link.target;
      if (t.type != 'component' || t.layerId != layerId) return false;
      if (t.index < 0 || t.index >= before.length) return true;
      final now = after == null ? -1 : after.indexWhere((c) => identical(c, before[t.index]));
      if (now < 0) return true;
      link.target = ModTarget.component(layerId, now, t.param);
      return false;
    });
  }
}

/// A modulator seen as a device (its knobs in the device kit's controls): values come from the project's
/// [ModulatorDoc], moves go live to the engine, and its knobs can be modulated by other modulators.
class ModulatorDeviceTarget extends DeviceTarget {
  const ModulatorDeviceTarget(AppState state, this.modulatorId) : super(state, masterLayerId, -2);

  final String modulatorId;

  ModulatorDoc? get doc => state.project.modulator(modulatorId);

  @override
  bool get isInstrument => false;

  @override
  ComponentUseDoc? get use => null;

  @override
  String? get componentId => doc?.componentId;

  @override
  NativeComponentInfo? get info {
    final id = componentId;
    return id == null ? null : state.componentInfo(id);
  }

  @override
  String get label => doc?.name ?? 'Modulator';

  @override
  ValueListenable<int> get tick => state.modulationTick;

  @override
  double value(String id) => doc?.params[id] ?? param(id)?.defaultValue ?? 0;

  @override
  void setLive(String id, double v) {
    final p = param(id);
    if (p != null) v = clampToParam(p, v);
    state.setModulatorParamLive(modulatorId, id, v);
  }

  @override
  void commit() => state.commitModulation();

  @override
  void set(String id, double v) {
    setLive(id, v);
    commit();
  }

  @override
  void setAll(Map<String, double> values) {
    for (final e in values.entries) {
      setLive(e.key, e.value);
    }
    commit();
  }

  @override
  bool get bypass => doc?.bypass ?? false;

  @override
  void setBypass(bool on) => state.setModulatorBypass(modulatorId, on);
}

class _ModulationUi {
  final tick = ValueNotifier<int>(0);
  final assigning = ValueNotifier<ModSourceRef?>(null);
  final dragging = ValueNotifier<ModSourceRef?>(null);
}

final _ui = Expando<_ModulationUi>('modulation ui');

/// Project modulation edits on AppState. Every edit goes through the project, so it saves, syncs and undoes as one
/// step like any other; knob moves and amount drags go live to the engine first.
extension ModulationEdits on AppState {
  _ModulationUi get _m => _ui[this] ??= _ModulationUi();

  /// Fires when a modulator's value or a link changes (live moves included).
  ValueNotifier<int> get modulationTick => _m.tick;

  /// Assign mode: a tapped output chip; while set, every knob it can reach pulses and a tap adds or removes a link.
  ValueNotifier<ModSourceRef?> get assigningModulation => _m.assigning;

  /// The output chip being dragged onto a knob (every knob that can take it lights up), or null.
  ValueNotifier<ModSourceRef?> get draggingModulation => _m.dragging;

  void _touch() => _m.tick.value++;

  /// The modulators a project can add: the built-ins, then loaded C++ modulators.
  List<NativeComponentInfo> get modulatorComponents => [
        for (final id in ModulatorKinds.builtins) ?componentInfo(id),
        for (final c in componentCatalog.value.values)
          if (!ModulatorKinds.builtins.contains(c.id) && isModulatorInfo(c) && componentPlayable(c.id)) c,
      ];

  /// Adds a modulator of [componentId] on [layerId] (null: the project's, shown on the master). It hears that track
  /// by default (its notes, or a follower its audio). Null at the budget.
  ModulatorDoc? addModulator(String componentId, {String? layerId}) {
    if (project.modulators.length >= kMaxModulators) return null;
    final base = componentInfo(componentId)?.label ?? ModulatorKinds.label(componentId);
    final same = project.modulators.where((m) => m.componentId == componentId).length;
    final info = componentInfo(componentId);
    final takesAudio = info?.ports.any((p) => p.input && p.isAudio) ?? componentId == ModulatorKinds.follower;
    final takesNotes = info?.ports.any((p) => p.input && p.type == 'event') ?? ModulatorKinds.hears(componentId) == 'notes';
    final m = ModulatorDoc(
      id: project.newModulatorId(),
      name: same == 0 ? base : '$base ${same + 1}',
      componentId: componentId,
      layerId: layerId == masterLayerId ? null : layerId,
      inputId: layerId == masterLayerId ? null : layerId,
      hears: takesAudio ? 'audio' : (takesNotes ? 'notes' : 'none'),
    );
    editProject((p) => p.modulators.add(m));
    _touch();
    return m;
  }

  /// Removes modulator [id] with every link from it and to its knobs.
  void removeModulator(String id) {
    editProject((p) {
      p.modulators.removeWhere((m) => m.id == id);
      p.modLinks.removeWhere((l) => l.source == id || (l.target.type == 'modulator' && l.target.layerId == id));
    });
    if (assigningModulation.value?.modulatorId == id) assigningModulation.value = null;
    _touch();
  }

  void editModulator(String id, void Function(ModulatorDoc m) change) {
    final m = project.modulator(id);
    if (m == null) return;
    editProject((_) => change(m));
    _touch();
  }

  /// A knob move on a modulator: live in the engine at once, kept in the project; [commitModulation] at the end.
  void setModulatorParamLive(String id, String param, double value) {
    final m = project.modulator(id);
    if (m == null) return;
    m.params[param] = value;
    engine?.setModulatorParam(id, param, value);
    _touch();
  }

  void setModulatorBypass(String id, bool bypass) {
    engine?.setModulatorBypass(id, bypass);
    editModulator(id, (m) => m.bypass = bypass);
  }

  /// Saves the values of a gesture (one undo step).
  void commitModulation() {
    editProject((_) {});
    _touch();
  }

  /// Why a link from [src] to [target] can't be made, or null when it can.
  String? whyNoLink(ModSourceRef src, ModTarget target) {
    final p = project;
    if (p.modulator(src.modulatorId) == null) return 'That modulator is gone';
    if (p.modLinks.length >= kMaxModLinks) return 'A project holds at most $kMaxModLinks modulation links';
    if (p.linksTo(target).length >= kMaxLinksPerTarget) return 'A knob takes at most $kMaxLinksPerTarget modulations';
    if (p.modulationLoops(src.modulatorId, target)) return 'That would make a loop: the modulator would hear itself';
    return null;
  }

  /// Links [src] to [target] (one undo step); an existing link of the pair is kept and returned. Null when it can't
  /// ([whyNoLink]).
  ModLinkDoc? addModLink(ModSourceRef src, ModTarget target, {double amount = 0.25, bool? bipolar}) {
    final existing = project.modLinks
        .where((l) => l.source == src.modulatorId && l.output == src.output && l.target == target)
        .firstOrNull;
    if (existing != null) return existing;
    if (whyNoLink(src, target) != null) return null;
    final kind = project.modulator(src.modulatorId)?.componentId;
    final link = ModLinkDoc(id: project.nextModLinkId, source: src.modulatorId, output: src.output, target: target,
        amount: amount, bipolar: bipolar ?? (kind == ModulatorKinds.lfo || kind == ModulatorKinds.random));
    editProject((p) => p.modLinks.add(link));
    _touch();
    return link;
  }

  void removeModLink(int id) {
    editProject((p) => p.modLinks.removeWhere((l) => l.id == id));
    _touch();
  }

  /// Assign mode's tap: adds the link, or removes it when there is one. Returns the link made, null when one was
  /// removed or none could be made (then [whyNoLink] says why).
  ModLinkDoc? toggleModLink(ModSourceRef src, ModTarget target) {
    final existing = project.modLinks
        .where((l) => l.source == src.modulatorId && l.output == src.output && l.target == target)
        .firstOrNull;
    if (existing != null) {
      removeModLink(existing.id);
      return null;
    }
    return addModLink(src, target);
  }

  ModLinkDoc? modLink(int id) => project.modLinks.where((l) => l.id == id).firstOrNull;

  /// An amount drag: live in the engine, kept in the project; [commitModulation] when it ends.
  void setModLinkAmountLive(int id, double amount) {
    final l = modLink(id);
    if (l == null) return;
    l.amount = amount.clamp(-1.0, 1.0);
    engine?.setModulationAmount(id, l.amount);
    _touch();
  }

  void editModLink(int id, void Function(ModLinkDoc l) change) {
    final l = modLink(id);
    if (l == null) return;
    editProject((_) => change(l));
    _touch();
  }

  /// A modulator output's name ("LFO 1", "Macros · M3").
  String modSourceLabel(ModSourceRef src) {
    final m = project.modulator(src.modulatorId);
    if (m == null) return 'Missing';
    final outs = modulatorOutputNames(m);
    return outs.length <= 1 ? m.name : '${m.name} · ${src.output < outs.length ? outs[src.output] : src.output + 1}';
  }

  /// Its outputs' names: the descriptor's modulation ports, else the built-in's.
  List<String> modulatorOutputNames(ModulatorDoc m) {
    final info = componentInfo(m.componentId);
    final ports = [for (final p in info?.ports ?? const <ComponentPortInfo>[]) if (p.type == 'modulation' && !p.input) p.id];
    if (ports.isEmpty) return ModulatorKinds.outputs(m.componentId);
    if (m.componentId == ModulatorKinds.macros || m.componentId == ModulatorKinds.midi) {
      return ModulatorKinds.outputs(m.componentId).take(ports.length).toList();
    }
    return [for (final p in ports) p.length <= 1 ? p.toUpperCase() : p[0].toUpperCase() + p.substring(1)];
  }

  /// What a link moves, for chips: "Bass · Filter cutoff", "Bass · Volume", "LFO 2 · Rate".
  String modTargetLabel(ModTarget t) {
    final layer = t.layerId == null ? null : layerById(t.layerId);
    final where = t.type == 'modulator'
        ? project.modulator(t.layerId)?.name ?? 'Missing'
        : t.layerId == null ? 'Master' : layer?.name ?? 'Missing';
    String paramLabel(String? componentId) {
      final p = componentId == null ? null : componentInfo(componentId)?.param(t.param);
      return p?.label ?? t.param;
    }
    final what = switch (t.type) {
      'volume' => 'Volume',
      'pan' => 'Pan',
      'send' => 'Send ${t.index + 1}${layer != null && t.index < layer.sends.length ? ' (${layerById(layer.sends[t.index].to)?.name ?? '?'})' : ''}',
      'instrument' => paramLabel(layer?.instrument?.id),
      'modulator' => paramLabel(project.modulator(t.layerId)?.componentId),
      _ => () {
          final chain = t.layerId == null ? project.masterComponents : layer?.components ?? const <ComponentUseDoc>[];
          final c = t.index < chain.length ? chain[t.index] : null;
          return '${c == null ? '?' : componentLabel(c.id)} ${paramLabel(c?.id)}';
        }(),
    };
    return '$where · $what';
  }

  /// The live offset (normalized travel) the engine last applied to [link]'s target, or null.
  double? liveModOffset(ModLinkDoc link) => engine?.modulationOffset(link.id);
}
