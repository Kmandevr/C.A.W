// Installing a downloaded update, one implementation per platform: Android hands the APK to the system installer
// (caw/updates, UpdateInstaller.kt), Windows swaps in staged files at the start or shows the downloaded zip, others
// offer the link.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../model/updates/releases.dart';
import '../model/updates/windows_stage.dart';

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

  /// Android: the installed APK (`ApplicationInfo.sourceDir`), which a small update is rebuilt from; null where
  /// there is none or it is split into several APKs.
  Future<String?> installedPackage() async => null;

  /// Windows: the folder caw.exe runs from, where a small update stages and swaps its files; null elsewhere.
  Future<Directory?> installDir() async => null;

  /// At the start, before the app is shown: finishes a small update staged by the last run (Windows). [relaunch]
  /// true means the new build was started and this process should exit; [note] is said once.
  Future<({bool relaunch, String? note})> finishStaged() async => (relaunch: false, note: null);
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
  Future<String?> installedPackage() async {
    try {
      return await _channel.invokeMethod<String>('installedApk');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
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

/// Windows: a small update stages the changed files beside the app and swaps them in at the next start
/// (`WindowsStage`), then starts the new build once; a full update's zip is shown in Explorer to unzip by hand.
class WindowsUpdateInstaller extends UpdateInstaller {
  WindowsUpdateInstaller({Future<ProcessResult> Function(String, List<String>)? run, this.appDir})
      : _run = run ?? Process.run;
  final Future<ProcessResult> Function(String, List<String>) _run;

  /// The app's folder (tests); the running caw.exe's folder otherwise.
  final Directory? appDir;

  @override
  UpdatePlatform get platform => UpdatePlatform.windows;

  @override
  Future<Directory?> installDir() async => appDir ?? File(Platform.resolvedExecutable).parent;

  @override
  Future<({bool relaunch, String? note})> finishStaged() async {
    final dir = await installDir();
    if (dir == null) return (relaunch: false, note: null);
    final stage = WindowsStage(dir);
    try {
      final result = await stage.swapIn();
      if (result == SwapResult.swapped) {
        // This process still runs the old files (renamed aside); the new build starts in a fresh one.
        await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
        return (relaunch: true, note: null);
      }
    } catch (_) {
      // Left as it was: the note (if any) says so.
    }
    return (relaunch: false, note: await stage.takeNote());
  }

  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    final folder = file.parent.path;
    try {
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
