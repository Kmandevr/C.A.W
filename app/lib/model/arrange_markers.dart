// Arrange's loop range, markers and regions on AppState (docs/reaper-flow.md, gap 2): drawn and dragged on the ruler,
// regions moved or copied with their clips, stored in the project; the loop range goes to the engine, which loops
// playback over it. Each edit is one undo step.
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_edit.dart';
import 'arrange_tempo.dart';
import 'project.dart';

extension ArrangeMarkers on AppState {
  /// Sets the loop range to [start]..[end] (in either order; at least a step long) and turns it on, as a drag along
  /// REAPER's timeline does.
  void setLoopRange(int start, int end, {bool on = true}) {
    final lo = math.max(0, math.min(start, end)), hi = math.min(project.maxArrangementSteps, math.max(start, end));
    if (hi <= lo) return;
    endUndoStep();
    editProject((p) {
      p.loopStartSteps = lo;
      p.loopEndSteps = hi;
      p.loopRange = on;
    });
    endUndoStep();
  }

  /// Removes the loop range: it turns off and its markers go (owner, 2026-11-12: a handle dragged onto the other
  /// end collapses the loop). One undo step; undo brings the range back as it was.
  void clearLoopRange() {
    final p = project;
    if (!p.loopRange && !p.hasLoopRange) return;
    endUndoStep();
    editProject((p) {
      p.loopRange = false;
      p.loopStartSteps = 0;
      p.loopEndSteps = 0;
    });
    endUndoStep();
  }

  /// The loop button and R (REAPER's repeat): turns the loop range on or off. With none drawn yet, the time selection
  /// becomes it, else the four bars from the bar the playhead is in.
  void toggleLoopRange() {
    final p = project;
    if (!p.hasLoopRange) {
      final a = timeSelectionStart, b = timeSelectionEnd;
      if (a != null && b != null && a != b) return setLoopRange(a, b);
      final bar = p.stepsPerBar;
      final from = (editStep ~/ bar) * bar;
      return setLoopRange(from, from + 4 * bar);
    }
    endUndoStep();
    editProject((p) => p.loopRange = !p.loopRange);
    endUndoStep();
  }

  /// Adds a marker at [step], or a section from [step] to [end], named by count ("Marker 3", "Section 2") in the
  /// next colour; returns it. Sections never overlap: one that would starts after the section under [step] and
  /// ends where the next one starts, and with no room left it is a marker.
  MarkerDoc addMarker(int step, {int? end, String? name}) {
    var region = end != null && end > step;
    final max = project.maxArrangementSteps;
    var from = step.clamp(0, max - 1).toInt(), to = region ? end.clamp(from + 1, max).toInt() : null;
    if (region) {
      for (final o in project.sections) {
        if (o.startSteps <= from && from < o.endSteps!) from = o.endSteps!;
      }
      final next = project.sections.where((o) => o.startSteps >= from).firstOrNull;
      if (next != null && to! > next.startSteps) to = next.startSteps;
      if (to! <= from || from >= max) {
        region = false;
        from = step.clamp(0, max - 1).toInt();
        to = null;
      }
    }
    final count = project.markers.where((m) => m.isRegion == region).length + 1;
    final marker = MarkerDoc(id: newId('k'), name: name ?? (region ? 'Section $count' : 'Marker $count'),
        startSteps: from, endSteps: to,
        color: (project.markers.length + (region ? 3 : 5)) % LayerDoc.trackColors);
    endUndoStep();
    editProject((p) => p.markers.add(marker));
    endUndoStep();
    return marker;
  }

  /// Whether span [from]..[to] is clear of every section but [except].
  bool sectionFits(int from, int to, {MarkerDoc? except}) => from >= 0 && to <= project.maxArrangementSteps &&
      project.sections.every((o) => identical(o, except) || o.endSteps! <= from || o.startSteps >= to);

  /// The first start at or after [from] where a section [length] long fits.
  int freeSpanAt(int from, int length) {
    var at = from;
    for (final o in project.sections) {
      if (o.endSteps! <= at) continue;
      if (o.startSteps >= at + length) break;
      at = o.endSteps!;
    }
    return at;
  }

  /// Moves [marker] (a region keeps its length) to start at [step]. While a drag lasts, its moves are one undo step.
  void moveMarker(MarkerDoc marker, int step) {
    final len = (marker.endSteps ?? marker.startSteps) - marker.startSteps;
    final at = step.clamp(0, project.maxArrangementSteps - 1 - len).toInt();
    if (at == marker.startSteps || (marker.isRegion && !sectionFits(at, at + len, except: marker))) return;
    editProject((_) {
      marker.startSteps = at;
      if (marker.endSteps != null) marker.endSteps = at + len;
    });
  }

  void editMarker(MarkerDoc marker, {String? name, int? color}) {
    endUndoStep();
    editProject((_) {
      if (name != null && name.trim().isNotEmpty) marker.name = name.trim().substring(0, math.min(64, name.trim().length));
      if (color != null) marker.color = color % LayerDoc.trackColors;
    });
    endUndoStep();
  }

  void removeMarker(MarkerDoc marker) {
    endUndoStep();
    editProject((p) => p.markers.remove(marker));
    endUndoStep();
  }

  /// The clips that start inside section [region], on every track (REAPER's region contents).
  List<PlacedClip> clipsInRegion(MarkerDoc region) => [
        if (region.isRegion)
          for (final l in project.layers)
            if (!l.isFolder)
              for (final c in l.clips)
                if (c.startSteps >= region.startSteps && c.startSteps < region.endSteps!) (layer: l, clip: c),
      ];

  /// The older name of [moveSection].
  MarkerDoc? moveRegionWithClips(MarkerDoc region, int step, {bool copy = false}) => moveSection(region, step, copy: copy);

  /// Moves section [section] to start at [step] with what is in it (owner, 2026-11-13): the clips and audio clips
  /// that start inside it (locked ones stay), the automation points inside it (replacing those where it lands), and
  /// its tempo and signature changes (the music after its old and new places keeps its own). With [copy] the
  /// section stays and a copy of it ("… copy") goes there with copies of all of it, each clip with its own notes.
  /// The move is kept inside the song and never onto another section. One undo step; returns the section that is
  /// at [step] now, or null when nothing moved.
  MarkerDoc? moveSection(MarkerDoc section, int step, {bool copy = false}) {
    if (!section.isRegion) return null;
    final a = section.startSteps, b = section.endSteps!, len = b - a;
    final inside = [for (final c in clipsInRegion(section)) if (copy || !c.clip.lock) c];
    final audio = [
      for (final l in project.layers)
        if (!l.isFolder)
          for (final c in l.audioClips) if (c.startSteps >= a && c.startSteps < b) (layer: l, clip: c),
    ];
    var lo = a, hi = b;
    for (final c in inside) {
      lo = math.min(lo, c.clip.startSteps);
      hi = math.max(hi, c.clip.startSteps + c.clip.lengthSteps);
    }
    final shift = (step - a).clamp(-lo, project.maxArrangementSteps - hi).toInt();
    if (shift == 0) return copy ? null : section;
    final at = a + shift;
    if (!sectionFits(at, at + len, except: copy ? null : section)) return null;
    MarkerDoc result = section;
    endUndoStep();
    editProject((p) {
      _moveAutomation(p, a, b, shift, copy: copy);
      moveTempoSpan(p, a, b, at, copy: copy);
      if (copy) {
        final name = '${section.name} copy';
        result = MarkerDoc(id: newId('k'), name: name.substring(0, math.min(64, name.length)),
            startSteps: at, endSteps: at + len, color: section.color);
        p.markers.add(result);
        for (final c in inside) {
          final made = copyClipAt(c.clip, c.clip.startSteps + shift);
          if (made != null) c.layer.clips.add(made);
        }
        for (final c in audio) {
          c.layer.audioClips.add(c.clip.copyWith(id: newId('ac'), startSteps: c.clip.startSteps + shift));
        }
      } else {
        section.startSteps = at;
        section.endSteps = at + len;
        for (final c in inside) {
          c.clip.startSteps += shift;
        }
        for (final c in audio) {
          c.clip.startSteps += shift;
        }
      }
    });
    endUndoStep();
    return result;
  }

  /// Copies section [section] with everything in it to the first free place after it. One undo step.
  MarkerDoc? copySection(MarkerDoc section) {
    if (!section.isRegion) return null;
    final len = section.endSteps! - section.startSteps;
    return moveSection(section, freeSpanAt(section.endSteps!, len), copy: true);
  }

  /// Deletes section [section] with what is in it (owner, 2026-11-13): the clips and audio clips that start inside
  /// it (locked ones too: the section goes whole), its automation points and its tempo and signature changes (the
  /// music after it keeps its own). One undo step.
  void deleteSection(MarkerDoc section) {
    if (!section.isRegion) return removeMarker(section);
    final a = section.startSteps, b = section.endSteps!;
    endUndoStep();
    editProject((p) {
      for (final l in p.layers) {
        l.clips.removeWhere((c) => c.startSteps >= a && c.startSteps < b);
        l.audioClips.removeWhere((c) => c.startSteps >= a && c.startSteps < b);
      }
      _moveAutomation(p, a, b, null);
      moveTempoSpan(p, a, b, null);
      p.markers.remove(section);
    });
    endUndoStep();
  }

  /// The automation points in [a]..[b) moved by [shift] steps (copied with [copy]; deleted when [shift] is null), in
  /// the project's lanes and every track's; where they land, a lane's own points there give way.
  void _moveAutomation(ProjectDoc p, int a, int b, int? shift, {bool copy = false}) {
    void lane(List<AutomationPointDoc> points) {
      final inside = [for (final q in points) if (q.step >= a && q.step < b) q];
      if (inside.isEmpty) return;
      if (shift == null || !copy) points.removeWhere(inside.contains);
      if (shift != null) {
        points.removeWhere((q) => q.step >= a + shift && q.step < b + shift);
        points.addAll([for (final q in inside) AutomationPointDoc(step: q.step + shift, value: q.value)]);
      }
      points.sort((x, y) => x.step.compareTo(y.step));
    }
    for (final l in p.automation) {
      lane(l.points);
    }
    for (final layer in p.layers) {
      for (final l in layer.automation) {
        lane(l.points);
      }
    }
  }

  /// REAPER's 1–0 keys: moves the playhead to marker [n] (1-based; markers only, in time order). False when there
  /// is no such marker.
  bool jumpToMarkerNumber(int n) {
    final markers = [for (final m in project.markers) if (!m.isRegion) m]..sort((a, b) => a.startSteps.compareTo(b.startSteps));
    if (n < 1 || n > markers.length) return false;
    seekTo(markers[n - 1].startSteps.toDouble());
    return true;
  }

  /// The markers' and regions' starts, sorted, without repeats.
  List<int> get markerSteps => ({for (final m in project.markers) m.startSteps}.toList()..sort());

  /// Moves the playhead to the next marker or region start after it (REAPER's ]), or the previous one before it
  /// (REAPER's [); false when there is none that way.
  bool jumpToMarker({required bool next}) {
    final here = editStep;
    final steps = markerSteps;
    final to = next ? steps.where((s) => s > here).firstOrNull : steps.where((s) => s < here).lastOrNull;
    if (to == null) return false;
    seekTo(to.toDouble());
    return true;
  }
}

