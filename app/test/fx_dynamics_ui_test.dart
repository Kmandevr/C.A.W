// fx-dynamics: the Dynamics and Drive effects' UIs: display decoding, the curve maths, the browser entries and each hero's gestures.
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/effects/drive_editors.dart';
import 'package:caw/ui/devices/effects/dynamics/catalog.dart';
import 'package:caw/ui/devices/effects/dynamics/fx_math.dart';
import 'package:caw/ui/devices/kit/presets.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const _new = ['org.caw.dynamics', 'org.caw.multiband', 'org.caw.deesser', 'org.caw.clipper', 'org.caw.phasedist'];

void main() {
  test('the new effects\' display floats decode by name', () {
    final d = decodeDisplay('org.caw.dynamics', [-6, -9, 3.5, 4, 2, -20, -40, 2, -12, 4, 6, 24, 0, 1], 14);
    expect((d.inputDb, d.values['gain_db'], d.values['level_db'], d.values['high_ratio']), (-6, 3.5, -20, 4));
    final m = decodeDisplay('org.caw.multiband', [
      -6, -8, 1, 88.3, 2500, //
      -30, 4, 6, 0, -33.8, -40.8, 10.3, //
      -20, -5, 0, 7, -30.2, -41.8, 5.7, //
      -40, 9, 12, 0, -35.5, -40.8, 10.3,
    ], 26);
    expect((m.values['ott'], m.values['xover_high_hz'], m.values['b2_gr_db'], m.values['b3_makeup_db']), (1, 2500, -5, 10.3));
    final s = decodeDisplay('org.caw.deesser', [-6, -7, 4, 6, -18, -30, 6500, 12, 0], 9);
    expect((s.gainReductionDb, s.values['freq']), (-4, 6500));
    final c = decodeDisplay('org.caw.clipper', [-1, -0.3, 0, 12, -0.3, 0.5, 2, 3.2, 0, 2, 0.5, -0.5], 12);
    expect((c.values['over_db'], c.values['oversample'], c.values['curve1']), (3.2, 2, -0.5));
    final p = decodeDisplay('org.caw.phasedist', [-6, -6, 0.4, 1, 0, 0, 0.3, -0.2, 1.1, 0.9], 10);
    expect((p.values['delay_l_ms'], p.values['mod_r']), (1.1, -0.2));
  });

  test('the curves match the engine\'s: dynamics, clip, the saturator\'s new shapes', () {
    // 14 dB over at 4:1 is 10.5 dB down; 20 dB under at 2:1 is lifted 10; the range holds it.
    expect(dynamicsGainDb(-6, lowThr: -30, lowRatio: 1, highThr: -20, highRatio: 4, knee: 0), closeTo(-10.5, 1e-9));
    expect(dynamicsGainDb(-50, lowThr: -30, lowRatio: 2, highThr: -20, highRatio: 1, knee: 0), closeTo(10, 1e-9));
    expect(dynamicsGainDb(-70, lowThr: -30, lowRatio: 10, highThr: -20, highRatio: 1, knee: 0, range: 12), 12);
    expect(ratioLabel(0.5), '1:2.0');
    expect(ratioLabel(50), '∞:1');
    for (final mode in [0, 1, 2]) {
      for (final u in [-3.0, -1.0, 0.5, 2.0, 9.0]) {
        expect(clipCurve(mode, u, 0.5).abs(), lessThanOrEqualTo(1.0));
      }
    }
    expect(clipCurve(1, 0.4, 0.5), 0.4); // below the knee: clean
    expect(driveShapeOf('Tri fold'), DriveShape.triFold);
    expect(driveShapeOf('Fold'), DriveShape.fold);
    expect(driveShapeOf('Bit shape'), DriveShape.bitShape);
    expect(driveShapeOf('Crush'), DriveShape.crush);
    expect(driveCurve(DriveShape.triFold, 1, 2), closeTo(0, 1e-9)); // x 2 = 2: folded back to 0
    expect(driveCurve(DriveShape.rectify, -0.5, 1), closeTo(driveCurve(DriveShape.rectify, 0.5, 1), 1e-12));
  });

  test('every new effect has a browser entry with a category, a description and an editor', () {
    final ids = {for (final e in fxDynamicsCatalog) e.id: e};
    for (final id in _new) {
      expect(ids[id], isNotNull, reason: id);
      expect(['Dynamics', 'Drive'], contains(ids[id]!.category));
      expect(ids[id]!.description.length, inInclusiveRange(10, 80));
      expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull, reason: id);
      // 3 to 8 factory presets from the engine (the fixture carries its descriptor's).
      final presets = builtinInfo(id).presets;
      expect(presets.length, inInclusiveRange(3, 8), reason: id);
    }
  });

  group('the heroes edit what they show', () {
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

    testWidgets('dynamics: a handle moves its threshold sideways and its ratio up and down', (tester) async {
      final s = await open(tester, 'org.caw.dynamics');
      final t = targetOf(s, 'org.caw.dynamics');
      final hero = tester.getRect(find.byKey(const ValueKey('dyn-hero')));
      // The high handle sits at -12 dB in: near the top right of the plot.
      final plotW = hero.width - 32;
      final at = Offset(hero.left + 10 + (60 / 72) * plotW, hero.top + 40);
      await tester.dragFrom(at, const Offset(-30, -40));
      await tester.pumpAndSettle();
      expect(t.value('high_threshold'), lessThan(-12));
      expect(t.value('high_ratio'), lessThan(2), reason: 'up: more output above the threshold');
      await tester.dragFrom(Offset(hero.left + 10 + (32 / 72) * plotW, hero.bottom - 60), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('low_ratio'), greaterThan(1), reason: 'up: quiet sound lifted');
      await close(tester);
    });

    testWidgets('multiband: a crossover drags sideways, a band threshold up and down, and OTT is a tile', (tester) async {
      final s = await open(tester, 'org.caw.multiband');
      final t = targetOf(s, 'org.caw.multiband');
      expect(t.value('mode'), 1, reason: 'OTT by default');
      final hero = tester.getRect(find.byKey(const ValueKey('mb-hero')));
      final areaW = hero.width - 12;
      double xOf(double hz) => hero.left + 6 + areaW * (math.log(hz / 20) / math.log(1000));
      await tester.dragFrom(Offset(xOf(2500), hero.center.dy), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(t.value('xover_high'), greaterThan(2500));
      await tester.tap(find.byKey(const ValueKey('mode-mode-0')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 0);
      final before = t.value('b2_down_thr');
      final areaH = hero.height - 38;
      final y = hero.top + 22 + areaH * (1 - (before + 72) / 72);
      await tester.dragFrom(Offset(xOf(450), y), const Offset(0, -30));
      await tester.pumpAndSettle();
      expect(t.value('b2_down_thr'), greaterThan(before));
      await close(tester);
    });

    testWidgets('de-esser: sideways moves the frequency, up the threshold', (tester) async {
      final s = await open(tester, 'org.caw.deesser');
      final t = targetOf(s, 'org.caw.deesser');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('deess-hero'))), const Offset(40, -30));
      await tester.pumpAndSettle();
      expect(t.value('freq'), greaterThan(6000));
      expect(t.value('threshold'), greaterThan(-30));
      await tester.tap(find.byKey(const ValueKey('mode-mode-1')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 1);
      await close(tester);
    });

    testWidgets('clipper: up drives harder, the ceiling line drags, clip to 0 dB hides the ceiling knob', (tester) async {
      final s = await open(tester, 'org.caw.clipper');
      final t = targetOf(s, 'org.caw.clipper');
      final hero = tester.getRect(find.byKey(const ValueKey('clip-hero')));
      await tester.dragFrom(Offset(hero.center.dx, hero.center.dy + 30), const Offset(30, -50));
      await tester.pumpAndSettle();
      expect(t.value('drive'), greaterThan(0));
      expect(t.value('softness'), greaterThan(0.5));
      expect(find.byKey(const ValueKey('dknob-ceiling')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('toggle-master')));
      await tester.tap(find.byKey(const ValueKey('toggle-master')));
      await tester.pumpAndSettle();
      expect(t.value('master'), 1);
      expect(find.byKey(const ValueKey('dknob-ceiling')), findsNothing);
      await close(tester);
    });

    testWidgets('phase distortion: up adds drive, sideways bias', (tester) async {
      final s = await open(tester, 'org.caw.phasedist');
      final t = targetOf(s, 'org.caw.phasedist');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('pd-hero'))), const Offset(40, -40));
      await tester.pumpAndSettle();
      expect(t.value('drive'), greaterThan(0.4));
      expect(t.value('bias'), greaterThan(0));
      await close(tester);
    });

    testWidgets('saturator: eleven mode tiles in two rows, the new ones pickable, a factory preset loads', (tester) async {
      final s = await open(tester, 'org.caw.saturator');
      final t = targetOf(s, 'org.caw.saturator');
      expect(find.byKey(const ValueKey('mode-mode-10')), findsOneWidget);
      final first = tester.getRect(find.byKey(const ValueKey('mode-mode-0')));
      final seventh = tester.getRect(find.byKey(const ValueKey('mode-mode-6')));
      expect(seventh.top, greaterThan(first.bottom - 1), reason: 'the second row');
      await tester.tap(find.byKey(const ValueKey('mode-mode-9')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 9);
      expect(find.byKey(const ValueKey('dknob-bits')), findsOneWidget, reason: 'Bit shape shows its bits');
      final fuzz = DevicePresets.of(t).firstWhere((p) => p.name == 'Fuzz box');
      DevicePresets.apply(t, fuzz);
      await tester.pumpAndSettle();
      expect(t.value('mode'), 6);
      await close(tester);
    });
  });
}
