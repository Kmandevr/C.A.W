// Timber's editor (org.caw.timber): the model cards (a model change as one undo step that keeps the shared knobs and their lanes), each model's picture and own knobs, the drags on the picture (a drawbar, the strike point), the live readouts from the display data, the phone's three panels and the wide screen, and goldens at phone and desktop size.
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
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/flagship/flagship_tools.dart' show FlagshipKeys;
import 'package:caw/ui/devices/timber/timber_editor.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart' show FakeDisplay;
import 'golden_util.dart';

NativeComponentInfo timberInfo() => NativeComponentInfo.listFromJson(
    jsonDecode(File('test/fixtures/timber_component.json').readAsStringSync()) as Map<String, dynamic>).single;

AppState timberState() {
  final s = AppState(settings: Settings())..starting = false;  // as after a project opens: edits are undo steps
  s.project = ProjectDoc(id: 'p', name: 'Timber', bpm: 120, layers: [LayerDoc(id: 'a', name: 'Keys', color: 3)]);
  s.componentCatalog.set([timberInfo()]);
  s.setNativeInstrument(s.project.layers.first, timberComponentId);
  return s;
}

/// A Timber display frame: [model], [sounding] of [cap] voices, the last key and velocity, the model's own floats.
DeviceDisplayFrame timberFrame({int model = 0, int sounding = 3, int cap = 32, double peakDb = -12, int key = 60,
    double velocity = 0.9, int notes = 5, List<double> own = const [0, 4000, 6, 3, 0, 0, 0]}) {
  final f = Float32List(16);
  f.setAll(0, [1, model.toDouble(), sounding.toDouble(), cap.toDouble(), peakDb, 0, key.toDouble(), velocity, notes.toDouble()]);
  f.setAll(9, own);
  return DeviceDisplayFrame(raw: f.toList());
}

void main() {
  late AppState s;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  final states = <AppState>[];
  setUp(() {
    s = timberState();
    states.add(s);
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

  LayerDoc layer() => s.project.layers.first;
  DeviceTarget target() => DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
  Map<String, double> params() => layer().instrument!.params;

  Future<void> open(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    await pumpGolden(tester, Scaffold(body: DeviceEditor(target: target(), onClose: () {})), size);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> pickModel(WidgetTester tester, int k) async {
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('timber-centrepiece')), matching: find.byKey(ValueKey('variant-card-$k'))));
    await tester.pumpAndSettle();
  }

  test('the registry opens Timber\'s own page, which picks the model itself', () {
    final e = DeviceEditors.custom(timberComponentId, timberInfo());
    expect(e, isNotNull);
    expect(e!.ownsVariant, isTrue);
    expect(e.sections(target()).single.stripAtBottom, isTrue, reason: 'the mod-source strip pinned at the bottom');
    expect(timberInfo().variants.length, timberModels.length);
    // Every model's own controls exist in its descriptor.
    for (final m in timberControls.entries) {
      final v = timberInfo().variants[m.key];
      for (final id in [...m.value.choices, ...m.value.knobs]) {
        expect(v.param(id), isNotNull, reason: '${v.name} model ${m.key} lacks $id');
      }
    }
  });

  testWidgets('phone: the cards and the picture on top, three panels swiped under them', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('timber-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('timber-visual')), findsOneWidget);
    for (var k = 0; k < 7; k++) {
      expect(find.byKey(ValueKey('variant-card-$k')), findsOneWidget);
    }
    expect(find.text('MODEL'), findsWidgets);
    expect(find.byKey(const ValueKey('dknob-hammer')), findsOneWidget, reason: 'the piano\'s own knobs on the Model panel');
    expect(find.byKey(const ValueKey('timber-quality')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flagship-dot-1')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('timber-panel-name'))).data, 'SOUND');
    expect(find.byKey(const ValueKey('dknob-release')), findsOneWidget);
    expect(find.byKey(const ValueKey('dknob-decay')), findsOneWidget, reason: 'the piano\'s decay on the envelope');
    expect(find.byKey(const ValueKey('dknob-attack')), findsNothing, reason: 'the piano has no attack');
    await tester.drag(find.byKey(const ValueKey('timber-pages')), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('timber-panel-name'))).data, 'SPACE');
    expect(find.byKey(const ValueKey('dknob-space')), findsOneWidget);
    expect(find.byKey(const ValueKey('dknob-voices')), findsOneWidget);
    // The keys strip shows and hides.
    await tester.tap(find.byKey(const ValueKey('timber-keys-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FlagshipKeys), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timber-keys-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(FlagshipKeys), findsNothing);
    await close(tester);
  });

  testWidgets('a model card changes the model in one undo step: shared knobs and their lanes stay, its own reset',
      (tester) async {
    target().set('tone', 0.4);
    target().set('hammer', 0.9);
    s.editProject((p) => p.automation.addAll([
      ProjectAutomationLaneDoc(targetType: 'instrument', target: 'tone', layerId: 'a'),
      ProjectAutomationLaneDoc(targetType: 'instrument', target: 'hammer', layerId: 'a'),
    ]));
    await open(tester);
    await pickModel(tester, TimberModel.organ);
    expect(params()['variant'], 2);
    expect(params()['tone'], 0.4, reason: 'a shared knob keeps its value');
    expect(params().containsKey('hammer'), isFalse, reason: 'the piano\'s knob goes');
    expect(s.project.automation.map((l) => l.target), ['tone'], reason: 'the piano\'s lane goes, the shared one stays');
    expect(target().info!.variantIndex, 2);
    expect(find.byKey(const ValueKey('dknob-hammer')), findsNothing);
    expect(find.byKey(const ValueKey('dknob-click')), findsOneWidget, reason: 'the organ\'s own knobs');
    expect(find.byKey(const ValueKey('dchoice-rotary-1')), findsOneWidget);
    expect(s.undo(), isTrue);
    await tester.pumpAndSettle();
    expect(params()['variant'] ?? 0, 0);
    expect(params()['hammer'], 0.9);
    expect(s.project.automation.length, 2);
    // A knob can't move the model (only the cards do).
    target().set('variant', 4);
    expect(params()['variant'] ?? 0, 0);
    await close(tester);
  });

  testWidgets('every model draws and shows its own controls', (tester) async {
    await open(tester, size: const Size(1280, 800));
    const own = {
      TimberModel.piano: 'dknob-resonance', TimberModel.epiano: 'dknob-pickup', TimberModel.organ: 'dknob-drive',
      TimberModel.plucked: 'dknob-brightness', TimberModel.bowed: 'dknob-pressure', TimberModel.mallets: 'dknob-hardness',
      TimberModel.winds: 'dknob-growl',
    };
    for (final e in own.entries) {
      await pickModel(tester, e.key);
      display.frame.value = timberFrame(model: e.key);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(ValueKey(e.value)), findsOneWidget, reason: 'model ${e.key}');
      expect(find.byKey(ValueKey('timber-controls-${e.key}')), findsOneWidget);
    }
    // The winds' third knob is named for the instrument: lips on brass.
    target().set('instrument', 3);
    await tester.pumpAndSettle();
    expect(find.text('Lips'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the picture takes drags: a drawbar pulled, the pluck point moved', (tester) async {
    await open(tester, size: const Size(1280, 800));
    await pickModel(tester, TimberModel.organ);
    expect(target().value('db4'), 0);
    final r = tester.getRect(find.byKey(const ValueKey('timber-grab')));
    // The 4' bar (the fourth of nine over the left 62 %), pulled down.
    final x = r.left + r.width * (0.06 + 0.62 * 3.5 / 9);
    await tester.dragFrom(Offset(x, r.top + r.height * 0.3), Offset(0, r.height * 0.5));
    await tester.pumpAndSettle();
    expect(target().value('db4'), greaterThanOrEqualTo(4));
    expect(target().value('db8'), 8, reason: 'its neighbour stays');
    await pickModel(tester, TimberModel.plucked);
    final before = target().value('position');
    await tester.dragFrom(r.center, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(target().value('position'), greaterThan(before), reason: 'left is further from the bridge');
    await close(tester);
  });

  testWidgets('the readouts follow the display: voices against the cap, the last key', (tester) async {
    await open(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('timber-voices'))).data, '32 voices');
    display.frame.value = timberFrame(sounding: 3, cap: 16, key: 60);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('timber-voices'))).data, '3 / 16 voices');
    expect(tester.widget<Text>(find.byKey(const ValueKey('timber-last-key'))).data, 'C4');
    await close(tester);
  });

  testWidgets('wide: one screen with the model\'s knobs under the picture and envelope, tone and space below',
      (tester) async {
    await open(tester, size: const Size(1280, 800));
    expect(find.byKey(const ValueKey('timber-wide')), findsOneWidget);
    expect(find.byKey(const ValueKey('timber-pages')), findsNothing);
    for (final k in ['timber-envelope', 'timber-tone', 'timber-space']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
    expect(find.descendant(of: find.byKey(const ValueKey('timber-centrepiece')), matching: find.byKey(const ValueKey('dknob-hammer'))),
        findsOneWidget);
    await close(tester);
  });

  group('goldens', () {
    for (final e in {'phone': const Size(390, 844), 'desktop': const Size(1280, 800)}.entries) {
      testWidgets(e.key, (tester) async {
        await open(tester, size: e.value);
        display.frame.value = timberFrame();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(goldenScreen, matchesGoldenFile('goldens/audio/timber_page_${e.key}.png'));
        await close(tester);
      });
    }
  });

  test('the Timber descriptor fixture matches the engine', () async {
    final e = Engine.create();
    final engine = {for (final c in await e.nativeComponents()) c.id: c};
    e.dispose();
    final want = engine[timberComponentId]!, have = timberInfo();
    List<Object> shape(NativeComponentInfo i) => [
      for (final v in i.variants) [for (final p in v.parameters) (p.id, p.min, p.max, p.defaultValue, p.choices.join('|'))],
    ];
    expect(shape(have), shape(want), reason: 'refresh test/fixtures/timber_component.json');
    expect(have.variants.fold<int>(0, (n, v) => n + v.presets.length), want.variants.fold<int>(0, (n, v) => n + v.presets.length));
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
