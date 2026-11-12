// The music video's Text & media tab parts (owner, 2026-11-12): text overlays (title, artist, free text) with size,
// position, colour and in/out animations that can sync to the beat, and the user's images as an overlay or a
// background, for one shot or the whole video; every change is an undo step through the editor's host.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/music_video_edit.dart';
import '../../model/music_video_overlay.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'video_kit.dart';
import 'video_painter.dart' show videoColor;
import 'video_shot_list.dart' show VideoEditHost;

Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(text, style: TextStyle(fontSize: 9.5, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: videoAccent)),
    );

/// A labelled slider whose drag is one undo step.
Widget _slider(VideoEditHost host, String key, String label, double value, double min, double max, String text,
        ValueChanged<double> on, {int? divisions}) =>
    Row(children: [
      SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 11, color: Neon.dim))),
      Expanded(child: Slider(key: ValueKey(key), value: value.clamp(min, max).toDouble(), min: min, max: max,
          divisions: divisions, onChangeStart: (_) => host.begin(), onChanged: (v) => host.live(() => on(v)),
          onChangeEnd: (_) => host.end())),
      SizedBox(width: 54, child: Text(text, textAlign: TextAlign.right, maxLines: 1, style: Neon.code(size: 10, color: Neon.text))),
    ]);

/// Nine places in the frame to put a text or an image (a tap moves it there; the sliders fine-tune).
class _PlacePad extends StatelessWidget {
  const _PlacePad({required this.keyPrefix, required this.x, required this.y, required this.onPick});
  final String keyPrefix;
  final double x, y;
  final void Function(double x, double y) onPick;

  @override
  Widget build(BuildContext context) {
    const at = [0.18, 0.5, 0.82];
    final level = Motion.of(context);
    return SizedBox(width: 78, height: 78, child: Column(children: [
      for (final py in at)
        Expanded(child: Row(children: [
          for (final px in at)
            Expanded(child: GestureDetector(
              key: ValueKey('$keyPrefix-${(px * 100).round()}-${(py * 100).round()}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Haptics.tap();
                onPick(px, py);
              },
              child: Center(child: AnimatedContainer(
                duration: Motion.fade(Motion.small, level),
                width: 14, height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (x - px).abs() < 0.17 && (y - py).abs() < 0.17 ? videoAccent : Colors.white.withValues(alpha: 0.06),
                  border: Border.all(color: Neon.line),
                ),
              )),
            )),
        ])),
    ]));
  }
}

/// The text overlays of a shot or of the whole video, with the presets to add more.
class VideoTextList extends StatelessWidget {
  const VideoTextList({super.key, required this.texts, required this.doc, required this.host, required this.stepsPerBar,
      this.wholeVideo = false, this.start = 0, this.end = 0, this.keyPrefix = 'video-text'});
  final List<VideoText> texts;
  final MusicVideoDoc doc;
  final VideoEditHost host;
  final int stepsPerBar;

  /// Whole-video overlays have their own span; a shot's show through it.
  final bool wholeVideo;
  final double start, end;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (texts.isEmpty)
          VideoNote(wholeVideo ? 'No text over the whole video.' : 'No text over this shot.'),
        for (var i = 0; i < texts.length; i++)
          KeyedSubtree(key: ObjectKey(texts[i]), child: VideoAppear(child: _TextCard(
              text: texts[i], host: host, stepsPerBar: stepsPerBar, wholeVideo: wholeVideo, start: start, end: end,
              keyPrefix: '$keyPrefix-$i', onRemove: () => host.edit(() => texts.removeAt(i))))),
        Align(alignment: Alignment.centerLeft, child: PopupMenuButton<VideoTextPreset>(
          key: ValueKey('$keyPrefix-add'),
          tooltip: 'Add text',
          enabled: texts.length < kVideoMaxTexts,
          onSelected: (p) => host.edit(() => texts.addAll(p.make(() => doc.newOverlayId('t')))),
          itemBuilder: (_) => [
            for (final p in VideoTextPreset.values)
              PopupMenuItem(value: p, key: ValueKey('$keyPrefix-add-${p.name}'), child: ListTile(dense: true,
                  title: Text(p.label), subtitle: Text(p.description, style: const TextStyle(fontSize: 10)))),
          ],
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.text_fields, size: 18, color: Neon.green),
            const SizedBox(width: 6),
            Text('Text', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w700)),
          ])),
        )),
      ]);
}

class _TextCard extends StatefulWidget {
  const _TextCard({required this.text, required this.host, required this.stepsPerBar, required this.wholeVideo,
      required this.start, required this.end, required this.keyPrefix, required this.onRemove});
  final VideoText text;
  final VideoEditHost host;
  final int stepsPerBar;
  final bool wholeVideo;
  final double start, end;
  final String keyPrefix;
  final VoidCallback onRemove;

  @override
  State<_TextCard> createState() => _TextCardState();
}

class _TextCardState extends State<_TextCard> {
  late final _words = TextEditingController(text: widget.text.text);
  bool _open = true;

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.text, h = widget.host, k = widget.keyPrefix, spb = widget.stepsPerBar;
    final level = Motion.of(context);
    final color = videoColor(t.color);
    final title = switch (t.kind) {
      VideoTextKind.free => t.text.isEmpty ? 'Text' : '“${t.text}”',
      _ => t.kind.label,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassPanel(radius: 10, tint: videoAccent, child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 40, child: Row(children: [
            const SizedBox(width: 6),
            Container(width: 4, height: 18, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Expanded(child: InkWell(
              key: ValueKey('$k-open'),
              onTap: () {
                Haptics.tap();
                setState(() => _open = !_open);
              },
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                Text('${t.animIn.label} in · ${t.animOut.label} out${t.beatSync ? ' · on the beat' : ''}', maxLines: 1,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Neon.dim)),
              ]),
            )),
            AnimatedRotation(turns: _open ? 0.5 : 0, duration: Motion.move(Motion.standard, level),
                child: const Icon(Icons.expand_more, size: 18, color: Neon.dim)),
            IconButton(key: ValueKey('$k-remove'), tooltip: 'Remove', iconSize: 18, color: Neon.dim,
                onPressed: widget.onRemove, icon: const Icon(Icons.close)),
          ])),
          VideoReveal(!_open ? null : Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              VideoTiles<VideoTextKind>(keyPrefix: '$k-kind', values: VideoTextKind.values, selected: t.kind, height: 32,
                  label: (v) => v.label, onPick: (v) => h.edit(() => t.kind = v)),
              VideoReveal(t.kind != VideoTextKind.free
                  ? const VideoNote('From the title card\'s Title and Artist (Text & media, at the top).')
                  : Padding(padding: const EdgeInsets.only(top: 6), child: TextField(
                      key: ValueKey('$k-words'), controller: _words, maxLength: 200,
                      decoration: const InputDecoration(isDense: true, labelText: 'Words', counterText: ''),
                      onChanged: (v) => h.edit(() => t.text = v)))),
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _PlacePad(keyPrefix: '$k-place', x: t.x, y: t.y, onPick: (x, y) => h.edit(() {
                      t.x = x;
                      t.y = y;
                    })),
                const SizedBox(width: 8),
                Expanded(child: Column(children: [
                  _slider(h, '$k-size', 'Size', t.size, VideoText.minSize, VideoText.maxSize,
                      '${(t.size * 100).round()}%', (v) => t.size = v),
                  _slider(h, '$k-x', 'Across', t.x, 0, 1, '${(t.x * 100).round()}%', (v) => t.x = v),
                  _slider(h, '$k-y', 'Down', t.y, 0, 1, '${(t.y * 100).round()}%', (v) => t.y = v),
                ])),
              ]),
              Row(children: [
                for (final c in VideoColor.values)
                  Padding(padding: const EdgeInsets.only(right: 8), child: GestureDetector(
                    key: ValueKey('$k-color-${c.name}'),
                    onTap: () => h.edit(() => t.color = c),
                    child: AnimatedContainer(
                      duration: Motion.fade(Motion.small, level),
                      width: 24, height: 24,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: videoColor(c),
                          border: Border.all(color: t.color == c ? Neon.text : Neon.line, width: t.color == c ? 2 : 1)),
                    ),
                  )),
                const Spacer(),
                VideoPill(key: ValueKey('$k-bold'), label: 'BOLD', on: t.bold, onTap: () => h.edit(() => t.bold = !t.bold)),
              ]),
              _label('IN'),
              VideoTiles<VideoTextAnim>(keyPrefix: '$k-in', values: VideoTextAnim.values, selected: t.animIn, height: 32,
                  label: (v) => v.label, onPick: (v) => h.edit(() => t.animIn = v)),
              _slider(h, '$k-in-beats', 'Over', t.inBeats, 0, 8, _beats(t.inBeats), (v) => t.inBeats = v, divisions: 16),
              _label('OUT'),
              VideoTiles<VideoTextAnim>(keyPrefix: '$k-out', values: VideoTextAnim.values, selected: t.animOut, height: 32,
                  label: (v) => v.label, onPick: (v) => h.edit(() => t.animOut = v)),
              _slider(h, '$k-out-beats', 'Over', t.outBeats, 0, 8, _beats(t.outBeats), (v) => t.outBeats = v,
                  divisions: 16),
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerLeft, child: VideoPill(key: ValueKey('$k-beat'), label: 'ON THE BEAT',
                  on: t.beatSync, onTap: () => h.edit(() => t.beatSync = !t.beatSync))),
              VideoNote(t.beatSync
                  ? 'Comes in on the first beat, pops on every beat, types a letter a sixteenth.'
                  : 'Comes in as its span starts and animates over the beats set.'),
              if (widget.wholeVideo) ...[
                _label('SHOWS'),
                _slider(h, '$k-from', 'From bar', ((t.start ?? widget.start) / spb).floorToDouble() + 1, 1,
                    math.max(1.0, (widget.end / spb).ceilToDouble()), '${((t.start ?? widget.start) / spb).floor() + 1}',
                    (v) => t.start = (v.round() - 1) * spb.toDouble(),
                    divisions: math.max(1, (widget.end / spb).ceil() - 1)),
                _slider(h, '$k-for', 'For bars', t.length == null ? 0 : t.length! / spb, 0,
                    math.max(1.0, ((widget.end - widget.start) / spb).ceilToDouble()),
                    t.length == null ? 'to end' : '${(t.length! / spb).round()}',
                    (v) => t.length = v.round() <= 0 ? null : v.round() * spb.toDouble(),
                    divisions: math.max(1, ((widget.end - widget.start) / spb).ceil())),
              ],
            ]))),
        ]),
      )),
    );
  }
}

String _beats(double b) => b == 0 ? 'none' : '${b == b.roundToDouble() ? b.round() : b.toStringAsFixed(1)} beat${b == 1 ? '' : 's'}';

/// The image layers of a shot or of the whole video, with Add image… (the system picker; [onImport] copies and
/// decodes it and returns its asset id, or null).
class VideoImageList extends StatelessWidget {
  const VideoImageList({super.key, required this.layers, required this.doc, required this.host, required this.thumbs,
      required this.onImport, this.problems = const {}, this.keyPrefix = 'video-image'});
  final List<VideoImageLayer> layers;
  final MusicVideoDoc doc;
  final VideoEditHost host;
  final Map<String, Object> thumbs;
  final Map<String, String> problems;
  final Future<String?> Function() onImport;
  final String keyPrefix;

  Future<void> _add(VideoImageAsset? reuse) async {
    final id = reuse?.id ?? await onImport();
    if (id == null) return;
    host.edit(() => layers.add(VideoImageLayer(id: doc.newOverlayId('i'), assetId: id)));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (layers.isEmpty) const VideoNote('No images. Cover art, a logo or a watermark: over the views, or behind them.'),
        for (var i = 0; i < layers.length; i++)
          KeyedSubtree(key: ObjectKey(layers[i]), child: VideoAppear(child: _ImageCard(
              layer: layers[i], asset: doc.asset(layers[i].assetId), host: host, keyPrefix: '$keyPrefix-$i',
              thumb: thumbs[layers[i].assetId], problem: problems[layers[i].assetId],
              onRemove: () => host.edit(() => layers.removeAt(i))))),
        Wrap(spacing: 4, children: [
          TextButton.icon(
            key: ValueKey('$keyPrefix-add'),
            onPressed: layers.length >= kVideoMaxImages ? null : () => _add(null),
            icon: Icon(Icons.add_photo_alternate_outlined, size: 18, color: Neon.green),
            label: Text('Add image…', style: TextStyle(color: Neon.green, fontWeight: FontWeight.w700)),
          ),
          if (doc.assets.isNotEmpty)
            PopupMenuButton<VideoImageAsset>(
              key: ValueKey('$keyPrefix-reuse'),
              tooltip: 'Use an image this video already has',
              enabled: layers.length < kVideoMaxImages,
              onSelected: _add,
              itemBuilder: (_) => [for (final a in doc.assets) PopupMenuItem(value: a, child: Text(a.name))],
              child: const Padding(padding: EdgeInsets.all(10), child: Text('Reuse…', style: TextStyle(color: Neon.dim))),
            ),
        ]),
      ]);
}

class _ImageCard extends StatelessWidget {
  const _ImageCard({required this.layer, required this.asset, required this.host, required this.keyPrefix,
      required this.thumb, required this.problem, required this.onRemove});
  final VideoImageLayer layer;
  final VideoImageAsset? asset;
  final VideoEditHost host;
  final String keyPrefix;
  final Object? thumb;
  final String? problem;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l = layer, h = host, k = keyPrefix;
    final image = thumb;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassPanel(radius: 10, tint: Neon.green, child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox(width: 40, height: 40,
                child: image is Widget ? image : const ColoredBox(color: Neon.panel, child: Icon(Icons.image_outlined, size: 18)))),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(asset?.name ?? 'Missing image', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              Text(problem != null ? 'Can\'t read it: $problem' : '${asset?.width ?? 0} × ${asset?.height ?? 0}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: problem != null ? Neon.pink : Neon.dim)),
            ])),
            IconButton(key: ValueKey('$k-remove'), tooltip: 'Remove', iconSize: 18, color: Neon.dim, onPressed: onRemove,
                icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 6),
          VideoTiles<VideoImagePlacement>(keyPrefix: '$k-placement', values: VideoImagePlacement.values,
              selected: l.placement, height: 32, label: (v) => v.label, onPick: (v) => h.edit(() => l.placement = v)),
          VideoReveal(l.placement == VideoImagePlacement.background
              ? const VideoNote('Fills the frame behind the views, cropped to cover it.')
              : Padding(padding: const EdgeInsets.only(top: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _PlacePad(keyPrefix: '$k-place', x: l.x, y: l.y, onPick: (x, y) => h.edit(() {
                        l.x = x;
                        l.y = y;
                      })),
                  const SizedBox(width: 8),
                  Expanded(child: Column(children: [
                    _slider(h, '$k-size', 'Size', l.size, 0.04, 1, '${(l.size * 100).round()}%', (v) => l.size = v),
                    _slider(h, '$k-x', 'Across', l.x, 0, 1, '${(l.x * 100).round()}%', (v) => l.x = v),
                    _slider(h, '$k-y', 'Down', l.y, 0, 1, '${(l.y * 100).round()}%', (v) => l.y = v),
                  ])),
                ]))),
          _slider(h, '$k-opacity', 'Opacity', l.opacity, 0, 1, '${(l.opacity * 100).round()}%', (v) => l.opacity = v),
        ]),
      )),
    );
  }
}
