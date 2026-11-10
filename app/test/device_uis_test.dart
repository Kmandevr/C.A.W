// The built-in devices' plugin UIs: each opens its own UI (not the fallback), its main gestures edit the right
// parameters, live display data draws, presets and A/B work, and goldens at phone (and some desktop) size.
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
    final s = stateWith(id);
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

  group('goldens, phone', () {
    for (final id in [...builtinEffects, ...builtinInstruments]) {
      testWidgets(id, (tester) async {
        await open(tester, id);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/${id.substring(8).replaceAll('.', '_')}_phone.png'));
        await close(tester);
      });
    }
  });

  group('gestures', () {
    testWidgets('EQ: drag a node for frequency and gain, pinch for Q, double-tap toggles, a tile sets the type', (tester) async {
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
      // Double-tap band 6 (6 kHz) switches it off.
      await tester.tapAt(node(6000, 0));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(node(6000, 0));
      await tester.pumpAndSettle();
      expect(t.value('b6_on'), 0);
      // The band chips select; the selected band's type tiles set its type (Notch is tile 9).
      await tester.tap(find.byKey(const ValueKey('eq-band-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('eq-type-9')));
      await tester.pumpAndSettle();
      expect(t.value('b5_type'), 9);
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  });

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
