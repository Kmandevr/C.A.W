// The Space, Modulation, Utility and Pitch merged devices' pages (1.0.8): mode cards switch the variant in one undo
// step with the reset rule, each centrepiece drag moves the right knob, no overflow at four sizes; and, with
// CAW_SPACE_SCREENS=<dir>, phone and wide PNGs of every device for the owner.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// Each merged device's pages by the old id of each variant (the first: the device's own).
const _devices = <String, List<String>>{
  'org.caw.delay': ['org.caw.delay.pro', 'org.caw.delay.pingpong'],
  'org.caw.reverb': ['org.caw.reverb.pro', 'org.caw.shimmer'],
  'org.caw.chorus': ['org.caw.chorus', 'org.caw.ensemble', 'org.caw.doubler', 'org.caw.flanger', 'org.caw.vibrato', 'org.caw.rotary'],
  'org.caw.phaser': ['org.caw.phaser'],
  'org.caw.tremolo': ['org.caw.tremolo', 'org.caw.autopan'],
  'org.caw.utility': ['org.caw.utility', 'org.caw.stereo.width', 'org.caw.stereo.balance', 'org.caw.imager', 'org.caw.haas',
    'org.caw.channelmixer'],
  'org.caw.shift': ['org.caw.pitchshift', 'org.caw.freqshift'],
};

/// Live-looking values for each variant's display (the layouts in docs/engine.md, "Display data").
Map<String, double> _live(String id) {
  final r = math.Random(4);
  return switch (id) {
    'org.caw.delay.pro' => {'time_l_s': 0.375, 'time_r_s': 0.375, 'feedback': 0.4},
    'org.caw.ensemble' => {for (var v = 0; v < 4; v++) 'voice$v': 12 + 3 * math.sin(v * 1.9)},
    'org.caw.doubler' => {'double0': 17, 'double1': 25},
    'org.caw.rotary' => {'horn_angle': 0.3, 'drum_angle': 0.1},
    'org.caw.tremolo' || 'org.caw.autopan' => {'lfo_l': 0.55, 'lfo_r': -0.2, 'gain_l': 0.8, 'gain_r': 0.5},
    'org.caw.imager' => {
      'corr_low': 0.95, 'corr_mid': 0.6, 'corr_high': 0.3, 'balance': 0.05,
      for (var p = 0; p < 128; p++) ...{'m$p': (r.nextDouble() * 2 - 1) * 0.7, 's$p': (r.nextDouble() * 2 - 1) * 0.3},
    },
    'org.caw.haas' => {'mono_loss_db': -2.4},
    'org.caw.pitchshift' => {'semitones_now': 7.2, 'latency_ms': 30},
    _ => const {},
  };
}

final _screens = Platform.environment['CAW_SPACE_SCREENS'];

void main() {
  late DeviceDisplaySource source;
  late FakeDisplay display;
  final motion = Motion.setting;
  final states = <AppState>[];

  setUp(() {
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

  Future<AppState> open(WidgetTester tester, String id, {Size size = const Size(412, 915), double ratio = 1}) async {
    final s = stateWith(id, make: PreviewState.new);
    s.starting = false; // edits are undo steps, as after a project opens
    Motion.setting = MotionLevel.off;
    states.add(s);
    display.frame.value = fakeFrame(id, values: _live(id));
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size * ratio);
    tester.view.devicePixelRatio = ratio;
    await tester.pump();
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  DeviceTarget target(AppState s) => DeviceTarget(s, 'a', 0);

  test('each merged device has one page, whatever its variant, and the page shows the cards (no Variant pill)', () {
    for (final MapEntry(key: device, value: olds) in _devices.entries) {
      for (final id in olds) {
        final e = DeviceEditors.custom(device, builtinInfo(id));
        expect(e?.ownsVariant, isTrue, reason: id);
        expect(identical(e, DeviceEditors.custom(device, builtinInfo(olds.first))), isTrue, reason: id);
      }
    }
  });

  group('the cards switch the variant: one undo step, the knobs the variants don\'t share reset', () {
    for (final (device, from, to, knob, set) in [
      ('org.caw.delay', 'org.caw.delay.pro', 1, 'feedback', 0.8),
      ('org.caw.reverb', 'org.caw.reverb.pro', 1, 'decay', 9.0),
      ('org.caw.chorus', 'org.caw.chorus', 3, 'rate', 2.0),
      ('org.caw.tremolo', 'org.caw.tremolo', 1, 'rate', 9.0),
      ('org.caw.utility', 'org.caw.utility', 4, 'width', 1.6),
      ('org.caw.shift', 'org.caw.pitchshift', 1, 'semitones', 5.0),
    ]) {
      testWidgets(device, (tester) async {
        final s = await open(tester, from);
        final t = target(s);
        t.set(knob, set);
        s.endUndoStep();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('variant-pick-0')), findsNothing, reason: 'no pill');
        await tester.tap(find.byKey(ValueKey('variant-card-$to')));
        await tester.pumpAndSettle();
        expect(MergedDevices.variantOf(device, t.use!.params), to);
        final info = builtinInfos().firstWhere((c) => c.id == device);
        final p = info.variants[to].param(knob);
        // A knob the new variant has under another range, or not at all, starts at its default.
        if (p != null) expect(t.value(knob), p.defaultValue, reason: '$knob resets');
        if (p == null) expect(t.use!.params.containsKey(knob), isFalse, reason: '$knob goes');
        expect(tester.takeException(), isNull);
        expect(s.undo(), isTrue);
        await tester.pumpAndSettle();
        expect(MergedDevices.variantOf(device, t.use!.params), 0);
        expect(t.value(knob), set);
        await close(tester);
      });
    }
  });

  group('the centrepiece drags the right knobs', () {
    Future<Rect> heroOf(WidgetTester tester, String key) async => tester.getRect(find.byKey(ValueKey(key)).first);

    testWidgets('Delay: the first tap sideways for the time (Time mode), up for the feedback', (tester) async {
      final s = await open(tester, 'org.caw.delay.pro');
      final t = target(s);
      await tester.tap(find.byKey(const ValueKey('sync-toggle-sync-time')));
      await tester.pumpAndSettle();
      expect(formatSync(t), 'Free');
      final time = t.value('time'), fb = t.value('feedback');
      final hero = await heroOf(tester, 'delay-hero');
      // The left lane's first tap: at its time on the 0..span axis, the left lane's height.
      final span = math.max(0.5, time / 1000 * 5.5);
      final x = hero.left + 14 + (hero.width - 22) * (time / 1000) / span;
      await tester.dragFrom(Offset(x, hero.top + hero.height * 0.48 - hero.height * 0.3 * 0.6), const Offset(30, -30));
      await tester.pumpAndSettle();
      expect(t.value('time'), greaterThan(time));
      expect(t.value('feedback'), greaterThan(fb));
      await tester.tap(find.byKey(const ValueKey('sync-toggle-sync-sync')));
      await tester.pumpAndSettle();
      expect(formatSync(t), isNot('Free'));
      await close(tester);
    });

    testWidgets('Reverb: sideways for the decay, up for the size', (tester) async {
      final s = await open(tester, 'org.caw.reverb.pro');
      final t = target(s);
      final decay = t.value('decay'), size = t.value('size');
      final hero = await heroOf(tester, 'reverb-hero');
      await tester.dragFrom(hero.center, const Offset(40, -30));
      await tester.pumpAndSettle();
      expect(t.value('decay'), greaterThan(decay));
      expect(t.value('size'), greaterThan(size));
      await close(tester);
    });

    for (final (id, x, y) in [
      ('org.caw.chorus', 'rate', 'depth'), ('org.caw.ensemble', 'spread', 'detune'), ('org.caw.doubler', 'width', 'detune'),
      ('org.caw.flanger', 'delay', 'feedback'), ('org.caw.vibrato', 'rate', 'depth'),
      ('org.caw.tremolo', 'rate', 'depth'), ('org.caw.autopan', 'rate', 'depth'),
    ]) {
      testWidgets('$id: the pad drags $x across and $y up', (tester) async {
        final s = await open(tester, id);
        final t = target(s);
        final x0 = t.value(x), y0 = t.value(y);
        final pad = await heroOf(tester, 'xy-$x-$y');
        await tester.dragFrom(pad.center - const Offset(20, -20), const Offset(-30, 30));
        await tester.pumpAndSettle();
        expect(t.value(x), lessThan(x0));
        expect(t.value(y), lessThan(y0));
        await close(tester);
      });
    }

    testWidgets('Rotary: a tap switches Slow and Fast', (tester) async {
      final s = await open(tester, 'org.caw.rotary');
      await tester.tap(find.byKey(const ValueKey('rotary-hero')));
      await tester.pumpAndSettle();
      expect(target(s).value('speed'), 1);
      await close(tester);
    });

    testWidgets('Phaser: sideways for the centre, up for the feedback', (tester) async {
      final s = await open(tester, 'org.caw.phaser');
      final t = target(s);
      final c = t.value('center'), fb = t.value('feedback');
      await tester.dragFrom((await heroOf(tester, 'phaser-hero')).center, const Offset(30, -20));
      await tester.pumpAndSettle();
      expect(t.value('center'), greaterThan(c));
      expect(t.value('feedback'), greaterThan(fb));
      await close(tester);
    });

    for (final (id, x, y) in [
      ('org.caw.utility', 'pan', 'width'), ('org.caw.stereo.width', null, 'width'), ('org.caw.stereo.balance', 'pan', null),
      ('org.caw.haas', 'delay', 'level'),
    ]) {
      testWidgets('$id: the goniometer drags ${x ?? '-'} across and ${y ?? '-'} up', (tester) async {
        final s = await open(tester, id);
        final t = target(s);
        final x0 = x == null ? 0.0 : t.value(x), y0 = y == null ? 0.0 : t.value(y);
        await tester.dragFrom((await heroOf(tester, 'utility-hero')).center, const Offset(40, -40));
        await tester.pumpAndSettle();
        if (x != null) expect(t.value(x), greaterThan(x0));
        if (y != null) expect(t.value(y), greaterThan(y0));
        await close(tester);
      });
    }

    testWidgets('Imager: a band dragged up widens it', (tester) async {
      final s = await open(tester, 'org.caw.imager');
      final hero = await heroOf(tester, 'imager-hero');
      await tester.dragFrom(Offset(hero.left + hero.width / 6, hero.center.dy), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(target(s).value('low_width'), greaterThan(1));
      await close(tester);
    });

    testWidgets('Pitch: sideways for whole semitones', (tester) async {
      final s = await open(tester, 'org.caw.pitchshift');
      await tester.dragFrom((await heroOf(tester, 'shift-pitch-hero')).center, const Offset(60, 0));
      await tester.pumpAndSettle();
      final st = target(s).value('semitones');
      expect(st, greaterThan(0));
      expect(st, st.roundToDouble());
      await close(tester);
    });

    testWidgets('Frequency: sideways for the shift in Hz, up for the feedback', (tester) async {
      final s = await open(tester, 'org.caw.freqshift');
      final t = target(s);
      final sh = t.value('shift');
      await tester.dragFrom((await heroOf(tester, 'freqshift-hero')).center, const Offset(30, -30));
      await tester.pumpAndSettle();
      expect(t.value('shift'), greaterThan(sh));
      expect(t.value('feedback'), greaterThan(0));
      await close(tester);
    });
  });

  group('no overflow', () {
    for (final id in [for (final v in _devices.values) ...v]) {
      testWidgets(id, (tester) async {
        for (final size in const [Size(360, 740), Size(412, 915), Size(844, 390), Size(1280, 800)]) {
          await open(tester, id, size: size);
          expect(tester.takeException(), isNull, reason: '$size');
          await openFold(tester);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$size, MORE open');
          await close(tester);
        }
      });
    }
  });

  group('screens for the owner', () {
    Future<void> shot(WidgetTester tester, String name) async {
      final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
      await tester.runAsync(() async {
        final img = await ro.toImage(pixelRatio: 2);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        Directory(_screens!).createSync(recursive: true);
        File('${_screens!}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    for (final MapEntry(key: device, value: olds) in _devices.entries) {
      for (final (i, id) in olds.indexed) {
        for (final (name, size) in [('phone', const Size(412, 915)), if (i == 0) ('wide', const Size(1280, 800))]) {
          testWidgets('$id $name', (tester) async {
            await loadAppFonts(tester);
            final s = await open(tester, id, size: size, ratio: 2);
            // A setting that shows the device working.
            final pose = switch (id) {
              'org.caw.pitchshift' => {'semitones': 7.0},
              'org.caw.stereo.balance' => {'pan': 0.3},
              'org.caw.stereo.width' => {'width': 1.5},
              'org.caw.reverb.pro' => {'predelay': 40.0},
              _ => const <String, double>{},
            };
            if (pose.isNotEmpty) DeviceTarget(s, 'a', 0).setAll(pose);
            await tester.pumpAndSettle();
            await openFold(tester);
            await tester.pumpAndSettle();
            await shot(tester, '${device.substring(8)}_${i}_${id.substring(8).replaceAll('.', '_')}_$name');
            await close(tester);
          });
        }
      }
    }
    for (final (name, size) in [('phone', const Size(412, 915)), ('wide', const Size(1280, 800))]) {
      testWidgets('inline in the FX stack $name', (tester) async {
        final s = stateWith('org.caw.delay.pro', make: PreviewState.new);
        states.add(s);
        for (final id in ['org.caw.chorus', 'org.caw.utility', 'org.caw.pitchshift']) {
          addBuiltinEffect(s, s.project.layers.first, id);
        }
        Motion.setting = MotionLevel.off;
        display.frame.value = fakeFrame('org.caw.delay.pro', values: _live('org.caw.delay.pro'));
        await pumpGolden(tester, Scaffold(body: SafeArea(child: ListenableBuilder(listenable: s,
            builder: (_, _) => FxStack(state: s, layer: s.project.layers.first)))), size * 2);
        tester.view.devicePixelRatio = 2;
        await tester.pumpAndSettle();
        await shot(tester, 'inline_fx_stack_$name');
        final list = tester.state<ScrollableState>(find.descendant(
            of: find.byKey(const ValueKey('fx-stack-list')), matching: find.byType(Scrollable), matchRoot: true).first).position;
        list.jumpTo(list.maxScrollExtent / 2);
        await tester.pumpAndSettle();
        await shot(tester, 'inline_fx_stack_mid_$name');
        await close(tester);
      });
    }
  }, skip: _screens == null);
}

String formatSync(DeviceTarget t) => t.param('sync')!.choices[t.value('sync').round()];

/// Opens the page's MORE fold when it has one.
Future<void> openFold(WidgetTester tester) async {
  final fold = find.byKey(const ValueKey('device-fold'));
  if (fold.evaluate().isEmpty) return;
  await tester.ensureVisible(fold.first);
  await tester.pumpAndSettle();
  await tester.tap(fold.first);
}
