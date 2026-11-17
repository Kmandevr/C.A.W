// The sample library (#229): bounded folder walks that never leave the folder, the incremental on-disk index, where each value comes from, and the browser's filters.
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/model/music_key.dart';
import 'package:caw/model/sample_library.dart';
import 'package:caw/model/sample_meta.dart';
import 'package:caw/model/sample_names.dart';
import 'package:caw/platform/linked_folders.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart' show writeTestWav;
import 'sample_fake.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('caw-samples'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File put(String rel, {int bytes = 64}) {
    final f = File('${tmp.path}/lib/$rel')..createSync(recursive: true);
    f.writeAsBytesSync(Uint8List(bytes));
    return f;
  }

  group('walking a folder', () {
    test('audio files only, in order, no hidden names, links skipped', () {
      put('Drums/Kick 01.wav');
      put('Drums/notes.txt');
      put('Loops/Am/Loop 120bpm.flac');
      put('.hidden/secret.wav');
      put('Drums/.DS_Store.wav');
      final outside = Directory('${tmp.path}/outside')..createSync();
      File('${outside.path}/stolen.wav').writeAsBytesSync([1, 2, 3]);
      if (!Platform.isWindows) {
        Link('${tmp.path}/lib/escape').createSync(outside.path);
        Link('${tmp.path}/lib/Drums/alias.wav').createSync('${outside.path}/stolen.wav');
      }
      final l = listDirectorySync('${tmp.path}/lib');
      expect([for (final f in l.files) f.rel], ['Drums/Kick 01.wav', 'Loops/Am/Loop 120bpm.flac']);
      expect(l.truncated, isFalse);
      expect(l.files.first.size, 64);
    });
    test('depth and file limits stop the walk and say so', () {
      put('a/b/c/d/deep.wav');
      put('top.wav');
      final shallow = listDirectorySync('${tmp.path}/lib', maxDepth: 2);
      expect([for (final f in shallow.files) f.rel], ['top.wav']);
      expect(shallow.truncated, isTrue);
      for (var i = 0; i < 5; i++) {
        put('many/$i.wav');
      }
      final few = listDirectorySync('${tmp.path}/lib', maxFiles: 3);
      expect(few.files.length, 3);
      expect(few.truncated, isTrue);
      expect(listDirectorySync('${tmp.path}/none').error, isNotNull);
    });
    test('relative paths never climb out', () {
      expect(joinInside('/x', '../etc/passwd'), isNull);
      expect(joinInside('/x', 'a/./b.wav'), isNull);
      expect(joinInside('/x', '/abs.wav'), isNull);
      expect(joinInside('/x', 'a/b.wav'), '/x${Platform.pathSeparator}a${Platform.pathSeparator}b.wav');
      expect(safeEntryName('ok name.wav'), isTrue);
      expect(safeEntryName('a/b'), isFalse);
      expect(safeEntryName('..'), isFalse);
      expect(safeEntryName('x' * 300), isFalse);
    });
  });

  group('what a file is', () {
    test('metadata before the name, the name before the length', () {
      final e = SampleEntry(root: 'r', rel: 'Loops 90bpm/Bass Am 128bpm.wav');
      describeSample(e, SampleMeta()
        ..bpm = 126
        ..seconds = 7.62);
      expect(e.bpm, 126);
      expect(e.bpmFrom, ValueSource.metadata);
      expect(e.key, const MusicalKey(9, minor: true));
      expect(e.keyFrom, ValueSource.name);
      expect(e.instrument, SampleInstrument.bass);
      expect(e.kind, SampleKind.loop);  // the folder says loops
      expect(e.kindFrom, ValueSource.name);
      final shot = SampleEntry(root: 'r', rel: 'Misc/Thing.wav');
      describeSample(shot, SampleMeta()..seconds = 0.4);
      expect(shot.kind, SampleKind.oneShot);
      expect(shot.kindFrom, ValueSource.detected);
      final long = SampleEntry(root: 'r', rel: 'Misc/Texture.wav');
      describeSample(long, SampleMeta()..seconds = 12);
      expect(long.kind, SampleKind.loop);
      // Four beats at the named tempo: a loop.
      final bar = SampleEntry(root: 'r', rel: 'Misc/Groove 120bpm.wav');
      describeSample(bar, SampleMeta()..seconds = 4.0);
      expect(bar.kind, SampleKind.loop);
      // acid beats give the tempo when nothing else does.
      final acid = SampleEntry(root: 'r', rel: 'Misc/Untitled.wav');
      describeSample(acid, SampleMeta()
        ..beats = 8
        ..seconds = 4.0);
      expect(acid.bpm, 120);
      expect(acid.bpmFrom, ValueSource.metadata);
      expect(acid.kind, SampleKind.loop);
    });
    test('an index line round-trips and is read with limits', () {
      final e = SampleEntry(root: 'r', rel: 'a/b.wav', size: 10, modified: 20, doc: 'd1')
        ..bpm = 120
        ..bpmFrom = ValueSource.name
        ..key = const MusicalKey(2, minor: true)
        ..keyFrom = ValueSource.detected
        ..keyConfidence = 0.4
        ..kind = SampleKind.loop
        ..kindFrom = ValueSource.metadata
        ..instrument = SampleInstrument.pad
        ..seconds = 3.5
        ..tags = ['pad', 'warm']
        ..tried = 3;
      final back = SampleEntry.fromJson('r', e.toJson())!;
      expect(back.toJson(), e.toJson());
      expect(SampleEntry.fromJson('r', {'r': '../x.wav'}), isNull);
      expect(SampleEntry.fromJson('r', {'r': 'a/.hidden.wav'}), isNull);
      final bad = SampleEntry.fromJson('r', {'r': 'ok.wav', 'b': 1e9, 'k': '99', 'sec': -1, 'g': List.filled(100, 'x' * 99)})!;
      expect(bad.bpm, isNull);
      expect(bad.key, isNull);
      expect(bad.seconds, isNull);
      expect(bad.tags.length, 32);
      expect(bad.tags.first.length, 40);
    });
  });

  group('the index', () {
    test('refresh reads only new and changed files, and the index comes back from disk', () async {
      final settings = Directory('${tmp.path}/settings')..createSync();
      writeTestWav('${tmp.path}/lib/Loops/Drum Loop 120bpm.wav', seconds: 0.5);
      writeTestWav('${tmp.path}/lib/Hits/Kick 01.wav', seconds: 0.2);
      final access = FakeFolderAccess();
      final lib = SampleLibrary(settingsDir: settings, access: access);
      await lib.load(refresh: false);
      final (lf, error) = await lib.link('${tmp.path}/lib', 'Lib');
      expect(error, isNull);
      await lib.refresh(lf!.id);
      expect(access.metaReads..sort(), ['Hits/Kick 01.wav', 'Loops/Drum Loop 120bpm.wav']);
      final loop = lib.entry(lf.id, 'Loops/Drum Loop 120bpm.wav')!;
      expect(loop.bpm, 120);
      expect(loop.instrument, SampleInstrument.drums);
      expect(loop.seconds, closeTo(0.5, 1e-6));
      // Nothing changed: nothing is read again. One file grows: only it is.
      access.metaReads.clear();
      await lib.refresh(lf.id);
      expect(access.metaReads, isEmpty);
      writeTestWav('${tmp.path}/lib/Hits/Kick 01.wav', seconds: 0.3);
      await lib.refresh(lf.id);
      expect(access.metaReads, ['Hits/Kick 01.wav']);
      // A new library reads the folders and the index without walking the folder.
      final again = SampleLibrary(settingsDir: settings, access: FakeFolderAccess());
      await again.load(refresh: false);
      expect(again.folders.single.id, lf.id);
      expect(again.entries(lf.id).length, 2);
      expect(again.entry(lf.id, 'Loops/Drum Loop 120bpm.wav')!.bpm, 120);
      // A damaged index is ignored, not trusted.
      File('${settings.path}/sample-index/${lf.id}.json').writeAsStringSync('{"version":1,"root":"${lf.id}","entries":[{"r":"../../x"}');
      expect(readIndexFileSync('${settings.path}/sample-index/${lf.id}.json', lf.id), isEmpty);
      File('${settings.path}/sample-index/${lf.id}.json').writeAsStringSync('{"version":1,"root":"other","entries":[{"r":"a.wav"}]}');
      expect(readIndexFileSync('${settings.path}/sample-index/${lf.id}.json', lf.id), isEmpty);
    });
    test('linking twice is refused; unlinking releases the grant and drops the index', () async {
      final settings = Directory('${tmp.path}/settings')..createSync();
      Directory('${tmp.path}/lib').createSync();
      final access = FakeFolderAccess();
      final lib = SampleLibrary(settingsDir: settings, access: access);
      final (lf, _) = await lib.link('${tmp.path}/lib', 'Lib');
      final (dup, error) = await lib.link('${tmp.path}/lib', 'Lib');
      expect(dup, isNull);
      expect(error, contains('linked already'));
      await lib.refresh(lf!.id);
      expect(File('${settings.path}/sample-index/${lf.id}.json').existsSync(), isTrue);
      await lib.unlink(lf.id);
      expect(lib.folders, isEmpty);
      expect(access.released, ['${tmp.path}/lib']);
      expect(File('${settings.path}/sample-index/${lf.id}.json').existsSync(), isFalse);
    });
    test('an unreachable folder says so', () async {
      final access = FakeFolderAccess()..reach = false;
      final lib = SampleLibrary(access: access);
      final (lf, _) = await lib.link('${tmp.path}/gone', 'Gone');
      await lib.refresh(lf!.id);
      expect(lib.reachable(lf.id), isFalse);
      expect(lib.progress[lf.id]!.error, contains('can\'t be reached'));
    });
    test('mergeListing reuses unchanged entries', () {
      final old = SampleEntry(root: 'r', rel: 'a.wav', size: 1, modified: 2)..bpm = 99;
      final m = mergeListing('r', const [ListedFile('a.wav', 1, 2), ListedFile('b.wav', 3, 4)], [old]);
      expect(identical(m.entries.first, old), isTrue);
      expect([for (final e in m.changed) e.rel], ['b.wav']);
      final changed = mergeListing('r', const [ListedFile('a.wav', 1, 5)], [old]);
      expect(changed.changed.single.bpm, isNull);
    });
  });

  group('filters', () {
    SampleEntry e(String rel, {double? bpm, MusicalKey? key, SampleKind? kind, SampleInstrument? inst, double? secs,
            ValueSource from = ValueSource.name, List<String> tags = const []}) =>
        SampleEntry(root: 'r', rel: rel)
          ..bpm = bpm
          ..bpmFrom = bpm == null ? null : from
          ..key = key
          ..keyFrom = key == null ? null : from
          ..kind = kind
          ..instrument = inst
          ..seconds = secs
          ..tags = tags;
    final all = [
      e('Loops/a.wav', bpm: 120, key: const MusicalKey(9, minor: true), kind: SampleKind.loop, inst: SampleInstrument.bass, secs: 8, tags: ['loop']),
      e('Loops/b.wav', bpm: 62, key: const MusicalKey(0), kind: SampleKind.loop, secs: 6.9),
      e('Loops/c.wav', bpm: 128, key: const MusicalKey(4, minor: true), from: ValueSource.detected, secs: 15),
      e('Hits/kick.wav', kind: SampleKind.oneShot, inst: SampleInstrument.kick, secs: 0.3),
      e('Hits/Deep/snare.wav', kind: SampleKind.oneShot, inst: SampleInstrument.snare, secs: 0.4),
    ];
    List<String> names(SampleQuery q) => [for (final x in q.apply(all)) x.name];

    test('tempo range, half and double, and estimates', () {
      final q = SampleQuery()
        ..bpmMin = 118
        ..bpmMax = 130;
      expect(names(q), ['a.wav', 'c.wav']);
      q.halfDouble = true;
      expect(names(q), ['a.wav', 'b.wav', 'c.wav']);
      q.estimates = false;
      expect(names(q), ['a.wav', 'b.wav']);
    });
    test('keys: exact, with relatives, with compatible keys', () {
      final q = SampleQuery()..keys.add(const MusicalKey(9, minor: true));
      expect(names(q), ['a.wav']);
      q.keyMatch = KeyMatch.relative;
      expect(names(q), ['a.wav', 'b.wav']);
      q.keyMatch = KeyMatch.compatible;
      expect(names(q), ['a.wav', 'b.wav', 'c.wav']);  // E minor is a fifth above A minor
    });
    test('type, instrument, length, folder, tags and search', () {
      expect(names(SampleQuery()..kinds.add(SampleKind.oneShot)), ['kick.wav', 'snare.wav']);
      expect(names(SampleQuery()..instruments.add(SampleInstrument.kick)), ['kick.wav']);
      expect(names(SampleQuery()..maxSeconds = 1), ['kick.wav', 'snare.wav']);
      expect(names(SampleQuery()..minSeconds = 7), ['a.wav', 'c.wav']);
      expect(names(SampleQuery()..folder = 'Hits'), ['kick.wav', 'snare.wav']);
      expect(names(SampleQuery()..folder = 'Hits/Deep'), ['snare.wav']);
      expect(names(SampleQuery()..tags.add('loop')), ['a.wav']);
      expect(names(SampleQuery()..text = 'loops am'), ['a.wav']);
      expect(names(SampleQuery()..text = 'bass'), ['a.wav']);
    });
    test('sorting puts unknown values last', () {
      final q = SampleQuery()..sort = SampleSort.bpm;
      expect(names(q).take(3), ['b.wav', 'a.wav', 'c.wav']);
      q.descending = true;
      expect(names(q).take(3), ['c.wav', 'a.wav', 'b.wav']);
      expect(names(q).last, isNot('a.wav'));
      final choices = filterChoices(all);
      expect(choices.minBpm, 62);
      expect(choices.maxBpm, 128);
      expect(choices.folders, ['Hits', 'Hits/Deep', 'Loops']);
    });
  });
}
