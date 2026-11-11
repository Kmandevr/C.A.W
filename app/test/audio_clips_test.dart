// Audio clips in the model (API 18): the project round trip and engine JSON, import into the project's storage, the
// clip edits (trim, split, loop extend, reverse, mode, pitch), takes with negative starts, drops, and undo.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

ProjectDoc audioProject() => ProjectDoc(id: 'p', name: 'Audio', bpm: 120, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/loop.wav', name: 'loop', bpm: 120, seconds: 4, channels: 2),
    ], layers: [
      LayerDoc(id: 't1', name: 'Vox', color: 0, input: AudioInputDoc(armed: true), audioClips: [
        AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: 16, lengthSeconds: 2, offsetSeconds: 0.25, gain: 0.5,
            fadeIn: 0.01, fadeOut: 0.5, fadeOutCurve: FadeCurve.equalPower),
      ]),
      LayerDoc(id: 'k', name: 'Keys', color: 1, instrument: ComponentUseDoc('org.caw.flagship')),
    ]);

void main() {
  late AppState s;
  late FakeAudioIo io;
  late Directory tmp;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = audioProject();
    io = FakeAudioIo();
    s.audioIo = io;
    tmp = Directory.systemTemp.createTempSync('caw-audio-test');
  });
  tearDown(() {
    s.dispose();
    tmp.deleteSync(recursive: true);
  });

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  test('the project round trips audio assets, clips and inputs', () {
    final p = audioProject();
    final again = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(again.toJson()), jsonEncode(p.toJson()));
    final c = again.layers.first.audioClips.single;
    expect(c.lengthSeconds, 2);
    expect(c.fadeOutCurve, FadeCurve.equalPower);
    expect(again.layers.first.input!.armed, isTrue);
    expect(again.assets.single.bpm, 120);
    expect(again.layers.first.isAudio, isTrue);
    expect(again.layers[1].isAudio, isFalse);
  });

  test('the engine JSON names the assets, plays fixed clips at their seconds and drops unknown assets', () {
    final p = audioProject();
    p.layers.first.audioClips.add(AudioClipDoc(id: 'gone', assetId: 'missing', lengthSeconds: 1));
    final j = jsonDecode(p.toEngineJson()) as Map<String, dynamic>;
    expect(j['assets'], [{'id': 'a1', 'path': '/abs/loop.wav', 'bpm': 120}]);
    final l = (j['layers'] as List).first as Map;
    final clips = l['audio_clips'] as List;
    expect(clips, hasLength(1), reason: 'a clip of an unknown asset would refuse the project');
    expect(clips.single['length_steps'], 16, reason: '2 s at 120 BPM is 16 steps');
    expect(clips.single['fade_out_curve'], 'equal_power');
    expect(l['input'], {'channel': 0, 'channels': 1, 'monitor': 'auto', 'armed': true});
    expect(l.containsKey('instrument'), isFalse);
    // A tempo change keeps a fixed clip's time: twice the tempo, twice the steps.
    p.bpm = 240;
    final j2 = jsonDecode(p.toEngineJson()) as Map<String, dynamic>;
    expect((((j2['layers'] as List).first as Map)['audio_clips'] as List).single['length_steps'], 32);
    expect(p.arrangementEndSteps, greaterThanOrEqualTo(48));
  });

  test('importing copies the file into the project folder and adds the asset', () async {
    final src = writeTestWav('${tmp.path}/in/My loop 95bpm.wav', seconds: 0.5);
    final copyTo = await s.importAudioPath(src.path);
    expect(File(copyTo.path).existsSync(), isTrue);
    expect(copyTo.path, startsWith(s.audioDirectory.path));
    expect(copyTo.path, isNot(src.path));
    expect(copyTo.bpm, 95, reason: 'the tempo read from the name');
    expect(copyTo.seconds, 2, reason: 'what the engine reported');
    expect(s.project.assets.map((a) => a.id), contains(copyTo.id));
    // A second import of the same name gets its own file.
    final second = await s.importAudioPath(src.path);
    expect(second.path, isNot(copyTo.path));
    // A file the engine can't read is removed again and reported.
    io.failUnknown = true;
    io.seconds.clear();
    await expectLater(s.importAudioPath(src.path), throwsA(isA<FormatException>()));
    File(copyTo.path).deleteSync();
    File(second.path).deleteSync();
  });

  test('audio on an instrument track goes on a new audio track under it', () {
    final asset = s.project.asset('a1')!;
    final clip = s.addAudioClip(layer('k'), asset, atStep: 8);
    final track = s.project.layers[2];
    expect(track.audioClips.single, same(clip));
    expect(track.input, isNotNull);
    expect(layer('k').audioClips, isEmpty);
    expect(clip.lengthSeconds, 4, reason: 'as long as the file');
    expect(s.selectedClipIds, {clip.id});
  });

  test('a drop from Files puts a clip where it lands, and on the empty area a new audio track', () {
    s.arrangementSnapSteps = 16;
    expect(s.dropAsset(layer('t1'), const AssetDrag(AssetKind.audioFile, 'a1', 'loop'), atStep: 34), isTrue);
    expect(layer('t1').audioClips.last.startSteps, 32, reason: 'snapped to the bar grid');
    final made = s.dropOnNewTrack(const AssetDrag(AssetKind.audioFile, 'a1', 'loop'), atStep: 0);
    expect(made, isNotNull);
    expect(made!.audioClips.single.assetId, 'a1');
    expect(s.audioAssets.single.drag!.kind, AssetKind.audioFile);
    expect(s.folderAssets(s.folderAt('audio/files')!).single.name, 'loop');
  });

  test('trim, resize with loop extend, split, reverse and mode keep the audio in place', () {
    final l = layer('t1');
    final c = l.audioClips.single;
    // Left trim by 4 steps (0.5 s at 120 BPM): the offset follows.
    s.trimAudioClipStart(l, c, 20);
    expect(c.startSteps, 20);
    expect(c.offsetSeconds, closeTo(0.75, 1e-9));
    expect(c.lengthAt(120), closeTo(12, 1e-9));
    // It can't reach before the file's start.
    s.trimAudioClipStart(l, c, 0);
    expect(c.offsetSeconds, 0);
    expect(c.startSteps, closeTo(14, 1e-9));
    // Past the file's end it loops (REAPER's loop extend).
    s.resizeAudioClipTo(l, c, 64);
    expect(c.loop, isTrue);
    expect(c.lengthAt(120), 64);
    s.setAudioLoop(l, c, false);
    expect(c.lengthAt(120), closeTo(32, 1e-9), reason: 'back to the 4 s file');
    // Split in two: the right part reads on from where the left stops.
    s.selectAudioClip(l, c);
    expect(s.splitAudioClips(30), isTrue);
    final right = l.audioClips.firstWhere((x) => x.id != c.id);
    expect(c.lengthAt(120), closeTo(16, 1e-9));
    expect(right.startSteps, 30);
    expect(right.offsetSeconds, closeTo(2, 1e-9));
    expect(c.fadeOut, 0);
    expect(right.fadeIn, 0);
    // Reverse reads the same part of the file backwards: offset from the end.
    s.reverseAudio(l, right);
    expect(right.reverse, isTrue);
    expect(right.offsetSeconds, closeTo(0, 1e-9));
    // Musical: same length now, then locked to the bars.
    s.setAudioMode(l, c, AudioClipMode.musical);
    expect(c.sourceBpm, 120);
    expect(c.lengthAt(120), closeTo(16, 1e-9));
    expect(c.lengthAt(60), closeTo(16, 1e-9), reason: 'a musical clip keeps its steps');
    // Fixed varispeed: an octave up plays twice as fast, so half as long.
    s.setAudioMode(l, c, AudioClipMode.fixed);
    s.setAudioStretch(l, c, AudioStretch.varispeed);
    s.setAudioPitch(l, c, 12);
    expect(c.lengthAt(120), closeTo(8, 1e-9));
  });

  test('fades stay inside the clip, and every edit is an undo step', () {
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    final l = layer('t1');
    final c = l.audioClips.single;
    s.setAudioFades(l, c, fadeIn: 5);
    expect(c.fadeIn, 2, reason: 'no longer than the clip');
    expect(c.fadeOut, 0);
    s.setAudioGain(l, c, 10);
    expect(c.gain, AudioClipDoc.maxGain);
    expect(s.undo(), isTrue);
    expect(layer('t1').audioClips.single.gain, 0.5);
    expect(gainDb(1), '0.0 dB');
    expect(gainDb(0), '-inf dB');
  });

  test('a take recorded before the song start is trimmed to start at 0', () {
    final c = clipForTake(id: 'x', assetId: 'a', startSteps: -2, seconds: 3, bpm: 120);
    expect(c.startSteps, 0);
    expect(c.offsetSeconds, closeTo(0.25, 1e-9));
    expect(c.lengthSeconds, closeTo(2.75, 1e-9));
    final late = clipForTake(id: 'y', assetId: 'a', startSteps: 15.5, seconds: 1, bpm: 120);
    expect(late.startSteps, 15.5);
    expect(late.offsetSeconds, 0);
  });

  test('duplicate, delete and takes', () {
    final l = layer('t1');
    final c = l.audioClips.single;
    final copy = s.duplicateAudioClip(l, c);
    expect(copy.startSteps, 32);
    s.selectAudioClip(l, copy);
    expect(s.deleteSelectedAudio(), isTrue);
    expect(l.audioClips, hasLength(1));
    s.editProject((p) => p.assets.add(AudioAssetDoc(id: 'a2', path: '/abs/take2.wav', name: 'take 2')));
    c.takes = ['a1', 'a2'];
    s.stepAudioTake(l, c, 1);
    expect(c.assetId, 'a2');
    s.stepAudioTake(l, c, 1);
    expect(c.assetId, 'a1');
  });
}
