// Audio clips on tracks, as the app edits them: importing files into the project's storage, audio tracks, and every
// clip edit (move, trim, split, fades, gain, reverse, pitch, mode, takes), each one undo step.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../engine/audio_engine.dart';
import 'app_state.dart';
import 'audio_clips.dart';
import 'project.dart';

final Expando<AudioIo> _io = Expando('audio io');
final Expando<Set<String>> _unsized = Expando('clips waiting for their file length');

/// The audio file kinds the engine decodes.
const audioExtensions = ['wav', 'wave', 'flac', 'mp3'];

bool isAudioFileName(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && audioExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// A file name safe in the project's folder: letters, digits, space, dot, dash and underscore.
String safeAudioName(String name) {
  final clean = name.replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_').trim();
  return clean.isEmpty || clean.startsWith('.') ? 'audio$clean' : (clean.length > 96 ? clean.substring(clean.length - 96) : clean);
}

/// A clip on a track.
typedef PlacedAudioClip = ({LayerDoc layer, AudioClipDoc clip});

extension AudioEdit on AppState {
  /// The engine's audio side ([EngineAudioIo] by default); tests set a fake.
  AudioIo get audioIo => _io[this] ??= EngineAudioIo(() => engine);
  set audioIo(AudioIo io) => _io[this] = io;

  /// The project's audio folder (imports and recordings): in its storage, else a temporary folder.
  Directory get audioDirectory =>
      storage?.audioDirectory(project.id) ??
      Directory('${Directory.systemTemp.path}${Platform.pathSeparator}caw-audio${Platform.pathSeparator}${project.id}');

  Directory get recordingsDirectory => Directory('${audioDirectory.path}${Platform.pathSeparator}recordings');

  // ---------- importing ----------

  /// Copies a file into the project's audio folder a chunk at a time ([read] gives its bytes; [onProgress] the
  /// bytes copied), then has the engine decode it (off the UI isolate) and adds it to the project. Returns the asset,
  /// or throws a [FormatException] with the engine's reason when the file isn't audio it can read.
  Future<AudioAssetDoc> importAudio(String name, Stream<List<int>> Function() read,
      {void Function(int bytes)? onProgress, double? bpm}) async {
    final dir = audioDirectory;
    await dir.create(recursive: true);
    final base = safeAudioName(name);
    var out = File('${dir.path}${Platform.pathSeparator}$base');
    for (var n = 2; await out.exists(); n++) {
      out = File('${dir.path}${Platform.pathSeparator}${base.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' $n\$1')}');
    }
    final sink = out.openWrite();
    var copied = 0;
    try {
      await for (final chunk in read()) {
        sink.add(chunk);
        copied += chunk.length;
        if (copied > (1 << 30)) throw const FormatException('The file is over 1 GB.');
        onProgress?.call(copied);
      }
      await sink.close();
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await out.exists()) await out.delete();
      rethrow;
    }
    final info = await audioIo.loadAsset(out.path);
    if (!info.ok) {
      if (await out.exists()) await out.delete();
      throw FormatException(info.error.isEmpty ? 'The engine could not read this file.' : info.error);
    }
    return addAssetFor(out.path, name: name.replaceFirst(RegExp(r'\.[^.]*$'), ''), info: info, bpm: bpm ?? guessBpm(name));
  }

  /// Copies the file at [path] in ([importAudio]).
  Future<AudioAssetDoc> importAudioPath(String path, {void Function(int bytes)? onProgress}) =>
      importAudio(path.split(RegExp(r'[/\\]')).last, () => File(path).openRead(), onProgress: onProgress);

  /// Adds (or finds) the asset for a file already in app storage (a recording, a sample pack's WAV): no copy.
  AudioAssetDoc addAssetFor(String path, {String? name, AssetInfo? info, double? bpm, bool recorded = false,
      double seconds = 0}) {
    final known = project.assets.where((a) => a.path == path).firstOrNull;
    if (known != null) {
      if (info != null && info.ok) _fill(known, info);
      return known;
    }
    final asset = AudioAssetDoc(id: newId('a'), path: path,
        name: name ?? path.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.[^.]*$'), ''),
        bpm: bpm, recorded: recorded, seconds: seconds);
    if (info != null && info.ok) _fill(asset, info);
    editProject((p) => p.assets.add(asset));
    return asset;
  }

  void _fill(AudioAssetDoc a, AssetInfo info) {
    a.seconds = info.seconds;
    a.channels = info.channels;
    a.sourceRate = info.sourceRate;
  }

  /// A tempo in a file's name ("loop 120bpm.wav", "drums_95_bpm"), or null.
  static double? guessBpm(String name) {
    final m = RegExp(r'(\d{2,3}(?:\.\d+)?)\s*_?\s*bpm', caseSensitive: false).firstMatch(name);
    final v = m == null ? null : double.tryParse(m.group(1)!);
    return v != null && v >= 40 && v <= 300 ? v : null;
  }

  /// Reads an asset whose length isn't known yet (off the UI isolate), then sizes the clips made before it was.
  Future<void> measureAsset(AudioAssetDoc asset) async {
    if (asset.seconds > 0) return;
    final info = await audioIo.loadAsset(asset.path);
    if (!info.ok) return;
    _fill(asset, info);
    final waiting = _unsized[this] ??= {};
    editProject((p) {
      for (final l in p.layers) {
        for (final c in l.audioClips) {
          if (c.assetId == asset.id && waiting.remove(c.id)) {
            c.lengthSeconds = asset.seconds;
            c.mode = AudioClipMode.fixed;
          }
        }
      }
    });
  }

  // ---------- tracks and clips ----------

  /// A new audio track (with an input, so it can be armed) after [after], or at the end.
  LayerDoc addAudioTrack({String? name, LayerDoc? after}) {
    final p = project;
    final track = LayerDoc(id: newId('l'), name: name == null || name.isEmpty ? 'Audio ${p.layers.length + 1}' : name,
        color: p.layers.length % LayerDoc.trackColors, parentId: after?.parentId, volume: 1, input: AudioInputDoc());
    final at = after == null ? p.layers.length : p.layers.indexOf(after) + 1;
    editProject((p) => p.layers.insert(at.clamp(0, p.layers.length), track));
    return track;
  }

  /// Where audio dropped on [layer] goes: the track itself when it holds audio or nothing, else a new audio track
  /// under it (a track plays an instrument or audio, not both).
  LayerDoc audioTrackFor(LayerDoc layer, {String? name}) {
    if (layer.isFolder) {
      final inside = project.layers.where((l) => l.parentId == layer.id && !l.isFolder && _takesAudio(l)).firstOrNull;
      return inside ?? addAudioTrack(name: name, after: layer);
    }
    return _takesAudio(layer) ? layer : addAudioTrack(name: name, after: layer);
  }

  bool _takesAudio(LayerDoc l) => !l.isFolder && l.instrument == null && l.clips.isEmpty;

  /// Puts [asset] on [layer] (or the audio track [audioTrackFor] picks) at [atStep] (else after its last clip): a
  /// fixed clip as long as the file. Selects it and returns it.
  AudioClipDoc addAudioClip(LayerDoc layer, AudioAssetDoc asset, {double? atStep}) {
    final track = audioTrackFor(layer, name: asset.name);
    final end = track.audioClips.fold<double>(0, (v, c) => math.max(v, c.endAt(project.bpm)));
    final at = (atStep ?? end).clamp(0.0, project.maxArrangementSteps - 1.0).toDouble();
    final known = asset.seconds > 0;
    final clip = AudioClipDoc(id: newId('ac'), assetId: asset.id, startSteps: at,
        lengthSeconds: known ? asset.seconds : project.stepsPerBar * 15 / project.bpm);
    if (!known) (_unsized[this] ??= {}).add(clip.id);
    editLayer(track, (l) {
      l.audioClips.add(clip);
      l.input ??= AudioInputDoc();
    });
    selectAudioClip(track, clip);
    if (!known) unawaited(measureAsset(asset));
    return clip;
  }

  /// A drop from Files: [id] is a project asset's id, or the path of a WAV in app storage (a sample pack's).
  bool dropAudio(LayerDoc layer, String id, {int? atStep, double seconds = 0}) {
    final asset = project.asset(id) ??
        (File(id).isAbsolute ? addAssetFor(id, seconds: seconds) : null);
    if (asset == null || layer.isFolder && !project.layers.contains(layer)) return false;
    final snap = arrangementSnapSteps;
    addAudioClip(layer, asset, atStep: atStep == null ? null : ((atStep / snap).floor() * snap).toDouble());
    return true;
  }

  /// A drop on the empty area below the tracks: a new audio track with the clip.
  LayerDoc? dropAudioOnNewTrack(String id, {int? atStep, String? name}) {
    final track = addAudioTrack(name: name);
    if (dropAudio(track, id, atStep: atStep)) return track;
    removeLayer(track);
    return null;
  }

  Iterable<PlacedAudioClip> get allAudioClips sync* {
    for (final l in project.layers) {
      for (final c in l.audioClips) {
        yield (layer: l, clip: c);
      }
    }
  }

  PlacedAudioClip? audioClipById(String? id) => id == null ? null : allAudioClips.where((c) => c.clip.id == id).firstOrNull;

  /// The selected audio clips, in track then time order.
  List<PlacedAudioClip> get selectedAudioClips => [
        for (final c in allAudioClips)
          if (selectedClipIds.contains(c.clip.id)) c,
      ];

  /// The audio clip the inspector shows on [layer]: the selected one there, else its first.
  AudioClipDoc? focusedAudioClip(LayerDoc layer) =>
      layer.audioClips.where((c) => c.id == selectedClipId).firstOrNull ?? layer.audioClips.firstOrNull;

  /// Selects [clip] (with [additive], adds or removes it), as a MIDI clip's tap does.
  void selectAudioClip(LayerDoc layer, AudioClipDoc clip, {bool additive = false}) {
    if (!additive) selectedClipIds.clear();
    if (additive && selectedClipIds.remove(clip.id)) {
      if (selectedClipId == clip.id) selectedClipId = selectedClipIds.firstOrNull;
    } else {
      selectedClipIds.add(clip.id);
      selectedClipId = clip.id;
      selectedLayerId = layer.id;
    }
    clipSelectionChanged();
  }

  String audioClipName(AudioClipDoc clip) => clip.name ?? project.asset(clip.assetId)?.name ?? 'Missing audio';

  double? _assetBpm(AudioClipDoc c) => project.asset(c.assetId)?.bpm;
  double _assetSeconds(AudioClipDoc c) => project.asset(c.assetId)?.seconds ?? 0;

  /// One undo step of its own for an edit of [clip] (the inspector's and the clip's own controls).
  void editAudioClip(LayerDoc layer, AudioClipDoc clip, void Function(AudioClipDoc c) change) {
    endUndoStep();
    editLayer(layer, (_) => change(clip));
    endUndoStep();
  }

  void moveAudioClip(LayerDoc layer, AudioClipDoc clip, double start) => editAudioClip(layer, clip,
      (c) => c.startSteps = start.clamp(0.0, project.maxArrangementSteps - c.lengthAt(project.bpm)).toDouble());

  /// Moves (or with [copy] copies) [clip] onto [to] at [start]; [to] null: a new audio track at the end. A track that
  /// plays an instrument gets a new audio track under it instead.
  AudioClipDoc moveAudioClipTo(LayerDoc from, AudioClipDoc clip, LayerDoc? to, double start, {bool copy = false}) {
    final target = to == null ? addAudioTrack(name: audioClipName(clip)) : audioTrackFor(to, name: audioClipName(clip));
    final at = math.max(0.0, start);
    endUndoStep();
    AudioClipDoc placed = clip;
    editProject((_) {
      if (copy) {
        placed = clip.copyWith(id: newId('ac'), startSteps: at);
        target.audioClips.add(placed);
      } else {
        from.audioClips.remove(clip);
        clip.startSteps = at;
        target.audioClips.add(clip);
      }
      target.input ??= AudioInputDoc();
    });
    endUndoStep();
    selectAudioClip(target, placed);
    return placed;
  }

  void trimAudioClipStart(LayerDoc layer, AudioClipDoc clip, double start) => editAudioClip(layer, clip,
      (c) => trimAudioStart(c, start, bpm: project.bpm, assetBpm: _assetBpm(c)));

  void resizeAudioClipTo(LayerDoc layer, AudioClipDoc clip, double length) => editAudioClip(layer, clip,
      (c) => resizeAudioClip(c, length, _assetSeconds(c), bpm: project.bpm, assetBpm: _assetBpm(c)));

  void setAudioFades(LayerDoc layer, AudioClipDoc clip, {double? fadeIn, double? fadeOut, FadeCurve? inCurve,
      FadeCurve? outCurve}) => editAudioClip(layer, clip, (c) {
        final secs = c.lengthAt(project.bpm) * 15 / project.bpm;
        if (fadeIn != null) c.fadeIn = fadeIn.clamp(0.0, secs).toDouble();
        if (fadeOut != null) c.fadeOut = fadeOut.clamp(0.0, secs).toDouble();
        if (c.fadeIn + c.fadeOut > secs) {
          fadeIn != null ? c.fadeOut = secs - c.fadeIn : c.fadeIn = secs - c.fadeOut;
        }
        if (inCurve != null) c.fadeInCurve = inCurve;
        if (outCurve != null) c.fadeOutCurve = outCurve;
      });

  void setAudioGain(LayerDoc layer, AudioClipDoc clip, double gain) =>
      editAudioClip(layer, clip, (c) => c.gain = gain.clamp(0.0, AudioClipDoc.maxGain).toDouble());

  void reverseAudio(LayerDoc layer, AudioClipDoc clip) => editAudioClip(layer, clip,
      (c) => reverseAudioClip(c, _assetSeconds(c), bpm: project.bpm, assetBpm: _assetBpm(c)));

  void setAudioPitch(LayerDoc layer, AudioClipDoc clip, double semitones) =>
      editAudioClip(layer, clip, (c) => setAudioClipPitch(c, semitones));

  void setAudioMode(LayerDoc layer, AudioClipDoc clip, AudioClipMode mode) => editAudioClip(layer, clip,
      (c) => setAudioClipMode(c, mode, bpm: project.bpm, assetBpm: _assetBpm(c)));

  void setAudioStretch(LayerDoc layer, AudioClipDoc clip, AudioStretch stretch) => editAudioClip(layer, clip, (c) {
        if (c.stretch == stretch) return;
        final before = c.pitchRate;
        c.stretch = stretch;
        if (c.fixed) c.lengthSeconds *= before / c.pitchRate;
      });

  /// The source tempo a musical clip follows (the asset's when [asset] is true: every clip of the file).
  void setAudioSourceBpm(LayerDoc layer, AudioClipDoc clip, double bpm) =>
      editAudioClip(layer, clip, (c) => c.sourceBpm = bpm.clamp(20.0, 999.0).toDouble());

  void toggleAudioMute(LayerDoc layer, AudioClipDoc clip) => editAudioClip(layer, clip, (c) => c.mute = !c.mute);
  void toggleAudioLock(LayerDoc layer, AudioClipDoc clip) => editAudioClip(layer, clip, (c) => c.lock = !c.lock);

  void setAudioLoop(LayerDoc layer, AudioClipDoc clip, bool on) => editAudioClip(layer, clip, (c) {
        c.loop = on;
        if (!on) {
          final max = maxUnloopedSteps(c, _assetSeconds(c), bpm: project.bpm, assetBpm: _assetBpm(c));
          if (max > 0 && c.lengthAt(project.bpm) > max) c.setLength(max, project.bpm);
        }
      });

  /// Splits the selected audio clips under [at] (with none selected, every unlocked one there). The right parts
  /// become the selection. True when something was split.
  bool splitAudioClips(double at, {bool selectedOnly = true}) {
    final chosen = [
      for (final c in selectedAudioClips.isEmpty || !selectedOnly ? allAudioClips : selectedAudioClips)
        if (!c.clip.lock && c.clip.startSteps < at && c.clip.endAt(project.bpm) > at) c,
    ];
    if (chosen.isEmpty) return false;
    final rights = <PlacedAudioClip>[];
    endUndoStep();
    editProject((p) {
      for (final c in chosen) {
        final r = splitAudioClip(c.clip, at, newId('ac'), bpm: p.bpm, assetBpm: _assetBpm(c.clip),
            assetSeconds: _assetSeconds(c.clip));
        if (r == null) continue;
        c.layer.audioClips.add(r);
        rights.add((layer: c.layer, clip: r));
      }
    });
    endUndoStep();
    if (rights.isNotEmpty) {
      selectedClipIds
        ..clear()
        ..addAll(rights.map((r) => r.clip.id));
      selectedClipId = rights.first.clip.id;
      clipSelectionChanged();
    }
    return rights.isNotEmpty;
  }

  /// A copy right after [clip] (REAPER's Ctrl+D).
  AudioClipDoc duplicateAudioClip(LayerDoc layer, AudioClipDoc clip) {
    final copy = clip.copyWith(id: newId('ac'), startSteps: clip.endAt(project.bpm));
    endUndoStep();
    editLayer(layer, (l) => l.audioClips.add(copy));
    endUndoStep();
    selectAudioClip(layer, copy);
    return copy;
  }

  /// Copies of the selected audio clips after them as a block. True when something was copied.
  bool duplicateSelectedAudio() {
    final chosen = selectedAudioClips;
    if (chosen.isEmpty) return false;
    final lo = chosen.map((c) => c.clip.startSteps).reduce(math.min);
    final hi = chosen.map((c) => c.clip.endAt(project.bpm)).reduce(math.max);
    final copies = <String>[];
    endUndoStep();
    editProject((_) {
      for (final c in chosen) {
        final copy = c.clip.copyWith(id: newId('ac'), startSteps: c.clip.startSteps + hi - lo);
        c.layer.audioClips.add(copy);
        copies.add(copy.id);
      }
    });
    endUndoStep();
    selectedClipIds
      ..clear()
      ..addAll(copies);
    selectedClipId = copies.first;
    clipSelectionChanged();
    return true;
  }

  void removeAudioClip(LayerDoc layer, AudioClipDoc clip) {
    endUndoStep();
    editLayer(layer, (l) => l.audioClips.remove(clip));
    endUndoStep();
    selectedClipIds.remove(clip.id);
    clipSelectionChanged();
  }

  /// Deletes the selected unlocked audio clips. True when something went.
  bool deleteSelectedAudio() {
    final chosen = [for (final c in selectedAudioClips) if (!c.clip.lock) c];
    if (chosen.isEmpty) return false;
    endUndoStep();
    editProject((_) {
      for (final c in chosen) {
        c.layer.audioClips.remove(c.clip);
        selectedClipIds.remove(c.clip.id);
      }
    });
    endUndoStep();
    clipSelectionChanged();
    return true;
  }

  // ---------- takes ----------

  /// Plays take [index] of a loop-recorded clip (wrapping), one undo step.
  void selectAudioTake(LayerDoc layer, AudioClipDoc clip, int index) {
    if (clip.takes.length < 2) return;
    final id = clip.takes[index % clip.takes.length];
    if (id == clip.assetId || project.asset(id) == null) return;
    editAudioClip(layer, clip, (c) => c.assetId = id);
  }

  void stepAudioTake(LayerDoc layer, AudioClipDoc clip, int delta) {
    final i = clip.takes.indexOf(clip.assetId);
    selectAudioTake(layer, clip, (i < 0 ? clip.takes.length - 1 : i) + delta);
  }

  /// Arms or disarms [layer]'s input (giving it one first), one undo step.
  void setAudioArmed(LayerDoc layer, bool armed) => editInput(layer, (i) => i.armed = armed);

  void editInput(LayerDoc layer, void Function(AudioInputDoc input) change) {
    endUndoStep();
    editLayer(layer, (l) => change(l.input ??= AudioInputDoc()));
    endUndoStep();
  }

  /// The armed audio tracks.
  List<LayerDoc> get armedAudioTracks => [for (final l in project.layers) if (!l.isFolder && (l.input?.armed ?? false)) l];
}
