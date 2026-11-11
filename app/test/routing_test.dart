// Routing (#175): sends and keys in the project and the engine JSON (loops left out), "New reverb bus" in one tap,
// a device's key, the routing view and Send to…, the ducker's UI, and (with CAW_LIB) the engine taking it all.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/routing_edit.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/devices/effects/ducker_editor.dart';
import 'package:caw/ui/routing_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Routing', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'kick', name: 'Kick', color: 0),
      LayerDoc(id: 'bass', name: 'Bass', color: 1, parentId: 'grp'),
      LayerDoc(id: 'grp', name: 'Group', color: 2, isFolder: true),
      LayerDoc(id: 'verb', name: 'Verb', color: 3, isFolder: true),
    ]);

Map<String, dynamic> _layerJson(ProjectDoc p, String id) =>
    ((jsonDecode(p.toEngineJson()) as Map)['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['id'] == id);

void main() {
  test('sends and keys round-trip through the project file', () {
    final p = _project();
    p.layers[0].sends.add(SendDoc('verb', level: 0.25, pre: true));
    p.layers[1].components.add(ComponentUseDoc('org.caw.ducker')..key = ComponentKeyDoc('kick', pre: false));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.layers[0].sends.single.to, 'verb');
    expect(back.layers[0].sends.single.level, 0.25);
    expect(back.layers[0].sends.single.pre, isTrue);
    expect(back.layers[1].components.single.key!.layer, 'kick');
    expect(back.layers[1].components.single.key!.pre, isFalse);
  });

  test('the engine gets only routes that make no loop, and a bus folder its effects', () {
    final p = _project();
    p.layers[3].components.add(ComponentUseDoc('org.caw.reverb.pro'));
    p.layers[0].sends.add(SendDoc('verb'));
    p.layers[2].sends.add(SendDoc('verb')); // grp → verb: fine (first in track order)
    p.layers[3].sends.add(SendDoc('grp'));  // verb → grp → verb: a loop, left out
    // A ducker on the bass keyed by its own folder would hear itself; keyed by the kick it plays.
    p.layers[1].components.add(ComponentUseDoc('org.caw.ducker')..key = ComponentKeyDoc('grp'));
    p.layers[1].components.add(ComponentUseDoc('org.caw.compressor')..key = ComponentKeyDoc('kick'));
    expect(_layerJson(p, 'kick')['sends'], [{'to': 'verb', 'level': 0.5}]);
    expect(_layerJson(p, 'grp')['sends'], [{'to': 'verb', 'level': 0.5}]);
    expect(_layerJson(p, 'verb')['sends'], isNull);
    expect(_layerJson(p, 'verb')['components'], isNotEmpty);
    final comps = (_layerJson(p, 'bass')['components'] as List);
    expect(comps[0], 'org.caw.ducker');
    expect((comps[1] as Map)['key'], {'layer': 'kick', 'tap': 'pre'});
    final plan = RoutingPlan.of(p);
    expect(plan.sendPlays(p.layers[3], 0), isFalse);
    expect(plan.canSend(p.layers[3], 'grp'), isFalse);
    expect(plan.canKey(p.layers[1], 'grp'), isFalse);
    expect(plan.canKey(p.layers[1], 'kick'), isTrue);
    // A folder without a bus carries nothing: a send to it is left out, and its effects too.
    p.layers[3].busEnabled = false;
    expect(_layerJson(p, 'kick')['sends'], isNull);
    expect(_layerJson(p, 'verb')['components'], isNull);
  });

  test('New reverb bus makes the bus, its reverb and the send in one undo step', () {
    final s = AppState(settings: Settings());
    s.project = _project();
    final kick = s.project.layers[0];
    final bus = s.newFxBus(FxBusKind.reverb, from: kick);
    expect(bus.isFolder && bus.busEnabled, isTrue);
    expect(bus.name, 'Reverb bus');
    expect(bus.components.single.id, 'org.caw.reverb.pro');
    expect(bus.components.single.params['mix'], 1.0);
    expect(kick.sends.single.to, bus.id);
    expect(s.newFxBus(FxBusKind.reverb).name, 'Reverb bus 2');
    expect(s.sendTargets(kick).map((b) => b.name), containsAll(['Group', 'Verb', 'Reverb bus 2']));
    expect(s.sendTargets(kick).map((b) => b.id), isNot(contains(bus.id)));  // already sent there
  });

  test('a key on a compressor turns its sidechain to External; a ducker on Tempo follows the key', () {
    final s = AppState(settings: Settings());
    s.project = _project();
    final bass = s.project.layers[1];
    bass.components.addAll([ComponentUseDoc('org.caw.compressor'), ComponentUseDoc('org.caw.ducker')]);
    expect(s.hasSidechain('org.caw.compressor'), isTrue);
    expect(s.hasSidechain('org.caw.eq'), isFalse);
    expect(s.setComponentKey(bass, 0, 'kick'), isTrue);
    expect(bass.components[0].params['sidechain'], 1);
    expect(s.setComponentKey(bass, 1, 'kick'), isTrue);
    expect(bass.components[1].params['mode'], 0);
    expect(s.setComponentKey(bass, 1, 'grp'), isFalse);  // its own folder: a loop
    expect(s.keySources(bass).map((l) => l.id), isNot(contains('grp')));
    s.setComponentKey(bass, 0, null);
    expect(bass.components[0].key, isNull);
    expect(bass.components[0].params['sidechain'], 0);
  });

  test('the ducker\'s curve follows its attack, hold and release', () {
    expect(duckAt(0, 10, 20, 100, 0), closeTo(0.0, 0.11));
    expect(duckAt(15, 10, 20, 100, 0), 1);
    expect(duckAt(80, 10, 20, 100, 0), closeTo(0.5, 1e-9));
    expect(duckAt(200, 10, 20, 100, 0), 0);
    // A positive curve holds the duck low longer (the pump).
    expect(duckAt(80, 10, 20, 100, 0.6), greaterThan(0.5));
  });

  testWidgets('the routing view shows outputs and sends; + Send makes a reverb bus', (tester) async {
    final s = AppState(settings: Settings());
    s.project = _project();
    s.project.layers[0].sends.add(SendDoc('verb'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RoutingView(state: s))));
    expect(find.byKey(const ValueKey('route-out-kick')), findsOneWidget);
    expect(find.text('Master'), findsWidgets);
    expect(find.byKey(const ValueKey('route-send-kick-0')), findsOneWidget);
    expect(find.textContaining('Hears: Kick (send)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('route-add-bass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New reverb bus'));
    await tester.pumpAndSettle();
    expect(s.project.layers.last.name, 'Reverb bus');
    expect(s.project.layers[1].sends.single.to, s.project.layers.last.id);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group('the ducker', () {
    late FakeDisplay display;
    setUp(() {
      display = FakeDisplay();
      DeviceDisplaySource.current = display;
    });
    tearDown(() => DeviceDisplaySource.current = DeviceDisplaySource.engine);

    Future<AppState> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 915) * 2.625;
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final s = stateWith('org.caw.ducker');
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: Center(
        child: TextButton(onPressed: () => openDevice(context, s, 'org.caw.ducker'), child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      display.frame.value = fakeFrame('org.caw.ducker', values: {'pos_ms': 30, 'duck': 0.9, 'gr': 8, 'mode': 2, 'phase': 0.1});
      await tester.pump();
      return s;
    }

    testWidgets('its hero drags the depth and its shapes and trigger tiles set the values', (tester) async {
      final s = await open(tester);
      final t = targetOf(s, 'org.caw.ducker');
      expect(find.byKey(const ValueKey('duck-hero')), findsOneWidget);
      expect(find.byKey(const ValueKey('sidechain-key-0')), findsOneWidget);
      final hero = tester.getRect(find.byKey(const ValueKey('duck-hero')));
      final before = t.value('depth');
      await tester.dragFrom(Offset(hero.center.dx, hero.bottom - 30), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(t.value('depth'), lessThan(before));
      await tester.tap(find.byKey(const ValueKey('duck-shape-Gate')));
      await tester.pumpAndSettle();
      expect(t.value('hold'), 120);
      await tester.tap(find.byKey(const ValueKey('mode-mode-1')));
      await tester.pumpAndSettle();
      expect(t.value('mode'), 1);
      expect(find.text('KEY · NOTES'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  test('the engine takes sends, a bus with effects and a keyed ducker', () async {
    final p = _project();
    p.layers[0].setInstrument('org.caw.synth.flagship');
    p.layers[1].setInstrument('org.caw.synth.flagship');
    p.layers[3].components.add(ComponentUseDoc('org.caw.reverb.pro', {'mix': 1.0}));
    p.layers[0].sends.add(SendDoc('verb', pre: true));
    p.layers[1].components.add(ComponentUseDoc('org.caw.ducker', {'mode': 0})..key = ComponentKeyDoc('kick'));
    final e = Engine.create();
    await e.setProject(p.toEngineJson());
    expect(e.lastProjectWarnings.where((w) => w.contains('key') || w.contains('send')), isEmpty);
    expect(e.setSend('kick', 0, 0.3, pre: false, mute: false), isTrue);
    expect(e.setSend('kick', 1, 0.3, pre: false, mute: false), isFalse);
    e.dispose();
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
