// Recording audio with a fake engine: arming asks for the microphone, Record sends the armed tracks (and the punch
// range), takes become clips (a loop's passes stacked as takes, a start before 0 trimmed), Undo, crash recovery, the
// latency (typed and pinged, with its warning) and the input settings.
import 'dart:io';

import 'package:caw/engine/audio_engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/mic_permission.dart';
import 'package:caw/ui/audio_record_ui.dart';
import 'package:caw/ui/settings/audio_input_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

class FakeMic implements MicPermission {
  FakeMic(this.allow);
  bool allow;
  int asked = 0;
  @override
  Future<bool> granted() async => allow;
  @override
  Future<bool> request() async {
    asked++;
    return allow;
  }

  /// What Android would say about our capture (another app has the microphone).
  bool silenced = false;
  @override
  Future<bool> inputSilenced() async => silenced;
}

ProjectDoc project() => ProjectDoc(id: 'rec', name: 'Rec', bpm: 120, loopBars: 4, layers: [
      LayerDoc(id: 'v', name: 'Vox', color: 0, input: AudioInputDoc()),
      LayerDoc(id: 'g', name: 'Gtr', color: 1, input: AudioInputDoc(channel: 2, channels: 2)),
    ]);

RecordedAudioTake take(String layer, int n, {double start = 0, int frame = 0, double seconds = 2}) =>
    RecordedAudioTake(layer: layer, path: '/tmp/$layer-take$n.wav', take: n, startSteps: start, startFrame: frame,
        frames: (seconds * 48000).round(), seconds: seconds, channels: 1, sampleRate: 48000, bpm: 120);

void main() {
  late AppState s;
  late FakeAudioIo io;
  late FakeMic mic;
  late AudioRecorder rec;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    io = FakeAudioIo();
    s.audioIo = io;
    mic = FakeMic(true);
    rec = AudioRecorder(s, permission: mic, prefs: AudioInputPrefs());
  });
  tearDown(() {
    rec.dispose();
    s.dispose();
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  test('arming asks for the microphone; refused, the track stays unarmed and says why', () async {
    mic.allow = false;
    expect(await rec.arm(layer('v'), true), isFalse);
    expect(layer('v').input!.armed, isFalse);
    expect(rec.message.value, contains('Microphone permission'));
    expect(io.inputConfigs, isEmpty, reason: 'no input opens without the permission');
    mic.allow = true;
    expect(await rec.arm(layer('v'), true), isTrue);
    expect(layer('v').input!.armed, isTrue);
    expect(io.inputConfigs.single.enabled, isTrue);
    expect(rec.prefs.enabled, isTrue);
    // Already open: arming another track asks nothing more.
    final asked = mic.asked;
    await rec.arm(layer('g'), true);
    expect(mic.asked, asked);
  });

  test('Record sends the armed tracks, their channels and the punch range', () async {
    await rec.arm(layer('v'), true);
    await rec.arm(layer('g'), true);
    rec.prefs.punch = PunchMode.loop;
    s.project.loopStartSteps = 16;
    s.project.loopEndSteps = 48;
    expect(await rec.start(), isTrue);
    final r = io.lastRecordRequest!;
    expect(r['bpm'], 120);
    expect(r['bits'], 32);
    expect(r['tracks'], [
      {'layer': 'v', 'channel': 0, 'channels': 1},
      {'layer': 'g', 'channel': 2, 'channels': 2},
    ]);
    expect(r['punch_in_steps'], 16);
    expect(r['punch_out_steps'], 48);
    expect(r['dir'], s.recordingsDirectory.path);
    expect(rec.recording, isTrue);
  });

  test('nothing armed: Record records no audio', () async {
    expect(await rec.start(), isFalse);
    expect(io.lastRecordRequest, isNull);
  });

  test('takes become clips: a loop\'s passes stack as takes, a start before 0 is trimmed', () async {
    await rec.arm(layer('v'), true);
    await rec.arm(layer('g'), true);
    await rec.start();
    io.stopTakes = [
      take('v', 1, start: -1, frame: -6000), take('v', 2, start: -1, frame: -6000), take('v', 3, start: -1, frame: -6000),
      take('g', 1, start: 32.5, frame: 390000, seconds: 1),
    ];
    final placed = (await rec.stop())!;
    expect(rec.recording, isFalse);
    expect(placed.clipIds, hasLength(2));
    final vox = layer('v').audioClips.single;
    expect(vox.takes, hasLength(3), reason: 'three passes, one clip');
    expect(vox.assetId, vox.takes.last, reason: 'the newest plays');
    expect(vox.startSteps, 0);
    expect(vox.offsetSeconds, closeTo(0.125, 1e-9), reason: 'one step at 120 BPM trimmed off');
    expect(vox.lengthSeconds, closeTo(1.875, 1e-9));
    final gtr = layer('g').audioClips.single;
    expect(gtr.startSteps, 32.5);
    expect(gtr.takes, isEmpty);
    expect(s.project.assets.where((a) => a.recorded), hasLength(4));
    expect(rec.lastRecording.value, same(placed));
    // The toast's Undo takes the clips and assets back.
    rec.discard(placed);
    expect(layer('v').audioClips, isEmpty);
    expect(s.project.assets, isEmpty);
  });

  test('the transport\'s Record starts and stops it', () async {
    await rec.arm(layer('v'), true);
    final transport = ValueNotifier(false);
    rec.follow(transport, () => transport.value);
    transport.value = true;
    // Starting creates the recordings folder on disk, so wait for it rather than for one turn of the event queue
    // (a busy machine needs more than one).
    await _until(() => rec.recording);
    expect(rec.recording, isTrue);
    io.stopTakes = [take('v', 1, start: 8, frame: 96000)];
    transport.value = false;
    await _until(() => io.stops == 1 && layer('v').audioClips.isNotEmpty);
    expect(io.stops, 1);
    expect(layer('v').audioClips.single.startSteps, 8);
  });

  test('recovery lists the takes a crash left and places them, on a new track when theirs is gone', () async {
    await s.recordingsDirectory.create(recursive: true);
    io.recovered = [take('v', 4, start: 4), take('gone', 1)];
    final found = await rec.recover();
    expect(io.recoveredFrom, s.recordingsDirectory.path);
    expect(found, hasLength(2));
    rec.placeTakes(found, recovered: true);
    expect(layer('v').audioClips.single.startSteps, 4);
    expect(s.project.layers.last.name, 'Recovered audio');
    // A take already in the project is not offered again.
    expect(await rec.recover(), isEmpty);
    await s.recordingsDirectory.delete(recursive: true);
  });

  test('latency: typed in milliseconds, back to measured, and a ping', () async {
    rec.setLatencyMs(12.5);
    expect(io.latencyOverride, 600);
    expect(rec.latency.source, 'override');
    rec.setLatencyMs(null);
    expect(io.latencyOverride, -1);
    final r = await rec.ping(poll: Duration.zero);
    expect(r!.ok, isTrue);
    expect(rec.latency.source, 'measured');
    expect(rec.latency.frames, 480);
  });

  test('the input choices round trip', () {
    final a = AudioInputPrefs()
      ..enabled = true
      ..deviceId = 'usb'
      ..channels = 4
      ..latencyOverride = 300
      ..punch = PunchMode.selection
      ..bits = 24;
    final b = AudioInputPrefs()..fromJson(a.toJson());
    expect(b.toJson(), a.toJson());
  });

  testWidgets('Settings › Audio: input on, a device, and the ping only after its warning', (tester) async {
    tester.view.physicalSize = const Size(412, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AudioInputSettings(recorder: rec)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('switch-audio.input')));
    await tester.pumpAndSettle();
    // On, but the microphone stays closed until a track is armed or monitors (owner, 2026-11-12).
    expect(rec.prefs.enabled, isTrue);
    expect(rec.inputOpen, isFalse);
    expect(io.inputConfigs, isEmpty);
    await tester.tap(find.byKey(const ValueKey('latency-measure')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('latency-warning')), findsOneWidget);
    expect(io.pinging, isFalse, reason: 'nothing plays before the user agrees');
    await tester.tap(find.byKey(const ValueKey('latency-go')));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(io.pinging, isTrue);
    await tester.pumpAndSettle();
    expect(find.textContaining('Round trip 10.0 ms'), findsOneWidget);
  });

  testWidgets('a project with takes a crash left offers them at start-up', (tester) async {
    s.recordingsDirectory.createSync(recursive: true);
    io.recovered = [take('v', 1, start: 0)];
    s.starting = false;
    s.ready = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AudioRecordFeedback(state: s, recorder: rec,
        child: const SizedBox.expand()))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-recovery')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio-recovery-add')));
    await tester.pumpAndSettle();
    expect(layer('v').audioClips, hasLength(1));
    await tester.pump(const Duration(seconds: 6));
    s.recordingsDirectory.deleteSync(recursive: true);
    expect(Directory(s.recordingsDirectory.path).existsSync(), isFalse);
  });
}

/// Waits for [done], turning the event queue and letting real I/O finish, for at most [limit].
Future<void> _until(bool Function() done, {Duration limit = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(end)) {
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
