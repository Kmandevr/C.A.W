// The flagship's user wavetable: the Import wavetable… action, the import and saved forms, and the drawing of the User table and Osc FM.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/flagship_shapes.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/flagship/flagship_editor.dart' show flagshipComponentId;
import 'package:caw/ui/devices/flagship/flagship_wavetable.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flagship_fixture.dart';

final _noLib = (Platform.environment['CAW_LIB'] ?? '').isEmpty;

/// A 16-bit mono WAV at 48 kHz of [samples] (-1..1).
Uint8List _wav(List<double> samples) {
  final b = ByteData(44 + samples.length * 2);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + samples.length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 48000, Endian.little);
  b.setUint32(28, 96000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + 2 * i, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Two 2048-sample frames: a sine, then a square.
List<double> _sineThenSquare() => [
      for (var i = 0; i < 2048; i++) 0.5 * math.sin(2 * math.pi * i / 2048),
      for (var i = 0; i < 2048; i++) i < 1024 ? 0.5 : -0.5,
    ];

void main() {
  group('the import action', () {
    late AppState s;
    var motion = MotionLevel.full;

    setUp(() {
      motion = Motion.setting;
      Motion.setting = MotionLevel.off;
      s = AppState(settings: Settings());
      s.project = ProjectDoc(id: 'p', name: 'W', bpm: 120, layers: [LayerDoc(id: 'a', name: 'A', color: 1)]);
      s.componentCatalog.set([flagshipFixture()]);
      s.setNativeInstrument(s.project.layers.first, flagshipComponentId);
    });
    tearDown(() {
      Motion.setting = motion;
      pickWavetableWav = defaultPickWavetableWav;
      pickWavetableSplit = defaultPickWavetableSplit;
      s.dispose();
    });

    Future<void> openSynth(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 900,
          child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: s.project.layers.first))))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fx-instrument-open')));
      await tester.pumpAndSettle();
    }

    testWidgets('without an engine it says the wavetable was not imported and changes nothing', (tester) async {
    // A modulated knob or a device visual moves on every frame; hold it still so the screen settles.
    MotionClock.hold = true;
    addTearDown(() => MotionClock.hold = false);
      var picked = 0, asked = 0;
      pickWavetableWav = () async {
        picked++;
        return _wav(_sineThenSquare());
      };
      pickWavetableSplit = (_) async {
        asked++;
        return 0;
      };
      await openSynth(tester);
      final button = find.byKey(const ValueKey('flagship-import-osc1_'));
      expect(button, findsOneWidget);
      expect(find.text('Import wavetable…'), findsWidgets);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect((picked, asked), (1, 1));
      expect(find.textContaining('Not imported'), findsOneWidget);
      final t = DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
      expect(t.value('osc1_table'), 0);
      expect(t.use!.state, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a cancelled pick or frame choice asks nothing more', (tester) async {
    // A modulated knob or a device visual moves on every frame; hold it still so the screen settles.
    MotionClock.hold = true;
    addTearDown(() => MotionClock.hold = false);
      var asked = 0;
      pickWavetableWav = () async => null;
      pickWavetableSplit = (_) async {
        asked++;
        return 0;
      };
      await openSynth(tester);
      final button = find.byKey(const ValueKey('flagship-import-osc1_'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(asked, 0);
      expect(find.textContaining('imported'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the frame dialog gives 0 for 2048-sample frames, or a count from 1 to 256', (tester) async {
      int? got = -1;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
          onPressed: () async => got = await defaultPickWavetableSplit(context), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wt-split-ok')));
      await tester.pumpAndSettle();
      expect(got, 0);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wt-split-count')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('wt-split-frames')), '300');
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('wt-split-ok'))).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('wt-split-frames')), '12');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('wt-split-ok')));
      await tester.pumpAndSettle();
      expect(got, 12);
    });
  });

  test('the import and saved forms, and the User table and Osc FM as drawn', () {
    final env = wavetableImport(Uint8List.fromList([1, 2, 3]), 7);
    expect(env.sublist(0, 4), ascii.encode('CWTI'));
    expect(ByteData.sublistView(env).getUint32(4, Endian.little), 7);
    expect(env.sublist(8), [1, 2, 3]);
    // A saved table: 2 frames, a sine and its negative.
    final b = ByteData(12 + 2 * 2048 * 2);
    b.setUint32(0, 0x31545743, Endian.little);
    b.setUint32(4, 2, Endian.little);
    b.setUint32(8, 2048, Endian.little);
    for (var i = 0; i < 2048; i++) {
      final v = (32767 * math.sin(2 * math.pi * i / 2048)).round();
      b.setInt16(12 + 2 * i, v, Endian.little);
      b.setInt16(12 + 2 * (2048 + i), -v, Endian.little);
    }
    final bytes = b.buffer.asUint8List();
    final user = UserWavetable.parse(bytes)!;
    expect(user.frames, hasLength(2));
    expect(UserWavetable.parse(env), isNull);
    expect(UserWavetable.parse(Uint8List.sublistView(bytes, 0, bytes.length - 1)), isNull);
    expect(tableFrameCount(userTableIndex, user), 2);
    expect(tableFrameCount(userTableIndex, null), 1);
    expect(wavetableNames, hasLength(6));
    // Halfway between the frames they cancel; frame 0 is the sine.
    final mid = oscillatorCycle(userTableIndex, 0.5, Warp.none, 0, points: 64, user: user);
    expect(mid.every((v) => v.abs() < 1e-3), isTrue);
    final first = oscillatorCycle(userTableIndex, 0, Warp.none, 0, points: 64, user: user);
    expect(first[16], closeTo(1, 1e-3));
    // No table loaded: a sine.
    expect(oscillatorCycle(userTableIndex, 0, Warp.none, 0, points: 64)[16], closeTo(1, 1e-6));
    // Osc FM bends the cycle by the modulator; with none, nothing moves.
    final sine = oscillatorCycle(4, 0, Warp.none, 0, points: 64);
    final mod = oscillatorCycle(4, 0, Warp.none, 0, points: 64);
    final bent = oscillatorCycle(4, 0, Warp.oscFm, 0.5, points: 64, modulator: mod, modRatio: 2);
    expect(oscillatorCycle(4, 0, Warp.oscFm, 0.5, points: 64), sine);
    expect([for (var i = 0; i < 64; i++) (bent[i] - sine[i]).abs()].reduce(math.max), greaterThan(0.2));
    expect(warpNames, hasLength(Warp.values.length));
    expect(oscFmSource(1), 3);
    expect(oscFmSource(2), 1);
  });

  test('the engine takes a WAV as a playing flagship\'s User table, and the project keeps its saved form', () async {
    final s = AppState(settings: Settings());
    final e = Engine.create();
    s.engine = e;
    s.project = ProjectDoc(id: 'p', name: 'W', bpm: 120,
        layers: [LayerDoc(id: 'a', name: 'A', color: 1, instrument: ComponentUseDoc(flagshipComponentId))]);
    final layer = s.project.layers.first;
    await e.setProject(s.project.toEngineJson());
    expect(await importFlagshipWavetable(s, layer, wavetableImport(_wav(_sineThenSquare()), 0)), isTrue);
    final state = layer.instrument!.state!;
    expect(UserWavetable.parse(base64Decode(state))!.frames, hasLength(2));
    expect(userWavetableFrames(state), 2);
    // Cut into 4 frames.
    expect(await importFlagshipWavetable(s, layer, wavetableImport(_wav(_sineThenSquare()), 4)), isTrue);
    expect(userWavetableFrames(layer.instrument!.state), 4);
    // A broken file is refused and the project keeps the table it had.
    final kept = layer.instrument!.state;
    expect(await importFlagshipWavetable(s, layer, wavetableImport(Uint8List.sublistView(_wav(_sineThenSquare()), 0, 40), 0)),
        isFalse);
    expect(await importFlagshipWavetable(s, layer, wavetableImport(_wav(List.filled(4096, 0)), 0)), isFalse);
    expect(layer.instrument!.state, kept);
    // The saved form loads back on its own (a project reload).
    await e.setProject(s.project.toEngineJson());
    expect(e.componentStates('a')[ProjectDoc.instrumentIndex]!.state, kept);
    s.engine = null;
    e.dispose();
    s.dispose();
  }, skip: _noLib ? 'set CAW_LIB to the built engine library' : null);
}
