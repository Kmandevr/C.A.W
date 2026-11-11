// The arrangement music video: the director's determinism, cuts on beats and sections, shot toggles, size checks,
// the frame clock and spring camera, a short render through the frame-hash encoder, and the setup sheet and preview.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/music_video.dart';
import 'package:caw/model/music_video_director.dart';
import 'package:caw/model/music_video_meters.dart';
import 'package:caw/model/music_video_scene.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/song_export.dart';
import 'package:caw/platform/video_encoder.dart';
import 'package:caw/ui/export_page.dart';
import 'package:caw/ui/music_video/video_painter.dart';
import 'package:caw/ui/music_video/video_preview.dart';
import 'package:caw/ui/music_video/video_render.dart';
import 'package:caw/ui/music_video/video_setup_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _beat = '---\ncaw: 1\nkind: pattern\nname: Beat\nlength: 1 bar\n---\n0 C2 1 1\n4 D2 1 0.8\n8 C2 1 1\n12 D2 1 0.8\n';
const _riff = '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 1 bar\n---\n0 C4 2 1\n2 E4 2 0.7\n4 G4 2 0.9\n6 B4 2 1\n'
    '8 C5 2 1\n10 B4 2 0.6\n12 G4 2 1\n14 E4 2 0.8\n';

/// Sixteen bars: drums all through, a riff from bar 9 (a drop), a marker at bar 5, a filter lane moving in bars 5..8.
ProjectDoc _song() => ProjectDoc(id: 'p', name: 'Video test', bpm: 120, loopBars: 16, modules: [
      ModuleDoc(id: 'beat', name: 'Beat', source: _beat),
      ModuleDoc(id: 'riff', name: 'Riff', source: _riff),
    ], layers: [
      LayerDoc(id: 'drums', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'beat', lengthSteps: 256)],
          instrument: ComponentUseDoc('org.caw.synth.saw', {'cutoff': 0.5})),
      LayerDoc(id: 'lead', name: 'Lead', color: 2, clips: [ClipDoc(id: 'c2', patternId: 'riff', startSteps: 128, lengthSteps: 128)],
          instrument: ComponentUseDoc('org.caw.synth.saw', {'cutoff': 0.2})),
    ], automation: [
      ProjectAutomationLaneDoc(targetType: 'instrument', target: 'cutoff', layerId: 'drums', points: [
        AutomationPointDoc(step: 64, value: 0), AutomationPointDoc(step: 128, value: 1),
      ]),
    ], markers: [MarkerDoc(id: 'm1', name: 'Verse', startSteps: 64)]);

VideoScene _scene([ProjectDoc? p]) => buildVideoScene(p ?? _song(), colorOf: (l) => 0xff00ffcc + l.color);

/// A song render that writes silent-ish WAVs of the exact range length at once.
class _FakeAudio implements SongRenderHandle {
  _FakeAudio(String requestJson) {
    final r = jsonDecode(requestJson) as Map<String, dynamic>;
    request = r;
    final steps = (r['end_steps'] as int) - (r['start_steps'] as int);
    final rate = r['sample_rate'] as int;
    final frames = (steps * 15 / 120 * rate).round();
    final dir = r['out_dir'] as String;
    final mix = File('$dir/mix.wav');
    writeTestWav(mix, sampleRate: rate, frames: frames, sample: (i, c) => 0.5 * math.sin(i * 0.05) * (i % 24000 < 12000 ? 1 : 0.1));
    final files = [
      {'path': mix.path, 'name': 'mix.wav', 'kind': 'mix', 'layer': '', 'frames': frames},
      if (r['tracks'] == true) ...[
        for (final id in ['drums', 'lead'])
          () {
            final f = File('$dir/$id.wav');
            writeTestWav(f, sampleRate: rate, frames: frames, sample: (i, c) => id == 'drums' ? 0.8 : 0.1);
            return {'path': f.path, 'name': '$id.wav', 'kind': 'track', 'layer': id, 'frames': frames};
          }(),
      ],
    ];
    result = Future.value(jsonEncode({'ok': true, 'error': '', 'files': files}));
  }
  late final Map<String, dynamic> request;
  @override
  double progress = 1;
  @override
  late final Future<String?> result;
  @override
  void cancel() {}
}

void main() {
  group('director', () {
    test('the same seed gives the same shots; another seed cuts differently', () {
      final scene = _scene();
      for (final style in VideoStyle.values) {
        final o = MusicVideoOptions(style: style, seed: 7);
        final a = directVideo(scene, o, start: 0, end: 256).shots.map((s) => '$s ${s.clip} ${s.lane} ${s.zoomFrom}').toList();
        final b = directVideo(_scene(), o.copy(), start: 0, end: 256).shots.map((s) => '$s ${s.clip} ${s.lane} ${s.zoomFrom}').toList();
        expect(a, b, reason: style.name);
      }
      final seeds = {
        for (var seed = 1; seed <= 6; seed++)
          directVideo(scene, MusicVideoOptions(seed: seed), start: 0, end: 256).shots.join(','),
      };
      expect(seeds.length, greaterThan(1));
    });

    test('cuts land on the bar (calm, minimal) or the beat (energetic), or on a section', () {
      final scene = _scene();
      final sectionSteps = {for (final s in scene.sections) s.step};
      expect(sectionSteps, containsAll([64.0, 128.0])); // the marker, and the riff's drop
      for (final style in VideoStyle.values) {
        final plan = directVideo(scene, MusicVideoOptions(style: style, seed: 3), start: 0, end: 256);
        expect(plan.shots.first.start, 0);
        expect(plan.shots.last.end, 256);
        final grid = style == VideoStyle.energetic ? 4 : 16;
        for (var i = 0; i < plan.shots.length; i++) {
          final s = plan.shots[i];
          if (i > 0) expect(s.start, plan.shots[i - 1].end);
          expect(s.end, greaterThan(s.start));
          expect(s.start % grid == 0 || sectionSteps.contains(s.start), isTrue, reason: '${style.name} cut at ${s.start}');
        }
        // A section inside a long shot cuts there.
        expect(plan.shots.map((s) => s.start), containsAll([64.0, 128.0]), reason: style.name);
      }
    });

    test('a drop or section opens on a wide flythrough when it is on', () {
      final scene = _scene();
      var sections = 0, wide = 0;
      for (var seed = 1; seed <= 20; seed++) {
        for (final s in directVideo(scene, MusicVideoOptions(seed: seed), start: 0, end: 256).shots) {
          if (!s.section) continue;
          sections++;
          if (s.kind == VideoShot.flythrough) wide++;
        }
      }
      expect(wide / sections, greaterThan(0.4));
    });

    test('switched-off shots never appear; targets follow what is active', () {
      final scene = _scene();
      for (var seed = 1; seed <= 10; seed++) {
        final only = directVideo(scene, MusicVideoOptions(seed: seed, shots: {VideoShot.pianoRoll, VideoShot.devices}),
            start: 0, end: 256);
        for (final s in only.shots) {
          expect(s.kind, isIn([VideoShot.pianoRoll, VideoShot.devices]));
          if (s.kind == VideoShot.pianoRoll) {
            expect(s.clip, isNotNull);
            // The busiest clip: the riff once it plays (eight notes a bar against four).
            if (s.start >= 128) expect(scene.clips[s.clip!].name, 'Riff');
          }
          if (s.kind == VideoShot.devices && s.start >= 64 && s.end <= 128) expect(s.lane, 0);
        }
        final noMixer = directVideo(scene, MusicVideoOptions(seed: seed, shots: {VideoShot.flythrough}), start: 0, end: 256);
        expect(noMixer.shots.every((s) => s.kind == VideoShot.flythrough), isTrue);
      }
    });

    test('the spring camera: closed form matches its equation and follows the playhead', () {
      const omega = 4.0, v = 8.0;
      // Integrate x'' = -2w(x' - v) - w^2(x - a - v t) finely and compare.
      var x = -10.0, u = 0.0;
      const dt = 1e-4;
      for (var t = 0.0; t < 1.5 - 1e-12; t += dt) {
        final acc = -2 * omega * (u - v) - omega * omega * (x - 0 - v * t);
        u += acc * dt;
        x += u * dt;
      }
      final (cx, cu) = springFollow(1.5, x0: -10, u0: 0, a: 0, v: v, omega: omega);
      expect(cx, closeTo(x, 0.02));
      expect(cu, closeTo(u, 0.02));
      final (late, _) = springFollow(10, x0: -10, u0: 0, a: 0, v: v, omega: omega);
      expect(late, closeTo(v * 10, 1e-6)); // settles onto the playhead
      final (z, _) = springTo(20, from: 1.4, velocity: 0, target: 1, omega: omega);
      expect(z, closeTo(1, 1e-9));
      expect(springTo(0, from: 1.4, velocity: 0, target: 1, omega: omega).$1, 1.4);
    });
  });

  group('setup', () {
    test('presets give even sizes for the ratio; checks catch odd, small and too-large sizes', () {
      expect(presetSize(VideoAspect.portrait, VideoResolution.p1080), (1080, 1920));
      expect(presetSize(VideoAspect.landscape, VideoResolution.p2160), (3840, 2160));
      expect(presetSize(VideoAspect.square, VideoResolution.p720), (720, 720));
      expect(presetSize(VideoAspect.feed, VideoResolution.p1080), (1080, 1350));
      expect(presetSize(VideoAspect(21, 9), VideoResolution.p1440), (3360, 1440));
      expect(VideoAspect(32, 18), VideoAspect.landscape);
      const caps = VideoEncoderCaps(maxLong: 3840, maxShort: 2160);
      expect(validateVideoSize(1080, 1920, caps), isNull);
      expect(validateVideoSize(2160, 3840, caps), isNull);
      expect(validateVideoSize(1081, 1920, caps), contains('even'));
      expect(validateVideoSize(100, 200, caps), contains('at least'));
      expect(validateVideoSize(4096, 2160, caps), contains('at most'));
      expect(validateVideoSize(0, 100, caps), isNotNull);
      final o = MusicVideoOptions(aspect: VideoAspect(1, 9));
      expect(o.problem(caps), contains('4:1'));
      expect(MusicVideoOptions(shots: {}).problem(caps), contains('shot'));
      expect(MusicVideoOptions(resolution: VideoResolution.custom, customWidth: 640, customHeight: 360).problem(caps), isNull);
      expect(MusicVideoOptions(resolution: VideoResolution.p1440, aspect: VideoAspect.portrait)
          .problem(const VideoEncoderCaps(maxLong: 1920, maxShort: 1080)), contains('at most'));
    });

    test('the frame clock: frame N is N / fps seconds in, whatever the wall clock', () {
      const c = FrameClock(fps: 30, startStep: 64, endStep: 128, bpm: 120);
      expect(c.durationSeconds, 8);
      expect(c.frameCount, 240);
      expect(c.stepAt(0), 64);
      expect(c.stepAt(30), 64 + 8); // one second at 120 bpm is 8 sixteenths
      for (final n in [1, 7, 239]) {
        expect(c.secondsAt(n), n / 30);
        expect(c.secondsAtStep(c.stepAt(n)), closeTo(n / 30, 1e-12));
      }
      expect(const FrameClock(fps: 60, startStep: 0, endStep: 1, bpm: 120).frameCount, 8); // 0.125 s
    });

    test('scene: looped notes unroll onto the timeline and lanes scale to 0..1', () {
      final s = _scene();
      expect(s.notes.where((n) => n.track == 0).length, 64); // four a bar for sixteen bars
      expect(s.notes.where((n) => n.track == 1).length, 64); // eight a bar for eight bars
      expect(s.notes.first.start, 0);
      expect(s.lanes.single.valueAt(96), closeTo(0.5, 1e-9));
      expect(s.lanes.single.device, 0);
      expect(s.busiestClip(128, 144), 1);
      expect(s.movingLane(0, 64), isNull);
      expect(s.movingLane(64, 128)!.$1, 0);
    });
  });

  testWidgets('a short render through the frame-hash encoder: one frame per 1/fps, the audio as long as the range',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('caw_video_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Future<(FrameHashEncoder, File?, MusicVideoRender)> once(String name) async {
      final enc = FrameHashEncoder();
      final r = MusicVideoRender(
        projectJson: _song().toEngineJson(), scene: _scene(), startStep: 112, endStep: 144,
        options: MusicVideoOptions(resolution: VideoResolution.custom, customWidth: 128, customHeight: 224, fps: 30, seed: 5),
        encoder: enc, workDir: Directory('${tmp.path}/$name'), audio: (p, r) => _FakeAudio(r));
      final f = await tester.runAsync(r.run);
      return (enc, f, r);
    }

    final (enc, file, render) = await once('a');
    expect(render.phase, VideoRenderPhase.done, reason: render.error);
    expect(file, isNotNull);
    expect(enc.frames, 120); // two bars at 120 bpm: 4 s at 30 fps
    expect(render.frameCount, 120);
    expect(enc.audioSeconds, closeTo(4.0, 1e-3));
    final lines = await tester.runAsync(() => file!.readAsLines());
    expect(lines!.length, 2 + 120);
    expect(lines[1], startsWith('size 128x224 fps 30 audio 4.0'));
    expect(enc.hashes.toSet().length, greaterThan(10)); // the picture moves
    expect(Directory('${tmp.path}/a/audio').existsSync(), isFalse); // the audio is cleaned up

    // Deterministic: the same render gives the same frames.
    final (again, _, _) = await once('b');
    expect(again.hashes, enc.hashes);
  });

  testWidgets('a cancelled render stops and leaves no file', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('caw_video_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final enc = FrameHashEncoder();
    final r = MusicVideoRender(
      projectJson: _song().toEngineJson(), scene: _scene(), startStep: 0, endStep: 256,
      options: MusicVideoOptions(resolution: VideoResolution.custom, customWidth: 128, customHeight: 128),
      encoder: enc, workDir: Directory('${tmp.path}/c'), audio: (p, q) => _FakeAudio(q));
    r.addListener(() {
      if (r.framesDrawn >= 5) r.cancel();
    });
    final f = await tester.runAsync(r.run);
    expect(f, isNull);
    expect(r.phase, VideoRenderPhase.cancelled);
    expect(enc.frames, lessThan(20));
    expect(Directory('${tmp.path}/c').existsSync(), isFalse);
  });

  testWidgets('frames draw at any size and the meters read the rendered audio', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('caw_video_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final wav = File('${tmp.path}/m.wav');
    writeTestWav(wav, sampleRate: 48000, frames: 48000, sample: (i, c) => i < 24000 ? 0.5 : 0.0);
    final meters = (await tester.runAsync(() => analyzeVideoAudio(mixPath: wav.path, fps: 30, frames: 30)))!;
    expect(meters.levelsAt(0).peakL, closeTo(0.5, 1e-3));
    expect(meters.levelsAt(0).rms, closeTo(0.5, 1e-3));
    expect(meters.levelsAt(29).peakL, lessThan(0.1)); // fallen after the sound stops
    final scene = _scene();
    final plan = directVideo(scene, MusicVideoOptions(), start: 0, end: 256);
    for (final shot in plan.shots.take(8)) {
      final input = VideoFrameInput(scene: scene, plan: plan, step: shot.start + 1, seconds: 4, levels: meters.levelsAt(3));
      final bytes = await tester.runAsync(() => rasterizeVideoFrame(input, 96, 64));
      expect(bytes!.length, 96 * 64 * 4);
    }
  });

  /// Scrolls [key] into view and taps it.
  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await tester.pump();
  }

  testWidgets('the setup sheet: toggles, ratio and size checks, and the preview starts and stops', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = _song();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MusicVideoPanel(state: s, encoder: FrameHashEncoder(maxSide: 2160)))));
    await tester.pump();
    expect(find.text('MUSIC VIDEO'), findsOneWidget);

    // Every shot off: the render can't start.
    for (final shot in VideoShot.values) {
      await tapKey(tester, 'video-shot-${shot.name}');
    }
    expect(find.text('Switch on at least one shot.'), findsWidgets);
    await tapKey(tester, 'video-shot-mixer');

    // A custom size that is odd is refused, then an even one is fine.
    await tapKey(tester, 'video-res-custom');
    await tester.enterText(find.byKey(const ValueKey('video-size-w')), '721');
    await tester.pump();
    expect(find.byKey(const ValueKey('video-size-problem')), findsOneWidget);
    expect(find.textContaining('even numbers'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('video-size-w')), '720');
    await tester.pump();
    expect(find.textContaining('even numbers'), findsNothing);

    // 16:9 at 4K is beyond this encoder's 2160 long side.
    await tapKey(tester, 'video-aspect-16:9');
    await tapKey(tester, 'video-res-p2160');
    expect(find.textContaining('at most 2160'), findsWidgets);
    await tapKey(tester, 'video-res-p720');
    expect(find.textContaining('1280 × 720'), findsOneWidget);

    // The preview plays (a silent clock with no engine), moves on, and stops.
    await tester.drag(find.byType(ListView).first, const Offset(0, 4000));
    await tester.pump();
    await tapKey(tester, 'video-preview-play');
    final preview = tester.state<MusicVideoPreviewState>(find.byType(MusicVideoPreview));
    expect(preview.playing, isTrue);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(preview.step, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('video-preview-play')));
    await tester.pump();
    expect(preview.playing, isFalse);
  });

  testWidgets('the Export page opens the Music video sheet', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = _song();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExportPage(state: s))));
    await tester.pump();
    await tester.drag(find.byType(ListView).first, const Offset(0, -6000));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open-music-video')));
    await tester.pumpAndSettle();
    expect(find.text('MUSIC VIDEO'), findsOneWidget);
  });
}
