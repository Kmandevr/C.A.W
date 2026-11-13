// The update check, prompt, downloads and installs: versions and channels, once a day, failures kept quiet, the
// prompt's choices and timing, the Settings row, assets and allowed hosts, cancel, Android's paths, downgrades,
// newer project files refused, and automatic updates (off by default; levels; never while busy).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sha256.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/model/updates/release_version.dart';
import 'package:caw/model/updates/releases.dart';
import 'package:caw/model/updates/update_fetch.dart';
import 'package:caw/model/updates/update_service.dart';
import 'package:caw/platform/update_installer.dart';
import 'package:caw/ui/settings/update_settings.dart';
import 'package:caw/ui/startup_screen.dart';
import 'package:caw/model/startup_progress.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/updates/update_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ReleaseVersion v(String s) => ReleaseVersion.tryParse(s)!;

Map<String, Object?> rel(String tag,
        {bool pre = false, bool draft = false, String body = '', List<String> assets = const [], String date = '2026-11-10T00:00:00Z'}) =>
    {
      'tag_name': tag,
      'name': 'C.A.W. $tag',
      'draft': draft,
      'prerelease': pre,
      'published_at': date,
      'body': body,
      'html_url': 'https://github.com/Kmandevr/C.A.W/releases/tag/$tag',
      'assets': [
        for (final a in assets)
          {'name': a, 'size': 1000, 'browser_download_url': 'https://github.com/Kmandevr/C.A.W/releases/download/$tag/$a'},
      ],
    };

final sample = [
  rel('v1.0.0-alpha.2', pre: true, assets: ['caw-1.0.0-alpha.2-android.apk', 'caw-1.0.0-alpha.2-android-symbols.zip', 'caw-1.0.0-alpha.2-windows.zip']),
  rel('v1.0.0-beta.1', pre: true, assets: ['caw-1.0.0-beta.1-android.apk']),
  rel('v1.0.0-alpha.1', pre: true, assets: ['caw-1.0.0-alpha.1-android.apk']),
  rel('v0.9.0-beta.1', pre: true),
  rel('v2.0.0', draft: true),
  rel('latest-main', pre: true, body: 'Every change: untested builds.\nVersion: 1.0.0-alpha.2\nBuild: abc1234', assets: ['caw-main-android.apk']),
  {'tag_name': 42}, 'junk', // ignored
];

/// A transport with answers by URL; records every request.
class FakeTransport implements UpdateTransport {
  final Map<String, UpdateResponse Function()> answers = {};
  final List<(Uri, Map<String, String>)> requests = [];
  Object? throwing;

  @override
  Future<UpdateResponse> get(Uri url, {required Map<String, String> headers, required Duration timeout}) async {
    requests.add((url, headers));
    if (throwing != null) throw throwing!;
    final a = answers[url.toString()];
    if (a == null) return UpdateResponse(status: 404, body: const Stream.empty());
    return a();
  }

  void json(Uri url, Object? body, {int status = 200}) =>
      answers[url.toString()] = () => UpdateResponse(status: status, body: Stream.value(utf8.encode(jsonEncode(body))));
}

class FakeInstaller extends UpdateInstaller {
  FakeInstaller(this.dir, {this.platform = UpdatePlatform.android, this.allowed = true, this.silent = false, this.downgrades = false});
  final Directory dir;
  @override
  final UpdatePlatform platform;
  bool allowed, silent, downgrades;
  final List<(File, AssetKind, bool)> installs = [];
  int permissionOpened = 0;

  @override
  bool get refusesDowngrade => downgrades;
  @override
  Future<Directory> downloadDir() async => dir;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<bool> silentPossible() async => silent;
  @override
  Future<void> openInstallPermission() async => permissionOpened++;
  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    installs.add((file, kind, silent));
    return UpdateOutcome('installing', started: true, file: file);
  }
}

class ListSource implements UpdateSource {
  ListSource(this.list);
  List<ReleaseInfo> list;
  int calls = 0;
  bool fail = false;
  @override
  String get name => 'test';
  @override
  Future<List<ReleaseInfo>> releases() async {
    calls++;
    if (fail) throw const UpdateFetchError('Offline or unreachable');
    return list;
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('caw-updates'));
  tearDown(() async {
    // A queued settings write can still land while the folder goes: try a few times, never fail the test for it.
    for (var i = 0; i < 5; i++) {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  UpdateService service(
          {String version = '1.0.0-alpha.1',
          String build = '',
          UpdateSource? source,
          FakeTransport? transport,
          FakeInstaller? installer,
          File? store,
          DateTime Function()? clock}) =>
      UpdateService(
        source: source ?? ListSource(parseGitHubReleases(sample)),
        fetcher: UpdateFetcher(transport: transport ?? FakeTransport()),
        installer: installer ?? FakeInstaller(tmp),
        store: store,
        clock: clock,
        version: version,
        build: build,
      );

  group('versions', () {
    test('semver order with pre-releases: alpha < beta < full, numbers as numbers', () {
      final order = ['0.9.0', '1.0.0-alpha.1', '1.0.0-alpha.2', '1.0.0-alpha.10', '1.0.0-beta.1', '1.0.0', '1.0.1-alpha.1', '1.1.0', '2.0.0'];
      for (var i = 0; i + 1 < order.length; i++) {
        expect(v(order[i]) < v(order[i + 1]), isTrue, reason: '${order[i]} < ${order[i + 1]}');
      }
      expect(v('v1.0.0-alpha.1+7'), v('1.0.0-alpha.1'));
      for (final bad in ['latest-main', '1.0', 'v1.0.0-', '01.0.0', '1.0.0-alpha..1', 'x' * 70]) {
        expect(ReleaseVersion.tryParse(bad), isNull, reason: bad);
      }
    });

    test('update steps: a new alpha number is a patch step', () {
      expect(updateStep(v('1.0.0'), v('1.0.1')), UpdateStep.patch);
      expect(updateStep(v('1.0.0'), v('1.1.0')), UpdateStep.minor);
      expect(updateStep(v('1.0.0'), v('2.0.0')), UpdateStep.major);
      expect(updateStep(v('1.0.0-alpha.1'), v('1.0.0-alpha.2')), UpdateStep.patch);
      expect(updateStep(v('1.0.0-alpha.3'), v('1.0.0')), UpdateStep.patch);
    });
  });

  group('channels', () {
    final all = parseGitHubReleases(sample);
    List<String> tags(UpdateChannel c) => [for (final r in releasesFor(all, c)) r.tag];

    test('the junk entries are skipped and the rolling build reads its version and build', () {
      expect(all.length, 6);
      final main = all.firstWhere((r) => r.rolling);
      expect(main.version, v('1.0.0-alpha.2'));
      expect(main.build, 'abc1234');
    });

    test('Stable is the alpha line and full releases, by tag not by GitHub\'s pre-release flag', () {
      expect(tags(UpdateChannel.stable), ['v1.0.0-alpha.2', 'v1.0.0-alpha.1']);
      expect(tags(UpdateChannel.beta), ['v1.0.0-beta.1', 'v1.0.0-alpha.2', 'v1.0.0-alpha.1', 'v0.9.0-beta.1']);
      expect(tags(UpdateChannel.everyChange).first, 'latest-main');
      expect(tags(UpdateChannel.everyChange), isNot(contains('v2.0.0')), reason: 'drafts never');
    });

    test('the update offered per channel', () {
      expect(updateFor(all, UpdateChannel.stable, v('1.0.0-alpha.1'))?.tag, 'v1.0.0-alpha.2');
      expect(updateFor(all, UpdateChannel.stable, v('1.0.0-alpha.2')), isNull);
      expect(updateFor(all, UpdateChannel.beta, v('1.0.0-alpha.2'))?.tag, 'v1.0.0-beta.1');
      expect(updateFor(all, UpdateChannel.everyChange, v('1.0.0-alpha.2'), currentBuild: 'def5678')?.tag, 'latest-main');
      expect(updateFor(all, UpdateChannel.everyChange, v('1.0.0-alpha.2'), currentBuild: 'abc1234')?.tag, 'v1.0.0-beta.1',
          reason: 'the same build is no update');
    });

    test('assets: the APK (not the symbols) on Android, the zip on Windows, none elsewhere', () {
      final r = all.firstWhere((r) => r.tag == 'v1.0.0-alpha.2');
      expect(assetFor(r, UpdatePlatform.android)!.$1.name, 'caw-1.0.0-alpha.2-android.apk');
      expect(assetFor(r, UpdatePlatform.windows)!.$2, AssetKind.zip);
      expect(assetFor(r, UpdatePlatform.other), isNull);
      expect(assetFor(all.firstWhere((r) => r.tag == 'v1.0.0-beta.1'), UpdatePlatform.windows), isNull);
      final installerOnly = parseGitHubReleases([rel('v9.0.0', assets: ['caw-9.0.0-windows.msi', 'caw-9.0.0-windows-setup.exe'])]);
      expect(assetFor(installerOnly.single, UpdatePlatform.windows), isNull, reason: 'no Windows installer is ever run');
    });
  });

  group('the request', () {
    test('one unauthenticated request for ten releases with only Accept and a generic User-Agent', () async {
      final t = FakeTransport()..json(GitHubReleasesSource.url, sample);
      final list = await GitHubReleasesSource(UpdateFetcher(transport: t)).releases();
      expect(list, hasLength(6));
      expect(t.requests.single.$1.toString(), 'https://api.github.com/repos/Kmandevr/C.A.W/releases?per_page=10');
      expect(t.requests.single.$2, {'Accept': 'application/vnd.github+json', 'User-Agent': 'CAW-app'});
    });

    test('offline, 403 (rate limit), garbage and oversized answers fail quietly and keep the last result', () async {
      final t = FakeTransport();
      final s = service(source: GitHubReleasesSource(UpdateFetcher(transport: t)));
      t.throwing = const SocketException('offline');
      expect(await s.check(), isFalse);
      expect(s.lastError, contains('Offline'));
      t.throwing = null;
      t.json(GitHubReleasesSource.url, {'message': 'rate limited'}, status: 403);
      expect(await s.check(), isFalse);
      expect(s.lastError, contains('403'));
      t.answers[GitHubReleasesSource.url.toString()] = () => UpdateResponse(status: 200, body: Stream.value(utf8.encode('<html>')));
      expect(await s.check(), isFalse);
      t.answers[GitHubReleasesSource.url.toString()] =
          () => UpdateResponse(status: 200, body: Stream.value(List.filled(300 * 1024, 32)));
      expect(await s.check(), isFalse);
      expect(s.lastError, 'Too large');
      t.json(GitHubReleasesSource.url, {'not': 'a list'});
      expect(await s.check(), isTrue);
      expect(s.offer, isNull);
    });

    test('at most one automatic check a day, none when automatic checks are off', () async {
      var now = DateTime.utc(2026, 11, 12, 9);
      final src = ListSource(const []);
      final s = service(source: src, clock: () => now);
      await s.checkIfDue();
      await s.checkIfDue();
      expect(src.calls, 1);
      now = now.add(const Duration(hours: 23));
      await s.checkIfDue();
      expect(src.calls, 1);
      now = now.add(const Duration(hours: 2));
      await s.checkIfDue();
      expect(src.calls, 2);
      s.setAuto(false);
      now = now.add(const Duration(days: 3));
      await s.checkIfDue();
      expect(src.calls, 2);
      src.fail = true;
      s.setAuto(true);
      await s.checkIfDue();
      expect(src.calls, 3);
      await s.checkIfDue();
      expect(src.calls, 3, reason: 'a failed check also waits a day');
    });
  });

  group('downloads', () {
    test('allowed hosts: https GitHub and its asset storage only', () {
      for (final ok in [
        'https://github.com/Kmandevr/C.A.W/releases/download/v1/a.apk',
        'https://objects.githubusercontent.com/x',
        'https://release-assets.githubusercontent.com/x',
      ]) {
        expect(allowedDownload(Uri.parse(ok)), isTrue, reason: ok);
      }
      for (final bad in [
        'http://github.com/a.apk',
        'https://evil.com/a.apk',
        'https://github.com.evil.com/a',
        'https://user@github.com/a',
        'https://github.com:8443/a',
        'file:///tmp/a.apk',
      ]) {
        expect(allowedDownload(Uri.parse(bad)), isFalse, reason: bad);
      }
    });

    test('a redirect to another host is refused; a redirect to the asset storage is followed', () async {
      final t = FakeTransport();
      final a = Uri.parse('https://github.com/Kmandevr/C.A.W/releases/download/v1/caw-android.apk');
      t.answers[a.toString()] = () => UpdateResponse(status: 302, location: 'https://evil.example/x.apk', body: const Stream.empty());
      final f = UpdateFetcher(transport: t);
      await expectLater(f.download(a, File('${tmp.path}/x.apk')), throwsA(isA<UpdateFetchError>()));
      t.answers[a.toString()] =
          () => UpdateResponse(status: 302, location: 'https://release-assets.githubusercontent.com/y', body: const Stream.empty());
      t.answers['https://release-assets.githubusercontent.com/y'] =
          () => UpdateResponse(status: 200, length: 3, body: Stream.value([1, 2, 3]));
      final got = await f.download(a, File('${tmp.path}/x.apk'));
      expect(await got.readAsBytes(), [1, 2, 3]);
    });

    test('too large is refused, before and while downloading', () async {
      final t = FakeTransport();
      final a = Uri.parse('https://github.com/Kmandevr/C.A.W/releases/download/v1/a.apk');
      t.answers[a.toString()] = () => UpdateResponse(status: 200, length: 500, body: Stream.value(List.filled(500, 0)));
      final f = UpdateFetcher(transport: t);
      await expectLater(f.download(a, File('${tmp.path}/a.apk'), maxBytes: 100), throwsA(isA<UpdateFetchError>()));
      t.answers[a.toString()] = () => UpdateResponse(status: 200, body: Stream.fromIterable([List.filled(80, 0), List.filled(80, 0)]));
      await expectLater(f.download(a, File('${tmp.path}/a.apk'), maxBytes: 100), throwsA(isA<UpdateFetchError>()));
      expect(File('${tmp.path}/a.apk.part').existsSync(), isFalse);
    });

    test('the first URL must be this repository\'s release download path', () async {
      final f = UpdateFetcher(transport: FakeTransport());
      for (final bad in [
        'https://github.com/a.apk',
        'https://github.com/someone/else/releases/download/v1/a.apk',
        'https://github.com/Kmandevr/C.A.W/releases/download/../../x/a.apk',
        'https://objects.githubusercontent.com/a.apk',
      ]) {
        await expectLater(f.download(Uri.parse(bad), File('${tmp.path}/a.apk')), throwsA(isA<UpdateFetchError>()), reason: bad);
      }
      final parsed = parseGitHubReleases([
        {
          'tag_name': 'v1.0.0',
          'assets': [
            {'name': 'x-android.apk', 'size': 1, 'browser_download_url': 'https://github.com/other/repo/releases/download/v1/x-android.apk'},
          ],
        },
      ]);
      expect(parsed.single.assets, isEmpty, reason: 'an asset outside the pinned path is never offered');
    });

    test('a download that stalls times out', () async {
      final t = FakeTransport();
      final body = StreamController<List<int>>();
      final a = Uri.parse('https://github.com/Kmandevr/C.A.W/releases/download/v1/a.apk');
      t.answers[a.toString()] = () => UpdateResponse(status: 200, length: 1000, body: body.stream);
      final run = UpdateFetcher(transport: t)
          .download(a, File('${tmp.path}/a.apk'), idle: const Duration(milliseconds: 50));
      body.add([1, 2, 3]);
      await expectLater(run, throwsA(isA<UpdateFetchError>().having((e) => e.message, 'message', contains('stalled'))));
      expect(File('${tmp.path}/a.apk.part').existsSync(), isFalse);
      await body.close();
    });

    group('checksums', () {
      final bytes = [1, 2, 3, 4];
      final good = sha256Hex(bytes);
      List<ReleaseInfo> releaseWith({String? digest, String? note, String name = 'caw-1.0.0-alpha.2-android.apk'}) =>
          parseGitHubReleases([
            {
              'tag_name': 'v1.0.0-alpha.2',
              'body': note == null ? '' : 'Notes\nSHA256 $name: $note\n',
              'assets': [
                {
                  'name': name,
                  'size': bytes.length,
                  'browser_download_url': 'https://github.com/Kmandevr/C.A.W/releases/download/v1.0.0-alpha.2/$name',
                  'digest': ?digest,
                },
              ],
            },
          ]);

      test('read from GitHub\'s digest or the notes line; a disagreement is a conflict', () {
        expect(releaseWith(digest: 'sha256:$good').single.assets.single.sha256, good);
        expect(releaseWith(note: good.toUpperCase()).single.assets.single.sha256, good);
        expect(releaseWith().single.assets.single.sha256, isNull);
        expect(releaseWith(digest: 'sha256:$good', note: 'a' * 64).single.assets.single.checksumConflict, isTrue);
      });

      Future<(UpdateOutcome, FakeInstaller)> run(List<ReleaseInfo> list, {UpdatePlatform platform = UpdatePlatform.android, List<int>? served}) async {
        final t = FakeTransport();
        final inst = FakeInstaller(tmp, platform: platform);
        final s = service(source: ListSource(list), transport: t, installer: inst);
        await s.check();
        final r = s.offer!;
        final asset = assetFor(r, platform)!.$1;
        final body = served ?? bytes;
        t.answers[asset.url.toString()] = () => UpdateResponse(status: 200, length: body.length, body: Stream.value(body));
        return (await s.downloadAndInstall(r), inst);
      }

      test('a matching download installs; a mismatch is deleted and refused', () async {
        var (o, inst) = await run(releaseWith(note: good));
        expect(o.started, isTrue);
        expect(inst.installs, hasLength(1));
        (o, inst) = await run(releaseWith(note: good), served: [9, 9, 9, 9]);
        expect(o.message, contains('did not match'));
        expect(inst.installs, isEmpty);
        expect(tmp.listSync().whereType<File>().where((f) => f.path.endsWith('.apk')), isEmpty);
        (o, inst) = await run(releaseWith(digest: 'sha256:$good', note: 'a' * 64));
        expect(inst.installs, isEmpty, reason: 'digest and notes disagree');
      });

      test('no published checksum: Android goes on (it checks the signature), Windows says unverified', () async {
        var (o, inst) = await run(releaseWith());
        expect(inst.installs, hasLength(1));
        (o, inst) = await run(releaseWith(name: 'caw-1.0.0-alpha.2-windows.zip'), platform: UpdatePlatform.windows);
        expect(o.message, startsWith('Unverified'));
      });
    });

    test('cancel stops the download and deletes the partial file', () async {
      final t = FakeTransport();
      final body = StreamController<List<int>>();
      final a = Uri.parse('https://github.com/Kmandevr/C.A.W/releases/download/v1/a.apk');
      t.answers[a.toString()] = () => UpdateResponse(status: 200, length: 1000, body: body.stream);
      final cancel = DownloadCancel();
      final run = UpdateFetcher(transport: t).download(a, File('${tmp.path}/a.apk'), cancel: cancel, progress: (got, _) {
        if (got >= 10) cancel.cancel();
      });
      body.add(List.filled(10, 1));
      await expectLater(run, throwsA(isA<DownloadCancelled>()));
      expect(File('${tmp.path}/a.apk').existsSync(), isFalse);
      expect(File('${tmp.path}/a.apk.part').existsSync(), isFalse);
      await body.close();
    });

    test('Update downloads the APK, deletes stale downloads and hands it to the installer', () async {
      File('${tmp.path}/old.apk').writeAsStringSync('old');
      final t = FakeTransport();
      final inst = FakeInstaller(tmp);
      final s = service(transport: t, installer: inst);
      await s.check();
      final r = s.offer!;
      t.answers[r.assets.first.url.toString()] = () => UpdateResponse(status: 200, length: 2, body: Stream.value([7, 7]));
      final o = await s.downloadAndInstall(r);
      expect(o.started, isTrue);
      expect(inst.installs.single.$1.path, endsWith('caw-1.0.0-alpha.2-android.apk'));
      expect(inst.installs.single.$3, isFalse, reason: 'a user\'s Update is never silent');
      expect(File('${tmp.path}/old.apk').existsSync(), isFalse);
    });

    test('Android: install not allowed yet sends the user to the setting instead of downloading', () async {
      final t = FakeTransport();
      final inst = FakeInstaller(tmp, allowed: false);
      final s = service(transport: t, installer: inst);
      await s.check();
      final o = await s.downloadAndInstall(s.offer!);
      expect(o.needsPermission, isTrue);
      expect(t.requests.where((r) => r.$1.host == 'github.com'), isEmpty);
      expect(inst.installs, isEmpty);
    });

    test('Linux (no asset for the platform) falls back to the download link', () async {
      final s = service(installer: FakeInstaller(tmp, platform: UpdatePlatform.other));
      await s.check();
      final o = await s.downloadAndInstall(s.offer!);
      expect(o.started, isFalse);
      expect(o.message, contains('download link'));
    });
  });

  group('the Android channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('caw/updates.test');
    final calls = <MethodCall>[];
    void handle(Future<Object?> Function(MethodCall) h) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) {
          calls.add(c);
          return h(c);
        });
    tearDown(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('install not allowed answers with the permission path', () async {
      handle((c) async => c.method == 'install' ? throw PlatformException(code: 'not_allowed') : false);
      final i = AndroidUpdateInstaller(channel: channel);
      expect(await i.canInstall(), isFalse);
      final o = await i.install(File('${tmp.path}/a.apk'), AssetKind.apk);
      expect(o.needsPermission, isTrue);
    });

    test('automatic: silent where Android allows it (only in the background), else the system prompt once', () async {
      var silent = true;
      handle((c) async => switch (c.method) {
            'canInstall' => true,
            'silentPossible' => silent,
            _ => null,
          });
      final t = FakeTransport();
      final s = service(transport: t, installer: null)
        ..setAutoLevel(AutoUpdateLevel.patches);
      final android = AndroidUpdateInstaller(channel: channel);
      final s2 = UpdateService(
          source: s.source, fetcher: s.fetcher, installer: _DirInstaller(android, tmp), version: '1.0.0-alpha.1')
        ..setAutoLevel(AutoUpdateLevel.patches);
      await s2.check();
      t.answers[s2.offer!.assets.first.url.toString()] = () => UpdateResponse(status: 200, length: 1, body: Stream.value([1]));
      var saved = 0;
      Future<void> save() async => saved++;
      expect(await s2.autoStep(busy: false, saveFirst: save), isNull, reason: 'silent waits for the background');
      final o = await s2.autoStep(busy: false, background: true, saveFirst: save);
      expect(o?.started, isTrue);
      expect(calls.lastWhere((c) => c.method == 'install').arguments['silent'], isTrue);
      expect(saved, 1, reason: 'the project is saved first');
      silent = false;
      calls.clear();
      await s2.autoStep(busy: false, saveFirst: save);
      expect(calls.lastWhere((c) => c.method == 'install').arguments['silent'], isFalse);
      calls.clear();
      await s2.autoStep(busy: false, saveFirst: save);
      expect(calls.where((c) => c.method == 'install'), isEmpty, reason: 'the prompt once per version');
    });
  });

  group('automatic updates', () {
    test('off by default, and nothing installs when off', () async {
      final s = service();
      expect(s.autoLevel, AutoUpdateLevel.off);
      expect(s.autoPreRelease, isFalse);
      expect(s.autoInstall, isFalse);
      await s.check();
      expect(await s.autoStep(busy: false, background: true), isNull);
    });

    test('each Stable level against patch, minor and major versions', () async {
      final list = parseGitHubReleases([rel('v1.0.1', assets: ['a-android.apk']), rel('v1.1.0'), rel('v2.0.0')]);
      final s = service(version: '1.0.0', source: ListSource(list));
      await s.check();
      expect(s.offer?.tag, 'v2.0.0', reason: 'the prompt still offers the newest');
      final expected = {
        AutoUpdateLevel.off: null,
        AutoUpdateLevel.patches: 'v1.0.1',
        AutoUpdateLevel.minor: 'v1.1.0',
        AutoUpdateLevel.all: 'v2.0.0',
      };
      for (final e in expected.entries) {
        s.setAutoLevel(e.key);
        expect(s.autoTarget?.tag, e.value, reason: e.key.name);
      }
    });

    test('Beta and Every change take the channel\'s newest when on, whatever the step; never a downgrade', () async {
      final s = service(version: '1.0.0-alpha.2', build: 'def5678');
      await s.check();
      s.setChannel(UpdateChannel.beta);
      expect(s.autoTarget, isNull);
      s.setAutoPreRelease(true);
      expect(s.autoTarget?.tag, 'v1.0.0-beta.1');
      s.setChannel(UpdateChannel.everyChange);
      expect(s.autoTarget?.tag, 'latest-main');
      final old = service(version: '3.0.0', source: ListSource(parseGitHubReleases([rel('v1.0.0')])))..setAutoLevel(AutoUpdateLevel.all);
      await old.check();
      expect(old.autoTarget, isNull);
    });

    test('never while playing, recording or rendering (busy)', () async {
      final t = FakeTransport();
      final inst = FakeInstaller(tmp, silent: true);
      final s = service(transport: t, installer: inst)..setAutoLevel(AutoUpdateLevel.all);
      await s.check();
      expect(await s.autoStep(busy: true, background: true), isNull);
      expect(t.requests.where((r) => r.$1.host == 'github.com'), isEmpty, reason: 'not even the download');
      expect(inst.installs, isEmpty);
    });

    test('Windows: a background download with a note for the next start, nothing installed', () async {
      final t = FakeTransport();
      final store = File('${tmp.path}/settings/updates.json');
      final inst = FakeInstaller(Directory('${tmp.path}/dl'), platform: UpdatePlatform.windows);
      final s = service(transport: t, installer: inst, store: store)..setAutoLevel(AutoUpdateLevel.all);
      await s.check();
      final zip = assetFor(s.offer!, UpdatePlatform.windows)!.$1;
      t.answers[zip.url.toString()] = () => UpdateResponse(status: 200, length: 1, body: Stream.value([1]));
      final o = await s.autoStep(busy: false);
      expect(o?.message, contains('downloaded'));
      expect(inst.installs, isEmpty);
      for (var i = 0; i < 100 && !(store.existsSync() && store.readAsStringSync().contains('downloaded_note')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final next = service(store: store);
      await next.load();
      expect(next.takeDownloadedNote(), contains('unzip'));
      expect(next.takeDownloadedNote(), isNull, reason: 'said once');
    });
  });

  group('prompt choices', () {
    test('Not now asks again next launch or after a day; Don\'t ask again persists', () async {
      var now = DateTime.utc(2026, 11, 12);
      final store = File('${tmp.path}/updates.json');
      final s = service(store: store, clock: () => now);
      await s.check();
      expect(s.shouldPrompt, isTrue);
      s.prompted();
      s.notNow();
      expect(s.shouldPrompt, isFalse);
      now = now.add(const Duration(hours: 25));
      expect(s.shouldPrompt, isTrue);
      s.prompted();
      s.dontAskAgain();
      expect(s.shouldPrompt, isFalse);
      for (var i = 0; i < 200 && !(store.existsSync() && store.readAsStringSync().contains('"prompts":false')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final next = service(store: store, clock: () => now);
      await next.load();
      expect(next.prompts, isFalse);
      expect(next.startupLine, 'Update available: v1.0.0-alpha.2', reason: 'Settings and the startup line still show it');
      next.setPrompts(true);
      await next.check();
      expect(next.shouldPrompt, isTrue);
    });
  });

  group('projects from a newer version', () {
    test('are refused whole and left as they are; the default project opens and says why', () async {
      final storage = ProjectStorage(tmp);
      final p = ProjectDoc(id: 'p1', name: 'From the future');
      final json = p.toJson()..['caw_app_project'] = ProjectDoc.fileVersion + 1;
      final file = File('${tmp.path}/p1.json');
      await storage.save(p);
      final path = (await tmp.list().firstWhere((e) => e.path.endsWith('.json'))).path;
      await File(path).writeAsString(jsonEncode(json));
      final before = await File(path).readAsString();
      await expectLater(storage.load('p1'), throwsA(isA<NewerProjectFormat>()));
      await storage.setLastOpened('p1');
      final s = AppState(settings: Settings());
      addTearDown(s.dispose);
      await s.openStorage(storage);
      expect(s.project.id, isNot('p1'));
      expect(s.openError, contains('newer version'));
      await s.flush();
      expect(await File(path).readAsString(), before);
      expect(file.path, isNotEmpty);
    });
  });

  group('widgets', () {
    /// Lets real file and stream work finish, frame by frame, until [done].
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(360, 740)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: child));
    }

    testWidgets('the startup screen shows an update an earlier check found, at 360 dp', (tester) async {
      final p = StartupProgress();
      addTearDown(p.dispose);
      await pump(tester, StartupScreen(progress: p, version: '1.0.0-alpha.1', updateLine: 'Update available: v1.0.0-alpha.2'),
          size: const Size(360, 640));
      await tester.pumpAndSettle();
      expect(find.text('Update available: v1.0.0-alpha.2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Updates row at 360 dp: status, privacy, notes, Update now, channel and automatic updates',
        (tester) async {
      final t = FakeTransport();
      final inst = FakeInstaller(tmp);
      late UpdateService s;
      await tester.runAsync(() async {
        s = service(transport: t, installer: inst);
        await s.check();
      });
      await pump(tester, Scaffold(body: SingleChildScrollView(child: UpdateSettings(service: s))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Update available: v1.0.0-alpha.2'), findsOneWidget);
      expect(find.text(updatePrivacyNote), findsOneWidget);
      expect(find.byKey(const ValueKey('update-notes')), findsNothing, reason: 'no notes in this release');
      expect(find.text('Off'), findsOneWidget, reason: 'automatic updates default to Off');
      t.answers[s.offer!.assets.first.url.toString()] = () => UpdateResponse(status: 200, length: 1, body: Stream.value([1]));
      await tester.tap(find.byKey(const ValueKey('update-now-settings')));
      await until(tester, () => inst.installs.isNotEmpty);
      expect(inst.installs, hasLength(1));
      s.setChannel(UpdateChannel.everyChange);
      await tester.pumpAndSettle();
      expect(find.text(UpdateChannel.everyChange.description), findsOneWidget);
      expect(find.byKey(const ValueKey('switch-about.updates.install')), findsOneWidget, reason: 'a switch, not levels');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Install another version lists the channel\'s releases with badges, betas on request', (tester) async {
      late UpdateService s;
      await tester.runAsync(() async {
        s = service(version: '1.0.0-alpha.2');
        await s.check();
      });
      await pump(tester, InstallAnotherVersionPage(service: s));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('release-v1.0.0-alpha.1')), findsOneWidget);
      expect(find.byKey(const ValueKey('release-v1.0.0-beta.1')), findsNothing);
      expect(find.textContaining('Installed'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('versions-prerelease')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('release-v1.0.0-beta.1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android downgrade: the uninstall warning and steps, no download', (tester) async {
      final t = FakeTransport();
      final inst = FakeInstaller(tmp, downgrades: true);
      late UpdateService s;
      await tester.runAsync(() async {
        s = service(version: '1.0.0-alpha.2', transport: t, installer: inst);
        await s.check();
      });
      await pump(tester, InstallAnotherVersionPage(service: s));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('release-v1.0.0-alpha.1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('install-v1.0.0-alpha.1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('uninstalling deletes'), findsOneWidget);
      expect(find.byKey(const ValueKey('downgrade-continue')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('downgrade-copy-link')));
      await tester.pumpAndSettle();
      expect(t.requests.where((r) => r.$1.host == 'github.com'), isEmpty);
      expect(inst.installs, isEmpty);
    });

    testWidgets('Windows downgrade offers restore points of every project first', (tester) async {
      final inst = FakeInstaller(tmp, platform: UpdatePlatform.windows);
      late UpdateService s;
      late AppState state;
      await tester.runAsync(() async {
        s = service(version: '1.0.0-alpha.2', installer: inst);
        await s.check();
        state = AppState(settings: Settings());
        final storage = ProjectStorage(Directory('${tmp.path}/projects')..createSync());
        await storage.save(ProjectDoc(id: 'p1', name: 'Song'));
        await storage.setLastOpened('p1');
        await state.openStorage(storage);
      });
      addTearDown(state.dispose);
      await pump(tester, InstallAnotherVersionPage(service: s, state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('release-v1.0.0-alpha.1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('install-v1.0.0-alpha.1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('may not open in an older one'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('downgrade-backup')));
      await until(tester, () => find.textContaining('Restore points made').evaluate().isNotEmpty);
      expect(find.textContaining('Restore points made for 1 project'), findsOneWidget);
    });

    testWidgets('the prompt: not over the startup screen, not while busy, then once with three choices', (tester) async {
      late UpdateService s;
      await tester.runAsync(() async {
        s = service();
        await s.check();
      });
      final state = AppState(settings: Settings());
      addTearDown(state.dispose);
      var busy = true;
      await pump(
          tester,
          UpdatePromptHost(
              state: state, service: s, busy: () => busy, settle: const Duration(milliseconds: 10), child: const Scaffold()));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('update-prompt')), findsNothing, reason: 'not ready: the startup screen is up');
      state.ready = true;
      state.clipSelectionChanged();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-prompt')), findsNothing, reason: 'playing');
      busy = false;
      state.clipSelectionChanged(); // playback stopped
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-prompt')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-never')));
      await tester.pumpAndSettle();
      expect(s.prompts, isFalse);
      state.clipSelectionChanged();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-prompt')), findsNothing);
    });
  });
}

/// The Android installer with the test's download folder.
class _DirInstaller extends UpdateInstaller {
  _DirInstaller(this.inner, this.dir);
  final AndroidUpdateInstaller inner;
  final Directory dir;
  @override
  UpdatePlatform get platform => UpdatePlatform.android;
  @override
  Future<Directory> downloadDir() async => dir;
  @override
  Future<bool> canInstall() => inner.canInstall();
  @override
  Future<bool> silentPossible() => inner.silentPossible();
  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) => inner.install(file, kind, silent: silent);
}
