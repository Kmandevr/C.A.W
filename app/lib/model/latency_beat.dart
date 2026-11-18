// The latency sheet's visual beat (owner, 2026-11-18, #241): where a click is between one heard click and the
// next, drawn with the playhead's own lead and output latency, from the song's metronome or, stopped, a click loop of
// its own on the engine's preview voice.
import 'dart:math' as math;
import 'dart:typed_data';

import 'playhead_clock.dart';
import 'tempo_map.dart';

/// The click loop's beat while stopped: 100 per minute, slow enough to see each click come.
const beatLoopSeconds = 0.6;

/// One beat of the click loop as a 16-bit mono WAV at [sampleRate]: a 12 ms click (1.5 kHz, decaying) at its very
/// start, then silence to [seconds]. Looped by the preview voice, it clicks once every [seconds] of the file.
Uint8List clickLoopWav({int sampleRate = 48000, double seconds = beatLoopSeconds}) {
  final n = (sampleRate * seconds).round();
  final data = ByteData(44 + n * 2);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  final click = (sampleRate * 0.012).round();
  for (var i = 0; i < click && i < n; i++) {
    final t = i / sampleRate;
    final v = math.sin(2 * math.pi * 1500 * t) * math.exp(-t / 0.003) * 0.7;
    data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Where a beat is in the song at sixteenth step [step]: 0 on a click of the metronome (each tick of the signature,
/// a 1/den note), rising to 1 just before the next. [signatures] in order, the first at beat 0 (as the project has).
double songBeatPhase(double step, List<TimeSignature> signatures) {
  final q = step / 4;
  var sig = signatures.isEmpty ? const TimeSignature(0, 0, 4, 4) : signatures.first;
  for (final s in signatures) {
    if (s.beat <= q) sig = s;
  }
  final x = (q - sig.beat) / sig.unitBeats;
  return x - x.floorToDouble();
}

/// The stopped sheet's click loop as heard: the preview voice's place in its one-beat file, read about 30 times a
/// second and run on between reads ([PlayheadClock], over seconds instead of steps), less the output latency, drawn
/// for the moment the frame lights up (the lead), exactly as the playhead is.
class LoopBeat {
  final PlayheadClock _clock = PlayheadClock();
  double _length = beatLoopSeconds;

  /// A read: the preview plays at [seconds] of a [length]-second file at [atUs] (playing false: it stopped).
  void read({required double seconds, required double length, required int atUs, required bool playing}) {
    if (length > 0) _length = length;
    _clock.read(step: seconds, atUs: atUs, playing: playing, stepsPerSecond: 1, from: 0, to: _length);
  }

  bool get running => _clock.running;

  /// The beat's phase heard at [nowUs] + [leadUs], [outputLatencyUs] after it was rendered: 0 on a click.
  double phase({required int nowUs, required int leadUs, required int outputLatencyUs}) {
    final rendered = _clock.at(nowUs + leadUs);
    final x = (rendered - outputLatencyUs / 1e6) / _length;
    return x - x.floorToDouble();
  }
}
