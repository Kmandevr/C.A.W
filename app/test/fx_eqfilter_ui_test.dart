// The merged EQ's and Filter's pages (1.0.8): mode cards and the model strip switch the variant in one undo step, each hero's drag edits the right knob, no overflow at four sizes; owner screens with CAW_EQ_SCREENS=<dir>.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/devices/visuals/filter_curve.dart' show freqToX;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// Each mode as the old id its variant was: the EQ's Bands, Graphic, DJ, Tilt; the Filter's Multimode, Ladder,
/// Nonlinear.
const eqModes = ['org.caw.eq', 'org.caw.geq', 'org.caw.eq.dj', 'org.caw.tilt'];
const filterModes = ['org.caw.filter', 'org.caw.ladder', 'org.caw.nlfilter'];

/// A frame like a playing EQ's or filter's: the fixture's, with the input spectrum, the graphic EQ's curve, the
/// DJ bands' levels and the filter's response.
DeviceDisplayFrame liveFrame(String id, {int tick = 0}) {
  final base = fakeFrame(id, tick: tick);
  return DeviceDisplayFrame(inputDb: base.inputDb, outputDb: base.outputDb,
    spectrum: id == 'org.caw.geq' ? [for (var i = 0; i < 64; i++) base.spectrum![i * 2]] : base.spectrum,
    values: {
      ...base.values,
      'pre_bins': 128,
      for (var i = 0; i < 128; i++) 'pre$i': (0.82 - i / 128 * 0.4 + 0.05 * math.sin(i * 0.45)).clamp(0.0, 1.0),
      for (var j = 0; j < 64; j++) 'c$j': 4 * math.cos(j / 63 * math.pi * 2) + 2,
      'low_db': -12, 'mid_db': -18, 'high_db': -26,
    });
}

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

  Future<AppState> open(WidgetTester tester, String id, {Size size = const Size(412, 915), bool live = true,
      Map<String, double> values = const {}}) async {
    final s = stateWith(id, make: PreviewState.new);
    states.add(s);
    final t = targetOf(s, id);
    if (values.isNotEmpty) t.setAll(values);
    s.starting = false;  // as after a project opens: edits are undo steps
    s.history.reset(jsonEncode(s.project.toJson()));
    display.frame.value = live ? liveFrame(id) : null;
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

  test('each mode opens the merged page, which picks the variant itself (no Variant pill)', () {
    for (final id in [...eqModes, ...filterModes]) {
      final info = builtinInfo(id);
      final entry = DeviceEditors.custom(info.id, info);
      expect(entry?.ownsVariant, isTrue, reason: id);
    }
  });

  group('mode cards: one undo step, the knobs the modes don\'t share reset', () {
    testWidgets('EQ: Bands to DJ and back', (tester) async {
      final s = await open(tester, 'org.caw.eq', values: {'b3_gain': 5, 'output': 3});
      final t = targetOf(s, 'org.caw.eq');
      expect(find.byKey(const ValueKey('variant-bar-0-0')), findsNothing, reason: 'the cards replace the pill');
      await tester.tap(find.byKey(const ValueKey('variant-card-2')));
      await tester.pumpAndSettle();
      expect(t.info!.variantIndex, 2);
      expect(find.byKey(const ValueKey('eq3-hero')), findsOneWidget);
      final params = s.project.layers.first.components.single.params;
      expect(params.containsKey('b3_gain'), isFalse);
      expect(params.containsKey('output'), isFalse, reason: 'Bands\' output (±24) is not DJ\'s (−24..+12)');
      expect(s.undo(), isTrue);
      await tester.pumpAndSettle();
      expect(t.info!.variantIndex, 0);
      expect((t.value('b3_gain'), t.value('output')), (5, 3));
      expect(find.byKey(const ValueKey('eq-view')), findsOneWidget);
      await close(tester);
    });

    testWidgets('Filter: a model in another variant sets the variant and its type at once', (tester) async {
      final s = await open(tester, 'org.caw.filter', values: {'type': 1, 'lfo_amount': 0.4});
      final t = targetOf(s, 'org.caw.filter');
      await tester.tap(find.byKey(const ValueKey('filter-model-0-4')));
      await tester.pumpAndSettle();
      expect((t.info!.variantIndex, t.value('type')), (0, 4), reason: 'a model of the same variant is its type');
      s.history.reset(jsonEncode(s.project.toJson()));
      await tester.ensureVisible(find.byKey(const ValueKey('filter-model-1-2')));
      await tester.tap(find.byKey(const ValueKey('filter-model-1-2')));
      await tester.pumpAndSettle();
      expect((t.info!.variantIndex, t.value('mode')), (1, 2));
      expect(s.project.layers.first.components.single.params.containsKey('lfo_amount'), isFalse);
      expect(find.byKey(const ValueKey('ladder-hero')), findsOneWidget);
      expect(s.undo(), isTrue);
      await tester.pumpAndSettle();
      expect((t.info!.variantIndex, t.value('type'), t.value('lfo_amount')), (0, 4, 0.4));
      await close(tester);
    });
  });

  group('the centrepiece drags the right knobs', () {
    testWidgets('Bands: a tap on open space adds a bell there, a drag moves it', (tester) async {
      final s = await open(tester, 'org.caw.eq');
      final t = targetOf(s, 'org.caw.eq');
      final view = tester.getRect(find.byKey(const ValueKey('eq-view')));
      final range = 24.0;
      Offset at(double hz, double db) =>
          Offset(view.left + freqToX(hz, view.width), view.center.dy - db / range * (view.height / 2 - 18));
      expect(t.value('b1_on'), 0);
      await tester.tapAt(at(400, 9));
      await tester.pumpAndSettle();
      expect(t.value('b1_on'), 1);
      expect(t.value('b1_type'), 0, reason: 'a bell');
      expect(t.value('b1_freq'), closeTo(400, 40));
      expect(t.value('b1_gain'), closeTo(9, 1.5));
      await tester.dragFrom(at(t.value('b1_freq'), t.value('b1_gain')), const Offset(30, 30));
      await tester.pumpAndSettle();
      expect(t.value('b1_freq'), greaterThan(450));
      expect(t.value('b1_gain'), lessThan(8));
      await close(tester);
    });

    for (final (id, key, x, y) in [
      ('org.caw.filter', 'filter-hero', 'cutoff', 'resonance'),
      ('org.caw.ladder', 'ladder-hero', 'cutoff', 'resonance'),
      ('org.caw.nlfilter', 'nlfilter-hero', 'cutoff', 'q'),
      ('org.caw.tilt', 'tilt-hero', 'freq', 'tilt'),
    ]) {
      testWidgets('$id: right raises $x, up raises $y', (tester) async {
        final s = await open(tester, id);
        final t = targetOf(s, id);
        final x0 = t.value(x), y0 = t.value(y);
        await tester.dragFrom(tester.getCenter(find.byKey(ValueKey(key))), const Offset(60, -50));
        await tester.pumpAndSettle();
        expect(t.value(x), greaterThan(x0), reason: x);
        expect(t.value(y), greaterThan(y0), reason: y);
        await close(tester);
      });
    }

    testWidgets('Graphic: a swipe draws the bars; DJ: a band drags its gain', (tester) async {
      var s = await open(tester, 'org.caw.geq');
      var t = targetOf(s, 'org.caw.geq');
      final hero = tester.getRect(find.byKey(const ValueKey('geq-hero')));
      await tester.dragFrom(hero.topLeft + Offset(hero.width * 10 / 30, hero.height * 0.25), Offset(hero.width * 4 / 30, 0));
      await tester.pumpAndSettle();
      for (var b = 11; b <= 15; b++) {
        expect(t.value('g$b'), greaterThan(2), reason: 'g$b');
      }
      await close(tester);
      s = await open(tester, 'org.caw.eq.dj');
      t = targetOf(s, 'org.caw.eq.dj');
      final dj = tester.getRect(find.byKey(const ValueKey('eq3-hero')));
      await restDrag(tester, dj.topLeft + Offset(freqToX(60, dj.width), dj.height / 2), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(t.value('low'), greaterThan(0));
      await close(tester);
    });
  });

  group('no overflow', () {
    for (final id in [...eqModes, ...filterModes]) {
      for (final size in const [Size(360, 740), Size(412, 915), Size(844, 390), Size(1280, 800)]) {
        testWidgets('$id at ${size.width.round()} × ${size.height.round()}', (tester) async {
          await open(tester, id, size: size);
          expect(tester.takeException(), isNull);
          await close(tester);
        });
      }
    }
  });

  group('inline in the FX stack', () {
    for (final id in [...eqModes, ...filterModes]) {
      for (final size in const [Size(412, 915), Size(844, 390)]) {
        testWidgets('$id at ${size.width.round()} × ${size.height.round()}', (tester) async {
          final s = stateWith(id);
          states.add(s);
          display.frame.value = liveFrame(id);
          await pumpGolden(tester, Scaffold(body: ListenableBuilder(listenable: s,
              builder: (_, _) => FxStack(state: s, layer: s.project.layers.first))), size);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('variant-card-0')), findsNothing, reason: 'compact: no cards');
          expect(find.byKey(const ValueKey('filter-models')), findsNothing);
          expect(tester.takeException(), isNull);
          await close(tester);
        });
      }
    }
  });

  // Screens for the owner (not goldens): each mode at phone and wide size, at 2x, with live-looking data.
  final dir = Platform.environment['CAW_EQ_SCREENS'];
  const looks = <String, Map<String, double>>{
    'org.caw.eq': {'b1_on': 1, 'b1_freq': 40, 'b3_gain': 4.5, 'b3_freq': 220, 'b4_gain': -5, 'b4_q': 2.2, 'b5_gain': 3,
      'b6_gain': -2.5, 'b7_gain': 3.5},
    'org.caw.geq': {'g1': 4, 'g3': 6, 'g5': 5, 'g8': 2, 'g12': -3, 'g15': -4, 'g18': -2, 'g22': 2, 'g25': 4, 'g28': 6, 'g30': 5,
      'g2': 5, 'g4': 6, 'g6': 4, 'g7': 3, 'g26': 5, 'g27': 6, 'g29': 6, 'g31': 4, 'g13': -4, 'g14': -4, 'g16': -3},
    'org.caw.eq.dj': {'low': 4, 'mid': -6, 'high': 2, 'kill_high': 0},
    'org.caw.tilt': {'tilt': 5, 'freq': 900},
    'org.caw.filter': {'type': 1, 'cutoff': 900, 'resonance': 0.55, 'lfo_amount': 0.3, 'env_amount': 0.25},
    'org.caw.ladder': {'cutoff': 700, 'resonance': 0.75, 'drive': 9},
    'org.caw.nlfilter': {'cutoff': 1200, 'q': 6, 'shape': 1, 'drive': 18},
  };
  for (final id in [...eqModes, ...filterModes]) {
    for (final MapEntry(key: name, value: size) in const {'phone': Size(412, 915), 'wide': Size(1280, 800)}.entries) {
      testWidgets('screen: $id $name', (tester) async {
        MotionClock.hold = true;
        addTearDown(() => MotionClock.hold = false);
        await loadAppFonts(tester);
        await open(tester, id, size: size, values: looks[id] ?? const {});
        for (var i = 20; i >= 0; i--) {
          display.frame.value = liveFrame(id, tick: i);
          await tester.pump();
        }
        await tester.pumpAndSettle();
        final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
        await tester.runAsync(() async {
          final img = await ro.toImage(pixelRatio: 2);
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          Directory(dir!).createSync(recursive: true);
          File('$dir/${id.substring(8)}_$name.png').writeAsBytesSync(data!.buffer.asUint8List());
        });
        await close(tester);
      }, skip: dir == null);
    }
  }
}
