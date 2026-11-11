// The built-in devices' plugin UIs: each opens its own UI (not the fallback), its main gestures edit the right
// parameters, live display data draws, presets and A/B work, and goldens at phone (and some desktop) size.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/devices/visuals/filter_curve.dart' show freqToX;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

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

  AppState state(String id) {
    final s = stateWith(id, make: PreviewState.new);
    Motion.setting = MotionLevel.off; // the app state applies its settings' motion; visuals stand still for goldens
    states.add(s);
    return s;
  }

  /// Opens [id]'s editor at [size] with the fake display showing a frame (or none when [live] is false).
  Future<AppState> open(WidgetTester tester, String id, {Size size = const Size(390, 844), bool live = true}) async {
    final s = state(id);
    display.frame.value = live ? fakeFrame(id) : null;
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    if (live) {
      // A few seconds of playing, so histories fill; the last frame is tick 0's.
      for (var i = 150; i >= 0; i--) {
        display.frame.value = fakeFrame(id, tick: i);
        await tester.pump();
      }
    }
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  group('every built-in opens its own UI', () {
    for (final id in [...builtinEffects, ...builtinInstruments]) {
      testWidgets(id, (tester) async {
        expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull, reason: '$id has no plugin UI');
        await open(tester, id);
        expect(find.byKey(const ValueKey('device-editor')), findsOneWidget);
        expect(find.byKey(const ValueKey('device-fallback')), findsNothing);
        expect(tester.takeException(), isNull);
        // And with no live data.
        display.frame.value = null;
        await tester.pump();
        expect(tester.takeException(), isNull);
        await close(tester);
      });
    }
  });

  // Step 5 of #175: every device on a phone held sideways (844 × 390) and narrow portrait (360 × 740), every tab,
  // lays out without overflow; the tab content scrolls instead of being cut.
  group('every built-in fits a phone, portrait and landscape, every tab', () {
    for (final id in [...builtinEffects, ...builtinInstruments]) {
      for (final size in const [Size(844, 390), Size(360, 740)]) {
        testWidgets('$id at ${size.width.round()} × ${size.height.round()}', (tester) async {
          await open(tester, id, size: size, live: false);
          expect(tester.takeException(), isNull);
          final tabs = find.byWidgetPredicate((w) => w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('device-tab-'));
          for (var i = 0; i < tabs.evaluate().length; i++) {
            await tester.tap(tabs.at(i));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'tab $i');
          }
          await close(tester);
        });
      }
    }
  });

  group('goldens, phone', () {
    for (final id in [...builtinEffects, ...builtinInstruments]) {
      testWidgets(id, (tester) async {
        await open(tester, id);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/${id.substring(8).replaceAll('.', '_')}_phone.png'));
        await close(tester);
      });
    }
  });

  group('goldens, desktop', () {
    for (final id in ['org.caw.eq', 'org.caw.compressor', 'org.caw.delay.pro', 'org.caw.drum.kit']) {
      testWidgets(id, (tester) async {
        await open(tester, id, size: const Size(1280, 800));
        await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/${id.substring(8).replaceAll('.', '_')}_desktop.png'));
        await close(tester);
      });
    }
  });

  testWidgets('the flagship\'s preset browser lists Init and the starters; picking one loads it and names it', (tester) async {
    final s = await open(tester, 'org.caw.synth.flagship');
    final t = targetOf(s, 'org.caw.synth.flagship');
    await tester.tap(find.byKey(const ValueKey('device-presets')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preset-browser')), findsOneWidget);
    expect(find.byKey(const ValueKey('preset-Init')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preset-Pluck')));
    await tester.pumpAndSettle();
    expect(t.value('env1_sustain'), 0);
    expect(t.value('osc1_unison'), 3);
    expect(find.text('Pluck'), findsOneWidget, reason: 'the header names the preset');
    t.set('osc1_level', 0.2);
    await tester.pumpAndSettle();
    expect(find.text('Pluck *'), findsOneWidget, reason: 'an edit marks it changed');
    await close(tester);
  });

  testWidgets('the header\'s A/B switch swaps two settings', (tester) async {
    final s = await open(tester, 'org.caw.eq');
    final t = targetOf(s, 'org.caw.eq');
    await tester.tap(find.byKey(const ValueKey('device-ab-b')));
    await tester.pumpAndSettle();
    t.set('b4_gain', 9);
    await tester.tap(find.byKey(const ValueKey('device-ab-a')));
    await tester.pumpAndSettle();
    expect(t.value('b4_gain'), 0);
    await tester.tap(find.byKey(const ValueKey('device-ab-b')));
    await tester.pumpAndSettle();
    expect(t.value('b4_gain'), 9);
    await close(tester);
  });

  group('gestures', () {
    testWidgets('EQ: drag a node for frequency and gain, pinch for Q, double-tap resets, power and + in the strip, a tile sets the type', (tester) async {
      final s = await open(tester, 'org.caw.eq');
      final t = targetOf(s, 'org.caw.eq');
      final view = tester.getRect(find.byKey(const ValueKey('eq-view')));
      Offset node(double hz, double db) =>
          Offset(view.left + freqToX(hz, view.width), view.center.dy - db / 24 * (view.height / 2 - 18));
      // Band 4: a bell at 800 Hz, 0 dB.
      await tester.dragFrom(node(800, 0), const Offset(40, -40));
      await tester.pumpAndSettle();
      expect(t.value('b4_gain'), greaterThan(3));
      expect(t.value('b4_freq'), greaterThan(900));
      // Pinch on band 5 (2500 Hz): spreading the fingers widens the band (lower Q).
      final q0 = t.value('b5_q');
      final at = node(2500, 0);
      final a = await tester.startGesture(at);
      final b = await tester.startGesture(at + const Offset(20, 0));
      await tester.pump();
      await a.moveBy(const Offset(-30, 0));
      await b.moveBy(const Offset(30, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(t.value('b5_q'), lessThan(q0));
      // Double-tap band 4 resets it (gain back to 0 dB); it stays on.
      final at4 = node(t.value('b4_freq'), t.value('b4_gain'));
      await tester.tapAt(at4);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at4);
      await tester.pumpAndSettle();
      expect(t.value('b4_gain'), 0);
      expect(t.value('b4_on'), 1);
      // The band's power is a button of its own.
      await tester.tap(find.byKey(const ValueKey('eq-band-6')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('eq-band-power')));
      await tester.tap(find.byKey(const ValueKey('eq-band-power')));
      await tester.pumpAndSettle();
      expect(t.value('b6_on'), 0);
      // "+" then a tap on the curve turns the first off band on there, selected, its values readable.
      await tester.ensureVisible(find.byKey(const ValueKey('eq-add')));
      await tester.tap(find.byKey(const ValueKey('eq-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('eq-add-hint')), findsOneWidget);
      final firstOff = [for (var n = 1; n <= 8; n++) if (t.param('b${n}_on') != null && t.value('b${n}_on') < 0.5) n].first;
      final v2 = tester.getRect(find.byKey(const ValueKey('eq-view')));
      await tester.tapAt(Offset(v2.left + freqToX(300, v2.width), v2.center.dy - 30));
      await tester.pumpAndSettle();
      expect(t.value('b${firstOff}_on'), 1);
      expect(t.value('b${firstOff}_freq'), closeTo(300, 30));
      expect(find.byKey(const ValueKey('eq-add-hint')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('eq-readout')), matching: find.text('BAND $firstOff')), findsOneWidget);
      // The band chips select; the selected band's type tiles set its type (Notch is tile 9).
      await tester.tap(find.byKey(const ValueKey('eq-band-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eq-type-9')));
      await tester.pumpAndSettle();
      expect(t.value('b5_type'), 9);
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('compressor: up and down on the history sets the threshold; up in the knee graph lowers the ratio', (tester) async {
      final s = await open(tester, 'org.caw.compressor');
      final t = targetOf(s, 'org.caw.compressor');
      final hero = tester.getRect(find.byKey(const ValueKey('comp-hero')));
      await tester.dragFrom(Offset(hero.left + 40, hero.center.dy), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('threshold'), greaterThan(-18));
      await tester.dragFrom(Offset(hero.right - 60, hero.center.dy), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('ratio'), lessThan(4));
      await close(tester);
    });

    testWidgets('limiter: the ceiling line drags; elsewhere drags the gain', (tester) async {
      final s = await open(tester, 'org.caw.limiter');
      final t = targetOf(s, 'org.caw.limiter');
      final hero = tester.getRect(find.byKey(const ValueKey('limiter-hero')));
      await tester.dragFrom(Offset(hero.center.dx, hero.bottom - 20), const Offset(0, -50));
      await tester.pumpAndSettle();
      expect(t.value('gain'), greaterThan(2));
      final area = Rect.fromLTRB(hero.left, hero.top + 22, hero.right, hero.bottom - 4);
      final cy = area.bottom - (-1 + 24) / 27 * area.height;
      await tester.dragFrom(Offset(hero.center.dx, cy), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(t.value('ceiling'), lessThan(-2));
      await close(tester);
    });

    testWidgets('gate: dragging away from the centre raises the threshold', (tester) async {
      final s = await open(tester, 'org.caw.gate');
      final t = targetOf(s, 'org.caw.gate');
      final hero = tester.getRect(find.byKey(const ValueKey('gate-hero')));
      await tester.dragFrom(Offset(hero.center.dx, hero.top + 50), const Offset(0, -30));
      await tester.pumpAndSettle();
      expect(t.value('threshold'), greaterThan(-40));
      await close(tester);
    });

    testWidgets('transient shaper: the left of the envelope is attack, the right sustain', (tester) async {
      final s = await open(tester, 'org.caw.transient');
      final t = targetOf(s, 'org.caw.transient');
      final hero = tester.getRect(find.byKey(const ValueKey('transient-hero')));
      await tester.dragFrom(Offset(hero.left + 30, hero.center.dy), const Offset(0, -40));
      await tester.dragFrom(Offset(hero.right - 40, hero.center.dy), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(t.value('attack'), greaterThan(0.1));
      expect(t.value('sustain'), lessThan(-0.1));
      await close(tester);
    });

    testWidgets('reverb: sideways sets the decay, up the size', (tester) async {
      final s = await open(tester, 'org.caw.reverb.pro');
      final t = targetOf(s, 'org.caw.reverb.pro');
      final hero = tester.getRect(find.byKey(const ValueKey('reverb-hero')));
      await tester.dragFrom(hero.center, const Offset(60, -30));
      await tester.pumpAndSettle();
      expect(t.value('decay'), greaterThan(2.6));
      expect(t.value('size'), greaterThan(0.6));
      await close(tester);
    });

    testWidgets('delay: the first echo drags through the sync divisions and sets the feedback; modes are tiles', (tester) async {
      final s = await open(tester, 'org.caw.delay.pro');
      final t = targetOf(s, 'org.caw.delay.pro');
      final hero = tester.getRect(find.byKey(const ValueKey('delay-hero')));
      // 1/8 D (0.375 s) of a 2.06 s view: the first left echo.
      final x = hero.left + 14 + (hero.width - 22) * 0.375 / (0.375 * 5.5);
      final y = hero.top + hero.height * 0.48 - hero.height * 0.3 * (0.35 + 0.65 * 0.3);
      await tester.dragFrom(Offset(x, y), const Offset(70, -20));
      await tester.pumpAndSettle();
      expect(t.value('sync'), greaterThan(7), reason: 'a longer division');
      expect(t.value('feedback'), greaterThan(0.4));
      await tester.tap(find.byKey(const ValueKey('mode-mode-1')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 1);
      await close(tester);
    });

    testWidgets('saturator: up on the curve adds drive, sideways bias; a tile picks the mode', (tester) async {
      final s = await open(tester, 'org.caw.saturator');
      final t = targetOf(s, 'org.caw.saturator');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('drive-hero'))), const Offset(40, -60));
      await tester.pumpAndSettle();
      expect(t.value('drive'), greaterThan(6));
      expect(t.value('bias'), greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('mode-mode-4')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 4);
      await close(tester);
    });

    testWidgets('distortion: the same UI on its shape and linear drive', (tester) async {
      final s = await open(tester, 'org.caw.distortion');
      final t = targetOf(s, 'org.caw.distortion');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('drive-hero'))), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(t.value('drive'), greaterThan(4));
      await tester.tap(find.byKey(const ValueKey('mode-shape-3')));
      await tester.pumpAndSettle();
      expect(t.value('shape'), 3);
      expect(find.byKey(const ValueKey('dknob-bits')), findsOneWidget, reason: 'Crush shows its bits');
      await close(tester);
    });

    testWidgets('filter: the handle drags the cutoff and resonance; type and LFO shape are tiles', (tester) async {
      final s = await open(tester, 'org.caw.filter');
      final t = targetOf(s, 'org.caw.filter');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('filter-hero'))), const Offset(60, -40));
      await tester.pumpAndSettle();
      expect(t.value('cutoff'), greaterThan(1300));
      expect(t.value('resonance'), greaterThan(0.2));
      await tester.tap(find.byKey(const ValueKey('mode-type-4')));
      await tester.tap(find.byKey(const ValueKey('mode-lfo_shape-2')));
      await tester.pumpAndSettle();
      expect((t.value('type'), t.value('lfo_shape')), (4, 2));
      await close(tester);
    });

    for (final (id, place) in [('org.caw.phaser', 'center'), ('org.caw.flanger', 'delay')]) {
      testWidgets('$id: sideways moves the comb, up raises the feedback', (tester) async {
        final s = await open(tester, id);
        final t = targetOf(s, id);
        final before = t.value(place);
        await tester.dragFrom(tester.getCenter(find.byKey(ValueKey('${id.substring(8)}-hero'))), const Offset(50, -30));
        await tester.pumpAndSettle();
        expect(t.value(place), greaterThan(before));
        expect(t.value('feedback'), greaterThan(0.4));
        await close(tester);
      });
    }

    testWidgets('chorus: the pad sets rate across and depth up', (tester) async {
      final s = await open(tester, 'org.caw.chorus');
      final t = targetOf(s, 'org.caw.chorus');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('xy-rate-depth'))), const Offset(40, -40));
      await tester.pumpAndSettle();
      expect(t.value('rate'), greaterThan(0.6));
      expect(t.value('depth'), greaterThan(0.5));
      await close(tester);
    });

    testWidgets('utility: sideways pans, up widens, a pinch widens; the switches flip', (tester) async {
      final s = await open(tester, 'org.caw.utility');
      final t = targetOf(s, 'org.caw.utility');
      final hero = tester.getCenter(find.byKey(const ValueKey('stereo-hero')));
      await tester.dragFrom(hero, const Offset(40, -30));
      await tester.pumpAndSettle();
      expect(t.value('pan'), greaterThan(0.1));
      expect(t.value('width'), greaterThan(1));
      final w0 = t.value('width');
      final a = await tester.startGesture(hero - const Offset(20, 0));
      final b = await tester.startGesture(hero + const Offset(20, 0));
      await tester.pump();
      await a.moveBy(const Offset(-20, 0));
      await b.moveBy(const Offset(20, 0));
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(t.value('width'), greaterThan(w0));
      await tester.tap(find.byKey(const ValueKey('toggle-invert_l')));
      await tester.pumpAndSettle();
      expect(t.value('invert_l'), 1);
      await close(tester);
    });

    testWidgets('width and balance: the same field on their one knob', (tester) async {
      var s = await open(tester, 'org.caw.stereo.width');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('stereo-hero'))), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(targetOf(s, 'org.caw.stereo.width').value('width'), lessThan(1));
      await close(tester);
      s = await open(tester, 'org.caw.stereo.balance');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('stereo-hero'))), const Offset(-50, 0));
      await tester.pumpAndSettle();
      expect(targetOf(s, 'org.caw.stereo.balance').value('pan'), lessThan(-0.1));
      await close(tester);
    });

    testWidgets('kick: the pad plays its note while held; the shape drags decay, tune and punch', (tester) async {
      final s = await open(tester, 'org.caw.drum.kick') as PreviewState;
      final t = targetOf(s, 'org.caw.drum.kick');
      final pad = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('pad-36'))));
      await tester.pump();
      expect(s.played.single.$1, 36);
      expect(s.held, hasLength(1));
      await pad.up();
      await tester.pump();
      expect(s.held, isEmpty);
      final hero = tester.getRect(find.byKey(const ValueKey('kick-hero')));
      await tester.dragFrom(hero.center, const Offset(60, -30));
      await tester.dragFrom(Offset(hero.left + 20, hero.center.dy), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('decay'), greaterThan(0.35));
      expect(t.value('tune'), greaterThan(48));
      expect(t.value('punch'), greaterThan(0.6));
      await close(tester);
    });

    testWidgets('snare and hats: halves and ends of the shape drag their own knobs; the hats have two pads', (tester) async {
      var s = await open(tester, 'org.caw.drum.snare') as PreviewState;
      var hero = tester.getRect(find.byKey(const ValueKey('snare-hero')));
      await tester.dragFrom(Offset(hero.center.dx, hero.top + 30), const Offset(40, 0));
      await tester.dragFrom(Offset(hero.center.dx, hero.bottom - 30), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(targetOf(s, 'org.caw.drum.snare').value('snappy'), greaterThan(0.18));
      expect(targetOf(s, 'org.caw.drum.snare').value('tune'), greaterThan(185));
      await close(tester);
      s = await open(tester, 'org.caw.drum.hats') as PreviewState;
      hero = tester.getRect(find.byKey(const ValueKey('hats-hero')));
      await tester.dragFrom(Offset(hero.right - 30, hero.center.dy), const Offset(-60, 0));
      await tester.pumpAndSettle();
      expect(targetOf(s, 'org.caw.drum.hats').value('open'), lessThan(0.3));
      await tester.tap(find.byKey(const ValueKey('pad-46')));
      await tester.tap(find.byKey(const ValueKey('pad-42')));
      expect([for (final p in s.played) p.$1], [46, 42]);
      await close(tester);
    });

    testWidgets('kit: a pad plays and picks its section', (tester) async {
      final s = await open(tester, 'org.caw.drum.kit') as PreviewState;
      await tester.tap(find.byKey(const ValueKey('pad-38')));
      await tester.pumpAndSettle();
      expect(s.played.single.$1, 38);
      expect(find.text('SNARE'), findsWidgets);
      final hero = tester.getRect(find.byKey(const ValueKey('kit-hero')));
      await tester.dragFrom(hero.center, const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(targetOf(s, 'org.caw.drum.kit').value('snare_snappy'), greaterThan(0.18));
      await close(tester);
    });
  });

  test('the descriptor fixture matches the engine\'s built-ins', () async {
    final e = Engine.create();
    final engine = {for (final c in await e.nativeComponents()) c.id: c};
    e.dispose();
    for (final id in [...builtinEffects, ...builtinInstruments]) {
      final want = engine[id], have = builtinInfo(id);
      expect(want, isNotNull, reason: id);
      expect([for (final p in have.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))],
          [for (final p in want!.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))],
          reason: '$id changed: refresh test/fixtures/builtin_components.json');
    }
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);

  test('presets: Init is always first; applying one sets every value, and the label tracks edits', () {
    final s = state('org.caw.compressor');
    final t = targetOf(s, 'org.caw.compressor');
    expect(DevicePresets.of(t).first.name, 'Init');
    expect(DevicePresets.label(t), 'Init');
    t.set('ratio', 8);
    expect(DevicePresets.label(t), 'Custom');
    DevicePresets.apply(t, DevicePresets.of(t).first);
    expect(t.value('ratio'), 4);
    expect(DevicePresets.label(t), 'Init');
  });

  test('A/B: B starts as a copy of A; switching back restores A', () {
    final s = state('org.caw.compressor');
    final t = targetOf(s, 'org.caw.compressor');
    t.set('ratio', 6);
    DeviceAB.select(t, true);
    expect(t.value('ratio'), 6);
    t.set('ratio', 12);
    DeviceAB.select(t, false);
    expect(t.value('ratio'), 6);
    DeviceAB.select(t, true);
    expect(t.value('ratio'), 12);
  });
}
