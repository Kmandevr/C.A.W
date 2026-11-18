// Updates through the companion app when it is there (docs/companion-protocol.md): the release list from
// update.check, and the install handed to its own screen (update.open). Absent, every call is today's in-app one.
import 'dart:io';

import 'package:caw_services/companion/companion_protocol.dart';
import 'package:caw_services/updates/releases.dart';
import 'package:caw_services/updates/update_fetch.dart';

import '../../platform/companion_link.dart';
import '../../platform/update_installer.dart';
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
class CompanionUpdateInstaller implements UpdateInstaller {
  CompanionUpdateInstaller(this.link, this.fallback);
  final CompanionLink link;
  final UpdateInstaller fallback;

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

  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    if (await link.probe() != CompanionStatus.present) return fallback.install(file, kind, silent: silent);
    final r = await link.request(CompanionKind.updateOpen, const {});
    if (r.ok) return UpdateOutcome('Finish the update in the C.A.W companion app.', started: true, file: file);
    if (r.fallBack) return fallback.install(file, kind, silent: silent);
    // update.open may already have opened the companion's screen: not repeated in-app.
    return UpdateOutcome('The companion app did not open (${r.detail ?? r.outcome.name}).', file: file);
  }

  @override
  Future<String?> installedPackage() => fallback.installedPackage();

  @override
  Future<Directory?> installDir() => fallback.installDir();

  @override
  Future<({bool relaunch, String? note})> finishStaged([List<String> args = const []]) => fallback.finishStaged(args);
}
