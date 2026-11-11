// Arrange's loop range, markers and regions on AppState (docs/reaper-flow.md, gap 2): drawn and dragged on the ruler,
// regions moved or copied with their clips, stored in the project; the loop range goes to the engine, which loops
// playback over it. Each edit is one undo step.
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_edit.dart';
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

  /// Adds a marker at [step], or a region from [step] to [end], named by count ("Marker 3", "Region 2") in the next
  /// colour; returns it.
  MarkerDoc addMarker(int step, {int? end, String? name}) {
    final region = end != null && end > step;
    final count = project.markers.where((m) => m.isRegion == region).length + 1;
    final marker = MarkerDoc(id: newId('k'), name: name ?? (region ? 'Region $count' : 'Marker $count'),
        startSteps: step.clamp(0, project.maxArrangementSteps - 1).toInt(),
        endSteps: region ? end.clamp(step + 1, project.maxArrangementSteps).toInt() : null,
        color: (project.markers.length + (region ? 3 : 5)) % LayerDoc.trackColors);
    endUndoStep();
    editProject((p) => p.markers.add(marker));
    endUndoStep();
    return marker;
  }

  /// Moves [marker] (a region keeps its length) to start at [step]. While a drag lasts, its moves are one undo step.
  void moveMarker(MarkerDoc marker, int step) {
    final len = (marker.endSteps ?? marker.startSteps) - marker.startSteps;
    final at = step.clamp(0, project.maxArrangementSteps - 1 - len).toInt();
    if (at == marker.startSteps) return;
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

  /// The clips that start inside region [region], on every track (REAPER's region contents).
  List<PlacedClip> clipsInRegion(MarkerDoc region) => [
        if (region.isRegion)
          for (final l in project.layers)
            if (!l.isFolder)
              for (final c in l.clips)
                if (c.startSteps >= region.startSteps && c.startSteps < region.endSteps!) (layer: l, clip: c),
      ];

  /// Moves [region] to start at [step] with the clips that start inside it, by the same time (locked clips stay);
  /// with [copy] the region stays and a copy of it ("… copy") goes there, with copies of its clips, each with its own
  /// notes. The move is kept inside the song, so no clip goes before its start. One undo step; returns the region
  /// that is at [step] now, or null when nothing moved.
  MarkerDoc? moveRegionWithClips(MarkerDoc region, int step, {bool copy = false}) {
    if (!region.isRegion) return null;
    final inside = [for (final c in clipsInRegion(region)) if (copy || !c.clip.lock) c];
    final len = region.endSteps! - region.startSteps;
    var lo = region.startSteps, hi = region.endSteps!;
    for (final c in inside) {
      lo = math.min(lo, c.clip.startSteps);
      hi = math.max(hi, c.clip.startSteps + c.clip.lengthSteps);
    }
    final shift = (step - region.startSteps).clamp(-lo, project.maxArrangementSteps - hi).toInt();
    if (shift == 0) return copy ? null : region;
    final at = region.startSteps + shift;
    MarkerDoc result = region;
    endUndoStep();
    editProject((p) {
      if (copy) {
        result = MarkerDoc(id: newId('k'), name: '${region.name} copy'.substring(0, math.min(64, region.name.length + 5)),
            startSteps: at, endSteps: at + len, color: region.color);
        p.markers.add(result);
        for (final c in inside) {
          final made = copyClipAt(c.clip, c.clip.startSteps + shift);
          if (made != null) c.layer.clips.add(made);
        }
      } else {
        region.startSteps = at;
        region.endSteps = at + len;
        for (final c in inside) {
          c.clip.startSteps += shift;
        }
      }
    });
    endUndoStep();
    return result;
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

