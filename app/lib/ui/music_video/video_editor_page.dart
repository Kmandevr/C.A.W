// The music video editor full screen (owner, 2026-11-12): its own closable page like the full-screen piano roll
// (Back, Esc or the close button leave it), the same tabbed panel as the sheet on the same video. A phone stacks the
// preview and lane over the tabs; a wide screen puts the preview and lane on the left and the tabs on the right.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/music_video_edit.dart';
import '../../model/song_export.dart';
import '../../platform/video_encoder.dart';
import '../glass.dart';
import '../haptics.dart';
import '../page_closer.dart';
import 'video_editor.dart';
import 'video_setup_sheet.dart';

/// Opens the full-screen editor on [doc] (the sheet's video: edits show there when the page closes).
Future<void> openMusicVideoEditorPage(BuildContext context, {required AppState state, required MusicVideoDoc doc,
    VideoEncoder? encoder, SongRenderStarter? audio, Directory? workDir, AutoCutRunner? runner}) {
  Haptics.tap();
  return Navigator.of(context).push(MaterialPageRoute<void>(
    settings: closablePage,
    builder: (_) => GlassPage(child: Scaffold(body: SafeArea(child: MusicVideoEditorPage(
        state: state, doc: doc, encoder: encoder, audio: audio, workDir: workDir, runner: runner)))),
  ));
}

class MusicVideoEditorPage extends StatelessWidget {
  const MusicVideoEditorPage({super.key, required this.state, required this.doc, this.encoder, this.audio, this.workDir,
      this.runner});
  final AppState state;
  final MusicVideoDoc doc;
  final VideoEncoder? encoder;
  final SongRenderStarter? audio;
  final Directory? workDir;
  final AutoCutRunner? runner;

  /// From this width the page lays the preview and lane beside the tabs.
  static const wideFrom = MusicVideoPanel.wideFrom;

  @override
  Widget build(BuildContext context) => MusicVideoPanel(state: state, doc: doc, encoder: encoder, audio: audio,
      workDir: workDir, runner: runner, fullScreen: true, onClose: () {
        Haptics.tap();
        Navigator.of(context).maybePop();
      });
}
