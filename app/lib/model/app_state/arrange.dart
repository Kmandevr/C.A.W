// AppState's Arrange edits: tracks, folders and lanes, automation points, time selection, the mix and clips.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of '../app_state.dart';

extension AppStateArrange on AppState {
  // ---------- layers (Arranger) ----------

  /// The tracks the arrangement shows, in order: every track. A collapsed folder no longer hides the tracks inside
  /// it but draws them as thin bars ([shownCollapse]; owner, 2026-11-11).
  List<LayerDoc> get visibleLayers => List.of(project.layers);

  /// How [layer]'s row shows: thin inside a collapsed folder (at any depth), else its own [LayerDoc.collapse], so
  /// opening the folder brings back each track's own state.
  TrackCollapse shownCollapse(LayerDoc layer) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
      final folder = project.layers.where((x) => x.id == parent).firstOrNull;
      if (folder == null) break;
      if (folder.collapsed) return TrackCollapse.thin;
      parent = folder.parentId;
    }
    return layer.collapse;
  }

  /// Whether [layer] is somewhere inside the folder [folderId], at any depth.
  bool isInside(LayerDoc layer, String folderId) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
      if (parent == folderId) return true;
      parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
    }
    return false;
  }

  int folderDepth(LayerDoc layer) {
    var depth = 0, parent = layer.parentId;
    final seen = <String>{layer.id};
    while (parent != null && seen.add(parent)) {
      final folder = project.layers.where((x) => x.id == parent).firstOrNull;
      if (folder == null) break;
      depth++;
      parent = folder.parentId;
    }
    return depth;
  }

  bool moveLayerIntoFolder(LayerDoc layer, String? folderId) {
    if (folderId == layer.id) return false;
    if (folderId != null) {
      final folder = project.layers.where((x) => x.id == folderId).firstOrNull;
      if (folder == null || !folder.isFolder) return false;
      var parent = folder.parentId;
      for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
        if (parent == layer.id) return false;
        parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
      }
    }
    bool inSubtree(LayerDoc candidate, String root) {
      var parent = candidate.parentId;
      for (var depth = 0; parent != null && depth < project.layers.length; depth++) {
        if (parent == root) return true;
        parent = project.layers.where((x) => x.id == parent).firstOrNull?.parentId;
      }
      return false;
    }
    final subtree = project.layers.where((candidate) =>
      candidate.id == layer.id || inSubtree(candidate, layer.id)).toList();
    project.layers.removeWhere((candidate) => subtree.contains(candidate));
    layer.parentId = folderId;
    if (folderId == null) {
      project.layers.addAll(subtree);
    } else {
      var insertAt = project.layers.indexWhere((x) => x.id == folderId) + 1;
      while (insertAt < project.layers.length && inSubtree(project.layers[insertAt], folderId)) {
        insertAt++;
      }
      project.layers.insertAll(insertAt, subtree);
    }
    _changed();
    return true;
  }

  void setFolderBus(LayerDoc folder, bool enabled) {
    if (!folder.isFolder) return;
    editLayer(folder, (l) => l.busEnabled = enabled);
  }

  /// Sets the visual spacer under [layer] (0 removes it). The engine never sees it, so nothing is re-sent.
  void setSpaceBelow(LayerDoc layer, double px) {
    final v = px.isFinite ? px.clamp(0.0, LayerDoc.maxSpaceBelow).toDouble() : 0.0;
    if (v == layer.spaceBelow) return;
    layer.spaceBelow = v;
    _changed(engine: false);
  }

  /// Opens or closes [layer]'s automation lanes under it in the arrangement (REAPER's envelope button). Only the
  /// screen changes, so the engine isn't re-sent.
  void setLanesShown(LayerDoc layer, bool shown) {
    if (layer.showLanes == shown) return;
    layer.showLanes = shown;
    _changed(engine: false);
  }

  /// Opens or closes [layer]'s take lanes under it (#209, comping). Only the screen changes.
  void setTakesShown(LayerDoc layer, bool shown) {
    if (layer.showTakes == shown) return;
    layer.showTakes = shown;
    _changed(engine: false);
  }

  /// Sets the row height of each of [layer]'s take lanes (null: the default; clamped to the lanes' range), as a
  /// drag on a take lane header's bottom edge leaves it: one undo step. Only the screen changes.
  void setTakeHeight(LayerDoc layer, double? height) {
    final h = height == null || !height.isFinite ? null : height.clamp(kMinLaneHeight, kMaxLaneHeight).toDouble();
    if (layer.takeHeight == h) return;
    endUndoStep();
    layer.takeHeight = h;
    _changed(engine: false);
    endUndoStep();
  }

  /// Sets how much of each of [layers]' rows shows (the track menu's Collapse, a header's bottom-edge drag or pinch):
  /// one undo step. With [height] (a normal row), that track's own height is set too. Only the screen changes.
  void setTrackCollapse(Iterable<LayerDoc> layers, TrackCollapse collapse, {double? height}) {
    final h = height == null || !height.isFinite ? null
        : height.clamp(LayerDoc.minHeight, LayerDoc.maxHeight).toDouble();
    endUndoStep();
    var changed = false;
    for (final l in layers) {
      if (l.collapse != collapse) {
        l.collapse = collapse;
        changed = true;
      }
      if (h != null && collapse == TrackCollapse.normal && l.height != h) {
        l.height = h;
        changed = true;
      }
    }
    if (!changed) return;
    _changed(engine: false);
    endUndoStep();
  }

  /// [layer]'s row goes back to the global default height (Settings' track height).
  void resetTrackHeight(LayerDoc layer) {
    if (layer.height == null) return;
    endUndoStep();
    layer.height = null;
    _changed(engine: false);
    endUndoStep();
  }

  /// A folder's chevron: collapsed, the tracks inside it show as thin bars ([shownCollapse]); opened, each goes back
  /// to its own state.
  void setFolderCollapsed(LayerDoc folder, bool collapsed) {
    if (!folder.isFolder) return;
    editLayer(folder, (l) => l.collapsed = collapsed);
  }

  void addAutomationLane(LayerDoc layer, String target) {
    if (target != 'volume' && target != 'pan') return;
    if (layer.automation.any((a) => a.target == target)) return;
    _pushAutomationUndo();
    final end = project.arrangementEndSteps.clamp(1, project.maxArrangementSteps).toInt();
    editLayer(layer, (l) => l.automation.add(AutomationLaneDoc(target: target,
      points: [AutomationPointDoc(step: 0, value: target == 'volume' ? l.volume : l.pan),
        AutomationPointDoc(step: end.toDouble(), value: target == 'volume' ? l.volume : l.pan)])));
  }

  void updateProjectAutomationPoint(ProjectAutomationLaneDoc lane, int index, double step, double value) {
    if (lane.targetType != 'track' && guardFrozen(project.layers.where((l) => l.id == lane.layerId).firstOrNull)) return;
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    final point = lane.points[index];
    final ordered = [...lane.points]..sort((a, b) => a.step.compareTo(b.step));
    final position = ordered.indexOf(point);
    final lower = position > 0 ? ordered[position - 1].step + 0.01 : 0.0;
    final upper = position < ordered.length - 1
        ? ordered[position + 1].step - 0.01 : project.maxArrangementSteps.toDouble();
    point.step = step.clamp(lower, math.max(lower, upper)).toDouble();
    point.value = value.clamp(-1000000.0, 1000000.0).toDouble();
    _changed();
  }

  void addProjectAutomationPoint(ProjectAutomationLaneDoc lane, double step, double value) {
    if (lane.targetType != 'track' && guardFrozen(project.layers.where((l) => l.id == lane.layerId).firstOrNull)) return;
    _pushAutomationUndo();
    final at = step.clamp(0.0, project.maxArrangementSteps.toDouble()).toDouble();
    if (lane.points.any((point) => (point.step - at).abs() < 0.01)) return;
    lane.points.add(AutomationPointDoc(step: at, value: value));
    lane.points.sort((a, b) => a.step.compareTo(b.step));
    _changed();
  }

  void removeProjectAutomationPoint(ProjectAutomationLaneDoc lane, int index) {
    if (lane.targetType != 'track' && guardFrozen(project.layers.where((l) => l.id == lane.layerId).firstOrNull)) return;
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    lane.points.removeAt(index);
    _changed();
  }

  void removeProjectAutomationLane(ProjectAutomationLaneDoc lane) {
    _pushAutomationUndo();
    project.automation.remove(lane);
    _changed();
  }

  void removeAutomationLane(LayerDoc layer, AutomationLaneDoc lane) {
    _pushAutomationUndo();
    editLayer(layer, (l) => l.automation.remove(lane));
  }

  void removeAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, int index) {
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    editLayer(layer, (l) {
      l.automation.firstWhere((a) => a.target == lane.target).points.removeAt(index);
    });
  }

  void updateAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, int index, double step, double value) {
    if (index < 0 || index >= lane.points.length) return;
    _pushAutomationUndo();
    editLayer(layer, (l) {
      final p = lane.points[index];
      final sorted = [...lane.points]..sort((a, b) => a.step.compareTo(b.step));
      final position = sorted.indexOf(p);
      final lower = position > 0 ? sorted[position - 1].step + 0.01 : 0.0;
      final upper = position >= 0 && position < sorted.length - 1 ? sorted[position + 1].step - 0.01 : project.maxArrangementSteps.toDouble();
      p.step = step.clamp(lower, math.min(upper, project.maxArrangementSteps.toDouble())).toDouble();
      p.value = value.clamp(lane.target == 'volume' ? 0.0 : -1.0, lane.target == 'volume' ? kMaxMixGain : 1.0).toDouble();
      // Clamp to neighboring points instead of reordering during a drag; the dragged handle stays stable.
    });
  }

  void addAutomationPoint(LayerDoc layer, AutomationLaneDoc lane, double step, double value) {
    _pushAutomationUndo();
    final at = step.clamp(0, project.maxArrangementSteps.toDouble()).toDouble();
    if (lane.points.any((p) => (p.step - at).abs() < 0.01)) return;
    editLayer(layer, (l) {
      l.automation.firstWhere((a) => a.target == lane.target).points.add(
        AutomationPointDoc(step: at,
          value: value.clamp(lane.target == 'volume' ? 0.0 : -1.0, lane.target == 'volume' ? kMaxMixGain : 1.0).toDouble()));
      l.automation.firstWhere((a) => a.target == lane.target).points.sort((a, b) => a.step.compareTo(b.step));
    });
  }

  void beginTimeSelection(int step) {
    timeSelectionAnchor = step.clamp(0, project.maxArrangementSteps).toInt();
    setTimeSelection(step, step);
  }

  void updateTimeSelection(int step) {
    final anchor = timeSelectionAnchor ?? timeSelectionStart ?? step;
    setTimeSelection(anchor, step);
  }

  void endTimeSelection() {
    timeSelectionAnchor = null;
  }

  void setTimeSelection(int start, int end) {
    timeSelectionStart = start.clamp(0, project.maxArrangementSteps).toInt();
    timeSelectionEnd = end.clamp(0, project.maxArrangementSteps).toInt();
    notifyListeners();
  }

  void clearTimeSelection() {
    timeSelectionStart = timeSelectionEnd = timeSelectionAnchor = null;
    notifyListeners();
  }

  /// Adds an empty track (no instrument yet: drop one on it, or pick one in its FX).
  void addLayer() {
    project.layers.add(LayerDoc(
      id: newId('l'),
      name: 'Layer ${project.layers.length + 1}',
      color: newTrackColor(NewTrackKind.midi),
      lengthSteps: project.stepsPerBar,
      volume: 1, // 0 dB (owner, 2026-11-10)
    ));
    _changed();
  }

  void removeLayer(LayerDoc l) {
    for (final child in project.layers.where((x) => x.parentId == l.id)) {
      child.parentId = l.parentId;
    }
    project.layers.remove(l);
    _pruneClipSelection();
    _changed();
  }

  void moveLayer(int from, int to) {
    if (to > from) to--;
    final l = project.layers.removeAt(from);
    project.layers.insert(to, l);
    _changed();
  }

  /// Volume, pan, mute and solo go straight to the audio thread.
  /// Master gain shares the same project/engine state but updates only value listeners during a drag.
  void setMaster(double value) {
    project.master = value.clamp(0.0, kMaxMixGain).toDouble();
    engine?.setMaster(project.master);
    _save();
    masterValueTick.value++;
    values.value++;
  }

  void mixLayer(LayerDoc l, {double? volume, double? pan, bool? mute, bool? solo}) {
    if (volume != null) volume = volume.clamp(0.0, kMaxMixGain).toDouble();
    if (volume != null) onParamMove?.call(AutomationTarget('track', 'volume', layerId: l.id), volume);
    if (pan != null) onParamMove?.call(AutomationTarget('track', 'pan', layerId: l.id), pan);
    if (volume != null) l.volume = volume;
    if (pan != null) l.pan = pan;
    if (mute != null) l.mute = mute;
    if (solo != null) l.solo = solo;
    // Volume and pan drags only redraw their sliders and go straight to the audio thread. Mute and solo reach
    // through folders and buses (soloing a track keeps its buses and send buses open; muting a folder without a bus
    // mutes its tracks), which the engine works out from the whole project, so they go as a project update.
    if (mute == null && solo == null) {
      engine?.setLayerMix(l.id, l.volume, l.pan, l.mute, l.solo);
      _save();
      layerValueTick(l.id).value++;
      values.value++;
    } else {
      _changed();
    }
  }

  void _pruneClipSelection() {
    final valid = {
      for (final layer in project.layers) ...[for (final clip in layer.clips) clip.id, for (final c in layer.audioClips) c.id],
    };
    selectedClipIds.removeWhere((id) => !valid.contains(id));
    if (selectedClipId == null || !selectedClipIds.contains(selectedClipId)) {
      if (selectedClipIds.isEmpty) {
        selectedClipId = null;
        selectedLayerId = null;
        if (selectedModuleId != null && !project.modules.any((m) => m.id == selectedModuleId)) {
          selectedModuleId = project.modules.firstOrNull?.id;
        }
      } else {
        for (final layer in project.layers) {
          final clip = layer.clips.where((c) => selectedClipIds.contains(c.id)).firstOrNull;
          if (clip == null) {
            // Only audio clips are selected here (lib/model/audio_edit.dart): the first of them leads.
            final audio = layer.audioClips.where((c) => selectedClipIds.contains(c.id)).firstOrNull;
            if (audio == null) continue;
            selectedLayerId = layer.id;
            selectedClipId = audio.id;
            break;
          }
          selectedLayerId = layer.id;
          selectedClipId = clip.id;
          selectedModuleId = clip.patternId;
          break;
        }
      }
    }
  }

  bool get canMultiEditSelectedClips {
    if (selectedClipIds.length < 2) return false;
    final ids = <String>{};
    for (final layer in project.layers) {
      for (final clip in layer.clips) {
        if (selectedClipIds.contains(clip.id)) ids.add(clip.patternId);
      }
    }
    return ids.length == 1;
  }

  Set<String> get selectedPatternModuleIds => {
    for (final layer in project.layers)
      for (final clip in layer.clips)
        if (selectedClipIds.contains(clip.id)) clip.patternId,
  };

  List<PatternDoc> get selectedPatternReferences {
    final active = selectedModuleId;
    final refs = <PatternDoc>[];
    final seen = <String>{};
    for (final layer in project.layers) {
      for (final clip in layer.clips) {
        if (!selectedClipIds.contains(clip.id) || clip.patternId == active || !seen.add(clip.patternId)) continue;
        final module = project.module(clip.patternId);
        if (module == null) continue;
        final parsed = PatternDoc.parse(module.runSource);
        if (parsed.ok && parsed.doc != null) refs.add(parsed.doc!);
      }
    }
    return refs;
  }

  void activateClip(LayerDoc layer, ClipDoc clip) {
    selectedLayerId = layer.id;
    selectedClipId = clip.id;
    selectedModuleId = clip.patternId;
    selectedClipIds.add(clip.id);
    notifyListeners();
  }

  /// Tells the screens that [selectedClipIds] changed (Arrange's marquee, split and glue set it directly).
  void clipSelectionChanged() => notifyListeners();

  void selectClip(LayerDoc layer, ClipDoc clip, {bool additive = false}) {
    if (!additive) selectedClipIds.clear();
    if (additive && selectedClipIds.contains(clip.id)) {
      selectedClipIds.remove(clip.id);
      if (selectedClipIds.isEmpty) {
        selectedClipId = null;
        selectedLayerId = null;
        selectedModuleId = null;
      } else {
        final next = project.layers.expand((l) => l.clips.map((c) => (l, c)))
            .where((entry) => selectedClipIds.contains(entry.$2.id)).first;
        selectedLayerId = next.$1.id;
        selectedClipId = next.$2.id;
        selectedModuleId = next.$2.patternId;
      }
    } else {
      selectedClipIds.add(clip.id);
      selectedLayerId = layer.id;
      selectedClipId = clip.id;
      selectedModuleId = clip.patternId;
    }
    notifyListeners();
  }

  void addClip(LayerDoc layer, String patternId, {int? startSteps}) {
    if (guardFrozen(layer)) return;
    final module = project.module(patternId);
    if (module == null || !isPattern(patternId)) return;
    final doc = PatternDoc.parse(module.runSource).doc;
    final length = doc?.lengthSteps(project.beatsPerBar) ?? project.stepsPerBar;
    final end = layer.clips.fold<int>(0, (v, c) => v > c.startSteps + c.lengthSteps ? v : c.startSteps + c.lengthSteps);
    final requestedStart = startSteps ?? end;
    if (requestedStart >= project.maxArrangementSteps) return;
    final at = requestedStart.clamp(0, project.maxArrangementSteps - 1).toInt();
    final clip = ClipDoc(id: newId('c'), patternId: patternId,
        startSteps: at, lengthSteps: length.clamp(1, project.maxArrangementSteps - at).toInt());
    editLayer(layer, (l) => l.clips.add(clip));
    selectClip(layer, clip);
  }

  void duplicateClip(LayerDoc layer, ClipDoc clip, {bool linked = false}) {
    if (guardFrozen(layer)) return;
    final start = clip.startSteps + clip.lengthSteps;
    if (start >= project.maxArrangementSteps) return;
    var patternId = clip.patternId;
    if (!linked) {
      final original = project.module(patternId);
      if (original == null) return;
      final copy = ModuleDoc(id: newId('m'), name: '${original.name} copy',
          source: original.source, runSource: original.runSource);
      project.modules.add(copy);
      patternId = copy.id;
    }
    final next = ClipDoc(id: newId('c'), patternId: patternId,
        startSteps: start, lengthSteps: clip.lengthSteps.clamp(1, project.maxArrangementSteps - start).toInt(),
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, linked: linked, loopSteps: clip.loopSteps,
        automation: [for (final a in clip.automation) a.copy(fresh: true)]);
    editLayer(layer, (l) => l.clips.add(next));
    selectClip(layer, next);
  }

  void moveClip(LayerDoc layer, ClipDoc clip, int startSteps) {
    if (guardFrozen(layer)) return;
    editLayer(layer, (l) {
      final to = startSteps.clamp(0, project.maxArrangementSteps - clip.lengthSteps).toInt();
      // "Automation follows clips" (#230): the track's points over the clip go along.
      followClipAutomation(l, [(clip.startSteps.toDouble(), (clip.startSteps + clip.lengthSteps).toDouble())],
          (to - clip.startSteps).toDouble());
      clip.startSteps = to;
    });
  }

  void resizeClip(LayerDoc layer, ClipDoc clip, int lengthSteps) {
    if (guardFrozen(layer)) return;
    editLayer(layer, (l) => clip.lengthSteps = lengthSteps.clamp(1, project.maxArrangementSteps - clip.startSteps).toInt());
  }

  void shiftClipSource(LayerDoc layer, ClipDoc clip, int deltaSteps) {
    if (guardFrozen(layer)) return;
    editLayer(layer, (l) => clip.sourceOffsetSteps = (clip.sourceOffsetSteps + deltaSteps).clamp(0, project.maxArrangementSteps).toInt());
  }

  void removeClip(LayerDoc layer, ClipDoc clip) {
    if (guardFrozen(layer)) return;
    editLayer(layer, (l) => l.clips.remove(clip));
    selectedClipIds.remove(clip.id);
    _pruneClipSelection();
    notifyListeners();
  }

  /// A new folder at the end, or at the end of [parentId]'s contents: a folder inside a folder, to any depth
  /// (REAPER, UG 5.13.5).
  void addFolder({String? parentId}) {
    final parent = parentId == null ? null : project.layers.where((l) => l.id == parentId && l.isFolder).firstOrNull;
    final folder = LayerDoc(id: newId('l'), name: 'Group', color: newTrackColor(NewTrackKind.folder),
        parentId: parent?.id, isFolder: true, busEnabled: true);
    var at = project.layers.length;
    if (parent != null) {
      at = project.layers.indexOf(parent) + 1;
      while (at < project.layers.length && isInside(project.layers[at], parent.id)) {
        at++;
      }
    }
    project.layers.insert(at, folder);
    selectedLayerId = folder.id;
    _changed();
  }
}
