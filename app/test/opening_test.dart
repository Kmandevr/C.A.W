// Tests how the app opens (UI plan U1): straight into the last project, or the "First loop" template on a first run
// or when the last project is gone (a damaged one says so). There is no startup screen.
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late ProjectStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('caw-opening-');
    storage = ProjectStorage(root);
  });
  tearDown(() => root.delete(recursive: true));

  Future<AppState> open() async {
    final s = AppState();
    await s.openStorage(storage);
    addTearDown(s.dispose);
    return s;
  }

  test('opens straight into the last project', () async {
    await storage.save(ProjectDoc(id: 'a', name: 'Alpha'));
    await storage.save(ProjectDoc(id: 'b', name: 'Beta'));
    await storage.setLastOpened('a');
    final s = await open();
    expect(s.starting, isFalse);
    expect(s.project.id, 'a');
    expect(s.project.name, 'Alpha');
    expect(s.savedProjects.map((p) => p.name), containsAll(['Alpha', 'Beta']));
  });

  test('a first run opens the First loop template', () async {
    final s = await open();
    expect(s.starting, isFalse);
    expect(s.project.name, s.starterProject().name);
  });

  test('a last project that is gone opens the template instead', () async {
    await storage.setLastOpened('deleted');
    final s = await open();
    expect(s.starting, isFalse);
    expect(s.project.name, s.starterProject().name);
  });

  test('a damaged last project opens the template and says so; its file stays', () async {
    final f = File('${root.path}${Platform.pathSeparator}broken.json')..writeAsStringSync('{not json');
    await storage.setLastOpened('broken');
    final s = await open();
    expect(s.starting, isFalse);
    expect(s.project.name, s.starterProject().name);
    expect(s.openError, contains('could not be read'));
    expect(f.existsSync(), isTrue);
  });

  test('a missing last project opens the template without an error', () async {
    await storage.setLastOpened('deleted');
    final s = await open();
    expect(s.openError, isNull);
  });
}
