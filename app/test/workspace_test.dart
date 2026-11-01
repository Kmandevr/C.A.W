import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/automation_screen.dart';
import 'package:caw/ui/engine_lab_screen.dart';
import 'package:caw/ui/exporter_screen.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/mixer_screen.dart';
import 'package:caw/ui/plugin_builder_screen.dart';

void main() {
  late AppState state;

  setUp(() {
    state = AppState(settings: Settings());
  });

  tearDown(() {
    state.dispose();
  });

  testWidgets('Mixer channel controls update the shared project model', (tester) async {
    final module = ModuleDoc(id: 'gen-1', name: 'Bass synth', source: '');
    final layer = LayerDoc(id: 'layer-1', name: 'Bass', color: 0, generatorId: module.id, volume: 0.5);
    state.project = ProjectDoc(id: 'project-1', name: 'Workspace test', modules: [module], layers: [layer]);
    state.selectedModuleId = module.id;
    state.info[module.id] = const ModuleInfo(ok: true, kind: 'generator');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MixerScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('MIXER / EDITOR'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.length, greaterThanOrEqualTo(3));
    sliders[1].onChanged!(0.72);
    await tester.pump();
    expect(layer.volume, closeTo(0.72, 0.0001));
  });

  testWidgets('Automation point edits update the same serialized lane model', (tester) async {
    final lane = AutomationLaneDoc(target: 'volume', points: [
      AutomationPointDoc(step: 0, value: 0.2),
      AutomationPointDoc(step: 64, value: 0.8),
    ]);
    final layer = LayerDoc(id: 'layer-1', name: 'Lead', color: 0, automation: [lane]);
    state.project = ProjectDoc(id: 'project-1', name: 'Automation test', layers: [layer]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: state,
          builder: (context, _) => AutomationScreen(state: state),
        ),
      ),
    ));

    expect(find.text('AUTOMATION'), findsOneWidget);
    expect(find.text('VOLUME'), findsOneWidget);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.length, 4);
    sliders[1].onChanged!(0.55);
    await tester.pump();
    expect(lane.points.first.value, closeTo(0.55, 0.0001));
  });

  testWidgets('Engine Lab reports compiled modules and track signal paths', (tester) async {
    final module = ModuleDoc(id: 'gen-1', name: 'Noise core', source: '');
    final layer = LayerDoc(id: 'layer-1', name: 'Noise', color: 0, generatorId: module.id);
    state.project = ProjectDoc(id: 'project-1', name: 'Engine Lab test', modules: [module], layers: [layer]);
    state.info[module.id] = const ModuleInfo(ok: true, kind: 'generator', summary: 'Noise generator');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: EngineLabScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('ENGINE LAB'), findsOneWidget);
    expect(find.text('TRACK SIGNAL PATHS'), findsOneWidget);
    expect(find.text('COMPILED MODULES'), findsOneWidget);
    expect(find.text('Noise core'), findsNWidgets(2));
    expect(find.text('Noise generator'), findsOneWidget);
  });
  testWidgets('File Manager exposes portable project and module actions', (tester) async {
    state.project = ProjectDoc(id: 'project-1', name: 'Portable project', modules: [
      ModuleDoc(id: 'gen-1', name: 'Bass', source: '---\\nkind: generator\\n---\\nsin(110)'),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileManagerScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('FILES / LIBRARY'), findsOneWidget);
    expect(find.text('Portable project'), findsOneWidget);
    expect(find.text('Export .cawproj'), findsOneWidget);
    expect(find.text('Import project'), findsOneWidget);
    expect(find.text('Import .caw module'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
  });



  testWidgets('Exporter switches between quick loop and advanced MIDI options', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExporterScreen(state: state)),
    ));

    expect(find.text('Quick Export'), findsWidgets);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('MIDI'), findsOneWidget);
    await tester.tap(find.text('MIDI'));
    await tester.pumpAndSettle();
    expect(find.text('Export MIDI'), findsOneWidget);
  });

  testWidgets('Plugin Builder exposes the native module workflow and honest target boundary', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PluginBuilderScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('PLUGIN BUILDER'), findsOneWidget);
    expect(find.text('Guided'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Build boundary: native .caw module validation and source packaging are available. CLAP/VST3 binary builds, plugin sandboxing, host I/O tests and per-plugin CPU/memory profiling require a native plugin SDK/host backend that is not present in this repository. No unavailable binary target is advertised.'), findsOneWidget);
  });

  test('imported projects receive a new identity and preserve project content', () async {
    state.starting = false;
    final imported = ProjectDoc(id: 'external-id', name: 'Imported session', bpm: 128);
    await state.importProject(imported);

    expect(state.project.id, isNot('external-id'));
    expect(state.project.name, 'Imported session');
    expect(state.project.bpm, 128);
  });

  test('imported module source becomes a new project module', () {
    final id = state.importModuleSource(
      '---\\nkind: generator\\nname: Imported bass\\n---\\nsin(110)',
      fileName: 'Bass.caw',
    );

    expect(state.project.module(id)?.name, 'Imported bass');
    expect(state.project.module(id)?.source, contains('sin(110)'));
  });

}
