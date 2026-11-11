// Routing in the project model: sends to bus folders, sidechain keys, and which of them the engine is given
// (RoutingPlan: none that would make a loop or that names a layer that is gone).
import 'project.dart';

/// A copy of a track's sound into a bus folder's input (docs/engine.md, "Sends and buses"): [level] is linear gain,
/// [pre] taps before the fader (after the track's effects), [mute] silences just this send.
class SendDoc {
  SendDoc(this.to, {this.level = 0.5, this.pre = false, this.mute = false});

  /// Sends per track (the engine's `kMaxSends`).
  static const maxSends = 8;

  /// A new send's level: about −6 dB, a useful amount of reverb or delay without drowning the track.
  static const defaultLevel = 0.5;

  String to;
  double level;
  bool pre, mute;

  Map<String, dynamic> toJson() => {'to': to, 'level': level, if (pre) 'pre': true, if (mute) 'mute': true};

  static SendDoc? fromJson(Object? j) {
    if (j is! Map || j['to'] is! String || (j['to'] as String).isEmpty) return null;
    final level = j['level'];
    return SendDoc(j['to'] as String,
        level: level is num && level.isFinite ? level.toDouble().clamp(0.0, kMaxMixGain) : defaultLevel,
        pre: j['pre'] == true,
        mute: j['mute'] == true);
  }

  static List<SendDoc> listFromJson(Object? raw) => [
        if (raw is List)
          for (final entry in raw.take(maxSends)) ?SendDoc.fromJson(entry),
      ];
}

/// Where a component's sidechain input listens: another layer's sound before its fader ([pre], after its effects)
/// or after it, times [level]. The notes that layer plays reach the component too (the ducker's Notes mode).
class ComponentKeyDoc {
  ComponentKeyDoc(this.layer, {this.pre = true, this.level = 1});
  String layer;
  bool pre;
  double level;

  Map<String, dynamic> toJson() => {'layer': layer, 'tap': pre ? 'pre' : 'post', if (level != 1) 'level': level};

  static ComponentKeyDoc? fromJson(Object? j) {
    if (j is! Map || j['layer'] is! String || (j['layer'] as String).isEmpty) return null;
    final level = j['level'];
    return ComponentKeyDoc(j['layer'] as String,
        pre: j['tap'] != 'post', level: level is num && level.isFinite ? level.toDouble().clamp(0.0, kMaxMixGain) : 1);
  }
}

/// The built-ins with a sidechain input (their descriptors declare a "sidechain" port; this list is for before the
/// descriptors arrive).
const keyedBuiltins = {'org.caw.ducker', 'org.caw.compressor', 'org.caw.gate', 'org.caw.ringmod' /* fx-creative */};

/// Which sends and keys of a project play. The engine refuses a whole project whose routing makes a loop (a bus
/// sending into a bus that feeds it, a ducker keyed by its own folder), so the app gives it only routes that keep
/// the graph loop-free: each layer's route to its parent bus first, then sends and keys in project order, each kept
/// only if it closes no loop. A send to a missing or bus-less folder, or a key from a missing or bus-less layer, is
/// left out the same way; the project keeps them, so undo or a re-enabled bus brings them back.
class RoutingPlan {
  RoutingPlan._(this._p);
  final ProjectDoc _p;
  final Map<String, Set<String>> _edges = {};
  final Set<(String, int)> _sends = {};
  final Set<ComponentUseDoc> _keys = Set.identity();

  factory RoutingPlan.of(ProjectDoc p) {
    final plan = RoutingPlan._(p);
    for (final l in p.layers) {
      if (!plan._plays(l)) continue;
      final to = routeTarget(p, l);
      if (to != null) plan._edge(l.id, to);
    }
    for (final l in p.layers) {
      for (var i = 0; i < l.sends.length && i < SendDoc.maxSends; i++) {
        final s = l.sends[i];
        if (plan.canSend(l, s.to)) {
          plan._edge(l.id, s.to);
          plan._sends.add((l.id, i));
        }
      }
      for (final c in l.components) {
        final k = c.key;
        if (k != null && plan.canKey(l, k.layer)) {
          plan._edge(k.layer, l.id);
          plan._keys.add(c);
        }
      }
    }
    return plan;
  }

  /// A layer carries sound unless it is a folder without a bus (only organisation).
  bool _plays(LayerDoc l) => !(l.isFolder && !l.busEnabled);

  LayerDoc? _layer(String id) => _p.layers.where((l) => l.id == id).firstOrNull;

  void _edge(String from, String to) => (_edges[from] ??= {}).add(to);

  /// Adds an edge other routes must not close a loop with (project modulation: a modulator hearing [from]'s audio
  /// and moving [to], modulation.dart).
  void addEdge(String from, String to) => _edge(from, to);

  /// Whether [to] is reached from [from] along the routes kept so far.
  bool reaches(String from, String to) {
    final seen = <String>{from};
    final stack = [from];
    while (stack.isNotEmpty) {
      final x = stack.removeLast();
      if (x == to) return true;
      for (final y in _edges[x] ?? const <String>{}) {
        if (seen.add(y)) stack.add(y);
      }
    }
    return false;
  }

  /// Whether [layer] can send to [busId] now: a bus folder, not itself, and no loop.
  bool canSend(LayerDoc layer, String busId) {
    final bus = _layer(busId);
    if (bus == null || !bus.isFolder || !bus.busEnabled || bus.id == layer.id || !_plays(layer)) return false;
    return !reaches(busId, layer.id);
  }

  /// Whether a component on [layer] can be keyed by [sourceId] now: another layer that carries sound, and no loop
  /// (a key from the folder the layer is in would hear itself).
  bool canKey(LayerDoc layer, String sourceId) {
    final source = _layer(sourceId);
    if (source == null || source.id == layer.id || !_plays(source)) return false;
    return !reaches(layer.id, sourceId);
  }

  /// [layer]'s sends the engine gets.
  List<SendDoc> sendsOf(LayerDoc layer) =>
      [for (var i = 0; i < layer.sends.length; i++) if (_sends.contains((layer.id, i))) layer.sends[i]];

  /// Whether [use]'s key reaches the engine.
  bool keyPlays(LayerDoc layer, ComponentUseDoc use) => _keys.contains(use);

  /// Whether [layer]'s send [index] plays (false: it would make a loop, or its bus is gone or has no bus).
  bool sendPlays(LayerDoc layer, int index) => _sends.contains((layer.id, index));
}

/// Where [layer]'s own sound goes: the nearest folder above it with a bus, or null for the master (folders without
/// a bus only organise). The engine's `routeTarget` does the same.
String? routeTarget(ProjectDoc p, LayerDoc layer) {
  var parent = layer.parentId;
  for (var depth = 0; parent != null && depth <= p.layers.length; depth++) {
    final found = p.layers.where((l) => l.id == parent).firstOrNull;
    if (found == null) return null;
    if (found.isFolder && found.busEnabled) return found.id;
    parent = found.parentId;
  }
  return null;
}
