import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:caw/model/project.dart';
import 'package:caw/model/storage.dart';

void main() {
  late Directory root;
  late ProjectStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('caw-restore-points-');
    storage = ProjectStorage(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('restore points round-trip, sort newest first and reject cross-project access', () async {
    final project = ProjectDoc(id: 'project-a', name: 'Original session', bpm: 128);
    final first = await storage.createRestorePoint(project);
    project.name = 'Edited session';
    final second = await storage.createRestorePoint(project);

    final points = await storage.listRestorePoints(project.id);
    expect(points, hasLength(2));
    expect(points.first.id, second);
    expect(points.last.id, first);
    expect(points.first.name, 'Edited session');

    final restored = await storage.loadRestorePoint(project.id, first);
    expect(restored?.id, project.id);
    expect(restored?.name, 'Original session');
    expect(await storage.loadRestorePoint('project-b', first), isNull);
    expect(await storage.loadRestorePoint(project.id, '../project-b'), isNull);
  });

  test('deleting a project also removes its restore-point history', () async {
    final project = ProjectDoc(id: 'project-delete', name: 'Delete');
    await storage.createRestorePoint(project);
    expect(await storage.listRestorePoints(project.id), hasLength(1));
    await storage.delete(project.id);
    expect(await storage.listRestorePoints(project.id), isEmpty);
  });

  test('restore point retention is bounded to the newest twenty snapshots', () async {
    final project = ProjectDoc(id: 'project-retention', name: 'Retention');
    final ids = <String>[];
    for (var i = 0; i < 22; i++) {
      project.name = 'Version $i';
      ids.add(await storage.createRestorePoint(project));
    }
    final points = await storage.listRestorePoints(project.id);
    expect(points, hasLength(20));
    expect(points.any((point) => point.id == ids.first), isFalse);
    expect(points.any((point) => point.id == ids.last), isTrue);
  });
}
