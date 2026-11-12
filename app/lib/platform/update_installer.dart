// Installing a downloaded update, one implementation per platform: Android hands the APK to the system installer
// (caw/updates, UpdateInstaller.kt), Windows opens the installer or shows the downloaded zip, others offer the link.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../model/updates/releases.dart';

/// What a finished download led to, said in one line.
class UpdateOutcome {
  const UpdateOutcome(this.message, {this.started = false, this.needsPermission = false, this.file});
  final String message;

  /// The system installer (or the Windows installer) opened.
  final bool started;

  /// Android: "install unknown apps" is off for C.A.W; [UpdateInstaller.openInstallPermission] opens that setting.
  final bool needsPermission;
  final File? file;
}

abstract class UpdateInstaller {
  UpdatePlatform get platform;

  /// Whether this platform's installer refuses an older version over a newer one (Android's versionCode check).
  bool get refusesDowngrade => false;

  /// The folder downloads go to (the app's cache, `updates/`).
  Future<Directory> downloadDir() async =>
      Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');

  /// Whether the app may hand a package to the installer now.
  Future<bool> canInstall() async => true;

  /// Opens the setting that allows it (Android's "Install unknown apps" for C.A.W).
  Future<void> openInstallPermission() async {}

  /// Whether an update can install with no prompt (Android 12+ when C.A.W is its own installer of record).
  Future<bool> silentPossible() async => false;

  /// Installs [file]; [silent] asks for no prompt where [silentPossible] (automatic updates only).
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false});
}

/// The platform's installer: Android's channel, Windows' shell, or none.
UpdateInstaller platformUpdateInstaller() {
  if (Platform.isAndroid) return AndroidUpdateInstaller();
  if (Platform.isWindows) return WindowsUpdateInstaller();
  return NoUpdateInstaller();
}

/// Android: `canInstall` is PackageManager.canRequestPackageInstalls (API 26); `install` commits a PackageInstaller
/// session with the file; the system asks the user, unless Android 12+ allows a silent update.
class AndroidUpdateInstaller extends UpdateInstaller {
  AndroidUpdateInstaller({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/updates') {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'status' || call.arguments is! Map) return;
      final m = call.arguments as Map;
      final status = m['status'];
      lastStatus = status is int ? status : null;
      lastStatusMessage = m['message'] is String ? m['message'] as String : '';
    });
  }
  final MethodChannel _channel;

  /// The last session result Android reported (PackageInstaller.STATUS_*: 0 success, -1 waiting for the user).
  int? lastStatus;
  String lastStatusMessage = '';

  @override
  UpdatePlatform get platform => UpdatePlatform.android;

  @override
  bool get refusesDowngrade => true;

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> openInstallPermission() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } on PlatformException {
      // Nothing to open: the message already says where the setting is.
    } on MissingPluginException {
      // The same.
    }
  }

  @override
  Future<bool> silentPossible() async {
    try {
      return await _channel.invokeMethod<bool>('silentPossible') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    try {
      await _channel.invokeMethod<void>('install', {'path': file.path, 'silent': silent});
      return UpdateOutcome(
          silent
              ? 'Installing in the background: Android closes C.A.W when it is done; open it again to carry on.'
              : 'Confirm the update in Android\'s installer. C.A.W closes while it installs; open it again after.',
          started: true,
          file: file);
    } on PlatformException catch (e) {
      if (e.code == 'not_allowed') {
        return const UpdateOutcome('Allow C.A.W to install apps in Android\'s settings, then press Update again.',
            needsPermission: true);
      }
      return UpdateOutcome('The installer did not open (${e.message ?? e.code}).', file: file);
    } on MissingPluginException {
      return UpdateOutcome('The installer is not available in this build.', file: file);
    }
  }
}

/// Windows: an installer is opened by the system (the user confirms there); a zip of the app's files is shown in
/// Explorer to unzip by hand: nothing is installed for the user.
class WindowsUpdateInstaller extends UpdateInstaller {
  WindowsUpdateInstaller({Future<ProcessResult> Function(String, List<String>)? run}) : _run = run ?? Process.run;
  final Future<ProcessResult> Function(String, List<String>) _run;

  @override
  UpdatePlatform get platform => UpdatePlatform.windows;

  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    final folder = file.parent.path;
    try {
      if (kind == AssetKind.installer) {
        await _run('explorer', [file.path]);
        return UpdateOutcome('The installer is open: follow it, then start C.A.W again.', started: true, file: file);
      }
      await _run('explorer', ['/select,', file.path]);
    } catch (_) {
      // Explorer didn't open: the message still says where the file is.
    }
    return UpdateOutcome('Downloaded to $folder. Close C.A.W, unzip it into a folder and run caw.exe from there.',
        file: file);
  }
}

/// Linux and the rest: no install; the download link is offered instead.
class NoUpdateInstaller extends UpdateInstaller {
  @override
  UpdatePlatform get platform => UpdatePlatform.other;

  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async =>
      UpdateOutcome('Downloaded to ${file.path}.', file: file);
}
