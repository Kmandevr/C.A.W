// The project library (Files › Projects): metadata read through the index and the migration of old projects, folder
// operations, deleting with undo (projects and other files), the index after a crash, and search and sort.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart' show ModuleInfo;
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/project_library.dart';
import 'package:caw/model/sample_packs.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/model/user_presets.dart';
import 'package:caw/version.dart';
import 'package:flutter_test/flutter_test.dart';

final _sep = Platform.pathSeparator;

/// A project file as an app from before 2026-11-12 wrote it: no `created`, no `saved_with`.
Map<String, dynamic> _oldProject(String id, String name, {int tracks = 2, double bpm = 120}) => {
      'caw_app_project': 2,
      'id': id,
      'name': name,
      'bpm': bpm,
      'beats_per_bar': 4,
      'loop_bars': 8,
      'layers': [
        for (var i = 0; i < tracks; i++) {'id': 'l$i', 'name': 'Track $i', 'color': i},
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProjectStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('caw-library-');
    storage = ProjectStorage(root);
  });
  tearDown(() async {
    await storage.library.settle();
    if (await root.exists()) await root.delete(recursive: true);
  });

  File file(String id) => File('${root.path}$_sep$id.json');
  void writeOld(String id, String name, {int tracks = 2, double bpm = 120}) =>
      file(id).writeAsStringSync(jsonEncode(_oldProject(id, name, tracks: tracks, bpm: bpm)));

  test('the build number matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(int.parse(line.split('+').last.trim()), appBuild);
  });

  group('metadata', () {
    test('old projects read as unknown; new ones carry created and saved-with', () async {
      writeOld('old', 'Old song', tracks: 3, bpm: 100);
      final created = DateTime.utc(2026, 11, 1, 12);
      await storage.save(ProjectDoc(id: 'new', name: 'New song', bpm: 140)..created = created);
      final list = await storage.library.refresh();
      final old = list.firstWhere((p) => p.id == 'old'), fresh = list.firstWhere((p) => p.id == 'new');
      expect(old.created, isNull);
      expect(old.savedWith, 'unknown');
      expect(old.tracks, 3);
      expect(old.bpm, 100);
      // 8 bars of 4/4 at 100 BPM: 32 beats, 19.2 s.
      expect(old.seconds, closeTo(19.2, 0.001));
      expect(fresh.created, created);
      expect(fresh.savedWith, '$appVersion ($appBuild)');
      expect(fresh.bytes, file('new').lengthSync());
      expect(old.folder, isNull); // no folder: the top level
    });

    test('the JSON fields round-trip and untrusted values are dropped', () {
      final p = ProjectDoc(id: 'a', name: 'A')..created = DateTime.utc(2026, 1, 2);
      final j = p.toJson();
      expect(j['saved_with'], {'version': appVersion, 'build': appBuild});
      expect(j['created'], '2026-01-02T00:00:00.000Z');
      final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back.created, DateTime.utc(2026, 1, 2));
      expect(back.savedWithVersion, appVersion);
      expect(back.savedWithBuild, appBuild);
      final bad = ProjectDoc.fromJson({
        'id': 'b',
        'created': 'x' * 100,
        'saved_with': {'version': 'v\n${'9' * 50}', 'build': -1},
      });
      expect(bad.created, isNull);
      expect(bad.savedWithVersion, isNull);
      expect(bad.savedWithBuild, isNull);
    });

    test('unchanged files are not read again (the index serves them)', () async {
      writeOld('a', 'Alpha');
      await storage.library.refresh();
      await storage.library.settle();
      // Same size and time, other content: a re-read would see the broken JSON and drop the project.
      final f = file('a');
      final stamp = f.lastModifiedSync(), size = f.lengthSync();
      f.writeAsStringSync('#' * size);
      f.setLastModifiedSync(stamp);
      final fresh = ProjectStorage(root);
      final list = await fresh.library.refresh();
      expect(list.single.name, 'Alpha');
      // A changed file is read again.
      writeOld('a', 'Alpha 2');
      f.setLastModifiedSync(stamp.add(const Duration(seconds: 5)));
      expect((await fresh.library.refresh()).single.name, 'Alpha 2');
      await fresh.library.settle();
    });

    test('a file larger than the limit is listed without reading it; a damaged one is skipped', () async {
      writeOld('ok', 'Fine');
      file('broken').writeAsStringSync('{not json');
      file('other-id').writeAsStringSync(jsonEncode(_oldProject('someone-else', 'Wrong id')));
      final list = await storage.library.refresh();
      expect(list.map((p) => p.id), ['ok']);
    });

    test('opening a project does not touch its file, and the app stamps created on a new project', () async {
      await storage.save(ProjectDoc(id: 'a', name: 'Alpha'));
      await storage.setLastOpened('a');
      final before = file('a').lastModifiedSync();
      final s = AppState();
      addTearDown(s.dispose);
      await s.openStorage(ProjectStorage(root));
      expect(s.project.id, 'a');
      expect(s.project.created, isNull); // an old project stays unknown
      expect(file('a').lastModifiedSync(), before);
      await s.newProject();
      expect(s.project.created, isNotNull);
      final saved = jsonDecode(file(s.project.id).readAsStringSync()) as Map;
      expect(saved['created'], isNotNull);
      expect(saved['saved_with'], {'version': appVersion, 'build': appBuild});
      await s.duplicateProject();
      expect(s.project.created!.isAfter(DateTime.utc(2026)), isTrue);
    });
  });

  group('folders', () {
    test('create, nest, rename, move into and delete (refused when full unless moved up)', () async {
      writeOld('a', 'A');
      writeOld('b', 'B');
      final lib = storage.library;
      await lib.refresh();
      final drums = lib.createFolder('Drums');
      final kicks = lib.createFolder('Kicks', parent: drums.id);
      lib.renameFolder(kicks.id, 'Kick drums');
      lib.moveProjects(['a'], kicks.id);
      lib.moveProjects(['b'], drums.id);
      expect(lib.trail(kicks.id).map((f) => f.name), ['Drums', 'Kick drums']);
      expect(lib.projectsIn(kicks.id).map((p) => p.id), ['a']);
      expect(lib.projectsIn(null), isEmpty);
      expect(() => lib.deleteFolder(drums.id), throwsStateError);
      expect(lib.moveFolder(drums.id, kicks.id), isFalse); // not into its own folder

      // Kept across a restart.
      await lib.settle();
      final again = ProjectStorage(root).library;
      await again.refresh();
      expect(again.projectsIn(kicks.id).map((p) => p.id), ['a']);
      expect(again.folders[kicks.id]!.parent, drums.id);

      again.deleteFolder(drums.id, moveContentsUp: true);
      expect(again.folders.keys, [kicks.id]);
      expect(again.folders[kicks.id]!.parent, isNull);
      expect(again.projectsIn(null).map((p) => p.id), ['b']);
      again.deleteFolder(kicks.id, moveContentsUp: true);
      expect(again.projectsIn(null).map((p) => p.id).toSet(), {'a', 'b'});
      await again.settle();
    });

    test('an untrusted index: loops, missing parents and unknown folders fall back to the top level', () async {
      writeOld('a', 'A');
      File('${root.path}$_sep$libraryIndexName').writeAsStringSync(jsonEncode({
        'caw_project_library': 1,
        'folders': [
          {'id': 'x', 'name': 'X', 'parent': 'y'},
          {'id': 'y', 'name': 'Y', 'parent': 'x'},
          {'id': 'z', 'name': 'Z\u0000', 'parent': 'gone'},
          {'id': '../bad', 'name': 'Bad'},
        ],
        'projects': {
          'a': {'folder': 'nowhere', 'meta': {'name': 1}},
        },
      }));
      final lib = storage.library;
      final list = await lib.refresh();
      expect(lib.folders.keys.toSet(), {'x', 'y', 'z'});
      // The loop is broken at one of its folders; the other hangs under it.
      expect(lib.folders.values.where((f) => f.parent == null).length, 2);
      expect(lib.folders['z']!.parent, isNull);
      expect(lib.folders['z']!.name, 'Z');
      expect(list.single.folder, isNull);
      expect(list.single.name, 'A');
    });
  });

  group('crashes', () {
    test('a half-written temporary index is ignored and the last whole one is used', () async {
      writeOld('a', 'A');
      final lib = storage.library;
      await lib.refresh();
      final f = lib.createFolder('Keep');
      lib.moveProjects(['a'], f.id);
      await lib.settle();
      File('${root.path}$_sep$libraryIndexName.tmp').writeAsStringSync('{"caw_project_li');
      final again = ProjectStorage(root).library;
      final list = await again.refresh();
      expect(list.single.folder, f.id);
    });

    test('a damaged index starts again with every project at the top level', () async {
      writeOld('a', 'A');
      File('${root.path}$_sep$libraryIndexName').writeAsStringSync('{"caw_project_library": 1, "fol');
      final list = await storage.library.refresh();
      expect(list.single.id, 'a');
      expect(list.single.folder, isNull);
      await storage.library.settle();
      expect(jsonDecode(File('${root.path}$_sep$libraryIndexName').readAsStringSync())['caw_project_library'], 1);
    });

    test('a trash batch left by a closed app is emptied, and one whose Undo had started is finished', () async {
      writeOld('a', 'A');
      writeOld('b', 'B');
      Directory('${root.path}${_sep}audio$_sep${'b'}').createSync(recursive: true);
      File('${root.path}${_sep}audio${_sep}b${_sep}take.wav').writeAsStringSync('RIFF');
      final lib = storage.library;
      await lib.refresh();
      final batchA = await lib.trash(['a']);
      final batchB = await lib.trash(['b']);
      // The Undo of b had begun when the app closed.
      File('${lib.trashDirectory.path}$_sep${batchB.id}${_sep}restoring').writeAsStringSync('1');
      expect(batchA.projectIds, ['a']);
      final again = ProjectStorage(root).library;
      final list = await again.refresh();
      expect(list.map((p) => p.id), ['b']);
      expect(File('${root.path}${_sep}audio${_sep}b${_sep}take.wav').existsSync(), isTrue);
      expect(again.trashDirectory.listSync(), isEmpty);
    });
  });

  group('mass delete with undo', () {
    test('projects go to the trash with their files and come back into their folders', () async {
      writeOld('a', 'A');
      writeOld('b', 'B');
      writeOld('c', 'C');
      final audio = Directory('${root.path}${_sep}audio${_sep}a')..createSync(recursive: true);
      File('${audio.path}${_sep}x.wav').writeAsStringSync('RIFF');
      await storage.setLastOpened('a');
      final s = AppState();
      addTearDown(s.dispose);
      await s.openStorage(storage);
      final lib = storage.library;
      final f = lib.createFolder('Old');
      lib.moveProjects(['a', 'b'], f.id);

      final batch = await s.trashProjects(['a', 'b']);
      expect(batch!.projectIds.toSet(), {'a', 'b'});
      expect(file('a').existsSync(), isFalse);
      expect(audio.existsSync(), isFalse);
      expect(s.project.id, 'c'); // the open one was deleted: the newest other opened, and 'a' wasn't saved again
      expect(file('a').existsSync(), isFalse);
      expect(s.savedProjects.map((p) => p.id), ['c']);

      expect(await s.restoreProjects(batch), 2);
      expect(file('a').existsSync(), isTrue);
      expect(File('${audio.path}${_sep}x.wav').existsSync(), isTrue);
      expect(lib.projectsIn(f.id).map((p) => p.id).toSet(), {'a', 'b'});
      expect(lib.trashDirectory.listSync(), isEmpty);

      final again = await s.trashProjects(['b']);
      await lib.purge(again!);
      expect(file('b').existsSync(), isFalse);
      expect(lib.trashDirectory.listSync(), isEmpty);
      expect((await s.listProjects()).map((p) => p.id).toSet(), {'a', 'c'});
    });

    test('other files: patterns, MIDI files, audio, presets and sample WAVs undo in one go', () async {
      final presets = Directory('${root.path}${_sep}presets')..createSync();
      final packs = Directory('${root.path}${_sep}packs')..createSync();
      final pack = Directory('${packs.path}${_sep}Pad')..createSync();
      File('${pack.path}${_sep}C3.wav').writeAsStringSync('RIFF');
      final s = AppState()
        ..userPresets = UserPresetStore(presets)
        ..samplePacksRoot = packs;
      addTearDown(s.dispose);
      s.starting = false;
      s.project = ProjectDoc(id: 'p', name: 'P', modules: [
        ModuleDoc(id: 'riff', name: 'Riff', source: '---\nkind: pattern\n---\n0 A2 1 1'),
      ], midiFiles: [
        MidiFileDoc(id: 'mf', name: 'Song.mid', parts: ['riff']),
      ], assets: [
        AudioAssetDoc(id: 'au', name: 'Vox', path: '/tmp/vox.wav'),
      ]);
      s.info['riff'] = const ModuleInfo(ok: true, kind: 'pattern');
      s.history.reset(jsonEncode(s.project.toJson()));
      s.userPresets.put(UserPreset(id: 'up_1', kind: UserPresetKind.track, name: 'Lead', modified: DateTime.utc(2026)));
      await s.refreshSamplePacks();

      final all = [...s.moduleAssets, ...s.midiFileAssets, ...s.audioAssets, ...s.presetAssets, ...s.sampleAssets];
      expect(all, hasLength(5));
      final done = s.deleteAssets(all);
      expect(done.count, 5);
      expect(s.project.modules, isEmpty);
      expect(s.project.midiFiles, isEmpty);
      expect(s.project.assets, isEmpty);
      expect(s.userPresets.all, isEmpty);
      await s.refreshSamplePacks();
      expect(s.sampleAssets, isEmpty);

      await s.undoAssetDeletion(done);
      expect(s.project.modules.map((m) => m.id), ['riff']);
      expect(s.project.midiFiles.map((m) => m.id), ['mf']);
      expect(s.project.assets.map((m) => m.id), ['au']);
      expect(s.userPresets.all.map((p) => p.id), ['up_1']);
      expect(s.sampleAssets.map((a) => a.name), ['C3.wav']);

      // Again, and this time the message closes: the WAV and its emptied pack go for good.
      final gone = s.deleteAssets(s.sampleAssets);
      await s.finishAssetDeletion(gone);
      expect(pack.existsSync(), isFalse);
    });
  });

  group('search and sort', () {
    final metas = [
      ProjectMeta(id: '1', name: 'Bass study', modified: DateTime.utc(2026, 3), created: DateTime.utc(2026, 1), bytes: 30),
      ProjectMeta(id: '2', name: 'acid line', modified: DateTime.utc(2026, 5), bytes: 10),
      ProjectMeta(id: '3', name: 'Ambient bass', modified: DateTime.utc(2026, 4), created: DateTime.utc(2026, 2), bytes: 20),
    ];
    List<String> ids(List<ProjectMeta> l) => [for (final p in l) p.id];

    test('sort by name, last edited, created (unknown last) and size', () {
      expect(ids(sortProjects(metas, ProjectSort.name)), ['2', '3', '1']);
      expect(ids(sortProjects(metas, ProjectSort.edited)), ['2', '3', '1']);
      expect(ids(sortProjects(metas, ProjectSort.created)), ['3', '1', '2']);
      expect(ids(sortProjects(metas, ProjectSort.size)), ['1', '3', '2']);
    });

    test('search matches every word, ignoring case', () {
      expect(ids(searchProjects(metas, 'BASS')), ['1', '3']);
      expect(ids(searchProjects(metas, 'bass amb')), ['3']);
      expect(ids(searchProjects(metas, '  ')), ['1', '2', '3']);
      expect(searchProjects(metas, 'nothing'), isEmpty);
    });
  });
}
