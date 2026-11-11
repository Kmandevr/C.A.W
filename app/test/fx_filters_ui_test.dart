// The EQ & Filter group's plugin UIs: each opens its own UI, fits a phone both ways, its hero's gestures edit the right parameters, its display decodes, and goldens at phone size.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/effects/filters/filters_shared.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/devices/visuals/filter_curve.dart' show freqToX;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const filters = ['org.caw.ladder', 'org.caw.nlfilter', 'org.caw.comb', 'org.caw.resonator', 'org.caw.formant',
  'org.caw.disperser', 'org.caw.eq.dj', 'org.caw.tilt', 'org.caw.geq'];

void main() {
  var motion = MotionLevel.full;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  final states = <AppState>[];

  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  Future<AppState> open(WidgetTester tester, String id, {Size size = const Size(390, 844), bool live = true}) async {
    final s = stateWith(id, make: PreviewState.new);
    Motion.setting = MotionLevel.off;
    states.add(s);
    display.frame.value = live ? fakeFrame(id, values: {'c10': 3, 'ceiling_db': -2, 'low_db': -10, 'mid_db': -20, 'high_db': -30}) : null;
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  group('each opens its own UI, with and without live data', () {
    for (final id in filters) {
      testWidgets(id, (tester) async {
        expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull);
        await open(tester, id);
        expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
        expect(find.byKey(const ValueKey('device-fallback')), findsNothing);
        display.frame.value = null;
        await tester.pump();
        expect(tester.takeException(), isNull);
        await close(tester);
      });
    }
  });

  group('each fits a phone, portrait and landscape', () {
    for (final id in filters) {
      for (final size in const [Size(844, 390), Size(360, 740)]) {
        testWidgets('$id at ${size.width.round()} × ${size.height.round()}', (tester) async {
          await open(tester, id, size: size, live: false);
          expect(tester.takeException(), isNull);
          await close(tester);
        });
      }
    }
  });

  group('each shows inline in the FX stack, portrait and landscape', () {
    for (final id in filters) {
      for (final size in const [Size(390, 844), Size(844, 390)]) {
        testWidgets('$id at ${size.width.round()} × ${size.height.round()}', (tester) async {
          final s = stateWith(id);
          Motion.setting = MotionLevel.off;
          states.add(s);
          display.frame.value = fakeFrame(id);
          await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s,
              builder: (_, _) => FxStack(state: s, layer: s.project.layers.first))), size);
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('fx-page-${id.substring(8)}')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await close(tester);
        });
      }
    }
  });

  group('goldens, phone', () {
    for (final id in filters) {
      testWidgets(id, (tester) async {
        await open(tester, id);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/${id.substring(8)}_phone.png'));
        await close(tester);
      });
    }
  });

  group('gestures', () {
    Future<void> drag(WidgetTester tester, String key, Offset from, Offset by) async {
      final hero = tester.getRect(find.byKey(ValueKey(key)));
      await tester.dragFrom(hero.topLeft + from, by);
      await tester.pumpAndSettle();
    }

    for (final (id, key, x, y) in [
      ('org.caw.ladder', 'ladder-hero', 'cutoff', 'resonance'),
      ('org.caw.nlfilter', 'nlfilter-hero', 'cutoff', 'q'),
      ('org.caw.comb', 'comb-hero', 'freq', 'feedback'),
      ('org.caw.resonator', 'resonator-hero', 'note', 'decay'),
      ('org.caw.disperser', 'disperser-hero', 'freq', 'amount'),
      ('org.caw.tilt', 'tilt-hero', 'freq', 'tilt'),
    ]) {
      testWidgets('$id: right raises $x, up raises $y; double-tap resets', (tester) async {
        final s = await open(tester, id);
        final t = targetOf(s, id);
        final x0 = t.value(x), y0 = t.value(y);
        await drag(tester, key, const Offset(120, 100), const Offset(60, -50));
        expect(t.value(x), greaterThan(x0), reason: x);
        expect(t.value(y), greaterThan(y0), reason: y);
        final hero = tester.getRect(find.byKey(ValueKey(key)));
        await tester.tapAt(hero.center);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(hero.center);
        await tester.pumpAndSettle();
        expect(t.value(x), closeTo(t.param(x)!.defaultValue, 1e-9));
        await close(tester);
      });
    }

    testWidgets('ladder: the mode tiles and slope pick the tap', (tester) async {
      final s = await open(tester, 'org.caw.ladder');
      final t = targetOf(s, 'org.caw.ladder');
      await tester.tap(find.byKey(const ValueKey('mode-mode-2')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 2);
      await tester.tap(find.byKey(const ValueKey('dchoice-slope-0')));
      await tester.pumpAndSettle();
      expect(t.value('slope'), 0);
      await close(tester);
    });

    testWidgets('formant: the pad moves the vowel', (tester) async {
      final s = await open(tester, 'org.caw.formant');
      final t = targetOf(s, 'org.caw.formant');
      final pad = tester.getRect(find.byKey(const ValueKey('xy-vowel_x-vowel_y')));
      await tester.dragFrom(pad.center, const Offset(-60, 40));
      await tester.pumpAndSettle();
      expect(t.value('vowel_x'), lessThan(0.5));
      expect(t.value('vowel_y'), lessThan(0.85));
      await close(tester);
    });

    testWidgets('3-band: a band drags its gain, a crossover its split, a double-tap kills', (tester) async {
      final s = await open(tester, 'org.caw.eq.dj');
      final t = targetOf(s, 'org.caw.eq.dj');
      final hero = tester.getRect(find.byKey(const ValueKey('eq3-hero')));
      final midX = freqToX(800, hero.width);
      await tester.dragFrom(hero.topLeft + Offset(midX, hero.height / 2), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('mid'), greaterThan(0));
      final lowX = freqToX(250, hero.width);
      await tester.dragFrom(hero.topLeft + Offset(lowX, hero.height / 2), const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(t.value('low_x'), greaterThan(260));
      final at = hero.topLeft + Offset(freqToX(60, hero.width), hero.height / 2);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(t.value('kill_low'), 1);
      await close(tester);
    });

    testWidgets('graphic EQ: a swipe draws the bars it crosses; Flat clears them', (tester) async {
      final s = await open(tester, 'org.caw.geq');
      final t = targetOf(s, 'org.caw.geq');
      final hero = tester.getRect(find.byKey(const ValueKey('geq-hero')));
      final bar = hero.width / 31;
      await tester.dragFrom(hero.topLeft + Offset(bar * 5.5, hero.height * 0.3), Offset(bar * 6, 0));
      await tester.pumpAndSettle();
      for (var b = 6; b <= 12; b++) {
        expect(t.value('g$b'), greaterThan(2), reason: 'g$b');
      }
      expect(t.value('g20'), 0);
      await tester.tap(find.byKey(const ValueKey('geq-flat')));
      await tester.pumpAndSettle();
      expect(t.value('g8'), 0);
      await close(tester);
    });
  });

  test('presets: each has Init and its engine presets', () {
    for (final id in filters) {
      final s = stateWith(id);
      final names = [for (final p in DevicePresets.of(targetOf(s, id))) p.name];
      expect(names.first, 'Init', reason: id);
      expect(names.length, inInclusiveRange(4, 9), reason: id);
      s.dispose();
    }
  });

  test('display floats decode into frames', () {
    final ladder = decodeDisplay('org.caw.ladder', [-6, -9, 0, 1, 800, 0.95, 6, 1, 2], 9);
    expect((ladder.inputDb, ladder.outputDb, ladder.values['cutoff'], ladder.values['oscillating']), (-6, -9, 800, 1));
    final f = List<double>.filled(132, -120);
    f[2] = 64;
    f[3] = 1;
    f[4] = 0;
    f[4 + 64 + 5] = 4.5;
    final geq = decodeDisplay('org.caw.geq', f, 132);
    expect(geq.spectrum!.length, 64);
    expect(geq.spectrum![0], 1.0);
    expect(geq.values['c5'], 4.5);
    f[3] = 0;
    expect(decodeDisplay('org.caw.geq', f, 132).spectrum, isNull);
    final eq3 = decodeDisplay('org.caw.eq.dj', [-6, -9, -10, -20, -30, 1, 0, 0, 250, 2500], 10);
    expect((eq3.values['low_db'], eq3.values['kill_low'], eq3.values['high_x']), (-10, 1, 2500));
  });

  test('the browser lists every effect of the group under EQ & Filter', () {
    expect([for (final e in filtersBrowserEntries) e.id], filters);
    for (final e in filtersBrowserEntries) {
      expect(e.category, 'EQ & Filter');
      expect(e.description, isNotEmpty);
    }
  });

  test('the response maths: a 24 dB ladder 3 octaves up, LR4 sums flat, the tilt\'s ends', () {
    expect(toDb(ladderResponse(8000, cutoff: 1000, resonance: 0, mode: 0, slope: 1, comp: 0).abs), lessThan(-60));
    for (final hz in [50.0, 250.0, 1000.0, 2500.0, 12000.0]) {
      final b = eq3Bands(hz, low: 250, high: 2500);
      expect(toDb((b[0] + b[1] + b[2]).abs), closeTo(0, 0.01));
    }
    expect(toDb(tiltResponse(20, tilt: 6, freq: 1000, q: 0.5).abs), closeTo(-3, 0.3));
    expect(toDb(tiltResponse(20000, tilt: 6, freq: 1000, q: 0.5).abs), closeTo(3, 0.4));
  });

  test('the fixture matches the engine\'s descriptors', () async {
    final e = Engine.create();
    final engine = {for (final c in await e.nativeComponents()) c.id: c};
    e.dispose();
    for (final id in [...filters, 'org.caw.eq']) {
      final want = engine[id], have = builtinInfo(id);
      expect(want, isNotNull, reason: id);
      expect([for (final p in have.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))],
          [for (final p in want!.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))], reason: id);
    }
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
