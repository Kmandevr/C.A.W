// The small-update manifest CI publishes with each build (scripts/update-delta.js): every file of the APK and the
// Windows zip with its size and SHA-256, and the patches from the previous build; read defensively, with limits.

/// One file inside a published artefact.
class ManifestFile {
  const ManifestFile(this.path, this.size, this.sha256);
  final String path;
  final int size;
  final String sha256;
}

/// A published artefact (the APK or the Windows zip) and the files inside it.
class ManifestArtifact {
  const ManifestArtifact({required this.asset, required this.kind, required this.size, required this.sha256, this.files = const []});
  final String asset;

  /// `apk` or `files` (the Windows zip).
  final String kind;
  final int size;
  final String sha256;
  final List<ManifestFile> files;
}

/// A patch that rebuilds [target] from the build [baseSha256] belongs to (for an APK, the whole old APK).
class ManifestPatch {
  const ManifestPatch(
      {required this.asset,
      required this.kind,
      required this.target,
      required this.baseSha256,
      this.baseBuild = '',
      required this.size,
      required this.sha256});
  final String asset, kind, target, baseSha256, baseBuild;
  final int size;
  final String sha256;
}

class UpdateManifest {
  const UpdateManifest({required this.version, this.build = '', this.artifacts = const [], this.patches = const []});
  final String version, build;
  final List<ManifestArtifact> artifacts;
  final List<ManifestPatch> patches;

  ManifestArtifact? artifact(String asset) {
    for (final a in artifacts) {
      if (a.asset == asset) return a;
    }
    return null;
  }

  /// The patch of [kind] that builds [target], if the build published one.
  ManifestPatch? patchFor(String target, String kind) {
    for (final p in patches) {
      if (p.target == target && p.kind == kind) return p;
    }
    return null;
  }

  /// The largest manifest read (a Windows build lists a few dozen files, an APK about a hundred).
  static const maxBytes = 1024 * 1024;
  static const maxFiles = 20000;

  /// Reads [json]; null when it is not a version-1 manifest. Entries that are not shaped right are skipped.
  static UpdateManifest? parse(Object? json) {
    if (json is! Map || json['caw_update_manifest'] != 1) return null;
    final artifacts = <ManifestArtifact>[];
    final list = json['artifacts'];
    if (list is List) {
      for (final a in list.take(8)) {
        if (a is! Map) continue;
        final asset = _name(a['asset']), kind = _kind(a['kind']), size = _size(a['size']), sha = _sha(a['sha256']);
        if (asset == null || kind == null || size == null || sha == null) continue;
        final files = <ManifestFile>[];
        final fl = a['files'];
        if (fl is List) {
          if (fl.length > maxFiles) continue; // refused whole: a partial list would look like missing files
          for (final f in fl) {
            if (f is! Map) continue;
            final p = f['path'], s = _size(f['size']), h = _sha(f['sha256']);
            if (p is! String || p.isEmpty || p.length > 1024 || s == null || h == null) continue;
            files.add(ManifestFile(p, s, h));
          }
        }
        artifacts.add(ManifestArtifact(asset: asset, kind: kind, size: size, sha256: sha, files: files));
      }
    }
    final patches = <ManifestPatch>[];
    final pl = json['patches'];
    if (pl is List) {
      for (final p in pl.take(8)) {
        if (p is! Map) continue;
        final asset = _name(p['asset']), kind = _kind(p['kind']), target = _name(p['target']);
        final base = _sha(p['base_sha256']), size = _size(p['size']), sha = _sha(p['sha256']);
        if (asset == null || kind == null || target == null || base == null || size == null || sha == null) continue;
        final bb = p['base_build'];
        patches.add(ManifestPatch(
            asset: asset,
            kind: kind,
            target: target,
            baseSha256: base,
            baseBuild: bb is String && bb.length <= 40 ? bb : '',
            size: size,
            sha256: sha));
      }
    }
    final v = json['version'], b = json['build'];
    return UpdateManifest(
      version: v is String && v.length <= 64 ? v : '',
      build: b is String && b.length <= 40 ? b : '',
      artifacts: artifacts,
      patches: patches,
    );
  }

  static final _hex = RegExp(r'^[0-9a-f]{64}$');
  static final _assetName = RegExp(r'^[A-Za-z0-9._-]{1,200}$');

  static String? _sha(Object? v) => v is String && _hex.hasMatch(v) ? v : null;
  static String? _name(Object? v) => v is String && _assetName.hasMatch(v) ? v : null;
  static String? _kind(Object? v) => v == 'apk' || v == 'files' ? v as String : null;
  static int? _size(Object? v) => v is int && v >= 0 && v <= (1 << 40) ? v : null;
}
