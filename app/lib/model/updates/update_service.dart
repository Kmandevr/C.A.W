// The update check (owner, 2026-11-12): where releases come from (a pluggable source, GitHub Releases now), the
// user's choices (automatic checks, the channel, prompts), at most one automatic check a day, the update found,
// and downloading and handing a release to the platform's installer. Never forced, never at startup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../platform/update_installer.dart';
import '../../version.dart';
import '../atomic_file.dart';
import '../sha256.dart';
import 'delta_update.dart';
import 'release_version.dart';
import 'releases.dart';
import 'update_fetch.dart';

/// Where releases are listed. GitHub Releases now; a later AutoStacc distribution is another implementation.
abstract class UpdateSource {
  /// Shown in Settings ("Checks GitHub Releases").
  String get name;
  Future<List<ReleaseInfo>> releases();
}

/// The repository's releases on GitHub: one unauthenticated request for the newest ten (not `/latest`, which skips
/// pre-releases, and the open alpha builds are pre-releases on GitHub).
class GitHubReleasesSource implements UpdateSource {
  GitHubReleasesSource(this.fetcher);
  final UpdateFetcher fetcher;
  static final url = Uri.parse('https://api.github.com/repos/Kmandevr/C.A.W/releases?per_page=10');

  @override
  String get name => 'GitHub Releases';

  @override
  Future<List<ReleaseInfo>> releases() async => parseGitHubReleases(await fetcher.getJson(url));
}

/// How big a step from one version to another is (semver).
enum UpdateStep { patch, minor, major }

/// [to]'s step over [from]: the first of major, minor and patch that differs. The same x.y.z with another
/// pre-release (1.0.0-alpha.1 to -alpha.2, or to 1.0.0) counts as a patch: during the open alpha a new alpha number
/// is a patch-level step ([Assumption], docs/decisions.md, until the owner says otherwise).
UpdateStep updateStep(ReleaseVersion from, ReleaseVersion to) {
  if (to.major != from.major) return UpdateStep.major;
  if (to.minor != from.minor) return UpdateStep.minor;
  return UpdateStep.patch;
}

/// What installs by itself on the Stable channel (owner, 2026-11-12).
enum AutoUpdateLevel {
  off('Off', 'Nothing installs by itself.'),
  patches('Patches only', 'x.y.Z: fixes.'),
  minor('Minor and patches', 'x.Y.z: new features without breaking changes, and fixes.'),
  all('All, including major', 'X.y.z: every new version, even ones that change how things work.');

  const AutoUpdateLevel(this.label, this.description);
  final String label;
  final String description;

  static AutoUpdateLevel byName(String? name) =>
      values.firstWhere((l) => l.name == name, orElse: () => AutoUpdateLevel.off);

  bool allows(UpdateStep step) => switch (this) {
        off => false,
        patches => step == UpdateStep.patch,
        minor => step != UpdateStep.major,
        all => true,
      };
}

/// What checking a download against its published SHA-256 found.
enum DownloadCheck { verified, unverified, mismatch }

class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.source,
    required this.fetcher,
    required this.installer,
    this.store,
    DateTime Function()? clock,
    String version = appVersion,
    this.build = appBuild,
  })  : _clock = clock ?? DateTime.now,
        current = ReleaseVersion.tryParse(version) ?? const ReleaseVersion(0, 0, 0);

  /// The service the app runs (null in tests and before main sets it).
  static UpdateService? running;

  /// A service that never reaches the network, for Settings opened without the app (tests, goldens).
  static final UpdateService inert = UpdateService(
      source: const _NoSource(), fetcher: UpdateFetcher(transport: const _NoTransport()), installer: NoUpdateInstaller());

  final UpdateSource source;
  final UpdateFetcher fetcher;
  final UpdateInstaller installer;

  /// Small updates (a patch from the installed build instead of the whole download).
  late final DeltaUpdater delta = DeltaUpdater(fetcher);
  final Map<String, DeltaPlan?> _plans = {};
  final Map<String, Future<DeltaPlan?>> _planning = {};

  /// Where the choices and the last result are kept (`updates.json` beside settings.json); null keeps them in memory.
  final File? store;
  final DateTime Function() _clock;
  final ReleaseVersion current;
  final String build;

  // The user's choices.
  bool auto = true;

  /// Automatic updates on the Stable channel: which steps install by themselves (owner, 2026-11-12: Off by
  /// default, "people don't like change on DAWs").
  AutoUpdateLevel autoLevel = AutoUpdateLevel.off;

  /// Automatic updates on Beta and Every change: on or off (the newest build of the channel, whatever the step).
  bool autoPreRelease = false;

  /// Whether automatic updates are on for the channel in use.
  bool get autoInstall => channel == UpdateChannel.stable ? autoLevel != AutoUpdateLevel.off : autoPreRelease;

  /// The release an automatic update would install now: on Stable the newest one within [autoLevel]'s step (a
  /// bigger step still shows through the prompt and Settings), on the other channels the update offered. Null when
  /// automatic updates are off or nothing qualifies.
  ReleaseInfo? get autoTarget {
    if (!autoInstall) return null;
    if (channel != UpdateChannel.stable) {
      final o = offer;
      return o != null && autoAllows(o) ? o : null;
    }
    ReleaseInfo? best;
    for (final r in releasesFor(releases, UpdateChannel.stable)) {
      final v = r.version;
      if (v == null || !(v > current) || !autoAllows(r)) continue;
      if (best == null || v > best.version!) best = r;
    }
    return best;
  }

  /// Whether an automatic update may install [r]: never an older one; on Stable only up to [autoLevel]'s step.
  bool autoAllows(ReleaseInfo r) {
    if (!autoInstall || isDowngrade(r)) return false;
    if (channel != UpdateChannel.stable) return true;
    final v = r.version;
    return v != null && autoLevel.allows(updateStep(current, v));
  }
  UpdateChannel channel = UpdateChannel.stable;
  bool prompts = true;

  // What the last check found.
  DateTime? lastCheck;
  String? lastError;
  List<ReleaseInfo> releases = const [];
  ReleaseInfo? offer;

  /// The label of the update found by an earlier launch's check (the startup screen's line, before any network).
  String? savedOfferLabel;

  /// The last update the prompt told the user about.
  String? lastNotified;

  /// A Windows download made by an automatic update, said once at the next start ("Downloaded to ...").
  String? downloadedNote;

  /// The update an automatic update has downloaded, ready to install when the app is idle.
  File? _ready;
  String? _readyLabel;

  /// The automatic update was staged as a small Windows update (no file to keep; the next start swaps it in).
  bool _staged = false;

  /// Versions the automatic update already showed Android's prompt for (once each).
  final Set<String> _autoPrompted = {};

  bool checking = false;
  bool _promptedThisSession = false;
  DateTime? _snoozedAt;

  static const day = Duration(days: 1);

  /// The startup screen's line: the update an earlier check found, if it is still newer than this build.
  String? get startupLine => savedOfferLabel == null ? null : 'Update available: $savedOfferLabel';

  Future<void> load() async {
    final f = store;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      auto = j['auto'] != false;
      autoLevel = AutoUpdateLevel.byName(j['auto_level'] as String?);
      autoPreRelease = j['auto_prerelease'] == true;
      downloadedNote = j['downloaded_note'] is String ? j['downloaded_note'] as String : null;
      channel = UpdateChannel.byName(j['channel'] as String?);
      prompts = j['prompts'] != false;
      lastCheck = DateTime.tryParse('${j['last_check'] ?? ''}');
      lastNotified = j['last_notified'] is String ? j['last_notified'] as String : null;
      final offerVersion = ReleaseVersion.tryParse('${j['offer_version'] ?? ''}');
      final offerBuild = j['offer_build'] is String ? j['offer_build'] as String : '';
      final label = j['offer_label'];
      // Still an update for this build (the user may have updated since).
      final still = offerVersion != null && (offerVersion > current || (offerBuild.isNotEmpty && offerBuild != build));
      savedOfferLabel = still && label is String && label.length <= 80 ? label : null;
    } catch (_) {
      // Unreadable: the defaults.
    }
  }

  Future<void> _save() async {
    final f = store;
    if (f == null) return;
    final o = offer;
    try {
      await f.parent.create(recursive: true);
      await writeFileAtomically(
          f,
          jsonEncode({
            'auto': auto,
            'auto_level': autoLevel.name,
            'auto_prerelease': autoPreRelease,
            if (downloadedNote != null) 'downloaded_note': downloadedNote,
            'channel': channel.name,
            'prompts': prompts,
            if (lastCheck != null) 'last_check': lastCheck!.toUtc().toIso8601String(),
            if (lastNotified != null) 'last_notified': lastNotified,
            if (o != null) 'offer_label': o.label,
            if (o?.version != null) 'offer_version': o!.version.toString(),
            if (o != null && o.build.isNotEmpty) 'offer_build': o.build,
          }));
    } catch (_) {
      // Not saved: checked again next launch.
    }
  }

  /// Checks when automatic checks are on and the last check is a day old or more. Never throws.
  Future<void> checkIfDue() async {
    final last = lastCheck;
    if (!auto || (last != null && _clock().difference(last) < day)) return;
    await check();
  }

  /// Checks now. False when the check failed (offline, rate-limited, an odd answer): [lastError] says why and the
  /// last result stays.
  Future<bool> check() async {
    if (checking) return false;
    checking = true;
    notifyListeners();
    try {
      releases = await source.releases();
      lastError = null;
      lastCheck = _clock();
      _pick();
      return true;
    } catch (e) {
      lastError = e is UpdateFetchError ? e.message : 'The check failed';
      lastCheck = _clock(); // a failed check also waits a day: offline or rate-limited, it would only fail again
      return false;
    } finally {
      checking = false;
      unawaited(_save());
      notifyListeners();
    }
  }

  void _pick() {
    offer = updateFor(releases, channel, current, currentBuild: build);
    savedOfferLabel = offer?.label;
    final o = offer;
    if (o != null) unawaited(planFor(o));
  }

  static String _planKey(ReleaseInfo r, ReleaseAsset a) => '${r.tag}|${a.name}|${a.sha256}';

  /// The small update for [r] on this install, once [planFor] has looked (null: none, or not looked yet).
  DeltaPlan? planOf(ReleaseInfo r) {
    final pick = assetFor(r, installer.platform);
    return pick == null ? null : _plans[_planKey(r, pick.$1)];
  }

  /// Looks once for a small update to [r] (its manifest and patch, and whether this install is the build the patch
  /// starts from); listeners hear when it is known. Never throws.
  Future<DeltaPlan?> planFor(ReleaseInfo r) async {
    final pick = assetFor(r, installer.platform);
    if (pick == null) return null;
    final key = _planKey(r, pick.$1);
    if (_plans.containsKey(key)) return _plans[key];
    return _planning[key] ??= () async {
      DeltaPlan? plan;
      try {
        // The manifest goes beside the update folder, not in it (that folder is cleared before each download).
        final dir = await installer.downloadDir();
        plan = await delta.plan(r, pick.$1, pick.$2, installer, Directory('${dir.parent.path}${Platform.pathSeparator}update-check'));
      } catch (_) {
        plan = null;
      }
      _planning.remove(key);
      _plans[key] = plan;
      if (plan != null) notifyListeners();
      return plan;
    }();
  }

  /// The download size line for [r] ("Update 4.7 MB instead of 54.5 MB"), or null when the size is not known.
  String? sizeLine(ReleaseInfo r) {
    final pick = assetFor(r, installer.platform);
    if (pick == null) return null;
    final plan = planOf(r);
    if (plan != null) return 'Update ${megabytes(plan.downloadBytes)} instead of ${megabytes(pick.$1.size)}';
    return pick.$1.size > 0 ? 'Download ${megabytes(pick.$1.size)}' : null;
  }

  /// Gets [r]'s update ready in the update folder: first as a small update where one fits ([planFor]; Android
  /// rebuilds and verifies the APK, Windows stages the changed files for the next start), else, or on any problem
  /// with it, the whole download, checked against its published SHA-256.
  Future<_Fetched> _fetch(ReleaseInfo r, ReleaseAsset asset, AssetKind kind,
      {void Function(int got, int total)? progress, DownloadCancel? cancel}) async {
    final dir = await installer.downloadDir();
    final target = File('${dir.path}${Platform.pathSeparator}${_safeName(asset.name)}');
    await deleteStaleDownloads(dir, keep: target);
    final plan = await planFor(r);
    if (plan != null) {
      try {
        if (kind == AssetKind.apk) {
          final file = await delta.rebuildApk(plan, installer, dir, target, progress: progress, cancel: cancel);
          return _Fetched(file, DownloadCheck.verified, patchBytes: plan.downloadBytes);
        }
        await delta.stageWindows(plan, installer, dir, progress: progress, cancel: cancel);
        return _Fetched(null, DownloadCheck.verified, patchBytes: plan.downloadBytes, staged: true);
      } on DownloadCancelled {
        rethrow;
      } catch (_) {
        // Any problem with the small update: the whole download instead, and no second try at the patch.
        _plans[_planKey(r, asset)] = null;
      }
    }
    final file = await fetcher.download(asset.url, target, progress: progress, cancel: cancel);
    final check = await verifyDownload(file, asset);
    return _Fetched(check == DownloadCheck.mismatch ? null : file, check);
  }

  void setAuto(bool on) {
    auto = on;
    unawaited(_save());
    notifyListeners();
  }

  void setAutoLevel(AutoUpdateLevel level) {
    autoLevel = level;
    unawaited(_save());
    notifyListeners();
  }

  void setAutoPreRelease(bool on) {
    autoPreRelease = on;
    unawaited(_save());
    notifyListeners();
  }

  /// Takes the note an automatic download left for this start (shown once).
  String? takeDownloadedNote() {
    final n = downloadedNote;
    if (n == null) return null;
    downloadedNote = null;
    unawaited(_save());
    return n;
  }

  /// One step of automatic updating, called when the app may be idle: never with automatic updates off, never for
  /// an older version, and never while [busy] (playing, recording, a render or export). It downloads the update
  /// first; on Android it then installs, silently where Android allows it and only while [background] (the app
  /// would close under the user otherwise), else with the system's prompt once per version; on Windows it leaves
  /// the download with a note for the next start; elsewhere it does nothing (the prompt tells the user).
  /// [saveFirst] saves the project before anything installs. Null when nothing happened.
  Future<UpdateOutcome?> autoStep({required bool busy, bool background = false, Future<void> Function()? saveFirst}) async {
    final r = autoTarget;
    if (r == null || busy) return null;
    final pick = assetFor(r, installer.platform);
    if (pick == null) return null;
    final (asset, kind) = pick;
    if (_readyLabel != r.label || (_ready == null && !_staged) || (_ready != null && !await _ready!.exists())) {
      if (asset.size > UpdateFetcher.maxDownloadBytes) return null;
      final dir = await installer.downloadDir();
      DownloadCheck check;
      try {
        final got = await _fetch(r, asset, kind);
        if (got.staged) {
          // Windows: swapped in when C.A.W next starts, which then says so.
          _ready = null;
          _staged = true;
          _readyLabel = r.label;
          return UpdateOutcome('${r.label} is ready: it is put in place the next time C.A.W starts.');
        }
        check = got.check;
        if (got.file == null) return null; // deleted; tried again later
        _ready = got.file;
        _staged = false;
        _readyLabel = r.label;
      } catch (_) {
        return null; // offline or refused: tried again at the next idle moment
      }
      if (installer.platform == UpdatePlatform.windows) {
        downloadedNote = '${check == DownloadCheck.unverified ? 'Unverified (no published checksum): ' : ''}'
            '${r.label} downloaded to ${dir.path}: close C.A.W, unzip it into a folder and run caw.exe.';
        unawaited(_save());
        return UpdateOutcome(downloadedNote!, file: _ready);
      }
    }
    if (installer.platform != UpdatePlatform.android || _ready == null) return null;
    if (!await installer.canInstall()) return null;
    final silent = await installer.silentPossible();
    if (silent && !background) return null; // waits for the app to be in the background
    if (!silent && _autoPrompted.contains(r.label)) return null;
    if (!silent) _autoPrompted.add(r.label);
    await saveFirst?.call();
    return installer.install(_ready!, kind, silent: silent);
  }

  static String _safeName(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  void setChannel(UpdateChannel c) {
    if (c == channel) return;
    channel = c;
    _pick();
    unawaited(_save());
    notifyListeners();
  }

  /// Prompts on or off (Settings; "Don't ask again" turns them off).
  void setPrompts(bool on) {
    prompts = on;
    if (on) _snoozedAt = null;
    unawaited(_save());
    notifyListeners();
  }

  /// Whether to show the update prompt now: an update was found, prompts are on, and this launch hasn't asked
  /// yet (or "Not now" was a day ago).
  bool get shouldPrompt {
    if (offer == null || !prompts) return false;
    if (!_promptedThisSession) return true;
    final s = _snoozedAt;
    return s != null && _clock().difference(s) >= day;
  }

  /// The prompt was shown.
  void prompted() {
    _promptedThisSession = true;
    lastNotified = offer?.label;
    unawaited(_save());
  }

  /// "Not now": asked again at the next launch, or after a day.
  void notNow() {
    _promptedThisSession = true;
    _snoozedAt = _clock();
  }

  /// "Don't ask again": no more prompts (Settings still shows the update and can turn prompts back on).
  void dontAskAgain() => setPrompts(false);

  /// Whether installing [r] here would go back to an older version.
  bool isDowngrade(ReleaseInfo r) {
    final v = r.version;
    return v != null && v < current;
  }

  /// Downloads [r]'s file for this platform into the update folder (stale downloads deleted first) and hands it to
  /// the installer. Only ever called from the user's Update press.
  Future<UpdateOutcome> downloadAndInstall(ReleaseInfo r,
      {void Function(int got, int total)? progress, DownloadCancel? cancel}) async {
    final pick = assetFor(r, installer.platform);
    if (pick == null) {
      return const UpdateOutcome('This release has no file for this device: copy the download link instead.');
    }
    final (asset, kind) = pick;
    if (asset.size > UpdateFetcher.maxDownloadBytes) {
      return const UpdateOutcome('The download is larger than allowed (300 MB).');
    }
    if (kind == AssetKind.apk && !await installer.canInstall()) {
      return const UpdateOutcome('Allow C.A.W to install apps in Android\'s settings, then press Update again.',
          needsPermission: true);
    }
    final got = await _fetch(r, asset, kind, progress: progress, cancel: cancel);
    final saved = got.patchBytes == null ? '' : ' (${megabytes(got.patchBytes!)} instead of ${megabytes(asset.size)})';
    if (got.staged) {
      return UpdateOutcome('${r.label} is ready$saved: close C.A.W and open it again to finish updating.');
    }
    final file = got.file;
    final check = got.check;
    if (file == null) {
      return const UpdateOutcome('The download did not match its published checksum, so it was deleted.');
    }
    final outcome = await installer.install(file, kind);
    if (check == DownloadCheck.unverified && kind == AssetKind.zip) {
      return UpdateOutcome('Unverified: this release publishes no checksum. ${outcome.message}', file: outcome.file);
    }
    return outcome;
  }

  /// Checks [file] against [asset]'s published SHA-256 (hashed off the UI isolate). A mismatch, or a digest and a
  /// notes line that disagree, deletes the file. No published checksum (older releases) is [DownloadCheck.unverified]:
  /// Android still checks the APK's signature against the installed app's; on Windows the app says so plainly.
  static Future<DownloadCheck> verifyDownload(File file, ReleaseAsset asset) async {
    final want = asset.sha256;
    if (asset.checksumConflict) {
      await _delete(file);
      return DownloadCheck.mismatch;
    }
    if (want == null) return DownloadCheck.unverified;
    final path = file.path;
    final got = await Isolate.run(() => sha256OfFileSync(path));
    if (got == want) return DownloadCheck.verified;
    await _delete(file);
    return DownloadCheck.mismatch;
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  /// Deletes everything in [dir] but [keep] (earlier or broken downloads).
  static Future<void> deleteStaleDownloads(Directory dir, {File? keep}) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (keep != null && e.path == keep.path) continue;
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
  }
}

class _NoSource implements UpdateSource {
  const _NoSource();
  @override
  String get name => 'none';
  @override
  Future<List<ReleaseInfo>> releases() async => throw const UpdateFetchError('Not available here');
}

class _NoTransport implements UpdateTransport {
  const _NoTransport();
  @override
  Future<UpdateResponse> get(Uri url, {required Map<String, String> headers, required Duration timeout}) async =>
      throw const UpdateFetchError('Not available here');
}

/// What [UpdateService._fetch] got: the file to install (null after a checksum mismatch, or when [staged]), its
/// check, and the patch's size when it came as a small update.
class _Fetched {
  const _Fetched(this.file, this.check, {this.patchBytes, this.staged = false});
  final File? file;
  final DownloadCheck check;
  final int? patchBytes;
  final bool staged;
}
