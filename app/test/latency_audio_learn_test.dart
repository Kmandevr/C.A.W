// Learning the output latency from recorded audio takes: the take's transients (the engine's slices, faked here)
// placed where the take landed, measured against the click's beats, under the same thresholds as MIDI takes, and
// only ever offered as a suggestion; nothing is learned without the click.
import 'package:caw/engine/audio_engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/audio_record.dart';
import 'package:caw/model/latency_comp.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sample_edit.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/audio_route.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'audio_record_test.dart' show FakeMic;
import 'latency_comp_test.dart' show FakeRoute, device, mic, speaker;

RecordedAudioTake _take(int n, {double startSteps = 0, double seconds = 9, bool complete = true}) => RecordedAudioTake(
    layer: 'v', path: '/tmp/vox-take$n.wav', take: n, startSteps: startSteps, frames: (seconds * 48000).round(),
    seconds: seconds, channels: 1, sampleRate: 48000, bpm: 120, complete: complete);

/// Onsets (seconds of the file) on beats 1..16 of a take whose first frame lies at [startSteps], each [lateMs] off.
List<double> _onBeats(double lateMs, {double startSteps = 0}) => [
      for (var b = (startSteps / 4).floor() + 1; b <= (startSteps / 4).floor() + 16; b++)
        (b - startSteps / 4) * 0.5 + lateMs / 1000,
    ];

/// Every cut inside the span, whatever the sensitivity (what was asked is still kept).
class _AllCuts extends FakeAudioAnalysis {
  @override
  Future<List<double>?> slicePoints(String path,
      {required double start, required double end, required double sensitivity, int maxSlices = 64}) async {
    sensitivities.add(sensitivity);
    return [for (final c in cuts) if (c > start && c < end) c];
  }
}

void main() {
  late AppState s;
  late FakeAudioIo io;
  late _AllCuts an;
  late AudioRecorder rec;
  setUp(() async {
    s = AppState(settings: Settings(), audioRoute: FakeRoute(const AudioRouteInfo(output: speaker, input: mic)));
    s.project = ProjectDoc(id: 'rec', name: 'Rec', bpm: 120, loopBars: 4,
        layers: [LayerDoc(id: 'v', name: 'Vox', color: 0, input: AudioInputDoc())]);
    io = FakeAudioIo();
    s.audioIo = io;
    an = _AllCuts();
    s.audioAnalysis = an;
    s.latency.readDevice = () => device(outMs: 20);
    await s.latency.refresh();
    rec = AudioRecorder(s, permission: FakeMic(true), prefs: AudioInputPrefs());
  });
  tearDown(() {
    rec.dispose();
    s.dispose();
  });

  Future<void> record(List<RecordedAudioTake> takes) async {
    await rec.arm(s.project.layers.single, true);
    expect(await rec.start(), isTrue);
    io.stopTakes = takes;
    await rec.stop();
    await pumpEventQueue();
  }

  test('three takes played 20 ms late against the click suggest 20 ms more, never applied by itself', () async {
    expect(s.settings.metronome, Metronome.recording, reason: 'the click sounds while recording by default');
    an.cuts = _onBeats(20);
    await record([_take(1)]);
    await record([_take(2)]);
    expect(s.latency.store.evidence[speaker.key]!.takes, 2);
    expect(s.latency.outputSuggestion, isNull, reason: 'two takes are not enough');
    // The third take's first frame lies half a beat into the second bar (step 18): its onsets still land 20 ms
    // after the song's beats.
    an.cuts = _onBeats(20, startSteps: 18);
    await record([_take(3, startSteps: 18)]);
    final sug = s.latency.outputSuggestion!;
    expect(sug.takes, 3);
    expect(sug.onsets, 48);
    expect(sug.shiftMs, 20);
    expect(sug.totalMs, closeTo(40, 1e-9));
    expect(s.latency.outputMs, closeTo(20, 1e-9), reason: 'shown, not applied');
    expect(an.sensitivities, everyElement(0.5));
    s.latency.acceptSuggestion();
    expect(s.latency.outputMs, closeTo(40, 1e-9));
    expect(s.latency.outputOffset.source, OffsetSource.learned);
  });

  test('without the click nothing is learned', () async {
    s.settings.metronome = Metronome.off;
    an.cuts = _onBeats(20);
    for (var i = 1; i <= 3; i++) {
      await record([_take(i)]);
    }
    expect(s.latency.store.evidence, isEmpty);
    expect(an.sensitivities, isEmpty, reason: 'the takes are not even analysed');
  });

  test('the same thresholds: a small shift, or onsets split between early and late, suggest nothing', () async {
    an.cuts = _onBeats(5);
    for (var i = 1; i <= 3; i++) {
      await record([_take(i)]);
    }
    expect(s.latency.outputSuggestion, isNull, reason: 'a median of 5 ms is under 8');
    s.latency.dismissSuggestion();
    s.latency.store.evidence.clear();
    // Half 20 ms late, half 20 ms early: no side has 70 %.
    an.cuts = [for (var b = 1; b <= 16; b++) b * 0.5 + (b.isEven ? 0.020 : -0.019)];
    for (var i = 1; i <= 3; i++) {
      await record([_take(i)]);
    }
    expect(s.latency.store.evidence[speaker.key]!.takes, 3);
    expect(s.latency.outputSuggestion, isNull);
  });

  test('onsets off the beat, incomplete and recovered takes do not count', () async {
    an.cuts = [for (var b = 1; b <= 16; b++) b * 0.5 + 0.25]; // every one an eighth after its beat: 250 ms off
    expect(await rec.learnFromTakes([_take(1)]), 0);
    an.cuts = _onBeats(20);
    expect(await rec.learnFromTakes([_take(2, complete: false)]), 0);
    expect(await rec.learnFromTakes([
      const RecordedAudioTake(layer: 'v', path: '/tmp/r.wav', seconds: 9, sampleRate: 48000, recovered: true),
    ]), 0);
    expect(await rec.learnFromTakes([_take(3)]), 16);
  });
}
