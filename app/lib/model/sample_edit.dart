// The sample editor's and stretch notch's edits of an audio clip (batch 1.0.4, #208): stretch, Follows tempo, pitch
// in cents, the source tempo (detected or typed), Normalise, Trim, loop points, and Slice to MIDI, which makes a drums
// or sampler track and a MIDI clip that plays the slices. Every edit is one undo step; the file is never changed.
import 'dart:async';
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_fx.dart';
import 'audio_analysis.dart';
import 'audio_clips.dart';
import 'audio_edit.dart';
import 'drums.dart';
import 'pattern_doc.dart';
import 'project.dart';
import 'sampler.dart';

final Expando<AudioAnalysis> _analysis = Expando('audio analysis');

/// The part of its file a clip plays on its first pass, in seconds of the file: (from, to).
typedef SourceSpan = ({double from, double to});

/// Where Slice to MIDI puts the slices: the drum pads up to one bank, the sampler beyond.
enum SliceTarget { drums, sampler }

SliceTarget sliceTargetFor(int slices) => slices <= drumPadsPerBank ? SliceTarget.drums : SliceTarget.sampler;

/// Stretches [clip] (one that doesn't follow the tempo) to play [seconds]: the same part of the file, read at
/// [AudioClipDoc.minStretch]..[AudioClipDoc.maxStretch] its speed. Fades keep their seconds, inside the clip.
void stretchAudioClip(AudioClipDoc clip, double seconds) {
  if (!clip.fixed || clip.lengthSeconds <= 0) return;
  final ratio = (clip.stretchRatio * seconds / clip.lengthSeconds)
      .clamp(AudioClipDoc.minStretch, AudioClipDoc.maxStretch).toDouble();
  clip.lengthSeconds *= ratio / clip.stretchRatio;
  clip.stretchRatio = ratio;
  clip.fadeIn = math.min(clip.fadeIn, clip.lengthSeconds);
  clip.fadeOut = math.min(clip.fadeOut, clip.lengthSeconds - clip.fadeIn);
}

/// The longest and shortest a fixed clip can be stretched to, in seconds: (shortest, longest).
(double, double) stretchLimits(AudioClipDoc clip) {
  final source = clip.lengthSeconds / clip.stretchRatio;
  return (source * AudioClipDoc.minStretch, source * AudioClipDoc.maxStretch);
}

/// The part of the file [clip] plays on its first pass, at [bpm] (seconds of the file; reversed clips count from
/// the file's start too).
SourceSpan clipSourceSpan(AudioClipDoc clip, {required double bpm, double? assetBpm, double fileSeconds = 0}) {
  final used = clip.sourceSeconds(bpm, assetBpm);
  final end = fileSeconds > 0 ? fileSeconds : clip.offsetSeconds + used;
  if (clip.reverse) {
    final to = math.max(0.0, end - clip.offsetSeconds);
    return (from: math.max(0.0, to - used), to: to);
  }
  return (from: clip.offsetSeconds, to: math.min(end, clip.offsetSeconds + used));
}

/// Slice [i] of [points] (the cuts) inside [span]: its start and end in seconds of the file.
List<SourceSpan> slicesOf(SourceSpan span, List<double> points) {
  final cuts = [span.from, for (final p in points) if (p > span.from && p < span.to) p, span.to];
  return [for (var i = 0; i + 1 < cuts.length; i++) (from: cuts[i], to: cuts[i + 1])];
}

/// The first note Slice to MIDI plays (C2, the drum pads' first note).
const kSliceBaseNote = 36;

/// The pattern text of the slices played at their times in the clip: slice i is note [kSliceBaseNote] + i from
/// [lead] + its position (steps), until the next slice. [perStep] is seconds of the file a step of the clip reads.
String slicePattern(List<SourceSpan> slices, {required double from, required double perStep, double lead = 0,
    String name = 'Slices'}) {
  Steps steps(double v) => Steps((v * 960).round(), 960);
  final notes = <PatternNote>[];
  for (final (i, s) in slices.indexed) {
    final at = lead + (s.from - from) / perStep, len = (s.to - s.from) / perStep;
    notes.add(PatternNote(id: i, at: steps(at), len: Steps.max(steps(len), kMinNoteLength),
        pitch: (kSliceBaseNote + i).toDouble(), vel: 1));
  }
  final last = notes.fold(Steps.zero, (m, n) => Steps.max(m, n.end));
  final bars = math.max(1, (last / Steps(16)).ceil());
  return PatternDoc.blank(name: name, bars: bars).paste(PatternClip(notes, last), Steps.zero).doc.serialize();
}

extension SampleEdit on AppState {
  /// The analysis calls: the engine's C API 32 tempo detection and slices while an engine is running, the waveform
  /// peaks ([PeaksAudioAnalysis] over [audioIo]) otherwise and for the peak; a test may set its own.
  AudioAnalysis get audioAnalysis => _analysis[this] ??= _LiveAnalysis(this);
  set audioAnalysis(AudioAnalysis a) => _analysis[this] = a;

  double? _fileBpm(AudioClipDoc c) => project.asset(c.assetId)?.bpm;
  double _fileSeconds(AudioClipDoc c) => project.asset(c.assetId)?.seconds ?? 0;

  /// The source tempo [clip] knows: its own, else its file's (null: unknown, so it can't follow the tempo).
  double? knownSourceBpm(AudioClipDoc clip) => clip.sourceBpm ?? _fileBpm(clip);

  /// Why Follows tempo can't be turned on for [clip], or null when it can.
  String? followsTempoBlocked(AudioClipDoc clip) =>
      knownSourceBpm(clip) == null ? 'Set the clip\'s tempo first: it isn\'t known yet.' : null;

  /// The Follows tempo switch: on locks the clip to the bars from its source tempo (refused while that is unknown).
  bool setAudioFollowsTempo(LayerDoc layer, AudioClipDoc clip, bool on) {
    if (on && followsTempoBlocked(clip) != null) return false;
    if (clip.followsTempo == on) return true;
    editAudioClip(layer, clip, (c) {
      c.sourceBpm ??= _fileBpm(c);
      if (!on) {
        // Back to a fixed clip at ratio 1: as long as the file part it plays.
        c.stretchRatio = 1;
      }
      setAudioClipMode(c, on ? AudioClipMode.musical : AudioClipMode.fixed, bpm: project.bpm, assetBpm: _fileBpm(c));
    });
    return true;
  }

  /// The stretch notch's drop: [clip] plays [seconds] (one undo step).
  void stretchAudioClipTo(LayerDoc layer, AudioClipDoc clip, double seconds) =>
      editAudioClip(layer, clip, (c) => stretchAudioClip(c, seconds));

  /// Pitch in [cents] (−2400..2400): semitones and cents on the clip tab; the length stays.
  void setAudioPitchCents(LayerDoc layer, AudioClipDoc clip, int cents) => editAudioClip(layer, clip,
      (c) => setAudioClipPitch(c, cents.clamp(-AudioClipDoc.maxPitchCents, AudioClipDoc.maxPitchCents) / 100));

  /// Types in the clip's tempo (20–999 BPM), or clears it with null (Follows tempo then turns off).
  void setClipSourceBpm(LayerDoc layer, AudioClipDoc clip, double? bpm) => editAudioClip(layer, clip, (c) {
        if (bpm == null) {
          if (c.followsTempo) setAudioClipMode(c, AudioClipMode.fixed, bpm: project.bpm, assetBpm: _fileBpm(c));
          c.sourceBpm = null;
        } else {
          c.sourceBpm = (bpm.clamp(20.0, 999.0) * 100).round() / 100;
        }
      });

  /// Estimates [asset]'s tempo from its onsets (off the UI isolate in the engine) and keeps it when sure; returns it.
  Future<TempoEstimate?> detectAssetTempo(AudioAssetDoc asset) async {
    if (asset.seconds <= 0) return null;
    final est = await audioAnalysis.detectTempo(asset.path, seconds: asset.seconds);
    if (est != null && asset.bpm == null && project.assets.contains(asset)) {
      editProject((_) => asset.bpm = est.bpm);
    }
    return est;
  }

  /// Detects [clip]'s tempo and sets it on the clip (one undo step); null when unsure (nothing changes).
  Future<TempoEstimate?> detectClipTempo(LayerDoc layer, AudioClipDoc clip) async {
    final asset = project.asset(clip.assetId);
    if (asset == null || asset.seconds <= 0) return null;
    final est = await audioAnalysis.detectTempo(asset.path, seconds: asset.seconds);
    if (est != null && layer.audioClips.contains(clip)) setClipSourceBpm(layer, clip, est.bpm);
    return est;
  }

  /// Normalise: the gain that brings the clip's loudest sample to [targetDb] (at most +12 dB). Returns the gain set,
  /// or null when the file won't load or is silent.
  Future<double?> normaliseAudioClip(LayerDoc layer, AudioClipDoc clip, {double targetDb = 0}) async {
    final asset = project.asset(clip.assetId);
    if (asset == null) return null;
    final span = clipSourceSpan(clip, bpm: project.bpm, assetBpm: asset.bpm, fileSeconds: asset.seconds);
    final peak = await audioAnalysis.peak(asset.path, start: span.from, end: span.to, channels: math.max(1, asset.channels));
    if (peak == null || peak <= 1e-6 || !layer.audioClips.contains(clip)) return null;
    final gain = (dbToGain(targetDb) / peak).clamp(0.0, AudioClipDoc.maxGain).toDouble();
    setAudioGain(layer, clip, gain);
    return gain;
  }

  /// Trim: the clip's start and end move in to where its sound begins and ends (above [thresholdDb] of its peak),
  /// keeping the audio where it is in the song. False when there is nothing to trim.
  Future<bool> trimAudioSilence(LayerDoc layer, AudioClipDoc clip, {double thresholdDb = -48}) async {
    final asset = project.asset(clip.assetId);
    if (asset == null || clip.loop || clip.reverse) return false;
    final span = clipSourceSpan(clip, bpm: project.bpm, assetBpm: asset.bpm, fileSeconds: asset.seconds);
    final peakAll = await audioAnalysis.peak(asset.path, start: span.from, end: span.to);
    if (peakAll == null || peakAll <= 1e-6) return false;
    // The sound's edges: the first point where it rises (or the start), and the last bit still above the floor.
    final floor = peakAll * dbToGain(thresholdDb);
    final edges = await _soundEdges(asset.path, span, floor);
    if (edges == null) return false;
    return layer.audioClips.contains(clip) && trimAudioToSource(layer, clip, edges.from, edges.to);
  }

  Future<SourceSpan?> _soundEdges(String path, SourceSpan span, double floor) async {
    const n = 64; // 1/64 of the clip a read: the edges land within that
    final step = (span.to - span.from) / n;
    if (step <= 0) return null;
    int? first, last;
    for (var i = 0; i < n; i++) {
      final p = await audioAnalysis.peak(path, start: span.from + i * step, end: span.from + (i + 1) * step);
      if (p != null && p >= floor) {
        first ??= i;
        last = i;
      }
    }
    if (first == null) return null;
    return (from: span.from + first * step, to: span.from + (last! + 1) * step);
  }

  /// Trims [clip] to play [from]..[to] seconds of its file (on its first pass), the audio staying where it is in
  /// the song (one undo step). False when that is the whole clip already or out of it.
  bool trimAudioToSource(LayerDoc layer, AudioClipDoc clip, double from, double to) {
    final bpm = project.bpm, assetBpm = _fileBpm(clip);
    final span = clipSourceSpan(clip, bpm: bpm, assetBpm: assetBpm, fileSeconds: _fileSeconds(clip));
    final a = from.clamp(span.from, span.to).toDouble(), b = to.clamp(span.from, span.to).toDouble();
    final per = clip.sourcePerStep(bpm, assetBpm);
    if (per <= 0 || b - a < per * AudioClipDoc.minLengthSteps) return false;
    if ((a - span.from).abs() < 1e-6 && (b - span.to).abs() < 1e-6) return false;
    editAudioClip(layer, clip, (c) {
      final start = c.startSteps + (a - span.from) / per;
      trimAudioStart(c, start, bpm: bpm, assetBpm: assetBpm);
      resizeAudioClip(c, (b - a) / per, _fileSeconds(c), bpm: bpm, assetBpm: assetBpm);
    });
    return true;
  }

  /// The loop handles: [clip] loops [start]..[end] seconds of its file (turning its loop on), one undo step.
  void setAudioLoopPoints(LayerDoc layer, AudioClipDoc clip, double start, double end) =>
      editAudioClip(layer, clip, (c) {
        final file = _fileSeconds(c);
        final hi = file > 0 ? file : math.max(start, end);
        final a = math.min(start, end).clamp(0.0, hi).toDouble(), b = math.max(start, end).clamp(0.0, hi).toDouble();
        c.loop = true;
        c.loopStart = a;
        c.loopEnd = file > 0 && (b - file).abs() < 1e-6 ? 0 : b;
      });

  /// Slice to MIDI's cuts for [clip] at [sensitivity] (seconds of the file), for the live preview.
  Future<List<double>?> sliceCuts(AudioClipDoc clip, double sensitivity) async {
    final asset = project.asset(clip.assetId);
    if (asset == null) return null;
    final span = clipSourceSpan(clip, bpm: project.bpm, assetBpm: asset.bpm, fileSeconds: asset.seconds);
    final points = await audioAnalysis.slicePoints(asset.path, start: span.from, end: span.to, sensitivity: sensitivity);
    return points == null ? null : [for (final p in points) if (p > span.from && p < span.to) p];
  }

  /// Why Slice to MIDI can't run on [clip], or null when it can.
  String? sliceBlocked(AudioClipDoc clip) {
    final asset = project.asset(clip.assetId);
    if (asset == null) return 'The file is missing.';
    if (clip.reverse) return 'Turn Reverse off to slice.';
    return null;
  }

  /// Slice to MIDI: a new track playing the slices (on the drum pads up to 16, else the sampler) under [layer] and a
  /// MIDI clip that plays them at their times in [clip], all one undo step. Returns the new track, or null.
  LayerDoc? sliceToMidi(LayerDoc layer, AudioClipDoc clip, List<double> cuts) {
    final asset = project.asset(clip.assetId);
    if (asset == null || sliceBlocked(clip) != null) return null;
    final bpm = project.bpm;
    final span = clipSourceSpan(clip, bpm: bpm, assetBpm: asset.bpm, fileSeconds: asset.seconds);
    final slices = slicesOf(span, cuts).take(kMaxSlices).toList();
    if (slices.isEmpty) return null;
    final target = sliceTargetFor(slices.length);
    if (target == SliceTarget.sampler && asset.sourceRate <= 0) return null;
    final file = asset.seconds > 0 ? asset.seconds : span.to;
    final start = clip.startSteps.floor();
    final name = '${audioClipName(clip)} slices';
    final source = slicePattern(slices, from: span.from, perStep: clip.sourcePerStep(bpm, asset.bpm),
        lead: clip.startSteps - start, name: name);
    final module = ModuleDoc(id: newId('m'), name: name, source: source);
    endUndoStep();
    final track = addEmptyTrack(name: name);
    editProject((p) {
      p.modules.add(module);
      final at = p.layers.indexOf(layer) + 1;
      p.layers.remove(track);
      track.parentId = layer.parentId;
      p.layers.insert(at.clamp(0, p.layers.length), track);
    });
    if (target == SliceTarget.drums) {
      setNativeInstrument(track, drumsComponentId);
      editLayer(track, (l) {
        final use = l.instrument!;
        use.params['mode'] = 0; // Kit
        use.params['base_note'] = kSliceBaseNote.toDouble();
        for (var i = 0; i < drumPadsPerBank; i++) {
          final pad = padId(i);
          for (final layerName in drumSoundLayers) {
            use.params['${pad}_${layerName}_on'] = 0;
          }
          if (i < slices.length) {
            use.params['${pad}_smp_on'] = 1;
            use.params['${pad}_smp_start'] = (slices[i].from / file).clamp(0.0, 1.0);
            use.params['${pad}_smp_end'] = (slices[i].to / file).clamp(0.0, 1.0);
          }
        }
        use.samples = [for (var i = 0; i < slices.length; i++) ComponentSampleDoc(i, path: asset.path)];
      });
    } else {
      setNativeInstrument(track, samplerComponentId);
      final rate = asset.sourceRate;
      final zones = SamplerState([
        for (final (i, s) in slices.indexed)
          SamplerZone(path: asset.path, loKey: kSliceBaseNote + i, hiKey: kSliceBaseNote + i,
              root: kSliceBaseNote + i, offset: (s.from * rate).round(), end: math.max(1, (s.to * rate).round() - 1),
              loopMode: 'one_shot'),
      ]);
      editLayer(track, (l) {
        l.instrument!.state = zones.toBase64();
        l.instrument!.stateVersion = 1;
      });
    }
    addClip(track, module.id, startSteps: start);
    endUndoStep();
    return track;
  }
}

/// Opens [asset] in the sample editor: the clip to edit is the selected one playing it, else the first; null when no
/// clip plays it.
PlacedAudioClip? sampleEditorClipFor(AppState s, String assetId) {
  final selected = s.allAudioClips.where((c) => c.clip.assetId == assetId && s.selectedClipIds.contains(c.clip.id));
  return selected.firstOrNull ?? s.allAudioClips.where((c) => c.clip.assetId == assetId).firstOrNull;
}

/// Keeps a value future from going stale: only the newest request's answer is delivered.
class Latest<T> {
  int _gen = 0;

  Future<void> run(Future<T> Function() work, void Function(T value) done) async {
    final gen = ++_gen;
    final v = await work();
    if (gen == _gen) done(v);
  }

  void cancel() => _gen++;
}

/// [AudioAnalysis] over whichever engine [state] runs now (the app makes a new one on a rate change): the engine's
/// C API 32 calls through [EngineAudioAnalysis], or [PeaksAudioAnalysis] when there is none.
class _LiveAnalysis implements AudioAnalysis {
  _LiveAnalysis(this.state);
  final AppState state;

  AudioAnalysis get _now {
    final peaks = PeaksAudioAnalysis(state.audioIo);
    final e = state.engine;
    if (e == null || e.nativeAddress == null) return peaks;
    return EngineAudioAnalysis(tempo: e.assetTempo, slices: e.assetSlices, peaks: peaks);
  }

  @override
  Future<TempoEstimate?> detectTempo(String path, {required double seconds}) => _now.detectTempo(path, seconds: seconds);

  @override
  Future<List<double>?> slicePoints(String path,
          {required double start, required double end, required double sensitivity, int maxSlices = kMaxSlices}) =>
      _now.slicePoints(path, start: start, end: end, sensitivity: sensitivity, maxSlices: maxSlices);

  @override
  Future<double?> peak(String path, {required double start, required double end, int channels = 2}) =>
      _now.peak(path, start: start, end: end, channels: channels);
}
