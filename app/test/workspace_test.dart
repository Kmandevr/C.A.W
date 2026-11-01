import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:caw/actions/actions.dart';
import 'package:caw/actions/key_event.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/automation_screen.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/engine_lab_screen.dart';
import 'package:caw/ui/exporter_screen.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/mixer_screen.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/ui/plugin_builder_screen.dart';
import 'package:caw/ui/widgets.dart';

void main() {
  late AppState state;

  setUp(() {
    state = AppState(settings: Settings());
  });

  tearDown(() {
    state.dispose();
  });


  testWidgets('workspace shortcuts and focus traversal work through the action router', (tester) async {
    final routerKey = GlobalKey<KeyRouterState>();
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var selectedView = -1;

    await tester.pumpWidget(MaterialApp(
      home: KeyRouter(
        key: routerKey,
        state: state,
        screenArea: Area.global,
        onView: (index) => selectedView = index,
        child: Column(children: [
          TextButton(focusNode: first, onPressed: () {}, child: const Text('First')),
          TextButton(focusNode: second, onPressed: () {}, child: const Text('Second')),
        ]),
      ),
    ));

    first.requestFocus();
    routerKey.currentState!.vim.run(const ActionRef.action('focus.next'));
    await tester.pump();
    expect(second.hasFocus, isTrue);
    routerKey.currentState!.vim.run(const ActionRef.action('focus.prev'));
    await tester.pump();
    expect(first.hasFocus, isTrue);

    routerKey.currentState!.vim.run(const ActionRef.action('view.mixer'));
    expect(selectedView, 2);
  });

  testWidgets('peak meters hold briefly and then decay on meter ticks', (tester) async {
    var peak = 0.0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PeakMeter(state: state, read: () => peak, color: Colors.green)),
    ));

    peak = 0.8;
    state.tick.value++;
    await tester.pump();
    expect(tester.widget<Bar>(find.byType(Bar)).value, closeTo(0.8, 0.0001));

    peak = 0;
    for (var i = 0; i < 12; i++) {
      state.tick.value++;
      await tester.pump();
    }
    expect(tester.widget<Bar>(find.byType(Bar)).value, closeTo(0.8, 0.0001));

    state.tick.value++;
    await tester.pump();
    expect(tester.widget<Bar>(find.byType(Bar)).value, closeTo(0.736, 0.0001));
  });

  test('master gain updates shared state without a full app notification', () {
    state.project = ProjectDoc(id: 'project-1', name: 'Master test', master: 0.7);
    var valueTicks = 0;
    var appNotifications = 0;
    state.values.addListener(() => valueTicks++);
    state.addListener(() => appNotifications++);

    state.setMaster(0.42);

    expect(state.project.master, closeTo(0.42, 0.0001));
    expect(valueTicks, 1);
    expect(appNotifications, 0);
  });

  testWidgets('Mixer channel controls update the shared project model', (tester) async {
    final module = ModuleDoc(id: 'gen-1', name: 'Bass synth', source: '');
    final layer = LayerDoc(id: 'layer-1', name: 'Bass', color: 0, generatorId: module.id, volume: 0.5);
    state.project = ProjectDoc(id: 'project-1', name: 'Workspace test', modules: [module], layers: [layer]);
    state.selectedModuleId = null;
    state.info[module.id] = const ModuleInfo(ok: true, kind: 'generator');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MixerScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('MIXER / EDITOR'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('MODULE INSPECTOR'), findsNothing);
    await tester.tap(find.text('Bass'));
    await tester.pump();
    expect(find.text('MODULE INSPECTOR'), findsOneWidget);
    expect(find.text('Focused editor'), findsOneWidget);
    expect(state.selectedLayerId, 'layer-1');
    expect(state.selectedModuleId, module.id);
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
    final pattern = ModuleDoc(id: 'pat-1', name: 'Beat pattern', source: '---\\nkind: pattern\\n---\\n0 C3 1');
    final layer = LayerDoc(id: 'layer-1', name: 'Noise', color: 0,
      generatorId: module.id, patternId: pattern.id);
    state.project = ProjectDoc(id: 'project-1', name: 'Engine Lab test', modules: [module, pattern], layers: [layer]);
    state.info[module.id] = const ModuleInfo(ok: true, kind: 'generator', summary: 'Noise generator');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: EngineLabScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('ENGINE LAB'), findsOneWidget);
    expect(find.text('TRACK SIGNAL PATHS'), findsOneWidget);
    expect(find.text('COMPILED MODULES'), findsOneWidget);
    expect(find.text('Noise core'), findsNWidgets(2));
    expect(find.text('Noise generator'), findsOneWidget);
    expect(find.text('MIDI'), findsOneWidget);
    expect(find.text('SPECTRUM · 0–24 kHz'), findsOneWidget);
    expect(find.text('512-POINT HANN / FFT'), findsOneWidget);
    expect(find.text('Beat pattern'), findsNWidgets(2));
    await tester.tap(find.text('Beat pattern').first);
    expect(state.selectedModuleId, pattern.id);
  });

  testWidgets('Arranger playhead updates from meter ticks without rebuilding the grid', (tester) async {
    final layer = LayerDoc(id: 'layer-1', name: 'Lead', color: 0);
    state.project = ProjectDoc(id: 'project-1', name: 'Timeline test', layers: [layer]);
    state.meters = const EngineMeters(playing: true, position: 0, loopLength: 256);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ArrangerScreen(state: state)),
    ));
    await tester.tap(find.byTooltip('Track height'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Extra tall · 120 px'));
    await tester.pumpAndSettle();

    CustomPaint painted(String name) => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((w) => w.painter.runtimeType.toString().contains(name));
    final gridBefore = painted('ArrangementGrid').painter;
    final playheadBefore = painted('PlayheadPainter').painter;

    state.meters = const EngineMeters(playing: true, position: 32, loopLength: 256);
    state.tick.value++;
    await tester.pump();

    expect(identical(gridBefore, painted('ArrangementGrid').painter), isTrue);
    expect(identical(playheadBefore, painted('PlayheadPainter').painter), isFalse);
  });

  testWidgets('File Manager exposes portable project and module actions', (tester) async {
    state.project = ProjectDoc(id: 'project-1', name: 'Portable project', modules: [
      ModuleDoc(id: 'gen-1', name: 'Bass', source: '---\\nkind: generator\\n---\\nsin(110)'),
    ]);
    state.createLibraryFolder('Synths');
    state.saveLibrarySearch('Bass search', 'bass');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileManagerScreen(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('FILES / PORTABILITY'), findsOneWidget);
    expect(find.text('Portable project'), findsOneWidget);
    expect(find.text('Export .cawproj'), findsOneWidget);
    expect(find.text('Import project'), findsOneWidget);
    expect(find.text('Import .caw module'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('Bass search'), findsOneWidget);
    expect(find.byTooltip('Undo library operation'), findsOneWidget);
    expect(find.byTooltip('Redo library operation'), findsOneWidget);
    await tester.tap(find.text('Bass search'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, 'bass');

    await tester.tap(find.byTooltip('Select modules'));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Move selected modules'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Synths'));
    await tester.pumpAndSettle();
    expect(state.project.module('gen-1')?.folderPath, 'Synths');
  });



  testWidgets('Exporter applies saved profiles and exposes recent history', (tester) async {
    state.settings.exportProfiles = [
      const ExportProfile(name: 'Master WAV', kind: 'loop', sampleRate: 44100, float32: true),
    ];
    state.settings.exportHistory = [
      ExportHistoryEntry(fileName: 'Recent_take.wav', kind: 'loop',
        createdAtMs: DateTime(2026, 11, 1).millisecondsSinceEpoch),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExporterScreen(state: state)),
    ));

    expect(find.text('Master WAV'), findsOneWidget);
    expect(find.text('Recent_take.wav'), findsOneWidget);
    await tester.tap(find.text('Choose a saved profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Master WAV').last);
    await tester.pumpAndSettle();
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('44.1 kHz'), findsOneWidget);
    expect(find.text('32-bit float'), findsOneWidget);
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

    await tester.tap(find.text('Blank effect'));
    await tester.pump();
    expect(state.project.modules, hasLength(1));
    expect(state.kindOf(state.project.modules.single.id), 'effect');
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Clone as new module'), findsOneWidget);
    await tester.tap(find.text('Clone as new module'));
    await tester.pumpAndSettle();
    expect(state.project.modules, hasLength(2));
    expect(state.kindOf(state.project.modules.last.id), 'effect');
  });

  test('imported projects receive a new identity and preserve project content', () async {
    state.starting = false;
    state.createLibraryFolder('Previous project folder');
    expect(state.canUndoLibrary, isTrue);
    final imported = ProjectDoc(id: 'external-id', name: 'Imported session', bpm: 128);
    await state.importProject(imported);

    expect(state.project.id, isNot('external-id'));
    expect(state.project.name, 'Imported session');
    expect(state.project.bpm, 128);
    expect(state.canUndoLibrary, isFalse);
    expect(state.canRedoLibrary, isFalse);
  });



  test('project import sanitizes virtual folder metadata', () {
    final imported = ProjectDoc.fromJson({
      'caw_app_project': 2,
      'id': 'unsafe-project',
      'name': 'Imported',
      'library_folders': ['Good/Child', '../outside', 'Bad\\\\Path'],
      'modules': [
        {'id': 'safe', 'name': 'Safe', 'source': '', 'folder_path': 'Good/Child'},
        {'id': 'unsafe', 'name': 'Unsafe', 'source': '', 'folder_path': '../../outside'},
      ],
      'layers': [],
    });

    expect(imported.libraryFolders, containsAll(['Good', 'Good/Child']));
    expect(imported.libraryFolders.any((path) => path.contains('..') || path.contains(String.fromCharCode(92))), isFalse);
    expect(imported.module('safe')?.folderPath, 'Good/Child');
    expect(imported.module('unsafe')?.folderPath, '');
  });

  test('library folder operations preserve modules through rename and delete', () {
    final id = state.importModuleSource(
      '---\\nkind: generator\\nname: Folder test\\n---\\nsin(220)',
      fileName: 'Folder.caw',
      folderPath: 'Drums/Kicks',
    );
    final secondId = state.importModuleSource(
      '---\\nkind: effect\\nname: Folder effect\\n---\\nidentity',
      fileName: 'Effect.caw',
      folderPath: 'Drums/Kicks',
    );
    expect(state.project.libraryFolders, containsAll(['Drums', 'Drums/Kicks']));
    expect(state.project.module(id)?.folderPath, 'Drums/Kicks');

    state.setModuleTags(id, ['bass', 'Analog', 'bass']);
    expect(state.project.module(id)?.tags, ['bass', 'Analog']);
    expect(state.setModulesTags([id, secondId], ['synth', 'analog', 'synth']), isTrue);
    expect(state.project.module(id)?.tags, ['synth', 'analog']);
    expect(state.project.module(secondId)?.tags, ['synth', 'analog']);
    expect(state.undoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.tags, ['bass', 'Analog']);
    expect(state.project.module(secondId)?.tags, isEmpty);
    expect(state.redoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.tags, ['synth', 'analog']);
    state.saveLibrarySearch('Bass modules', 'bass');
    expect(state.project.savedLibrarySearches['Bass modules'], 'bass');

    state.createLibraryFolder('Synths');
    expect(state.moveModulesToFolder([id, secondId], 'Synths'), isTrue);
    expect(state.project.module(id)?.folderPath, 'Synths');
    expect(state.project.module(secondId)?.folderPath, 'Synths');
    expect(state.canUndoLibrary, isTrue);
    expect(state.undoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.folderPath, 'Drums/Kicks');
    expect(state.canRedoLibrary, isTrue);
    expect(state.redoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.folderPath, 'Synths');
    expect(state.renameLibraryFolder('Synths', 'Sounds/Synths'), isTrue);
    expect(state.project.libraryFolders, containsAll(['Sounds', 'Sounds/Synths']));
    expect(state.project.module(id)?.folderPath, 'Sounds/Synths');
    expect(state.project.module(secondId)?.folderPath, 'Sounds/Synths');
    final restored = ProjectDoc.fromJson(state.project.toJson());
    expect(restored.libraryFolders, containsAll(['Sounds', 'Sounds/Synths']));
    expect(restored.module(id)?.tags, ['synth', 'analog']);
    expect(restored.savedLibrarySearches['Bass modules'], 'bass');

    expect(state.deleteLibraryFolder('Sounds'), isTrue);
    expect(state.project.module(id)?.folderPath, '');
    expect(state.project.libraryFolders, isNot(contains('Sounds/Synths')));
    expect(state.project.module(id)?.source, contains('sin(220)'));
    expect(state.project.module(secondId)?.source, contains('identity'));
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
