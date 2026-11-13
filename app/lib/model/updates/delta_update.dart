// Small updates: whether a release's patch fits this install (the manifest, the installed APK's or files' SHA-256),
// and getting the update that way: Android rebuilds the full APK from the installed one, Windows stages the changed
// files. Anything unexpected returns null or throws, and the caller downloads the whole update instead.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../../platform/update_installer.dart';
import '../sha256.dart';
import 'patch_format.dart';
import 'releases.dart';
import 'update_fetch.dart';
import 'update_manifest.dart';
import 'windows_stage.dart';

/// A patch that fits this install: what it downloads instead of [full].
class DeltaPlan {
  const DeltaPlan({required this.release, required this.full, required this.kind, required this.patchAsset, required this.patch, required this.artifact});
  final ReleaseInfo release;
  final ReleaseAsset full;
  final AssetKind kind;
  final ReleaseAsset patchAsset;
  final ManifestPatch patch;
  final ManifestArtifact artifact;

  /// What the small update downloads.
  int get downloadBytes => patch.size;
}

/// Hashes [path] off the UI isolate, remembered per path, size and modification time (the installed APK is hashed
/// once per run, not on every check).
class _HashCache {
  final Map<String, (int, DateTime, String)> _known = {};

  Future<String?> of(String path) async {
    final f = File(path);
    try {
      final st = await f.stat();
      if (st.type != FileSystemEntityType.file) return null;
      final k = _known[path];
      if (k != null && k.$1 == st.size && k.$2 == st.modified) return k.$3;
      final sha = await Isolate.run(() => sha256OfFileSync(path));
      _known[path] = (st.size, st.modified, sha);
      return sha;
    } catch (_) {
      return null;
    }
  }
}

class DeltaUpdater {
  DeltaUpdater(this.fetcher);
  final UpdateFetcher fetcher;
  final _hashes = _HashCache();

  /// The manifest asset of [r] (`…-update.json`) when it has a published checksum.
  static ReleaseAsset? manifestAsset(ReleaseInfo r) {
    for (final a in r.assets) {
      if (a.name.toLowerCase().endsWith('-update.json') && a.sha256 != null && !a.checksumConflict) return a;
    }
    return null;
  }

  /// Downloads and reads [r]'s manifest into [dir] (deleted afterwards), checked against its published SHA-256.
  Future<UpdateManifest?> manifest(ReleaseInfo r, Directory dir) async {
    final a = manifestAsset(r);
    if (a == null || a.size > UpdateManifest.maxBytes) return null;
    final f = File('${dir.path}${Platform.pathSeparator}.manifest-${a.name}');
    try {
      await dir.create(recursive: true);
      await fetcher.download(a.url, f, maxBytes: UpdateManifest.maxBytes);
      final bytes = await f.readAsBytes();
      if (sha256Hex(bytes) != a.sha256) return null;
      return UpdateManifest.parse(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      return null;
    } finally {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// A plan to get [full] (the release's APK or Windows zip) as a patch, or null when there is none for this
  /// install: no manifest or patch, no checksums to verify the result, the patch no smaller, or (Android) the
  /// installed APK's SHA-256 is not the build the patch starts from. On Windows the app's files are checked when the
  /// patch is applied ([stageWindows]), not here.
  Future<DeltaPlan?> plan(ReleaseInfo r, ReleaseAsset full, AssetKind kind, UpdateInstaller installer, Directory dir) async {
    if (full.sha256 == null || full.checksumConflict) return null;
    final m = await manifest(r, dir);
    if (m == null) return null;
    final art = m.artifact(full.name);
    if (art == null || art.sha256 != full.sha256 || art.size != full.size) return null;
    final p = m.patchFor(full.name, kind == AssetKind.apk ? 'apk' : 'files');
    if (p == null || p.size >= full.size || p.size > UpdateFetcher.maxDownloadBytes) return null;
    ReleaseAsset? pa;
    for (final a in r.assets) {
      if (a.name == p.asset) pa = a;
    }
    if (pa == null || pa.checksumConflict || (pa.sha256 != null && pa.sha256 != p.sha256)) return null;
    if (kind == AssetKind.apk) {
      final apk = await installer.installedPackage();
      if (apk == null || await _hashes.of(apk) != p.baseSha256) return null;
    } else {
      final dirNow = await installer.installDir();
      if (dirNow == null || art.files.isEmpty) return null;
    }
    return DeltaPlan(release: r, full: full, kind: kind, patchAsset: pa, patch: p, artifact: art);
  }

  Future<File> _download(DeltaPlan plan, Directory dir, void Function(int, int)? progress, DownloadCancel? cancel) async {
    final f = File('${dir.path}${Platform.pathSeparator}${plan.patch.asset}');
    final got = await fetcher.download(plan.patchAsset.url, f, progress: progress, cancel: cancel, maxBytes: plan.patch.size);
    final path = got.path;
    final sha = await Isolate.run(() => sha256OfFileSync(path));
    if (sha != plan.patch.sha256) {
      await _delete(got);
      throw const PatchError('the patch did not match its published checksum');
    }
    return got;
  }

  /// Android: downloads the patch and rebuilds the release's APK at [out] from the installed one; the result must
  /// hash to the release's published SHA-256 (checked as it is written) before anything installs it.
  Future<File> rebuildApk(DeltaPlan plan, UpdateInstaller installer, Directory dir, File out,
      {void Function(int, int)? progress, DownloadCancel? cancel}) async {
    final apk = await installer.installedPackage();
    if (apk == null) throw const PatchError('the installed package is not readable');
    final patch = await _download(plan, dir, progress, cancel);
    try {
      final base = plan.patch.baseSha256, want = plan.full.sha256!, pp = patch.path, op = out.path;
      await Isolate.run(() => rebuildSingleFile(patchPath: pp, basePath: apk, baseSha256: base, outPath: op, wantSha256: want));
      return out;
    } finally {
      await _delete(patch);
    }
  }

  /// Windows: downloads the patch and stages the changed files beside the app for the next start. Every file of the
  /// new build must then be either already here (same SHA-256) or staged.
  Future<int> stageWindows(DeltaPlan plan, UpdateInstaller installer, Directory dir,
      {void Function(int, int)? progress, DownloadCancel? cancel}) async {
    final install = await installer.installDir();
    if (install == null) throw const PatchError('the app folder is unknown');
    final want = {for (final f in plan.artifact.files) f.path: f.sha256};
    if (want.keys.any((p) => !safeRelativePath(p))) throw const PatchError('the manifest has an unsafe path');
    final stage = WindowsStage(install);
    final patch = await _download(plan, dir, progress, cancel);
    try {
      await stage.begin();
      final pp = patch.path, ip = install.path, sp = stage.files.path;
      final staged = await Isolate.run(() {
        final s = stageFiles(patchPath: pp, installDir: ip, stageDir: sp, expected: want);
        // Everything not staged must already be the new build's.
        for (final e in want.entries) {
          if (s.containsKey(e.key)) continue;
          final local = '$ip${Platform.pathSeparator}${e.key.replaceAll('/', Platform.pathSeparator)}';
          if (!File(local).existsSync() || sha256OfFileSync(local) != e.value) {
            throw PatchError('${e.key} here differs from both builds');
          }
        }
        return s;
      });
      await stage.commit(plan.release.label, staged);
      return staged.length;
    } catch (_) {
      await stage.clear();
      rethrow;
    } finally {
      await _delete(patch);
    }
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// "3.2 MB" for [bytes].
String megabytes(int bytes) {
  final mb = bytes / 1048576;
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.toStringAsFixed(0)} MB';
}
