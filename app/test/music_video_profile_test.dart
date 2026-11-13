// The music video render's profile (docs/performance.md "Music video render"): where a render's time goes, one frame
// at a time against the pipeline, at 1080 × 1920 and 30 fps. Opt-in (CAW_VIDEO_PROFILE=1; CAW_LIB adds the engine's
// real audio render); it prints the numbers and checks only that both runs drew every frame.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/music_video.dart';
import 'package:caw/model/music_video_edit.dart';
import 'package:caw/model/music_video_scene.dart';
import 'package:caw/model/project.dart';
import 'package:caw/platform/video_encoder.dart';
import 'package:caw/ui/music_video/video_render.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'music_video_test_song.dart';

/// What the app's Dart side does with a frame on Android: before, the StandardMessageCodec copy of the method call
/// (`{'rgba': bytes}`); after, nothing here (the bytes go straight into the binary message).
class _ChannelCostEncoder implements VideoEncoder {
  _ChannelCostEncoder({required this.codec});
  final bool codec;
  int frames = 0;
  @override
  String get extension => 'mp4';
  @override
  String get mimeType => 'video/mp4';
  @override
  Future<VideoEncoderCaps> caps() async => const VideoEncoderCaps(maxLong: 8192, maxShort: 8192);
  @override
  Future<void> start(VideoEncodeConfig config) async {}
  @override
  Future<void> addFrame(Uint8List rgba) async {
    if (codec) const StandardMethodCodec().encodeMethodCall(MethodCall('frame', {'rgba': rgba}));
    frames++;
  }

  @override
  Future<void> finish() async {}
  @override
  Future<void> cancel() async {}
}

void main() {
  final on = Platform.environment['CAW_VIDEO_PROFILE'] == '1';
  final engine = Platform.environment['CAW_LIB']?.isNotEmpty == true;

  testWidgets('profile: one frame at a time against the pipeline, 1080 × 1920 at 30 fps', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('caw_video_profile_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final song = videoTestSong();
    // The engine's own synth when it renders the audio for real.
    if (engine) {
      for (final l in song.layers) {
        l.instrument = ComponentUseDoc('org.caw.synth.flagship');
      }
      song.automation.clear();
    }
    final scene = buildVideoScene(song, colorOf: (l) => 0xff00ffcc + l.color);
    // A typical edited video: three shots, a split layout, a glow on the beat.
    final doc = MusicVideoDoc(timeline: VideoTimeline([
      VideoCut(id: 's1', start: 112, length: 16, layout: VideoLayout.single(VideoShot.flythrough)),
      VideoCut(id: 's2', start: 128, length: 8, layout: VideoLayout(preset: VideoLayoutPreset.bigStrip),
          effects: [VideoEffect(kind: VideoEffectKind.glow, drive: VideoDrive.beat)]),
      VideoCut(id: 's3', start: 136, length: 8, layout: VideoLayout.single(VideoShot.falling)),
    ]));
    final results = <String, Object>{};
    for (final (name, depth, codec) in [('before', 1, true), ('after', 0, false)]) {
      final enc = _ChannelCostEncoder(codec: codec);
      final r = MusicVideoRender(
        projectJson: song.toEngineJson(), scene: scene, startStep: 112, endStep: 144,
        options: MusicVideoOptions(resolution: VideoResolution.p1080, fps: 30), timeline: doc.timeline, doc: doc,
        encoder: enc, workDir: Directory('${tmp.path}/$name'),
        audio: engine ? null : (p, q) => FakeVideoAudio(q),
        pipelineDepth: depth == 0 ? null : depth);
      await tester.runAsync(r.run);
      expect(r.phase, VideoRenderPhase.done, reason: r.error);
      expect(enc.frames, 120);
      results[name] = {'depth': r.pipelineDepth, 'codec_copy': codec, ...r.profile.toJson()};
    }
    // The channel's copy on its own, for one 1080 × 1920 frame.
    final frame = Uint8List(1080 * 1920 * 4);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      const StandardMethodCodec().encodeMethodCall(MethodCall('frame', {'rgba': frame}));
    }
    results['standard_codec_ms_frame'] = sw.elapsedMicroseconds / 1000 / 20;
    // ignore: avoid_print
    print('MUSIC VIDEO PROFILE ${const JsonEncoder.withIndent('  ').convert(results)}');
  }, skip: !on);
}
