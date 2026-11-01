// Mixer / Editor: detailed channel controls and the shared module inspector.
// All edits flow through AppState; this screen does not own a second mix or processing model.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';

class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  double _inspectorFraction = 0.34;
  int _mobilePage = 0;
  final FocusNode _dividerFocusNode = FocusNode(debugLabel: 'Mixer inspector width');

  @override
  void dispose() {
    _dividerFocusNode.dispose();
    super.dispose();
  }

  void _adjustInspector(double delta) {
    setState(() {
      _inspectorFraction = (_inspectorFraction + delta).clamp(0.24, 0.52).toDouble();
    });
  }

  Widget _channelPanel(int columns) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('CHANNELS', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (widget.state.project.layers.isEmpty)
        const NeonPanel(child: Text('No channels yet. Add a track in Arranger.'))
      else
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.state.project.layers.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 280,
          ),
          itemBuilder: (context, index) => _ChannelStrip(
            state: widget.state,
            layer: widget.state.project.layers[index],
            index: index,
          ),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final wide = constraints.maxWidth >= 1200;
    final columns = constraints.maxWidth >= 1100 ? 3 : constraints.maxWidth >= 680 ? 2 : 1;
    final s = widget.state;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
      const Text('MIXER / EDITOR', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w900, fontSize: 12)),
      const Text('Shared project channels · live engine controls', style: TextStyle(color: Neon.dim, fontSize: 11)),
      const SizedBox(height: 12),
      NeonPanel(color: Neon.pink, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ValueListenableBuilder<int>(
          valueListenable: s.masterValueTick,
          builder: (context, _, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('MASTER OUTPUT', style: TextStyle(color: Neon.pink, fontWeight: FontWeight.w800))),
              Text('${(s.project.master * 100).round()}%', style: Neon.code(color: Neon.pink)),
            ]),
            Slider(value: s.project.master.clamp(0.0, 1.0).toDouble(), min: 0, max: 1,
              activeColor: Neon.pink, onChanged: s.setMaster),
          ]),
        ),
        const SizedBox(height: 4),
        Row(children: [
          const SizedBox(width: 20, child: Text('L', style: TextStyle(color: Neon.blue, fontSize: 10))),
          Expanded(child: PeakMeter(state: s, read: () => s.meters.peakL, color: Neon.blue)),
          const SizedBox(width: 48, child: Text('R', style: TextStyle(color: Neon.green, fontSize: 10))),
          Expanded(child: PeakMeter(state: s, read: () => s.meters.peakR, color: Neon.green)),
        ]),
        ValueListenableBuilder<int>(
          valueListenable: s.tick,
          builder: (context, _, _) => Text(
            'Peak L ${s.meters.peakL.toStringAsFixed(3)}   Peak R ${s.meters.peakR.toStringAsFixed(3)}',
            style: Neon.code(size: 11, color: Neon.dim)),
        ),
      ])),
      const SizedBox(height: 14),
      if (wide)
        LayoutBuilder(builder: (context, inner) {
          final dividerWidth = 12.0;
          final available = inner.maxWidth - dividerWidth;
          final inspectorWidth = available * _inspectorFraction;
          final channelWidth = available - inspectorWidth;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: channelWidth, child: _channelPanel(columns)),
            Focus(
              focusNode: _dividerFocusNode,
              onFocusChange: (_) => setState(() {}),
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                  _adjustInspector(0.02);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  _adjustInspector(-0.02);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Semantics(
                container: true,
                focused: _dividerFocusNode.hasFocus,
                label: 'Mixer inspector width',
                value: '${(_inspectorFraction * 100).round()} percent',
                increasedValue: '${((_inspectorFraction + 0.02).clamp(0.24, 0.52) * 100).round()} percent',
                decreasedValue: '${((_inspectorFraction - 0.02).clamp(0.24, 0.52) * 100).round()} percent',
                onIncrease: () => _adjustInspector(0.02),
                onDecrease: () => _adjustInspector(-0.02),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (details) => _adjustInspector(-details.delta.dx / available),
                    child: SizedBox(width: dividerWidth, height: 520,
                      child: Center(child: Container(width: 2, height: 72,
                        decoration: BoxDecoration(color: Neon.blue, borderRadius: BorderRadius.circular(2)))),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: inspectorWidth,
              child: _ModuleInspector(state: s, onOpenBuilder: widget.onOpenBuilder)),
          ]);
        })
      else ...[
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Channels'), icon: Icon(Icons.tune)),
            ButtonSegment(value: 1, label: Text('Focused editor'), icon: Icon(Icons.edit_note)),
          ],
          selected: {_mobilePage},
          showSelectedIcon: false,
          onSelectionChanged: (value) => setState(() => _mobilePage = value.first),
        ),
        const SizedBox(height: 12),
        if (_mobilePage == 0)
          if (s.project.layers.isEmpty)
            const NeonPanel(child: Text('No channels yet. Add a track in Arranger.'))
          else
            for (var i = 0; i < s.project.layers.length; i++)
              _MobileChannelRow(
                state: s,
                layer: s.project.layers[i],
                index: i,
                selected: s.selectedLayerId == s.project.layers[i].id,
                onSelect: () => setState(() {
                  s.selectLayer(s.project.layers[i]);
                  _mobilePage = 1;
                }),
              )
        else
          _MobileFocusedEditor(state: s, onOpenBuilder: widget.onOpenBuilder),
      ],
    ]);
  });
}

class _MobileChannelRow extends StatelessWidget {
  const _MobileChannelRow({
    required this.state,
    required this.layer,
    required this.index,
    required this.selected,
    required this.onSelect,
  });
  final AppState state;
  final LayerDoc layer;
  final int index;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: NeonPanel(
      color: selected ? Neon.blue : Neon.layer(layer.color),
      padding: const EdgeInsets.all(10),
      child: ValueListenableBuilder<int>(
        valueListenable: state.layerValueTick(layer.id),
        builder: (context, _, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: InkWell(
              onTap: onSelect,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            )),
            IconButton(tooltip: layer.mute ? 'Unmute' : 'Mute',
              onPressed: () => state.mixLayer(layer, mute: !layer.mute),
              icon: Icon(Icons.volume_off, color: layer.mute ? Neon.pink : Neon.dim)),
            IconButton(tooltip: layer.solo ? 'Unsolo' : 'Solo',
              onPressed: () => state.mixLayer(layer, solo: !layer.solo),
              icon: Icon(Icons.headphones, color: layer.solo ? Neon.yellow : Neon.dim)),
            IconButton(tooltip: 'Open focused channel editor', onPressed: onSelect,
              icon: const Icon(Icons.chevron_right, color: Neon.blue)),
          ]),
          Row(children: [
            const SizedBox(width: 48, child: Text('LEVEL', style: TextStyle(color: Neon.dim, fontSize: 10))),
            Expanded(child: Slider(value: layer.volume.clamp(0.0, 1.0).toDouble(), min: 0, max: 1,
              activeColor: Neon.green, onChanged: (v) => state.mixLayer(layer, volume: v))),
            SizedBox(width: 38, child: Text('${(layer.volume * 100).round()}%',
              textAlign: TextAlign.end, style: Neon.code(size: 11, color: Neon.green))),
          ]),
          Row(children: [
            const SizedBox(width: 48, child: Text('PAN', style: TextStyle(color: Neon.dim, fontSize: 10))),
            Expanded(child: Slider(value: layer.pan.clamp(-1.0, 1.0).toDouble(), min: -1, max: 1,
              activeColor: Neon.blue, onChanged: (v) => state.mixLayer(layer, pan: v))),
            SizedBox(width: 38, child: Text(layer.pan.abs() < .01 ? 'C' :
              '${(layer.pan.abs() * 100).round()}${layer.pan < 0 ? 'L' : 'R'}',
              textAlign: TextAlign.end, style: Neon.code(size: 11, color: Neon.blue))),
          ]),
          PeakMeter(key: ValueKey(layer.id), state: state,
            read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0,
            color: Neon.green),
        ]),
      ),
    ),
  );
}

class _MobileFocusedEditor extends StatelessWidget {
  const _MobileFocusedEditor({required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final layers = state.project.layers;
      final selected = layers.where((layer) => layer.id == state.selectedLayerId).firstOrNull ?? layers.firstOrNull;
      if (selected == null) {
        return const NeonPanel(child: Text('Add a track in Arranger to open its focused editor.'));
      }
      final index = layers.indexOf(selected);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NeonPanel(color: Neon.blue, child: DropdownButton<String>(
          value: selected.id,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          items: [for (final layer in layers) DropdownMenuItem(value: layer.id, child: Text(layer.name))],
          onChanged: (id) {
            final layer = layers.where((item) => item.id == id).firstOrNull;
            if (layer != null) state.selectLayer(layer);
          },
        )),
        const SizedBox(height: 10),
        SizedBox(height: 340, child: _ChannelStrip(state: state, layer: selected, index: index)),
        const SizedBox(height: 12),
        _ModuleInspector(state: state, onOpenBuilder: onOpenBuilder),
      ]);
    },
  );
}

class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({required this.state, required this.layer, required this.index});
  final AppState state;
  final LayerDoc layer;
  final int index;

  @override
  Widget build(BuildContext context) {
    final folders = state.project.layers.where((item) => item.isFolder && item.id != layer.id).toList();
    final routeId = folders.any((folder) => folder.id == layer.parentId) ? layer.parentId : null;
    return NeonPanel(
      color: state.selectedLayerId == layer.id ? Neon.blue : Neon.layer(layer.color),
      padding: const EdgeInsets.all(10),
      child: ValueListenableBuilder<int>(
        valueListenable: state.layerValueTick(layer.id),
        builder: (context, _, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: InkWell(
                onTap: () => state.selectLayer(layer),
                child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              )),
              IconButton(tooltip: layer.mute ? 'Unmute' : 'Mute', onPressed: () => state.mixLayer(layer, mute: !layer.mute),
                icon: Icon(Icons.volume_off, color: layer.mute ? Neon.pink : Neon.dim)),
              IconButton(tooltip: layer.solo ? 'Unsolo' : 'Solo', onPressed: () => state.mixLayer(layer, solo: !layer.solo),
                icon: Icon(Icons.headphones, color: layer.solo ? Neon.yellow : Neon.dim)),
            ]),
            if (layer.isFolder)
              Row(children: [
                const Expanded(child: Text('GROUP BUS', style: TextStyle(color: Neon.dim, fontSize: 10))),
                Switch.adaptive(
                  value: layer.busEnabled,
                  onChanged: (v) => state.setFolderBus(layer, v),
                ),
              ])
            else ...[
              if (layer.chain.isEmpty)
                const Text('No generator or effects', style: TextStyle(color: Neon.dim, fontSize: 11))
              else
                Wrap(spacing: 4, runSpacing: 2, children: [
                  for (final id in layer.chain)
                    ActionChip(
                      label: Text(state.project.module(id)?.name ?? 'Missing module',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
                      onPressed: () { state.selectLayer(layer); state.selectModule(id); },
                      side: const BorderSide(color: Neon.line),
                      backgroundColor: Neon.panelHi,
                    ),
                ]),
              Row(children: [
                const SizedBox(width: 48, child: Text('ROUTE', style: TextStyle(color: Neon.dim, fontSize: 10))),
                Expanded(child: DropdownButton<String?>(
                  value: routeId,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Master')),
                    for (final folder in folders)
                      DropdownMenuItem<String?>(value: folder.id, child: Text(folder.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (id) { state.moveLayerIntoFolder(layer, id); },
                )),
              ]),
            ],
            const SizedBox(height: 6),
            PeakMeter(key: ValueKey(layer.id), state: state,
              read: () => index < state.layerMeters.length ? state.layerMeters[index].peak : 0.0,
              color: Neon.green),
            const Spacer(),
            Row(children: [
              const SizedBox(width: 48, child: Text('LEVEL', style: TextStyle(color: Neon.dim, fontSize: 10))),
              Expanded(child: Slider(value: layer.volume.clamp(0.0, 1.0).toDouble(), min: 0, max: 1,
                activeColor: Neon.green, onChanged: (v) => state.mixLayer(layer, volume: v))),
              SizedBox(width: 38, child: Text((layer.volume * 100).round().toString(),
                textAlign: TextAlign.end, style: Neon.code(size: 11, color: Neon.green))),
            ]),
            Row(children: [
              const SizedBox(width: 48, child: Text('PAN', style: TextStyle(color: Neon.dim, fontSize: 10))),
              Expanded(child: Slider(value: layer.pan.clamp(-1.0, 1.0).toDouble(), min: -1, max: 1,
                activeColor: Neon.blue, onChanged: (v) => state.mixLayer(layer, pan: v))),
              SizedBox(width: 38, child: Text(layer.pan.abs() < .01 ? 'C' :
                (layer.pan.abs() * 100).round().toString() + (layer.pan < 0 ? 'L' : 'R'),
                textAlign: TextAlign.end, style: Neon.code(size: 11, color: Neon.blue))),
            ]),
          ],
        ),
      ),
    );
  }
}

class _ModuleInspector extends StatelessWidget {
  const _ModuleInspector({required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) {
    final layer = state.project.layers.where((l) => l.id == state.selectedLayerId).firstOrNull;
    final id = state.project.module(state.selectedModuleId) != null
      ? state.selectedModuleId : layer?.generatorId ?? layer?.effectIds.firstOrNull;
    final module = state.project.module(id);
    final info = id == null ? null : state.info[id];
    return NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('MODULE INSPECTOR', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800))),
        TextButton.icon(onPressed: module == null ? null : onOpenBuilder,
          icon: const Icon(Icons.open_in_new, size: 16), label: const Text('Open in Builder')),
      ]),
      if (module == null)
        const Text('Select a generator, effect or instrument in Builder to inspect its parameters.')
      else ...[
        Text(module.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        Text(info?.summary.isNotEmpty == true ? info!.summary : state.kindOf(module.id),
          style: const TextStyle(color: Neon.dim)),
        const SizedBox(height: 8),
        if (info == null || !info.ok)
          Text(info?.error ?? 'Module has not compiled. Run it in Builder to expose engine parameters.',
            style: const TextStyle(color: Neon.pink))
        else if (info.params.isEmpty)
          const Text('This module exposes no parameters.', style: TextStyle(color: Neon.dim))
        else
          ValueListenableBuilder<int>(valueListenable: state.moduleValueTick(module.id), builder: (context, _, _) => ParamGroups(
            params: info.params, valueOf: (p) => module.params[p.name] ?? p.defaultValue,
            color: state.isEffect(module.id) ? Neon.pink : Neon.green,
            onChanged: (p, v) => state.setParam(module.id, p.name, v))),
        if (module.edited)
          const Padding(padding: EdgeInsets.only(top: 8), child: Text(
            'Source has unrun edits. Run in Builder before expecting them in playback.',
            style: TextStyle(color: Neon.yellow, fontSize: 12))),
      ],
    ]));
  }
}
