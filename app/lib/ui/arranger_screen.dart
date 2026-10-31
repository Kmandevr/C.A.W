// Arranger: project settings (BPM with tap, meter, loop length, key, seed) and the loop stack of layers.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/project.dart';
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';


class ArrangerScreen extends StatefulWidget {
  const ArrangerScreen({super.key, required this.state, this.onOpenPattern});
  final AppState state;
  final VoidCallback? onOpenPattern;
  @override
  State<ArrangerScreen> createState() => _ArrangerScreenState();
}

class _ArrangerScreenState extends State<ArrangerScreen> {
  bool mixer = false, settings = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final stepW = Neon.compact(context) ? 14.0 : 18.0;
    final headW = Neon.compact(context) ? 158.0 : 184.0;
    final end = p.layers.fold<int>(p.loopSteps, (v, l) =>
      l.clips.fold<int>(v, (e, c) => math.max(e, c.startSteps + c.lengthSteps)));
    final width = math.max(560.0, end * stepW);
    final patterns = p.modules.where((m) => s.isPattern(m.id)).toList();
    final visible = s.visibleLayers;
    final selectedLayer = p.layers.where((l) => l.id == s.selectedLayerId).firstOrNull;
    final selectedClip = selectedLayer?.clips.where((c) => c.id == s.selectedClipId).firstOrNull;
    final splitAt = s.timeSelectionEnd;
    return Column(children: [
      if (s.meters.overloaded > 0) _OverloadBanner(state: s),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          const Expanded(child: Text('ARRANGEMENT', style: TextStyle(
            color: Neon.dim, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w800))),
          TextButton.icon(onPressed: p.layers.length >= 64 ? null : s.addLayer,
            icon: const Icon(Icons.add, size: 17), label: const Text('Track')),
          if (selectedLayer != null && selectedClip != null && splitAt != null && splitAt > selectedClip.startSteps && splitAt < selectedClip.startSteps + selectedClip.lengthSteps)
            IconButton(onPressed: () => s.splitClipAt(selectedLayer, selectedClip, splitAt), icon: const Icon(Icons.content_cut), tooltip: 'Split at time selection'),
          DropdownButton<int>(value: s.arrangementSnapSteps, underline: const SizedBox.shrink(),
            items: [for (final v in [1, 2, 4, 8, 16]) DropdownMenuItem(value: v, child: Text('1/${v == 1 ? 16 : 16 ~/ v}'))],
            onChanged: (v) { if (v != null) setState(() => s.arrangementSnapSteps = v); }),
          TextButton.icon(onPressed: p.layers.length >= 64 ? null : s.addFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 17), label: const Text('Folder')),
          IconButton(onPressed: () => setState(() => mixer = !mixer),
            color: mixer ? Neon.blue : Neon.dim, icon: const Icon(Icons.tune), tooltip: 'Mixer'),
          IconButton(onPressed: () => setState(() => settings = !settings),
            color: settings ? Neon.blue : Neon.dim, icon: const Icon(Icons.settings_outlined), tooltip: 'Settings'),
        ]),
      ),
      if (settings) Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Column(children: [
          _ProjectSettings(state: s),
          if (s.globalDefs.isNotEmpty) NeonPanel(color: Neon.blue, child: ParamGroups(
            params: s.globalDefs, color: Neon.blue, valueOf: s.globalValue,
            onChanged: (d, v) => s.setGlobal(d.name, v))),
        ]),
      ),
      Expanded(child: p.layers.isEmpty
        ? const Center(child: Text('Add a track, choose a generator, then add a MIDI clip.'))
        : SingleChildScrollView(child: Column(children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: headW, child: Column(children: [
                const SizedBox(height: 30, child: Padding(
                  padding: EdgeInsets.only(left: 10, top: 8),
                  child: Align(alignment: Alignment.centerLeft,
                    child: Text('TRACKS', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3))))),
                for (final layer in visible)
                  _TimelineHeader(state: s, layer: layer, index: p.layers.indexOf(layer),
                    depth: s.folderDepth(layer), patterns: patterns),
              ])),
              Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal,
                child: SizedBox(width: width, child: Column(children: [
                  SizedBox(height: 30, child: Row(children: [
                    for (var b = 0; b < (end / p.stepsPerBar).ceil(); b++)
                      SizedBox(width: p.stepsPerBar * stepW,
                        child: Align(alignment: Alignment.centerLeft,
                          child: Text('${b + 1}', style: Neon.code(size: 10, color: Neon.dim)))),
                  ])),
                  for (final layer in visible)
                    _TimelineLane(state: s, layer: layer, width: width, stepW: stepW,
                      selectedIds: s.selectedClipIds, onOpen: widget.onOpenPattern),
                ])))),
            ]),
          ]))),
      if (mixer) _ArrangementMixer(state: s),
    ]);
  }
}

class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader({required this.state, required this.layer, required this.index, required this.depth, required this.patterns});
  final AppState state;
  final LayerDoc layer;
  final int index, depth;
  final List<ModuleDoc> patterns;

  @override
  Widget build(BuildContext context) {
    final color = Neon.layer(layer.color);
    final gens = state.project.modules.where((m) => state.isGenerator(m.id)).toList();
    return Container(height: 76 + layer.automation.length * 34, padding: EdgeInsets.fromLTRB(7 + depth * 13, 5, 4, 4),
      decoration: const BoxDecoration(color: Neon.panel,
        border: Border(bottom: BorderSide(color: Neon.line), right: BorderSide(color: Neon.line))),
      child: Column(children: [
        Row(children: [
          if (layer.isFolder)
            IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints.tightFor(width: 22, height: 24),
              icon: Icon(layer.collapsed ? Icons.chevron_right : Icons.expand_more, color: color, size: 18),
              onPressed: () => state.setFolderCollapsed(layer, !layer.collapsed))
          else Container(width: 6, height: 20, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 5),
          Expanded(child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
          PopupMenuButton<String>(padding: EdgeInsets.zero, iconSize: 16,
            onSelected: (v) {
              if (v == 'up' && index > 0) state.moveLayer(index, index - 1);
              if (v == 'down' && index < state.project.layers.length - 1) state.moveLayer(index, index + 2);
              if (v == 'delete') state.removeLayer(layer);
              if (v == 'unparent') state.moveLayerIntoFolder(layer, null);
              if (v.startsWith('parent:')) state.moveLayerIntoFolder(layer, v.substring(7));
              if (v == 'bus') state.setFolderBus(layer, !layer.busEnabled);
              if (v == 'automation-volume') state.addAutomationLane(layer, 'volume');
              if (v == 'automation-pan') state.addAutomationLane(layer, 'pan');
            },
            itemBuilder: (_) => [
              if (index > 0) const PopupMenuItem(value: 'up', child: Text('Move up')),
              if (index < state.project.layers.length - 1) const PopupMenuItem(value: 'down', child: Text('Move down')),
              if (layer.parentId != null) const PopupMenuItem(value: 'unparent', child: Text('Move out of folder')),
              for (final folder in state.project.layers.where((f) => f.isFolder && f.id != layer.id))
                PopupMenuItem(value: 'parent:${folder.id}', child: Text('Move into ${folder.name}')),
              if (layer.isFolder) PopupMenuItem(value: 'bus', child: Text(layer.busEnabled ? 'Disable group bus' : 'Enable group bus')),
              if (!layer.isFolder) const PopupMenuItem(value: 'automation-volume', child: Text('Add volume automation')),
              if (!layer.isFolder) const PopupMenuItem(value: 'automation-pan', child: Text('Add pan automation')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ]),
        ]),
        if (!layer.isFolder) Expanded(child: Row(children: [
          ToggleChip(label: 'M', tooltip: 'Mute', on: layer.mute, color: Neon.yellow,
            onTap: () => state.mixLayer(layer, mute: !layer.mute)),
          const SizedBox(width: 3),
          ToggleChip(label: 'S', tooltip: 'Solo', on: layer.solo, color: Neon.blue,
            onTap: () => state.mixLayer(layer, solo: !layer.solo)),
          const SizedBox(width: 4),
          Expanded(child: DropdownButton<String?>(
            isExpanded: true, value: gens.any((g) => g.id == layer.generatorId) ? layer.generatorId : null,
            hint: const Text('Generator', style: TextStyle(fontSize: 9)),
            underline: const SizedBox.shrink(),
            items: [for (final g in gens) DropdownMenuItem(value: g.id,
              child: Text(g.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9)))],
            onChanged: (id) => state.editLayer(layer, (l) => l.generatorId = id))),
          PopupMenuButton<String>(padding: EdgeInsets.zero, tooltip: 'Add MIDI clip',
            icon: const Icon(Icons.add_box_outlined, color: Neon.blue, size: 17),
            onSelected: (id) => state.addClip(layer, id),
            itemBuilder: (_) => [for (final m in patterns) PopupMenuItem(value: m.id, child: Text(m.name))],
          ),
        ])) else const Expanded(child: Align(alignment: Alignment.centerLeft,
          child: Row(children: [Text(layer.busEnabled ? 'GROUP BUS' : 'GROUP', style: TextStyle(color: Neon.dim, fontSize: 9)), const Spacer(), Icon(Icons.account_tree_outlined, size: 13, color: color)]))),
      ]),
    );
  }
}

class _TimelineLane extends StatelessWidget {
  const _TimelineLane({required this.state, required this.layer, required this.width,
    required this.stepW, required this.selectedIds, this.onOpen});
  final AppState state;
  final LayerDoc layer;
  final double width, stepW;
  final Set<String> selectedIds;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final height = 76.0 + layer.automation.length * 34.0;
    return SizedBox(width: width, height: height,
    child: Stack(children: [
      CustomPaint(size: Size(width, height), painter: _ArrangementGrid(stepW, state.project.stepsPerBar)),
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque,
        onTapUp: (d) { final step = (d.localPosition.dx / stepW).round(); state.setTimeSelection(step, step); },
        onHorizontalDragStart: (d) { final step = (d.localPosition.dx / stepW).round(); state.beginTimeSelection(step); },
        onHorizontalDragUpdate: (d) => state.updateTimeSelection((d.localPosition.dx / stepW).round()),
        onHorizontalDragEnd: (_) => state.endTimeSelection(),
        child: const SizedBox.expand())),
      if (state.timeSelectionStart != null && state.timeSelectionEnd != null)
        Positioned(left: math.min(state.timeSelectionStart!, state.timeSelectionEnd!) * stepW, top: 0,
          width: math.max(1.0, (state.timeSelectionEnd! - state.timeSelectionStart!).abs() * stepW), height: height,
          child: IgnorePointer(child: Container(color: Neon.blue.withValues(alpha: .09)))),

      for (final clip in layer.clips)
        Positioned(left: clip.startSteps * stepW, top: 8,
          width: math.max(12.0, clip.lengthSteps * stepW), height: 60,
          child: _TimelineClip(state: state, layer: layer, clip: clip, stepW: stepW,
            color: Neon.layer(layer.color), selected: selectedIds.contains(clip.id), onOpen: onOpen)),
      if (layer.clips.isEmpty && !layer.isFolder)
        const Positioned(left: 10, top: 29, child: Text('Add MIDI clip with +',
          style: TextStyle(color: Neon.dim, fontSize: 10))),
      for (var i = 0; i < layer.automation.length; i++)
        Positioned(left: 0, right: 0, top: 76 + i * 34.0, height: 34,
          child: _AutomationLaneView(state: state, layer: layer, lane: layer.automation[i], stepW: stepW, width: width)),
    ]),
  );
  }
}

class _ArrangementGrid extends CustomPainter {
  _ArrangementGrid(this.stepW, this.barSteps);
  final double stepW;
  final int barSteps;
  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()..color = Neon.line.withValues(alpha: .55)..strokeWidth = .6;
    final major = Paint()..color = Neon.dim.withValues(alpha: .35)..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += stepW) {
      final n = (x / stepW).round();
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), n % barSteps == 0 ? major : minor);
    }
  }
  @override
  bool shouldRepaint(covariant _ArrangementGrid old) => old.stepW != stepW || old.barSteps != barSteps;
}

class _TimelineClip extends StatefulWidget {
  const _TimelineClip({required this.state, required this.layer, required this.clip,
    required this.stepW, required this.color, required this.selected, this.onOpen});
  final AppState state;
  final LayerDoc layer;
  final ClipDoc clip;
  final double stepW;
  final Color color;
  final bool selected;
  final VoidCallback? onOpen;
  @override
  State<_TimelineClip> createState() => _TimelineClipState();
}

class _TimelineClipState extends State<_TimelineClip> {
  double dx = 0, resizeDx = 0;
  bool dragging = false, resizing = false, sourceDragging = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final length = (c.lengthSteps + (resizing ? (resizeDx / widget.stepW).round() : 0)).clamp(1, 4096 - c.startSteps);
    final name = widget.state.project.module(c.patternId)?.name ?? 'Missing pattern';
    return Transform.translate(offset: Offset(dragging && !sourceDragging ? dx : 0, 0),
      child: Transform.scale(scaleX: resizing ? length / c.lengthSteps : 1.0,
        alignment: Alignment.centerLeft,
        child: Material(color: widget.color.withValues(alpha: widget.selected ? .42 : .23),
          borderRadius: BorderRadius.circular(5),
          child: Stack(children: [
        Positioned.fill(child: GestureDetector(
          onTap: () => widget.state.selectClip(widget.layer, c, additive: HardwareKeyboard.instance.isShiftPressed),
          onDoubleTap: () { widget.state.selectClip(widget.layer, c); widget.onOpen?.call(); },
          onHorizontalDragStart: (_) => setState(() { dragging = true; sourceDragging = HardwareKeyboard.instance.isAltPressed; dx = 0; }),
          onHorizontalDragUpdate: (d) => setState(() => dx += d.delta.dx),
          onHorizontalDragEnd: (_) {
            final raw = (dx / widget.stepW).round();
            final snap = widget.state.arrangementSnapSteps;
            if (sourceDragging) {
              final delta = HardwareKeyboard.instance.isShiftPressed ? raw : (raw / snap).round() * snap;
              widget.state.shiftClipSource(widget.layer, c, delta);
            } else {
              final rawStart = c.startSteps + raw;
              final finalStart = HardwareKeyboard.instance.isShiftPressed ? rawStart : (rawStart / snap).round() * snap;
              widget.state.moveClip(widget.layer, c, finalStart);
            }
            setState(() { dragging = false; sourceDragging = false; dx = 0; });
          },
          child: Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5),
              border: Border.all(color: widget.selected ? widget.color : widget.color.withValues(alpha: .7),
                width: widget.selected ? 1.7 : 1)),
            padding: const EdgeInsets.fromLTRB(7, 4, 13, 3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: widget.color, fontSize: 10, fontWeight: FontWeight.w800))),
                PopupMenuButton<String>(padding: EdgeInsets.zero, iconSize: 14,
                  icon: Icon(Icons.more_horiz, color: widget.color),
                  onSelected: (v) {
                    if (v == 'edit') { widget.state.selectClip(widget.layer, c); widget.onOpen?.call(); }
                    if (v == 'copy') widget.state.duplicateClip(widget.layer, c);
                    if (v == 'linked') widget.state.duplicateClip(widget.layer, c, linked: true);
                    if (v == 'delete') widget.state.removeClip(widget.layer, c);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit pattern')),
                    PopupMenuItem(value: 'copy', child: Text('Duplicate independently')),
                    PopupMenuItem(value: 'linked', child: Text('Duplicate linked')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ]),
              ]),
              Expanded(child: Align(alignment: Alignment.bottomLeft,
                child: Text(c.loop ? 'MIDI · LOOP' : 'MIDI',
                  style: TextStyle(color: widget.color.withValues(alpha: .8), fontSize: 8)))),
            ]),
          ),
        )),
        Positioned(right: 0, top: 0, bottom: 0, width: 12,
          child: GestureDetector(behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() { resizing = true; resizeDx = 0; }),
            onHorizontalDragUpdate: (d) => setState(() => resizeDx += d.delta.dx),
            onHorizontalDragEnd: (_) {
              final snap = widget.state.arrangementSnapSteps;
              final finalLength = HardwareKeyboard.instance.isShiftPressed ? length : math.max(snap, (length / snap).round() * snap);
              widget.state.resizeClip(widget.layer, c, finalLength);
              setState(() { resizing = false; resizeDx = 0; });
            },
            child: Center(child: Container(width: 2, height: 22, color: widget.color)))),
          ]),
        )),
    );
  }
}

class _AutomationLaneView extends StatelessWidget {
  const _AutomationLaneView({required this.state, required this.layer, required this.lane, required this.stepW, required this.width});
  final AppState state;
  final LayerDoc layer;
  final AutomationLaneDoc lane;
  final double stepW, width;

  double _y(double value) => lane.target == 'volume' ? 28 - value * 24 : 16 - value * 12;

  @override
  Widget build(BuildContext context) => Stack(children: [
    GestureDetector(behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final step = (d.localPosition.dx / stepW).clamp(0.0, 4096.0).toDouble();
        final value = (lane.target == 'volume' ? (1 - d.localPosition.dy / 32).clamp(0.0, 1.0)
            : (1 - d.localPosition.dy / 16).clamp(-1.0, 1.0)).toDouble();
        state.addAutomationPoint(layer, lane, step, value);
      },
      child: CustomPaint(size: Size(width, 34), painter: _AutomationCurvePainter(lane, stepW))),
    for (var i = 0; i < lane.points.length; i++)
      Positioned(left: lane.points[i].step * stepW - 5, top: _y(lane.points[i].value) + 2,
        child: GestureDetector(
          onPanUpdate: (d) => state.updateAutomationPoint(layer, lane, i,
            lane.points[i].step + d.delta.dx / stepW,
            lane.points[i].value - d.delta.dy / (lane.target == 'volume' ? 24 : 12)),
          child: Container(width: 10, height: 10, decoration: BoxDecoration(
            color: Neon.blue, shape: BoxShape.circle, border: Border.all(color: Neon.text, width: 1))),
        )),
    Positioned(left: 6, top: 1, child: Text(lane.target.toUpperCase(),
      style: const TextStyle(color: Neon.dim, fontSize: 8, letterSpacing: 1))),
  ]);
}

class _AutomationCurvePainter extends CustomPainter {
  _AutomationCurvePainter(this.lane, this.stepW);
  final AutomationLaneDoc lane;
  final double stepW;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Neon.blue.withValues(alpha: .75)..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < lane.points.length; i++) {
      final p = lane.points[i];
      final y = lane.target == 'volume' ? 28 - p.value * 24 : 16 - p.value * 12;
      final at = Offset(p.step * stepW, y + 7);
      if (i == 0) { path.moveTo(at.dx, at.dy); } else { path.lineTo(at.dx, at.dy); }
    }
    canvas.drawPath(path, paint);
    canvas.drawLine(Offset(0, 33), Offset(size.width, 33), Paint()..color = Neon.line);
  }
  @override
  bool shouldRepaint(covariant _AutomationCurvePainter old) => true;
}

class _ArrangementMixer extends StatelessWidget {
  const _ArrangementMixer({required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => Container(height: 150,
    decoration: const BoxDecoration(color: Neon.panel, border: Border(top: BorderSide(color: Neon.line))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(padding: EdgeInsets.fromLTRB(12, 7, 12, 2),
        child: Text('MIXER', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.4))),
      Expanded(child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final l in state.project.layers.where((x) => !x.isFolder || x.busEnabled))
          SizedBox(width: 150, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Column(children: [
              Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Neon.layer(l.color), fontSize: 11)),
              Expanded(child: ValueListenableBuilder<int>(valueListenable: state.values,
                builder: (context, _, _) => Column(children: [
                  Row(children: [const Icon(Icons.volume_up, size: 13, color: Neon.dim),
                    Expanded(child: Slider(value: l.volume, onChanged: (v) => state.mixLayer(l, volume: v)))]),
                  Row(children: [const Text('L', style: TextStyle(color: Neon.dim, fontSize: 10)),
                    Expanded(child: Slider(value: l.pan, min: -1, max: 1,
                      onChanged: (v) => state.mixLayer(l, pan: v))),
                    const Text('R', style: TextStyle(color: Neon.dim, fontSize: 10))]),
                ]))),
            ]))),
      ])),
    ]),
  );
}

class _OverloadBanner extends StatelessWidget {
  const _OverloadBanner({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: NeonPanel(
          color: Neon.pink,
          child: Row(children: [
            const Icon(Icons.speed, color: Neon.pink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  'Out of headroom: the newest layer${state.meters.overloaded > 1 ? 's were' : ' was'} muted to keep audio clean.'
                  '${state.lightTurnedOnBySelf ? ' Light mode is now on (Settings).' : ''}'),
            ),
            TextButton(onPressed: state.clearOverload, child: const Text('Unmute')),
          ]),
        ),
      );
}

class _ProjectSettings extends StatefulWidget {
  const _ProjectSettings({required this.state});
  final AppState state;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  final List<DateTime> _taps = [];
  late final TextEditingController _seed;

  static const keys = [
    'C major', 'C minor', 'C# minor', 'D major', 'D minor', 'Eb major', 'E minor', 'F major', 'F minor', //
    'F# minor', 'G major', 'G minor', 'A major', 'A minor', 'Bb major', 'B minor', 'None',
  ];

  @override
  void initState() {
    super.initState();
    _seed = TextEditingController(text: widget.state.project.seed.toRadixString(16));
  }

  @override
  void didUpdateWidget(covariant _ProjectSettings old) {
    super.didUpdateWidget(old);
    final hex = widget.state.project.seed.toRadixString(16);
    if (int.tryParse(_seed.text, radix: 16) != widget.state.project.seed) _seed.text = hex;
  }

  @override
  void dispose() {
    _seed.dispose();
    super.dispose();
  }

  void _tap() {
    final now = DateTime.now();
    if (_taps.isNotEmpty && now.difference(_taps.last).inMilliseconds > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 5) _taps.removeAt(0);
    if (_taps.length >= 2) {
      final ms = _taps.last.difference(_taps.first).inMicroseconds / 1000.0 / (_taps.length - 1);
      final bpm = (60000 / ms).clamp(20.0, 400.0);
      widget.state.editProject((p) => p.bpm = double.parse(bpm.toStringAsFixed(1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final bpmText = p.bpm == p.bpm.roundToDouble() ? p.bpm.toStringAsFixed(0) : p.bpm.toStringAsFixed(1);
    return NeonPanel(
      color: Neon.blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton.outlined(
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm - 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.remove)),
          Expanded(
            child: Column(children: [
              Text(bpmText, style: Neon.code(size: 34, color: Neon.blue).copyWith(fontWeight: FontWeight.w700)),
              const Text('BPM', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ]),
          ),
          IconButton.outlined(
              onPressed: () => s.editProject((p) => p.bpm = (p.bpm + 1).clamp(20, 400).roundToDouble()),
              icon: const Icon(Icons.add)),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Neon.blue, minimumSize: const Size(72, 48)),
            onPressed: _tap,
            child: const Text('TAP', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _Labeled(
            'Time',
            DropdownButton<int>(
              value: p.beatsPerBar,
              items: [for (var b = 2; b <= 7; b++) DropdownMenuItem(value: b, child: Text('$b/4'))],
              onChanged: (v) => s.editProject((p) => p.beatsPerBar = v!),
            ),
          ),
          _Labeled(
            'Loop',
            DropdownButton<int>(
              value: p.loopBars,
              items: [
                for (final b in {1, 2, 4, 8, 16, p.loopBars}.toList()..sort())
                  DropdownMenuItem(value: b, child: Text(b == 1 ? '1 bar' : '$b bars')),
              ],
              onChanged: (v) => s.editProject((p) => p.loopBars = v!),
            ),
          ),
          _Labeled(
            'Key',
            DropdownButton<String>(
              value: keys.contains(p.key) ? p.key : 'None',
              items: [for (final k in keys) DropdownMenuItem(value: k, child: Text(k))],
              onChanged: (v) => s.editProject((p) => p.key = v!),
            ),
          ),
          _Labeled(
            'Seed',
            SizedBox(
              width: 92,
              child: TextField(
                controller: _seed,
                style: Neon.code(size: 14),
                decoration: const InputDecoration(prefixText: '0x'),
                onSubmitted: (v) {
                  final n = int.tryParse(v, radix: 16);
                  if (n != null && n >= 0 && n <= 0xFFFFFFFF) s.editProject((p) => p.seed = n);
                },
              ),
            ),
          ),
          Text('${p.loopSeconds.toStringAsFixed(2)} s loop', style: const TextStyle(color: Neon.dim)),
        ]),
        Row(children: [
          const SizedBox(width: 56, child: Text('Master', style: TextStyle(color: Neon.dim))),
          Expanded(
            child: Slider(
              value: p.master,
              activeColor: Neon.blue,
              onChanged: (v) => s.editProject((p) => p.master = v),
            ),
          ),
          SizedBox(width: 120, child: PeakMeter(state: s, read: () => s.meters.peakL > s.meters.peakR ? s.meters.peakL : s.meters.peakR, color: Neon.blue)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          activeThumbColor: Neon.blue,
          title: const Text('Crossfade loop seams'),
          subtitle: const Text('3 ms blend where a layer restarts', style: TextStyle(color: Neon.dim)),
          value: p.seamCrossfade,
          onChanged: (v) => s.editProject((p) => p.seamCrossfade = v),
        ),
      ]),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: const TextStyle(color: Neon.dim)),
        child,
      ]);
}

