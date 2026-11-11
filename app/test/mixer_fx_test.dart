// The mixer's FX (gap 9): the master strip's effect slots open the master chain's devices, and effects dragged from
// one strip to another are copied (or moved, with Alt or Shift, or the toast's Move), their lanes going with a move.
import 'package:caw/engine/component_info.dart';
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/mixer_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/frame/sections.dart' show AssetDrag, AssetKind;
import 'package:caw/ui/mixer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const width = NativeComponentInfo(id: 'org.caw.stereo.width', name: 'Width', role: 'effect', builtin: true,
    parameters: [ComponentParameterInfo(id: 'width', name: 'Width', defaultValue: 1, min: 0, max: 2)]);
const synth = NativeComponentInfo(id: 'org.caw.synth.basic', name: 'Basic synth', role: 'instrument', builtin: true);

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Mix', modules: [
      ModuleDoc(id: 'echo', name: 'Echo', source: '---\nkind: effect\n---\n', params: {'mix': 0.3}),
    ], layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0, effectIds: ['echo'],
          components: [ComponentUseDoc('org.caw.stereo.width', {'width': 1.5})]),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
      LayerDoc(id: 'f', name: 'Group', color: 2, isFolder: true, busEnabled: false),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.componentCatalog.set(const [width, synth]);
    s.nativeCatalog = const [width, synth];
  });
  tearDown(() => s.dispose());

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  group('the master chain as a track', () {
    test('its stand-in edits the project\'s master components', () {
      final master = masterLayerOf(s.project);
      expect(identical(masterLayerOf(s.project), master), isTrue);
      expect(s.addNativeEffect(master, 'org.caw.stereo.width'), isNotNull);
      expect(s.project.masterComponents.single.id, 'org.caw.stereo.width');
      expect(s.project.layers.any(isMasterLayer), isFalse);
      final t = DeviceTarget(s, masterLayerId, 0);
      t.set('width', 0.5);
      expect(s.project.masterComponents.single.params['width'], 0.5);
      t.setBypass(true);
      expect(s.project.masterComponents.single.bypass, isTrue);
      expect(s.project.toJson().toString(), contains('master_components'));
    });

    test('the master takes C++ effects only', () {
      final master = masterLayerOf(s.project);
      expect(s.dropAsset(master, const AssetDrag(AssetKind.cawModule, 'echo', 'Echo')), isFalse);
      expect(s.dropAsset(master, const AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Synth', instrument: true)), isFalse);
      expect(s.dropAsset(master, const AssetDrag(AssetKind.nativeEffect, 'org.caw.stereo.width', 'Width')), isTrue);
      expect(s.project.masterComponents.length, 1);
    });

    test('an undo gives a fresh stand-in on the restored chain', () {
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      s.addNativeEffect(masterLayerOf(s.project), 'org.caw.stereo.width');
      s.endUndoStep();
      expect(s.undo(), isTrue);
      expect(masterLayerOf(s.project).components, isEmpty);
      expect(DeviceTarget(s, masterLayerId, 0).use, isNull);
    });
  });

  group('FX between strips', () {
    test('a C++ effect copies with its values, the source keeps it', () {
      expect(s.dropFx(const FxSlotDrag('a', 'native', 0), layer('b')), isTrue);
      expect(layer('a').components.length, 1);
      final copy = layer('b').components.single;
      expect(copy.params['width'], 1.5);
      expect(identical(copy, layer('a').components.single), isFalse);
    });

    test('a move takes the effect and its lanes', () {
      s.project.automation.add(ProjectAutomationLaneDoc(targetType: 'component', target: 'width', layerId: 'a', component: 0));
      expect(s.dropFx(const FxSlotDrag('a', 'native', 0), masterLayerOf(s.project), move: true), isTrue);
      expect(layer('a').components, isEmpty);
      expect(s.project.masterComponents.single.params['width'], 1.5);
      final lane = s.project.automation.single;
      expect(lane.layerId, isNull);
      expect(lane.component, 0);
    });

    test('a .caw effect copy gets its own module; the master and a plain folder refuse it', () {
      const drag = FxSlotDrag('a', 'caw', 0);
      expect(s.canDropFx(drag, masterLayerOf(s.project)), isFalse);
      expect(s.canDropFx(drag, layer('f')), isFalse);
      expect(s.canDropFx(drag, layer('a')), isFalse);
      expect(s.dropFx(drag, layer('b')), isTrue);
      final id = layer('b').effectIds.single;
      expect(id, isNot('echo'));
      expect(s.project.module(id)!.params['mix'], 0.3);
      expect(layer('a').effectIds, ['echo']);
    });
  });

  group('on screen', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
          builder: (context, _) => MixerScreen(state: s, onOpenBuilder: () {})))));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5)); // the toast, autosave and history timers run out
      await tester.pumpAndSettle();
    }

    testWidgets('the master strip shows its FX slots and adds FX', (tester) async {
      await pump(tester);
      expect(find.text('No master FX'), findsOneWidget);
      s.addNativeEffect(masterLayerOf(s.project), 'org.caw.stereo.width');
      await tester.pump();
      expect(find.byKey(const ValueKey('master-fx-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('master-fx-add')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('master-fx-chain')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('master-fx-stack')), findsOneWidget);
      expect(find.text('MASTER EFFECTS'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('a slot long-pressed and dragged onto the master strip copies it there', (tester) async {
      await pump(tester);
      final slot = find.descendant(of: find.byType(FxSlot), matching: find.text('Width'));
      expect(slot, findsOneWidget);
      final g = await tester.startGesture(tester.getCenter(slot));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveTo(tester.getCenter(find.byKey(const ValueKey('fader-master'))));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(s.project.masterComponents.single.params['width'], 1.5);
      expect(layer('a').components.length, 1);
      expect(find.text('Copied Width to Master'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800)); // the toast slides in
      // The toast's Move turns the copy into a move.
      await tester.tap(find.text('Move'));
      await tester.pump();
      expect(layer('a').components, isEmpty);
      expect(s.project.masterComponents.length, 1);
      await settle(tester);
    });

    testWidgets('Alt held while dropping moves the effect', (tester) async {
      await pump(tester);
      final slot = find.descendant(of: find.byType(FxSlot), matching: find.text('Width'));
      final g = await tester.startGesture(tester.getCenter(slot));
      await tester.pump(const Duration(milliseconds: 600));
      await g.moveTo(tester.getCenter(find.byKey(const ValueKey('fader-b'))));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await g.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(layer('a').components, isEmpty);
      expect(layer('b').components.single.id, 'org.caw.stereo.width');
      await settle(tester);
    });
  });
}
