// The music video's second round (owner, 2026-11-12): export settings (24 fps, quality, draft), text overlays,
// images with limits, camera moves, the new transitions and beat presets, saving as version 2 and reading version 1,
// the render's pipeline, drafts, cancel and profile, the tabbed sheet at 360 dp, and goldens of the layout and of a
// frame for each transition and overlay.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/music_video.dart';
import 'package:caw/model/music_video_autocut.dart';
import 'package:caw/model/music_video_director.dart';
import 'package:caw/model/music_video_edit.dart';
import 'package:caw/model/music_video_meters.dart';
import 'package:caw/model/music_video_overlay.dart';
import 'package:caw/model/music_video_scene.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/video_encoder.dart';
import 'package:caw/ui/music_video/video_editor.dart';
import 'package:caw/ui/music_video/video_images.dart';
import 'package:caw/ui/music_video/video_painter.dart';
import 'package:caw/ui/music_video/video_render.dart';
import 'package:caw/ui/music_video/video_render_chip.dart';
import 'package:caw/ui/music_video/video_setup_sheet.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';
import 'music_video_test_song.dart';

VideoScene _scene() => buildVideoScene(videoTestSong(), colorOf: (l) => 0xff00ffcc + l.color);

/// A small opaque image drawn here (a gradient square with a ring), PNG-encoded.
/// [png] with its header's size changed to [w] × [h] (the IHDR chunk's CRC recomputed), its pixels left as they are.
Uint8List _pngSized(Uint8List png, int w, int h) {
  final out = Uint8List.fromList(png);
  final d = ByteData.sublistView(out);
  d.setUint32(16, w);
  d.setUint32(20, h);
  var c = 0xffffffff;
  for (final b in out.sublist(12, 29)) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
    }
  }
  d.setUint32(29, c ^ 0xffffffff);
  return out;
}

Future<Uint8List> _png(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..shader = ui.Gradient.linear(Offset.zero, Offset(w.toDouble(), h.toDouble()), [Neon.yellow, Neon.violet]));
  c.drawCircle(Offset(w / 2, h / 2), w / 3, Paint()
    ..color = const Color(0xffffffff)
    ..style = PaintingStyle.stroke
    ..strokeWidth = w / 10);
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  setUp(resetMusicVideoSheet);

  group('export settings', () {
    test('24 fps, the quality presets and their bitrates; balanced is the bitrate every video had', () {
      final o = MusicVideoOptions(resolution: VideoResolution.p1080, fps: 30);
      expect(o.bitrate, (1080 * 1920 * 30 * 0.1).round()); // as before the choice existed
      o.quality = VideoQuality.small;
      expect(o.bitrate, (1080 * 1920 * 30 * 0.05).round());
      o.quality = VideoQuality.high;
      expect(o.bitrate, (1080 * 1920 * 30 * 0.2).round());
      expect(o.estimatedBytes(60), ((o.bitrate + kVideoAudioBitrate) / 8 * 60).round());
      o.fps = 24;
      expect(o.problem(VideoEncoderCaps.fallback), isNull);
      o.fps = 25;
      expect(o.problem(VideoEncoderCaps.fallback), contains('24, 30 or 60'));
      // Saved and read back; an unknown quality reads as balanced.
      final back = MusicVideoOptions.fromJson((MusicVideoOptions(fps: 24, quality: VideoQuality.high)).toJson());
      expect((back.fps, back.quality), (24, VideoQuality.high));
      expect(MusicVideoOptions.fromJson({'quality': 'ultra'}).quality, VideoQuality.balanced);
      expect(MusicVideoOptions().toJson().containsKey('quality'), isFalse);
    });

    test('a draft keeps the ratio at 360 on its short side, 15 fps, small quality', () {
      final d = MusicVideoOptions(aspect: VideoAspect.landscape, resolution: VideoResolution.p2160, fps: 60).draft();
      expect(d.size, (640, 360));
      expect((d.fps, d.quality), (MusicVideoOptions.draftFps, VideoQuality.small));
      expect(MusicVideoOptions(aspect: VideoAspect.portrait).draft().size, (360, 640));
    });
  });

  group('text overlays', () {
    test('fade, slide, pop and typewriter in and out; on the beat it starts on the first beat', () {
      final t = VideoText(id: 't1', text: 'Hello', animIn: VideoTextAnim.fade, animOut: VideoTextAnim.fade,
          inBeats: 1, outBeats: 1, beatSync: false);
      expect(t.frameAt(-1, 0, 32, 5), isNull);
      expect(t.frameAt(0, 0, 32, 5), isNull); // fully faded at its first instant
      expect(t.frameAt(2, 0, 32, 5)!.opacity, inExclusiveRange(0, 1));
      expect(t.frameAt(8, 0, 32, 5)!.opacity, 1);
      expect(t.frameAt(31, 0, 32, 5)!.opacity, lessThan(1));
      expect(t.frameAt(32, 0, 32, 5), isNull);
      // On the beat: a span starting off the beat waits for the next one.
      t.beatSync = true;
      expect(t.frameAt(2, 1, 32, 5), isNull);
      expect(t.frameAt(5, 1, 32, 5), isNotNull);
      // Slide moves it, pop scales it, typewriter types a letter a sixteenth on the beat.
      t.animIn = VideoTextAnim.slide;
      expect(t.frameAt(1, 0, 32, 5)!.dy, greaterThan(0));
      t.animIn = VideoTextAnim.pop;
      expect(t.frameAt(1, 0, 32, 5)!.scale, isNot(1));
      // Popped in and on the beat, it pulses on each beat.
      expect(t.frameAt(8, 0, 32, 5)!.scale, greaterThan(t.frameAt(10, 0, 32, 5)!.scale));
      t.animIn = VideoTextAnim.typewriter;
      expect(t.frameAt(0, 0, 32, 5)!.typed, 1);
      expect(t.frameAt(2, 0, 32, 5)!.typed, 3);
      expect(t.frameAt(9, 0, 32, 5)!.typed, 5);
    });

    test('the presets, saving and the reader\'s limits', () {
      final doc = MusicVideoDoc();
      for (final p in VideoTextPreset.values) {
        doc.texts.addAll(p.make(() => doc.newOverlayId('t')));
      }
      expect(doc.texts.map((t) => t.id).toSet().length, doc.texts.length); // unique ids
      expect(doc.texts.first.shown('Song', 'Me'), 'Song');
      final j = jsonDecode(jsonEncode(doc.toJson()));
      final back = MusicVideoDoc.fromJson(j);
      expect(jsonEncode(back.toJson()), jsonEncode(doc.toJson()));
      // Untrusted: too many, out of range, repeated ids.
      final bad = MusicVideoDoc.fromJson({
        'version': 2,
        'texts': [for (var i = 0; i < 100; i++) {'id': 'x', 'size': 9, 'x': -3, 'in_beats': 1e9, 'kind': 'nope'}],
      });
      expect(bad.texts.length, kVideoMaxTexts);
      expect(bad.texts.map((t) => t.id).toSet().length, kVideoMaxTexts);
      expect((bad.texts.first.size, bad.texts.first.x, bad.texts.first.inBeats, bad.texts.first.kind),
          (VideoText.maxSize, 0.0, VideoText.maxBeats, VideoTextKind.free));
    });
  });

  group('images', () {
    test('an asset names a file in the assets folder only, never a path', () {
      expect(VideoImageAsset.fromJson({'id': 'a', 'file': 'img1.png'}), isNotNull);
      for (final f in ['../x.png', '/etc/passwd', 'a/b.png', 'x.exe', 'img1.png/..']) {
        expect(VideoImageAsset.fromJson({'id': 'a', 'file': f}), isNull, reason: f);
      }
      final doc = MusicVideoDoc.fromJson({
        'assets': [for (var i = 0; i < 50; i++) {'id': 'img${i % 40}', 'file': 'img$i.png'}],
        'images': [for (var i = 0; i < 40; i++) {'asset': 'img1', 'size': 99, 'opacity': -1}],
      });
      expect(doc.assets.length, kVideoMaxImageAssets);
      expect(doc.images.length, kVideoMaxImages);
      expect((doc.images.first.size, doc.images.first.opacity), (1.0, 0.0));
    });

    testWidgets('import copies the image into the assets folder; decoding keeps it within the limits', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_img_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      await tester.runAsync(() async {
        final src = File('${tmp.path}/cover.png')..writeAsBytesSync(await _png(64, 48));
        final (asset, image) = await importVideoImage(src.path, Directory('${tmp.path}/assets'), 'img1');
        expect((asset.file, asset.name, asset.width, asset.height), ('img1.png', 'cover.png', 64, 48));
        expect(File('${tmp.path}/assets/img1.png').existsSync(), isTrue);
        image.dispose();
        // Large images are kept at most 2048 on the long side.
        final big = await decodeVideoImage(await _png(4096, 1024));
        expect((big.width, big.height), (2048, 512));
        big.dispose();
        // Too wide is refused from its header, before its pixels are decoded.
        await expectLater(decodeVideoImage(await _png(8200, 2)), throwsA(isA<FormatException>()));
        await expectLater(decodeVideoImage(Uint8List.fromList(utf8.encode('not an image'))), throwsA(isA<FormatException>()));
        await expectLater(importVideoImage('${tmp.path}/x.exe', Directory('${tmp.path}/assets'), 'img2'),
            throwsA(isA<FormatException>()));
        // The store loads the project's assets and notes a missing one.
        final store = VideoImageStore(Directory('${tmp.path}/assets'));
        await store.load([asset, VideoImageAsset(id: 'gone', file: 'gone.png', name: 'gone.png')]);
        expect(store.images.keys, ['img1']);
        expect(store.problems.keys, ['gone']);
        store.dispose();
      });
    });

    testWidgets('formats decoded at full size take fewer pixels; JPEG and WebP are known from their bytes',
        (tester) async {
      await tester.runAsync(() async {
        // A PNG whose header says 4500 × 4000 (18 MP): refused before its pixels are decoded.
        final png = await _png(2, 2);
        expect(decodesScaled(png), isFalse);
        await expectLater(decodeVideoImage(_pngSized(png, 4500, 4000)), throwsA(isA<FormatException>()));
      });
      expect(decodesScaled(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0])), isTrue);
      expect(decodesScaled(Uint8List.fromList([...ascii.encode('RIFF'), 0, 0, 0, 0, ...ascii.encode('WEBPVP8 ')])), isTrue);
      expect(VideoImageAsset.maxPixelsFullDecode, lessThan(VideoImageAsset.maxPixels));
    });

    testWidgets('the store decodes only the images in use, within its budget, and lets a late decode go',
        (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_store_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      await tester.runAsync(() async {
        final dir = Directory('${tmp.path}/assets')..createSync();
        final assets = [
          for (var i = 1; i <= 3; i++) VideoImageAsset(id: 'img$i', file: 'img$i.png', name: 'img$i.png'),
        ];
        for (final a in assets) {
          File('${dir.path}/${a.file}').writeAsBytesSync(await _png(400, 200));
        }
        // A budget of 2 × 300² pixels: two in use get 300 px on the long side, one gets its own 400.
        final store = VideoImageStore(dir, budgetBytes: 2 * 300 * 300 * 4);
        await store.load(assets, used: {'img1', 'img2'});
        expect(store.images.keys.toSet(), {'img1', 'img2'});
        expect(store.images['img1']!.width, 300);
        await store.load(assets, used: {'img1'});
        expect(store.images.keys, ['img1']);
        expect(store.images['img1']!.width, 400); // re-decoded larger with the whole budget
        // Disposed while a decode is under way: no image is kept, and nothing throws.
        final late = store.load(assets);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        store.dispose();
        await late;
        expect(store.images, isEmpty);
      });
      expect(VideoImageStore.sideFor(1, VideoImageStore.defaultBudget), VideoImageAsset.keepSide);
      expect(VideoImageStore.sideFor(32, VideoImageStore.defaultBudget), lessThan(VideoImageAsset.keepSide));
    });

    testWidgets('asset ids are never reused, and a removed asset\'s file is swept from its folder only',
        (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_ids_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      await tester.runAsync(() async {
        final dir = Directory('${tmp.path}/assets')..createSync();
        expect(await nextVideoAssetId([], dir), 'img1');
        final kept = VideoImageAsset(id: 'img1', file: 'img1.png', name: 'a.png');
        File('${dir.path}/img1.png').writeAsBytesSync([1]);
        // img3's asset is gone (undone away), but its file is still there: the next id goes past it.
        File('${dir.path}/img3.jpg').writeAsBytesSync([1]);
        File('${dir.path}/notes.txt').writeAsBytesSync([1]);
        File('${tmp.path}/img9.png').writeAsBytesSync([1]); // outside the folder
        expect(await nextVideoAssetId([kept], dir), 'img4');
        await sweepVideoAssets(dir, [kept]);
        expect(File('${dir.path}/img1.png').existsSync(), isTrue);
        expect(File('${dir.path}/img3.jpg').existsSync(), isFalse);
        expect(File('${dir.path}/notes.txt').existsSync(), isTrue);
        expect(File('${tmp.path}/img9.png').existsSync(), isTrue);
        expect(await nextVideoAssetId([kept], dir), 'img2');
      });
    });
  });

  group('camera moves, transitions and beat presets', () {
    test('a framing stays inside the picture, and a move eases from start to end', () {
      const f = VideoFraming(zoom: 1.2, x: 0.4, y: -0.4);
      final c = f.clamped;
      expect(c.x, closeTo((1 - 1 / 1.2) / 2, 1e-9));
      expect(const VideoFraming(zoom: 0.5).clamped.zoom, 1);
      final m = VideoCameraMove(from: const VideoFraming(), to: const VideoFraming(zoom: 2), ease: VideoEase.easeInOut);
      expect(m.at(0).zoom, 1);
      expect(m.at(1).zoom, 2);
      expect(m.at(0.25).zoom, lessThan(1.25)); // eased: slow at the start
      expect(VideoCameraMove.fromJson(m.toJson())!.toJson(), m.toJson());
    });

    test('presets set the drive, pulse and amount; the off-beat pulses between beats', () {
      final e = VideoEffect(kind: VideoEffectKind.glow);
      VideoEffectPreset.downbeat.apply(e);
      expect((e.drive, e.decay, e.amount), (VideoDrive.bar, 0.2, 0.8));
      expect(VideoEffectPreset.of(e), VideoEffectPreset.downbeat);
      VideoEffectPreset.offbeat.apply(e);
      expect(e.strength(2, VideoLevels.silent, 16), closeTo(e.amount, 1e-9));
      expect(e.strength(0, VideoLevels.silent, 16), 0);
      e.amount = 0.3;
      expect(VideoEffectPreset.of(e), isNull);
    });

    test('auto-cut picks transitions to match the style', () {
      expect(styledTransition(VideoStyle.energetic, CutTrigger.loudness, 32, 16), (VideoTransition.flash, 4.0));
      expect(styledTransition(VideoStyle.energetic, CutTrigger.interval, 32, 16), (VideoTransition.cut, 0.0));
      expect(styledTransition(VideoStyle.calm, CutTrigger.track, 32, 16).$1, VideoTransition.slide);
      expect(styledTransition(VideoStyle.minimal, CutTrigger.burst, 4, 16), (VideoTransition.crossfade, 2.0));
      final cuts = autoCut(_scene(), AutoCutSettings(), MusicVideoOptions(style: VideoStyle.energetic, seed: 3),
          start: 0, end: 256);
      expect(cuts.skip(1).map((c) => c.transition).toSet().length, greaterThan(1));
      final plain = autoCut(_scene(), AutoCutSettings(styledTransitions: false),
          MusicVideoOptions(style: VideoStyle.energetic, seed: 3), start: 0, end: 256);
      expect(plain.every((c) => c.transition == VideoTransition.cut || c.transition == VideoTransition.push), isTrue);
    });
  });

  group('saving', () {
    test('version 2 saves every new part and reads it back; version 1 reads as it was', () {
      final cut = VideoCut(id: 's1', start: 0, length: 32, transition: VideoTransition.glitch, transitionSteps: 2,
          camera: VideoCameraMove(), texts: [VideoText(id: 't1', kind: VideoTextKind.title)],
          images: [VideoImageLayer(id: 'i1', assetId: 'img1', placement: VideoImagePlacement.background)],
          effects: [VideoEffect(kind: VideoEffectKind.tint, drive: VideoDrive.offbeat)]);
      final doc = MusicVideoDoc(options: MusicVideoOptions(fps: 24, quality: VideoQuality.small),
          timeline: VideoTimeline([cut]), texts: [VideoText(id: 't2', text: 'Hi')],
          assets: [VideoImageAsset(id: 'img1', file: 'img1.png', name: 'cover.png', width: 64, height: 48)],
          images: [VideoImageLayer(id: 'i2', assetId: 'img1', start: 16, length: 8)]);
      final j = jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>;
      expect(j['version'], 2);
      final back = MusicVideoDoc.fromJson(j);
      expect(jsonEncode(back.toJson()), jsonEncode(doc.toJson()));
      expect(back.timeline.cuts.single.transition, VideoTransition.glitch);
      expect(back.timeline.cuts.single.camera, isNotNull);

      // A version 1 file (before 2026-11-12's second round): the same shots, none of the new parts.
      final v1 = {
        'version': 1,
        'options': {'fps': 60, 'title_card': true},
        'shots': [
          {'id': 's1', 'start': 0, 'length': 16, 'layout': {'preset': 'full', 'panels': [{'view': 'mixer'}]},
              'transition': 'push', 'transition_steps': 4},
        ],
        'auto_cut': {'interval': true},
        'snap': 'bar',
      };
      final old = MusicVideoDoc.fromJson(v1);
      expect(old.timeline.cuts.single.transition, VideoTransition.push);
      expect(old.texts, isEmpty);
      expect(old.assets, isEmpty);
      expect(old.images, isEmpty);
      expect(old.timeline.cuts.single.camera, isNull);
      expect((old.options.fps, old.options.quality), (60, VideoQuality.balanced));
      expect(old.autoCut.styledTransitions, isTrue);
      // A newer version is read for what this one knows.
      expect(MusicVideoDoc.fromJson({...v1, 'version': 9, 'future': 1}).timeline.cuts.length, 1);
    });
  });

  group('render', () {
    test('a queued frame that fails before its turn is held and thrown at its turn, in order', () async {
      final first = Completer<int>();
      final take1 = heldFuture(first.future);
      final take2 = heldFuture(Future<int>.error(StateError('frame 2 failed')));
      // Frame 2 fails while frame 1 is still pending: no unhandled error (the test would fail on one).
      await Future<void>.delayed(Duration.zero);
      first.complete(1);
      expect(await take1(), 1);
      await expectLater(take2(), throwsA(isA<StateError>()));
    });

    Future<(FrameHashEncoder, MusicVideoRender)> render(WidgetTester tester, Directory dir,
        {MusicVideoOptions? options, int? depth, bool draft = false, MusicVideoDoc? doc}) async {
      final enc = FrameHashEncoder();
      final o = options ?? MusicVideoOptions(resolution: VideoResolution.custom, customWidth: 128, customHeight: 224, seed: 5);
      final r = MusicVideoRender(projectJson: videoTestSong().toEngineJson(), scene: _scene(),
          options: draft ? o.draft() : o, startStep: 112, endStep: 144, encoder: enc, workDir: dir,
          audio: (p, q) => FakeVideoAudio(q), timeline: doc?.timeline, doc: doc, pipelineDepth: depth, draft: draft);
      await tester.runAsync(r.run);
      return (enc, r);
    }

    testWidgets('the pipeline draws the same frames as one at a time, and the profile says where the time went',
        (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_v2_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final (one, r1) = await render(tester, Directory('${tmp.path}/a'), depth: 1);
      final (three, r3) = await render(tester, Directory('${tmp.path}/b'), depth: 3);
      expect(r1.phase, VideoRenderPhase.done, reason: r1.error);
      expect(three.hashes, one.hashes);
      expect(one.frames, 120);
      // The frames drawn before this round (music_video_test.dart's pinned hashes) are unchanged.
      expect(one.hashes[0], '434202556405b4bf');
      expect(r3.profile.frames, 120);
      expect(r3.profile.videoSeconds, closeTo(4, 1e-9));
      expect(r3.profile.wallUs, greaterThan(0));
      expect(r3.profile.paintUs, greaterThan(0));
      expect(r3.profile.rasterUs, greaterThan(0));
      expect(r3.profile.summary, contains('per second of video'));
      expect(videoPipelineDepth(3840, 2160), 2);
      expect(videoPipelineDepth(7680, 4320), 1);
      expect(videoPipelineDepth(1080, 1920), 3);
    });

    testWidgets('24 fps and a draft: the frame counts follow the rate and size', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_v2_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final o = MusicVideoOptions(aspect: VideoAspect.portrait, resolution: VideoResolution.p720, fps: 24);
      final (full, rf) = await render(tester, Directory('${tmp.path}/f'),
          options: o..resolution = VideoResolution.custom..customWidth = 144..customHeight = 256);
      expect((full.frames, rf.frameCount), (96, 96)); // 4 s at 24 fps
      final (draft, rd) = await render(tester, Directory('${tmp.path}/d'), options: MusicVideoOptions(fps: 60), draft: true);
      expect(rd.draft, isTrue);
      expect(draft.frames, 60); // 4 s at 15 fps
      expect(rd.options.size, (360, 640));
    });

    testWidgets('a cancel mid-pipeline stops, lets the frames in flight go and leaves no file', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_v2_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final enc = FrameHashEncoder();
      final r = MusicVideoRender(projectJson: videoTestSong().toEngineJson(), scene: _scene(),
          options: MusicVideoOptions(resolution: VideoResolution.custom, customWidth: 128, customHeight: 128),
          startStep: 0, endStep: 256, encoder: enc, workDir: Directory('${tmp.path}/c'), audio: (p, q) => FakeVideoAudio(q),
          pipelineDepth: 3);
      r.addListener(() {
        if (r.framesDrawn >= 6) r.cancel();
      });
      expect(await tester.runAsync(r.run), isNull);
      expect(r.phase, VideoRenderPhase.cancelled);
      expect(enc.frames, lessThan(20));
      expect(Directory('${tmp.path}/c').existsSync(), isFalse);
    });

    testWidgets('the background job: one at a time, its chip shows progress and then Save', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_v2_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = videoTestSong();
      final jobs = MusicVideoJobs.instance;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: VideoRenderOverlay(state: s, child: const SizedBox()))));
      expect(find.byKey(const ValueKey('video-chip')), findsNothing);
      final r = MusicVideoRender(projectJson: s.project.toEngineJson(), scene: _scene(),
          options: MusicVideoOptions(resolution: VideoResolution.custom, customWidth: 128, customHeight: 128),
          startStep: 112, endStep: 128, encoder: FrameHashEncoder(), workDir: Directory('${tmp.path}/j'),
          audio: (p, q) => FakeVideoAudio(q));
      final out = await tester.runAsync(() => jobs.start(r, name: 'Song'));
      expect(out, isNotNull);
      await tester.pumpAndSettle();
      expect(find.text('Video ready'), findsOneWidget);
      expect(find.byKey(const ValueKey('video-chip-save')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-chip-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-chip')), findsNothing);
      expect(jobs.render, isNull);
    });
  });

  group('frames', () {
    testWidgets('every transition and overlay draws a frame (and three or more tracks still draw)', (tester) async {
      final scene = _scene();
      final image = (await tester.runAsync(() async => decodeVideoImage(await _png(64, 64))))!;
      addTearDown(image.dispose);
      for (final t in VideoTransition.values) {
        final doc = MusicVideoDoc(timeline: VideoTimeline([
          VideoCut(id: 's1', start: 0, length: 32, layout: VideoLayout.single(VideoShot.flythrough)),
          VideoCut(id: 's2', start: 32, length: 32, layout: VideoLayout.single(VideoShot.falling), transition: t,
              transitionSteps: 8, camera: VideoCameraMove(), texts: [VideoText(id: 't', text: 'Hi')],
              images: [VideoImageLayer(id: 'i', assetId: 'img1')]),
        ]), images: [VideoImageLayer(id: 'b', assetId: 'img1', placement: VideoImagePlacement.background)]);
        final plan = planVideo(scene, MusicVideoOptions(), doc.timeline, start: 0, end: 64);
        final input = VideoFrameInput.forOptions(scene: scene, plan: plan, step: 36, seconds: 18,
            options: MusicVideoOptions(), doc: doc, bitmaps: {'img1': image}, rangeEnd: 64);
        final bytes = await tester.runAsync(() => rasterizeVideoFrame(input, 72, 128));
        expect(bytes!.length, 72 * 128 * 4, reason: t.name);
      }
    });
  });

  group('the sheet at 360 dp', () {
    Future<AppState> pumpSheet(WidgetTester tester, {MusicVideoDoc? doc}) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = videoTestSong()..musicVideo = (doc ?? MusicVideoDoc(timeline: VideoTimeline([
        VideoCut(id: 's1', start: 0, length: 64),
        VideoCut(id: 's2', start: 64, length: 64, layout: VideoLayout(preset: VideoLayoutPreset.bigStrip)),
      ]))).toJson();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MusicVideoPanel(state: s,
          encoder: FrameHashEncoder(maxSide: 2160)))));
      await tester.pumpAndSettle();
      return s;
    }

    testWidgets('the preview, lane, tabs and export bar all show; each tab opens without overflow', (tester) async {
      await pumpSheet(tester);
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      Rect r(String k) => tester.getRect(find.byKey(ValueKey(k)));
      // Pinned: the render button sits at the bottom, inside the screen; the preview at the top.
      expect(r('video-render').bottom, lessThanOrEqualTo(screen.height));
      expect(r('video-render').bottom, greaterThan(screen.height - 90));
      expect(r('video-preview-frame').top, lessThan(r('video-tab-shots').top));
      for (final t in VideoTab.values) {
        await tester.tap(find.byKey(ValueKey('video-tab-${t.name}')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: t.name);
        // Still pinned on every tab.
        expect(r('video-render').bottom, lessThanOrEqualTo(screen.height), reason: t.name);
        expect(find.byKey(const ValueKey('video-preview-frame')), findsOneWidget);
      }
      final exportList = find.descendant(of: find.byKey(const PageStorageKey('video-tab-export')),
          matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('video-quality-note')), 200, scrollable: exportList);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('video-beat-summary')), 200, scrollable: exportList);
      expect(find.textContaining('on the beat'), findsWidgets);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Look and Text & media edit the shot chosen on the lane; a cut marker picks the transition',
        (tester) async {
      final s = await pumpSheet(tester);
      MusicVideoDoc saved() => MusicVideoDoc.fromJson(s.project.musicVideo);
      // Look, with no shot chosen, says how; choosing one shows its looks and effects.
      await tester.tap(find.byKey(const ValueKey('video-tab-look')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pick a shot on the lane'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-lane-shot-s2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-look-s2')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('video-look-palette-warm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-look-palette-warm')));
      await tester.pumpAndSettle();
      expect(saved().timeline.byId('s2')!.layout.panels.first.look.palette, VideoPalette.warm);
      // An effect with a beat preset.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('video-fx-add')), 200,
          scrollable: find.descendant(of: find.byKey(const PageStorageKey('video-tab-look')), matching: find.byType(Scrollable)).first);
      await tester.ensureVisible(find.byKey(const ValueKey('video-fx-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-fx-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-fx-add-glow')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('video-fx-preset-0-downbeat')), 200,
          scrollable: find.descendant(of: find.byKey(const PageStorageKey('video-tab-look')), matching: find.byType(Scrollable)).first);
      await tester.drag(find.descendant(of: find.byKey(const PageStorageKey('video-tab-look')), matching: find.byType(Scrollable)).first,
          const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('video-fx-preset-0-downbeat')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-fx-preset-0-downbeat')));
      await tester.pumpAndSettle();
      expect(saved().timeline.byId('s2')!.effects.single.drive, VideoDrive.bar);

      // Text & media: a title over the whole video, and one over the chosen shot.
      await tester.tap(find.byKey(const ValueKey('video-tab-media')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('video-vtext-add')), 150,
          scrollable: find.descendant(of: find.byKey(const PageStorageKey('video-tab-media')), matching: find.byType(Scrollable)).first);
      await tester.ensureVisible(find.byKey(const ValueKey('video-vtext-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-vtext-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-vtext-add-title')));
      await tester.pumpAndSettle();
      expect(saved().texts.single.kind, VideoTextKind.title);
      final shotAdd = find.byKey(const ValueKey('video-stext-add'));
      await tester.scrollUntilVisible(shotAdd, 200,
          scrollable: find.descendant(of: find.byKey(const PageStorageKey('video-tab-media')), matching: find.byType(Scrollable)).first);
      await tester.ensureVisible(shotAdd);
      await tester.pumpAndSettle();
      await tester.tap(shotAdd);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-stext-add-free')));
      await tester.pumpAndSettle();
      expect(saved().timeline.byId('s2')!.texts.single.text, 'Your text');
      // Undo takes the shot's text away again (one step), redo brings it back.
      final editor = tester.state<MusicVideoEditorState>(find.byType(MusicVideoEditor));
      editor.undo();
      await tester.pumpAndSettle();
      expect(saved().timeline.byId('s2')!.texts, isEmpty);
      editor.redo();
      await tester.pumpAndSettle();
      expect(saved().timeline.byId('s2')!.texts.length, 1);

      // A tap on the cut marker between the shots opens the transition picker.
      await tester.tap(find.byKey(const ValueKey('video-lane-cut-1')));
      await tester.pumpAndSettle();
      expect(find.text('INTO SHOT 2 · 5.1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-transition-wipe')).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('video-transition-length-16')).last);
      await tester.pumpAndSettle();
      expect((saved().timeline.byId('s2')!.transition, saved().timeline.byId('s2')!.transitionSteps),
          (VideoTransition.wipe, 16.0));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Draft renders in the background and offers Save', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('caw_video_v2_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      s.project = videoTestSong()..loopBars = 2;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MusicVideoPanel(state: s, encoder: FrameHashEncoder(),
          audio: (p, q) => FakeVideoAudio(q), workDir: tmp))));
      await tester.pumpAndSettle();
      // Tapped in the real zone, so the render's files and frames run for real.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('video-draft')));
        bool ended(MusicVideoRender? r) => r != null && r.phase.index >= VideoRenderPhase.done.index;
        for (var i = 0; i < 1500 && !ended(MusicVideoJobs.instance.render); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      final r = MusicVideoJobs.instance.render!;
      expect((r.draft, r.phase), (true, VideoRenderPhase.done));
      expect(r.options.size, (360, 640));
      expect(find.byKey(const ValueKey('video-save')), findsOneWidget);
      expect(find.textContaining('Draft: '), findsOneWidget);
      MusicVideoJobs.instance.dismiss();
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('goldens', () {
    // Text laid out by the tests before the fonts loaded mustn't be reused in a golden.
    setUp(clearVideoTextCache);
    for (final t in [VideoTab.shots, VideoTab.look, VideoTab.media, VideoTab.export]) {
      testWidgets('golden: the sheet at 360 dp, ${t.label}', (tester) async {
        final s = AppState(settings: Settings());
        addTearDown(s.dispose);
        s.project = videoTestSong()
          ..musicVideo = MusicVideoDoc(
            timeline: VideoTimeline([
              VideoCut(id: 's1', start: 0, length: 64, effects: [VideoEffect(kind: VideoEffectKind.glow, drive: VideoDrive.beat)]),
              VideoCut(id: 's2', start: 64, length: 64, layout: VideoLayout(preset: VideoLayoutPreset.bigStrip),
                  transition: VideoTransition.wipe, transitionSteps: 4,
                  texts: [VideoText(id: 't1', kind: VideoTextKind.title)]),
              VideoCut(id: 's3', start: 128, length: 128, layout: VideoLayout.single(VideoShot.falling)),
            ]),
            texts: [VideoText(id: 't2', text: 'Out now', y: 0.85)],
          ).toJson();
        await pumpGolden(tester, Scaffold(body: MusicVideoPanel(state: s, encoder: FrameHashEncoder(maxSide: 2160))),
            const Size(360, 780));
        await tester.tap(find.byKey(const ValueKey('video-lane-shot-s2')));
        await tester.tap(find.byKey(ValueKey('video-tab-${t.name}')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/music_video_${t.name}_phone.png'));
        await tester.pump(const Duration(seconds: 1));
      });
    }

    testWidgets('golden: one frame for each transition and each overlay', (tester) async {
      await loadAppFonts(tester); // before the frames are recorded, so their text has real glyphs
      final scene = _scene();
      final image = (await tester.runAsync(() async => decodeVideoImage(await _png(64, 64))))!;
      addTearDown(image.dispose);
      final frames = <(String, VideoFrameInput)>[];
      ShotPlan plan(MusicVideoDoc doc) => planVideo(scene, MusicVideoOptions(), doc.timeline, start: 0, end: 64);
      VideoFrameInput at(MusicVideoDoc doc, double step) => VideoFrameInput.forOptions(scene: scene, plan: plan(doc),
          step: step, seconds: 10, options: MusicVideoOptions(titleCard: false, title: 'Night Drive', artist: 'C.A.W'),
          doc: doc, bitmaps: {'img1': image}, rangeEnd: 64);
      for (final t in VideoTransition.values) {
        final doc = MusicVideoDoc(timeline: VideoTimeline([
          VideoCut(id: 's1', start: 0, length: 32, layout: VideoLayout.single(VideoShot.flythrough)),
          VideoCut(id: 's2', start: 32, length: 32, layout: VideoLayout.single(VideoShot.falling), transition: t,
              transitionSteps: 8),
        ]));
        frames.add((t.label, at(doc, 34.5)));
      }
      for (final a in VideoTextAnim.values) {
        final doc = MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64)]),
            texts: [VideoText(id: 't', kind: VideoTextKind.title, size: 0.14, animIn: a, inBeats: 2, beatSync: true)]);
        frames.add(('Text ${a.label}', at(doc, 3)));
      }
      frames.add(('Image overlay', at(MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64)]),
          images: [VideoImageLayer(id: 'i', assetId: 'img1', size: 0.4)]), 8)));
      frames.add(('Image background', at(MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          layout: VideoLayout.single(VideoShot.falling))]),
          images: [VideoImageLayer(id: 'b', assetId: 'img1', placement: VideoImagePlacement.background, opacity: 0.6)]), 8)));
      frames.add(('Camera move', at(MusicVideoDoc(timeline: VideoTimeline([VideoCut(id: 's1', start: 0, length: 64,
          camera: VideoCameraMove.presets['Pan right']!())])), 40)));
      frames.add(('Title card', VideoFrameInput.forOptions(scene: scene, plan: plan(MusicVideoDoc()), step: 2, seconds: 1,
          options: MusicVideoOptions(title: 'Night Drive', artist: 'C.A.W'))));
      final pictures = <(String, ui.Image)>[];
      for (final (name, f) in frames) {
        final img = (await tester.runAsync(() => recordVideoFrame(f, 90, 160).toImage(90, 160)))!;
        pictures.add((name, img));
      }
      addTearDown(() {
        for (final (_, i) in pictures) {
          i.dispose();
        }
      });
      await pumpGolden(tester, Scaffold(body: Padding(padding: const EdgeInsets.all(6), child: Wrap(spacing: 6, runSpacing: 6,
          children: [
            for (final (name, img) in pictures)
              SizedBox(width: 90, child: Column(mainAxisSize: MainAxisSize.min, children: [
                RawImage(image: img, width: 90, height: 160),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9)),
              ])),
          ]))), const Size(600, 760));
      await expectLater(goldenScreen, matchesGoldenFile('goldens/music_video_frames.png'));
    });
  });
}

