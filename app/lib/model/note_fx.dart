// Per-note FX edits on AppState (#127): moving a track's effect to run once per note and back, the voice budget,
// and per-note knobs and bypass (they reach every slot).
import 'app_state.dart';
import 'arrange_fx.dart';
import 'collab/project_ops.dart';
import 'mixer_fx.dart';
import 'project.dart';

/// The engine's component-index bit that names a per-note component (CAW_NOTE_COMPONENT in caw.h).
const int noteComponentFlag = 0x40000000;

extension NoteFxEdits on AppState {
  /// Why [componentId] can't run per note on [layer], or null when it can: the instrument needs a voice bus and the
  /// effect must say it can run per note (its descriptor's domains). Unknown descriptors (still loading) say so.
  String? perNoteBlocker(LayerDoc layer, String componentId) {
    if (layer.isFolder || isMasterLayer(layer)) return 'Only a track with an instrument runs effects per note';
    final instrument = layer.instrument;
    if (instrument == null) return 'Add an instrument first';
    final inst = componentInfo(instrument.id);
    if (inst == null) return 'Waiting for the instrument to load';
    if (!inst.runsPerNote) return '${inst.label} has no per-note output';
    final fx = componentInfo(componentId);
    if (fx == null) return 'Waiting for the effect to load';
    if (!fx.runsPerNote) return '${fx.label} only runs on the whole track';
    return null;
  }

  /// Moves track effect [index] to the end of the per-note effects (its knobs and bypass go with it).
  bool runPerNote(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.components.length) return false;
    if (perNoteBlocker(layer, layer.components[index].id) != null) return false;
    apply(ProjectMove(layer.components[index].uid, layer.id, OpList.noteComponents, kAtEnd));
    return true;
  }

  /// Moves per-note effect [index] back to the front of the track's effects (it then runs on the whole track).
  void runOnTrack(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.noteComponents.length) return;
    // Its per-note lanes go, as a moved effect's lanes do.
    apply(ProjectMove(layer.noteComponents[index].uid, layer.id, OpList.components, 0));
  }

  void removeNoteEffect(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.noteComponents.length) return;
    apply(ProjectDelete(layer.noteComponents[index].uid));
  }

  /// How many notes get their own slot (1..16).
  void setNoteVoices(LayerDoc layer, int voices) {
    final v = voices.clamp(1, LayerDoc.maxNoteVoices);
    if (v == layer.noteVoices) return;
    editLayer(layer, (l) => l.noteVoices = v);
  }

  /// Where per-note effect [index] sits in the engine (unplayable ones are left out), or null.
  int? engineNoteIndex(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.noteComponents.length || !componentPlayable(layer.noteComponents[index].id)) return null;
    return layer.noteComponents.take(index).where((c) => componentPlayable(c.id)).length;
  }

  void setNoteBypass(LayerDoc layer, int index, bool bypass) {
    if (index < 0 || index >= layer.noteComponents.length) return;
    apply(ProjectSet(layer.noteComponents[index].uid, OpField.bypass, bypass));
  }

  /// A knob move on per-note effect [index]: every slot at once, kept in the project ([commitNativeParams] saves).
  void setNoteParamLive(LayerDoc layer, int index, String param, double value) {
    if (index < 0 || index >= layer.noteComponents.length) return;
    apply(ProjectSet(layer.noteComponents[index].uid, OpField.param(param), value));
  }
}
