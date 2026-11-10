// Arrange's mixer card (phone, owner 2026-11-09): a glass card over the tracks with narrow strips; tap one to widen it.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project.dart';
import '../glass.dart';
import '../mixer_screen.dart';
import '../theme.dart';
import '../widgets.dart';

class MixerCard extends StatefulWidget {
  const MixerCard({super.key, required this.state, required this.onClose, this.onSlot});
  final AppState state;
  final VoidCallback onClose;

  /// A chain slot of a widened strip was tapped (Arrange opens that track's FX).
  final void Function(LayerDoc layer, String moduleId)? onSlot;

  @override
  State<MixerCard> createState() => _MixerCardState();
}

class _MixerCardState extends State<MixerCard> {
  String? _wide;

  /// The full strip needs this much height; a shorter card scrolls up and down.
  static const _stripHeight = 440.0;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final layers = s.project.layers.where((l) => !l.isFolder || l.busEnabled).toList();
    return GlassOverlay(
      key: const ValueKey('mixer-card'),
      radius: 14,
      child: Column(children: [
        SizedBox(height: 36, child: Row(children: [
          const SizedBox(width: 12),
          const Text('MIXER', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
          const Spacer(),
          IconButton(tooltip: 'Close mixer', iconSize: 18, onPressed: widget.onClose, icon: const Icon(Icons.close)),
        ])),
        Expanded(child: LayoutBuilder(builder: (context, box) {
          final h = math.max(_stripHeight, box.maxHeight);
          return SingleChildScrollView(child: SizedBox(height: h, child: layers.isEmpty
            ? const Center(child: Text('Add a track to mix it.', style: TextStyle(color: Neon.dim)))
            : ListView(
                key: const ValueKey('mixer-card-strips'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                children: [
                  for (final l in layers)
                    Padding(padding: const EdgeInsets.only(right: 4), child: AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      child: _wide == l.id
                          ? ChannelStrip(key: ValueKey('wide-${l.id}'), state: s, layer: l,
                              index: s.project.layers.indexOf(l),
                              onSlot: (id) => widget.onSlot?.call(l, id))
                          : _NarrowStrip(state: s, layer: l, index: s.project.layers.indexOf(l),
                              onTap: () => setState(() => _wide = l.id)),
                    )),
                ],
              )));
        })),
      ]),
    );
  }
}

/// A narrow strip: the track's colour and name, a fader with its meter, M and S. Tap the name to widen it.
class _NarrowStrip extends StatelessWidget {
  const _NarrowStrip({required this.state, required this.layer, required this.index, required this.onTap});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = Neon.layer(layer.color);
    return SizedBox(width: 52, child: GlassPanel(tint: tint, radius: 8, child: ValueListenableBuilder<int>(
      valueListenable: state.layerValueTick(layer.id),
      builder: (context, _, _) => Column(children: [
        Semantics(button: true, label: 'Widen ${layer.name}', child: InkWell(
          key: ValueKey('narrow-${layer.id}'),
          onTap: onTap,
          child: Container(
            height: 40,
            decoration: BoxDecoration(border: Border(top: BorderSide(color: tint, width: 3))),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(layer.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
          ),
        )),
        Expanded(child: Row(children: [
          Expanded(child: RotatedBox(quarterTurns: 3, child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(
              value: layer.volume.clamp(0.0, 1.0).toDouble(),
              activeColor: tint,
              semanticFormatterCallback: (v) => '${layer.name} level ${(v * 100).round()}%',
              onChanged: (v) => state.mixLayer(layer, volume: v)),
          ))),
          SizedBox(width: layer.isStereo ? 9 : 6, child: TrackMeter(state: state, index: index, stereo: layer.isStereo,
            color: tint, vertical: true)),
          const SizedBox(width: 4),
        ])),
        Text('${(layer.volume * 100).round()}%', style: Neon.code(size: 9, color: Neon.dim)),
        const SizedBox(height: 2),
        ToggleChip(label: 'M', size: 34, on: layer.mute, color: Neon.yellow,
          tooltip: layer.mute ? 'Unmute ${layer.name}' : 'Mute ${layer.name}',
          onTap: () => layer.isFolder ? state.editLayer(layer, (l) => l.mute = !l.mute) : state.mixLayer(layer, mute: !layer.mute)),
        const SizedBox(height: 3),
        ToggleChip(label: 'S', size: 34, on: layer.solo, color: Neon.blue,
          tooltip: layer.solo ? 'Unsolo ${layer.name}' : 'Solo ${layer.name}',
          onTap: () => layer.isFolder ? state.editLayer(layer, (l) => l.solo = !l.solo) : state.mixLayer(layer, solo: !layer.solo)),
        const SizedBox(height: 6),
      ]),
    )));
  }
}
