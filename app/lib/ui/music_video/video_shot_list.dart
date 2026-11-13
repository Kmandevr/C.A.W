// The music video's shot list (owner, 2026-11-12): each shot's start, length, view and layout, effects and transition,
// and the chosen shot's editor: split presets with draggable dividers, a view and look per panel, the effect stack
// (in the FX stack's card style) with beat presets, how the shot begins (the transition picker) and its keyframed
// camera.
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../model/music_video.dart';
import '../../model/music_video_director.dart' show VideoTransition;
import '../../model/music_video_edit.dart';
import '../../model/music_video_overlay.dart';
import '../../model/music_video_scene.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'video_kit.dart';

/// How the list's controls change the shots: [edit] is one undoable change (saved at once); a slider or divider
/// drag calls [begin], then [live] as it moves (redrawn, not saved), then [end].
abstract class VideoEditHost {
  void edit(VoidCallback change);

  /// Adds an effect of [kind] to [effects] (Strobe asks first, once, about photosensitivity).
  Future<void> addEffect(List<VideoEffect> effects, VideoEffectKind kind);
  void begin();
  void live(VoidCallback change);
  void end();
  void split();
  void duplicate();
  void delete();
}

/// The parts of a shot's editor: where it is, its layout and views, its look, its effects, how it begins, its camera,
/// and the split, duplicate and delete buttons.
enum ShotPart {
  span, layout, look, effects, transition, camera, actions;

  static const all = {span, layout, look, effects, transition, camera, actions};

  /// What the tabbed sheet's Shots tab opens in a row (the look and effects have their own tab).
  static const shots = {span, layout, transition, camera, actions};
}

class ShotList extends StatelessWidget {
  const ShotList({super.key, required this.timeline, required this.scene, required this.snap, required this.selected,
      required this.onSelect, required this.host, required this.aspect, required this.start, required this.end,
      this.parts = ShotPart.all});
  final Set<ShotPart> parts;
  final VideoTimeline timeline;
  final VideoScene scene;
  final VideoSnap snap;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final VideoEditHost host;
  final double aspect, start, end;

  @override
  Widget build(BuildContext context) {
    final spb = scene.stepsPerBar;
    if (timeline.isEmpty) {
      return const VideoNote('No shots yet: the auto director cuts the video. Auto-cut fills the lane with shots to '
          'edit, or Add puts one at the cursor.');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < timeline.cuts.length; i++)
        KeyedSubtree(
          key: ValueKey('video-shot-row-${timeline.cuts[i].id}'),
          child: VideoAppear(child: _ShotRow(
            index: i, cut: timeline.cuts[i], spb: spb, open: timeline.cuts[i].id == selected,
            outside: timeline.cuts[i].end <= start || timeline.cuts[i].start >= end,
            onTap: () {
              Haptics.tap();
              onSelect(timeline.cuts[i].id == selected ? null : timeline.cuts[i].id);
            },
            editor: timeline.cuts[i].id == selected
                ? ShotEditor(cut: timeline.cuts[i], timeline: timeline, scene: scene, snap: snap, host: host,
                    aspect: aspect, start: start, end: end, parts: parts)
                : null,
          )),
        ),
    ]);
  }
}

class _ShotRow extends StatelessWidget {
  const _ShotRow({required this.index, required this.cut, required this.spb, required this.open, required this.onTap,
      required this.editor, required this.outside});
  final int index;
  final VideoCut cut;
  final int spb;
  final bool open, outside;
  final VoidCallback onTap;
  final Widget? editor;

  @override
  Widget build(BuildContext context) {
    final view = cut.layout.panels.first.view;
    final color = videoViewColor(view);
    final level = Motion.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AnimatedOpacity(
        duration: Motion.fade(Motion.small, level),
        opacity: outside ? 0.5 : 1,
        child: AnimatedContainer(
          duration: Motion.fade(Motion.small, level),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: open ? color : Colors.white.withValues(alpha: 0.08), width: open ? 1.6 : 1),
            boxShadow: open ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10)] : null,
          ),
          child: GlassPanel(radius: 10, tint: color, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InkWell(
              key: ValueKey('video-shot-${cut.id}'),
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(height: 46, child: Row(children: [
                const SizedBox(width: 8),
                Container(width: 4, height: 22, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                SizedBox(width: 22, child: Text('${index + 1}', style: Neon.code(size: 11, color: Neon.dim))),
                Icon(videoViewIcon(view), size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(cut.layout.summary, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  Text(
                    [
                      '${videoBarBeat(cut.start, spb)} → ${videoBarBeat(cut.end, spb)}',
                      videoLength(cut.length, spb),
                      if (cut.effects.isNotEmpty) '${cut.effects.length} FX',
                      if (cut.effects.any((e) => e.flashes)) '⚠ Strobe',
                      cut.animateLayout ? 'animate' : cut.transition.label.toLowerCase(),
                      if (cut.camera != null) 'camera',
                      if (cut.texts.isNotEmpty) '${cut.texts.length} text',
                      if (cut.reason.isNotEmpty) cut.reason,
                    ].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9.5, color: Neon.dim)),
                ])),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: Motion.move(Motion.standard, level),
                  child: const Icon(Icons.expand_more, size: 18, color: Neon.dim),
                ),
                const SizedBox(width: 8),
              ])),
            ),
            VideoReveal(editor == null ? null : Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: editor)),
          ])),
        ),
      ),
    );
  }
}

/// The chosen shot's editor.
class ShotEditor extends StatefulWidget {
  const ShotEditor({super.key, required this.cut, required this.timeline, required this.scene, required this.snap,
      required this.host, required this.aspect, required this.start, required this.end, this.parts = ShotPart.all});
  final Set<ShotPart> parts;
  final VideoCut cut;
  final VideoTimeline timeline;
  final VideoScene scene;
  final VideoSnap snap;
  final VideoEditHost host;
  final double aspect, start, end;

  @override
  State<ShotEditor> createState() => _ShotEditorState();
}

class _ShotEditorState extends State<ShotEditor> {
  int _panel = 0;

  VideoCut get c => widget.cut;
  VideoEditHost get h => widget.host;
  int get spb => widget.scene.stepsPerBar;

  @override
  Widget build(BuildContext context) {
    final panel = c.layout.panels[_panel.clamp(0, c.layout.panels.length - 1)];
    final g = widget.snap.grid(spb);
    final parts = widget.parts;
    // A shot wholly outside the range (the song got shorter, or the range is a loop or selection) keeps its place.
    final inRange = c.start < widget.end && c.end > widget.start;
    final diagram = LayoutDiagram(layout: c.layout, aspect: widget.aspect, selected: _panel, host: h,
        onPanel: (i) => setState(() => _panel = i));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (parts.contains(ShotPart.span)) ...[
        _label('SPAN'),
        VideoReveal(inRange ? null : const VideoNote('This shot lies outside the range: the video doesn\'t show it, and its '
            'span is kept as it is.')),
        Row(children: [
          Expanded(child: _Stepper(keyPrefix: 'video-start', label: 'Start', value: videoBarBeat(c.start, spb),
              onDown: !inRange ? null : () => h.edit(() => widget.timeline.setSpan(c.id, start: c.start - g, snap: widget.snap, stepsPerBar: spb,
                  lo: widget.start, hi: widget.end)),
              onUp: !inRange ? null : () => h.edit(() => widget.timeline.setSpan(c.id, start: c.start + g, snap: widget.snap, stepsPerBar: spb,
                  lo: widget.start, hi: widget.end)))),
          const SizedBox(width: 8),
          Expanded(child: _Stepper(keyPrefix: 'video-length', label: 'Length', value: videoLength(c.length, spb),
              onDown: !inRange || c.length <= g ? null : () => h.edit(() => widget.timeline.setSpan(c.id, length: c.length - g,
                  snap: widget.snap, stepsPerBar: spb, lo: widget.start, hi: widget.end)),
              onUp: !inRange ? null : () => h.edit(() => widget.timeline.setSpan(c.id, length: c.length + g, snap: widget.snap,
                  stepsPerBar: spb, lo: widget.start, hi: widget.end)))),
        ]),
      ],
      if (parts.contains(ShotPart.layout)) ...[
        _label('LAYOUT'),
        VideoTiles<VideoLayoutPreset>(keyPrefix: 'video-layout', values: VideoLayoutPreset.values, selected: c.layout.preset,
            height: 50, label: (v) => v.label, icon: _presetIcon,
            onPick: (v) => h.edit(() {
                  c.layout = c.layout.withPreset(v);
                  _panel = 0;
                })),
        const SizedBox(height: 8),
        diagram,
        VideoReveal(switchKey: '${c.layout.preset.name}-$_panel', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _label(c.layout.panels.length > 1 ? 'PANEL ${_panel + 1} VIEW' : 'VIEW'),
          VideoTiles<VideoShot>(keyPrefix: 'video-panel-view', values: VideoShot.values, selected: panel.view, height: 50,
              label: (v) => v.label, icon: videoViewIcon, onPick: (v) => h.edit(() => panel.view = v)),
          _PanelOptions(panel: panel, scene: widget.scene, host: h),
          if (parts.contains(ShotPart.look)) ...[
            _label('LOOK'),
            _LookEditor(look: panel.look, host: h),
          ],
        ])),
      ] else if (parts.contains(ShotPart.look)) ...[
        // The Look tab: the panel to restyle, then its look.
        if (c.layout.panels.length > 1) ...[_label('PANEL'), diagram],
        VideoReveal(switchKey: '${c.layout.preset.name}-$_panel', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _label(c.layout.panels.length > 1 ? 'PANEL ${_panel + 1} LOOK · ${panel.view.label.toUpperCase()}'
              : 'LOOK · ${panel.view.label.toUpperCase()}'),
          _LookEditor(look: panel.look, host: h),
        ])),
      ],
      if (parts.contains(ShotPart.effects)) ...[
        _label('EFFECTS'),
        EffectStack(effects: c.effects, scene: widget.scene, host: h, panels: c.layout.panels.length),
      ],
      if (parts.contains(ShotPart.transition)) ...[
        _label('TRANSITION IN'),
        TransitionPicker(cut: c, stepsPerBar: spb, host: h),
        const SizedBox(height: 6),
        VideoTiles<bool>(keyPrefix: 'video-layout-change', values: const [false, true], selected: c.animateLayout,
            height: 40, label: (v) => v ? 'Layout animates' : 'Layout cuts',
            onPick: (v) => h.edit(() {
                  c.animateLayout = v;
                  if (v && c.transitionSteps <= 0) c.transitionSteps = 4;
                })),
        const VideoNote('Animate slides the panels from the last shot\'s places to these, so views that stay never jump.'),
      ],
      if (parts.contains(ShotPart.camera)) ...[
        _label('CAMERA'),
        _CameraEditor(cut: c, host: h),
      ],
      if (parts.contains(ShotPart.actions)) ...[
        const SizedBox(height: 4),
        Wrap(spacing: 4, children: [
          TextButton.icon(key: const ValueKey('video-shot-split'), onPressed: h.split,
              icon: const Icon(Icons.content_cut, size: 16), label: const Text('Split at cursor')),
          TextButton.icon(key: const ValueKey('video-shot-duplicate'), onPressed: h.duplicate,
              icon: const Icon(Icons.copy_all_outlined, size: 16), label: const Text('Duplicate')),
          TextButton.icon(key: const ValueKey('video-shot-delete'), onPressed: h.delete,
              icon: Icon(Icons.delete_outline, size: 16, color: Neon.pink), label: Text('Delete', style: TextStyle(color: Neon.pink))),
        ]),
      ],
    ]);
  }
}

IconData videoTransitionIcon(VideoTransition t) => switch (t) {
      VideoTransition.cut => Icons.content_cut,
      VideoTransition.crossfade => Icons.gradient,
      VideoTransition.push => Icons.keyboard_double_arrow_left,
      VideoTransition.slide => Icons.input,
      VideoTransition.zoom => Icons.zoom_out_map,
      VideoTransition.flash => Icons.flash_on,
      VideoTransition.wipe => Icons.border_left,
      VideoTransition.glitch => Icons.blur_linear,
    };

/// A cut's transition (two rows of four) and its length in beats or bars (owner, 2026-11-12), in the shot editor and
/// in the sheet a cut marker opens.
class TransitionPicker extends StatelessWidget {
  const TransitionPicker({super.key, required this.cut, required this.stepsPerBar, required this.host, this.onChanged});
  final VideoCut cut;
  final int stepsPerBar;
  final VideoEditHost host;
  final VoidCallback? onChanged;

  /// The lengths offered, in steps: half a beat, one, two and three beats, a bar and two bars.
  List<double> get lengths => {2.0, 4.0, 8.0, 12.0, stepsPerBar.toDouble(), stepsPerBar * 2.0}.toList()..sort();

  void _edit(VoidCallback f) {
    host.edit(f);
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = cut;
    const all = VideoTransition.values;
    final flashes = c.transition == VideoTransition.flash || c.transition == VideoTransition.glitch;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var row = 0; row < 2; row++)
        Padding(
          padding: EdgeInsets.only(top: row == 0 ? 0 : 4),
          child: VideoTiles<VideoTransition>(keyPrefix: 'video-transition', values: all.sublist(row * 4, row * 4 + 4),
              selected: c.transition, height: 46, label: (v) => v.label, icon: videoTransitionIcon,
              onPick: (v) => _edit(() {
                    c.transition = v;
                    if (v != VideoTransition.cut && c.transitionSteps <= 0) c.transitionSteps = 4;
                  })),
        ),
      VideoReveal(c.transition == VideoTransition.cut && !c.animateLayout
          ? null
          : Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final l in lengths)
                ChoiceChip(
                  key: ValueKey('video-transition-length-${l.round()}'),
                  label: Text(l == 2 ? '½ beat' : videoLength(l, stepsPerBar), style: const TextStyle(fontSize: 11)),
                  selected: (c.transitionSteps <= 0 ? 4 : c.transitionSteps) == l,
                  showCheckmark: false,
                  selectedColor: videoAccent.withValues(alpha: 0.25),
                  onSelected: (_) => _edit(() => c.transitionSteps = l),
                ),
            ]))),
      VideoReveal(flashes ? const VideoNote('⚠ A flash or glitch at a cut is one burst of light; keep them apart for '
          'viewers sensitive to flashing.') : null),
    ]);
  }
}

/// A shot's camera: the auto camera, or a keyframed move from a start framing to an end one, eased (owner,
/// 2026-11-12).
class _CameraEditor extends StatefulWidget {
  const _CameraEditor({required this.cut, required this.host});
  final VideoCut cut;
  final VideoEditHost host;

  @override
  State<_CameraEditor> createState() => _CameraEditorState();
}

class _CameraEditorState extends State<_CameraEditor> {
  bool _end = true;

  @override
  Widget build(BuildContext context) {
    final c = widget.cut, h = widget.host;
    final move = c.camera;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      VideoTiles<bool>(keyPrefix: 'video-camera', values: const [false, true], selected: move != null, height: 40,
          label: (v) => v ? 'Keyframed' : 'Auto',
          onPick: (v) => h.edit(() => c.camera = v ? VideoCameraMove() : null)),
      VideoReveal(move == null
          ? const VideoNote('The auto camera follows the playhead and eases in from the opening zoom.')
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final e in VideoCameraMove.presets.entries)
                  ActionChip(key: ValueKey('video-camera-preset-${e.key}'), label: Text(e.key, style: const TextStyle(fontSize: 11)),
                      onPressed: () => h.edit(() => c.camera = e.value()..ease = move.ease)),
              ])),
              const SizedBox(height: 6),
              VideoTiles<bool>(keyPrefix: 'video-camera-key', values: const [false, true], selected: _end, height: 32,
                  label: (v) => v ? 'End framing' : 'Start framing', onPick: (v) => setState(() => _end = v)),
              VideoReveal(switchKey: _end, Column(children: [
                for (final (name, label, lo, hi) in [('zoom', 'Zoom', 1.0, 3.0), ('x', 'Across', -0.33, 0.33),
                    ('y', 'Up / down', -0.33, 0.33)])
                  _SliderRow(keyName: 'video-camera-$name', label: label,
                      value: switch (name) { 'zoom' => (_end ? move.to : move.from).zoom, 'x' => (_end ? move.to : move.from).x,
                          _ => (_end ? move.to : move.from).y },
                      min: lo, max: hi, divisions: 40,
                      text: (v) => name == 'zoom' ? '${v.toStringAsFixed(2)}×' : '${(v * 100).round()}%', host: h,
                      onChanged: (v) {
                        final f = _end ? move.to : move.from;
                        final next = VideoFraming(zoom: name == 'zoom' ? v : f.zoom, x: name == 'x' ? v : f.x,
                            y: name == 'y' ? v : f.y).clamped;
                        _end ? move.to = next : move.from = next;
                      }),
              ])),
              VideoTiles<VideoEase>(keyPrefix: 'video-camera-ease', values: VideoEase.values, selected: move.ease, height: 34,
                  label: (v) => v.label, onPick: (v) => h.edit(() => move.ease = v)),
              const VideoNote('The move frames the whole shot from its start to its end; the views still follow the '
                  'song inside it.'),
            ])),
      VideoReveal(move == null
          ? _SliderRow(keyName: 'video-zoom', label: 'Opening zoom', value: c.zoom, min: 0.5, max: 2, divisions: 30,
              text: (v) => '${v.toStringAsFixed(2)}×', host: h, onChanged: (v) => c.zoom = v)
          : null),
    ]);
  }
}

IconData _presetIcon(VideoLayoutPreset p) => switch (p) {
      VideoLayoutPreset.full => Icons.crop_square,
      VideoLayoutPreset.topBottom => Icons.view_agenda_outlined,
      VideoLayoutPreset.sideBySide => Icons.view_column_outlined,
      VideoLayoutPreset.bigStrip => Icons.web_asset,
      VideoLayoutPreset.grid => Icons.grid_view,
    };

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(text, style: TextStyle(fontSize: 9.5, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: videoAccent)),
    );

class _Stepper extends StatelessWidget {
  const _Stepper({required this.keyPrefix, required this.label, required this.value, required this.onDown, required this.onUp});
  final String keyPrefix, label, value;
  final VoidCallback? onDown, onUp;

  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: Neon.line)),
        child: Row(children: [
          IconButton(key: ValueKey('$keyPrefix-down'), onPressed: onDown, iconSize: 16, icon: const Icon(Icons.remove)),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label, style: const TextStyle(fontSize: 8.5, color: Neon.dim)),
            AnimatedSwitcher(
              duration: Motion.fade(Motion.small, Motion.of(context)),
              child: Text(value, key: ValueKey(value), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Neon.code(size: 11, color: Neon.text)),
            ),
          ])),
          IconButton(key: ValueKey('$keyPrefix-up'), onPressed: onUp, iconSize: 16, icon: const Icon(Icons.add)),
        ]),
      );
}

/// A labelled slider whose drag is one undo step.
class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.keyName, required this.label, required this.value, required this.min, required this.max,
      required this.text, required this.host, required this.onChanged, this.divisions});
  final String keyName, label;
  final double value, min, max;
  final int? divisions;
  final String Function(double) text;
  final VideoEditHost host;
  final void Function(double) onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(width: 78, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
        Expanded(child: Slider(
          key: ValueKey(keyName),
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChangeStart: (_) => host.begin(),
          onChanged: (v) => host.live(() => onChanged(v)),
          onChangeEnd: (_) => host.end(),
        )),
        SizedBox(width: 64, child: Text(text(value), textAlign: TextAlign.right, maxLines: 1,
            style: Neon.code(size: 10, color: Neon.text))),
      ]);
}

/// The layout drawn at the video's ratio: tap a panel to edit it, drag a divider to resize.
class LayoutDiagram extends StatelessWidget {
  const LayoutDiagram({super.key, required this.layout, required this.aspect, required this.selected, required this.host,
      required this.onPanel});
  final VideoLayout layout;
  final double aspect;
  final int selected;
  final VideoEditHost host;
  final ValueChanged<int> onPanel;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    return Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 170, maxWidth: 320),
      child: AspectRatio(aspectRatio: aspect, child: LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        final rects = layout.rects();
        return Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: Neon.bg, border: Border.all(color: Neon.line)),
          child: Stack(children: [
            for (var i = 0; i < layout.panels.length && i < rects.length; i++)
              AnimatedPositioned(
                key: ValueKey('diagram-panel-$i'),
                duration: Motion.move(Motion.standard, level),
                curve: Curves.easeOutCubic,
                left: rects[i].left * size.width + 2,
                top: rects[i].top * size.height + 2,
                width: math.max(0, rects[i].width * size.width - 4),
                height: math.max(0, rects[i].height * size.height - 4),
                child: GestureDetector(
                  key: ValueKey('video-layout-panel-$i'),
                  onTap: () {
                    Haptics.tap();
                    onPanel(i);
                  },
                  child: AnimatedContainer(
                    duration: Motion.fade(Motion.small, level),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: videoViewColor(layout.panels[i].view).withValues(alpha: i == selected ? 0.3 : 0.14),
                      border: Border.all(color: videoViewColor(layout.panels[i].view).withValues(alpha: i == selected ? 1 : 0.5),
                          width: i == selected ? 1.6 : 1),
                    ),
                    child: Center(child: FittedBox(child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(videoViewIcon(layout.panels[i].view), size: 16, color: videoViewColor(layout.panels[i].view)),
                        Text(layout.panels[i].view.label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
                      ]),
                    ))),
                  ),
                ),
              ),
            for (final d in layout.dividers())
              Positioned(
                key: ValueKey('diagram-divider-${d.index}'),
                left: d.vertical ? d.at * size.width - 12 : d.from * size.width,
                top: d.vertical ? d.from * size.height : d.at * size.height - 12,
                width: d.vertical ? 24 : (d.to - d.from) * size.width,
                height: d.vertical ? (d.to - d.from) * size.height : 24,
                child: _DividerHandle(
                  key: ValueKey('video-layout-divider-${d.index}'),
                  vertical: d.vertical,
                  onStart: () {
                    Haptics.grab();
                    host.begin();
                  },
                  onMove: (global) {
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(global);
                    host.live(() => layout.setSplit(d.index, d.vertical ? local.dx / size.width : local.dy / size.height));
                  },
                  onEnd: () {
                    Haptics.drop();
                    host.end();
                  },
                  child: Center(child: Container(
                    width: d.vertical ? 4 : 28,
                    height: d.vertical ? 28 : 4,
                    decoration: BoxDecoration(color: Neon.text.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(2)),
                  )),
                ),
              ),
          ]),
        );
      })),
    ));
  }
}

/// A track picker: Auto (the busiest) or one of the scene's tracks.
class _TrackPicker extends StatelessWidget {
  const _TrackPicker({required this.keyName, required this.label, required this.value, required this.scene,
      required this.onChanged, this.auto = 'Auto (busiest)'});
  final String keyName, label;
  final String? value, auto;
  final VideoScene scene;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final tracks = [for (final t in scene.tracks) if (!t.isFolder) t];
    final known = value == null || tracks.any((t) => t.id == value);
    return Row(children: [
      SizedBox(width: 78, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
      Expanded(child: DropdownButton<String?>(
        key: ValueKey(keyName),
        isExpanded: true,
        isDense: true,
        value: known ? value : null,
        items: [
          if (auto != null) DropdownMenuItem<String?>(value: null, child: Text(auto!, style: const TextStyle(fontSize: 12))),
          for (final t in tracks)
            DropdownMenuItem<String?>(value: t.id, child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: Color(t.color), shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Expanded(child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
            ])),
        ],
        onChanged: onChanged,
      )),
    ]);
  }
}

/// A panel's view settings: what it follows, how much it shows, and the falling keyboard's options.
class _PanelOptions extends StatelessWidget {
  const _PanelOptions({required this.panel, required this.scene, required this.host});
  final VideoPanel panel;
  final VideoScene scene;
  final VideoEditHost host;

  @override
  Widget build(BuildContext context) {
    final v = panel.view;
    final timeline = v == VideoShot.flythrough || v == VideoShot.pianoRoll || v == VideoShot.falling;
    final focus = v == VideoShot.pianoRoll || v == VideoShot.mixer || v == VideoShot.devices;
    final spbBars = v == VideoShot.falling ? 2.0 : (v == VideoShot.pianoRoll ? 2.0 : 8.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      VideoReveal(focus
          ? Padding(padding: const EdgeInsets.only(top: 6), child: _TrackPicker(keyName: 'video-panel-track',
              label: 'Follows', value: panel.trackId, scene: scene, onChanged: (t) => host.edit(() => panel.trackId = t)))
          : null),
      VideoReveal(timeline
          ? _SliderRow(keyName: 'video-panel-bars', label: v == VideoShot.falling ? 'Fall (bars)' : 'Shows (bars)',
              value: panel.bars ?? spbBars, min: 0.5, max: 16, divisions: 31, text: (b) => b.toStringAsFixed(1),
              host: host, onChanged: (b) => panel.bars = b)
          : null),
      VideoReveal(v == VideoShot.falling
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(alignment: Alignment.centerLeft, child: VideoPill(key: const ValueKey('video-falling-88'),
                  label: 'ALL 88 KEYS', on: panel.fullKeyboard, onTap: () => host.edit(() => panel.fullKeyboard = !panel.fullKeyboard))),
              const VideoNote('Off, the keyboard spans the notes the shown tracks play.'),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final t in scene.tracks)
                  if (!t.isFolder)
                    VideoPill(key: ValueKey('video-falling-track-${t.id}'), label: t.name.toUpperCase(),
                        on: !panel.hiddenTracks.contains(t.id),
                        onTap: () => host.edit(() => panel.hiddenTracks.contains(t.id)
                            ? panel.hiddenTracks.remove(t.id)
                            : panel.hiddenTracks.add(t.id))),
              ]),
            ])
          : null),
    ]);
  }
}

class _LookEditor extends StatelessWidget {
  const _LookEditor({required this.look, required this.host});
  final VideoLook look;
  final VideoEditHost host;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        VideoTiles<VideoPalette>(keyPrefix: 'video-look-palette', values: VideoPalette.values, selected: look.palette,
            height: 36, label: (v) => v.label, onPick: (v) => host.edit(() => look.palette = v)),
        const SizedBox(height: 6),
        VideoTiles<VideoNoteStyle>(keyPrefix: 'video-look-notes', values: VideoNoteStyle.values, selected: look.noteStyle,
            height: 36, label: (v) => v.label, onPick: (v) => host.edit(() => look.noteStyle = v)),
        const SizedBox(height: 6),
        VideoTiles<VideoBackground>(keyPrefix: 'video-look-bg', values: VideoBackground.values, selected: look.background,
            height: 36, label: (v) => v.label, onPick: (v) => host.edit(() => look.background = v)),
        Row(children: [
          VideoPill(key: const ValueKey('video-look-grid'), label: 'GRID', on: look.grid,
              onTap: () => host.edit(() => look.grid = !look.grid)),
          const SizedBox(width: 8),
          Expanded(child: _SliderRow(keyName: 'video-look-glow', label: 'Glow', value: look.glow, min: 0,
              max: VideoLook.maxGlow, divisions: 20, text: (v) => '${(v * 100).round()}%', host: host,
              onChanged: (v) => look.glow = v)),
        ]),
      ]);
}

/// A shot's effect stack, in the FX stack's style: cards to reorder, bypass and remove, each with its amount, what
/// drives it and its settings.
class EffectStack extends StatelessWidget {
  const EffectStack({super.key, required this.effects, required this.scene, required this.host, this.panels = 1});
  final List<VideoEffect> effects;
  final VideoScene scene;
  final VideoEditHost host;

  /// The shot's layout's places, for each effect's target.
  final int panels;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (effects.isEmpty) const VideoNote('None. Effects run top to bottom over the whole shot.'),
        if (effects.isNotEmpty)
          ReorderableListView(
            key: const ValueKey('video-fx-list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (from, to) => host.edit(() {
              final e = effects.removeAt(from);
              effects.insert(to.clamp(0, effects.length), e);
            }),
            children: [
              for (var i = 0; i < effects.length; i++)
                KeyedSubtree(key: ObjectKey(effects[i]), child: VideoAppear(child: _EffectCard(
                    index: i, effect: effects[i], scene: scene, host: host, panels: panels,
                    onRemove: () => host.edit(() => effects.removeAt(i))))),
            ],
          ),
        Align(alignment: Alignment.centerLeft, child: PopupMenuButton<VideoEffectKind>(
          key: const ValueKey('video-fx-add'),
          tooltip: 'Add an effect',
          onSelected: (k) => host.addEffect(effects, k),
          enabled: effects.length < kVideoMaxEffects,
          itemBuilder: (_) => [
            for (final k in VideoEffectKind.values)
              PopupMenuItem(value: k, key: ValueKey('video-fx-add-${k.name}'), child: ListTile(dense: true,
                  trailing: k == VideoEffectKind.strobe ? Icon(Icons.warning_amber_rounded, size: 18, color: Neon.yellow) : null,
                  title: Text(k.label), subtitle: Text(k.description, style: const TextStyle(fontSize: 10)))),
          ],
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 18, color: Neon.green),
            const SizedBox(width: 6),
            Text('Effect', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w700)),
          ])),
        )),
      ]);
}

class _EffectCard extends StatelessWidget {
  const _EffectCard({required this.index, required this.effect, required this.scene, required this.host,
      required this.onRemove, this.panels = 1});
  final int index, panels;
  final VideoEffect effect;
  final VideoScene scene;
  final VideoEditHost host;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final e = effect;
    final color = e.on ? videoAccent : Neon.dim;
    final level = Motion.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AnimatedOpacity(
        duration: Motion.fade(Motion.small, level),
        opacity: e.on ? 1 : 0.55,
        child: GlassPanel(radius: 10, tint: color, child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 4, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 36, child: Row(children: [
              ReorderableDragStartListener(index: index, child: const Tooltip(message: 'Drag to reorder',
                  child: SizedBox(width: 36, height: 36, child: Icon(Icons.drag_indicator, size: 18, color: Neon.dim)))),
              Container(width: 4, height: 18, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.kind.label, maxLines: 1, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                Text(e.flashes ? '⚠ Flashes: take care with photosensitive viewers' : e.kind.description, maxLines: 1,
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, color: e.flashes ? Neon.yellow : Neon.dim)),
              ])),
              IconButton(key: ValueKey('video-fx-on-$index'), tooltip: e.on ? 'Bypass' : 'Turn on', iconSize: 18,
                  color: e.on ? Neon.green : Neon.dim, onPressed: () => host.edit(() => e.on = !e.on),
                  icon: const Icon(Icons.power_settings_new)),
              IconButton(key: ValueKey('video-fx-remove-$index'), tooltip: 'Remove', iconSize: 18, color: Neon.dim,
                  onPressed: onRemove, icon: const Icon(Icons.close)),
            ])),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              VideoReveal(panels > 1
                  ? Padding(padding: const EdgeInsets.only(bottom: 4), child: VideoTiles<int>(
                      keyPrefix: 'video-fx-target-$index', values: [-1, for (var k = 0; k < panels; k++) k],
                      selected: e.panelIn(panels) ?? -1, height: 32,
                      label: (v) => v < 0 ? 'Whole shot' : 'Panel ${v + 1}',
                      onPick: (v) => host.edit(() => e.panel = v < 0 ? null : v)))
                  : null),
              _SliderRow(keyName: 'video-fx-amount-$index', label: 'Amount', value: e.amount, min: 0, max: 1, divisions: 20,
                  text: (v) => '${(v * 100).round()}%', host: host, onChanged: (v) => e.amount = v),
              // The beat presets (owner, 2026-11-12): one tap sets the drive, its pulse and the amount.
              SizedBox(height: 36, child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final pr in VideoEffectPreset.values)
                  Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(
                    key: ValueKey('video-fx-preset-$index-${pr.name}'),
                    label: Text(pr.label, style: const TextStyle(fontSize: 10.5)),
                    selected: VideoEffectPreset.of(e) == pr,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    selectedColor: videoAccent.withValues(alpha: 0.25),
                    onSelected: (_) => host.edit(() => pr.apply(e)),
                  )),
              ])),
              const SizedBox(height: 4),
              for (var row = 0; row < 2; row++)
                Padding(padding: EdgeInsets.only(top: row * 4.0), child: VideoTiles<VideoDrive>(
                    keyPrefix: 'video-fx-drive-$index', values: VideoDrive.values.sublist(row * 3, row * 3 + 3),
                    selected: e.drive, height: 32, label: (v) => v.label, onPick: (v) => host.edit(() => e.drive = v))),
              VideoReveal(e.drive == VideoDrive.track
                  ? _TrackPicker(keyName: 'video-fx-track-$index', label: 'Track', value: e.trackId, scene: scene,
                      auto: null, onChanged: (t) => host.edit(() => e.trackId = t))
                  : null),
              VideoReveal(VideoEffectPreset.beats(e.drive)
                  ? _SliderRow(keyName: 'video-fx-decay-$index', label: 'Pulse', value: e.decay, min: 0.05, max: 1,
                      divisions: 19, text: (v) => '${(v * 100).round()}%', host: host, onChanged: (v) => e.decay = v)
                  : null),
              VideoReveal(e.kind == VideoEffectKind.tint || e.kind == VideoEffectKind.strobe
                  ? Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 8, children: [
                      for (final col in VideoEffectColor.values)
                        GestureDetector(
                          key: ValueKey('video-fx-color-$index-${col.name}'),
                          onTap: () => host.edit(() => e.color = col),
                          child: AnimatedContainer(
                            duration: Motion.fade(Motion.small, level),
                            width: 24, height: 24,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _swatch(col),
                              border: Border.all(color: e.color == col ? Neon.text : Colors.transparent, width: 2),
                            ),
                          ),
                        ),
                    ]))
                  : null),
            ])),
          ]),
        )),
      ),
    );
  }
}

Color _swatch(VideoEffectColor c) => switch (c) {
      VideoEffectColor.accent => Neon.pink,
      VideoEffectColor.blue => Neon.blue,
      VideoEffectColor.green => Neon.green,
      VideoEffectColor.yellow => Neon.yellow,
      VideoEffectColor.violet => Neon.violet,
      VideoEffectColor.white => Colors.white,
    };

/// A divider's grip: it takes drags across its line only (sideways for a vertical divider, up and down for a
/// horizontal one), so the sheet still scrolls the other way.
class _DividerHandle extends StatelessWidget {
  const _DividerHandle({super.key, required this.vertical, required this.onStart, required this.onMove, required this.onEnd,
      required this.child});
  final bool vertical;
  final VoidCallback onStart, onEnd;
  final ValueChanged<Offset> onMove;
  final Widget child;

  @override
  Widget build(BuildContext context) => vertical
      ? GestureDetector(behavior: HitTestBehavior.opaque, dragStartBehavior: DragStartBehavior.down, onHorizontalDragStart: (_) => onStart(),
          onHorizontalDragUpdate: (d) => onMove(d.globalPosition), onHorizontalDragEnd: (_) => onEnd(),
          onHorizontalDragCancel: onEnd, child: child)
      : GestureDetector(behavior: HitTestBehavior.opaque, dragStartBehavior: DragStartBehavior.down, onVerticalDragStart: (_) => onStart(),
          onVerticalDragUpdate: (d) => onMove(d.globalPosition), onVerticalDragEnd: (_) => onEnd(),
          onVerticalDragCancel: onEnd, child: child);
}
