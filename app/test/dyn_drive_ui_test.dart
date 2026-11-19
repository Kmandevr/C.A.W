// The Dynamics and Drive device pages (1.0.8): variant cards as one undo step with the reset rule, each hero's drags, and no overflow at phone and desktop sizes.
import 'dart:convert';
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/variant_edit.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/effects/dyn_drive/drive_device.dart';
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

  /// Opens merged device [id] on [variant] at [size]; edits after this are undo steps.
  Future<(AppState, DeviceTarget)> open(WidgetTester tester, String id,
      {int variant = 0, Size size = const Size(412, 915), Map<String, double> values = const {}}) async {
    final s = stateWith(id, make: PreviewState.new);
    Motion.setting = MotionLevel.off;
    states.add(s);
    final t = targetOf(s, id);
    if (variant != 0) s.setDeviceVariant(t, variant);
    s.project.layers.first.components.single.params.addAll(values);
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    display.frame.value = fakeFrame(id);
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    return (s, t);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('every Dynamics and Drive device opens its own page, with no Variant pill', (tester) async {
    for (final id in ['org.caw.compressor', 'org.caw.limiter', 'org.caw.transient', 'org.caw.drive', 'org.caw.bits']) {
      expect(DeviceEditors.custom(id, builtinInfo(id)), isNotNull, reason: id);
      await open(tester, id);
      expect(find.byKey(const ValueKey('device-fallback')), findsNothing, reason: id);
      expect(find.byKey(const ValueKey('variant-pick-0')), findsNothing, reason: '$id: cards replace the pill');
      expect(tester.takeException(), isNull);
      await close(tester);
    }
  });

  testWidgets('a Compressor card switches the variant in one undo step, resetting the knobs it doesn\'t share', (tester) async {
    // 1.1.0: Down, Dynamics, Up and Bus (Gate, Shape and Duck are their own devices' now).
    final (s, t) = await open(tester, 'org.caw.compressor', values: {'threshold': -20, 'attack': 40});
    expect(find.byKey(const ValueKey('variant-card-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('variant-card-4')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('variant-card-2')));
    await tester.pumpAndSettle();
    expect(t.info!.variantIndex, 2);
    // Up's threshold has another range (−80..0): a different knob, so it starts at its default.
    expect(t.value('threshold'), -30);
    expect(find.text('UP'), findsWidgets);
    expect(find.byKey(const ValueKey('dknob-range')), findsOneWidget);
    expect(s.undo(), isTrue);
    await tester.pumpAndSettle();
    expect(t.info!.variantIndex, 0);
    expect((t.value('threshold'), t.value('attack')), (-20, 40));
    expect(find.byKey(const ValueKey('dknob-ratio')), findsOneWidget);
    // Bus: its stepped ratio as chips.
    await tester.tap(find.byKey(const ValueKey('variant-card-3')));
    await tester.pumpAndSettle();
    expect(find.text('BUS'), findsWidgets);
    expect(find.byKey(const ValueKey('chip-ratio-3')), findsOneWidget, reason: '1.5, 2, 4 and 10:1');
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a Drive card switches the variant and resets its drive; mode cards set the mode', (tester) async {
    final (s, t) = await open(tester, 'org.caw.drive', values: {'drive': 12, 'shape': 1});
    await tester.tap(find.byKey(const ValueKey('variant-card-1')));
    await tester.pumpAndSettle();
    expect(t.info!.variantIndex, 1);
    expect(t.value('drive'), t.param('drive')!.defaultValue, reason: 'dB drive is another knob');
    expect(find.byKey(const ValueKey('mode-mode-10')), findsOneWidget, reason: 'Saturate\'s eleven modes');
    await tester.tap(find.byKey(const ValueKey('mode-mode-1')));
    await tester.pumpAndSettle();
    expect(t.value('mode'), 1);
    expect(s.undo(), isTrue);
    expect(s.undo(), isTrue);
    await tester.pumpAndSettle();
    expect((t.info!.variantIndex, t.value('drive'), t.value('shape')), (0, 12, 1));
    await close(tester);
  });

  group('the heroes edit what they show', () {
    testWidgets('compressor (Down): the trace drags the threshold, the curve the ratio, the knee bracket the knee', (tester) async {
      final (_, t) = await open(tester, 'org.caw.compressor');
      final hero = tester.getRect(find.byKey(const ValueKey('comp-hero')));
      await tester.dragFrom(Offset(hero.left + 40, hero.center.dy), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('threshold'), greaterThan(-18));
      await tester.dragFrom(Offset(hero.right - 40, hero.top + 60), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('ratio'), lessThan(4));
      // The knee bracket's handle: 12 dp above the plot's bottom, at the knee's top end.
      final ph = hero.height - 28, pw = ph < hero.width * 0.48 ? ph : hero.width * 0.48;
      final left = hero.right - pw - 10;
      final thr = t.value('threshold'), knee = t.value('knee');
      final kx = left + ((thr + knee / 2) + 60) / 60 * pw;
      await tester.dragFrom(Offset(kx, hero.top + 22 + ph - 12), const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(t.value('knee'), greaterThan(6));
      await close(tester);
    });

    testWidgets('dynamics, gate and duck: their handles move their own knobs', (tester) async {
      var (_, t) = await open(tester, 'org.caw.compressor', variant: 1);
      var hero = tester.getRect(find.byKey(const ValueKey('comp-hero')));
      await tester.dragFrom(Offset(hero.right - 40, hero.top + 60), const Offset(-20, -40));
      await tester.pumpAndSettle();
      expect(t.value('high_threshold'), lessThan(-12));
      expect(t.value('high_ratio'), lessThan(2));
      await close(tester);

      (_, t) = await open(tester, 'org.caw.gate');  // 1.1.0: the Gate's own device (1.0.9: the Compressor's 2)
      hero = tester.getRect(find.byKey(const ValueKey('comp-hero')));
      await tester.dragFrom(Offset(hero.left + 40, hero.center.dy), const Offset(0, -30));
      await tester.pumpAndSettle();
      expect(t.value('threshold'), greaterThan(-40));
      // The range handle sits where the expander meets the floor.
      final ph = hero.height - 28, pw = ph < hero.width * 0.48 ? ph : hero.width * 0.48;
      final left = hero.right - pw - 10, top = hero.top + 22;
      final thr = t.value('threshold'), ratio = t.value('ratio'), range = t.value('range');
      final x0 = (thr + range / (ratio - 1)).clamp(-80.0, thr);
      final out = x0 + range < thr + (x0 - thr) * ratio ? thr + (x0 - thr) * ratio : x0 + range;
      final at = Offset(left + (x0 + 80) / 80 * pw, top + ph - ((out + 80) / 80).clamp(0.0, 1.0) * ph);
      await tester.dragFrom(at, const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('range'), greaterThan(-80));
      await close(tester);

      (_, t) = await open(tester, 'org.caw.duck');  // 1.1.0: the Ducker's first (1.0.9: the Compressor's 4)
      expect(find.byKey(const ValueKey('chip-detection-2')), findsOneWidget, reason: 'RMS, Peak, ISP');
      await tester.tap(find.byKey(const ValueKey('chip-detection-2')));
      await tester.pumpAndSettle();
      expect(t.value('detection'), 2);
      hero = tester.getRect(find.byKey(const ValueKey('comp-hero')));
      await tester.dragFrom(Offset(hero.right - 40, hero.top + 60), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('amount'), lessThan(0.5));
      await close(tester);
    });

    testWidgets('limiter: the ceiling line and the gain; the big GR meter shows', (tester) async {
      final (_, t) = await open(tester, 'org.caw.limiter');
      expect(find.byKey(const ValueKey('limiter-gr-meter')), findsOneWidget);
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

    testWidgets('transient: the attack part drags attack, the rest sustain', (tester) async {
      final (_, t) = await open(tester, 'org.caw.transient');
      final hero = tester.getRect(find.byKey(const ValueKey('transient-hero')));
      await tester.dragFrom(Offset(hero.left + 20, hero.center.dy), const Offset(0, -40));
      await tester.dragFrom(Offset(hero.right - 60, hero.center.dy), const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(t.value('attack'), greaterThan(0.1));
      expect(t.value('sustain'), lessThan(-0.1));
      await close(tester);
    });

    testWidgets('drive: up drives harder; sideways the bias on Saturate and Phase, the softness on Clip', (tester) async {
      for (final (variant, side) in [(0, null), (1, 'bias'), (2, 'softness'), (3, 'bias')]) {
        final (_, t) = await open(tester, 'org.caw.drive', variant: variant);
        final before = t.value('drive'), sideBefore = side == null ? 0 : t.value(side);
        await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('drive-hero'))), const Offset(40, -60));
        await tester.pumpAndSettle();
        expect(t.value('drive'), greaterThan(before), reason: 'variant $variant');
        if (side != null) expect(t.value(side), greaterThan(sideBefore), reason: 'variant $variant');
        await close(tester);
      }
    });

    testWidgets('clip: Clip to 0 dB hides the ceiling knob', (tester) async {
      final (_, t) = await open(tester, 'org.caw.drive', variant: 2);
      expect(find.byKey(const ValueKey('dknob-ceiling')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('toggle-master')));
      await tester.tap(find.byKey(const ValueKey('toggle-master')));
      await tester.pumpAndSettle();
      expect(t.value('master'), 1);
      expect(find.byKey(const ValueKey('dknob-ceiling')), findsNothing);
      await close(tester);
    });

    testWidgets('bits: up and down the bits, sideways the rate', (tester) async {
      final (_, t) = await open(tester, 'org.caw.bits');
      await tester.dragFrom(tester.getCenter(find.byKey(const ValueKey('bits-hero'))), const Offset(60, -40));
      await tester.pumpAndSettle();
      expect(t.value('bits'), greaterThan(8));
      expect(t.value('rate'), greaterThan(8000));
      await close(tester);
    });
  });

  test('the drive curve maths: the harmonics of a clean sine are its own, a folded one adds odd ones', () {
    final clean = [for (var i = 0; i < 128; i++) 0.5 * math.sin(2 * math.pi * i / 128)];
    final h = cycleHarmonics(clean);
    expect(h.first, closeTo(0.5, 1e-9));
    expect(evenShare(h), isNull, reason: 'no overtones');
    final clipped = [for (final v in clean) (v * 4).clamp(-0.5, 0.5).toDouble()];
    expect(evenShare(cycleHarmonics(clipped)), closeTo(0, 1e-6), reason: 'a symmetric clip: odd only');
  });

  group('no overflow', () {
    const pages = [
      ('org.caw.compressor', 5), ('org.caw.limiter', 1), ('org.caw.transient', 1), ('org.caw.drive', 4), ('org.caw.bits', 1),
    ];
    for (final size in const [Size(360, 740), Size(412, 915), Size(844, 390), Size(1280, 800)]) {
      testWidgets('every page and variant at ${size.width.round()} × ${size.height.round()}', (tester) async {
        for (final (id, count) in pages) {
          for (var v = 0; v < count; v++) {
            await open(tester, id, variant: v, size: size);
            expect(tester.takeException(), isNull, reason: '$id variant $v');
            final more = find.byKey(const ValueKey('device-fold'));
            if (more.evaluate().isNotEmpty) {
              await tester.ensureVisible(more.first);
              await tester.tap(more.first);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: '$id variant $v, MORE open');
            }
            await close(tester);
          }
        }
      });
    }
  });
}
