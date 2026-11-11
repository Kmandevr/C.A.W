// The marker and region list (REAPER's Region/Marker Manager): every marker and region in time order with its
// position and length; tap one to jump there, long-press for rename, colour, loop, duplicate with clips and delete.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/arrange_edit.dart';
import '../../model/arrange_markers.dart';
import '../../model/project.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';
import '../widgets.dart';
import 'long_press_menu.dart';
import '../pointer_input.dart';

/// "bar.beat" (1-based) of [step].
String barBeat(ProjectDoc p, int step) {
  final beat = p.stepsPerBar ~/ p.beatsPerBar;
  return '${step ~/ p.stepsPerBar + 1}.${step % p.stepsPerBar ~/ (beat < 1 ? 1 : beat) + 1}';
}

/// A length in bars and beats ("4 bars", "2 bars 1 beat", "3 beats").
String barsLength(ProjectDoc p, int steps) {
  final beatSteps = p.stepsPerBar ~/ p.beatsPerBar;
  final bars = steps ~/ p.stepsPerBar, beats = steps % p.stepsPerBar ~/ (beatSteps < 1 ? 1 : beatSteps);
  return [
    if (bars > 0) '$bars bar${bars == 1 ? '' : 's'}',
    if (beats > 0 || bars == 0) '$beats beat${beats == 1 ? '' : 's'}',
  ].join(' ');
}

/// Asks for [m]'s new name and keeps it.
Future<void> renameMarker(BuildContext context, AppState s, MarkerDoc m) async {
  final c = TextEditingController(text: m.name);
  final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
    title: Text(m.isRegion ? 'Rename region' : 'Rename marker'),
    content: TextField(key: const ValueKey('marker-name'), controller: c, autofocus: true,
      onSubmitted: (v) => Navigator.of(context).pop(v)),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      TextButton(onPressed: () => Navigator.of(context).pop(c.text), child: const Text('Rename')),
    ]));
  c.dispose();
  if (name != null) s.editMarker(m, name: name);
}

/// The long-press menu of marker or region [m] (the ruler's and the list's).
Future<void> markerMenu(BuildContext context, AppState s, MarkerDoc m, Offset at) async {
  final v = await showLongPressMenu<String>(context, at: at, title: m.name, style: s.settings.longPressMenu, actions: [
    const MenuAction('rename', 'Rename', Icons.edit_outlined),
    const MenuAction('color', 'Colour', Icons.palette_outlined),
    if (m.isRegion) const MenuAction('loop', 'Loop this region', Icons.repeat),
    if (m.isRegion) const MenuAction('duplicate', 'Duplicate with clips', Icons.copy_all_outlined),
    if (m.isRegion) const MenuAction('select', 'Select its clips', Icons.select_all),
    const MenuAction('list', 'Markers and regions…', Icons.list),
    const MenuAction('delete', 'Delete', Icons.delete_outline, danger: true),
  ]);
  if (v == null || !context.mounted) return;
  switch (v) {
    case 'rename':
      await renameMarker(context, s, m);
    case 'color':
      s.editMarker(m, color: m.color + 1);
    case 'loop':
      s.setLoopRange(m.startSteps, m.endSteps!);
    case 'duplicate':
      // REAPER's duplicate: the copy right after the region, its clips with it.
      if (s.moveRegionWithClips(m, m.endSteps!, copy: true) != null) Haptics.drop();
    case 'select':
      final clips = s.clipsInRegion(m);
      s.selectClipsInBox(clips);
    case 'list':
      await showMarkerList(context, s);
    case 'delete':
      s.removeMarker(m);
  }
}

/// The list in a sheet.
Future<void> showMarkerList(BuildContext context, AppState s) => showGlassSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(child: ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
    child: ListenableBuilder(listenable: s, builder: (context, _) {
      final p = s.project;
      final markers = [for (final m in p.markers) if (!m.isRegion) m]..sort((a, b) => a.startSteps.compareTo(b.startSteps));
      final regions = [for (final m in p.markers) if (m.isRegion) m]..sort((a, b) => a.startSteps.compareTo(b.startSteps));
      Widget row(MarkerDoc m, String lead, String detail) {
        final color = Neon.layer(m.color);
        // A right-click opens the menu a long-press does.
        return Builder(builder: (context) => GestureDetector(
          onSecondaryTap: () => markerMenu(context, s, m, menuAnchorOf(context)),
          child: ListTile(
          key: ValueKey('marker-row-${m.id}'),
          dense: true,
          leading: SizedBox(width: 36, child: Center(child: Text(lead, style: Neon.code(size: 12, color: color)))),
          title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(detail, style: const TextStyle(color: Neon.dim, fontSize: 11)),
          trailing: IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert),
            onPressed: () => markerMenu(context, s, m, menuAnchorOf(context))),
          onTap: () {
            Haptics.tap();
            s.seekTo(m.startSteps.toDouble());
            Navigator.of(context).pop();
          },
          onLongPress: () => markerMenu(context, s, m, menuAnchorOf(context)),
        )));
      }
      return ListView(shrinkWrap: true, children: [
        const Heading('Markers and regions'),
        if (markers.isEmpty && regions.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(
            'None yet: ${PointerInput.hold} the ruler to add a marker or a region (Shift+M, Shift+R).',
            style: const TextStyle(color: Neon.dim))),
        if (markers.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 0), child: Text('MARKERS',
          style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800))),
        // Keys 1–9 and 0 jump to the first ten markers (REAPER's).
        for (var i = 0; i < markers.length; i++)
          row(markers[i], i < 10 ? '${(i + 1) % 10}' : '·', 'At ${barBeat(p, markers[i].startSteps)}'),
        if (regions.isNotEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 0), child: Text('REGIONS',
          style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800))),
        for (final r in regions)
          row(r, 'R', '${barBeat(p, r.startSteps)} to ${barBeat(p, r.endSteps!)} · '
              '${barsLength(p, r.endSteps! - r.startSteps)} · ${s.clipsInRegion(r).length} clips'),
      ]);
    }),
  )),
);
