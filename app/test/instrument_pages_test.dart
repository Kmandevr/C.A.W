// The 1.1.3 instruments' pages (Starling, Nightingale, Curlew, Bittern, Woodpecker): each opens from its device, switches variant, its knobs and picture take drags, Bittern's drawknobs and room, no overflow on phone and landscape, phone goldens, and the descriptor fixture against the engine.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/devices/device_controls.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/instruments/instrument_editors.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart' show FakeDisplay;
import 'golden_util.dart';

const _fixture = 'test/fixtures/instruments_113.json';

List<NativeComponentInfo> instrumentInfos() => NativeComponentInfo.listFromJson(
    jsonDecode(File(_fixture).readAsStringSync()) as Map<String, dynamic>);

/// A display frame: 3 of 16 voices sounding, the last key C4 at velocity 0.9, the model's own floats [own].
DeviceDisplayFrame frame({int variant = 0, List<double> own = const [0, 0.5, 0.5, 0, 0, 0, 0]}) {
  final f = Float32List(16);
  f.setAll(0, [1, variant.toDouble(), 3, 16, -12, 0, 60, 0.9, 5]);
  f.setAll(9, own);
  return DeviceDisplayFrame(raw: f.toList());
}

/// Each page's knob on its first panel that a test turns, and what its picture's drag moves (and which way).
const _knob = {'starling': 'hammer', 'nightingale': 'pressure', 'curlew': 'breath', 'woodpecker': 'hardness'};

void main() {
  late AppState s;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  final states = <AppState>[];
  setUp(() {
    Motion.setting = MotionLevel.off;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
  });
  tearDown(() => DeviceDisplaySource.current = source);
  tearDownAll(() {
    for (final x in states) {
      x.dispose();
    }
  });

  AppState stateFor(String id) {
    final st = AppState(settings: Settings())..starting = false;
    st.project = ProjectDoc(id: 'p', name: 'Instruments', bpm: 120, layers: [LayerDoc(id: 'a', name: 'Keys', color: 3)]);
    st.componentCatalog.set(instrumentInfos());
    st.setNativeInstrument(st.project.layers.first, id);
    states.add(st);
    return st;
  }

  DeviceTarget target() => DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
  Map<String, double> params() => s.project.layers.first.instrument!.params;

  Future<void> open(WidgetTester tester, String id, {Size size = const Size(390, 844)}) async {
    s = stateFor(id);
    await pumpGolden(tester, Scaffold(body: DeviceEditor(target: target(), onClose: () {})), size);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  /// Swipes the phone's panels one to the left, from under their content (a sideways drag on a knob turns it).
  Future<void> nextPanel(WidgetTester tester, String k) async {
    final r = tester.getRect(find.byKey(ValueKey('$k-pages')));
    await tester.dragFrom(Offset(r.center.dx, r.bottom - 8), const Offset(-400, 0));
    await tester.pumpAndSettle();
  }

  /// A finger resting on [at], then moving by [by] in small steps (a deliberate drag, not a swipe).
  Future<void> slowDrag(WidgetTester tester, Offset at, Offset by) async {
    final g = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(by / 10);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  test('every page is registered: its own section, the cards own the variant, the strip at the bottom', () {
    for (final spec in instrumentSpecs) {
      final info = instrumentInfos().firstWhere((c) => c.id == spec.id);
      final e = DeviceEditors.custom(spec.id, info);
      expect(e, isNotNull, reason: spec.id);
      expect(e!.ownsVariant, isTrue);
      final sections = e.sections(DeviceTarget(AppState(settings: Settings()), 'a', DeviceTarget.instrumentSlot));
      expect(sections.single.stripAtBottom, isTrue);
      expect(spec.panels.length, 3);
    }
  });

  for (final spec in instrumentSpecs) {
    final k = spec.key;
    group(spec.id, () {
      testWidgets('opens from the device: the picture on top, three named panels swiped under it', (tester) async {
        await open(tester, spec.id);
        expect(find.byKey(ValueKey('$k-page')), findsOneWidget);
        expect(find.byKey(ValueKey('$k-visual')), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(ValueKey('$k-panel-name'))).data, spec.panels[0].name.toUpperCase());
        for (var i = 1; i < 3; i++) {
          await nextPanel(tester, k);
          expect(tester.widget<Text>(find.byKey(ValueKey('$k-panel-name'))).data, spec.panels[i].name.toUpperCase());
        }
        expect(find.byKey(const ValueKey('dknob-voices')), findsOneWidget, reason: 'the space panel last');
        expect(tester.takeException(), isNull);
        await close(tester);
      });

      testWidgets('switches variant from its cards', (tester) async {
        await open(tester, spec.id);
        final info = instrumentInfos().firstWhere((c) => c.id == spec.id);
        if (info.variants.length < 2) {
          // Starling has one model for now (its guitar and harp come later), Bittern none: no cards.
          expect(find.byKey(const ValueKey('variant-card-0')), findsNothing);
          await close(tester);
          return;
        }
        for (var v = info.variants.length - 1; v >= 0; v--) {
          await tester.tap(find.descendant(of: find.byKey(ValueKey('$k-centrepiece')), matching: find.byKey(ValueKey('variant-card-$v'))));
          await tester.pumpAndSettle();
          expect(target().info!.variantIndex, v);
          expect(params()['variant'] ?? 0, v);
          expect(find.byKey(ValueKey('$k-picture-$v')), findsOneWidget);
          expect(find.byKey(ValueKey('$k-controls-$v')), findsOneWidget, reason: 'the variant\'s own knobs');
          expect(tester.takeException(), isNull);
        }
        await close(tester);
      });

      testWidgets('a knob turns with a sideways drag', (tester) async {
        await open(tester, spec.id);
        var id = _knob[k];
        if (id == null) {
          // Bittern's first panel is its drawknobs: turn the Wind panel's tremulant.
          await nextPanel(tester, k);
          id = 'tremulant';
        }
        final before = target().value(id);
        final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey('dknob-$id'))));
        for (var i = 0; i < 8; i++) {
          await g.moveBy(const Offset(8, 0));
          await tester.pump(const Duration(milliseconds: 8));
        }
        await g.up();
        await tester.pumpAndSettle();
        expect(target().value(id), greaterThan(before), reason: '$id turned up');
        await close(tester);
      });

      testWidgets('every knob and choice on every panel and variant moves its engine param', (tester) async {
        await open(tester, spec.id, size: const Size(390, 1400));
        final info = instrumentInfos().firstWhere((c) => c.id == spec.id);
        final variants = info.variants.length < 2 ? 1 : info.variants.length;
        final checked = <String>{};
        for (var v = 0; v < variants; v++) {
          if (variants > 1) {
            await tester.tap(find.descendant(of: find.byKey(ValueKey('$k-centrepiece')), matching: find.byKey(ValueKey('variant-card-$v'))));
            await tester.pumpAndSettle();
          }
          for (var panel = 0; panel < 3; panel++) {
            final shown = find.descendant(of: find.byKey(ValueKey('$k-panel-$panel')), matching: find.byType(DeviceKnob));
            final ids = [for (final w in tester.widgetList<DeviceKnob>(shown)) w.paramId];
            for (final id in ids) {
              final p = target().param(id)!;
              final before = target().value(id);
              // Up from below the middle, down from above it.
              final dir = before < (p.min + p.max) / 2 ? 1.0 : -1.0;
              final g = await tester.startGesture(tester.getCenter(find.byKey(ValueKey('dknob-$id'))));
              for (var i = 0; i < 10; i++) {
                await g.moveBy(Offset(10 * dir, 0));
                await tester.pump(const Duration(milliseconds: 8));
              }
              await g.up();
              await tester.pumpAndSettle();
              expect(target().value(id), isNot(before), reason: '$k variant $v: $id');
              checked.add(id);
            }
            final choices = find.descendant(of: find.byKey(ValueKey('$k-panel-$panel')), matching: find.byType(DeviceChoice));
            for (final w in tester.widgetList<DeviceChoice>(choices).toList()) {
              final id = w.paramId;
              final p = target().param(id)!;
              final next = (target().value(id) - p.min).round() == 0 ? 1 : 0;
              await tester.tap(find.byKey(ValueKey('dchoice-$id-$next')));
              await tester.pumpAndSettle();
              expect(target().value(id), p.min + next, reason: '$k variant $v: $id');
              checked.add(id);
            }
            if (panel < 2) await nextPanel(tester, k);
          }
          // Back to the first panel for the next variant.
          for (var i = 0; i < 2; i++) {
            final r = tester.getRect(find.byKey(ValueKey('$k-pages')));
            await tester.dragFrom(Offset(r.center.dx, r.bottom - 8), const Offset(400, 0));
            await tester.pumpAndSettle();
          }
        }
        // Every parameter but the variant and Bittern's stops (their drawknobs, tested below) has a control.
        final stops = {'bourdon16', 'principal8', 'rohrflute8', 'gamba8', 'celeste8', 'octave4', 'flute4', 'nazard', 'fifteenth2',
          'tierce', 'mixture', 'trumpet8', 'subbass32'};
        final all = {for (final vi in info.variants.isEmpty ? [info] : info.variants) for (final p in vi.parameters) p.id}
          ..remove('variant')..removeAll(stops);
        // Phantom partials show only at High quality (the tier choice was flipped off Setting above, to Eco).
        all.remove('phantom');
        expect(checked, containsAll(all), reason: '$k: a parameter without a control');
        expect(tester.takeException(), isNull);
        await close(tester);
      });

      testWidgets('lays out without overflow on a small phone and in landscape', (tester) async {
        for (final size in const [Size(360, 740), Size(844, 390), Size(1280, 800)]) {
          await open(tester, spec.id, size: size);
          display.frame.value = frame();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$size');
          await close(tester);
        }
      });

      testWidgets('golden: phone', (tester) async {
        await open(tester, spec.id);
        display.frame.value = frame();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/devices/${k}_page_phone.png'));
        await close(tester);
      });
    });
  }

  testWidgets('the pictures take drags: the bow sideways and pressed, the breath, the hammer and mallet, a rank', (tester) async {
    Future<Rect> picture(String k) async => tester.getRect(find.byKey(ValueKey('$k-visual')));

    await open(tester, 'org.caw.nightingale');
    var r = await picture('nightingale');
    var pos = target().value('position'), press = target().value('pressure');
    await slowDrag(tester, r.center, const Offset(-60, -30));
    expect(target().value('position'), greaterThan(pos), reason: 'left is further from the bridge');
    expect(target().value('pressure'), greaterThan(press), reason: 'up presses harder');
    await close(tester);

    for (final (id, k, param) in const [('org.caw.curlew', 'curlew', 'breath'), ('org.caw.starling', 'starling', 'hammer'),
        ('org.caw.woodpecker', 'woodpecker', 'hardness')]) {
      await open(tester, id);
      r = await picture(k);
      final before = target().value(param);
      await slowDrag(tester, r.center, const Offset(0, -30));
      expect(target().value(param), greaterThan(before), reason: '$k: up raises $param');
      await close(tester);
    }

    await open(tester, 'org.caw.bittern');
    r = await picture('bittern');
    // The Gamba's rank (the fourth of thirteen across the façade) pulled up from nothing.
    expect(target().value('gamba8'), 0);
    final x = r.left + r.width * (0.03 + 0.77 * 3.5 / 13);
    await slowDrag(tester, Offset(x, r.center.dy), const Offset(0, -40));
    expect(target().value('gamba8'), greaterThan(0));
    expect(target().value('principal8'), 1, reason: 'its neighbours stay');
    await close(tester);
  });

  testWidgets('Bittern: a drawknob draws and pushes in its stop, a drag sets its level; the room picks Cathedral, Loft or Dry',
      (tester) async {
    await open(tester, 'org.caw.bittern');
    expect(find.byKey(const ValueKey('bittern-stop-trumpet8')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bittern-stop-trumpet8')));
    await tester.pumpAndSettle();
    expect(target().value('trumpet8'), 1, reason: 'drawn: full, as its default is none');
    await tester.tap(find.byKey(const ValueKey('bittern-stop-principal8')));
    await tester.pumpAndSettle();
    expect(target().value('principal8'), 0, reason: 'pushed in');
    await tester.tap(find.byKey(const ValueKey('bittern-stop-principal8')));
    await tester.pumpAndSettle();
    expect(target().value('principal8'), 1, reason: 'drawn again at its default');
    final before = target().value('octave4');
    await slowDrag(tester, tester.getCenter(find.byKey(const ValueKey('bittern-stop-octave4'))), const Offset(0, 30));
    expect(target().value('octave4'), lessThan(before), reason: 'down lowers its level');
    // The room: on by default (Cathedral), the Loft and Dry presets' values.
    for (var i = 0; i < 2; i++) {
      await nextPanel(tester, 'bittern');
    }
    expect(target().value('space'), closeTo(0.45, 1e-6));
    await tester.tap(find.byKey(const ValueKey('bittern-room-1')));
    await tester.pumpAndSettle();
    expect(target().value('space'), closeTo(0.15, 1e-6));
    await tester.tap(find.byKey(const ValueKey('bittern-room-2')));
    await tester.pumpAndSettle();
    expect(target().value('space'), 0);
    await close(tester);
  });

  testWidgets('Starling: Phantom partials show at High quality only, and turn', (tester) async {
    await open(tester, 'org.caw.starling', size: const Size(390, 1400));
    s.settings.soundQuality = SoundQuality.normal;
    target().set('tier', 0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dknob-phantom')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dchoice-tier-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dknob-phantom')), findsOneWidget);
    final before = target().value('phantom');
    await tester.drag(find.byKey(const ValueKey('dknob-phantom')), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(target().value('phantom'), greaterThan(before));
    await close(tester);
  });

  testWidgets('the readouts follow the display: voices against the cap, the last key', (tester) async {
    await open(tester, 'org.caw.curlew');
    expect(tester.widget<Text>(find.byKey(const ValueKey('curlew-voices'))).data, '8 voices');
    display.frame.value = frame();
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('curlew-voices'))).data, '3 / 16 voices');
    expect(tester.widget<Text>(find.byKey(const ValueKey('curlew-last-key'))).data, 'C4');
    await close(tester);
  });

  test('the instruments\' descriptor fixture matches the engine', () async {
    final e = Engine.create();
    final engine = {for (final c in await e.nativeComponents()) c.id: c};
    e.dispose();
    List<Object> shape(NativeComponentInfo i) => [
      for (final v in i.variants.isEmpty ? [i] : i.variants)
        [for (final p in v.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))],
    ];
    for (final have in instrumentInfos()) {
      expect(shape(have), shape(engine[have.id]!), reason: 'refresh $_fixture (${have.id})');
    }
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
