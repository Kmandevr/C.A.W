// Tests automation writing (Touch, Latch, Write, Read; thinning; one undo step per take; the Automate button) and the
// recording flow (the on-screen keys and pads playing and recording a take, the "Keep take?" toast, loop takes and
// their picker, and the count-in's timing with the engine, which needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/automation_writer.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/frame/live_keys.dart';
import 'package:caw/ui/frame/record_tools.dart';
import 'package:caw/ui/volume_fader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// An AppState whose transport is set by the test: playing or not, and where the playhead is.
class PlayState extends AppState {
  bool playing = false;
  double at = 0;
  final on = <(String, double, double)>[];
  int offs = 0;
  @override
  bool get transportOn => playing;
  @override
  double get playheadStep => at;
  @override
  void previewOn(String layerId, int id, double pitch, double velocity) => on.add((layerId, pitch, velocity));
  @override
  void previewOff(int id) => offs++;

  /// Stops the transport (the writer and the recorder both end their takes on the change).
  void stop() {
    playing = false;
    stopPlayback();
  }
}

PlayState playState() {
  final s = PlayState()
    ..project = (ProjectDoc(id: 'p', name: 'Test')
      ..layers.addAll([
        LayerDoc(id: 'L1', name: 'Keys', color: 0, volume: 1),
        LayerDoc(id: 'L2', name: 'Drums', color: 1, instrument: ComponentUseDoc('org.caw.drum.kick', {})),
      ]));
  s.ready = true;
  s.starting = false;
  return s;
}

List<(double, double)> pointsOf(AutomationLaneDoc lane) => [for (final p in lane.points) (p.step, p.value)];

void main() {
  group('automation writing', () {
    late PlayState s;
    late AutomationWriter w;
    LayerDoc l1() => s.project.layers.first;
    AutomationLaneDoc? lane(String target) => l1().automation.where((a) => a.target == target).firstOrNull;

    setUp(() {
      s = playState();
      w = AutomationWriter(s, pointers: false)..setArmed(true);
      s.playing = true;
    });
    tearDown(() => w.dispose());

    test('Touch writes while the control is held, then returns to the lane', () {
      w.setMode(AutomationMode.touch);
      w.pointerDown();
      s.at = 4;
      s.mixLayer(l1(), volume: 0.5);
      expect(w.writing, isTrue);
      s.at = 6;
      s.mixLayer(l1(), volume: 0.25);
      s.at = 8;
      w.pointerUp(); // let go
      expect(w.writing, isFalse);
      expect(pointsOf(lane('volume')!), [(3.99, 1.0), (4.0, 0.5), (6.0, 0.25), (8.0, 0.25), (8.25, 1.0)],
          reason: 'the lane was 0 dB (the fader before the touch) and goes back there after it');
      // A second touch over an existing lane keeps the lane outside it.
      w.pointerDown();
      s.at = 12;
      s.mixLayer(l1(), pan: -0.5);
      s.at = 13;
      w.pointerUp();
      expect(lane('pan')!.points.first.value, 0);
      expect(lane('pan')!.points.last.value, 0);
      expect(lane('volume')!.points.length, 5, reason: 'the volume lane is untouched by the pan write');
    });

    test('Touch over an existing lane suspends it in the engine while held and keeps the lane around the write', () {
      l1().automation.add(AutomationLaneDoc(target: 'pan', points: [
        AutomationPointDoc(step: 0, value: -1), AutomationPointDoc(step: 16, value: 1)]));
      w.pointerDown();
      s.at = 4;
      s.mixLayer(l1(), pan: 0.5);
      expect(s.suspendedLanes, contains(automationKey('track', 'pan', layerId: 'L1')));
      s.at = 6;
      w.pointerUp();
      expect(s.suspendedLanes, isEmpty);
      final p = pointsOf(lane('pan')!);
      expect(p.first, (0.0, -1.0));
      expect(p.last, (16.0, 1.0));
      expect(p.where((x) => x.$1 == 6.25).single.$2, closeTo(-1 + 2 * 6.25 / 16, 1e-9), reason: 'back to the old lane');
    });

    test('a smooth move is thinned to a few points', () {
      w.pointerDown();
      for (var i = 0; i <= 64; i++) {
        s.at = 4 + i / 8; // 8 moves per step: a straight ramp of pan
        s.mixLayer(l1(), pan: -1 + i / 32);
      }
      w.pointerUp();
      final p = lane('pan')!.points;
      expect(p.length, lessThanOrEqualTo(5), reason: 'a ramp is two points, plus the anchor and the return');
      expect(p.any((x) => x.step == 12 && x.value == 1), isTrue);
    });

    test('Latch keeps the last value until stop', () {
      w.setMode(AutomationMode.latch);
      w.pointerDown();
      s.at = 4;
      s.mixLayer(l1(), volume: 0.5);
      s.at = 5;
      w.pointerUp();
      expect(w.writing, isTrue, reason: 'latched');
      s.at = 12;
      s.tick.value++;
      s.stop();
      expect(w.writing, isFalse);
      expect(pointsOf(lane('volume')!), [(3.99, 1.0), (4.0, 0.5), (12.0, 0.5)],
          reason: 'a new lane holds the last value after the take');
    });

    test('Write overwrites every lane from play to stop, then falls back to Read', () {
      l1().automation.add(AutomationLaneDoc(target: 'pan', points: [
        AutomationPointDoc(step: 0, value: -1), AutomationPointDoc(step: 16, value: 1)]));
      w.setMode(AutomationMode.write);
      s.meters = const EngineMeters(playing: true);
      s.at = 0;
      s.tick.value++; // the first tick while playing starts the pass
      expect(w.writing, isTrue);
      expect(s.suspendedLanes, isNotEmpty, reason: 'the controls play, not the lanes being overwritten');
      w.pointerDown();
      s.at = 4;
      s.mixLayer(l1(), pan: 0.5);
      w.pointerUp();
      expect(w.writing, isTrue, reason: 'Write goes on after a release');
      s.at = 8;
      s.tick.value++;
      s.stop();
      expect(pointsOf(lane('pan')!), [(0.0, 0.0), (4.0, 0.5), (8.0, 0.5), (8.25, -1 + 2 * 8.25 / 16), (16.0, 1.0)]);
      expect(w.mode, AutomationMode.read);
      expect(s.settings.automationMode, 'read');
    });

    test('Read and a disarmed button write nothing', () {
      w.setMode(AutomationMode.read);
      w.pointerDown();
      s.at = 4;
      s.mixLayer(l1(), volume: 0.5);
      w.pointerUp();
      w.setMode(AutomationMode.touch);
      w.setArmed(false);
      w.pointerDown();
      s.mixLayer(l1(), volume: 0.4);
      w.pointerUp();
      expect(l1().automation, isEmpty);
    });

    test('a stopped transport writes nothing', () {
      s.playing = false;
      w.pointerDown();
      s.mixLayer(l1(), volume: 0.5);
      w.pointerUp();
      expect(l1().automation, isEmpty);
    });

    test('native and module parameters write project lanes; a volume lane reaches +12 dB', () {
      w.pointerDown();
      s.at = 2;
      s.mixLayer(l1(), volume: 3.0); // +9.5 dB
      s.at = 3;
      w.pointerUp();
      expect(lane('volume')!.points.map((p) => p.value), contains(3.0));
      expect(ProjectDoc.fromJson(s.project.toJson()).layers.first.automation.first.points.map((p) => p.value),
          contains(3.0), reason: 'kept by the project file');
      final drums = s.project.layers[1];
      w.pointerDown();
      s.at = 4;
      s.onParamMove!(const AutomationTarget('instrument', 'decay', layerId: 'L2'), 0.7);
      drums.instrument!.params['decay'] = 0.7;
      s.at = 5;
      w.pointerUp();
      final pl = s.project.automation.single;
      expect((pl.targetType, pl.layerId, pl.target), ('instrument', 'L2', 'decay'));
      expect(pl.points.map((p) => p.value), contains(0.7));
    });

    test('one undo step takes back the whole take', () {
      w.pointerDown();
      s.at = 4;
      s.mixLayer(l1(), volume: 0.5);
      w.pointerUp();
      w.pointerDown();
      s.at = 8;
      s.mixLayer(l1(), pan: 0.5);
      w.pointerUp();
      s.stop();
      expect(l1().automation.length, 2);
      expect(s.undo(), isTrue);
      expect(s.project.layers.first.automation, isEmpty, reason: 'both writes were one take');
    });

    test('merge keeps what the lane had before and after the written span', () {
      final old = [AutomationPointDoc(step: 0, value: 0), AutomationPointDoc(step: 10, value: 1),
          AutomationPointDoc(step: 20, value: 0)];
      final out = AutomationWriter.merge(old, [(8, 0.5), (12, 0.5)], original: 0, returns: true);
      expect([for (final p in out) (p.step, p.value)],
          [(0.0, 0.0), (7.99, 0.799), (8.0, 0.5), (12.0, 0.5), (12.25, 1 - 2.25 / 10), (20.0, 0.0)]);
    });
  });

  testWidgets('the Automate button arms on a tap, picks its mode on a long-press, and a held fader writes',
      (tester) async {
    final s = playState();
    final w = AutomationWriter(s);
    addTearDown(w.dispose);
    final l = s.project.layers.first;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          AutomateButton(writer: w, state: s),
          ListenableBuilder(
            listenable: s.layerValueTick(l.id),
            builder: (context, _) => SizedBox(
              width: 60,
              height: 200,
              child: VolumeFader(value: l.volume, label: 'Keys', onChanged: (v) => s.mixLayer(l, volume: v)),
            ),
          ),
        ]),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('transport-automate')));
    await tester.pump();
    expect(w.armed, isTrue);
    expect(find.text('T'), findsOneWidget, reason: 'armed shows the mode letter');

    await tester.longPress(find.byKey(const ValueKey('transport-automate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Latch'));
    await tester.pumpAndSettle();
    expect(w.mode, AutomationMode.latch);
    expect(find.text('L'), findsOneWidget);
    w.setMode(AutomationMode.touch);

    s.playing = true;
    s.at = 4;
    final g = await tester.startGesture(tester.getCenter(find.byType(VolumeFader)));
    await g.moveBy(const Offset(0, 20));
    s.at = 6;
    await g.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(w.writing, isTrue, reason: 'held while the finger is down');
    s.at = 7;
    await g.up();
    await tester.pump();
    expect(w.writing, isFalse);
    final lane = l.automation.single;
    expect(lane.target, 'volume');
    expect(lane.points.first.value, 1.0);
    expect(lane.points.last.value, 1.0, reason: 'Touch returns to the level before the take');
    expect(lane.points.any((p) => p.value < 1), isTrue);
    s.stop();
    await tester.pump(const Duration(seconds: 1));
  });

  group('the on-screen keys and pads', () {
    Future<(PlayState, LiveMidi)> pumpKeys(WidgetTester tester, {String select = 'L1'}) async {
      tester.view.physicalSize = const Size(412, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = playState()..selectedLayerId = select;
      final live = LiveMidi(s, null)..keysOpen = true;
      addTearDown(live.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TakeToast(
            midi: live,
            child: Align(alignment: Alignment.bottomCenter, child: LiveKeysPanel(midi: live, state: s)),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (s, live);
    }

    testWidgets('a key plays the selected track, louder lower down, and ends when let go', (tester) async {
      final (s, _) = await pumpKeys(tester);
      final piano = find.byKey(const ValueKey('live-piano'));
      expect(piano, findsOneWidget);
      final r = tester.getRect(piano);
      // The first white key (C3, MIDI 48), near its bottom and near its top.
      await tester.tapAt(Offset(r.left + 15, r.bottom - 6));
      await tester.tapAt(Offset(r.left + 15, r.top + 70));
      expect(s.on.map((n) => (n.$1, n.$2)), [('L1', 48.0), ('L1', 48.0)]);
      expect(s.on[0].$3, greaterThan(s.on[1].$3));
      expect(s.offs, 2);
      // A black key: C#3, in the top part between C and D.
      await tester.tapAt(Offset(r.left + 30, r.top + 10));
      expect(s.on.last.$2, 49.0);
    });

    testWidgets('pads follow General MIDI drums on a drum track and the scale elsewhere', (tester) async {
      final (s, live) = await pumpKeys(tester, select: 'L2');
      final pads = find.byKey(const ValueKey('live-pads'));
      expect(pads, findsOneWidget, reason: 'a drum track opens on the pads');
      expect(find.text('Kick'), findsOneWidget);
      final r = tester.getRect(pads);
      await tester.tapAt(Offset(r.left + 10, r.bottom - 10)); // bottom-left: the kick
      expect(s.on.single.$2, 36.0);
      s.selectedLayerId = 'L1';
      s.project.key = 'A minor';
      live.keysOpen = false;
      live.keysOpen = true;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-keys-pads')));
      await tester.pumpAndSettle();
      expect(find.text('A3'), findsOneWidget, reason: 'the pads start on the key root');
      expect(scalePads(s.project, 3).take(8), [57, 59, 60, 62, 64, 65, 67, 69]);
    });

    testWidgets('Record takes the on-screen keys into a take, with a "Keep take?" toast whose Undo removes it',
        (tester) async {
      final (s, live) = await pumpKeys(tester);
      final bar = s.project.stepsPerBar;
      s.pausedStep = bar + 2.0; // recording starts during bar 2
      s.at = bar + 2.0;
      live.toggleRecord();
      expect(live.recording, isTrue);
      await tester.pump();
      expect(find.byKey(const ValueKey('live-keys-rec')), findsOneWidget);
      final r = tester.getRect(find.byKey(const ValueKey('live-piano')));
      final g = await tester.startGesture(Offset(r.left + 15 + 2 * 30, r.bottom - 6)); // E3
      s.pausedStep = bar + 6.0;
      await g.up();
      live.toggleRecord(); // stop
      await tester.pump();
      final layer = s.project.layers.first;
      final clip = layer.clips.single;
      expect(clip.startSteps, bar);
      final note = PatternDoc.parse(s.project.module(clip.patternId)!.source).doc!.notes.single;
      expect((note.at, note.len, note.pitch), (Steps(2), Steps(4), 52.0));
      expect(find.byKey(const ValueKey('take-toast')), findsOneWidget);
      expect(find.textContaining('Keep take?'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(layer.clips, isEmpty);
      expect(s.project.module(clip.patternId), isNull);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a loop recording keeps every pass as a take of one clip, the newest playing; the picker switches',
        (tester) async {
      final (s, live) = await pumpKeys(tester);
      final loop = s.project.engineLoopSteps.toDouble();
      s.pausedStep = 0;
      live.toggleRecord();
      void note(double from, double to, int pitch) {
        s.pausedStep = from;
        live.keyDown(pitch, 1);
        s.pausedStep = to;
        live.keyUp(pitch);
      }

      note(2, 4, 60); // pass 1
      s.pausedStep = loop - 1;
      live.keyUp(0); // a playhead read near the end
      note(3, 5, 62); // pass 2: the playhead wrapped
      live.toggleRecord();
      final layer = s.project.layers.first;
      final clip = layer.clips.single;
      expect(clip.takes.length, 2);
      expect(clip.patternId, clip.takes.last, reason: 'the newest take plays');
      expect(clip.startSteps, 0);
      final first = PatternDoc.parse(s.project.module(clip.takes.first)!.source).doc!;
      expect(first.notes.single.pitch, 60.0);
      // The picker: the older take.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => TextButton(
            onPressed: () => showTakePicker(context, s, layer, clip, const Offset(100, 100)),
            child: const Text('pick'),
          )),
        ),
      ));
      await tester.tap(find.text('pick'));
      await tester.pumpAndSettle();
      expect(find.textContaining('(newest)'), findsOneWidget);
      await tester.tap(find.text(s.project.module(clip.takes.first)!.name));
      await tester.pumpAndSettle();
      expect(clip.patternId, clip.takes.first);
      expect(ProjectDoc.fromJson(s.project.toJson()).layers.first.clips.single.takes, clip.takes);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  test('loop recording into a loop range: each pass is a take over the range', () {
    final s = playState();
    final live = LiveMidi(s, null);
    addTearDown(live.dispose);
    s.project
      ..loopRange = true
      ..loopStartSteps = 16
      ..loopEndSteps = 48;
    s.pausedStep = 20;
    s.at = 20;
    live.toggleRecord('L1');
    void note(double from, double to, int pitch) {
      s.pausedStep = from;
      live.keyDown(pitch, 1);
      s.pausedStep = to;
      live.keyUp(pitch);
    }

    note(22, 24, 60); // pass 1
    s.pausedStep = 46;
    live.keyUp(0);
    note(18, 20, 62); // pass 2: back at the range's start
    live.toggleRecord();
    final clip = s.project.layers.first.clips.single;
    expect(clip.takes.length, 2);
    expect((clip.startSteps, clip.lengthSteps), (16, 32), reason: 'the range, bars 2 and 3');
    final first = PatternDoc.parse(s.project.module(clip.takes.first)!.source).doc!.notes.single;
    final second = PatternDoc.parse(s.project.module(clip.takes.last)!.source).doc!.notes.single;
    expect((first.at, first.pitch), (Steps(6), 60.0));
    expect((second.at, second.pitch), (Steps(2), 62.0));
  });

  group('with the engine', () {
    final lib = Platform.environment['CAW_LIB'];
    final skip = lib == null || lib.isEmpty;

    test('the count-in clicks one bar, then playback starts and the take counts from its start', () async {
      final s = AppState();
      addTearDown(s.dispose);
      s.engine = Engine.create();
      s.project = s.demoProject();
      s.ready = true;
      s.starting = false;
      s.useAudioDevice = false;
      s.info = await s.engine!.setProject(s.project.toEngineJson());
      final live = LiveMidi(s, null);
      addTearDown(live.dispose);
      expect(s.settings.countInBars, 1);
      s.selectedLayerId = s.project.layers[2].id; // the bass
      live.toggleRecord();
      expect(s.transportOn, isTrue);
      expect(live.countInBeats, s.project.beatsPerBar);
      final e = s.engine!;
      e.pullForTest(512);
      final m0 = e.meters();
      final beat = 60 / s.project.bpm * 48000; // the test engine runs at 48 kHz
      expect(m0.playing, isFalse, reason: 'counting in');
      e.pullForTest((beat * s.project.beatsPerBar).round() - 1024);
      expect(e.meters().playing, isFalse);
      e.pullForTest(1024);
      expect(e.meters().playing, isTrue, reason: 'one bar after Record');
      expect(e.meters().position, lessThan(1024), reason: 'from the start, on the bar');
      live.toggleRecord();
    }, skip: skip);
  });
}
