// Lark's page and the clip pitch editor (1.1.0) with a fake engine: the note line drags Speed and Humanize, Custom shows its notes, Edit pitch… opens the editor; the editor analyses with progress and cancel, draws the notes, a blob drags up (snapped) and sideways and at its edge, the knobs shape the chosen note, its own undo, and a render lands as a new take or in place of the clip, one project undo step; the audio clip's hold menu has Edit pitch…. With CAW_PITCH_SCREENS=<dir>, phone PNGs at 2x.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/pitch_clip.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/audio_clip_view.dart';
import 'package:caw/ui/arrange/pitch_editor.dart';
import 'package:caw/ui/devices/effects/voice/lark_device.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

final _dir = Platform.environment['CAW_PITCH_SCREENS'];

const _rate = 48000, _hop = 256;

/// A phrase's analysis: four notes (A3, C4 a little flat, D4 with vibrato, E4), 0.5 s each with short rests.
PitchAnalysis fakeAnalysis() {
  const pitches = [57.0, 59.82, 62.05, 64.0];
  final frames = (2.4 * _rate).round();
  final hops = frames ~/ _hop + 1;
  final midi = Float32List(hops), voicing = Float32List(hops), rms = Float32List(hops)..fillRange(0, hops, -90);
  final notes = <PitchNote>[];
  for (final (i, p) in pitches.indexed) {
    final s = ((0.1 + i * 0.58) * _rate).round(), e = s + (0.5 * _rate).round();
    notes.add(PitchNote(index: i, start: s, end: e, pitch: p, vibratoRate: i == 2 ? 5.5 : 0, vibratoCents: i == 2 ? 30 : 4));
    for (var h = s ~/ _hop; h < e ~/ _hop; h++) {
      final t = (h * _hop - s) / _rate;
      midi[h] = p + (i == 2 ? 0.3 * math.sin(2 * math.pi * 5.5 * t) : 0.04 * math.sin(t * 7));
      voicing[h] = 1;
      rms[h] = -12 - 14 * (t - 0.25).abs() / 0.25;
    }
  }
  return PitchAnalysis(sampleRate: _rate, frames: frames, hopFrames: _hop, notes: notes, midi: midi, voicing: voicing, rmsDb: rms);
}

/// The editor's engine, in memory: an analysis that finishes when [finish] completes, renders that record their
/// edits and say they wrote a file.
class FakePitchBackend implements PitchClipBackend {
  /// Set: the analysis waits for it.
  Completer<void>? finish;
  final rendered = <Map<int, PitchNoteEdit>>[];
  final released = <PitchClipSession>[];
  String? fail;

  @override
  PitchJob<PitchClipSession> analyse(String path) => PitchJob((job) async {
        job.stage.value = 'Listening';
        job.progress.value = 0.4;
        if (finish case final f?) await f.future;
        if (fail != null) throw PitchClipError(fail!);
        return PitchClipSession(fakeAnalysis());
      });

  @override
  PitchJob<PitchRenderResult> render(PitchClipSession session, Map<int, PitchNoteEdit> edits, String outPath) =>
      PitchJob((job) async {
        rendered.add(edits);
        return PitchRenderResult(path: outPath, frames: session.analysis.frames, sampleRate: _rate, channels: 1,
            notesEdited: edits.length);
      });

  @override
  void release(PitchClipSession session) => released.add(session);
}

ProjectDoc vocalProject() => ProjectDoc(id: 'p', name: 'Lark', bpm: 120, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/vox.wav', name: 'vox', seconds: 2.4, channels: 1, sourceRate: _rate),
    ], layers: [
      LayerDoc(id: 't1', name: 'Vox', color: 0, audioClips: [AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: 0, lengthSeconds: 2.4)]),
    ]);

void main() {
  late FakePitchBackend backend;
  final motion = Motion.setting;
  setUp(() {
    backend = FakePitchBackend();
    pitchClipBackendFor = (_) => backend;
    Motion.setting = MotionLevel.off;
  });
  tearDown(() {
    pitchClipBackendFor = null;
    Motion.setting = motion;
  });

  AppState vocal() {
    final s = AppState(settings: Settings());
    s.project = vocalProject();
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    addTearDown(s.dispose);
    return s;
  }

  AudioClipDoc clipOf(AppState s) => s.project.layers.first.audioClips.first;

  Future<PitchEditorState> openEditor(WidgetTester tester, AppState s, {Size size = const Size(412, 915)}) async {
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    unawaited(showPitchEditor(ctx, s, s.project.layers.first, clipOf(s)));
    await tester.pumpAndSettle();
    // The analysis lands a few microtasks later.
    final ed = tester.state<PitchEditorState>(find.byType(PitchEditorScreen));
    for (var i = 0; i < 20 && ed.analysis == null && backend.finish == null && backend.fail == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    return ed;
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(from + by * (i / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  group('the scale maths', () {
    test('the classes follow the key and the scale, Custom its switches', () {
      expect(larkClasses(0, 1, List.filled(12, true)), {0, 2, 4, 5, 7, 9, 11});
      expect(larkClasses(2, 1, List.filled(12, true)), {2, 4, 6, 7, 9, 11, 1});
      expect(larkClasses(9, 10, List.filled(12, true)), {9, 0, 2, 4, 7});
      expect(larkClasses(0, 12, [for (var k = 0; k < 12; k++) k == 0 || k == 7]), {0, 7});
    });
    test('a pitch snaps to the nearest allowed note', () {
      expect(larkTarget(60.8, {0, 2, 4, 5, 7, 9, 11}), 60);
      expect(larkTarget(61.6, {0, 2, 4, 5, 7, 9, 11}), 62);
      expect(larkTarget(61.6, {}), 61.6);
      expect(snapPitchOffset(59.82, 1.7), closeTo(2.18, 1e-9));
    });
    test('edits go to the engine as only what differs', () {
      final j = pitchEditsJson({2: const PitchNoteEdit(pitch: 2, vibrato: 0.5), 0: PitchNoteEdit.none,
        1: const PitchNoteEdit(timeFrames: 999999999)}, sampleRate: _rate);
      expect(j, {'edits': [{'note': 1, 'time_frames': 10 * _rate}, {'note': 2, 'pitch': 2.0, 'vibrato': 0.5}]});
    });
    test('an analysis from untrusted JSON is bounded', () {
      final a = PitchAnalysis.fromJson({'ok': true, 'sample_rate': 48000, 'frames': 1000, 'hop_frames': 256, 'notes': [
        {'start': 10, 'end': 500, 'pitch': 60.2}, {'start': 600, 'end': 500, 'pitch': 61}, {'start': 0, 'end': 99999, 'pitch': 'x'},
        {'start': 0, 'end': 99999, 'pitch': 300},
      ]}, midi: Float32List(4), voicing: Float32List(4), rmsDb: Float32List(4))!;
      expect(a.notes.length, 2);
      expect(a.notes[1].end, 1000);
      expect(a.notes[1].pitch, 127);
      expect(PitchAnalysis.fromJson({'ok': false}, midi: Float32List(0), voicing: Float32List(0), rmsDb: Float32List(0)), isNull);
    });
  });

  group("Lark's page", () {
    late DeviceDisplaySource source;
    setUp(() {
      source = DeviceDisplaySource.current;
      DeviceDisplaySource.current = FakeDisplay();
      MotionClock.hold = true;
    });
    tearDown(() {
      DeviceDisplaySource.current = source;
      MotionClock.hold = false;
    });

    testWidgets('the note line drags Speed and Humanize; Custom shows its notes; Edit pitch… opens the editor',
        (tester) async {
      final s = stateWith('org.caw.pitchfix');
      addTearDown(s.dispose);
      s.starting = false;
      final layer = s.project.layers.first;
      s.project.assets.add(AudioAssetDoc(id: 'a1', path: '/abs/vox.wav', name: 'vox', seconds: 2.4, channels: 1));
      layer.audioClips.add(AudioClipDoc(id: 'c1', assetId: 'a1', lengthSeconds: 2.4));
      final t = targetOf(s, 'org.caw.pitchfix');
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), const Size(412, 915));
      openDevice(ctx, s, 'org.caw.pitchfix');
      await tester.pumpAndSettle();
      expect(find.byType(LarkPage), findsOneWidget);
      expect(find.byKey(const ValueKey('toggle-keep_vibrato')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-fallback')), findsNothing);

      final speed = t.value('speed'), humanize = t.value('humanize');
      await drag(tester, tester.getCenter(find.byKey(const ValueKey('lark-hero'))), const Offset(60, -50));
      expect(t.value('speed'), greaterThan(speed));
      expect(t.value('humanize'), greaterThan(humanize));

      expect(find.byKey(const ValueKey('toggle-note_cs')), findsNothing);
      t.set('scale', 12);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toggle-note_cs')), findsOneWidget, reason: "Custom's note switches");

      await tester.ensureVisible(find.byKey(const ValueKey('lark-edit-pitch')));
      await tester.tap(find.byKey(const ValueKey('lark-edit-pitch')));
      await tester.pumpAndSettle();
      expect(find.byType(PitchEditorScreen), findsOneWidget);
      expect(find.textContaining('Edit pitch · vox'), findsOneWidget);
    });
  });

  group('the clip pitch editor', () {
    testWidgets('analyses with progress and cancel; a failure says why in a line', (tester) async {
      final s = vocal();
      backend.finish = Completer();
      final ed = await openEditor(tester, s);
      expect(find.byKey(const ValueKey('pitch-progress')), findsOneWidget);
      expect(find.text('Listening…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pitch-cancel')));
      backend.finish!.complete();
      backend.finish = null;
      await tester.pumpAndSettle();
      expect(find.byType(PitchEditorScreen), findsNothing, reason: 'cancel closes the editor');
      expect(ed.mounted, isFalse);

      backend.fail = 'the file could not be read';
      await openEditor(tester, s);
      expect(find.byKey(const ValueKey('pitch-error')), findsOneWidget);
      expect(find.text('the file could not be read'), findsOneWidget);
    });

    testWidgets('a blob drags up onto a semitone, sideways in time and at its edge; knobs shape it; its own undo',
        (tester) async {
      final s = vocal();
      final ed = await openEditor(tester, s);
      expect(find.byKey(const ValueKey('pitch-progress')), findsNothing);
      expect(ed.analysis!.notes.length, 4);
      expect(find.byKey(const ValueKey('pitch-render')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pitch-render'))).onPressed, isNull,
          reason: 'nothing to render yet');

      // Up about two rows: C4 (a little flat) snaps to D4 exactly.
      final c = ed.noteCenterGlobal(1)!;
      final rowPx = (ed.yOf(60) - ed.yOf(61)).abs();
      await drag(tester, c, Offset(0, -rowPx * 2.1));
      expect(ed.selected, 1);
      expect(ed.editOf(1).pitch, closeTo(62 - 59.82, 1e-9));
      expect(ed.editOf(1).timeFrames, 0, reason: 'a vertical drag keeps its time');
      expect(find.textContaining('→  D4 ±0 ct'), findsOneWidget);

      // Sideways: a time move only.
      await drag(tester, ed.noteCenterGlobal(1)!, const Offset(40, 0));
      expect(ed.editOf(1).timeFrames, greaterThan(0));
      expect(ed.editOf(1).pitch, closeTo(62 - 59.82, 1e-9));

      // The right edge stretches it.
      final a = ed.analysis!;
      final n = a.notes[0];
      final right = ed.noteCenterGlobal(0)! + Offset((ed.xOf(n.end / _rate) - ed.xOf((n.start + n.end) / 2 / _rate)) - 3, 0);
      await drag(tester, right, const Offset(30, 0));
      expect(ed.selected, 0);
      expect(ed.editOf(0).stretch, greaterThan(1));
      expect(ed.editOf(0).timeFrames, 0);

      // The knobs set the chosen note's drift, vibrato and transition.
      await tester.drag(find.byKey(const ValueKey('pitch-vibrato')), const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(ed.editOf(0).vibrato, lessThan(1));

      // Snap off: a drag lands between semitones.
      await tester.tap(find.byKey(const ValueKey('pitch-snap')));
      await tester.pumpAndSettle();
      expect(ed.snap, isFalse);
      await drag(tester, ed.noteCenterGlobal(3)!, Offset(0, -rowPx * 1.6));
      expect((ed.editOf(3).pitch * 100).round() % 100, isNot(0));

      // The editor's undo goes back a gesture at a time; a double tap resets a note.
      final before = Map.of(ed.edits);
      await tester.tap(find.byKey(const ValueKey('pitch-undo')));
      await tester.pumpAndSettle();
      expect(ed.edits.containsKey(3), isFalse);
      await tester.tap(find.byKey(const ValueKey('pitch-redo')));
      await tester.pumpAndSettle();
      expect(ed.edits, before);
      final g = ed.noteCenterGlobal(1)!;
      await tester.tapAt(g);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(g);
      await tester.pumpAndSettle();
      expect(ed.edits.containsKey(1), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders as a new take, one project undo step', (tester) async {
      final s = vocal();
      final ed = await openEditor(tester, s);
      await drag(tester, ed.noteCenterGlobal(2)!, Offset(0, (ed.yOf(60) - ed.yOf(61)) * 1.1));
      expect(ed.editOf(2).pitch, closeTo(61 - 62.05, 1e-9));
      await tester.tap(find.byKey(const ValueKey('pitch-render')));
      await tester.pumpAndSettle();
      expect(backend.rendered.single.keys, [2]);
      expect(find.byType(PitchEditorScreen), findsNothing, reason: 'the render closes the editor');
      expect(find.text('Pitch edits rendered as a new take'), findsOneWidget);
      expect(backend.released, hasLength(1), reason: 'the session is let go');
      final clip = clipOf(s);
      expect(clip.takes.length, 2);
      expect(clip.takes.first, 'a1');
      expect(clip.assetId, clip.takes.last);
      expect(s.project.asset(clip.assetId)!.name, 'vox (pitch)');
      expect(s.project.asset(clip.assetId)!.path, contains('pitch_c1_'));
      expect(s.undo(), isTrue);
      expect(clipOf(s).assetId, 'a1');
      expect(clipOf(s).takes, isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('renders in place of the clip; leaving with edits asks first', (tester) async {
      final s = vocal();
      var ed = await openEditor(tester, s);
      await drag(tester, ed.noteCenterGlobal(0)!, const Offset(30, 0));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard pitch edits?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      ed = tester.state<PitchEditorState>(find.byType(PitchEditorScreen));
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      expect(ed.target, PitchRenderTarget.replace);
      await tester.tap(find.byKey(const ValueKey('pitch-render')));
      await tester.pumpAndSettle();
      final clip = clipOf(s);
      expect(clip.takes, isEmpty);
      expect(clip.assetId, isNot('a1'));
      expect(s.project.asset('a1'), isNotNull, reason: 'the original stays for undo');
      expect(s.undo(), isTrue);
      expect(clipOf(s).assetId, 'a1');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets("the audio clip's hold menu opens it", (tester) async {
      final s = vocal();
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), const Size(412, 915));
      unawaited(showAudioClipMenu(ctx, s, s.project.layers.first, clipOf(s), const Offset(200, 300)));
      await tester.pumpAndSettle();
      expect(find.text('Edit pitch…'), findsOneWidget);
      await tester.tap(find.text('Edit pitch…'));
      await tester.pumpAndSettle();
      expect(find.byType(PitchEditorScreen), findsOneWidget);
    });

    testWidgets('fits a phone in both orientations and a desktop', (tester) async {
      for (final size in const [Size(360, 740), Size(844, 390), Size(1280, 800)]) {
        final s = vocal();
        await openEditor(tester, s, size: size);
        expect(tester.takeException(), isNull, reason: '$size');
        await tester.pumpWidget(const SizedBox());
      }
    });

    if (_dir != null) {
      testWidgets('screens', (tester) async {
        Future<void> shot(String name) async {
          final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
          await tester.runAsync(() async {
            final img = await ro.toImage(pixelRatio: 2);
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            Directory(_dir!).createSync(recursive: true);
            File('${_dir!}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
          });
        }

        final s = vocal();
        final ed = await openEditor(tester, s);
        await drag(tester, ed.noteCenterGlobal(1)!, Offset(0, -(ed.yOf(60) - ed.yOf(61)).abs() * 2.1));
        await shot('pitch_editor_phone');
        await tester.pumpWidget(const SizedBox());
        final w = vocal();
        await openEditor(tester, w, size: const Size(1280, 800));
        await shot('pitch_editor_wide');
      });
    }
  });
}
