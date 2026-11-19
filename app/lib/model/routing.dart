// Routing in the project model: output overrides, sends to buses and tracks (feedback ones too), sidechain keys, and
// which of them the engine is given (RoutingPlan: none that would make an unbroken loop or names a layer that is gone).
import 'project.dart';

/// A copy of a track's sound into another one's input (docs/app.md, "Routing"): a bus folder's, or a track's, summed
/// before its effects (the track keeps its instrument). [level] is linear gain, [pre] taps before the fader (after
/// the track's effects), [mute] silences just this send. [feedback] lets the send close a loop (the engine delays it
/// one 64-frame chunk), the only route that may; [limiter] keeps such a loop from running away (only with feedback).
class SendDoc {
  SendDoc(this.to, {this.level = 0.5, this.pre = false, this.mute = false, this.feedback = false, this.limiter = true});

  /// Sends per track (the engine's `kMaxSends`).
  static const maxSends = 8;

  /// A new send's level: about −6 dB, a useful amount of reverb or delay without drowning the track.
  static const defaultLevel = 0.5;

  String to;
  double level;
  bool pre, mute, feedback, limiter;

  /// Each flag is written only when it isn't its default, so a project without them saves as it always did.
  Map<String, dynamic> toJson() => {
        'to': to, 'level': level, if (pre) 'pre': true, if (mute) 'mute': true,
        if (feedback) 'feedback': true, if (!limiter) 'limiter': false,
      };

  static SendDoc? fromJson(Object? j) {
    if (j is! Map || j['to'] is! String || (j['to'] as String).isEmpty) return null;
    final level = j['level'];
    return SendDoc(j['to'] as String,
        level: level is num && level.isFinite ? level.toDouble().clamp(0.0, kMaxMixGain) : defaultLevel,
        pre: j['pre'] == true,
        mute: j['mute'] == true,
        feedback: j['feedback'] == true,
        limiter: j['limiter'] != false);
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
const keyedBuiltins = {'org.caw.ducker', 'org.caw.compressor', 'org.caw.gate', 'org.caw.duck', 'org.caw.ringmod' /* fx-creative */};

/// Which outputs, sends and keys of a project play. The engine refuses a whole project whose routing makes a loop (a
/// bus sending into a bus that feeds it, a ducker keyed by its own folder), so the app gives it only routes that
/// keep the graph loop-free, in this order:
/// 1. every layer's own route: its [LayerDoc.output] bus when it names an enabled bus folder other than itself, or
///    the master for [LayerDoc.toMaster], else its parent folder's bus ([routeTarget]), else the master. The parent
///    routes are laid first; then each output override, in track order, replaces its layer's parent route only if
///    it closes no loop (else the parent route stays, which never closes one; the master never does);
/// 2. then sends and keys in track order, each kept only if it closes no loop. A feedback send ([SendDoc.feedback])
///    is kept whatever it closes and is no edge for the others' checks (the engine breaks the loop with a delay).
/// A route to a missing or bus-less folder, a send to itself, or a key from a missing or bus-less layer is left out
/// the same way; the project keeps them, so undo or a re-enabled bus brings them back.
class RoutingPlan {
  RoutingPlan._(this._p);
  final ProjectDoc _p;
  final Map<String, Set<String>> _edges = {};
  final Map<String, String> _outputs = {};
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
      final out = l.output;
      if (out == null || !plan.canOutput(l, out)) continue;  // no bus, or it would loop: the parent route stays
      final parent = routeTarget(p, l);
      if (parent != null) plan._edges[l.id]?.remove(parent);
      if (out != LayerDoc.toMaster) plan._edge(l.id, out);
      plan._outputs[l.id] = out;
    }
    for (final l in p.layers) {
      for (var i = 0; i < l.sends.length && i < SendDoc.maxSends; i++) {
        final s = l.sends[i];
        if (s.feedback ? plan.canSendFeedback(l, s.to) : plan.canSend(l, s.to)) {
          if (!s.feedback) plan._edge(l.id, s.to);
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

  bool _isBus(String id) => switch (_layer(id)) { final l? => l.isFolder && l.busEnabled, null => false };

  LayerDoc? _layer(String id) => _p.layers.where((l) => l.id == id).firstOrNull;

  void _edge(String from, String to) => (_edges[from] ??= {}).add(to);

  /// Adds an edge other routes must not close a loop with (project modulation: a modulator hearing [from]'s audio
  /// and moving [to], modulation.dart).
  void addEdge(String from, String to) => _edge(from, to);

  /// Whether [to] is reached from [from] along the routes kept so far (feedback sends are no edges).
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

  /// The bus [layer]'s own sound goes to: its kept [LayerDoc.output], else its parent folder's bus, else null (the
  /// master, [LayerDoc.toMaster] included).
  String? outputOf(LayerDoc layer) => switch (_outputs[layer.id]) {
        LayerDoc.toMaster => null,
        final String bus => bus,
        null => routeTarget(_p, layer),
      };

  /// Whether [layer]'s [LayerDoc.output] override plays (false: none, or it would loop or names no bus).
  bool outputPlays(LayerDoc layer) => _outputs.containsKey(layer.id);

  /// Whether [layer] can output to bus [busId] now: an enabled bus folder, not itself, and no loop; or
  /// [LayerDoc.toMaster], which never loops.
  bool canOutput(LayerDoc layer, String busId) =>
      _plays(layer) &&
      (busId == LayerDoc.toMaster || (busId != layer.id && _isBus(busId) && !reaches(busId, layer.id)));

  /// Whether [to] can take a send from [layer] at all: a bus folder or a track (anything that carries sound), not
  /// [layer] itself. Loops aside: [canSend] checks those.
  bool _sendable(LayerDoc layer, String to) {
    final target = _layer(to);
    return target != null && target.id != layer.id && _plays(target) && _plays(layer);
  }

  /// Whether [layer] can send to [to] now: a bus folder or a track, not itself, and no loop.
  bool canSend(LayerDoc layer, String to) => _sendable(layer, to) && !reaches(to, layer.id);

  /// Whether [layer] can send to [to] as a feedback send: what [canSend] allows, and loops too.
  bool canSendFeedback(LayerDoc layer, String to) => _sendable(layer, to);

  /// Whether a component on [layer] can be keyed by [sourceId] now: another layer that carries sound (a track a send
  /// feeds too), and no loop (a key from the folder the layer is in would hear itself). Keys never close a loop.
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

  /// Whether [layer]'s send [index] plays (false: it would make a loop, or its target is gone or has no bus).
  bool sendPlays(LayerDoc layer, int index) => _sends.contains((layer.id, index));
}

/// Where [layer]'s sound goes by its place in the folders: the nearest folder above it with a bus, or null for the
/// master (folders without a bus only organise). The engine's `routeTarget` does the same; an output override
/// ([LayerDoc.output], [RoutingPlan.outputOf]) comes before it.
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
