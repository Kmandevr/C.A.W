// Flock (org.caw.flock, docs/engine.md "Flock"): the sample its grains read, kept as the instrument entry's state ({"path": ...}), and the built-in tones it plays without one.
import 'dart:convert';

import 'app_state.dart';
import 'project.dart';

const flockComponentId = 'org.caw.flock';

/// The built-in tones in `builtin` order (engine/src/builtin_flock.cpp).
const flockTones = ['Strings', 'Glass', 'Breath', 'Choir'];

/// The engine's limit on the path (bytes of UTF-8).
const flockMaxPath = 4096;

/// The sample a Flock entry's state names, or null (none, or a state the engine would refuse).
String? flockSampleOf(ComponentUseDoc use) {
  if (use.id != flockComponentId) return null;
  final s = use.state;
  if (s == null || s.isEmpty || s.length > 32768) return null;
  try {
    final j = jsonDecode(utf8.decode(base64Decode(s)));
    final p = j is Map ? j['path'] : null;
    return p is String && p.isNotEmpty && utf8.encode(p).length <= flockMaxPath ? p : null;
  } catch (_) {
    return null;
  }
}

/// The state naming [path] (null: none), base64 of the engine's JSON.
String flockStateFor(String? path) =>
    base64Encode(utf8.encode(jsonEncode(path == null || path.isEmpty ? const <String, Object>{} : {'path': path})));

extension FlockEdit on AppState {
  /// The sample [layer]'s Flock reads (null: a built-in tone, or the instrument isn't Flock).
  String? flockSample(LayerDoc layer) {
    final use = layer.instrument;
    return use == null ? null : flockSampleOf(use);
  }

  /// Makes [path] (null: none, so the built-in tone plays) the sample of [layer]'s Flock, and with [tone] picks the
  /// built-in tone too: one undo step; the project update loads it in the engine (`flock::applyProjectState`). False
  /// when the instrument isn't Flock or the path is too long for the engine.
  bool setFlockSample(LayerDoc layer, String? path, {int? tone}) {
    final use = layer.instrument;
    if (use == null || use.id != flockComponentId) return false;
    if (path != null && utf8.encode(path).length > flockMaxPath) return false;
    endUndoStep();
    editLayer(layer, (_) {
      use.state = flockStateFor(path);
      if (tone != null) use.params['builtin'] = tone.clamp(0, flockTones.length - 1).toDouble();
      use.stateVersion = 1;
    });
    endUndoStep();
    layerValueTick(layer.id).value++;
    return true;
  }
}
