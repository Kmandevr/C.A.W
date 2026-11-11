// Templates (gap 10): a project or a track saved as a template, New project from one (and as Settings' default),
// track templates inserted with fresh ids from the add-track menu, the bundled starters, and the store on disk.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/templates.dart';
import 'package:caw/ui/arrange/templates_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'My song', bpm: 97, modules: [
      ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n'),
      ModuleDoc(id: 'echo', name: 'Echo', source: '---\nkind: effect\n---\n', params: {'mix': 0.4}),
    ], layers: [
      LayerDoc(id: 'f', name: 'Band', color: 1, isFolder: true),
      LayerDoc(id: 'a', name: 'Drums', color: 0, parentId: 'f', effectIds: ['echo'],
          instrument: ComponentUseDoc('org.caw.drums', {}, false, null, 1, 'Kit: 808'),
          clips: [ClipDoc(id: 'c1', patternId: 'pat', lengthSteps: 16)], sends: [SendDoc('r'), SendDoc('outside')]),
      LayerDoc(id: 'r', name: 'Verb', color: 2, parentId: 'f', isFolder: true,
          components: [ComponentUseDoc('org.caw.reverb.pro', {'mix': 1.0})]),
      LayerDoc(id: 'outside', name: 'Other bus', color: 3, isFolder: true),
    ], automation: [
      ProjectAutomationLaneDoc(targetType: 'instrument', target: 'level', layerId: 'a',
          points: [AutomationPointDoc(step: 0, value: 0.5)]),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
  });
  tearDown(() => s.dispose());

  test('the bundled starters: First loop and Song sketch, and five track templates', () {
    expect(s.projectTemplates.map((t) => t.name), ['First loop', 'Song sketch']);
    expect(s.trackTemplates.map((t) => t.name), ['Drums', 'Bass', 'Keys', 'Pad', 'Reverb bus']);
    final sketch = s.projectFromTemplate(s.templateById('builtin:song-sketch')!);
    expect(sketch.layers.map((l) => l.name), ['Drums', 'Bass', 'Keys', 'Pad', 'Reverb bus']);
    final bus = sketch.layers.last;
    expect(sketch.layers.firstWhere((l) => l.name == 'Pad').sends.single.to, bus.id);
    expect(s.projectFromTemplate(s.templateById(firstLoopTemplateId)!).name, 'First loop');
  });

  test('a project saved as a template comes back as a new project with its tracks and clips', () {
    final t = s.saveProjectTemplate('Band setup');
    expect(s.projectTemplates.last.name, 'Band setup');
    final p = s.projectFromTemplate(t);
    expect(p.id, isNot('p'));
    expect(p.name, 'Band setup');
    expect(p.bpm, 97);
    expect(p.layers.map((l) => l.name), ['Band', 'Drums', 'Verb', 'Other bus']);
    expect(p.layers[1].clips.single.patternId, 'pat');
    // Saving under the same name replaces it.
    s.saveProjectTemplate('band setup');
    expect(s.templateStore.of(TemplateKind.project), hasLength(1));
  });

  test('New project opens the template Settings names, or a blank one', () {
    expect(s.newProjectDoc().layers, isEmpty);
    s.settings.newProjectTemplate = firstLoopTemplateId;
    expect(s.newProjectDoc().name, 'First loop');
    s.settings.newProjectTemplate = s.saveProjectTemplate('Mine').id;
    expect(s.newProjectDoc().name, 'Mine');
    s.settings.newProjectTemplate = 'gone';
    expect(s.newProjectDoc().layers, isEmpty);
  });

  test('a folder saved as a track template inserts with new ids, its sends inside and its lanes', () {
    final folder = s.project.layers.first;
    final t = s.saveTrackTemplate(folder, 'Band');
    expect((t.json['layers'] as List), hasLength(3));
    final first = s.insertTrackTemplate(t)!;
    final added = s.project.layers.sublist(4);
    expect(added.map((l) => l.name), ['Band', 'Drums', 'Verb']);
    expect(first.id, isNot('f'));
    expect(added[1].parentId, first.id);
    expect(added[1].sends.single.to, added[2].id); // the send outside the folder is left out
    expect(added[1].clips, isEmpty); // without clips
    expect(added[1].instrument!.preset, 'Kit: 808');
    // Its .caw effect is a copy of its own.
    final echo = added[1].effectIds.single;
    expect(echo, isNot('echo'));
    expect(s.project.module(echo)!.params['mix'], 0.4);
    expect(s.project.automation.where((a) => a.layerId == added[1].id), hasLength(1));
    expect(s.selectedLayerId, first.id);
  });

  test('a track template with clips brings its patterns', () {
    final drums = s.project.layers[1];
    final t = s.saveTrackTemplate(drums, 'Drums with beat', clips: true);
    final added = s.insertTrackTemplate(t)!;
    expect(added.parentId, isNull);
    expect(added.sends, isEmpty);
    final clip = added.clips.single;
    expect(clip.id, isNot('c1'));
    expect(clip.patternId, isNot('pat'));
    expect(s.project.module(clip.patternId)!.source, contains('0 C2 1 1'));
  });

  test('a bundled track template inserts', () {
    final before = s.project.layers.length;
    s.insertTrackTemplate(s.trackTemplates.firstWhere((t) => t.name == 'Reverb bus'));
    expect(s.project.layers.length, before + 1);
    expect(s.project.layers.last.isFolder, isTrue);
    expect(s.project.layers.last.components.single.id, 'org.caw.reverb.pro');
  });

  test('templates are kept on disk and read back', () async {
    final dir = await Directory.systemTemp.createTemp('caw-templates');
    addTearDown(() => dir.delete(recursive: true));
    final store = TemplateStore(dir);
    s.templateStore = store;
    s.saveTrackTemplate(s.project.layers[1], 'Drums');
    s.saveProjectTemplate('Song');
    await store.flush();
    final again = TemplateStore(dir);
    await again.load();
    expect(again.of(TemplateKind.track).single.name, 'Drums');
    expect(again.of(TemplateKind.project).single.name, 'Song');
    again.remove(again.of(TemplateKind.project).single.id);
    await again.flush();
    expect(dir.listSync().length, 1);
  });

  testWidgets('the add-track menu lists the track templates and inserts one', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      ctx = context;
      return const SizedBox.expand();
    }))));
    final before = s.project.layers.length;
    final done = showAddTrackMenu(ctx, s, const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(find.text('Empty track'), findsOneWidget);
    await tester.tap(find.text('Pad'));
    await tester.pumpAndSettle();
    await done;
    expect(s.project.layers.length, before + 1);
    expect(s.project.layers.last.name, 'Pad');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('New from template lists the starters; the star makes one the default', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      ctx = context;
      return const SizedBox.expand();
    }))));
    s.saveProjectTemplate('Mine');
    final done = showProjectTemplates(ctx, s);
    await tester.pumpAndSettle();
    expect(find.text('Song sketch'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('template-default-builtin:song-sketch')));
    await tester.pumpAndSettle();
    expect(s.settings.newProjectTemplate, 'builtin:song-sketch');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await done;
    await tester.pump(const Duration(seconds: 1));
  });
}
