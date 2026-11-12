// The music video tests' shared song (sixteen bars: drums, a riff from bar 9, a marker, a moving filter lane) and a
// stand-in song render that writes WAVs of the range's exact length at once.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:caw/model/music_video_meters.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/song_export.dart';

const videoTestBeat = '---\ncaw: 1\nkind: pattern\nname: Beat\nlength: 1 bar\n---\n0 C2 1 1\n4 D2 1 0.8\n8 C2 1 1\n12 D2 1 0.8\n';
const _riff = '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 1 bar\n---\n0 C4 2 1\n2 E4 2 0.7\n4 G4 2 0.9\n6 B4 2 1\n'
    '8 C5 2 1\n10 B4 2 0.6\n12 G4 2 1\n14 E4 2 0.8\n';

/// Sixteen bars: drums all through, a riff from bar 9 (a drop), a marker at bar 5, a filter lane moving in bars 5..8.
ProjectDoc videoTestSong() => ProjectDoc(id: 'p', name: 'Video test', bpm: 120, loopBars: 16, modules: [
      ModuleDoc(id: 'beat', name: 'Beat', source: videoTestBeat),
      ModuleDoc(id: 'riff', name: 'Riff', source: _riff),
    ], layers: [
      LayerDoc(id: 'drums', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'beat', lengthSteps: 256)],
          instrument: ComponentUseDoc('org.caw.synth.saw', {'cutoff': 0.5})),
      LayerDoc(id: 'lead', name: 'Lead', color: 2, clips: [ClipDoc(id: 'c2', patternId: 'riff', startSteps: 128, lengthSteps: 128)],
          instrument: ComponentUseDoc('org.caw.synth.saw', {'cutoff': 0.2})),
    ], automation: [
      ProjectAutomationLaneDoc(targetType: 'instrument', target: 'cutoff', layerId: 'drums', points: [
        AutomationPointDoc(step: 64, value: 0), AutomationPointDoc(step: 128, value: 1),
      ]),
    ], markers: [MarkerDoc(id: 'm1', name: 'Verse', startSteps: 64)]);

/// A song render that writes silent-ish WAVs of the exact range length at once.
class FakeVideoAudio implements SongRenderHandle {
  FakeVideoAudio(String requestJson) {
    final r = jsonDecode(requestJson) as Map<String, dynamic>;
    request = r;
    final steps = (r['end_steps'] as int) - (r['start_steps'] as int);
    final rate = r['sample_rate'] as int;
    final frames = (steps * 15 / 120 * rate).round();
    final dir = r['out_dir'] as String;
    final mix = File('$dir/mix.wav');
    writeTestWav(mix, sampleRate: rate, frames: frames, sample: (i, c) => 0.5 * math.sin(i * 0.05) * (i % 24000 < 12000 ? 1 : 0.1));
    final files = [
      {'path': mix.path, 'name': 'mix.wav', 'kind': 'mix', 'layer': '', 'frames': frames},
      if (r['tracks'] == true) ...[
        for (final id in ['drums', 'lead'])
          () {
            final f = File('$dir/$id.wav');
            writeTestWav(f, sampleRate: rate, frames: frames, sample: (i, c) => id == 'drums' ? 0.8 : 0.1);
            return {'path': f.path, 'name': '$id.wav', 'kind': 'track', 'layer': id, 'frames': frames};
          }(),
      ],
    ];
    result = Future.value(jsonEncode({'ok': true, 'error': '', 'files': files}));
  }
  late final Map<String, dynamic> request;
  @override
  double progress = 1;
  @override
  late final Future<String?> result;
  @override
  void cancel() {}
}

