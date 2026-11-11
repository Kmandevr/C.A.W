// fx-space: the Space, Modulation and Utility effects' UIs: display decoding, browser entries, the heroes' drags and
// loading a WAV impulse into the convolver (with CAW_LIB, through the engine).
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/fx_space_display.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/effects/space/space_fx_reverb.dart';
import 'package:caw/ui/devices/kit/controls.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// A 16-bit mono WAV at 48 kHz of [frames] frames: a click, and a quieter one 50 ms later.
Uint8List _wav(int frames) {
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void u16(int v) => b.add([v & 255, (v >> 8) & 255]);
  b.add('RIFF'.codeUnits);
  u32(36 + frames * 2);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(48000);
  u32(96000);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(frames * 2);
  for (var i = 0; i < frames; i++) {
    u16(i == 0 ? 16000 : i == 2400 ? 8000 : 0);
  }
  return b.toBytes();
}

bool get _noLib => (Platform.environment['CAW_LIB'] ?? '').isEmpty;

void main() {
  test('the display floats decode by name', () {
    final h = decodeDisplay('org.caw.haas', [-6, -7, 0.4, -1.5, 12, 41.7, 1], 7);
    expect((h.values['correlation'], h.values['mono_loss_db'], h.values['notch_hz'], h.values['mono']), (0.4, -1.5, 41.7, 1));
    final c = decodeDisplay('org.caw.convolver', [-6, -8, -14, 10.7, 2.2, 1, 9, 1, 2, 0.9, 0.4], 11);
    expect((c.values['latency_ms'], c.values['ir_s'], c.values['file'], c.values['env1']), (10.7, 2.2, 1, 0.4));
    final i = decodeDisplay('org.caw.imager', [-6, -6, 0.8, 0.1, 1, 0.7, 0.2, -0.5, 1, 0.3, -0.2], 11);
    expect((i.values['corr_high'], i.values['m0'], i.values['s0']), (0.2, 0.3, -0.2));
    final e = decodeDisplay('org.caw.ensemble', [-6, -6, 4, 3.5, 0.2, 10, 11, 12, 13], 9);
    expect((e.values['voices'], e.values['voice3']), (4, 13));
  });

  test('every effect has a browser entry, an editor and 3 to 8 factory presets', () {
    for (final id in fxSpaceIds) {
      final entry = fxSpaceBrowser[id];
      expect(entry, isNotNull, reason: id);
      expect(['Space', 'Modulation', 'Utility'], contains(entry!.category));
      expect(entry.description.length, inInclusiveRange(10, 90), reason: id);
      expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull, reason: id);
      expect(builtinInfo(id).presets.length, inInclusiveRange(3, 8), reason: id);
    }
  });

  group('the heroes', () {
    var motion = MotionLevel.full;
    late DeviceDisplaySource source;
    late FakeDisplay display;
    final states = <AppState>[];
    setUp(() {
      motion = Motion.setting;
      source = DeviceDisplaySource.current;
      display = FakeDisplay();
      DeviceDisplaySource.current = display;
    });
    tearDown(() {
      Motion.setting = motion;
      DeviceDisplaySource.current = source;
      pickImpulseWav = defaultPickImpulseWav;
      for (final s in states) {
        s.dispose();
      }
      states.clear();
    });

    Future<AppState> open(WidgetTester tester, String id) async {
      final s = stateWith(id, make: PreviewState.new);
      Motion.setting = MotionLevel.off;
      states.add(s);
      display.frame.value = fakeFrame(id);
      late BuildContext ctx;
      await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })), const Size(390, 844));
      openDevice(ctx, s, id);
      await tester.pumpAndSettle();
      return s;
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }

    for (final (id, x, y) in [
      ('org.caw.convolver', 'decay', 'size'),
      ('org.caw.shimmer', 'decay', 'amount'),
      ('org.caw.haas', 'delay', 'level'),
      ('org.caw.ensemble', 'spread', 'detune'),
      ('org.caw.doubler', 'width', 'detune'),
      ('org.caw.vibrato', 'rate', 'depth'),
      ('org.caw.tremolo', 'rate', 'depth'),
      ('org.caw.autopan', 'rate', 'depth'),
    ]) {
      testWidgets('$id: a drag right and up raises $x and $y', (tester) async {
        final s = await open(tester, id);
        final t = targetOf(s, id);
        final before = (t.value(x), t.value(y));
        final pad = tester.getRect(find.byType(XYPad).first);
        await tester.dragFrom(pad.center + const Offset(-60, 40), const Offset(80, -60));
        await tester.pumpAndSettle();
        expect(t.value(x), greaterThan(before.$1), reason: x);
        expect(t.value(y), greaterThan(before.$2), reason: y);
        await close(tester);
      });
    }

    testWidgets('convolver: Load WAV… without an engine says it was not loaded and keeps the impulse', (tester) async {
      pickImpulseWav = () async => _wav(4800);
      final s = await open(tester, 'org.caw.convolver');
      final t = targetOf(s, 'org.caw.convolver');
      await tester.ensureVisible(find.byKey(const ValueKey('convolver-load')));
      await tester.tap(find.byKey(const ValueKey('convolver-load')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not loaded'), findsOneWidget);
      expect(t.value('source'), 1);
      expect(t.use!.state, isNull);
      await close(tester);
    });
  });

  test('the engine takes a WAV impulse into a playing convolver, and the project keeps it', () async {
    final s = AppState(settings: Settings());
    final e = Engine.create();
    s.engine = e;
    s.project = ProjectDoc(id: 'p', name: 'IR', bpm: 120,
        layers: [LayerDoc(id: 'a', name: 'A', color: 1, instrument: ComponentUseDoc('org.caw.synth.flagship'))]);
    final layer = s.project.layers.first;
    layer.components.add(ComponentUseDoc('org.caw.utility'));
    layer.components.add(ComponentUseDoc('org.caw.convolver', {'source': 9.0, 'mix': 1.0}));
    await e.setProject(s.project.toEngineJson());
    final file = _wav(4800);
    expect(await s.loadNativeEffectState(layer, 1, file), isTrue);
    expect(layer.components[1].state, isNotNull);
    final states = e.componentStates('a');
    expect(states[1]!.state, isNotEmpty, reason: 'the convolver saves the decoded impulse');
    // A truncated file is refused and changes nothing; so is a component that isn't there.
    final kept = layer.components[1].state;
    expect(await s.loadNativeEffectState(layer, 1, Uint8List.sublistView(file, 0, 40)), isFalse);
    expect(layer.components[1].state, kept);
    expect(await e.setComponentState('a', 5, file, 1), isFalse);
    s.engine = null;
    e.dispose();
    s.dispose();
  }, skip: _noLib ? 'set CAW_LIB to the built engine library' : null);
}
