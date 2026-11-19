// The clip pitch editor through the real engine (C API 42; needs CAW_LIB): a synthetic sung phrase is decoded and analysed on a worker isolate, a note is moved up two semitones and rendered to a WAV, which analyses again with that note moved and the others kept; the render then goes into the project as a new take, one undo step.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/engine/pitch_clip_engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/pitch_clip.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sung-like phrase at [rate]: A3, C4 and D4 for 0.45 s each with 0.12 s rests, each a sawtooth-ish voice (eight
/// harmonics falling off) with 5.5 Hz vibrato of ±25 cents, a 40 ms swell in and out and a little breath noise.
Float32List sungPhrase(int rate) {
  const notes = [57.0, 60.0, 62.0];
  const len = 0.45, rest = 0.12;
  final frames = ((notes.length * (len + rest) + rest) * rate).round();
  final out = Float32List(frames);
  final rnd = math.Random(7);
  var t0 = rest;
  for (final n in notes) {
    final start = (t0 * rate).round(), count = (len * rate).round();
    var phase = 0.0;
    for (var i = 0; i < count; i++) {
      final t = i / rate;
      final midi = n + 0.25 * math.sin(2 * math.pi * 5.5 * t);
      phase += 440 * math.pow(2, (midi - 69) / 12) / rate;
      final env = math.min(1.0, math.min(t / 0.04, (len - t) / 0.04));
      var v = 0.0;
      for (var h = 1; h <= 8; h++) {
        v += math.sin(2 * math.pi * phase * h) / (h * 1.3);
      }
      out[start + i] = (0.3 * env * v + 0.004 * (rnd.nextDouble() - 0.5)).toDouble();
    }
    t0 += len + rest;
  }
  return out;
}

void main() {
  final lib = Platform.environment['CAW_LIB'] ?? '';
  test('analyse a sung phrase, move a note up two semitones, render and keep it as a take', () async {
    final dir = Directory.systemTemp.createTempSync('caw-pitch');
    final engine = Engine.create();
    addTearDown(() {
      engine.dispose();
      dir.deleteSync(recursive: true);
    });
    final rate = engine.sampleRate;
    final src = '${dir.path}/vox.wav';
    writeFloatWav(src, rate, [sungPhrase(rate)]);
    final backend = NativePitchClipBackend(() => engine);

    final job = backend.analyse(src);
    final seen = <double>[];
    job.progress.addListener(() {
      if (job.progress.value != null) seen.add(job.progress.value!);
    });
    final session = (await job.result)!;
    final a = session.analysis;
    expect(a.sampleRate, rate);
    expect(seen, isNotEmpty, reason: 'decoding reports its progress');
    expect(a.notes.length, 3, reason: '${[for (final n in a.notes) n.pitch]}');
    for (final (i, want) in [57.0, 60.0, 62.0].indexed) {
      expect(a.notes[i].pitch, closeTo(want, 0.1), reason: 'note $i');
    }
    expect(a.notes[1].vibratoCents, greaterThan(5), reason: 'the vibrato is found');
    expect(a.hops, greaterThan(100));
    expect(a.midi.where((m) => m > 0).length, greaterThan(a.hops ~/ 2));

    final out = '${dir.path}/pitch.wav';
    final r = (await backend.render(session, {1: const PitchNoteEdit(pitch: 2)}, out).result)!;
    expect(r.notesEdited, 1);
    expect(r.frames, a.frames);
    expect(File(out).existsSync(), isTrue);

    final again = (await backend.analyse(out).result)!;
    expect(again.analysis.notes.length, 3);
    expect(again.analysis.notes[0].pitch, closeTo(57, 0.1), reason: 'an unedited note is kept');
    expect(again.analysis.notes[1].pitch, closeTo(62, 0.15), reason: 'C4 + 2 = D4');
    expect(again.analysis.notes[2].pitch, closeTo(62, 0.1));
    backend.release(again);

    // A cancelled analysis gives nothing back.
    final cancelled = backend.analyse(src)..cancel();
    expect(await cancelled.result, isNull);

    // Into the project: a new take the clip plays, one undo step back to the original.
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    s.project = ProjectDoc(id: 'p', name: 'Pitch', assets: [AudioAssetDoc(id: 'a1', path: src, name: 'vox', seconds: a.seconds, channels: 1)],
        layers: [LayerDoc(id: 't1', name: 'Vox', color: 0, audioClips: [AudioClipDoc(id: 'c1', assetId: 'a1', lengthSeconds: a.seconds)])]);
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    final layer = s.project.layers.first, clip = layer.audioClips.first;
    final asset = s.applyPitchRender(layer, clip, r, target: PitchRenderTarget.newTake)!;
    expect(clip.assetId, asset.id);
    expect(clip.takes, ['a1', asset.id]);
    expect(s.project.asset(asset.id)!.path, out);
    expect(s.undo(), isTrue);
    expect(s.project.layers.first.audioClips.first.assetId, 'a1');
    backend.release(session);
  }, skip: lib.isEmpty ? 'set CAW_LIB to the built engine library' : null, timeout: const Timeout(Duration(minutes: 2)));
}
