// Mixer / Editor: detailed channel controls and the shared module inspector.
// All edits flow through AppState; this screen does not own a second mix or processing model.
import 'package:flutter/material.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import 'param_control.dart';
import 'theme.dart';
import 'widgets.dart';

class MixerScreen extends StatelessWidget {
  const MixerScreen({super.key, required this.state, required this.onOpenBuilder});
  final AppState state;
  final VoidCallback onOpenBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final columns = constraints.maxWidth >= 1100 ? 4 : constraints.maxWidth >= 680 ? 2 : 1;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
      const Text('MIXER / EDITOR', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.w900, fontSize: 12)),
      const Text('Shared project channels · live engine controls', style: TextStyle(color: Neon.dim, fontSize: 11)),
      const SizedBox(height: 12),
      NeonPanel(color: Neon.pink, child: ValueListenableBuilder<int>(
        valueListenable: state.values,
        builder: (context, _, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('MASTER OUTPUT', style: TextStyle(color: Neon.pink, fontWeight: FontWeight.w800))),
            Text((state.project.master * 100).round().toString() + '%', style: Neon.code(color: Neon.pink)),
          ]),
          Slider(value: state.project.master.clamp(0.0, 1.0), min: 0, max: 1, activeColor: Neon.pink,
            onChanged: (v) => state.editProject((p) => p.master = v)),
          Text('Peak L ' + state.meters.peakL.toStringAsFixed(3) + '   Peak R ' + state.meters.peakR.toStringAsFixed(3),
            style: Neon.code(size: 12, color: Neon.dim)),
        ]),
      )),
      const SizedBox(height: 14),
      const Text('CHANNELS', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (state.project.layers.isEmpty)
        const NeonPanel(child: Text('No channels yet. Add a track in Arranger.'))
      else
        GridView.builder(
          shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          itemCount: state.project.layers.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns, crossAxisSpacing: 10, mainAxisSpacing: 10, mainAxisExtent: 224),
          itemBuilder: (context, index) => _ChannelStrip(state: state, layer: state.project.layers[index], index: index),
        ),
      const SizedBox(height: 16),
      _ModuleInspector(state: state, onOpenBuilder: onOpenBuilder),
    ]);
  });
}

class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({required this.state, required this.layer, required this.index});
  final AppState state;
  final LayerDoc layer;
  final int index;

  @override
  Widget build(BuildContext context) => NeonPanel(color: Neon.layer(layer.color), padding: const EdgeInsets.all(10),
    child: ValueListenableBuilder<int>(valueListenable: state.values, builder: (context, _, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800))),
          IconButton(tooltip: layer.mute ? 'Unmute' : 'Mute', visualDensity: VisualDensity.compact,
            onPressed: () => state.mixLayer(layer, mute: !layer.mute),
            icon: Icon(Icons.volume_off, color: layer.mute ? Neon.pink : Neon.dim)),
          IconButton(tooltip: layer.solo ? 'Unsolo' : 'Solo', visualDensity: VisualDensity.compact,
            onPressed: () => state.mixLayer(layer, solo: !layer.solo),
            icon: Icon(Icons.headphones, color: layer.solo ? Neon.yellow : Neon.dim)),
        ]),
        Text(layer.generatorId == null ? 'No generator' : (state.project.module(layer.generatorId)?.name ?? 'Missing generator'),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: Neon.code(size: 11, color: Neon.dim)),
        const SizedBox(height: 6),
        ValueListenableBuilder<int>(valueListenable: state.tick, builder: (context, _, _) {
          final meter = index < state.layerMeters.length ? state.layerMeters[index] : null;
          return Bar(value: meter?.peak ?? 0, color: Neon.green, height: 6);
        }),
        const Spacer(),
        Row(children: [
          const SizedBox(width: 48, child: Text('LEVEL', style: TextStyle(color: Neon.dim, fontSize: 10))),
          Expanded(child: Slider(value: layer.volume.clamp(0.0, 1.0), min: 0, max: 1, activeColor: Neon.green,
            onChanged: (v) => state.mixLayer(layer, volume: v))),
          SizedBox(width: 38, child: Text((layer.volume * 100).round().toString(),
            textAlign: TextAlign.end, style: Neon.code(size: 11, color: Neon.green))),
        ]),
        Row(children: [
          const SizedBox(width: 48, child: Text('PAN', style: TextStyle(color: Neon.dim, fontSize: 10))),
          Expanded(child: Slider(value: layer.pan.clamp(-1.0, 1.0), min: -1, max: 1, activeColor: Neon.blue,
            onChanged: (v) => state.mixLayer(layer, pan: v))),
          SizedBox(width: 38, child: Text(layer.pan.abs() < .01 ? 'C' :
            (layer.pan.abs() * 100).round().toString() + (layer.pan < 0 ? 'L' : 'R'),
            textAlign: TextAlign.end, style: Neon.code(size: 11, color: Neon.blue))),
        ]),
      ],
    )),
  );
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
          ValueListenableBuilder<int>(valueListenable: state.values, builder: (context, _, _) => ParamGroups(
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
