// The microphone opens only while something uses it, is released behind the app and reopened on return, and when
// another app holds it the note shows where the input meters are while it is tried again quietly (owner, 2026-11-12).
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/mic_permission.dart';
import 'package:caw/ui/arrange/audio_input_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

class _Mic implements MicPermission {
  bool allow = true, silenced = false;
  int asked = 0;
  @override
  Future<bool> granted() async => allow;
  @override
  Future<bool> request() async {
    asked++;
    return allow;
  }

  @override
  Future<bool> inputSilenced() async => silenced;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState s;
  late FakeAudioIo io;
  late _Mic mic;
  late AudioRecorder rec;

  setUp(() {
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, loopBars: 4, layers: [
      LayerDoc(id: 'v', name: 'Vox', color: 0, input: AudioInputDoc()),
    ]);
    io = FakeAudioIo();
    s.audioIo = io;
    mic = _Mic();
    AudioRecorder.retryEvery = const Duration(milliseconds: 20);
    rec = AudioRecorder(s, permission: mic, prefs: AudioInputPrefs());
    AudioRecorder.current = rec;
  });
  tearDown(() {
    AudioRecorder.current = null;
    rec.dispose();
    s.dispose();
  });

  LayerDoc vox() => s.project.layers.single;
  List<bool> configs() => [for (final c in io.inputConfigs) c.enabled];

  test('the microphone opens only while a track is armed or monitors, and closes when none does', () async {
    expect(await rec.openInput(), isTrue);  // Settings › Audio: input on
    expect(rec.prefs.enabled, isTrue);
    expect(rec.inputOpen, isFalse, reason: 'nothing uses it yet: it stays closed');
    expect(io.inputConfigs, isEmpty);
    await rec.arm(vox(), true);
    await rec.settled();
    expect(rec.inputOpen, isTrue);
    expect(configs(), [true]);
    await rec.arm(vox(), false);
    await rec.settled();
    expect(rec.inputOpen, isFalse, reason: 'released for other apps');
    expect(configs(), [true, false]);
    expect(rec.prefs.enabled, isTrue, reason: 'still on: the next arm opens it without asking');
    // Monitoring "on" uses it too, armed or not; it opens without asking (the permission is granted).
    final asked = mic.asked;
    s.editInput(vox(), (i) => i.monitor = 'on');
    await rec.settled();
    expect(rec.inputOpen, isTrue);
    expect(mic.asked, asked);
    s.editInput(vox(), (i) => i.monitor = 'auto');
    await rec.settled();
    expect(rec.inputOpen, isFalse);
  });

  test('behind the app the microphone is released, and on return it opens again', () async {
    await rec.arm(vox(), true);
    await rec.settled();
    expect(rec.inputOpen, isTrue);
    s.lifecycle(foreground: false);
    await rec.settled();
    expect(rec.inputOpen, isFalse);
    expect(configs().last, isFalse);
    s.lifecycle(foreground: true);
    await rec.settled();
    expect(rec.inputOpen, isTrue);
    expect(configs().last, isTrue);
    expect(rec.micBusy.value, isFalse);
  });

  test('another app takes the microphone: busy, tried again quietly, and clear once it is free', () async {
    await rec.arm(vox(), true);
    await rec.settled();
    expect(rec.micBusy.value, isFalse);
    final before = io.inputConfigs.length;
    // The engine says the input stopped delivering (the output plays on regardless).
    io.inputStatusNow = {'enabled': true, 'running': true, 'state': 'stalled', 'channels': 2};
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(rec.micBusy.value, isTrue);
    expect(io.inputConfigs.length, greaterThan(before), reason: 'retried');
    expect(io.inputConfigs.skip(before).every((c) => c.enabled), isTrue, reason: 'never turned off by a retry');
    expect(rec.message.value, isNull, reason: 'quietly: no error line');
    // Free again.
    io.inputStatusNow = {'enabled': true, 'running': true, 'state': 'open', 'channels': 2};
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(rec.micBusy.value, isFalse);
    // Android silencing our capture for another app counts as busy too, with no retry needed.
    mic.silenced = true;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(rec.micBusy.value, isTrue);
    mic.silenced = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(rec.micBusy.value, isFalse);
    // Released, nothing is checked any more.
    await rec.arm(vox(), false);
    await rec.settled();
    io.inputStatusNow = {'enabled': false, 'running': false, 'state': 'off'};
    final count = io.inputConfigs.length;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(io.inputConfigs.length, count);
    expect(rec.micBusy.value, isFalse);
  });

  test('the Android channel answers whether our input is silenced, and a missing plugin means no', () async {
    const channel = MethodChannel('caw/permissions');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'inputSilenced' ? true : null);
    expect(await AndroidMicPermission(channel: channel).inputSilenced(), isTrue);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await AndroidMicPermission(channel: channel).inputSilenced(), isFalse);
    expect(await const NoMicPrompt().inputSilenced(), isFalse);
  });

  testWidgets('the note shows where the input meter is while the microphone is busy', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 300,
        child: AudioInputMeter(layer: vox())))));
    expect(find.byKey(const ValueKey('audio-input-meter-v')), findsOneWidget);
    expect(find.text(micBusyNote), findsNothing);
    rec.micBusy.value = true;
    await tester.pumpAndSettle();
    expect(find.text(micBusyNote), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-input-meter-v')), findsNothing);
    rec.micBusy.value = false;
    await tester.pumpAndSettle();
    expect(find.text(micBusyNote), findsNothing);
    expect(find.byKey(const ValueKey('audio-input-meter-v')), findsOneWidget);
  });
}
