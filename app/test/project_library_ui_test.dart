// Files › Projects on a 360 dp phone: select mode and its bottom bar, select all / none, moving to a folder (from the
// bar and by dragging), deleting with Undo, sort and search, select mode for other files, and goldens of the screen.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart' show ModuleInfo;
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/ui/file_manager_screen.dart';
import 'package:caw/ui/files/project_library_view.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

const _phone = Size(360, 760);
final _sep = Platform.pathSeparator;

void main() {
  late Directory root;
  late ProjectStorage storage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('caw-library-ui-');
    storage = ProjectStorage(root);
  });
  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Three saved projects with fixed dates (noon UTC, so the shown day is the same in any time zone).
  Future<AppState> library(WidgetTester tester) async {
    late AppState s;
    await tester.runAsync(() async {
      void write(String id, String name, DateTime edited, {DateTime? created, int tracks = 2, bool old = false}) {
        final j = (ProjectDoc(id: id, name: name, bpm: 120, layers: [
          for (var i = 0; i < tracks; i++) LayerDoc(id: 'l$i', name: 'T$i', color: i),
        ])..created = created).toJson();
        if (old) j.remove('saved_with');
        final f = File('${root.path}$_sep$id.json')..writeAsStringSync(jsonEncode(j));
        f.setLastModifiedSync(edited);
      }

      write('alpha', 'Alpha jam', DateTime.utc(2026, 11, 10, 12), created: DateTime.utc(2026, 11, 1, 12), tracks: 3);
      write('beta', 'Beta sketch', DateTime.utc(2026, 11, 11, 12), created: DateTime.utc(2026, 11, 2, 12));
      write('gamma', 'Old gamma', DateTime.utc(2026, 9, 1, 12), tracks: 1, old: true);
      await storage.setLastOpened('alpha');
      s = AppState();
      await s.openStorage(storage);
      // Opening doesn't rewrite a file whose text is unchanged; pin the open one's time anyway for the golden.
      File('${root.path}${_sep}alpha.json').setLastModifiedSync(DateTime.utc(2026, 11, 10, 12));
      await storage.library.refresh();
    });
    addTearDown(s.dispose);
    return s;
  }

  /// Lets real file work (the trash, the index) finish, then settles the frame.
  Future<void> io(WidgetTester tester, {bool Function()? until}) async {
    // Each step of the work waits on a real file and then on a frame of the test's clock, so they take turns.
    for (var i = 0; i < (until == null ? 12 : 100); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
      if (until != null && until()) break;
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pump(WidgetTester tester, AppState s) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SectionScope(controller: SectionController(),
          child: Scaffold(body: FileManagerScreen(state: s, folder: 'projects'))),
    ));
    await tester.pump();
    await io(tester); // the view's first refresh (the open project's save, the index) runs on real files
  }

  Finder card(String id) => find.byKey(ValueKey('project:$id'));
  String count(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('selection-count'))).data!;

  testWidgets('cards show the details; Select turns on checkboxes and the bar; select all and none', (tester) async {
    final s = await library(tester);
    await pump(tester, s);
    expect(find.text('Alpha jam'), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
    expect(find.textContaining('Created unknown'), findsOneWidget); // the old project
    expect(find.text('Saved with unknown'), findsOneWidget);
    expect(find.textContaining('3 tracks'), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('projects-select')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    expect(count(tester), '0 selected');
    await tester.tap(card('beta'));
    await tester.pump();
    expect(count(tester), '1 selected');
    expect(s.project.id, 'alpha'); // a tap in select mode selects, it doesn't open
    await tester.tap(find.byKey(const ValueKey('select-all')));
    await tester.pump();
    expect(count(tester), '3 selected');
    await tester.tap(find.byKey(const ValueKey('select-all'))); // now "Select none"
    await tester.pump();
    expect(count(tester), '0 selected');
    await tester.tap(find.byKey(const ValueKey('projects-select'))); // Done
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
  });

  testWidgets('a long press starts select mode; Move to folder puts the projects in it', (tester) async {
    final s = await library(tester);
    final folder = storage.library.createFolder('Drafts');
    await pump(tester, s);
    expect(find.byKey(ValueKey('project-folder:${folder.id}')), findsOneWidget);
    await tester.longPress(card('beta'));
    await tester.pumpAndSettle();
    expect(count(tester), '1 selected');
    await tester.tap(card('gamma'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('selection-move')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('move-target:${folder.id}')));
    await tester.pumpAndSettle();
    expect(card('beta'), findsNothing);
    expect(card('gamma'), findsNothing);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
    expect(storage.library.projectsIn(folder.id).map((p) => p.id).toSet(), {'beta', 'gamma'});
    expect(find.text('2 projects'), findsOneWidget);

    // Into the folder, and back up by its breadcrumb.
    await tester.tap(find.byKey(ValueKey('project-folder:${folder.id}')));
    await tester.pumpAndSettle();
    expect(card('beta'), findsOneWidget);
    expect(card('alpha'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('crumb:top')));
    await tester.pumpAndSettle();
    expect(card('alpha'), findsOneWidget);
    await io(tester);
  });

  testWidgets('a project held and dragged onto a folder moves into it', (tester) async {
    final s = await library(tester);
    final folder = storage.library.createFolder('Keepers');
    await pump(tester, s);
    final g = await tester.startGesture(tester.getCenter(card('alpha')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    final to = tester.getCenter(find.byKey(ValueKey('project-folder:${folder.id}')));
    for (var i = 1; i <= 5; i++) {
      await g.moveTo(Offset.lerp(tester.getCenter(card('alpha')), to, i / 5)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(storage.library.projectsIn(folder.id).map((p) => p.id), ['alpha']);
    expect(card('alpha'), findsNothing);
    await io(tester);
  });

  testWidgets('Delete asks once, moves to the trash and Undo brings the projects back', (tester) async {
    final s = await library(tester);
    await pump(tester, s);
    await tester.longPress(card('beta'));
    await tester.pumpAndSettle();
    await tester.tap(card('gamma'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('selection-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 projects?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await io(tester, until: () => find.text('Deleted 2 projects.').evaluate().isNotEmpty);
    expect(File('${root.path}${_sep}beta.json').existsSync(), isFalse);
    expect(card('beta'), findsNothing);
    expect(find.text('Deleted 2 projects.'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await io(tester, until: () => card('gamma').evaluate().isNotEmpty);
    expect(File('${root.path}${_sep}beta.json').existsSync(), isTrue);
    expect(card('beta'), findsOneWidget);
    expect(card('gamma'), findsOneWidget);
  });

  testWidgets('Export saves each selected project as a .caw into the folder picked', (tester) async {
    final s = await library(tester);
    final was = ProjectExportPicker.saveFolder;
    addTearDown(() => ProjectExportPicker.saveFolder = was);
    final saved = <String, String>{};
    ProjectExportPicker.saveFolder = (files) async {
      for (final (f, name) in files) {
        saved[name] = f.readAsStringSync();
      }
      return files.length;
    };
    await pump(tester, s);
    await tester.longPress(card('beta'));
    await tester.pumpAndSettle();
    await tester.tap(card('gamma'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('selection-export')));
    await io(tester, until: () => saved.isNotEmpty);
    expect(saved.keys.toSet(), {'Beta sketch.caw', 'Old gamma.caw'});
    expect((jsonDecode(saved['Beta sketch.caw']!) as Map)['id'], 'beta');
  });

  testWidgets('sort and search above the list', (tester) async {
    final s = await library(tester);
    await pump(tester, s);
    double y(String id) => tester.getTopLeft(card(id)).dy;
    expect(y('beta') < y('alpha') && y('alpha') < y('gamma'), isTrue); // last edited first
    await tester.tap(find.byKey(const ValueKey('projects-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name').last);
    await tester.pumpAndSettle();
    expect(y('alpha') < y('beta') && y('beta') < y('gamma'), isTrue);
    await tester.enterText(find.byKey(const ValueKey('projects-search')), 'sketch');
    await tester.pumpAndSettle();
    expect(card('beta'), findsOneWidget);
    expect(card('alpha'), findsNothing);
  });

  testWidgets('other files: Select, check two patterns, Delete and Undo', (tester) async {
    final s = AppState()..starting = false;
    addTearDown(s.dispose);
    s.project = ProjectDoc(id: 'files', name: 'Files', modules: [
      ModuleDoc(id: 'riff', name: 'Riff', source: '---\nkind: pattern\n---\n0 A2 1 1'),
      ModuleDoc(id: 'beat', name: 'Beat', source: '---\nkind: pattern\n---\nc4'),
    ]);
    s.info['riff'] = const ModuleInfo(ok: true, kind: 'pattern');
    s.info['beat'] = const ModuleInfo(ok: true, kind: 'pattern');
    s.history.reset(jsonEncode(s.project.toJson()));
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SectionScope(controller: SectionController(),
        child: Scaffold(body: FileManagerScreen(state: s, folder: 'audio/patterns')))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('files-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('select-all')));
    await tester.pump();
    expect(count(tester), '2 selected');
    await tester.tap(find.byKey(const ValueKey('selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await tester.pumpAndSettle();
    expect(s.project.modules, isEmpty);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(s.project.modules.map((m) => m.id).toSet(), {'riff', 'beat'});
  });

  group('goldens', () {
    late MotionLevel motion;
    setUp(() => motion = Motion.setting);
    tearDown(() => Motion.setting = motion);

    testWidgets('Files › Projects on a 360 dp phone, and in select mode', (tester) async {
      final s = await library(tester);
      final folder = storage.library.createFolder('Drafts');
      storage.library.moveProjects(['gamma'], folder.id);
      await pumpGolden(tester, SectionScope(controller: SectionController(),
          child: Scaffold(body: FileManagerScreen(state: s, folder: 'projects'))), _phone);
      await expectLater(goldenScreen, matchesGoldenFile('goldens/files_projects_phone.png'));
      await tester.longPress(card('beta'));
      await tester.pumpAndSettle();
      await expectLater(goldenScreen, matchesGoldenFile('goldens/files_projects_select_phone.png'));
      await io(tester);
    });
  });

  test('export names are safe and unique', () {
    final taken = <String>{};
    expect(exportFileName('My song', taken), 'My song.caw');
    expect(exportFileName('My song', taken), 'My song (2).caw');
    expect(exportFileName('../a:b', taken), 'Project.._a_b.caw');
    expect(libraryLength(92), '1:32');
    expect(libraryLength(3725), '1:02:05');
  });
}
