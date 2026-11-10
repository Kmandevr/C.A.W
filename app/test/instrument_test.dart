// C++ instruments in the app: the layer model and its engine JSON, the blank template, the track menu and the FX card.
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _instrumentPorts = [
  ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
  ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
];
const _synth = NativeComponentInfo(id: 'org.caw.synth.basic', name: 'Basic synth', role: 'instrument', builtin: true,
    ports: _instrumentPorts,
    parameters: [ComponentParameterInfo(id: 'cutoff', name: 'Cutoff', defaultValue: 2400, min: 40, max: 18000)]);
const _width = NativeComponentInfo(id: 'org.caw.stereo.width', name: 'Width', role: 'utility', builtin: true, ports: [
  ComponentPortInfo(id: 'in', type: 'audio', input: true, layout: 'stereo', channels: 2),
  ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
]);

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Instruments', modules: [
      ModuleDoc(id: 'gen', name: 'Saw', source: 'saw(freq)'),
      ModuleDoc(id: 'fx', name: 'Fold', source: '---\nkind: effect\n---\nin'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Lead', color: 0, generatorId: 'gen', effectIds: ['fx']),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
    ]);

void main() {
  group('model', () {
    test('an instrument replaces the generator and round-trips through the project file', () {
      final layer = _project().layers.first;
      expect(layer.chain, ['gen', 'fx']);
      layer.setInstrument('org.caw.synth.basic');
      expect(layer.generatorId, isNull);
      expect(layer.chain, ['fx'], reason: 'with a C++ instrument only the .caw effects run');
      layer.instrument!.params['cutoff'] = 900;
      layer.setInstrument('org.caw.synth.basic');
      expect(layer.instrument!.params['cutoff'], 900, reason: 'the same instrument keeps its values');
      final back = LayerDoc.fromJson(jsonDecode(jsonEncode(layer.toJson())) as Map<String, dynamic>);
      expect(back.instrument?.id, 'org.caw.synth.basic');
      expect(back.instrument?.params['cutoff'], 900);
      expect(back.generatorId, isNull);
      layer.setInstrument(null);
      expect(layer.toJson().containsKey('instrument'), isFalse);
    });

    test('the engine gets a playable instrument and its lanes; one not loaded yet is left out', () {
      final p = _project();
      p.layers.first.setInstrument('local.lead.cpp1');
      p.automation.add(ProjectAutomationLaneDoc(targetType: 'instrument', target: 'cutoff', layerId: 'a',
          points: [AutomationPointDoc(step: 0, value: 500)]));
      Map<String, dynamic> engine(Set<String>? playable) =>
          jsonDecode(p.toEngineJson(playableComponents: playable)) as Map<String, dynamic>;
      final played = engine({'local.lead.cpp1'});
      final layer = (played['layers'] as List).first as Map<String, dynamic>;
      expect(layer['instrument'], 'local.lead.cpp1');
      expect(layer['chain'], ['fx']);
      expect((played['automation'] as List).single['target_type'], 'instrument');
      final waiting = engine(<String>{});
      expect(((waiting['layers'] as List).first as Map<String, dynamic>).containsKey('instrument'), isFalse);
      expect(waiting['automation'], isEmpty);
      expect(((engine(null)['layers'] as List).first as Map)['instrument'], 'local.lead.cpp1');
    });

    test('saved state reaches the instrument by its engine index', () {
      final p = _project();
      p.layers.first.setInstrument('org.caw.synth.basic');
      p.storeComponentStates((layerId) => layerId == 'a' ? {ProjectDoc.instrumentIndex: (state: 'AAEC', version: 3)} : {});
      expect(p.layers.first.instrument!.state, 'AAEC');
      expect(p.layers.first.instrument!.stateVersion, 3);
    });

    test('the blank instrument template is an instrument with its manifest', () {
      final doc = CppComponentDoc.blankInstrument(id: 'cpp1', name: 'My lead');
      expect(doc.componentId, 'local.my-lead.cpp1');
      expect(doc.files.keys, containsAll(['caw-component.json', 'src/instrument.cpp']));
      final source = doc.files['src/instrument.cpp']!;
      expect(source, contains('caw::InstrumentProcessor'));
      expect(source, contains('caw::ModuleRole::Instrument'));
      expect(source, contains('PortType::Event'));
      expect(source, contains('class Mylead final'));
      expect(jsonDecode(doc.files['caw-component.json']!)['sources'], ['src/instrument.cpp']);
    });

    test('descriptors tell an instrument from an effect by its ports', () {
      expect(_synth.isInstrument, isTrue);
      expect(_width.isInstrument, isFalse);
    });
  });

  group('ui', () {
    late AppState s;
    late SectionController sections;
    setUp(() {
      s = AppState(settings: Settings());
      s.project = _project();
      sections = SectionController();
    });
    tearDown(() {
      s.dispose();
      sections.dispose();
    });

    testWidgets('the track menu lists C++ instruments next to .caw ones; choosing one makes it the instrument',
        (tester) async {
      s.componentCatalog.set(const [_synth, _width]);
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
      await tester.longPress(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      expect(find.text('Instrument · Saw'), findsOneWidget);
      expect(find.text('Instrument · Basic synth'), findsOneWidget);
      expect(find.text('Instrument · Width'), findsNothing, reason: 'an effect is not an instrument');
      await tester.tap(find.text('Instrument · Basic synth'));
      await tester.pumpAndSettle();
      final layer = s.project.layers.first;
      expect(layer.instrument?.id, 'org.caw.synth.basic');
      expect(layer.generatorId, isNull);
      // Back to the .caw generator: the C++ instrument goes.
      await tester.longPress(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Instrument · Saw'));
      await tester.pumpAndSettle();
      expect(layer.instrument, isNull);
      expect(layer.generatorId, 'gen');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the FX tab shows the instrument card with its knobs, bypass and remove', (tester) async {
      s.componentCatalog.set(const [_synth]);
      final layer = s.project.layers.first;
      s.setNativeInstrument(layer, 'org.caw.synth.basic');
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 800,
          child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: layer))))));
      await tester.pump();
      expect(find.text('INSTRUMENT · C++'), findsOneWidget);
      expect(find.byKey(const ValueKey('fx-instrument-title')), findsOneWidget);
      final knob = find.byKey(const ValueKey('knob-org.caw.synth.basic-cutoff'));
      expect(knob, findsOneWidget);
      await tester.drag(knob, const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(layer.instrument!.params['cutoff'], greaterThan(2400));
      await tester.tap(find.byKey(const ValueKey('fx-instrument-bypass')));
      await tester.pumpAndSettle();
      expect(layer.instrument!.bypass, isTrue);
      await tester.tap(find.byTooltip('Remove Basic synth'));
      await tester.pumpAndSettle();
      expect(layer.instrument, isNull);
      expect(find.text('INSTRUMENT · C++'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
    });

    test('dropping an instrument on a track makes it the instrument, not an insert', () {
      s.componentCatalog.set(const [_synth]);
      final layer = s.project.layers[1];
      expect(s.dropAsset(layer, const AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Basic synth')), isTrue);
      expect(layer.instrument?.id, 'org.caw.synth.basic');
      expect(layer.components, isEmpty);
    });
  });
}
