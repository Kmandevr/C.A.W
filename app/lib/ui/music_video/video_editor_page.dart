// The music video editor full screen (owner, 2026-11-12): its own closable page like the full-screen piano roll
// (Back, Esc or the close button leave it). A phone stacks the preview over the lane and the list; a wide screen puts
// the preview and lane on the left and the shot list on the right.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/music_video_director.dart';
import '../../model/music_video_edit.dart';
import '../../model/music_video_scene.dart';
import '../glass.dart';
import '../haptics.dart';
import '../page_closer.dart';
import '../theme.dart';
import 'video_editor.dart';
import 'video_kit.dart';
import 'video_preview.dart';

/// Opens the full-screen editor on [doc] (the sheet's video: edits show there when the page closes).
Future<void> openMusicVideoEditorPage(BuildContext context, {required AppState state, required MusicVideoDoc doc,
    required VideoScene scene, required double start, required double end, required VoidCallback onSave,
    Future<List<double>?> Function()? loudness, AutoCutRunner? runner}) {
  Haptics.tap();
  return Navigator.of(context).push(MaterialPageRoute<void>(
    settings: closablePage,
    builder: (_) => GlassPage(child: Scaffold(body: SafeArea(child: MusicVideoEditorPage(
        state: state, doc: doc, scene: scene, start: start, end: end, onSave: onSave, loudness: loudness,
        runner: runner)))),
  ));
}

class MusicVideoEditorPage extends StatefulWidget {
  const MusicVideoEditorPage({super.key, required this.state, required this.doc, required this.scene,
      required this.start, required this.end, required this.onSave, this.loudness, this.runner});
  final AppState state;
  final MusicVideoDoc doc;
  final VideoScene scene;
  final double start, end;
  final VoidCallback onSave;
  final Future<List<double>?> Function()? loudness;
  final AutoCutRunner? runner;

  /// From this width the page lays the preview and lane beside the list.
  static const wideFrom = 900.0;

  @override
  State<MusicVideoEditorPage> createState() => _MusicVideoEditorPageState();
}

class _MusicVideoEditorPageState extends State<MusicVideoEditorPage> {
  late final _position = ValueNotifier<double>(widget.start);
  final _previewKey = GlobalKey<MusicVideoPreviewState>();

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _close() {
    Haptics.tap();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.doc.options;
    final (w, h) = o.size;
    final plan = planVideo(widget.scene, o, widget.doc.timeline, start: widget.start, end: widget.end);
    final preview = MusicVideoPreview(key: _previewKey, state: widget.state, scene: widget.scene, plan: plan,
        options: o, start: widget.start, end: widget.end, position: _position);
    final header = SizedBox(height: 44, child: Row(children: [
      IconButton(key: const ValueKey('video-editor-close'), tooltip: 'Close (Esc)', onPressed: _close,
          icon: const Icon(Icons.arrow_back)),
      Icon(Icons.movie_filter_outlined, size: 18, color: videoAccent),
      const SizedBox(width: 8),
      const Expanded(child: Text('MUSIC VIDEO EDITOR', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, letterSpacing: 1.6, fontWeight: FontWeight.w800))),
    ]));
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= MusicVideoEditorPage.wideFrom;
      final editor = MusicVideoEditor(
        doc: widget.doc, scene: widget.scene, start: widget.start, end: widget.end, aspect: w / h,
        playhead: _position, onSeek: (st) => _previewKey.currentState?.seek(st),
        onChanged: () => setState(() {}), onSave: widget.onSave, loudness: widget.loudness, runner: widget.runner,
        settings: widget.state.settings, fullScreen: true, onFullScreen: _close,
        side: wide
            ? (top, list) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 6, child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 8, 16), children: [
                    header, preview, const SizedBox(height: 8), top,
                  ])),
                  const VerticalDivider(width: 1, color: Neon.line),
                  Expanded(flex: 4, child: ListView(padding: const EdgeInsets.fromLTRB(8, 52, 12, 16), children: [list])),
                ])
            : null,
      );
      if (wide) return editor;
      // A phone: the preview on top (up to two fifths of the height), the lane and list scrolling under it.
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: header),
        ConstrainedBox(constraints: BoxConstraints(maxHeight: box.maxHeight * 0.42), child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(), child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12), child: preview))),
        const SizedBox(height: 6),
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [editor])),
      ]);
    });
  }
}
