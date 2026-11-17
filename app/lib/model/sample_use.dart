// Linked samples in a project: the app-wide library, the preview, using a file in place (the double tap's smart target), its links at open, and Find it.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../engine/sample_preview_io.dart';
import '../platform/linked_folders.dart';
import 'app_state.dart';
import 'audio_clips.dart';
import 'audio_edit.dart';
import 'drums.dart';
import 'device_target.dart';
import 'music_key.dart';
import 'project.dart';
import 'project_dependencies.dart';
import 'sample_library.dart';
import 'sample_names.dart';
import 'sampler.dart';

final Expando<SampleLibrary> _library = Expando('sample library');
final Expando<SamplePreviewIo> _preview = Expando('sample preview');

/// Where a double tap in the sample browser puts a file (owner, 2026-11-17).
enum SampleTargetKind {
  /// The selected audio track, at the playhead (snapped).
  audioTrack,

  /// The selected drum pad of the selected track's Drums.
  drumPad,

  /// The selected track's sampler: a new zone.
  sampler,

  /// A new audio track at the playhead.
  newTrack,
}

class SampleTarget {
  const SampleTarget(this.kind, {this.layer, this.pad, this.atStep = 0});
  final SampleTargetKind kind;
  final LayerDoc? layer;
  final int? pad;
  final double atStep;

  /// What the browser's add button says it will do.
  String get label => switch (kind) {
        SampleTargetKind.audioTrack => 'Add to ${layer?.name ?? 'track'}',
        SampleTargetKind.drumPad => 'Load into pad ${(pad ?? 0) + 1}',
        SampleTargetKind.sampler => 'Add to ${layer?.name ?? 'the sampler'}',
        SampleTargetKind.newTrack => 'Add on a new track',
      };
}

extension SampleUse on AppState {
  /// The linked folders and their index, app-wide (`sample-folders.json` beside settings.json).
  SampleLibrary get sampleLibrary => _library[this] ??= _makeLibrary();
  set sampleLibrary(SampleLibrary l) => _library[this] = l;

  SampleLibrary _makeLibrary() {
    final lib = SampleLibrary(settingsDir: settings.dir);
    final access = lib.access;
    if (access is AndroidFolderAccess) {
      access.onClosed = (path) {
        sessionPathNames.remove(path);
      };
    }
    lib.analyse = (library, folder, entries) => detectSampleValues(entries, limit: 64);
    return lib;
  }

  /// The engine's preview voice ([EngineSamplePreviewIo] by default); tests set a fake.
  SamplePreviewIo get samplePreview => _preview[this] ??= EngineSamplePreviewIo(() => engine);
  set samplePreview(SamplePreviewIo io) => _preview[this] = io;

  /// Estimates what neither the metadata nor the names gave, from the audio (off the UI isolate), for at most
  /// [limit] files: a loop's tempo (`caw_asset_tempo`, kept only when sure) and a tonal file's key (`caw_asset_key`).
  Future<void> detectSampleValues(List<SampleEntry> entries, {int limit = 64}) async {
    final io = samplePreview;
    var n = 0;
    for (final e in entries) {
      if (n >= limit) break;
      final wantTempo = e.bpm == null && e.kind == SampleKind.loop && (e.tried & 1) == 0 && (e.seconds ?? 0) <= 120;
      final wantKey = e.key == null && !(e.instrument?.isHit ?? false) && e.instrument != SampleInstrument.drums &&
          (e.tried & 2) == 0 && (e.seconds ?? 0) <= 120;
      if (!wantTempo && !wantKey) continue;
      final path = await sampleLibrary.pathOf(e);
      if (path == null) continue;
      n++;
      if (wantTempo) {
        e.tried |= 1;
        final r = await engine?.assetTempo(path);
        final bpm = r?['bpm'];
        if (r?['ok'] == true && bpm is num && bpm.isFinite && bpm >= 40 && bpm <= 300) {
          e.bpm = (bpm * 100).roundToDouble() / 100;
          e.bpmFrom = ValueSource.detected;
          if (e.kindFrom == ValueSource.detected) inferKindFromLength(e);
        }
      }
      if (wantKey) {
        e.tried |= 2;
        applyKeyEstimate(e, await io.key(path));
      }
      sampleLibrary.changed();
    }
  }

  /// The smart target for a double tap: the selected audio track gets the file at the playhead (snapped); the
  /// selected track's Drums its selected pad ([selectedPad]); its sampler a zone; otherwise a new audio track.
  SampleTarget sampleTarget({int? Function(LayerDoc layer)? selectedPad}) {
    final snap = math.max(1, arrangementSnapSteps);
    final at = ((playheadStep / snap).round() * snap).toDouble().clamp(0.0, project.maxArrangementSteps - 1.0);
    final layer = project.layers.where((l) => l.id == selectedLayerId).firstOrNull;
    if (layer != null && !layer.isFolder) {
      final inst = layer.instrument?.id;
      if (inst == drumsComponentId) {
        return SampleTarget(SampleTargetKind.drumPad, layer: layer, pad: selectedPad?.call(layer) ?? 0, atStep: at);
      }
      if (inst == samplerComponentId) return SampleTarget(SampleTargetKind.sampler, layer: layer, atStep: at);
      if (layer.instrument == null && layer.clips.isEmpty) {
        return SampleTarget(SampleTargetKind.audioTrack, layer: layer, atStep: at);
      }
    }
    return SampleTarget(SampleTargetKind.newTrack, atStep: at);
  }

  /// The project's asset for [e], used in place (nothing is copied): found by its link, else added with it.
  /// Null when the file can't be reached now.
  Future<AudioAssetDoc?> sampleAsset(SampleEntry e) async {
    final path = await sampleLibrary.pathOf(e);
    if (path == null) return null;
    final link = LinkedRef(e.root, e.rel);
    if (isSessionPath(path)) {
      sessionPathNames[path] = link.placeholder;
      final access = sampleLibrary.access;
      final lf = sampleLibrary.folder(e.root);
      if (access is AndroidFolderAccess && lf != null) access.pin(lf.location, e.listed);
    }
    final known = project.assets.where((a) => a.link?.root == e.root && a.link?.rel == e.rel).firstOrNull;
    if (known != null) {
      if (known.path != path) editProject((p) => relinkProjectPath(p, known.path, path));
      return known;
    }
    final asset = addAssetFor(path, name: e.baseName, bpm: e.bpm,
        seconds: e.secondsApprox ? 0 : (e.seconds ?? 0));
    asset.link = link;
    return asset;
  }

  /// The double tap: puts [e] where [target] says (one undo step). Returns a line for the user.
  Future<String> addSample(SampleEntry e, SampleTarget target) async {
    final asset = await sampleAsset(e);
    if (asset == null) return '${e.name} can\'t be reached: is its folder still there?';
    switch (target.kind) {
      case SampleTargetKind.audioTrack:
        final track = target.layer!;
        addAudioClip(track, asset, atStep: target.atStep);
        return 'Added ${e.baseName} to ${track.name}.';
      case SampleTargetKind.newTrack:
        final track = addAudioTrack(name: e.baseName);
        addAudioClip(track, asset, atStep: target.atStep);
        return 'Added ${e.baseName} on a new track.';
      case SampleTargetKind.drumPad:
        final track = target.layer!;
        final t = DeviceTarget(this, track.id, DeviceTarget.instrumentSlot);
        final info = t.info;
        if (info == null) return 'The drums aren\'t ready yet.';
        final pad = target.pad ?? 0;
        endUndoStep();
        setPadSample(t, DrumsLayout.of(info), pad, ComponentSampleDoc(pad, path: asset.path));
        endUndoStep();
        return 'Loaded ${e.baseName} into pad ${pad + 1}.';
      case SampleTargetKind.sampler:
        final track = target.layer!;
        final zones = samplerState(track);
        final root = e.rootNote ?? 60;
        if (zones.zones.isEmpty) {
          // An empty sampler plays the file on every key, rooted at its note (C4 when none is known).
          zones.zones.add(SamplerZone(path: asset.path, loKey: 0, hiKey: 127, root: root));
        } else {
          final top = zones.zones.map((z) => z.hiKey).reduce(math.max);
          if (top >= 127 || zones.zones.length >= SamplerState.maxZones) return 'The sampler has no free key.';
          zones.addFiles([asset.path], top + 1);
          zones.zones.last.root = e.rootNote ?? top + 1;
        }
        setSamplerState(track, zones);
        return 'Added ${e.baseName} to ${track.name}.';
    }
  }

  /// After a project opens: every linked file's path for this device and session (a moved or relinked folder is
  /// followed; on Android each file is opened as a session handle and kept open). Then the missing-files check.
  Future<void> resolveLinkedSamples() async {
    final opened = project;
    if (!opened.assets.any((a) => a.link != null)) return;
    final lib = sampleLibrary;
    await lib.load(refresh: false);
    final moves = <(String, String)>[];
    for (final a in [...opened.assets]) {
      final link = a.link;
      if (link == null) continue;
      final lf = lib.folder(link.root);
      if (lf == null) continue;
      String? path;
      if (lib.access.stablePaths) {
        path = joinInside(lf.location, link.rel);
      } else {
        final e = lib.entry(link.root, link.rel);
        if (e != null) path = await lib.pathOf(e);
        if (path != null) {
          sessionPathNames[path] = link.placeholder;
          final access = lib.access;
          if (access is AndroidFolderAccess && e != null) access.pin(lf.location, e.listed);
        }
      }
      if (path != null && path != a.path) moves.add((a.path, path));
    }
    if (!identical(project, opened) || moves.isEmpty) return;
    editProject((p) {
      for (final (from, to) in moves) {
        relinkProjectPath(p, from, to);
      }
    });
  }

  /// The project's linked files that are missing, with their links.
  List<AudioAssetDoc> missingLinkedAssets() {
    final missing = {for (final m in missingFiles) m.path};
    return [for (final a in project.assets) if (a.link != null && missing.contains(a.path)) a];
  }

  /// Find it › Choose the file: [path] in place of [asset] (no copy). A file inside a linked folder keeps a link to
  /// it; else the asset refers to the file by path.
  Future<void> findLinkedFile(AudioAssetDoc asset, String path) async {
    final from = asset.path;
    final at = sampleLibrary.locate(path);
    editProject((p) {
      relinkProjectPath(p, from, path);
      asset.link = at == null ? null : LinkedRef(at.$1.id, at.$2);
    });
    await checkMissingFiles();
  }

  /// Find it › Relink a folder: [location] (a picked folder) holds the missing files at the same paths as the old
  /// folder did. The folder the links name is pointed there (linked now when this device didn't know it), so every
  /// project's links follow. Returns how many missing files it found; 0 changes nothing.
  Future<int> relinkLinkedFolder(String rootId, String location, String name) async {
    final lib = sampleLibrary;
    await lib.load(refresh: false);
    final wanted = [for (final a in project.assets) if (a.link?.root == rootId) a.link!.rel];
    if (wanted.isEmpty) return 0;
    final listing = await lib.access.list(location);
    final there = {for (final f in listing.files) f.rel};
    final found = wanted.where(there.contains).length;
    if (found == 0) return 0;
    if (lib.folder(rootId) != null) {
      await lib.relocate(rootId, location, name);
    } else {
      final (_, error) = await lib.link(location, name, id: rootId);
      if (error != null) return 0;
      await lib.refresh(rootId);
    }
    await resolveLinkedSamples();
    await checkMissingFiles();
    return found;
  }

  /// Whether [path] is a linked file the open project uses (Export project… may package it).
  bool isLinkedSampleFile(String path) {
    for (final a in project.assets) {
      if (a.link != null && a.path == path) {
        if (isSessionPath(path)) return true;
        final lf = sampleLibrary.folder(a.link!.root);
        return lf != null && isInsideFolders(path, [lf.location]);
      }
    }
    return false;
  }
}

/// `caw_asset_key`'s answer onto [e]: a key only when the engine was sure, marked as an estimate with its confidence.
void applyKeyEstimate(SampleEntry e, Map<String, dynamic> r) {
  final tonic = r['tonic'];
  if (r['ok'] != true || r['sure'] != true || tonic is! int || tonic < 0 || tonic > 11) return;
  final c = r['confidence'];
  e.key = MusicalKey(tonic, minor: r['mode'] == 'minor');
  e.keyFrom = ValueSource.detected;
  e.keyConfidence = c is num && c.isFinite ? c.toDouble().clamp(0.0, 1.0) : null;
}

/// The preview's stretch for [e] at the project's tempo: the ratio that plays a loop of known tempo at [projectBpm]
/// (1 for anything else, and outside 0.25..4).
double previewRatio(SampleEntry e, double projectBpm, {bool sync = true}) {
  final bpm = e.bpm;
  if (!sync || bpm == null || e.kind == SampleKind.oneShot || projectBpm <= 0) return 1;
  final r = bpm / projectBpm;
  return r < 0.25 || r > 4 ? 1 : r;
}

/// Whether [path] is a file (for Find it's pick; a link is not followed).
Future<bool> isPlainFile(String path) async {
  try {
    return await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.file;
  } catch (_) {
    return false;
  }
}
