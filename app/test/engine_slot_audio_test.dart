// Per-device auto gain and slot meters in the app: the project's `auto_gain` (save, load, undo, new devices) and, with
// CAW_LIB, EngineSlotAudio over the real engine (a meter reading, the ear's trim on a +6 dB effect).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:caw/engine/bindings.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_slot_audio.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/engine_slot_audio.dart';
import 'package:caw/model/mixer_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/devices/kit/device_header.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Gain', bpm: 120, modules: [], layers: [
      LayerDoc(id: 't', name: 'Tone', color: 2)
        ..instrument = ComponentUseDoc('org.caw.test.osc', {'shape': 3, 'level': 0.2})
        ..components = [ComponentUseDoc('org.caw.utility', {'gain': 6})],
    ]);

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final noLib = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  tearDown(() => DeviceSlotAudio.current = null);

  group('the project keeps auto gain', () {
    test('written as "auto_gain": true only when on; a file without it saves byte for byte, at the same version', () {
      final p = _project();
      final before = jsonEncode(p.toJson());
      expect(before, isNot(contains('auto_gain')));
      expect(ComponentUseDoc('org.caw.eq').toJson(), 'org.caw.eq', reason: 'a bare id as before');
      p.layers.first.components.first.autoGain = true;
      p.masterComponents.add(ComponentUseDoc('org.caw.eq')..autoGain = true);
      final j = p.toJson();
      expect(j['caw_app_project'], ProjectDoc.baseFileVersion, reason: 'an older build ignores the key: no new version');
      final text = jsonEncode(j);
      expect(text, contains('"auto_gain":true'));
      expect(ComponentUseDoc('org.caw.eq').toJson(), 'org.caw.eq');
      expect((ComponentUseDoc('org.caw.eq')..autoGain = true).toJson(), {'id': 'org.caw.eq', 'auto_gain': true});
      final back = ProjectDoc.fromJson(jsonDecode(text) as Map<String, dynamic>);
      expect(back.layers.first.components.first.autoGain, isTrue);
      expect(back.masterComponents.single.autoGain, isTrue);
      expect(jsonEncode(back.toJson()), text);
      // The engine's copy carries it, so a project update sets it again.
      expect(p.toEngineJson(), contains('"auto_gain":true'));
      // Untrusted input: only a literal true turns it on.
      expect(ComponentUseDoc.fromJson({'id': 'org.caw.eq', 'auto_gain': 'yes'})!.autoGain, isFalse);
      expect(ComponentUseDoc.fromJson({'id': 'org.caw.eq', 'auto_gain': 1})!.autoGain, isFalse);
      final off = ProjectDoc.fromJson(jsonDecode(before) as Map<String, dynamic>);
      expect(jsonEncode(off.toJson()), before);
    });

    test('switching it is one undo step', () {
      final s = AppState(settings: Settings());
      s.project = _project();
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      final layer = s.project.layers.first;
      s.setNativeAutoGain(layer, 0, true);
      expect(s.project.layers.first.components.first.autoGain, isTrue);
      expect(s.undo(), isTrue);
      expect(s.project.layers.first.components.first.autoGain, isFalse);
      expect(s.redo(), isTrue);
      expect(s.project.layers.first.components.first.autoGain, isTrue);
      s.dispose();
    });

    test('a new device starts with Settings › Sound "Auto gain on new devices"', () {
      for (final on in [false, true]) {
        final s = AppState(settings: Settings()..autoGainNewDevices = on);
        s.project = _project();
        final layer = s.project.layers.first;
        expect(s.addNativeEffect(layer, 'org.caw.eq')!.autoGain, on);
        expect(s.addNativeEffect(masterLayerOf(s.project), 'org.caw.eq')!.autoGain, on);
        expect(s.project.masterComponents.single.autoGain, on);
        s.dispose();
      }
    });
  });

  testWidgets('over the engine: a slot meter reads a peak and the ear shows the trim on a +6 dB effect', (tester) async {
    final s = AppState(settings: Settings());
    final e = Engine.create();
    s.engine = e;
    s.project = _project();
    DeviceSlotAudio.current = EngineSlotAudio.instance;
    final fx = DeviceTarget(s, 't', 0), inst = DeviceTarget(s, 't', DeviceTarget.instrumentSlot);
    expect(DeviceSlotAudio.meterFor(fx), isTrue);
    expect(DeviceSlotAudio.autoGainFor(fx), isTrue);
    expect(DeviceSlotAudio.meterFor(inst), isTrue, reason: 'the instrument has a meter');
    expect(DeviceSlotAudio.autoGainFor(inst), isFalse, reason: 'and no auto gain: no ear');
    await tester.runAsync(() => e.setProject(s.project.toEngineJson()));
    // The ear switches it in the engine and in the project.
    DeviceSlotAudio.toggleAutoGain(fx);
    expect(s.project.layers.first.components.first.autoGain, isTrue);
    expect(EngineSlotAudio.instance.autoGain(fx), isTrue);
    // Eight seconds of audio through the engine (its loudness window is 3 s).
    final b = Bindings.instance;
    final h = Pointer<Void>.fromAddress(e.nativeAddress!);
    final left = calloc<Float>(256), right = calloc<Float>(256);
    try {
      e.play();
      for (var k = 0; k < 48000 * 8 ~/ 256; k++) {
        b.process(h, left, right, 256);
      }
    } finally {
      calloc.free(left);
      calloc.free(right);
    }
    final peak = EngineSlotAudio.instance.outputPeak(fx);
    expect(peak, isNotNull);
    expect(peak!, greaterThan(0.05));
    expect(EngineSlotAudio.instance.outputPeak(inst), greaterThan(0.05));
    expect(EngineSlotAudio.instance.autoGainTrimDb(fx), closeTo(-6, 0.3));
    await tester.pumpWidget(MaterialApp(home: Material(child: Center(
        child: DeviceAutoGainButton(target: fx, color: Colors.amber)))));
    final text = tester.widget<Text>(find.byKey(const ValueKey('device-autogain-trim'))).data!;
    expect(text, anyOf('−5.8 dB', '−5.9 dB', '−6.0 dB', '−6.1 dB', '−6.2 dB'));
    // Switched off: the ear goes dim and the trim goes.
    DeviceSlotAudio.toggleAutoGain(fx);
    await tester.pump();
    expect(find.byKey(const ValueKey('device-autogain-trim')), findsNothing);
    expect(EngineSlotAudio.instance.autoGainTrimDb(fx), isNull);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  }, skip: noLib != null);
}
