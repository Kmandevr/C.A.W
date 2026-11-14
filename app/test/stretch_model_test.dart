// Batch 1.0.4 (#208, #90) in the model: format v4's audio clip fields with bounded parsing (v3 loads unchanged), the
// stretch and Follows tempo rules, true widths on a tempo map, the engine JSON, the analysis maths, the sample
// editor's tools and Slice to MIDI (drum pads or sampler, one undo step).
import 'dart:convert';
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_analysis.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/drums.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sample_edit.dart';
import 'package:caw/model/sampler.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/tempo_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';

ProjectDoc stretchProject() => ProjectDoc(id: 'p', name: 'Stretch', bpm: 120, assets: [
      AudioAssetDoc(id: 'a1', path: '/abs/beat.wav', name: 'beat', seconds: 4, channels: 2, sourceRate: 44100),
      AudioAssetDoc(id: 'a2', path: '/abs/loop.wav', name: 'loop 100bpm', bpm: 100, seconds: 2, channels: 1,
          sourceRate: 48000),
    ], layers: [
      LayerDoc(id: 't1', name: 'Beat', color: 0, input: AudioInputDoc(), audioClips: [
        AudioClipDoc(id: 'c1', assetId: 'a1', startSteps: 16, lengthSeconds: 2, offsetSeconds: 0, gain: 1),
        AudioClipDoc(id: 'c2', assetId: 'a2', startSteps: 64, lengthSeconds: 2, loop: true, loopStart: 0.5,
            loopEnd: 1.5),
      ]),
    ]);

void main() {
  late AppState s;
  late FakeAudioAnalysis an;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = stretchProject();
    s.audioIo = FakeAudioIo();
    an = FakeAudioAnalysis();
    s.audioAnalysis = an;
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() => s.dispose());

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);
  AudioClipDoc clip(String id) => s.allAudioClips.firstWhere((c) => c.clip.id == id).clip;

  group('format v4', () {
    test('writes the contract\'s fields and reads them back, loop points in frames', () {
      final c = clip('c2')
        ..pitch = 3.25
        ..gain = dbToGain(-6)
        ..stretchRatio = 1.5
        ..fadeIn = 0.1
        ..fadeOutCurve = FadeCurve.sCurve
        ..fadeOut = 0.2
        ..sourceBpm = 100;
      final j = jsonDecode(jsonEncode(s.project.toJson())) as Map<String, dynamic>;
      expect(j['caw_app_project'], 4);
      final raw = (j['layers'] as List).first['audio_clips'][1] as Map<String, dynamic>;
      expect(raw['pitch_cents'], 325);
      expect(raw['gain_db'], closeTo(-6, 1e-3));
      expect(raw['stretch'], 1.5);
      expect(raw['stretch_mode'], 'wsola');
      expect(raw['follows_tempo'], isFalse);
      expect(raw['fade_out'], {'seconds': 0.2, 'curve': 's_curve'});
      expect(raw['loop_start'], 24000);
      expect(raw['loop_end'], 72000);
      expect(raw.containsKey('loop_start_seconds'), isFalse);
      final back = ProjectDoc.fromJson(j).layers.first.audioClips[1];
      expect(back.pitch, 3.25);
      expect(back.loopStart, closeTo(0.5, 1e-9));
      expect(back.loopEnd, closeTo(1.5, 1e-9));
      expect(back.stretchRatio, 1.5);
      expect(back.fadeOutCurve, FadeCurve.sCurve);
      expect(gainToDb(back.gain), closeTo(-6, 1e-3));
      expect(jsonEncode(ProjectDoc.fromJson(j).toJson()), jsonEncode(j), reason: 'a stable round trip');
      expect(c.sourceBpm, back.sourceBpm);
    });

    test('a v3 clip loads unchanged', () {
      final v3 = {
        'caw_app_project': 3, 'id': 'old', 'name': 'Old', 'bpm': 120,
        'assets': [{'id': 'a', 'path': '/abs/x.wav', 'name': 'x', 'seconds': 3, 'source_rate': 44100}],
        'layers': [{'id': 't', 'name': 'T', 'audio_clips': [{
          'id': 'c', 'asset': 'a', 'start_steps': 4, 'length_steps': 8, 'offset_seconds': 0.5, 'gain': 0.5,
          'fade_in_seconds': 0.05, 'fade_in_curve': 'fast', 'fade_out_seconds': 0.3, 'fade_out_curve': 'slow',
          'reverse': true, 'loop': true, 'loop_start_seconds': 0.25, 'loop_end_seconds': 1.25, 'pitch': -7,
          'mode': 'musical', 'stretch': 'varispeed', 'source_bpm': 90, 'mute': false}]}],
      };
      final c = ProjectDoc.fromJson(jsonDecode(jsonEncode(v3)) as Map<String, dynamic>).layers.single.audioClips.single;
      expect(c.gain, 0.5);
      expect((c.fadeIn, c.fadeInCurve, c.fadeOut, c.fadeOutCurve), (0.05, FadeCurve.fast, 0.3, FadeCurve.slow));
      expect((c.loopStart, c.loopEnd), (0.25, 1.25));
      expect(c.pitch, -7);
      expect(c.followsTempo, isTrue);
      expect(c.stretch, AudioStretch.varispeed);
      expect(c.stretchRatio, 1);
      expect(c.sourceBpm, 90);
      expect(c.lengthAt(120), 8);
    });

    test('parsing stays bounded', () {
      final c = AudioClipDoc.fromJson({
        'id': 'c', 'asset': 'a', 'stretch': 1e9, 'pitch_cents': -1e9, 'gain_db': 1e9, 'source_bpm': double.infinity,
        'fade_in': {'seconds': 1e12, 'curve': 7}, 'fade_out': 'nope', 'loop_start': -5, 'loop_end': 1e18,
        'follows_tempo': 'yes', 'takes': List.filled(1000, 't'),
      }, rate: 48000)!;
      expect(c.stretchRatio, AudioClipDoc.maxStretch);
      expect(c.pitchCents, -AudioClipDoc.maxPitchCents);
      expect(gainToDb(c.gain), closeTo(12, 1e-9));
      expect(c.sourceBpm, isNull);
      expect(c.fadeIn, 3600);
      expect(c.fadeInCurve, FadeCurve.linear);
      expect(c.fadeOut, 0);
      expect(c.loopStart, 0);
      expect(c.loopEnd, 3 * 3600);
      expect(c.followsTempo, isFalse);
      expect(c.takes.length, 64);
      expect(AudioClipDoc.fromJson({'id': 'c', 'asset': 'a', 'stretch': 0.01})!.stretchRatio, AudioClipDoc.minStretch);
      expect(AudioClipDoc.fromJson({'id': 'c', 'asset': 'a', 'stretch': double.nan})!.stretchRatio, 1);
    });

    test('a v5 file is refused whole', () {
      expect(() => ProjectDoc.fromJson({'caw_app_project': 5, 'id': 'x'}), throwsA(isA<NewerProjectFormat>()));
    });
  });

  group('stretch and tempo', () {
    test('the notch stretches between a quarter and four times, keeping the file part', () {
      final c = clip('c1');
      final source = c.sourceSeconds(120, null);
      s.stretchAudioClipTo(layer('t1'), c, 3);
      expect(c.stretchRatio, closeTo(1.5, 1e-9));
      expect(c.lengthSeconds, closeTo(3, 1e-9));
      expect(c.sourceSeconds(120, null), closeTo(source, 1e-9));
      s.stretchAudioClipTo(layer('t1'), c, 100);
      expect(c.stretchRatio, AudioClipDoc.maxStretch);
      expect(c.lengthSeconds, closeTo(8, 1e-9));
      expect(stretchLimits(c).$1, closeTo(0.5, 1e-9));
      expect(stretchLimits(c).$2, closeTo(8, 1e-9));
      expect(s.undo(), isTrue);
      expect(clip('c1').stretchRatio, closeTo(1.5, 1e-9));
    });

    test('Follows tempo needs a known source tempo', () {
      final c = clip('c1');
      expect(s.followsTempoBlocked(c), isNotNull);
      expect(s.setAudioFollowsTempo(layer('t1'), c, true), isFalse);
      expect(c.followsTempo, isFalse);
      s.setClipSourceBpm(layer('t1'), c, 128);
      expect(s.followsTempoBlocked(c), isNull);
      expect(s.setAudioFollowsTempo(layer('t1'), c, true), isTrue);
      expect(c.followsTempo, isTrue);
      expect(s.followsTempoBlocked(clip('c2')), isNull, reason: 'the file\'s tempo counts');
      s.setClipSourceBpm(layer('t1'), c, null);
      expect(c.followsTempo, isFalse, reason: 'clearing the tempo turns it off');
    });

    test('a detected tempo fills the clip and the file; unsure leaves it empty', () async {
      final c = clip('c1');
      final est = await s.detectClipTempo(layer('t1'), c);
      expect(est!.bpm, 120);
      expect(c.sourceBpm, 120);
      an.tempo = null;
      s.project.assets.first.bpm = null;
      expect(await s.detectAssetTempo(s.project.assets.first), isNull);
      expect(s.project.assets.first.bpm, isNull);
    });

    test('pitch is semitones and cents and never changes the length', () {
      final c = clip('c1');
      s.setAudioPitchCents(layer('t1'), c, 731);
      expect(c.pitch, 7.31);
      expect(c.lengthSeconds, 2);
      s.setAudioPitchCents(layer('t1'), c, 99999);
      expect(c.pitchCents, 2400);
    });

    test('a fixed clip spans its true width on a tempo map', () {
      final c = clip('c1');
      // 120 BPM to bar 2 (beat 4), then 60 BPM: the clip starts at beat 4, so its 2 s are 2 beats, 8 steps.
      s.project.tempoMap = [const TempoPoint(0, 120), const TempoPoint(4, 60)];
      expect(c.lengthAt(120), 16);
      expect(c.spanSteps(s.project.tempo), closeTo(8, 1e-9));
      final engine = jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>;
      expect(engine['layers'][0]['audio_clips'][0]['length_steps'], closeTo(8, 1e-9));
      final musical = AudioClipDoc(id: 'm', assetId: 'a1', lengthSteps: 12, mode: AudioClipMode.musical);
      expect(musical.spanSteps(s.project.tempo), 12);
    });

    test('the engine JSON: a stretched fixed clip plays as a musical one before C API 32', () {
      final c = clip('c1')..stretchRatio = 2;
      final old = c.toEngineJson(120, api: 31);
      expect(old['mode'], 'musical');
      expect(old['source_bpm'], 240);
      expect(old.containsKey('stretch_ratio'), isFalse);
      final now = c.toEngineJson(120, api: 32);
      expect(now['mode'], 'fixed');
      expect(now['stretch_ratio'], 2);
      expect(now['follows_tempo'], isFalse);
      c.stretchRatio = 1;
      expect(c.toEngineJson(120, api: 31)['mode'], 'fixed', reason: 'ratio 1 is the plain clip');
    });
  });

  group('analysis', () {
    List<double> hits(List<double> at, {double len = 4, double res = 0.005}) {
      final env = List<double>.filled((len / res).round(), 0.001);
      for (final t in at) {
        final i = (t / res).round();
        for (var k = 0; k < 40 && i + k < env.length; k++) {
          env[i + k] = math.max(env[i + k], math.exp(-k / 10));
        }
      }
      return env;
    }

    test('transients: more of them as the sensitivity rises', () {
      final env = hits([0.5, 1.0, 1.5, 2.0])..[(2.6 / 0.005).round()] = 0.12;
      final low = onsetBuckets(env, 0.0, 0.005), high = onsetBuckets(env, 1.0, 0.005);
      expect([for (final b in low) b * 0.005], [closeTo(0.5, 0.01), closeTo(1.0, 0.01), closeTo(1.5, 0.01), closeTo(2.0, 0.01)]);
      expect(high.length, greaterThan(low.length));
      expect(onsetBuckets(env, 1, 0.005, maxOnsets: 2).length, 2);
      expect(onsetBuckets(List.filled(100, 0.0), 1, 0.005), isEmpty);
    });

    test('the tempo of a steady beat; none from a few hits', () {
      final beat = [for (var t = 0.1; t < 8; t += 0.5) t];
      expect(tempoFromEnvelope(hits(beat, len: 8), 0.005)!.bpm, closeTo(120, 0.6));
      expect(tempoFromEnvelope(hits([0.3, 1.7]), 0.005), isNull);
    });
  });

  group('sample editor tools', () {
    test('Normalise sets the gain from the peak, one undo step', () async {
      final c = clip('c1');
      an.peakLevel = 0.25;
      final g = await s.normaliseAudioClip(layer('t1'), c);
      expect(gainToDb(g!), closeTo(12, 0.05), reason: '0.25 is −12 dB');
      expect(c.gain, g);
      an.peakLevel = 0;
      expect(await s.normaliseAudioClip(layer('t1'), c), isNull);
      expect(s.undo(), isTrue);
      expect(clip('c1').gain, 1);
    });

    test('Trim moves both ends in to the sound, keeping it in place', () async {
      final c = clip('c1');
      an.peakAt = (a, b) => b > 0.5 && a < 1.5 ? 0.8 : 0.0;
      expect(await s.trimAudioSilence(layer('t1'), c), isTrue);
      expect(c.offsetSeconds, closeTo(0.5, 2 / 64 + 1e-9));
      expect(c.startSteps, closeTo(16 + c.offsetSeconds * 8, 1e-6));
      expect(c.lengthSeconds, closeTo(1, 4 / 64));
      expect(s.undo(), isTrue);
      expect(clip('c1').offsetSeconds, 0);
    });

    test('loop handles set the loop points and turn the loop on', () {
      final c = clip('c1');
      s.setAudioLoopPoints(layer('t1'), c, 1.5, 0.5);
      expect((c.loop, c.loopStart, c.loopEnd), (true, 0.5, 1.5));
      s.setAudioLoopPoints(layer('t1'), c, 0, 4);
      expect(c.loopEnd, 0, reason: 'the file\'s end is 0');
    });

    test('Slice to MIDI: up to 16 slices go on drum pads, with a clip of their notes, one undo step', () {
      final before = jsonEncode(s.project.toJson());
      final tracks = s.project.layers.length;
      final c = clip('c1');
      final t = s.sliceToMidi(layer('t1'), c, [0.5, 1.0, 1.5])!;
      expect(s.project.layers.length, tracks + 1);
      expect(s.project.layers.indexOf(t), 1, reason: 'right under the audio track');
      final use = t.instrument!;
      expect(use.id, drumsComponentId);
      expect(use.params['a1_smp_on'], 1);
      expect(use.params['a1_smp_start'], 0);
      expect(use.params['a1_smp_end'], closeTo(0.125, 1e-9));
      expect(use.params['a4_smp_end'], closeTo(0.5, 1e-9), reason: 'the clip plays 2 s of the 4 s file');
      expect(use.params['a5_smp_on'], 0, reason: 'the rest of the bank is empty');
      expect(use.params['a1_body_on'], 0);
      expect(use.samples.length, 4);
      final mc = t.clips.single;
      expect(mc.startSteps, 16);
      final doc = [for (final n in PatternDoc.parse(s.project.module(mc.patternId)!.source).doc!.notes)
        (n.pitch.round(), n.at.toDouble())];
      expect(doc.map((n) => n.$1), [36, 37, 38, 39]);
      expect(doc.map((n) => n.$2), [0, 4, 8, 12], reason: '0.5 s is 4 steps at 120 BPM');
      expect(s.undo(), isTrue);
      expect(jsonEncode(s.project.toJson()), before);
    });

    test('Slice to MIDI: past 16 slices the sampler plays them', () {
      an.cuts = [for (var i = 1; i < 20; i++) i * 0.1];
      final c = clip('c1');
      final t = s.sliceToMidi(layer('t1'), c, an.cuts)!;
      expect(sliceTargetFor(20), SliceTarget.sampler);
      expect(t.instrument!.id, samplerComponentId);
      final zones = s.samplerState(t).zones;
      expect(zones.length, 20);
      expect((zones[1].loKey, zones[1].offset, zones[1].end), (37, 4410, 8819));
      expect(s.sliceBlocked(c..reverse = true), isNotNull);
    });
  });
}
