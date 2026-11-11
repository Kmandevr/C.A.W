// MIDI record modes (REAPER's, UG 3.32; docs/reaper-flow.md gap 3): overdub adds a recording's notes into the clips
// already on the track where they were played, replace first clears those clips' notes over the time recorded. Notes
// played where the track has no clip become a new clip, as the default mode does with all of them.
import 'dart:math' as math;

import 'app_state.dart';
import 'live_midi.dart';
import 'pattern_doc.dart';
import 'project.dart';
import 'settings.dart';

/// What a merged recording changed, so the "Keep take?" toast's Undo can take it back: patterns it rewrote (their
/// sources before), and the clip and pattern it made for notes played outside any clip.
class MergedRecording {
  const MergedRecording(this.before, this.clipIds, this.moduleIds);
  final Map<String, String> before;
  final List<String> clipIds, moduleIds;
}

/// Writes [notes] (song steps, every pass folded into the loop) on [layer] by [mode]: null for
/// [MidiRecordMode.takes], which the recorder writes as a new clip. [from]..[to] is the time recorded (replace
/// clears it). One edit.
MergedRecording? mergeRecording(AppState s, LayerDoc layer, List<TakenNote> notes,
    {required MidiRecordMode mode, required double from, required double to}) {
  if (mode == MidiRecordMode.takes) return null;
  final p = s.project;
  final docs = <String, PatternDoc>{};
  final before = <String, String>{};
  PatternDoc? docOf(ClipDoc c) {
    final known = docs[c.patternId];
    if (known != null) return known;
    final m = p.module(c.patternId);
    final d = m == null ? null : PatternDoc.parse(m.source).doc;
    if (m == null || d == null) return null;
    before[m.id] = m.source;
    return docs[m.id] = d;
  }

  final clips = [for (final c in layer.clips) if (!c.lock) c];

  // Replace: each clip's notes heard between [from] and [to] go first.
  if (mode == MidiRecordMode.replace) {
    for (final c in clips) {
      final lo = math.max(from, c.startSteps.toDouble()), hi = math.min(to, (c.startSteps + c.lengthSteps).toDouble());
      if (hi <= lo) continue;
      final d = docOf(c);
      if (d == null) continue;
      final len = c.loopLength(d.lengthSteps(p.beatsPerBar));
      final gone = <int>{};
      for (final n in d.notes) {
        // Where the note plays in the song: once, or once a loop of the pattern while the clip loops.
        final first = c.startSteps - c.sourceOffsetSteps + n.at.toDouble();
        for (var t = first; t < hi; t += len) {
          if (t >= lo) {
            gone.add(n.id);
            break;
          }
          if (!c.loop) break;
        }
      }
      if (gone.isNotEmpty) docs[c.patternId] = d.delete(gone);
    }
  }

  // Each note goes into the clip it was played over (the newest on top when clips overlap).
  final outside = <TakenNote>[];
  for (final n in notes) {
    final c = clips.lastWhere((c) => n.at >= c.startSteps && n.at < c.startSteps + c.lengthSteps,
        orElse: () => ClipDoc(id: '', patternId: ''));
    final d = c.id.isEmpty ? null : docOf(c);
    if (d == null) {
      outside.add(n);
      continue;
    }
    final len = c.loopLength(d.lengthSteps(p.beatsPerBar));
    var pos = n.at - c.startSteps + c.sourceOffsetSteps;
    if (c.loop) pos %= len;
    if (pos < 0 || pos >= len) {
      outside.add(n);
      continue;
    }
    Steps grid(double v) => Steps.fromDouble((v * 8).round() / 8);
    docs[c.patternId] = docs[c.patternId]!.insert(grid(pos), n.pitch, grid(math.max(0.125, n.len)), vel: n.vel).doc;
  }

  final changed = {for (final e in docs.entries) if (e.value.serialize() != before[e.key]) e.key: e.value.serialize()};
  if (changed.isEmpty && outside.isEmpty) return const MergedRecording({}, [], []);
  final bar = p.stepsPerBar;
  ModuleDoc? made;
  int start = 0;
  if (outside.isNotEmpty) {
    start = (outside.map((n) => n.at).reduce(math.min) / bar).floor() * bar;
    var k = 1;
    while (p.modules.any((m) => m.name == 'Take $k')) {
      k++;
    }
    made = LiveMidi.takeModule(outside, start: start, stepsPerBar: bar, name: 'Take $k');
  }
  s.editProject((p) {
    for (final e in changed.entries) {
      final m = p.module(e.key)!;
      m.source = e.value;
      m.runSource = e.value;
    }
    if (made != null) p.modules.add(made);
  });
  ClipDoc? clip;
  if (made != null) {
    s.addClip(layer, made.id, startSteps: start);
    clip = layer.clips.where((c) => c.patternId == made!.id).firstOrNull;
  }
  return MergedRecording({for (final id in changed.keys) id: before[id]!}, [?clip?.id], [?made?.id]);
}

/// Loop-recorded takes on a clip (REAPER's T and Shift+T, the take chip's ‹ ›).
extension ClipTakes on AppState {
  /// Plays take [index] (0: the oldest) of [clip]; one undo step.
  void selectTake(LayerDoc layer, ClipDoc clip, int index) {
    if (clip.takes.length < 2) return;
    final id = clip.takes[index % clip.takes.length];
    if (id == clip.patternId || project.module(id) == null) return;
    endUndoStep();
    editLayer(layer, (_) => clip.patternId = id);
    endUndoStep();
  }

  /// The next take ([delta] 1) or the one before (-1), wrapping round.
  void stepTake(LayerDoc layer, ClipDoc clip, int delta) {
    final i = clip.takes.indexOf(clip.patternId);
    selectTake(layer, clip, (i < 0 ? clip.takes.length - 1 : i) + delta);
  }
}
