import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/engine/engine.dart';
import '../lib/model/app_state.dart';
import '../lib/model/project.dart';
import '../lib/model/settings.dart';
import '../lib/ui/automation_screen.dart';
import '../lib/ui/engine_lab_screen.dart';
import '../lib/ui/mixer_screen.dart';

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
}
