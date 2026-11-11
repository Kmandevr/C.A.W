// The mixer's FX edits: the master's effect chain seen as a track (so the FX stack and device UIs open it), and
// effects dragged from one strip to another (copied, or moved).
import 'project.dart';
import 'app_state.dart';
import 'arrange_fx.dart';

/// The id the master's stand-in track goes by ([masterLayerOf]); no real track can have it (ids are made by
/// `newId`, never with a NUL).
const masterLayerId = '\u0000master';

bool isMasterLayer(LayerDoc? layer) => layer?.id == masterLayerId;

final _masterLayers = Expando<LayerDoc>('master layer');

/// The master as a track for the FX stack and the device editors: its `components` list *is*
/// [ProjectDoc.masterComponents], so every edit lands on the master chain. Not in [ProjectDoc.layers]; the same
/// object comes back while the project keeps the same list.
LayerDoc masterLayerOf(ProjectDoc p) {
  final known = _masterLayers[p];
  if (known != null && identical(known.components, p.masterComponents)) return known;
  return _masterLayers[p] = LayerDoc(id: masterLayerId, name: 'Master', color: 0, components: p.masterComponents,
      ownColor: true);
}

/// What the engine calls a chain's layer: null for the master.
String? engineLayerId(LayerDoc layer) => isMasterLayer(layer) ? null : layer.id;

/// A C++ effect being dragged from a mixer strip: slot [index] of track [layerId] ([masterLayerId] for the master).
class FxSlotDrag {
  const FxSlotDrag(this.layerId, this.index);
  final String layerId;
  final int index;
}

extension MixerFx on AppState {
  /// The track [id] names, or the master's stand-in for [masterLayerId].
  LayerDoc? chainLayer(String id) =>
      id == masterLayerId ? masterLayerOf(project) : project.layers.where((l) => l.id == id).firstOrNull;

  /// Whether [drag] can land on [to]: a different chain that takes effects (a folder only with its bus on; the
  /// master only C++ effects, as the engine's master chain holds only those).
  bool canDropFx(FxSlotDrag drag, LayerDoc to) {
    final from = chainLayer(drag.layerId);
    if (from == null || identical(from, to) || from.id == to.id) return false;
    if (to.isFolder && !to.busEnabled) return false;
    return drag.index >= 0 && drag.index < from.components.length;
  }

  /// Puts the effect [drag] names at the end of [to]'s chain, as REAPER's FX drag between strips: a copy with the
  /// same values, or with [move] the effect itself, leaving the source. One undo step; false when it can't go there.
  bool dropFx(FxSlotDrag drag, LayerDoc to, {bool move = false}) {
    if (!canDropFx(drag, to)) return false;
    final from = chainLayer(drag.layerId)!;
    final use = from.components[drag.index];
    final copy = move ? use : ComponentUseDoc.fromJson(use.toJson())!;
    final before = List.of(from.components);
    editProject((p) {
      if (move) {
        from.components.removeAt(drag.index);
        // Its lanes go with it (lanes address an effect by chain index; the master's lanes have no layer).
        for (final lane in p.automation) {
          if (lane.targetType == 'component' && lane.layerId == engineLayerId(from) && lane.component == drag.index) {
            lane.layerId = engineLayerId(to);
            lane.component = to.components.length;
          }
        }
      }
      // At the end of [to]'s chain, so its own lanes keep their indexes.
      to.components.add(copy);
      if (move) followComponentLanes(p, engineLayerId(from), before);
    });
    return true;
  }
}
