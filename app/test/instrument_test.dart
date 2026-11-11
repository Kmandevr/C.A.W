// C++ instruments in the app: the layer model and its engine JSON, the blank template, the track menu and the FX card.
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/frame/sections.dart';
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';

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

const _saw = NativeComponentInfo(id: 'org.caw.synth.saw', name: 'Saw', role: 'instrument', builtin: true,
    ports: _instrumentPorts);

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Instruments', layers: [
      LayerDoc(id: 'a', name: 'Lead', color: 0, instrument: ComponentUseDoc('org.caw.synth.saw'),
          components: [ComponentUseDoc('org.caw.stereo.width')]),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
    ]);

void main() {
  group('model', () {
    test('an instrument replaces another and round-trips through the project file', () {
      final layer = _project().layers.first;
      layer.instrument!.params['cutoff'] = 300;
      layer.setInstrument('org.caw.synth.basic');
      expect(layer.instrument!.params, isEmpty, reason: 'another instrument starts from its defaults');
      expect(layer.components.single.id, 'org.caw.stereo.width', reason: 'the effects stay');
      layer.instrument!.params['cutoff'] = 900;
      layer.setInstrument('org.caw.synth.basic');
      expect(layer.instrument!.params['cutoff'], 900, reason: 'the same instrument keeps its values');
      final back = LayerDoc.fromJson(jsonDecode(jsonEncode(layer.toJson())) as Map<String, dynamic>);
      expect(back.instrument?.id, 'org.caw.synth.basic');
      expect(back.instrument?.params['cutoff'], 900);
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
      expect(layer.containsKey('chain'), isFalse);
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

    testWidgets('the track menu has one Instrument… entry: the browser lists the instruments, not effects',
        (tester) async {
      s.componentCatalog.set(const [_saw, _synth, _width]);
      s.nativeCatalog = const [_saw, _synth, _width];
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: SectionScope(controller: sections,
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => ArrangerScreen(state: s))))));
      await tester.pump();
      // A double tap opens the track menu (owner, 2026-11-11).
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      expect(find.text('Instrument · Saw…'), findsOneWidget);
      expect(find.textContaining('Instrument · Basic synth'), findsNothing, reason: 'no long list any more');
      await tester.tap(find.text('Instrument · Saw…'));
      await tester.pumpAndSettle();
      expect(find.text('INSTRUMENTS'), findsOneWidget);
      expect(find.text('Saw'), findsOneWidget);
      expect(find.text('Width'), findsNothing, reason: 'an effect is not an instrument');
      await tester.tap(find.text('Basic synth'));
      await tester.pumpAndSettle();
      // The track had the Saw: replacing it asks first.
      expect(find.text('Replace the instrument?'), findsOneWidget);
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      final layer = s.project.layers.first;
      expect(layer.instrument?.id, 'org.caw.synth.basic');
      // Back to the Saw, and Cancel keeps what it has.
      // A double tap opens the track menu (owner, 2026-11-11).
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(const ValueKey('track-header-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Instrument · Basic synth…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saw'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(layer.instrument?.id, 'org.caw.synth.basic');
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

  group('First loop', () {
    test('is made of built-in C++ instruments playing patterns, with no .caw sounds', () {
      final p = AppState().starterProject();
      expect(p.name, 'First loop');
      expect([for (final l in p.layers) l.name], ['Kick', 'Hats', 'Bass', 'Lead', 'Acid', 'Pad']);
      for (final l in p.layers) {
        expect(l.instrument?.id, startsWith('org.caw.'), reason: l.name);
        expect(l.clips.single.lengthSteps, p.loopSteps, reason: l.name);
        expect(l.components.every((c) => c.id.startsWith('org.caw.')), isTrue, reason: l.name);
      }
      for (final m in p.modules) {
        expect(m.source, contains('kind: pattern'), reason: m.name);
      }
      expect([for (final l in p.layers) if (l.mute) l.name], ['Acid', 'Pad']);
    });

    final lib = Platform.environment['CAW_LIB'];
    test('the engine plays it, and lists its instruments with readable names', () async {
      final s = AppState();
      final p = s.starterProject();
      final e = Engine.create();
      final result = await e.setProject(p.toEngineJson());
      for (final m in p.modules) {
        expect(result[m.id]?.ok, isTrue, reason: m.name);
      }
      final infos = await e.nativeComponents();
      final names = {for (final c in infos) if (c.isInstrument) c.id: c.name};
      expect(names, containsPair('org.caw.drums', 'Drums'));
      expect(names, containsPair('org.caw.synth.flagship', 'Flagship'));
      // One synth (2026-11-10): the bass, acid, morph and basic synths are Flagship presets now; one drum instrument
      // (2026-11-11): the kick, snare, hats and kit are org.caw.drums.
      for (final id in ComponentUseDoc.retiredInstruments) {
        expect(names.containsKey(id), isFalse, reason: id);
      }
      final flagship = infos.firstWhere((c) => c.id == 'org.caw.synth.flagship');
      expect(flagship.presets.map((p) => p.name), containsAll(['Init', 'Morph pad', 'Mono bass', 'Acid 303', 'Basic']));
      expect(flagship.presets.firstWhere((p) => p.name == 'Mono bass').params['voice_mode'], 2);
      // The starter's tracks name their presets; resolved, they hold the values the First loop's old synths had.
      final drums = infos.firstWhere((c) => c.id == 'org.caw.drums');
      expect(drums.presets.map((p) => p.name), containsAll(['Kit: 808', 'Kit: 909', '808 Kick', 'Crash']));
      // An old drum migrates: Single mode, its values on pad A1, no preset.
      final kick = Engine.resolveInstrument({'id': 'org.caw.drum.kick', 'params': {'tune': 60}})!;
      expect(kick['migrated'], isTrue);
      expect(kick['id'], 'org.caw.drums');
      expect(kick['preset'], isNull);
      expect((kick['params'] as Map)['a1_body_freq'], 60);
      final resolved = s.starterProject()..resolveInstruments(Engine.resolveInstrument);
      final old = {
        'Bass': {'id': 'org.caw.bass', 'params': {'cutoff': 270, 'resonance': 0.45, 'env': 0.6, 'decay': 0.18, 'sustain': 0.2}},
        'Lead': {'id': 'org.caw.synth.morph', 'params': {'shape': 0.66, 'drift': 0.15, 'unison': 3, 'detune': 0.1,
          'cutoff': 2600, 'attack': 0.005, 'decay': 0.25, 'sustain': 0.5, 'release': 0.3}},
        'Acid': {'id': 'org.caw.synth.acid', 'params': {'resonance': 0.8}},
        'Pad': {'id': 'org.caw.synth.morph', 'params': <String, double>{}},
      };
      for (final MapEntry(key: name, value: entry) in old.entries) {
        final layer = resolved.layers.firstWhere((l) => l.name == name);
        final migrated = Engine.resolveInstrument(entry)!;
        expect(layer.instrument!.id, 'org.caw.synth.flagship', reason: name);
        expect(layer.instrument!.preset, migrated['preset'], reason: name);
        expect(layer.instrument!.params, {
          for (final e in (migrated['params'] as Map).entries) e.key as String: (e.value as num).toDouble(),
        }, reason: name);
      }
      e.play();
      e.pullForTest(48000 * 2);
      for (var i = 0; i < p.layers.length; i++) {
        final peak = e.layerMeter(i).peak;
        if (p.layers[i].mute) continue;
        expect(peak, greaterThan(0.01), reason: p.layers[i].name);
      }
      e.dispose();
    }, skip: lib == null || lib.isEmpty);
  });
}
