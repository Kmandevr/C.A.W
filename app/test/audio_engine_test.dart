// The audio side through the real engine (needs CAW_LIB): a generated WAV imported, its peaks read, a project with an
// audio clip accepted and rendered, and the sampler's SFZ export and import round trip.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/audio_engine.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sampler.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('caw-audio-engine'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('import decodes a WAV off the UI isolate and its peaks come back', () async {
    final e = Engine.create();
    final s = AppState(settings: Settings())..engine = e;
    s.project = ProjectDoc(id: 'p', name: 'A', bpm: 120);
    try {
      final wav = writeTestWav('${tmp.path}/sine.wav', seconds: 1.5, rate: 44100);
      final asset = await s.importAudioPath(wav.path);
      expect(asset.seconds, closeTo(1.5, 0.01));
      expect(asset.sourceRate, 44100);
      expect(asset.channels, 1);
      final peaks = await s.audioIo.peaks(asset.path, 0, asset.seconds, 64);
      expect(peaks, isNotNull);
      expect(peaks!.length, 128);
      // A half-scale sine: every bucket spans about -0.5..0.5.
      expect(peaks[1], closeTo(0.5, 0.02));
      expect(peaks[0], closeTo(-0.5, 0.02));
      final bad = File('${tmp.path}/bad.wav')..writeAsStringSync('RIFF not really');
      expect((await s.audioIo.loadAsset(bad.path)).ok, isFalse);

      final track = s.addAudioTrack(name: 'Audio');
      final clip = s.addAudioClip(track, asset, atStep: 0);
      expect(clip.lengthAt(120), closeTo(12, 0.1), reason: '1.5 s at 120 BPM');
      await e.setProject(s.project.toEngineJson());
      expect(e.lastProjectWarnings.where((w) => w.contains('audio')), isEmpty);

      final out = '${tmp.path}/render.wav';
      final job = RenderJob.start(RenderRequest(projectJson: s.project.toEngineJson(), kind: ExportKind.loop, outPath: out));
      expect(await job.result, isNull);
      final bytes = await File(out).readAsBytes();
      expect(bytes.skip(1000).take(20000).any((b) => b != 0), isTrue, reason: 'the clip sounds in the render');
    } finally {
      s.engine = null;
      s.dispose();
      e.dispose();
    }
  }, skip: skip);

  test('SFZ export with copied samples and import give the same zones back', () async {
    final e = Engine.create();
    final io = EngineAudioIo(() => e);
    try {
      final wav = writeTestWav('${tmp.path}/src/a3.wav', seconds: 0.25);
      final state = SamplerState([
        SamplerZone(path: wav.path, loKey: 48, hiKey: 59, root: 57, loVel: 1, hiVel: 100, volume: -3),
        SamplerZone(path: wav.path, loKey: 60, hiKey: 72, root: 64, loopMode: 'loop_continuous', loopStart: 100,
            loopEnd: 9000, seqLength: 2, seqPosition: 2),
      ]);
      final sfz = '${tmp.path}/out/kit.sfz';
      Directory('${tmp.path}/out').createSync();
      final exported = await io.sfzExport(jsonEncode(state.toJson()), sfz, copySamples: true);
      expect(exported.ok, isTrue, reason: exported.error);
      expect(File('${tmp.path}/out/samples/a3.wav').existsSync(), isTrue);
      final back = await io.sfzImport(sfz);
      expect(back.ok, isTrue, reason: back.error);
      expect(back.zones, 2);
      final zones = SamplerState.fromJson(back.state!).zones;
      expect(zones[0].loKey, 48);
      expect(zones[0].root, 57);
      expect(zones[0].hiVel, 100);
      expect(zones[0].volume, -3);
      expect(zones[1].loopMode, 'loop_continuous');
      expect(zones[1].loopEnd, 9000);
      expect(zones[1].seqPosition, 2);
      expect(zones[0].path, endsWith('samples${Platform.pathSeparator}a3.wav'));
      // The sampler plays from a project with that state.
      final p = ProjectDoc(id: 'p', name: 'S', layers: [
        LayerDoc(id: 'l', name: 'Sampler', color: 0,
            instrument: ComponentUseDoc(samplerComponentId)..state = base64Encode(utf8.encode(jsonEncode(back.state)))),
      ]);
      await e.setProject(p.toEngineJson());
      expect(e.lastProjectWarnings, isEmpty);
    } finally {
      e.dispose();
    }
  }, skip: skip);

  test('a fixed clip of a real file keeps its seconds through a tempo change', () {
    final c = AudioClipDoc(id: 'c', assetId: 'a', lengthSeconds: 1.5);
    expect(c.lengthAt(120), 12);
    expect(c.lengthAt(60), 6);
  });
}
