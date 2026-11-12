// Releases from the update source, read defensively: the update channels, which release is an update, which asset
// suits this platform, and the hosts a download may come from.
import 'release_version.dart';

/// Where the app looks for updates (owner, 2026-11-12). Stable is the default for everyone.
enum UpdateChannel {
  stable('Stable', 'Public releases: the open alpha builds now, full releases later.'),
  beta('Beta', 'Tagged test builds of changes not yet public, as well as everything in Stable.'),
  everyChange('Every change', 'A new build after every change to the code. Untested: it may break.');

  const UpdateChannel(this.label, this.description);
  final String label;
  final String description;

  static UpdateChannel byName(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => UpdateChannel.stable);

  /// Whether [r] belongs to this channel: by the tag's pre-release word, not GitHub's pre-release flag (every
  /// `-alpha.N` is marked a pre-release on GitHub, yet it is the public line).
  bool includes(ReleaseInfo r) {
    if (r.draft) return false;
    if (r.rolling) return this == everyChange;
    final v = r.version;
    if (v == null) return false;
    if (v.isFull || v.stage == 'alpha') return true;
    return this != stable; // beta and any other test stage
  }
}

/// One downloadable file of a release.
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, required this.size});
  final String name;
  final Uri url;
  final int size;
}

/// One release as the source lists it.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    this.title = '',
    this.notes = '',
    this.page,
    this.published,
    this.draft = false,
    this.prerelease = false,
    this.rolling = false,
    this.build = '',
    this.assets = const [],
  });

  final String tag;

  /// The version: from the tag, or for the rolling build its notes' `Version:` line. Null when neither reads.
  final ReleaseVersion? version;
  final String title, notes;

  /// The release's web page (html_url), to copy as the download link.
  final Uri? page;
  final DateTime? published;
  final bool draft, prerelease;

  /// The "Every change" build (tag `latest-main`), replaced on every change to Main.
  final bool rolling;

  /// The short commit it was built from (the notes' `Build:` line; [rolling] builds carry one).
  final String build;
  final List<ReleaseAsset> assets;

  String get label => rolling ? 'Every change${build.isEmpty ? '' : ' ($build)'}' : 'v${version ?? tag}';
}

/// The tag of the rolling "Every change" release that CI replaces on each change to Main.
const String rollingTag = 'latest-main';

/// Hosts a release download may come from: GitHub, and the storage it redirects asset downloads to (checked
/// 2026-11-12: github.com/.../releases/download/... answers 302 to release-assets.githubusercontent.com; older
/// releases used objects.githubusercontent.com).
const Set<String> downloadHosts = {'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com'};

/// Whether [u] may be downloaded from: https on the default port, an allowed host, no user info.
bool allowedDownload(Uri u) =>
    u.scheme == 'https' && downloadHosts.contains(u.host.toLowerCase()) && u.userInfo.isEmpty && (!u.hasPort || u.port == 443);

final _buildLine = RegExp(r'^\s*Build:\s*([0-9a-f]{7,40})\s*$', multiLine: true, caseSensitive: false);
final _versionLine = RegExp(r'^\s*Version:\s*v?(\S{1,64})\s*$', multiLine: true, caseSensitive: false);

String _text(Object? v, int max) => v is String ? (v.length > max ? v.substring(0, max) : v) : '';

/// Reads GitHub's `GET /repos/{owner}/{repo}/releases` answer. Anything not shaped as expected is skipped, never
/// thrown: the source is outside the app.
List<ReleaseInfo> parseGitHubReleases(Object? json) {
  if (json is! List) return const [];
  final out = <ReleaseInfo>[];
  for (final r in json.take(50)) {
    if (r is! Map) continue;
    final tag = _text(r['tag_name'], 100);
    if (tag.isEmpty) continue;
    final notes = _text(r['body'], 20000);
    final rolling = tag == rollingTag;
    final version = rolling
        ? ReleaseVersion.tryParse(_versionLine.firstMatch(notes)?.group(1) ?? '')
        : ReleaseVersion.tryParse(tag);
    final assets = <ReleaseAsset>[];
    final list = r['assets'];
    if (list is List) {
      for (final a in list.take(20)) {
        if (a is! Map) continue;
        final name = _text(a['name'], 200);
        final url = Uri.tryParse(_text(a['browser_download_url'], 2000));
        final size = a['size'];
        if (name.isEmpty || url == null || !allowedDownload(url)) continue;
        assets.add(ReleaseAsset(name: name, url: url, size: size is int && size >= 0 ? size : 0));
      }
    }
    final page = Uri.tryParse(_text(r['html_url'], 2000));
    out.add(ReleaseInfo(
      tag: tag,
      version: version,
      title: _text(r['name'], 200),
      notes: notes,
      page: page != null && page.scheme == 'https' && page.host == 'github.com' ? page : null,
      published: DateTime.tryParse(_text(r['published_at'], 40)),
      draft: r['draft'] == true,
      prerelease: r['prerelease'] == true,
      rolling: rolling,
      build: (_buildLine.firstMatch(notes)?.group(1) ?? '').toLowerCase(),
      assets: assets,
    ));
  }
  return out;
}

/// The releases [channel] offers, newest first (the rolling build first, then by version).
List<ReleaseInfo> releasesFor(List<ReleaseInfo> all, UpdateChannel channel) {
  final list = [for (final r in all) if (channel.includes(r)) r];
  list.sort((a, b) {
    if (a.rolling != b.rolling) return a.rolling ? -1 : 1;
    final va = a.version, vb = b.version;
    if (va == null || vb == null) return (vb == null ? 0 : 1) - (va == null ? 0 : 1);
    return vb.compareTo(va);
  });
  return list;
}

/// The update [channel] offers over the running build ([current], [currentBuild]): the newest tagged release above
/// it, or on Every change the rolling build when it was made from another commit and is not older. Null: up to date.
ReleaseInfo? updateFor(List<ReleaseInfo> all, UpdateChannel channel, ReleaseVersion current, {String currentBuild = ''}) {
  ReleaseInfo? best;
  for (final r in releasesFor(all, channel)) {
    final v = r.version;
    if (r.rolling) {
      // Built from Main's newest commit, so it holds every tagged change: it wins when it is another build.
      final differs = r.build.isNotEmpty && r.build != currentBuild.toLowerCase();
      if (differs && (v == null || !(v < current))) return r;
      continue;
    }
    if (v == null || !(v > current)) continue;
    if (best == null || (best.version != null && v > best.version!)) best = r;
  }
  return best;
}

/// The platforms an update can be installed on.
enum UpdatePlatform { android, windows, other }

/// What a downloaded asset is: an Android package, a Windows installer, or a zip of the app's files.
enum AssetKind { apk, installer, zip }

/// The file of [r] for [platform], with its kind; null when there is none (the download link is offered instead).
(ReleaseAsset, AssetKind)? assetFor(ReleaseInfo r, UpdatePlatform platform) {
  bool named(ReleaseAsset a, String end) => a.name.toLowerCase().endsWith(end);
  switch (platform) {
    case UpdatePlatform.android:
      for (final a in r.assets) {
        if (named(a, '-android.apk')) return (a, AssetKind.apk);
      }
    case UpdatePlatform.windows:
      for (final a in r.assets) {
        if (named(a, '-windows.msi') || named(a, '-windows-setup.exe')) return (a, AssetKind.installer);
      }
      for (final a in r.assets) {
        if (named(a, '-windows.zip')) return (a, AssetKind.zip);
      }
    case UpdatePlatform.other:
      break;
  }
  return null;
}
