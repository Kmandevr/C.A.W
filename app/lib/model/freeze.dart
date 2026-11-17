// Freeze and bounce to audio (1.0.5, #209): a track's instrument and effects rendered before its fader, off the UI
// isolate with progress and cancel, then played in their place (freeze) or put on a new audio track (bounce).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'app_state.dart';
import 'audio_clips.dart';
import 'audio_edit.dart';
import 'project.dart';
import 'routing.dart';
import 'song_export.dart' show SongRenderHandle, SongRenderStarter, startNativeSongRender;

/// Starts a track render (the engine's caw_render_song on the native worker pool); tests swap in a fake.
SongRenderStarter trackRenderStarter = startNativeSongRender;

/// The longest tail a track render runs past its range: it ends sooner, once the track has been quiet
/// (below [freezeSilenceDb]) for half a second.
const double freezeMaxTailSeconds = 30;
const double freezeSilenceDb = -120;

/// What a freeze or bounce render is called on disk: the engine writes `<name>.wav` into the project's audio folder.
const String frozenFilePrefix = 'frozen_', bounceFilePrefix = 'bounce_';

/// A running freeze or bounce: its progress (0..1), a way to stop it, and its end ([done]: null when it was applied,
/// else why not: 'cancelled' or the engine's error).
class TrackRenderJob {
  TrackRenderJob._(this._handle, this.done);
  final SongRenderHandle? _handle;
  final Future<String?> done;
  double get progress => _handle?.progress ?? 0;
  void cancel() => _handle?.cancel();
}

extension Freeze on AppState {
  /// A track that can be frozen or bounced: one with an instrument or audio clips, not recording its input.
  bool canRenderTrack(LayerDoc l) => !l.isFolder && (l.instrument != null || l.audioClips.isNotEmpty) &&
      !(l.input?.armed ?? false);

  /// An edit is about to change frozen track [l] (its notes, devices or the automation of them): true, and the
  /// screens are asked to offer "Unfreeze to edit?" ([AppState.onFrozenEdit]), when it is frozen; the edit is not
  /// made. A track whose freeze no longer plays (the tempo changed) is edited freely.
  bool guardFrozen(LayerDoc? l) {
    if (l == null || !project.playsFrozen(l)) return false;
    onFrozenEdit?.call(l);
    return true;
  }

  /// [guardFrozen] for an edit of pattern [patternId]: every track playing it.
  bool guardFrozenPattern(String patternId) {
    for (final l in project.layers) {
      if (l.clips.any((c) => c.patternId == patternId || c.takes.contains(patternId)) && guardFrozen(l)) return true;
    }
    return false;
  }

  /// Freezes [l]: renders its instrument and effects (automation included) before its fader over the whole song,
  /// tail included, into the project's audio folder, then plays that file in their place. One undo step.
  TrackRenderJob freezeTrack(LayerDoc l) => _render(l, prefix: frozenFilePrefix, apply: (path, seconds, rate, layer) {
        final asset = AudioAssetDoc(id: newId('a'), path: path, name: 'Frozen · ${layer.name}', seconds: seconds,
            channels: 2, sourceRate: rate);
        editProject((p) {
          p.assets.add(asset);
          layer
            ..frozenAsset = asset.id
            ..frozenContext = p.freezeContext;
        });
        endUndoStep();
      });

  /// Unfreezes [l]: its instrument and effects play again and the frozen file leaves the project (deleted from
  /// disk when the project next opens and nothing names it, so undo can bring the freeze back). One undo step.
  void unfreezeTrack(LayerDoc l) {
    if (!l.frozen) return;
    final id = l.frozenAsset;
    editProject((p) {
      l
        ..frozenAsset = null
        ..frozenContext = null;
      if (p.layers.every((x) => x.frozenAsset != id) &&
          p.layers.every((x) => x.audioClips.every((c) => c.assetId != id && !c.takes.contains(id)))) {
        p.assets.removeWhere((a) => a.id == id);
      }
    });
    endUndoStep();
  }

  /// Bounce to audio: [l]'s instrument and effects over its clips' span (the song without clips), tail included,
  /// as one clip on a new audio track under it with its fader, pan, sends and folder; [l] is muted. One undo step.
  TrackRenderJob bounceTrack(LayerDoc l) {
    final span = _clipSpan(l, l.clips);
    return _render(l, prefix: bounceFilePrefix, start: span?.$1, end: span?.$2,
        apply: (path, seconds, rate, layer) => _addBounce(layer, path, seconds, rate, span?.$1 ?? 0, muteTrack: true));
  }

  /// Bounce to audio of [clips] (on track [l]): just those clips through the track over their span, tail included,
  /// onto a new audio track under it at the same position; the clips are muted. One undo step.
  TrackRenderJob bounceClips(LayerDoc l, List<ClipDoc> clips) {
    final ids = {for (final c in clips) c.id};
    final span = _clipSpan(l, clips);
    if (span == null) return TrackRenderJob._(null, Future.value('no clips to bounce'));
    return _render(l, prefix: bounceFilePrefix, start: span.$1, end: span.$2,
        only: (copy) => copy.clips.removeWhere((c) => !ids.contains(c.id)),
        apply: (path, seconds, rate, layer) => _addBounce(layer, path, seconds, rate, span.$1,
            muteClips: ids));
  }

  /// [clips]' span in whole steps (audio clips with the MIDI ones when [clips] is the track's); null for none.
  (int, int)? _clipSpan(LayerDoc l, List<ClipDoc> clips) {
    final starts = [for (final c in clips) c.startSteps,
      if (identical(clips, l.clips)) for (final a in l.audioClips) a.startSteps.floor()];
    final ends = [for (final c in clips) c.startSteps + c.lengthSteps,
      if (identical(clips, l.clips)) for (final a in l.audioClips) a.endAt(project.bpm).ceil()];
    if (starts.isEmpty) return null;
    return (starts.reduce(math.min).clamp(0, project.maxArrangementSteps - 1),
        ends.reduce(math.max).clamp(1, project.maxArrangementSteps));
  }

  void _addBounce(LayerDoc source, String path, double seconds, int rate, int at,
      {bool muteTrack = false, Set<String> muteClips = const {}}) {
    final asset = AudioAssetDoc(id: newId('a'), path: path, name: '${source.name} (bounce)', seconds: seconds,
        channels: 2, sourceRate: rate);
    final track = LayerDoc(
      id: newId('l'), name: '${source.name} (bounce)', color: source.color, ownColor: source.ownColor,
      parentId: source.parentId, volume: source.volume, pan: source.pan,
      sends: SendDoc.listFromJson([for (final s in source.sends) s.toJson()]),
      automation: [for (final a in source.automation) AutomationLaneDoc.fromJson(a.toJson())],
      audioClips: [AudioClipDoc(id: newId('ac'), assetId: asset.id, startSteps: at.toDouble(), lengthSeconds: seconds)],
    );
    editProject((p) {
      p.assets.add(asset);
      p.layers.insert(p.layers.indexOf(source) + 1, track);
      if (muteTrack) source.mute = true;
      for (final c in source.clips) {
        if (muteClips.contains(c.id)) c.mute = true;
      }
    });
    endUndoStep();
  }

  /// Renders [l] before its fader over [start]..[end] (the song when null) plus its tail, from a copy of the project
  /// where [l] plays live, unmuted and nothing is soloed; [only] trims [l]'s copy (a clip bounce). On success, and
  /// when [l] is still there as it was, [apply] gets the file; otherwise the file is deleted.
  TrackRenderJob _render(LayerDoc l, {required String prefix, int? start, int? end, void Function(LayerDoc copy)? only,
      required void Function(String path, double seconds, int rate, LayerDoc layer) apply}) {
    final opened = project;
    final before = jsonEncode(l.toJson());
    final copy = ProjectDoc.fromJson(jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>);
    for (final x in copy.layers) {
      x.solo = false;
      if (x.id != l.id) continue;
      x
        ..mute = false
        ..frozenAsset = null
        ..frozenContext = null;
      only?.call(x);
    }
    final rate = settings.sampleRate;
    final dir = audioDirectory;
    final name = '$prefix${l.id}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final request = {
      'out_dir': dir.path, 'project': 'track', 'pattern': name, 'mix': false, 'layers': [l.id],
      'stem_tap': 'pre', 'stems_through_master': false, 'bit_depth': 32, 'sample_rate': rate,
      if (start != null && end != null) ...{'bounds': 'selection', 'start_steps': start, 'end_steps': end}
      else 'bounds': 'song',
      'tail': 'silence', 'tail_seconds': freezeMaxTailSeconds, 'silence_db': freezeSilenceDb,
    };
    SongRenderHandle? handle;
    try {
      dir.createSync(recursive: true);
      handle = trackRenderStarter(engineJsonOf(copy), jsonEncode(request));
    } catch (e) {
      return TrackRenderJob._(null, Future.value('$e'));
    }
    Future<String?> finish() async {
      final out = await handle!.result;
      Object? parsed;
      try {
        parsed = out == null ? null : jsonDecode(out);
      } catch (_) {}
      if (parsed is! Map || parsed['ok'] != true) {
        return parsed is Map ? (parsed['error'] as String? ?? 'the render failed') : (out ?? 'the render failed');
      }
      final files = parsed['files'];
      final file = files is List && files.isNotEmpty && files.first is Map ? files.first as Map : null;
      final path = file?['path'], frames = file?['frames'];
      if (path is! String || frames is! num) return 'the render wrote no file';
      final layer = identical(project, opened) ? project.layers.where((x) => x.id == l.id).firstOrNull : null;
      if (layer == null || jsonEncode(layer.toJson()) != before) {
        try {
          File(path).deleteSync();
        } catch (_) {}
        return 'the track changed while it rendered; nothing was changed';
      }
      apply(path, frames / rate, rate, layer);
      return null;
    }
    return TrackRenderJob._(handle, finish());
  }

  /// Freezes whose file is gone (a restore point after the file was cleaned up, a copied project) play live: the
  /// freeze is dropped from [p] before it opens.
  void dropMissingFreezes(ProjectDoc p) {
    for (final l in p.layers) {
      final a = p.asset(l.frozenAsset);
      if (!l.frozen || (a != null && File(a.path).existsSync())) continue;
      l
        ..frozenAsset = null
        ..frozenContext = null;
    }
  }

  /// Deletes freeze and bounce renders in the open project's audio folder that the project no longer names (an
  /// unfreeze, an undone freeze or bounce, a render the app closed during): run when a project opens.
  Future<void> purgeFrozenAudio() async {
    final opened = project;
    final dir = audioDirectory;
    try {
      if (!await dir.exists()) return;
      final named = {for (final a in opened.assets) a.path};
      await for (final f in dir.list()) {
        if (!identical(project, opened)) return;
        final base = f.path.split(RegExp(r'[/\\]')).last;
        if (f is! File || !(base.startsWith(frozenFilePrefix) || base.startsWith(bounceFilePrefix))) continue;
        if (!named.contains(f.path)) await f.delete();
      }
    } catch (_) {
      // Cleaning up is best effort: a file left behind is deleted at a later open.
    }
  }
}
