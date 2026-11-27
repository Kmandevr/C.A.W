// Arrange's track and clip menus, a track header dragged to a new place, renaming, and the callbacks the lanes and clips use.
// ignore_for_file: invalid_use_of_protected_member
part of '../arranger_screen.dart';

/// The + Track button's tooltip, in the words of the input in use.
String get _addTrackTip => 'Add a track (${PointerInput.hold} for a folder, audio or a template)';

extension _TrackMenus on _ArrangerScreenState {
  Future<void> _trackMenu(LayerDoc layer, Offset at, List<ModuleDoc> patterns) async {
    final s = widget.state;
    final index = s.project.layers.indexOf(layer);
    s.componentCatalog.refreshIfStale();
    final hasVolume = layer.automation.any((a) => a.target == 'volume');
    final hasPan = layer.automation.any((a) => a.target == 'pan');
    final canAutomate = !layer.isFolder || layer.busEnabled;
    final midi = LiveMidi.current;
    // Sections, the most used first (owner, 2026-11-11); volume and pan edit in place.
    const track = 'Track', mix = 'Mix', record = 'Record', clips = 'Clips', move = 'Move', lanes = 'Automation',
        collapse = 'Collapse', render = 'Render', more = 'More';
    final shown = s.shownCollapse(layer);
    final v = await showLongPressMenu<String>(context, at: at, title: layer.name, style: s.settings.longPressMenu, actions: [
      if (!layer.isFolder) ...[
        const MenuAction('fx', 'Effects', Icons.graphic_eq, section: track),
        // The same browser as the FX stack's (REAPER: instruments are FX), filtered to instruments.
        if (!layer.isAudio)
          MenuAction('instrument', 'Instrument · ${s.instrumentName(layer) ?? 'none'}…', Icons.piano, section: track),
      ],
      const MenuAction('rename', 'Rename', Icons.edit_outlined, section: track),
      MenuAction('color', layer.ownColor || layer.parentId == null ? 'Colour' : 'Own colour', Icons.palette_outlined,
          section: track),
      if (layer.ownColor && layer.parentId != null) const MenuAction('folder-color', "Use the folder's colour",
          Icons.format_color_reset_outlined, section: track),
      if (!layer.isFolder || layer.busEnabled) ...[
        MenuAction('volume', 'Volume', Icons.volume_up_outlined, section: mix, number: MenuNumber(
          value: _gainDb(layer.volume), min: -60, max: _gainDb(kMaxMixGain), defaultValue: 0,
          format: (db) => db <= -60 ? '-inf dB' : '${db.toStringAsFixed(1)} dB',
          parse: (t) => t.trim().toLowerCase().startsWith('-inf') ? -60
              : double.tryParse(t.replaceAll(RegExp(r'[^-+0-9.]'), '')),
          onChanged: (db) => s.mixLayer(layer, volume: _dbGain(db)),
          onChangeEnd: (db) { s.mixLayer(layer, volume: _dbGain(db)); s.endUndoStep(); })),
        MenuAction('pan', 'Pan', Icons.compare_arrows, section: mix, number: MenuNumber(
          value: layer.pan * 100, min: -100, max: 100, defaultValue: 0,
          format: (v) => v.round() == 0 ? 'C' : '${v < 0 ? 'L' : 'R'}${v.abs().round()}',
          parse: (t) {
            final text = t.trim().toUpperCase();
            if (text == 'C') return 0;
            final n = double.tryParse(text.replaceAll(RegExp(r'[^-+0-9.]'), ''));
            return n == null ? null : (text.startsWith('L') ? -n.abs() : n);
          },
          onChanged: (v) => s.mixLayer(layer, pan: v / 100),
          onChangeEnd: (v) { s.mixLayer(layer, pan: v / 100); s.endUndoStep(); })),
      ],
      if (!layer.isFolder) ...[
        // MIDI keyboards and the on-screen keys record into a track (lib/model/live_midi.dart); audio recording needs
        // the engine's input.
        // While any track records, this stops that take (one take at a time).
        // With no USB keyboard, recording opens the on-screen keys and pads.
        if (layer.isAudio) ...[
          // An audio track records its input (lib/model/audio_record.dart) when armed and Record is pressed.
          MenuAction('audio-arm', 'Record arm', Icons.fiber_manual_record, checked: layer.input?.armed ?? false,
              section: record),
          MenuAction('audio-input', 'Input · ${layer.input?.label ?? 'none'}…', Icons.input, section: record),
        ] else ...[
          MenuAction('arm', midi?.recording ?? false ? 'Stop recording' : 'Record arm', Icons.fiber_manual_record,
              enabled: midi != null, checked: midi?.armedLayerId == layer.id, section: record),
          MenuAction('input', 'Input · ${midi == null || midi.devices.isEmpty ? 'none' : midi.devices.join(', ')}', Icons.input,
              enabled: false, hint: 'MIDI keyboards play the selected track; an audio track records audio input',
              section: record),
        ],
        if (layer.instrument == null && layer.clips.isEmpty)
          const MenuAction('audio-import', 'Import audio…', Icons.graphic_eq_rounded, section: clips)
        else
          const MenuAction('audio-track', 'New audio track below', Icons.graphic_eq_rounded, section: clips),
        for (final pattern in patterns)
          MenuAction('clip:${pattern.id}', 'Add clip · ${pattern.name}', Icons.add_box_outlined, section: clips),
        const MenuAction('midi', 'Import MIDI file…', Icons.file_open_outlined, section: clips),
      ],
      if (index > 0) const MenuAction('up', 'Move up', Icons.arrow_upward, section: move),
      if (index < s.project.layers.length - 1) const MenuAction('down', 'Move down', Icons.arrow_downward, section: move),
      // Out one level, as REAPER's folders nest (UG 5.13.5): into the folder above, or to the top.
      if (layer.parentId != null) MenuAction('unparent', 'Move out of ${s.project.layers
          .where((f) => f.id == layer.parentId).firstOrNull?.name ?? 'folder'}', Icons.drive_file_move_rtl_outlined,
          section: move),
      // Any folder at any depth, except this one, its folder and the folders inside it.
      for (final folder in s.project.layers.where((f) => f.isFolder && f.id != layer.id && f.id != layer.parentId &&
          !s.isInside(f, layer.id)))
        MenuAction('parent:${folder.id}', 'Move into ${folder.name}', Icons.drive_file_move_outlined, section: move),
      if (layer.isFolder) const MenuAction('subfolder', 'New folder inside', Icons.create_new_folder_outlined,
          section: move),
      if (layer.isFolder) MenuAction('bus', layer.busEnabled ? 'Disable group bus' : 'Enable group bus',
          Icons.account_tree_outlined, section: move),
      MenuAction('spacer', layer.spaceBelow > 0 ? 'Remove spacer below' : 'Add spacer below', Icons.space_bar,
          section: move),
      if (takeLaneCount(layer) > 0) MenuAction('takes', layer.showTakes ? 'Hide take lanes' : 'Show take lanes',
          Icons.layers_outlined, checked: layer.showTakes, section: lanes),
      if (canAutomate) MenuAction('lanes', layer.showLanes ? 'Hide automation lanes' : 'Show automation lanes',
          Icons.show_chart, checked: layer.showLanes, section: lanes),
      if (canAutomate && !hasVolume) const MenuAction('automation-volume', 'Add volume automation', Icons.show_chart,
          section: lanes),
      if (canAutomate && !hasPan) const MenuAction('automation-pan', 'Add pan automation', Icons.show_chart,
          section: lanes),
      if (hasVolume) const MenuAction('remove-automation-volume', 'Remove volume automation',
          Icons.remove_circle_outline, section: lanes),
      if (hasPan) const MenuAction('remove-automation-pan', 'Remove pan automation', Icons.remove_circle_outline,
          section: lanes),
      // REAPER's track heights (owner, 2026-11-11): the row's full height, compact (name, M and S) or a thin bar.
      for (final (c, label, icon) in const [(TrackCollapse.normal, 'Normal', Icons.view_stream_outlined),
          (TrackCollapse.compact, 'Compact', Icons.view_headline), (TrackCollapse.thin, 'Thin', Icons.horizontal_rule)])
        MenuAction('collapse:${c.name}', label, icon, checked: shown == c, section: collapse),
      if (layer.height != null) const MenuAction('default-height', 'Default height', Icons.height, section: collapse),
      // Freeze and bounce (owner, 2026-11-14: in the hold menu, no header button).
      if (s.canRenderTrack(layer) || layer.frozen) ...[
        MenuAction('freeze', layer.frozen ? 'Unfreeze' : 'Freeze', Icons.ac_unit, checked: layer.frozen,
            section: render),
        if (layer.frozen && !s.project.playsFrozen(layer))
          const MenuAction('refreeze', 'Freeze again (the tempo changed)', Icons.ac_unit, section: render),
        if (s.canRenderTrack(layer))
          const MenuAction('bounce', 'Bounce to audio', Icons.graphic_eq_rounded, section: render),
      ],
      MenuAction('template', layer.isFolder ? 'Save folder as track template…' : 'Save as track template…',
          Icons.bookmark_add_outlined, section: more),
      const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true, section: more),
    ]);
    if (v == null || !mounted) return;
    if (v == 'fx') _openTrack(layer, tab: FocusTab.fx);
    if (v == 'freeze' && layer.frozen) {
      s.unfreezeTrack(layer);
      return;
    }
    if (v == 'freeze' || v == 'refreeze') {
      if (v == 'refreeze') s.unfreezeTrack(layer);
      await runTrackRender(context, 'Freeze ${layer.name}', () => s.freezeTrack(layer));
      return;
    }
    if (v == 'bounce') {
      await runTrackRender(context, 'Bounce ${layer.name}', () => s.bounceTrack(layer));
      return;
    }
    if (v == 'arm') midi?.toggleRecord(layer.id);
    if (v == 'audio-arm') {
      await toggleAudioArm(context, s, layer);
      return;
    }
    if (v == 'audio-input') {
      await showAudioInputSheet(context, s, layer);
      return;
    }
    if (v == 'audio-import') {
      await importAudioFiles(context, s, layer: layer);
      return;
    }
    if (v == 'audio-track') s.addAudioTrack(after: layer);
    if (v == 'instrument') {
      await pickInstrument(context, s, layer);
      return;
    }
    if (v.startsWith('clip:')) s.addClip(layer, v.substring(5));
    if (v == 'midi') await importMidiFile(context, s, layer: layer);
    if (v == 'rename') await _rename(layer);
    if (v == 'color') s.editLayer(layer, (l) { l.color = l.ownColor ? (l.color + 1) % LayerDoc.trackColors : l.color; l.ownColor = true; });
    if (v == 'folder-color') s.editLayer(layer, (l) => l.ownColor = false);
    if (v == 'up' && index > 0) s.moveLayer(index, index - 1);
    if (v == 'down' && index < s.project.layers.length - 1) s.moveLayer(index, index + 2);
    if (v == 'unparent') {
      // Just below its folder, in that folder's own parent.
      final folder = s.project.layers.where((f) => f.id == layer.parentId).firstOrNull;
      folder == null ? s.moveLayerIntoFolder(layer, null) : s.moveTrack(layer, folder, TrackDrop.below);
    }
    if (v == 'subfolder') s.addFolder(parentId: layer.id);
    if (v.startsWith('parent:')) {
      final folder = s.project.layers.where((f) => f.id == v.substring(7)).firstOrNull;
      if (folder != null) s.moveTrack(layer, folder, TrackDrop.into);
    }
    if (v == 'bus') s.setFolderBus(layer, !layer.busEnabled);
    if (v.startsWith('collapse:')) {
      s.setTrackCollapse(_collapseTargets(layer), TrackCollapse.values.byName(v.substring(9)));
    }
    if (v == 'default-height') s.resetTrackHeight(layer);
    if (v == 'lanes') s.setLanesShown(layer, !layer.showLanes);
    if (v == 'takes') toggleTakeLanes(s, layer);
    if (v == 'automation-volume') s.addAutomationLane(layer, 'volume');
    if (v == 'automation-pan') s.addAutomationLane(layer, 'pan');
    if (v == 'remove-automation-volume') s.removeAutomationLane(layer, layer.automation.firstWhere((a) => a.target == 'volume'));
    if (v == 'remove-automation-pan') s.removeAutomationLane(layer, layer.automation.firstWhere((a) => a.target == 'pan'));
    if (v == 'template') {
      if (mounted) await saveTrackTemplate(context, s, layer);
      return;
    }
    if (v == 'spacer') s.setSpaceBelow(layer, layer.spaceBelow > 0 ? 0 : _SpacerHeader.initial);
    if (v == 'delete' && mounted && await confirmTrackDelete(context, s, layer) && mounted) {
      if (_focusId == layer.id) _focus(null);
      s.removeLayer(layer);
    }
  }

  /// The tracks the menu's Collapse applies to: the selected tracks, which is the one the menu is for (the arranger
  /// selects one track at a time today; a multi-track selection would join here).
  List<LayerDoc> _collapseTargets(LayerDoc layer) => [layer];

  List<ModuleDoc> get _patterns => [for (final m in widget.state.project.modules) if (widget.state.isPattern(m.id)) m];
  void _trackDrag(LayerDoc layer, _HeaderPhase phase, Offset at) {
    switch (phase) {
      case _HeaderPhase.press:
        // A hold opens the track menu at once; moving past the touch slop closes it and picks the track up to
        // reorder it (owner, 2026-11-12). The menu cancels the gesture under it, so the finger is followed from here.
        _pressed = layer;
        _pressAt = at;
        _held = true;
        _headerHold.start(_headerPointer, at,
          begin: (from) {
            if (!mounted) return;
            Motion.tick();
            _held = false;
            _startTrackDrag(layer, from);
          },
          move: (p) => _trackDrag(layer, _HeaderPhase.move, p),
          end: (cancel) => _trackDrag(layer, cancel ? _HeaderPhase.cancel : _HeaderPhase.release, Offset.zero));
        _trackMenu(layer, at, _patterns);
      case _HeaderPhase.grab:
        _pressed = layer;
        _pressAt = at;
        _held = false;
        _startTrackDrag(layer, at);
      case _HeaderPhase.move:
        if (_dragged == null && !_held && _pressed == layer && (at - _pressAt).distance > 10) {
          _startTrackDrag(layer, _pressAt);
        }
        if (_dragged != layer) return;
        _trackAt = at;
        _trackGhostAt.value = at;
        _drag.point(at);
        _trackHover();
      case _HeaderPhase.release:
        _held = false;
        if (_dragged != layer) {
          // A hold let go without moving: the menu it opened stays.
          _pressed = null;
          return;
        }
        final spot = _drag.hover.value;
        _endTrackDrag();
        if (spot == null) return;
        final target = widget.state.project.layers.where((l) => l.id == spot.layerId).firstOrNull;
        widget.state.moveTrack(layer, spot.newTrack ? null : target, spot.where);
      case _HeaderPhase.cancel:
        if (_dragged == layer) _endTrackDrag();
        _pressed = null;
        _held = false;
    }
  }

  void _startTrackDrag(LayerDoc layer, Offset at) {
    _dragged = layer;
    _trackAt = at;
    _trackGhostAt.value = at;
    _drag.begin(track: true, onScroll: _trackHover, onCancel: _endTrackDrag);
    final color = trackColor(widget.state, layer);
    _trackGhost = OverlayEntry(builder: (context) => ValueListenableBuilder<Offset>(
      valueListenable: _trackGhostAt,
      builder: (context, p, _) => Positioned(left: p.dx + 12, top: p.dy - 14, child: IgnorePointer(child: Material(
        key: const ValueKey('track-drag-ghost'),
        color: Color.lerp(Neon.panel, color, 0.35)!.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: color, width: 3))),
          child: Text(layer.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))))))));
    Overlay.of(context).insert(_trackGhost!);
  }

  void _trackHover() {
    final layer = _dragged;
    if (layer == null) return;
    final s = widget.state;
    var spot = _drag.trackSpotAt(_trackAt);
    // Onto itself, or into itself, a track inside it or the parent it is already in, it stays where it is.
    final onto = spot?.layerId == null ? null : s.project.layers.where((l) => l.id == spot!.layerId).firstOrNull;
    if (onto != null && (identical(onto, layer) || s.isInside(onto, layer.id) ||
        (spot!.where == TrackDrop.into && layer.parentId == onto.id))) {
      spot = null;
    }
    _drag.hover.value = spot;
  }

  void _endTrackDrag() {
    _trackGhost?.remove();
    _trackGhost = null;
    _dragged = _pressed = null;
    _drag.end();
  }

  Future<void> _rename(LayerDoc layer) async {
    final controller = TextEditingController(text: layer.name);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Rename track'),
      content: TextField(controller: controller, autofocus: true, maxLength: 64,
        onSubmitted: (v) => Navigator.of(context).pop(v)),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Rename')),
      ],
    ));
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isNotEmpty && trimmed != layer.name) widget.state.editLayer(layer, (l) => l.name = trimmed);
  }

  Future<void> _clipMenu(LayerDoc layer, ClipDoc clip, Offset at) async {
    final s = widget.state;
    final splitAt = s.timeSelectionEnd;
    final canSplit = splitAt != null && splitAt > clip.startSteps && splitAt < clip.startSteps + clip.lengthSteps;
    final playhead = s.editStep;
    final canSplitHere = !clip.lock && playhead > clip.startSteps && playhead < clip.startSteps + clip.lengthSteps;
    const clipSection = 'Clip', edit = 'Edit', size = 'Size', more = 'More';
    final bar = s.project.stepsPerBar;
    // Reset goes back to the pattern's own length.
    final doc = PatternDoc.parse(s.project.module(clip.patternId)?.source ?? '').doc;
    final patternBars = doc == null ? null : math.max(1, doc.lengthSteps(s.project.beatsPerBar)) / bar;
    final consolidate = s.selectedClipIds.contains(clip.id)
        ? [for (final c in layer.clips) if (s.selectedClipIds.contains(c.id) && !c.lock) c] : const <ClipDoc>[];
    final v = await showLongPressMenu<String>(context, at: at, title: s.clipName(clip),
      style: s.settings.longPressMenu, actions: [
        const MenuAction('notes', 'Edit notes', Icons.piano, section: clipSection),
        const MenuAction('properties', 'Properties…', Icons.tune, section: clipSection),
        // The phone's way to select several (docs/ui.md): this clip joins the selection and Select mode turns on.
        if (!s.selectedClipIds.contains(clip.id) || !_selectMode)
          const MenuAction('select', 'Select several', Icons.checklist, section: clipSection)
        else
          const MenuAction('select', 'Deselect', Icons.deselect, section: clipSection),
        // Loop-recorded takes (lib/model/live_midi.dart): pick the one the clip plays.
        if (clip.takes.length > 1) MenuAction('takes', 'Takes (${clip.takes.length})…', Icons.layers_outlined,
            section: clipSection),
        // Comping (#209): the takes as lanes under the track.
        if (clip.takes.length > 1) MenuAction('take-lanes', layer.showTakes ? 'Hide take lanes' : 'Take lanes',
            Icons.view_agenda_outlined, checked: layer.showTakes, section: clipSection),
        if (widget.onOpenPattern != null) const MenuAction('edit', 'Open in Build', Icons.open_in_new,
            section: clipSection),
        const MenuAction('copy', 'Duplicate independently', Icons.copy, section: edit),
        const MenuAction('linked', 'Duplicate linked', Icons.link, section: edit),
        if (canSplitHere) const MenuAction('split-here', 'Split at the playhead', Icons.content_cut, section: edit),
        if (canSplit && !clip.lock) const MenuAction('split', 'Split at time selection', Icons.content_cut,
            section: edit),
        MenuAction('loop', clip.loop ? 'Disable clip looping' : 'Enable clip looping', Icons.loop, checked: clip.loop,
            section: edit),
        // The length in bars, on the grid's beats; applied when the slider is let go (it rebuilds the project).
        if (!clip.lock) MenuAction('length', 'Length (bars)', Icons.straighten, section: size, number: MenuNumber(
          value: clip.lengthSteps / bar, min: 1 / s.project.beatsPerBar,
          max: math.max(64.0, clip.lengthSteps / bar).ceilToDouble(),
          defaultValue: patternBars,
          format: (b) => b == b.roundToDouble() ? b.toInt().toString() : b.toStringAsFixed(2),
          onChangeEnd: (b) {
            s.resizeClip(layer, clip, math.max(1, (b * bar).round()));
            s.endUndoStep();
          })),
        // The clip's own loop point (owner, 2026-11-11; the piano roll's loop bar sets it too): in bars, whole steps.
        MenuAction('loop-length', 'Loop length…', Icons.repeat, section: size, number: MenuNumber(
          value: s.project.clipLoopSteps(clip) / bar, min: 1 / bar,
          max: math.max(16.0, s.project.clipLoopSteps(clip) / bar).ceilToDouble(),
          defaultValue: patternBars,
          format: (b) => b == b.roundToDouble() ? b.toInt().toString() : b.toStringAsFixed(2),
          onChangeEnd: (b) => s.setClipLoop(layer, clip, math.max(1, (b * bar).round())))),
        if (clip.loopSteps != null)
          const MenuAction('loop-reset', 'Reset loop to pattern length', Icons.restart_alt, section: size),
        const MenuAction('midi', 'Export as MIDI file', Icons.file_upload_outlined, section: more),
        // Freeze and bounce (owner, 2026-11-14): the selection's clips on this track, or this clip.
        if (s.canRenderTrack(layer)) const MenuAction('bounce', 'Bounce to audio', Icons.graphic_eq_rounded,
            section: more),
        // Consolidate (#209): the selection's clips on this track joined into one clip.
        if (consolidate.length >= 2) MenuAction('consolidate', 'Consolidate ${consolidate.length} clips',
            Icons.join_full, section: more),
        if (!clip.lock) const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true, section: more),
      ]);
    if (v == null || !mounted) return;
    if (v == 'select') {
      final adding = !s.selectedClipIds.contains(clip.id) || !_selectMode;
      setState(() => _selectMode = true);
      if (adding && !s.selectedClipIds.contains(clip.id)) s.toggleClipSelection(layer, clip);
      if (!adding) s.toggleClipSelection(layer, clip);
    }
    if (v == 'properties') {
      if (!s.selectedClipIds.contains(clip.id)) s.selectClip(layer, clip);
      await showClipProperties(context, s);
      return;
    }
    if (v == 'split-here' || v == 'split') {
      s.selectClip(layer, clip);
      s.splitClips(at: v == 'split' ? splitAt : playhead);
    }
    if (v == 'bounce') {
      final chosen = s.selectedClipIds.contains(clip.id)
          ? [for (final c in layer.clips) if (s.selectedClipIds.contains(c.id)) c] : [clip];
      await runTrackRender(context, 'Bounce ${chosen.length == 1 ? s.clipName(clip) : '${chosen.length} clips'}',
          () => s.bounceClips(layer, chosen));
      return;
    }
    if (v == 'notes') {
      if (!await editableOrUnfreeze(context, s, layer) || !mounted) return;
      s.activateClip(layer, clip);
      _focus(layer.id, tab: FocusTab.clip);
    }
    if (v == 'takes') return showTakePicker(context, s, layer, clip, at);
    if (v == 'take-lanes') toggleTakeLanes(s, layer);
    if (v == 'consolidate' && !s.consolidateMidiClips(layer, consolidate)) Haptics.error();
    if (v == 'edit') { s.activateClip(layer, clip); widget.onOpenPattern?.call(); }
    if (v == 'copy') s.duplicateClip(layer, clip);
    if (v == 'linked') s.duplicateClip(layer, clip, linked: true);
    if (v == 'loop') s.editLayer(layer, (l) => clip.loop = !clip.loop);
    if (v == 'loop-reset') s.setClipLoop(layer, clip, null);
    if (v == 'midi') await exportClipAsMidi(context, s, clip);
    if (v == 'delete') s.removeClip(layer, clip);
  }

  _TrackCallbacks _callbacks(List<ModuleDoc> patterns) => _TrackCallbacks(
    // A tap only selects the track (owner, 2026-11-12); a double tap opens its main editor.
    onTap: (l) => widget.state.selectLayer(l),
    onFx: (l) => _openTrack(l, tab: FocusTab.fx),
    onMenu: (l, at) => _trackMenu(l, at, patterns),
    onClipMenu: _clipMenu,
    // A mouse's double-click on a MIDI clip opens its notes, as the menu's Edit notes does.
    onClipOpen: (l, c) async {
      if (!await editableOrUnfreeze(context, widget.state, l) || !mounted) return;
      widget.state.activateClip(l, c);
      _focus(l.id, tab: FocusTab.clip);
    },
    onAudioOpen: (l) => _focus(l.id, tab: FocusTab.clip),
    selectMode: () => _selectMode,
    guides: _guides,
    onMarquee: (phase, at, additive) => switch (phase) {
      _Marquee.start => _marqueeStart(at, additive: additive),
      _Marquee.move => _marqueeMove(at),
      _Marquee.end => _marqueeEnd(),
    },
  );
}
