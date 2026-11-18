// #242: real input and output devices on Android: the choices by type and name, keys that survive reconnects, the engine id they open by, the recorder following a reconnect, and the input drop-down.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_devices.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/audio_route.dart';
import 'package:caw/platform/mic_permission.dart';
import 'package:caw/ui/settings/audio_input_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'latency_comp_test.dart' show FakeRoute;

AudioEndpoint dev(int id, int type, String name) =>
    AudioEndpoint(id: id, name: name, platformType: type, kind: androidDeviceKind(type));

// What an S22+ with Bluetooth headphones connected might list ([Assumption] the shape, from AudioManager's types).
final outputs = [
  dev(2, 1, 'SM-S906B'), // earpiece
  dev(3, 2, 'SM-S906B'), // speaker
  dev(41, 8, 'WH-1000XM4'), // A2DP
  dev(42, 7, 'WH-1000XM4'), // SCO: calls only, not offered
  dev(5, 25, 'SM-S906B'), // remote submix: not offered
];
final inputs = [
  dev(10, 15, 'SM-S906B'), // built-in mic, bottom
  dev(11, 15, 'SM-S906B'), // built-in mic, top
  dev(43, 7, 'WH-1000XM4'), // the headset's mic over SCO
  dev(12, 18, 'SM-S906B'), // telephony: not offered
];

class _Mic implements MicPermission {
  @override
  Future<bool> granted() async => true;
  @override
  Future<bool> request() async => true;
  @override
  Future<bool> inputSilenced() async => false;
}

bool get _haveEngine {
  final lib = Platform.environment['CAW_LIB'];
  return lib != null && lib.isNotEmpty && File(lib).existsSync();
}

void main() {
  test('outputs by type, with the product name only where it is not the phone', () {
    final c = platformChoices(outputs, input: false);
    expect([for (final x in c) x.label], ['Phone earpiece', 'Phone speaker', 'Bluetooth · WH-1000XM4']);
    expect([for (final x in c) x.key], ['android:1:', 'android:2:', 'android:8:WH-1000XM4']);
    expect(c[2].engineId, 'aaudio:41');
  });

  test('inputs: alike ones numbered, a Bluetooth headset mic labelled call quality, telephony left out', () {
    final c = platformChoices(inputs, input: true);
    expect([for (final x in c) x.label],
        ['Phone microphone (1)', 'Phone microphone (2)', 'Bluetooth mic, call quality · WH-1000XM4']);
    expect([for (final x in c) x.key], ['android:15:', 'android:15:#2', 'android:7:WH-1000XM4']);
    expect(c[2].callQuality, isTrue);
    expect(c[0].callQuality, isFalse);
  });

  test('a saved key opens by the id its device has now; not connected, the default; other ids as they are', () {
    final before = platformChoices(outputs, input: false);
    expect(engineDeviceId('android:8:WH-1000XM4', before), 'aaudio:41');
    // Reconnected: Android gives it a new id; the key is the same.
    final after = platformChoices([dev(3, 2, 'SM-S906B'), dev(57, 8, 'WH-1000XM4')], input: false);
    expect(engineDeviceId('android:8:WH-1000XM4', after), 'aaudio:57');
    expect(engineDeviceId('android:8:WH-1000XM4', platformChoices([dev(3, 2, 'SM-S906B')], input: false)), '');
    expect(engineDeviceId(r'{0.0.0.00000000}.{abc}', before), r'{0.0.0.00000000}.{abc}');  // WASAPI's endpoint id
    expect(engineDeviceId('', before), '');
    expect(choiceRouted(41, before)?.label, 'Bluetooth · WH-1000XM4');
    expect(choiceRouted(0, before), isNull);
  });

  group('the recorder', () {
    late FakeRoute route;
    late AppState s;
    late FakeAudioIo io;
    late AudioRecorder rec;
    setUp(() {
      route = FakeRoute(const AudioRouteInfo())..lists = AudioDeviceLists(outputs: outputs, inputs: inputs);
      s = AppState(settings: Settings(), audioRoute: route);
      io = FakeAudioIo();
      s.audioIo = io;
      rec = AudioRecorder(s, permission: _Mic(), prefs: AudioInputPrefs());
    });
    tearDown(() {
      rec.dispose();
      s.dispose();
    });

    test('opens a chosen input by its id, and again by its new id when it reconnects', () async {
      rec.prefs.deviceId = 'android:7:WH-1000XM4';
      rec.prefs.deviceName = 'Bluetooth mic, call quality · WH-1000XM4';
      expect(await rec.openInput(force: true), isTrue);
      expect(io.inputConfigs.last.id, 'aaudio:43');
      // The headset goes away: the default records.
      route.connect(AudioDeviceLists(outputs: outputs, inputs: inputs.take(2).toList()));
      await pumpEventQueue();
      expect(io.inputConfigs.last.id, '');
      // Back with a new id.
      route.connect(AudioDeviceLists(outputs: outputs, inputs: [...inputs.take(2), dev(77, 7, 'WH-1000XM4')]));
      await pumpEventQueue();
      expect(io.inputConfigs.last.id, 'aaudio:77');
      final n = io.inputConfigs.length;
      route.connect(AudioDeviceLists(outputs: outputs, inputs: [...inputs.take(2), dev(77, 7, 'WH-1000XM4')]));
      await pumpEventQueue();
      expect(io.inputConfigs.length, n, reason: 'the same id: nothing reopens');
    });

    testWidgets('the input drop-down lists the platform\'s inputs and keeps a saved one that is not connected',
        (tester) async {
      tester.view.physicalSize = const Size(412, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      rec.prefs.deviceId = 'android:22:Scarlett';
      rec.prefs.deviceName = 'USB headset mic · Scarlett';
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: SingleChildScrollView(child: AudioInputSettings(recorder: rec)))));
      await tester.pumpAndSettle();
      expect(find.text('USB headset mic · Scarlett (not connected)'), findsOneWidget);
      expect(find.textContaining('not connected: the default records'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dropdown-audio.inputDevice')));
      await tester.pumpAndSettle();
      expect(find.text('Phone microphone (2)').last, findsOneWidget);
      await tester.tap(find.text('Bluetooth mic, call quality · WH-1000XM4').last);
      await tester.pumpAndSettle();
      expect(rec.prefs.deviceId, 'android:7:WH-1000XM4');
      expect(find.textContaining('narrowband, as on a call'), findsOneWidget);
    });
  });

  test('with the engine: the output choice reaches it by the id its device has now, and again after a reconnect',
      () async {
    final route = FakeRoute(const AudioRouteInfo())..lists = AudioDeviceLists(outputs: outputs, inputs: inputs);
    final s = AppState(settings: Settings(), audioRoute: route);
    s.useAudioDevice = false;
    s.engine = Engine.create(sampleRate: 48000);
    s.settings.update((x) {
      x.audioDeviceId = 'android:8:WH-1000XM4';
      x.audioDevice = 'Bluetooth · WH-1000XM4';
    });
    s.applyAudioSettings();
    await s.audioConfigured;
    expect(s.engine!.audioStatus().requestedDeviceId, 'aaudio:41');
    expect(s.engine!.audioStatus().requestedDevice, '', reason: 'a platform choice opens by its id alone');
    route.connect(AudioDeviceLists(outputs: [dev(3, 2, 'SM-S906B')]));  // the headphones go away
    await pumpEventQueue();
    await s.audioConfigured;
    expect(s.engine!.audioStatus().requestedDeviceId, '');
    expect(s.audioError, contains('not connected'));
    route.connect(AudioDeviceLists(outputs: [dev(3, 2, 'SM-S906B'), dev(58, 8, 'WH-1000XM4')]));
    await pumpEventQueue();
    await s.audioConfigured;
    expect(s.engine!.audioStatus().requestedDeviceId, 'aaudio:58');
    expect(s.audioError, isNull);
    s.dispose();
  }, skip: !_haveEngine);
}
