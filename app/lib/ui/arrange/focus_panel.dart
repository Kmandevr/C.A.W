// The focus view's panel for one track (owner, 2026-11-09): tabs FX, Mixer, Clip and Automation, under or beside the tracks.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project.dart';
import '../../model/settings.dart';
import '../automation_screen.dart';
import '../feedback.dart';
import '../frame/frame_widgets.dart' show SlideIn;
import '../glass.dart';
import '../haptics.dart';
import '../mixer_screen.dart';
import '../pattern_editor.dart';
import '../theme.dart';
import '../volume_fader.dart';
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
    this.browsing = false,
    this.onBrowse,
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

  /// The Files browser is open beside the panel; [onBrowse] opens or closes it (drag effects into the FX stack).
  final bool browsing;
  final VoidCallback? onBrowse;

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
          if (onBrowse != null)
            IconButton(key: const ValueKey('focus-browse'), tooltip: 'Files: drag effects or patterns here',
              iconSize: 18, onPressed: onBrowse, color: browsing ? Neon.blue : null, icon: const Icon(Icons.folder_open)),
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
            // On the fader's dB taper: the knob turns through fader positions; double-tap is 0 dB.
            Knob(key: const ValueKey('mix-volume'), value: VolumeTaper.position(layer.volume), min: 0, max: 1,
              defaultValue: VolumeTaper.position(1), label: 'Volume', color: Neon.green, size: 44,
              valueText: (p) => VolumeTaper.label(VolumeTaper.gain(p)),
              onChanged: (p) => state.mixLayer(layer, volume: VolumeTaper.gain(p))),
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

/// Landscape and desktop: the tracks with the focus panel on the right. On a phone in landscape the panel takes
/// [Settings.focusPanelShare] of the width (two thirds by default, owner 2026-11-10) and its left edge drags: the
/// edge grows when grabbed, a ghost shows where the panel will land with its share, it snaps to a half and two thirds
/// with a tick, and the share is saved on release (double-tap: back to two thirds). Desktop keeps 34% (320 to 480 dp).
class FocusSidePane extends StatefulWidget {
  const FocusSidePane({super.key, required this.settings, required this.tracks, required this.panel, this.desktop = false});
  final Settings settings;
  final Widget tracks, panel;
  final bool desktop;

  /// The shares a drag snaps to, and how close (as a share) counts as on one.
  static const snaps = [0.5, 2 / 3];
  static const snapReach = 0.025;

  /// The narrowest the tracks get beside the panel, in logical pixels.
  static const minTracks = 120.0;

  @override
  State<FocusSidePane> createState() => _FocusSidePaneState();
}

class _FocusSidePaneState extends State<FocusSidePane> {
  double? _from, _ghost; // the share at the drag's start, and where it would land now
  double? _snap;

  Settings get settings => widget.settings;

  double _snapped(double share) {
    for (final s in FocusSidePane.snaps) {
      if ((share - s).abs() <= FocusSidePane.snapReach) return s;
    }
    return share;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final total = box.maxWidth;
        final maxShare = ((total - FocusSidePane.minTracks) / total).clamp(0.0, Settings.maxFocusPanelShare);
        double widthOf(double share) => (total * share.clamp(Settings.minFocusPanelShare, maxShare)).toDouble();
        final w = widget.desktop
            ? math.min((total * 0.34).clamp(320.0, 480.0).toDouble(), total - FocusSidePane.minTracks)
            : widthOf(settings.focusPanelShare);
        final pane = SizedBox(
          width: w,
          child: SlideIn(from: const Offset(0.12, 0), child: Padding(
            padding: EdgeInsets.fromLTRB(widget.desktop ? 4 : 0, 0, 4, 4), child: widget.panel)),
        );
        if (widget.desktop) {
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: widget.tracks), pane]);
        }
        final ghost = _ghost;
        final edge = DragEdge(
          key: const ValueKey('focus-panel-edge'),
          axis: Axis.horizontal,
          label: 'Resize the panel',
          thickness: 14,
          hot: _snap != null,
          onStart: () => setState(() {
            _from = settings.focusPanelShare;
            _ghost = _from;
          }),
          onDrag: (moved) {
            final from = _from;
            if (from == null) return;
            final raw = (from - moved / total).clamp(Settings.minFocusPanelShare, maxShare).toDouble();
            final at = _snapped(raw);
            final snap = at == raw ? null : at;
            if (snap != null && snap != _snap) Haptics.tick();
            setState(() {
              _ghost = at;
              _snap = snap;
            });
          },
          onEnd: () {
            final at = _ghost;
            setState(() => _from = _ghost = _snap = null);
            if (at != null && at != settings.focusPanelShare) settings.update((s) => s.focusPanelShare = at);
          },
          onReset: () {
            Haptics.tick();
            settings.update((s) => s.focusPanelShare = Settings.defaultFocusPanelShare);
          },
        );
        return Stack(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: widget.tracks),
            edge,
            pane,
          ]),
          // Where the panel will land: a ghost of its edge and area, with its share, until the drag ends.
          if (ghost != null)
            Positioned(
              key: const ValueKey('focus-panel-ghost'),
              top: 0,
              bottom: 4,
              right: 4,
              width: widthOf(ghost),
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Neon.blue.withValues(alpha: 0.08),
                    border: Border(left: BorderSide(color: (_snap != null ? Neon.green : Neon.blue).withValues(alpha: 0.9), width: 2)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.only(top: 48),
                  child: Text(
                    _snap == 2 / 3 ? '⅔' : _snap == 0.5 ? '½' : '${(ghost * 100).round()}%',
                    style: Neon.code(size: 13, color: _snap != null ? Neon.green : Neon.blue),
                  ),
                ),
              ),
            ),
        ]);
      });
}
