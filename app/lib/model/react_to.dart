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
  /// to the loudness of a track it changes; a full project), and what it made: [ReactMade.linked] when the link is
  /// new, [ReactMade.modulatorId] when the modulator is ([undoReactTo] takes back just those).
  ({ModLinkDoc? link, String? why, ReactMade made}) reactTo(DeviceTarget t, String paramId, String sourceLayerId,
      ReactKind kind) {
    const none = ReactMade(linked: false);
    final source = layerById(sourceLayerId);
    if (source == null) return (link: null, why: 'That track is gone', made: none);
    final target = ModTarget.ofDevice(t, paramId);
    endUndoStep();
    var m = reactModulator(t, sourceLayerId, kind);
    final made = m == null;
    if (m == null) {
      m = addModulator(kind.componentId, layerId: t.layerId);
      if (m == null) return (link: null, why: 'A project holds at most $kMaxModulators modulators', made: none);
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
      return (link: null, why: why, made: none);
    }
    final had = project.modLinks.any((l) => l.source == ref.modulatorId && l.output == ref.output && l.target == target);
    final link = addModLink(ref, target);
    endUndoStep();
    return (
      link: link,
      why: link == null ? 'That link can\'t be made' : null,
      made: ReactMade(linked: link != null && !had, linkId: link?.id, modulatorId: made ? m.id : null),
    );
  }

  /// Takes back what a [reactTo] made (React to…'s Undo), as one undo step of its own: the link, and the modulator
  /// when it was made for it and nothing else links from it now. Edits made since stay.
  void undoReactTo(ReactMade made) {
    endUndoStep();
    final link = made.linkId;
    if (made.linked && link != null && modLink(link) != null) removeModLink(link);
    final m = made.modulatorId;
    if (m != null && project.modulator(m) != null && !project.modLinks.any((l) => l.source == m)) removeModulator(m);
    endUndoStep();
  }
}

/// What a [ReactTo.reactTo] made: whether the link is new (its id), and the modulator's id when it is new too.
class ReactMade {
  const ReactMade({required this.linked, this.linkId, this.modulatorId});
  final bool linked;
  final int? linkId;
  final String? modulatorId;
}
