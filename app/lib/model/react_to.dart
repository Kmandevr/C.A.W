// A knob's "React to…" (device shell): a project modulator keyed from another track (its loudness or its notes) linked to the knob, as one undo step.
import 'app_state.dart';
import 'device_target.dart';
import 'mixer_fx.dart' show masterLayerId;
import 'modulation.dart';
import 'project.dart';
import 'routing_edit.dart' show RoutingEdit;

/// What a knob reacts to on the track it hears: its loudness (an envelope follower on the track's audio) or its
/// notes (an envelope the track's notes trigger).
enum ReactKind {
  loudness('Loudness', ModulatorKinds.follower, 'audio'),
  notes('Notes', ModulatorKinds.envelope, 'notes');

  const ReactKind(this.label, this.componentId, this.hears);
  final String label, componentId, hears;
}

extension ReactTo on AppState {
  /// The tracks a knob can react to for [kind]: every track and bus with a bus (notes: tracks with notes, no folder).
  List<LayerDoc> reactSources(ReactKind kind) => [
        for (final l in project.layers)
          if (kind == ReactKind.notes ? !l.isFolder : (!l.isFolder || l.busEnabled)) l,
      ];

  /// The project modulator that already does this (the same kind hearing [sourceLayerId] the same way, shown on the
  /// device's track), so a second knob reacting to it shares it.
  ModulatorDoc? reactModulator(DeviceTarget t, String sourceLayerId, ReactKind kind) {
    final shownOn = t.layerId == masterLayerId ? null : t.layerId;
    return project.modulators.where((m) => m.componentId == kind.componentId && m.inputId == sourceLayerId &&
        m.hears == kind.hears && m.layerId == shownOn && !m.bypass).firstOrNull;
  }

  /// Makes [t]'s knob [paramId] react to track [sourceLayerId]: links the modulator that does it, creating it when
  /// there is none, as one undo step. Returns the link, or the reason it can't be made (a loop: a knob can't react
  /// to the loudness of a track it changes; a full project).
  ({ModLinkDoc? link, String? why}) reactTo(DeviceTarget t, String paramId, String sourceLayerId, ReactKind kind) {
    final source = layerById(sourceLayerId);
    if (source == null) return (link: null, why: 'That track is gone');
    final target = ModTarget.ofDevice(t, paramId);
    endUndoStep();
    var m = reactModulator(t, sourceLayerId, kind);
    final made = m == null;
    if (m == null) {
      m = addModulator(kind.componentId, layerId: t.layerId);
      if (m == null) return (link: null, why: 'A project holds at most $kMaxModulators modulators');
      final id = m.id;
      editModulator(id, (x) {
        x.inputId = sourceLayerId;
        x.hears = kind.hears;
        x.name = '${source.name} ${kind.label.toLowerCase()}';
      });
    }
    final ref = ModSourceRef(m.id, 0);
    final why = whyNoLink(ref, target);
    if (why != null) {
      if (made) removeModulator(m.id);  // the burst then changed nothing: no undo step
      endUndoStep();
      return (link: null, why: why);
    }
    final link = addModLink(ref, target);
    endUndoStep();
    return (link: link, why: link == null ? 'That link can\'t be made' : null);
  }
}
