// The focus view's panel for one track (owner, 2026-11-09): tabs FX, Mixer, Clip and Automation, under or beside the tracks.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project.dart';
import '../automation_screen.dart';
import '../glass.dart';
import '../mixer_screen.dart';
import '../pattern_editor.dart';
import '../theme.dart';
import 'track_color.dart';
import 'fx_stack.dart';
import 'knob.dart';

enum FocusTab { fx, mixer, clip, automation }

extension FocusTabInfo on FocusTab {
  String get label => switch (this) {
        FocusTab.fx => 'FX',
        FocusTab.mixer => 'Mixer',
        FocusTab.clip => 'Clip',
        FocusTab.automation => 'Automation',
      };
  IconData get icon => switch (this) {
        FocusTab.fx => Icons.graphic_eq,
        FocusTab.mixer => Icons.tune,
        FocusTab.clip => Icons.piano,
        FocusTab.automation => Icons.timeline,
      };
}

class FocusPanel extends StatelessWidget {
  const FocusPanel({
    super.key,
    required this.state,
    required this.layer,
    required this.tab,
    required this.onTab,
    required this.onClose,
    this.onPrevious,
    this.onNext,
    this.onOpenModule,
    this.bottomSheetStyle = false,
    this.expanded = false,
    this.onExpand,
  });

  final AppState state;
  final LayerDoc layer;
  final FocusTab tab;
  final ValueChanged<FocusTab> onTab;
  final VoidCallback onClose;
  final VoidCallback? onPrevious, onNext;
  final ValueChanged<String>? onOpenModule;

  /// Phone portrait: the panel sits under the pinned track, with a handle; swiping its header down closes it.
  final bool bottomSheetStyle;

  /// Phone portrait: the panel opened up over the pinned track ([onExpand] true), or under it.
  final bool expanded;
  final ValueChanged<bool>? onExpand;

  @override
  Widget build(BuildContext context) {
    final color = trackColor(state, layer);
    final header = GestureDetector(
      key: const ValueKey('focus-panel-header'),
      behavior: HitTestBehavior.opaque,
      // Swipe up to open the panel higher (over the pinned track), down to lower it again or close it.
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -250 && onExpand != null && !expanded) onExpand!(true);
        if (v > 250) expanded && onExpand != null ? onExpand!(false) : onClose();
      },
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (bottomSheetStyle)
          Padding(padding: const EdgeInsets.only(top: 5), child: Container(width: 36, height: 4,
            decoration: BoxDecoration(color: Neon.dim.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(2)))),
        SizedBox(height: 40, child: Row(children: [
          IconButton(tooltip: 'Previous track', iconSize: 18, onPressed: onPrevious, icon: const Icon(Icons.chevron_left)),
          Container(width: 4, height: 16, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Flexible(child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color))),
          IconButton(tooltip: 'Next track', iconSize: 18, onPressed: onNext, icon: const Icon(Icons.chevron_right)),
          const Spacer(),
          if (onExpand != null)
            IconButton(key: const ValueKey('focus-expand'), tooltip: expanded ? 'Lower the panel' : 'Open the panel higher',
              iconSize: 18, onPressed: () => onExpand!(!expanded),
              icon: Icon(expanded ? Icons.unfold_less : Icons.unfold_more)),
          IconButton(key: const ValueKey('focus-close'), tooltip: 'All tracks', iconSize: 18, onPressed: onClose,
            icon: Icon(bottomSheetStyle ? Icons.keyboard_arrow_down : Icons.close)),
        ])),
        SizedBox(height: 36, child: Row(children: [
          for (final t in FocusTab.values)
            Expanded(child: _TabButton(tab: t, selected: t == tab, color: color, onTap: () => onTab(t))),
        ])),
      ]),
    );
    return GlassPanel(
      key: const ValueKey('focus-panel'),
      tint: color,
      radius: 12,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
        Expanded(child: switch (tab) {
          FocusTab.fx => FxStack(key: ValueKey('fx-${layer.id}'), state: state, layer: layer, onOpenModule: onOpenModule),
          FocusTab.mixer => _MixerTab(state: state, layer: layer),
          FocusTab.clip => _ClipTab(state: state, layer: layer),
          FocusTab.automation => TrackAutomationPanel(state: state, layer: layer),
        }),
      ]),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.tab, required this.selected, required this.color, required this.onTap});
  final FocusTab tab;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      key: ValueKey('focus-tab-${tab.name}'),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(
          color: selected ? color : Colors.transparent, width: 2))),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(tab.icon, size: 16, color: selected ? color : Neon.dim),
          const SizedBox(width: 4),
          Flexible(child: Text(tab.label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: selected ? Neon.text : Neon.dim))),
        ]),
      ),
    ),
  );
}

/// The track's strip from the Mixer, with big volume and pan knobs beside it.
class _MixerTab extends StatelessWidget {
  const _MixerTab({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final h = box.maxHeight < 440 ? 440.0 : box.maxHeight;
    return SingleChildScrollView(child: SizedBox(height: h, child: Padding(
      padding: const EdgeInsets.all(8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ChannelStrip(state: state, layer: layer, index: state.project.layers.indexOf(layer), onSlot: (_) {}),
        const SizedBox(width: 12),
        Expanded(child: ValueListenableBuilder<int>(
          valueListenable: state.layerValueTick(layer.id),
          builder: (context, _, _) => Wrap(spacing: 8, runSpacing: 8, children: [
            Knob(key: const ValueKey('mix-volume'), value: layer.volume, min: 0, max: 1, defaultValue: 0.8,
              label: 'Volume', color: Neon.green, size: 44,
              valueText: (v) => '${(v * 100).round()}%',
              onChanged: (v) => state.mixLayer(layer, volume: v)),
            Knob(key: const ValueKey('mix-pan'), value: layer.pan, min: -1, max: 1, defaultValue: 0,
              label: 'Pan', color: Neon.blue, size: 44,
              valueText: (v) => v.abs() < .01 ? 'C' : '${(v.abs() * 100).round()}${v < 0 ? 'L' : 'R'}',
              onChanged: (v) => state.mixLayer(layer, pan: v)),
          ]),
        )),
      ]),
    )));
  });
}

/// The selected clip's notes in the pattern editor (the one Sounds uses), or a way to add a clip.
class _ClipTab extends StatelessWidget {
  const _ClipTab({required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) {
    final clip = layer.clips.where((c) => c.id == state.selectedClipId).firstOrNull ?? layer.clips.firstOrNull;
    final module = state.project.module(clip?.patternId);
    if (layer.isFolder) {
      return const Center(child: Text('Folders hold tracks, not clips.', style: TextStyle(color: Neon.dim)));
    }
    if (clip == null || module == null) {
      final patterns = state.project.modules.where((m) => state.isPattern(m.id)).toList();
      return ListView(padding: const EdgeInsets.all(12), children: [
        Text(clip == null ? 'No clip on this track yet.' : 'This clip\'s pattern is missing.',
          style: const TextStyle(color: Neon.dim)),
        const SizedBox(height: 8),
        for (final p in patterns)
          ListTile(dense: true, leading: const Icon(Icons.add, size: 18), title: Text('Add clip · ${p.name}'),
            onTap: () => state.addClip(layer, p.id)),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (layer.clips.length > 1)
        SizedBox(height: 36, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 6),
          children: [
            for (final c in layer.clips)
              Padding(padding: const EdgeInsets.only(right: 4), child: ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text('${state.project.module(c.patternId)?.name ?? '?'} · ${c.startSteps ~/ state.project.stepsPerBar + 1}',
                  style: const TextStyle(fontSize: 10)),
                selected: c.id == clip.id,
                onSelected: (_) => state.selectClip(layer, c))),
          ])),
      Expanded(child: PatternEditor(key: ValueKey('clip-${module.id}'), state: state, module: module)),
    ]);
  }
}
