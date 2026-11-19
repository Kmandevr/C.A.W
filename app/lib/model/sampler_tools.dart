// The sampler's tools through the engine (C API 43, docs/engine.md "Sampler tools"): drop and play (roots detected, the whole keyboard mapped), slicing a loop to keys or Drums pads, and multisample recording note by note.
import 'dart:async';
import 'dart:math' as math;

import 'app_state.dart';
import 'arrange_fx.dart';
import 'audio_edit.dart';
import 'drums.dart';
import 'project.dart';
import 'sampler.dart';

/// How dropped samples spread over the keys (the engine's `caw_sampler_map` modes).
enum DropMapping { auto, root, spread, keys }

String dropMappingLabel(DropMapping m) => switch (m) {
      DropMapping.auto => 'Fit to keyboard',
      DropMapping.root => 'By root',
      DropMapping.spread => 'Spread evenly',
      DropMapping.keys => 'One key each',
    };

/// What `caw_sampler_map` found: the zones, the mode it used and each sample's root (null: not sure).
class DropResult {
  const DropResult(this.zones, this.mode, this.roots, {this.error = ''});
  final List<SamplerZone> zones;
  final DropMapping mode;
  final List<int?> roots;
  final String error;
}

/// One slice of a file in its own frames, [start, end), and the key it plays on.
class SliceSpan {
  const SliceSpan(this.start, this.end, this.key);
  final int start, end, key;
}

class SliceResult {
  const SliceResult(this.zones, this.slices, this.frames, {this.error = ''});
  final List<SamplerZone> zones;
  final List<SliceSpan> slices;
  final int frames;
  final String error;
  bool get ok => error.isEmpty && zones.isNotEmpty;
}

/// A multisample recording plan: every [step] semitones from [lowKey] to [highKey], [layers] velocity layers each,
/// each note held [noteSeconds] then [gapSeconds] of silence, after [leadSeconds] to get ready.
class MultisamplePlan {
  MultisamplePlan({this.lowKey = 48, this.highKey = 72, this.step = 3, this.layers = 1, this.noteSeconds = 2,
      this.gapSeconds = 1, this.leadSeconds = 2});
  int lowKey, highKey, step, layers;
  double noteSeconds, gapSeconds, leadSeconds;

  static const maxNotes = 128;

  /// The velocity range of layer [i] (of [layers]): equal parts of 1..127, the loudest last.
  (int, int) velocities(int i) {
    final lo = (i * 127 / layers).floor() + 1, hi = ((i + 1) * 127 / layers).floor();
    return (lo, math.max(lo, hi));
  }

  /// The notes in the order they are asked for: each key, softest layer first.
  List<PlannedNote> get notes {
    final out = <PlannedNote>[];
    var t = leadSeconds;
    for (var k = lowKey; k <= highKey && out.length < maxNotes; k += math.max(1, step)) {
      for (var v = 0; v < layers && out.length < maxNotes; v++) {
        final (lo, hi) = velocities(v);
        out.add(PlannedNote(k, t, t + noteSeconds, lo, hi));
        t += noteSeconds + gapSeconds;
      }
    }
    return out;
  }

  double get seconds {
    final n = notes;
    return n.isEmpty ? 0 : n.last.end + gapSeconds;
  }
}

/// One note asked for: [key] played at [start] seconds of the take until [end], for velocities [loVel]..[hiVel].
class PlannedNote {
  const PlannedNote(this.key, this.start, this.end, this.loVel, this.hiVel);
  final int key, loVel, hiVel;
  final double start, end;

  /// The window the engine searches: from a little before the prompt into the gap after it.
  Map<String, dynamic> request(double gap) =>
      {'key': key, 'start_seconds': math.max(0.0, start - 0.3), 'end_seconds': end + gap * 0.8, 'lovel': loVel, 'hivel': hiVel};
}

/// What `caw_sampler_take` made: the zones and, per note, whether it was heard and in tune.
class TakeResult {
  const TakeResult(this.zones, this.found, this.inTune, {this.error = ''});
  final List<SamplerZone> zones;
  final List<bool> found, inTune;
  final String error;
}

List<SamplerZone> _zonesOf(Map<String, dynamic> j) {
  final st = j['state'];
  return st is Map<String, dynamic> ? SamplerState.fromJson(st).zones : const [];
}

/// The mapping without the engine (it could not read the files): one sample on every key at C4 (or its given root),
/// several spread evenly, each at its range's middle.
List<SamplerZone> fallbackMapping(List<String> paths, DropMapping mode, int startKey, {int? root}) {
  final n = paths.length;
  if (mode == DropMapping.keys) {
    return [for (var i = 0; i < n && startKey + i <= 127; i++)
      SamplerZone(path: paths[i], loKey: startKey + i, hiKey: startKey + i, root: startKey + i)];
  }
  if (n == 1) return [SamplerZone(path: paths.single, root: root ?? 60)];
  return [
    for (var i = 0; i < n; i++)
      SamplerZone(path: paths[i], loKey: i * 128 ~/ n, hiKey: (i + 1) * 128 ~/ n - 1, root: (i * 128 ~/ n + (i + 1) * 128 ~/ n) ~/ 2),
  ];
}

extension SamplerToolsEdit on AppState {
  /// Drop and play: [paths] mapped over the keyboard by the engine (roots detected unless [root] is given), or by
  /// [fallbackMapping] when the engine cannot. Never empty for a non-empty [paths].
  Future<DropResult> mapDroppedSamples(List<String> paths, {DropMapping mode = DropMapping.auto, int startKey = 36,
      int? root}) async {
    if (paths.isEmpty) return const DropResult([], DropMapping.auto, []);
    final list = paths.take(128).toList();
    final j = await audioIo.samplerTool('map', {
      'samples': [for (final p in list) {'path': p, 'root': ?root}],
      'mode': mode.name,
      'start_key': startKey,
    });
    final zones = j['ok'] == true ? _zonesOf(j) : const <SamplerZone>[];
    if (zones.isEmpty) {
      return DropResult(fallbackMapping(list, mode, startKey, root: root),
          mode == DropMapping.auto ? (list.length == 1 ? DropMapping.root : DropMapping.spread) : mode,
          List.filled(list.length, root), error: '${j['error'] ?? ''}');
    }
    final used = DropMapping.values.where((m) => m.name == j['mode']).firstOrNull ?? mode;
    final roots = [for (final s in (j['samples'] as List? ?? const [])) s is Map && s['root'] is num ? (s['root'] as num).toInt() : null];
    return DropResult(zones, used, roots);
  }

  /// Slices [path] by its transients or an equal grid of [divisions], to keys from [startKey].
  Future<SliceResult> sliceSample(String path, {bool grid = false, int divisions = 16, double sensitivity = 0.5,
      int startKey = 36}) async {
    final j = await audioIo.samplerTool('slice', {
      'path': path,
      'by': grid ? 'grid' : 'transients',
      'divisions': divisions.clamp(1, 128),
      'sensitivity': sensitivity.clamp(0.0, 1.0),
      'start_key': startKey.clamp(0, 127),
    });
    if (j['ok'] != true) return SliceResult(const [], const [], 0, error: '${j['error'] ?? 'the file could not be sliced'}');
    final slices = [
      for (final s in (j['slices'] as List? ?? const []))
        if (s is Map && s['start'] is num && s['end'] is num && s['key'] is num)
          SliceSpan((s['start'] as num).toInt(), (s['end'] as num).toInt(), (s['key'] as num).toInt()),
    ];
    return SliceResult(_zonesOf(j), slices, (j['frames'] as num?)?.toInt() ?? 0);
  }

  /// A new Drums track after [after] playing [slices] of [path] on its first pads (Kit mode, every other layer off),
  /// as Slice to MIDI does. One undo step.
  LayerDoc sendSlicesToDrums(String path, List<SliceSpan> slices, int frames, {String name = 'Slices', LayerDoc? after}) {
    endUndoStep();
    final track = addEmptyTrack(name: name);
    if (after != null) {
      editProject((p) {
        p.layers.remove(track);
        track.parentId = after.parentId;
        p.layers.insert((p.layers.indexOf(after) + 1).clamp(0, p.layers.length), track);
      });
    }
    setNativeInstrument(track, drumsComponentId);
    final used = slices.take(drumPadsPerBank).toList();
    editLayer(track, (l) {
      final use = l.instrument!;
      use.params['mode'] = 0;
      use.params['base_note'] = 36;
      for (var i = 0; i < drumPadsPerBank; i++) {
        final pad = padId(i);
        for (final layerName in drumSoundLayers) {
          use.params['${pad}_${layerName}_on'] = 0;
        }
        if (i < used.length && frames > 0) {
          use.params['${pad}_smp_on'] = 1;
          use.params['${pad}_smp_start'] = (used[i].start / frames).clamp(0.0, 1.0);
          use.params['${pad}_smp_end'] = (used[i].end / frames).clamp(0.0, 1.0);
        }
      }
      use.samples = [for (var i = 0; i < used.length; i++) ComponentSampleDoc(i, path: path)];
    });
    endUndoStep();
    return track;
  }

  /// Cuts a recorded take into zones by [plan]'s notes.
  Future<TakeResult> takeToZones(String takePath, MultisamplePlan plan) async {
    final notes = plan.notes;
    final j = await audioIo.samplerTool('take', {
      'path': takePath,
      'notes': [for (final n in notes) n.request(plan.gapSeconds)],
    });
    if (j['ok'] != true) return TakeResult(const [], const [], const [], error: '${j['error'] ?? 'the take could not be read'}');
    final res = (j['notes'] as List? ?? const []).whereType<Map>().toList();
    return TakeResult(_zonesOf(j), [for (final r in res) r['found'] == true], [for (final r in res) r['in_tune'] == true]);
  }
}
