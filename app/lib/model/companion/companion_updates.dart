// Updates through the companion app when it is there (docs/companion-protocol.md): the release list from
// update.check, and the install handed to it (update.open, on the channel Settings holds). Absent, every call is today's in-app one.
import 'dart:io';

import 'package:caw_services/companion/companion_protocol.dart';
import 'package:caw_services/updates/releases.dart';
import 'package:caw_services/updates/update_fetch.dart';

import '../../platform/companion_link.dart';
import '../../platform/update_installer.dart';
import '../../version.dart';
import '../updates/update_service.dart';

/// The companion's release list, read by the same defensive parser as GitHub's (asset URLs still pinned to this
/// repository), or [fallback]'s when the companion is absent, doesn't know the kind, or a read timed out.
class CompanionUpdateSource implements UpdateSource {
  CompanionUpdateSource(this.link, this.fallback);
  final CompanionLink link;
  final UpdateSource fallback;

  @override
  String get name => link.status == CompanionStatus.present ? 'the C.A.W companion app' : fallback.name;

  @override
  Future<List<ReleaseInfo>> releases() async {
    if (await link.probe() != CompanionStatus.present) return fallback.releases();
    final r = await link.request(CompanionKind.updateCheck, const {});
    if (r.ok) return parseGitHubReleases(r.body['releases']);
    // update.check only reads, so a timeout may be answered in-app too.
    if (r.fallBack || r.outcome == CompanionOutcome.timeout) return fallback.releases();
    throw UpdateFetchError('The companion app could not check (${r.detail ?? r.outcome.name})');
  }
}

/// Installs through the companion when it is there: it holds the install permissions and installs only on the
/// user's tap in its own screen. Everything else, and everything while it is absent, is [fallback]'s.
/// The companion installs the update of the channel C.A.W's settings hold ([channel], by default the running update
/// service's), and on Every change it is told this build's commit ([build]) so it skips the build already installed.
class CompanionUpdateInstaller implements UpdateInstaller {
  CompanionUpdateInstaller(this.link, this.fallback, {UpdateChannel Function()? channel, String Function()? build})
      : _channel = channel ?? (() => UpdateService.running?.channel ?? UpdateChannel.stable),
        _build = build ?? (() => UpdateService.running?.build ?? appCommit);
  final CompanionLink link;
  final UpdateInstaller fallback;
  final UpdateChannel Function() _channel;
  final String Function() _build;

  bool get _present => link.status == CompanionStatus.present;

  @override
  UpdatePlatform get platform => fallback.platform;

  @override
  bool get refusesDowngrade => fallback.refusesDowngrade;

  @override
  Future<Directory> downloadDir() => fallback.downloadDir();

  @override
  Future<bool> canInstall() async => await link.probe() == CompanionStatus.present || await fallback.canInstall();

  @override
  Future<void> openInstallPermission() async {
    if (!_present) await fallback.openInstallPermission();
  }

  @override
  Future<bool> silentPossible() async => !_present && await fallback.silentPossible();

  // The companion downloads and checks the APK itself, so C.A.W hands an Android update over before downloading it.
  @override
  Future<UpdateOutcome?> handOff(AssetKind kind) async {
    if (kind != AssetKind.apk || await link.probe() != CompanionStatus.present) return null;
    return _open(null);
  }

  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    if (await link.probe() != CompanionStatus.present) return fallback.install(file, kind, silent: silent);
    return await _open(file) ?? await fallback.install(file, kind, silent: silent);
  }

  /// Asks the companion to install; null when it says to fall back to the in-app path.
  Future<UpdateOutcome?> _open(File? file) async {
    final channel = _channel();
    final r = await link.request(CompanionKind.updateOpen, updateOpenBody(channel, build: _build()));
    if (r.ok) return _outcome(readUpdateOpenReply(r.body), channel, file);
    if (r.fallBack) return null;
    // A companion from before channels refuses a channel's name: it can install only Stable.
    if (r.outcome == CompanionOutcome.badRequest && channel != UpdateChannel.stable) {
      return UpdateOutcome('The companion app is too old to install from ${channel.label}: update it first.', file: file);
    }
    // update.open may already have opened the companion's screen: not repeated in-app.
    return UpdateOutcome('The companion app did not open (${r.detail ?? r.outcome.name}).', file: file);
  }

  static UpdateOutcome _outcome(({bool started, String? release, UpdateOpenSkip? skip}) reply, UpdateChannel channel, File? file) {
    if (reply.started) return UpdateOutcome('Finish the update in the C.A.W companion app.', started: true, file: file);
    final name = reply.release ?? 'its newest release';
    final message = switch (reply.skip) {
      UpdateOpenSkip.upToDate => 'The companion app found nothing newer on ${channel.label}.',
      UpdateOpenSkip.older =>
        'On ${channel.label} the newest is $name, older than this build, so nothing was installed (C.A.W never goes back a version).',
      UpdateOpenSkip.unverifiable => 'The companion app could not check $name, so it installed nothing.',
      _ => 'The companion app found nothing to install.',
    };
    return UpdateOutcome(message, file: file);
  }

  @override
  Future<String?> installedPackage() => fallback.installedPackage();

  @override
  Future<Directory?> installDir() => fallback.installDir();

  @override
  Future<({bool relaunch, String? note})> finishStaged([List<String> args = const []]) => fallback.finishStaged(args);
}
