// Linked samples in a project (#229): the double tap's smart target, files used in place, links followed at open, Find it, export packaging and session paths never saved.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/drums.dart';
import 'package:caw/model/music_key.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/project_dependencies.dart';
import 'package:caw/model/project_package.dart';
import 'package:caw/model/sample_library.dart';
import 'package:caw/model/sample_names.dart';
import 'package:caw/model/sample_use.dart';
import 'package:caw/model/sampler.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/zip_archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'sample_fake.dart';

void main() {
  late Directory tmp;
  late AppState s;
  late SampleLibrary lib;
  late FakeFolderAccess access;
  late LinkedFolder lf;

  SampleEntry entry(String rel, {double? bpm, SampleKind? kind}) => SampleEntry(root: lf.id, rel: rel)
    ..bpm = bpm
    ..kind = kind
    ..seconds = 0.5;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('caw-sample-use');
    s = AppState(settings: Settings());
    s.audioIo = FakeAudioIo();
    s.samplePreview = FakePreview();
    access = FakeFolderAccess();
    lib = SampleLibrary(access: access);
    s.sampleLibrary = lib;
    writeTestWav('${tmp.path}/lib/Drums/Kick 01.wav', seconds: 0.5);
    writeTestWav('${tmp.path}/lib/Loops/Loop 120bpm.wav', seconds: 0.5);
    final (folder, _) = await lib.link('${tmp.path}/lib', 'Lib');
    lf = folder!;
    await lib.refresh(lf.id);
    s.project = ProjectDoc(id: 'p', name: 'P', bpm: 120, layers: []);
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  group('the double tap\'s target', () {
    test('nothing selected: a new audio track at the playhead, snapped', () async {
      s.arrangementSnapSteps = 4;
      s.pausedStep = 9.5;
      final t = s.sampleTarget();
      expect(t.kind, SampleTargetKind.newTrack);
      expect(t.atStep, 8);
      expect(t.label, 'Add on a new track');
      final e = lib.entry(lf.id, 'Loops/Loop 120bpm.wav')!;
      final line = await s.addSample(e, t);
      expect(line, contains('new track'));
      final track = s.project.layers.single;
      final clip = track.audioClips.single;
      expect(clip.startSteps, 8);
      final asset = s.project.asset(clip.assetId)!;
      // Used in place: the asset is the linked file itself, nothing was copied.
      expect(asset.path, '${tmp.path}/lib${Platform.pathSeparator}Loops${Platform.pathSeparator}Loop 120bpm.wav');
      expect(asset.link!.root, lf.id);
      expect(asset.link!.rel, 'Loops/Loop 120bpm.wav');
      expect(asset.bpm, 120);
      final copies = s.audioDirectory.existsSync()
          ? s.audioDirectory.listSync(recursive: true).where((f) => f.path.contains('Loop 120bpm'))
          : const <FileSystemEntity>[];
      expect(copies, isEmpty);
      // A second add reuses the asset.
      await s.addSample(e, s.sampleTarget());
      expect(s.project.assets.length, 1);
    });
    test('a selected audio track gets it at the playhead', () async {
      final track = s.addAudioTrack(name: 'Beats');
      s.selectedLayerId = track.id;
      s.pausedStep = 16;
      final t = s.sampleTarget();
      expect(t.kind, SampleTargetKind.audioTrack);
      expect(t.layer, track);
      await s.addSample(lib.entry(lf.id, 'Drums/Kick 01.wav')!, t);
      expect(track.audioClips.single.startSteps, 16);
      expect(s.project.layers.length, 1);
    });
    test('a track with an instrument gets a new audio track; drums and the sampler load it', () async {
      final synth = LayerDoc(id: 'syn', name: 'Synth', color: 0, instrument: ComponentUseDoc('org.caw.synth.flagship'));
      final drums = LayerDoc(id: 'dr', name: 'Drums', color: 1, instrument: ComponentUseDoc(drumsComponentId));
      final sampler = LayerDoc(id: 'sm', name: 'Sampler', color: 2, instrument: ComponentUseDoc(samplerComponentId));
      s.project.layers.addAll([synth, drums, sampler]);
      s.selectedLayerId = 'syn';
      expect(s.sampleTarget().kind, SampleTargetKind.newTrack);
      s.selectedLayerId = 'dr';
      final pad = s.sampleTarget(selectedPad: (_) => 5);
      expect(pad.kind, SampleTargetKind.drumPad);
      expect(pad.pad, 5);
      expect(pad.label, 'Load into pad 6');
      s.selectedLayerId = 'sm';
      final t = s.sampleTarget();
      expect(t.kind, SampleTargetKind.sampler);
      final e = lib.entry(lf.id, 'Drums/Kick 01.wav')!;
      await s.addSample(e, t);
      final zones = s.samplerState(sampler).zones;
      expect(zones.single.loKey, 0);
      expect(zones.single.hiKey, 127);
      expect(zones.single.root, 60);
      expect(zones.single.path, s.project.assets.single.path);
      await s.addSample(lib.entry(lf.id, 'Loops/Loop 120bpm.wav')!, t);
      expect(s.samplerState(sampler).zones.length, 1);  // the first zone covers every key: no free key
    });
  });

  group('links', () {
    test('a moved folder is followed when the project opens', () async {
      final e = lib.entry(lf.id, 'Drums/Kick 01.wav')!;
      await s.addSample(e, s.sampleTarget());
      final asset = s.project.assets.single;
      // The folder moves; the library is pointed at the new place (Find it's relink does this).
      final moved = Directory('${tmp.path}/moved');
      Directory('${tmp.path}/lib').renameSync(moved.path);
      lf.location = moved.path;
      await s.resolveLinkedSamples();
      expect(asset.path, '${moved.path}${Platform.pathSeparator}Drums${Platform.pathSeparator}Kick 01.wav');
    });
    test('a missing linked file: Find it relinks the whole folder by relative paths', () async {
      final asset = AudioAssetDoc(id: 'a1', path: '/nowhere/Drums/Kick 01.wav', name: 'Kick',
          link: const LinkedRef('lfOther', 'Drums/Kick 01.wav'));
      final other = AudioAssetDoc(id: 'a2', path: '/nowhere/Loops/Loop 120bpm.wav', name: 'Loop',
          link: const LinkedRef('lfOther', 'Loops/Loop 120bpm.wav'));
      s.project.assets.addAll([asset, other]);
      await s.checkMissingFiles();
      expect(s.missingLinkedAssets().length, 2);
      // A folder without those files changes nothing.
      Directory('${tmp.path}/empty').createSync();
      expect(await s.relinkLinkedFolder('lfOther', '${tmp.path}/empty', 'Empty'), 0);
      expect(lib.folder('lfOther'), isNull);
      // The right folder: this device now knows the project's folder by its id, and both files are found.
      writeTestWav('${tmp.path}/backup/Drums/Kick 01.wav');
      writeTestWav('${tmp.path}/backup/Loops/Loop 120bpm.wav');
      expect(await s.relinkLinkedFolder('lfOther', '${tmp.path}/backup', 'Backup'), 2);
      expect(lib.folder('lfOther')!.location, '${tmp.path}/backup');
      expect(File(asset.path).existsSync(), isTrue);
      expect(File(other.path).existsSync(), isTrue);
      expect(s.missingFiles, isEmpty);
    });
    test('Find it with a chosen file uses it in place', () async {
      final asset = AudioAssetDoc(id: 'a1', path: '/nowhere/x.wav', name: 'X', link: const LinkedRef('gone', 'x.wav'));
      s.project.assets.add(asset);
      await s.checkMissingFiles();
      expect(s.missingLinkedAssets(), [asset]);
      final elsewhere = writeTestWav('${tmp.path}/elsewhere/x.wav');
      await s.findLinkedFile(asset, elsewhere.path);
      expect(asset.path, elsewhere.path);
      expect(asset.link, isNull);  // not in a linked folder: an ordinary path now
      expect(s.missingFiles, isEmpty);
      // A file inside a linked folder keeps a link to it.
      await s.findLinkedFile(asset, '${tmp.path}/lib/Drums/Kick 01.wav');
      expect(asset.link!.root, lf.id);
      expect(asset.link!.rel, 'Drums/Kick 01.wav');
    });
  });

  group('export and saving', () {
    test('the export lists linked files and may package them', () async {
      await s.addSample(lib.entry(lf.id, 'Drums/Kick 01.wav')!, s.sampleTarget());
      final path = s.project.assets.single.path;
      expect(s.isProjectFile(path), isTrue);
      expect(s.isProjectFile('${tmp.path}/lib/Loops/Loop 120bpm.wav'), isFalse);  // linked, but not used
      final deps = scanProjectDependencies(s.project, isProjectFile: s.isProjectFile);
      final d = deps.singleWhere((d) => d.path == path);
      expect(d.linked, isTrue);
      expect(d.packageable, isTrue);
      expect(d.name, 'Kick 01.wav');
      expect(d.size, greaterThan(44));
      // Packaged: the file goes in the .caw by its own name; no device path travels with it.
      final out = await Directory('${tmp.path}/out').create();
      final caw = await s.writeProjectFile(deps, {d.key}, into: out);
      final zip = ZipReader.open(caw.path);
      try {
        expect(zip['assets/Kick 01.wav'], isNotNull);
        final packed = utf8.decode(zip.readBytes(zip['project.json']!));
        expect(packed, isNot(contains(tmp.path)));
      } finally {
        zip.close();
      }
    });
    test('a session handle is saved as its link and never trusted when read back', () {
      const link = LinkedRef('lf1', 'Pads/Warm.wav');
      final a = AudioAssetDoc(id: 'a', path: '/proc/self/fd/57', name: 'Warm', link: link);
      expect(a.toJson()['path'], '/caw-linked/lf1/Pads/Warm.wav');
      expect(AudioAssetDoc.fromJson(a.toJson())!.link!.rel, 'Pads/Warm.wav');
      sessionPathNames['/proc/self/fd/57'] = link.placeholder;
      final pad = jsonEncode({'samples': [{'slot': 0, 'path': '/proc/self/fd/57'}], 'other': '/proc/self/fd/570'});
      final saved = saveSessionPaths(pad);
      expect(saved, contains('/caw-linked/lf1/Pads/Warm.wav'));
      expect(saved, contains('/proc/self/fd/570'));  // a different handle is not touched by a prefix
      sessionPathNames.clear();
      // A project that names /proc or /dev itself: those become missing files before anything reads them.
      final p = ProjectDoc(id: 'q', name: 'Q', bpm: 120, layers: [], assets: [
        AudioAssetDoc(id: 'x', path: '/proc/self/fd/3', name: 'x'),
        AudioAssetDoc(id: 'y', path: '/dev/zero', name: 'y'),
      ]);
      expect(quarantineUnsafePaths(p, '/tmp/missing'), 2);
      expect(p.assets.every((a) => a.path.startsWith('/tmp/missing')), isTrue);
      expect(LinkedRef.fromJson({'root': 'lf1', 'rel': '../../etc/passwd'}), isNull);
      expect(LinkedRef.fromJson({'root': 'a b', 'rel': 'x.wav'}), isNull);
    });
  });

  group('preview helpers', () {
    test('the stretch to the project tempo, and a key estimate', () {
      expect(previewRatio(entry('a.wav', bpm: 90, kind: SampleKind.loop), 120), 0.75);
      expect(previewRatio(entry('a.wav', bpm: 90, kind: SampleKind.oneShot), 120), 1);
      expect(previewRatio(entry('a.wav', bpm: 90, kind: SampleKind.loop), 120, sync: false), 1);
      expect(previewRatio(entry('a.wav', bpm: 20, kind: SampleKind.loop), 120), 1);  // past 0.25
      final e = entry('pad.wav');
      applyKeyEstimate(e, {'ok': true, 'sure': false, 'tonic': 2, 'mode': 'minor'});
      expect(e.key, isNull);
      applyKeyEstimate(e, {'ok': true, 'sure': true, 'tonic': 2, 'mode': 'minor', 'confidence': 0.7});
      expect(e.key, const MusicalKey(2, minor: true));
      expect(e.keyFrom, ValueSource.detected);
      expect(e.keyConfidence, 0.7);
      applyKeyEstimate(entry('b.wav'), {'ok': true, 'sure': true, 'tonic': 44});
    });
    test('detection estimates a tonal file\'s key once', () async {
      final e = lib.entry(lf.id, 'Loops/Loop 120bpm.wav')!;
      e.instrument = SampleInstrument.pad;
      await s.detectSampleValues([e]);
      final fake = s.samplePreview as FakePreview;
      expect(fake.keyAsked.length, 1);
      expect(e.key, const MusicalKey(9, minor: true));
      expect(e.keyFrom, ValueSource.detected);
      await s.detectSampleValues([e]);
      expect(fake.keyAsked.length, 1);
      // A drum hit is never given a key.
      final kick = lib.entry(lf.id, 'Drums/Kick 01.wav')!;
      expect(kick.instrument, SampleInstrument.kick);
      await s.detectSampleValues([kick]);
      expect(fake.keyAsked.length, 1);
    });
  });
}
