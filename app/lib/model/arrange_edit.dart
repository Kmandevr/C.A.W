// Arrange's clip edits on AppState, REAPER-style (docs/reaper-flow.md, gap 1): the clip selection (Ctrl/Shift-click,
// a marquee, the phone's Select mode), split at the playhead, glue, duplicate, delete, several clips moved or copied
// together, and a clip's properties. Each action is one undo step.
import 'dart:math' as math;

import 'app_state.dart';
import 'audio_edit.dart';
import 'pattern_doc.dart';
import 'project.dart';

/// The most notes a split or glue writes into a new pattern; past it a split shares the pattern instead and a glue
/// is left undone (a long looping clip can unroll into a great many notes).
const kClipEditMaxNotes = 20000;

/// [clip]'s notes as they play on the timeline between [from] and [to] (absolute steps; the clip's own edges when
/// null), with times from [from]: its source window from the offset, repeated while the clip loops, and notes cut at
/// the window's edges as the engine cuts them (`compileArrangement`). With [tails], a note already sounding at [from]
/// is kept from there, as the engine plays it; without, a note that started before [from] is left out (a split: its
/// note-on stays in the left clip). Null when there would be more than [limit] notes.
List<PatternNote>? clipNotes(PatternDoc src, ClipDoc clip, int beatsPerBar,
    {int? from, int? to, bool tails = true, int limit = kClipEditMaxNotes}) {
  final lo = from ?? clip.startSteps, hi = to ?? clip.startSteps + clip.lengthSteps;
  final sourceLength = math.max(1, src.lengthSteps(beatsPerBar));
  var sourcePos = clip.sourceOffsetSteps, consumed = 0, timeline = clip.startSteps;
  final out = <PatternNote>[];
  while (consumed < clip.lengthSteps && timeline < hi) {
    if (sourcePos >= sourceLength) {
      if (!clip.loop) break;
      sourcePos %= sourceLength;
    }
    final segment = math.min(clip.lengthSteps - consumed, sourceLength - sourcePos);
    if (segment <= 0) break;
    final wStart = math.max(timeline, lo), wEnd = math.min(timeline + segment, hi);
    if (wEnd > wStart) {
      final srcFrom = Steps(sourcePos + wStart - timeline), srcTo = Steps(sourcePos + wEnd - timeline);
      for (final n in src.notes) {
        if (n.end <= srcFrom || n.at >= srcTo) continue;
        if (!tails && n.at < srcFrom) continue;
        final cs = Steps.max(n.at, srcFrom), ce = Steps.min(n.end, srcTo);
        final at = Steps(wStart - lo) + (cs - srcFrom), len = ce - cs;
        final trimmed = cs != n.at || ce != n.end;
        out.add(trimmed
            ? n.copyWith(at: at, len: len, ratchet: 1, slide: false,
                expr: n.expr.rebased(n.at.toDouble(), n.len.toDouble(), cs.toDouble(), len.toDouble()))
            : n.copyWith(at: at));
        if (out.length > limit) return null;
      }
    }
    timeline += segment;
    consumed += segment;
    sourcePos += segment;
  }
  return out;
}

/// A clip on its track, as the selection lists it.
typedef PlacedClip = ({LayerDoc layer, ClipDoc clip});

extension ArrangeEdit on AppState {
  /// The selected clips on their tracks, in track then time order.
  List<PlacedClip> get selectedClips => [
        for (final layer in project.layers)
          for (final clip in [...layer.clips]..sort((a, b) => a.startSteps.compareTo(b.startSteps)))
            if (selectedClipIds.contains(clip.id)) (layer: layer, clip: clip),
      ];

  /// Where Split cuts: the playhead while playing, else where play would start (the ruler or an empty lane tapped,
  /// or where playback paused), else the start.
  int get editStep {
    if (meters.playing) return playheadStep.floor();
    return (pausedStep ?? timeSelectionStart ?? 0).floor();
  }

  /// [clip]'s name on screen: its own, else its pattern's.
  String clipName(ClipDoc clip) => clip.name ?? project.module(clip.patternId)?.name ?? 'Missing pattern';

  // ---------- selection ----------

  /// Ctrl-click (REAPER) and a tap in Select mode: the clip joins the selection, or leaves it.
  void toggleClipSelection(LayerDoc layer, ClipDoc clip) => selectClip(layer, clip, additive: true);

  /// Shift-click (REAPER, UG 7.2.1): every clip from the selected one to [clip], on the tracks between them and
  /// overlapping the time between them.
  void selectClipRange(LayerDoc layer, ClipDoc clip) {
    final anchor = selectedClips.where((c) => c.clip.id == selectedClipId).firstOrNull;
    if (anchor == null) return selectClip(layer, clip);
    final tracks = visibleLayers;
    final a = tracks.indexOf(anchor.layer), b = tracks.indexOf(layer);
    if (a < 0 || b < 0) return selectClip(layer, clip);
    final from = math.min(anchor.clip.startSteps, clip.startSteps);
    final to = math.max(anchor.clip.startSteps + anchor.clip.lengthSteps, clip.startSteps + clip.lengthSteps);
    for (final t in tracks.sublist(math.min(a, b), math.max(a, b) + 1)) {
      for (final c in t.clips) {
        if (c.startSteps < to && c.startSteps + c.lengthSteps > from) selectedClipIds.add(c.id);
      }
    }
    selectedClipIds.add(clip.id);
    clipSelectionChanged();
  }

  /// A marquee (REAPER's right-drag, or a long-press drag in Select mode) touched [clips]: they become the selection,
  /// or join it with [additive] (REAPER's Shift+right-drag).
  void selectClipsInBox(Iterable<PlacedClip> clips, {bool additive = false}) {
    if (!additive) selectedClipIds.clear();
    PlacedClip? first;
    for (final c in clips) {
      selectedClipIds.add(c.clip.id);
      first ??= c;
    }
    if (first != null) {
      selectedLayerId = first.layer.id;
      selectedClipId = first.clip.id;
      selectedModuleId = first.clip.patternId;
    } else if (selectedClipIds.isEmpty) {
      selectedClipId = null;
    }
    clipSelectionChanged();
  }

  void clearClipSelection() {
    selectedClipIds.clear();
    selectedClipId = null;
    clipSelectionChanged();
  }

  // ---------- split, glue, duplicate, delete ----------

  /// S (REAPER, UG 7.2.1): splits the selected clips under [at] (the edit step by default); with none selected,
  /// every clip under it. Locked clips stay whole. Notes crossing the cut end there (REAPER's "Allow trim of MIDI
  /// items when splitting" adds a note-off at the split, UG 22.9.1) and the right part doesn't play them again; it
  /// gets its own pattern (REAPER never pools the parts of a split, UG 13.35). True when something was split.
  bool splitClips({int? at}) {
    final step = at ?? editStep;
    // Audio clips split by their own rules (audio_edit.dart): a selection of only audio clips splits those; with
    // nothing selected every clip under the cut splits, audio too. A mixed selection splits its MIDI clips.
    final none = selectedClipIds.isEmpty, midiChosen = selectedClips.isNotEmpty;
    bool under(ClipDoc c) => !c.lock && c.startSteps < step && c.startSteps + c.lengthSteps > step;
    final chosen = selectedClipIds.isEmpty
        ? [for (final l in project.layers) if (!l.isFolder) for (final c in l.clips) if (under(c)) (layer: l, clip: c)]
        : [for (final c in selectedClips) if (under(c.clip)) c];
    final audio = none || !midiChosen ? splitAudioClips(step.toDouble(), selectedOnly: !none) : false;
    if (chosen.isEmpty) return audio;
    endUndoStep();
    final rights = <PlacedClip>[];
    editProject((p) {
      for (final c in chosen) {
        rights.add((layer: c.layer, clip: _splitOne(c.layer, c.clip, step)));
      }
    });
    selectClipsInBox(rights);
    endUndoStep();
    return true;
  }

  ClipDoc _splitOne(LayerDoc layer, ClipDoc clip, int step) {
    final end = clip.startSteps + clip.lengthSteps;
    final original = project.module(clip.patternId);
    final src = original == null ? null : PatternDoc.parse(original.runSource).doc;
    final notes = src == null || end - step > kPatternMaxSteps
        ? null
        : clipNotes(src, clip, project.beatsPerBar, from: step, tails: false);
    ClipDoc right;
    if (notes == null) {
      // A pattern that doesn't parse, or too many notes to write out: the right part shares the pattern from its
      // offset (it then plays a crossing note's tail).
      right = ClipDoc(id: newId('c'), patternId: clip.patternId, startSteps: step, lengthSteps: end - step,
          sourceOffsetSteps: clip.sourceOffsetSteps + step - clip.startSteps, loop: clip.loop, linked: true,
          name: clip.name, color: clip.color, mute: clip.mute);
    } else {
      final module = _patternModule(_uniqueName('${original!.name} part'), end - step, notes);
      project.modules.add(module);
      right = ClipDoc(id: newId('c'), patternId: module.id, startSteps: step, lengthSteps: end - step,
          loop: clip.loop, name: clip.name, color: clip.color, mute: clip.mute);
    }
    clip.lengthSteps = step - clip.startSteps;
    layer.clips.add(right);
    return right;
  }

  /// Glue (REAPER, UG 7.33): the selected clips on each track become one clip from the first start to the last end,
  /// in a new pattern holding the notes as they played, in place (muted clips add none). The originals' patterns
  /// stay in the project. True when something was glued.
  bool glueSelected() {
    final byTrack = <LayerDoc, List<ClipDoc>>{};
    for (final c in selectedClips) {
      if (!c.clip.lock) byTrack.putIfAbsent(c.layer, () => []).add(c.clip);
    }
    final glued = <PlacedClip>[];
    final plans = <(LayerDoc, List<ClipDoc>, ModuleDoc, ClipDoc)>[];
    for (final MapEntry(key: layer, value: clips) in byTrack.entries) {
      if (clips.length < 2) continue;
      final lo = clips.map((c) => c.startSteps).reduce(math.min);
      final hi = clips.map((c) => c.startSteps + c.lengthSteps).reduce(math.max);
      if (hi - lo > kPatternMaxSteps) continue;
      final notes = <PatternNote>[];
      var ok = true;
      for (final c in clips) {
        if (c.mute) continue;
        final m = project.module(c.patternId);
        final src = m == null ? null : PatternDoc.parse(m.runSource).doc;
        if (src == null) continue;
        final part = clipNotes(src, c, project.beatsPerBar, limit: kClipEditMaxNotes - notes.length);
        if (part == null) {
          ok = false;
          break;
        }
        notes.addAll([for (final n in part) n.copyWith(at: n.at + Steps(c.startSteps - lo))]);
      }
      if (!ok) continue;
      final first = clips.first;
      final module = _patternModule(_uniqueName(clipName(first)), hi - lo, notes);
      plans.add((layer, clips, module,
          ClipDoc(id: newId('c'), patternId: module.id, startSteps: lo, lengthSteps: hi - lo, loop: false, color: first.color)));
    }
    if (plans.isEmpty) return false;
    endUndoStep();
    editProject((p) {
      for (final (layer, clips, module, clip) in plans) {
        p.modules.add(module);
        layer.clips.removeWhere(clips.contains);
        layer.clips.add(clip);
        glued.add((layer: layer, clip: clip));
      }
    });
    selectClipsInBox(glued);
    endUndoStep();
    return true;
  }

  /// Duplicate (REAPER's Ctrl+D): copies of the selected clips, each with its own notes, right after the selection
  /// as a block, so the copies keep their spacing. The copies become the selection.
  bool duplicateSelected() {
    final chosen = selectedClips;
    if (chosen.isEmpty) return duplicateSelectedAudio();
    final lo = chosen.map((c) => c.clip.startSteps).reduce(math.min);
    final hi = chosen.map((c) => c.clip.startSteps + c.clip.lengthSteps).reduce(math.max);
    final copies = <PlacedClip>[];
    endUndoStep();
    editProject((p) {
      for (final c in chosen) {
        final start = c.clip.startSteps + hi - lo;
        if (start >= p.maxArrangementSteps) continue;
        final copy = _copyOf(c.clip, start);
        if (copy != null) {
          c.layer.clips.add(copy);
          copies.add((layer: c.layer, clip: copy));
        }
      }
    });
    selectClipsInBox(copies);
    endUndoStep();
    return copies.isNotEmpty;
  }

  /// Delete (REAPER: Delete removes the selected items). Locked clips stay. True when something was deleted.
  bool deleteSelected() {
    final audio = deleteSelectedAudio();
    final chosen = [for (final c in selectedClips) if (!c.clip.lock) c];
    if (chosen.isEmpty) return audio;
    endUndoStep();
    editProject((_) {
      for (final c in chosen) {
        c.layer.clips.remove(c.clip);
        selectedClipIds.remove(c.clip.id);
      }
    });
    selectClipsInBox(const [], additive: true);
    endUndoStep();
    return true;
  }

  // ---------- several clips dragged together ----------

  /// A drag of [grabbed] (one of several selected clips) from [from] to [to] at [startSteps] moves, or with [copy]
  /// copies, every selected clip by the same time and the same number of tracks (REAPER moves a selection together).
  /// When some clip would leave the tracks, they all stay on their own tracks. Locked clips stay. One undo step.
  void moveSelectedClips(LayerDoc from, ClipDoc grabbed, LayerDoc? to, int startSteps, {bool copy = false}) {
    final chosen = [for (final c in selectedClips) if (!c.clip.lock) c];
    if (chosen.isEmpty) return;
    final tracks = [for (final l in visibleLayers) if (!l.isFolder) l];
    var down = to == null ? 0 : tracks.indexOf(to) - tracks.indexOf(from);
    if (to == null || !tracks.contains(to) || !tracks.contains(from) ||
        chosen.any((c) {
          final i = tracks.indexOf(c.layer) + down;
          return !tracks.contains(c.layer) || i < 0 || i >= tracks.length;
        })) {
      down = 0;
    }
    final earliest = chosen.map((c) => c.clip.startSteps).reduce(math.min);
    final latestEnd = chosen.map((c) => c.clip.startSteps + c.clip.lengthSteps).reduce(math.max);
    final shift = (startSteps - grabbed.startSteps).clamp(-earliest, project.maxArrangementSteps - latestEnd).toInt();
    if (shift == 0 && down == 0 && !copy) return;
    final placed = <PlacedClip>[];
    endUndoStep();
    editProject((p) {
      for (final c in chosen) {
        final target = down == 0 ? c.layer : tracks[tracks.indexOf(c.layer) + down];
        final start = c.clip.startSteps + shift;
        if (copy) {
          final made = _copyOf(c.clip, start);
          if (made == null) continue;
          target.clips.add(made);
          placed.add((layer: target, clip: made));
        } else {
          c.layer.clips.remove(c.clip);
          c.clip.startSteps = start;
          target.clips.add(c.clip);
          placed.add((layer: target, clip: c.clip));
        }
      }
    });
    selectClipsInBox(placed);
    endUndoStep();
  }

  // ---------- properties ----------

  /// The Properties sheet's edits to [clip] (REAPER's item properties, F2, UG 7.8). [color] -1 goes back to the
  /// track's colour. Each call is one undo step.
  void setClipProperties(LayerDoc layer, ClipDoc clip,
      {String? name, int? color, int? lengthSteps, bool? loop, int? sourceOffsetSteps, bool? mute, bool? lock}) {
    endUndoStep();
    editLayer(layer, (_) {
      if (name != null) clip.name = name.trim().isEmpty ? null : name.trim().substring(0, math.min(128, name.trim().length));
      if (color != null) clip.color = color < 0 ? null : color % LayerDoc.trackColors;
      if (lengthSteps != null) clip.lengthSteps = lengthSteps.clamp(1, project.maxArrangementSteps - clip.startSteps).toInt();
      if (loop != null) clip.loop = loop;
      if (sourceOffsetSteps != null) clip.sourceOffsetSteps = sourceOffsetSteps.clamp(0, project.maxArrangementSteps).toInt();
      if (mute != null) clip.mute = mute;
      if (lock != null) clip.lock = lock;
    });
    endUndoStep();
  }

  // ---------- helpers ----------

  /// A copy of [clip] at [start] with its own pattern (added to the project): call it inside an edit.
  ClipDoc? copyClipAt(ClipDoc clip, int start) => _copyOf(clip, start);

  ClipDoc? _copyOf(ClipDoc clip, int start) {
    final original = project.module(clip.patternId);
    if (original == null) return null;
    final source = ModuleDoc(id: newId('m'), name: '${original.name} copy',
        source: original.source, runSource: original.runSource, params: Map.of(original.params));
    project.modules.add(source);
    return ClipDoc(id: newId('c'), patternId: source.id, startSteps: start,
        lengthSteps: clip.lengthSteps.clamp(1, project.maxArrangementSteps - start).toInt(),
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, name: clip.name, color: clip.color, mute: clip.mute);
  }

  ModuleDoc _patternModule(String name, int lengthSteps, List<PatternNote> notes) {
    var doc = PatternDoc.blank(name: name, steps: lengthSteps.clamp(1, kPatternMaxSteps).toInt());
    if (notes.isNotEmpty) {
      final span = notes.map((n) => n.end).reduce(Steps.max);
      doc = doc.paste(PatternClip(notes, span), Steps.zero).doc;
    }
    final text = doc.serialize();
    return ModuleDoc(id: newId('m'), name: name, source: text);
  }

  String _uniqueName(String base) {
    if (project.modules.every((m) => m.name != base)) return base;
    var n = 2;
    while (project.modules.any((m) => m.name == '$base $n')) {
      n++;
    }
    return '$base $n';
  }
}
