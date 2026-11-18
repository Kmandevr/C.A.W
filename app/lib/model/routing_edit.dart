// Routing edits on AppState: sends to buses and tracks (add, live level, pre/post, mute, feedback, limiter, remove),
// "New reverb bus" in one tap, a track's output, and a device's sidechain key, each one undo step and loop-free
// unless a feedback send breaks the loop (RoutingPlan).
import 'app_state.dart';
import 'arrange_fx.dart';
import 'project.dart';
import 'routing.dart';

/// What a one-tap new bus starts with.
enum FxBusKind {
  reverb('Reverb', 'org.caw.reverb.pro'),
  delay('Delay', 'org.caw.delay.pro');

  const FxBusKind(this.label, this.componentId);
  final String label, componentId;
}

/// A place [RoutingEdit.sendChoices] offers a send to: a bus folder or a track, and whether only a feedback send
/// can go there (a plain one would close a loop).
typedef SendTarget = ({LayerDoc layer, bool feedbackOnly});

/// A place [RoutingEdit.outputTargets] offers a layer's output: [id] for [RoutingEdit.setOutput], and the bus, or
/// null for the master ([LayerDoc.toMaster], which the UI labels "Master").
typedef OutputTarget = ({String id, LayerDoc? bus});

extension RoutingEdit on AppState {
  RoutingPlan get routing => RoutingPlan.of(project);

  LayerDoc? layerById(String? id) => id == null ? null : project.layers.where((l) => l.id == id).firstOrNull;

  /// Every bus folder in the project (folders with their bus on), in track order.
  List<LayerDoc> get buses => [for (final l in project.layers) if (l.isFolder && l.busEnabled) l];

  /// The buses [layer] can send to now (no loop, not one it already sends to). Sends into tracks, and feedback
  /// sends, are in [sendChoices].
  List<LayerDoc> sendTargets(LayerDoc layer) {
    final plan = routing;
    return [
      for (final b in buses)
        if (plan.canSend(layer, b.id) && !layer.sends.any((s) => s.to == b.id)) b,
    ];
  }

  /// Every layer [layer] can send to now, in track order: bus folders and tracks it doesn't already send to, each
  /// marked [SendTarget.feedbackOnly] when a plain send would close a loop (only a feedback send may go there).
  List<SendTarget> sendChoices(LayerDoc layer) {
    final plan = routing;
    return [
      for (final l in project.layers)
        if (!layer.sends.any((s) => s.to == l.id) && plan.canSendFeedback(layer, l.id))
          (layer: l, feedbackOnly: !plan.canSend(layer, l.id)),
    ];
  }

  /// Where [layer]'s sound goes: its output override when it plays, else its nearest bus folder, or null for the
  /// master.
  LayerDoc? outputOf(LayerDoc layer) => layerById(routing.outputOf(layer));

  /// Where [layer] can output to now without a loop: the master first ([LayerDoc.toMaster]) when its default route
  /// isn't already the master (it sits in a bus folder), then the buses (not itself, nor one fed by it) in track
  /// order. Null in [setOutput] is the default: its parent folder's bus, else the master.
  List<OutputTarget> outputTargets(LayerDoc layer) {
    final plan = routing;
    return [
      if (plan.canOutput(layer, LayerDoc.toMaster) && routeTarget(project, layer) != null)
        (id: LayerDoc.toMaster, bus: null),
      for (final b in buses) if (plan.canOutput(layer, b.id)) (id: b.id, bus: b),
    ];
  }

  /// Sends [layer]'s own sound to bus [busId], or the master for [LayerDoc.toMaster], instead of its parent folder's
  /// bus or the master (null: back to that default), one undo step; false (nothing changed) when it can't output
  /// there ([RoutingPlan.canOutput]).
  bool setOutput(LayerDoc layer, String? busId) {
    if (busId == layer.output) return true;
    if (busId != null && !routing.canOutput(layer, busId)) return false;
    editLayer(layer, (l) => l.output = busId);
    return true;
  }

  /// The layers [layer] could take a key from: every other layer with sound whose key wouldn't loop.
  List<LayerDoc> keySources(LayerDoc layer) {
    final plan = routing;
    return [for (final l in project.layers) if (plan.canKey(layer, l.id)) l];
  }

  /// Whether component [componentId] has a sidechain input (its descriptor's "sidechain" audio input).
  bool hasSidechain(String componentId) {
    final info = componentInfo(componentId);
    if (info == null) return keyedBuiltins.contains(componentId);
    return info.ports.any((p) => p.input && p.isAudio && p.id == 'sidechain');
  }

  /// Adds a send from [layer] to [to], a bus folder or a track (at [level]), one undo step; a [feedback] send may
  /// close a loop. Null when it can't (a plain send closing a loop, the limit, already there, itself).
  SendDoc? addSend(LayerDoc layer, String to, {double level = SendDoc.defaultLevel, bool feedback = false}) {
    if (layer.sends.length >= SendDoc.maxSends || layer.sends.any((s) => s.to == to)) return null;
    final plan = routing;
    if (!(feedback ? plan.canSendFeedback(layer, to) : plan.canSend(layer, to))) return null;
    final send = SendDoc(to, level: level, feedback: feedback);
    editLayer(layer, (l) => l.sends.add(send));
    return send;
  }

  /// Makes [layer]'s send [index] a feedback send or a plain one, one undo step (a project sync: the engine has no
  /// live setter for it). False (nothing changed) when a plain send would close a loop.
  bool setSendFeedback(LayerDoc layer, int index, bool feedback) {
    if (index < 0 || index >= layer.sends.length) return false;
    final s = layer.sends[index];
    if (s.feedback == feedback) return true;
    if (!feedback) {
      // Checked with the send as it is now: a feedback send is no edge, so this asks whether a plain one would loop.
      if (!routing.canSend(layer, s.to)) return false;
    }
    editLayer(layer, (_) => s.feedback = feedback);
    return true;
  }

  /// Turns [layer]'s send [index]'s loop limiter on or off (it acts only on a feedback send), one undo step.
  void setSendLimiter(LayerDoc layer, int index, bool limiter) {
    if (index < 0 || index >= layer.sends.length || layer.sends[index].limiter == limiter) return;
    editLayer(layer, (_) => layer.sends[index].limiter = limiter);
  }

  /// A new bus folder at the end of the track list, named for [kind] ("Reverb", "Reverb 2"...), running that effect
  /// fully wet, and a send to it from [layer] (when given): one tap, one undo step.
  LayerDoc newFxBus(FxBusKind kind, {LayerDoc? from}) {
    final p = project;
    final taken = {for (final l in p.layers) l.name};
    var name = '${kind.label} bus';
    for (var n = 2; taken.contains(name); n++) {
      name = '${kind.label} bus $n';
    }
    final bus = LayerDoc(id: newId('l'), name: name, color: p.layers.length % LayerDoc.trackColors, isFolder: true,
        volume: 1, components: [ComponentUseDoc(kind.componentId, {'mix': 1.0})]);
    editProject((p) {
      p.layers.add(bus);
      if (from != null && from.sends.length < SendDoc.maxSends && !(from.isFolder && !from.busEnabled)) {
        from.sends.add(SendDoc(bus.id));
      }
    });
    return bus;
  }

  /// The engine's index of [layer]'s send [index] (sends it isn't given are skipped), or null.
  int? engineSendIndex(LayerDoc layer, int index) {
    final plan = routing;
    if (!plan.sendPlays(layer, index)) return null;
    var n = 0;
    for (var i = 0; i < index; i++) {
      if (plan.sendPlays(layer, i)) n++;
    }
    return n;
  }

  void _pushSend(LayerDoc layer, int index) {
    final s = layer.sends[index];
    final e = engineSendIndex(layer, index);
    if (e != null) engine?.setSend(layer.id, e, s.level, pre: s.pre, mute: s.mute);
  }

  /// A send knob's move: live in the engine, kept in the project; [commitSend] when the gesture ends.
  void setSendLevelLive(LayerDoc layer, int index, double level) {
    if (index < 0 || index >= layer.sends.length) return;
    layer.sends[index].level = level.isFinite ? level.clamp(0.0, kMaxMixGain).toDouble() : 0;
    _pushSend(layer, index);
    layerValueTick(layer.id).value++;
  }

  void commitSend(LayerDoc layer) => editLayer(layer, (_) {});

  /// Pre or post fader, and mute: live and saved.
  void setSendFlags(LayerDoc layer, int index, {bool? pre, bool? mute}) {
    if (index < 0 || index >= layer.sends.length) return;
    final s = layer.sends[index];
    if (pre != null) s.pre = pre;
    if (mute != null) s.mute = mute;
    _pushSend(layer, index);
    editLayer(layer, (_) {});
  }

  void removeSend(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.sends.length) return;
    editLayer(layer, (l) => l.sends.removeAt(index));
  }

  /// Keys component [slot] of [layer] from [sourceId] (null: no key), [pre] or post fader.
  bool setComponentKey(LayerDoc layer, int slot, String? sourceId, {bool pre = true}) {
    if (slot < 0 || slot >= layer.components.length) return false;
    if (sourceId != null && !routing.canKey(layer, sourceId)) return false;
    final use = layer.components[slot];
    // A compressor or gate listens to the key once it has one (Sidechain: External), and back to itself without.
    if (use.id == 'org.caw.compressor' || use.id == 'org.caw.gate') {
      setNativeParamLive(layer, slot, 'sidechain', sourceId == null ? 0 : 1);
    }
    // A ducker on Tempo (it needs no input) starts following the key's audio when given one.
    if (use.id == 'org.caw.ducker' && sourceId != null && (use.params['mode'] ?? 2) == 2) {
      setNativeParamLive(layer, slot, 'mode', 0);
    }
    // fx-creative: a ring mod takes the key as its carrier when given one, and goes back to a sine without.
    if (use.id == 'org.caw.ringmod') {
      final keyed = (use.params['source'] ?? 0).round() == 5;
      if (sourceId != null && !keyed) setNativeParamLive(layer, slot, 'source', 5);
      if (sourceId == null && keyed) setNativeParamLive(layer, slot, 'source', 0);
    }
    editLayer(layer, (l) => use.key = sourceId == null ? null : ComponentKeyDoc(sourceId, pre: pre));
    return true;
  }
}
