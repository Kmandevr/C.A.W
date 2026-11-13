// Small updates: the manifest read with limits, patches rebuilding their targets byte for byte (fixtures made by
// scripts/update-delta.js), Windows staging and the swap at the next start (and putting things back), and the
// service falling back to the whole download on a checksum mismatch or a missing previous build.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/model/sha256.dart';
import 'package:caw/model/updates/delta_update.dart';
import 'package:caw/model/updates/patch_format.dart';
import 'package:caw/model/updates/releases.dart';
import 'package:caw/model/updates/update_fetch.dart';
import 'package:caw/model/updates/update_manifest.dart';
import 'package:caw/model/updates/update_service.dart';
import 'package:caw/model/updates/windows_stage.dart';
import 'package:caw/platform/update_installer.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixtures: `CAW_WRITE_FIXTURES=$PWD/app/test/fixtures/updates node --test scripts/update-delta.test.js` writes them:
// an old and a new build (base.zip, target.zip: an unchanged entry, a stored one changed in a few bytes, one
// removed, one added, a different signing-block stand-in) and the APK and Windows patches between them.
const fixtures = 'test/fixtures/updates';
File fixture(String name) => File('$fixtures/$name');

/// The files of a zip (stored or deflated entries; enough for the fixtures).
Map<String, Uint8List> unzip(Uint8List b) {
  final d = ByteData.sublistView(b);
  var eocd = b.length - 22;
  while (d.getUint32(eocd, Endian.little) != 0x06054b50) {
    eocd--;
  }
  final count = d.getUint16(eocd + 10, Endian.little);
  var p = d.getUint32(eocd + 16, Endian.little);
  final out = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    final method = d.getUint16(p + 10, Endian.little);
    final comp = d.getUint32(p + 20, Endian.little);
    final nameLen = d.getUint16(p + 28, Endian.little);
    final extra = d.getUint16(p + 30, Endian.little), comment = d.getUint16(p + 32, Endian.little);
    final lho = d.getUint32(p + 42, Endian.little);
    final name = utf8.decode(b.sublist(p + 46, p + 46 + nameLen));
    p += 46 + nameLen + extra + comment;
    final start = lho + 30 + d.getUint16(lho + 26, Endian.little) + d.getUint16(lho + 28, Endian.little);
    final raw = b.sublist(start, start + comp);
    out[name] = method == 0 ? raw : Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
  }
  return out;
}

Future<void> writeTree(Directory dir, Map<String, Uint8List> files) async {
  for (final e in files.entries) {
    final f = File('${dir.path}/${e.key}');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(e.value);
  }
}

Future<Map<String, String>> treeHashes(Directory dir) async => {
      for (final f in dir.listSync(recursive: true).whereType<File>())
        if (!f.path.contains('.caw-update') && !f.path.endsWith('.caw-old'))
          f.path.substring(dir.path.length + 1).replaceAll('\\', '/'): sha256OfFileSync(f.path),
    };

/// A CAWPATCH v1 of whole files only ([files] path → bytes), for cases the fixtures don't hold.
List<int> dataPatch(Map<String, List<int>> files) {
  final body = BytesBuilder();
  void varint(int n) {
    do {
      var b = n & 0x7f;
      n >>= 7;
      if (n > 0) b |= 0x80;
      body.addByte(b);
    } while (n > 0);
  }

  List<int> hexBytes(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
  varint(files.length);
  for (final e in files.entries) {
    final p = utf8.encode(e.key);
    varint(p.length);
    body.add(p);
    varint(e.value.length);
    body.add(hexBytes(sha256Hex(e.value)));
    body.addByte(0); // no base
    body.addByte(2); // DATA
    varint(e.value.length);
    body.add(e.value);
    body.addByte(0); // END
  }
  return [...ascii.encode('CAWPATCH'), 1, ...ZLibEncoder(raw: true).convert(body.takeBytes())];
}

const tag = 'latest-main';
const prefix = 'https://github.com/Kmandevr/C.A.W/releases/download/$tag/';

class FakeTransport implements UpdateTransport {
  final Map<String, List<int>> files = {};
  final List<String> requested = [];
  @override
  Future<UpdateResponse> get(Uri url, {required Map<String, String> headers, required Duration timeout}) async {
    requested.add(url.pathSegments.last);
    final f = files[url.toString()];
    if (f == null) return UpdateResponse(status: 404, body: const Stream.empty());
    return UpdateResponse(status: 200, length: f.length, body: Stream.value(f));
  }
}

class FakeInstaller extends UpdateInstaller {
  FakeInstaller(this.dir, {required this.platform, this.apk, this.app});
  final Directory dir;
  @override
  final UpdatePlatform platform;
  String? apk;
  Directory? app;
  final List<File> installed = [];
  final List<Uint8List> installedBytes = [];
  @override
  Future<Directory> downloadDir() async => dir;
  @override
  Future<String?> installedPackage() async => apk;
  @override
  Future<Directory?> installDir() async => app;
  @override
  Future<UpdateOutcome> install(File file, AssetKind kind, {bool silent = false}) async {
    installed.add(file);
    installedBytes.add(await file.readAsBytes());
    return UpdateOutcome('installing', started: true, file: file);
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('caw-delta'));
  tearDown(() async {
    for (var i = 0; i < 5; i++) {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  final base = fixture('base.zip').readAsBytesSync();
  final target = fixture('target.zip').readAsBytesSync();
  final manifestBytes = fixture('caw-main-update.json').readAsBytesSync();
  final manifest = UpdateManifest.parse(jsonDecode(utf8.decode(manifestBytes)))!;

  group('manifest', () {
    test('reads artefacts, files and patches', () {
      expect(manifest.artifacts.map((a) => a.asset), ['caw-main-android.apk', 'caw-main-windows.zip']);
      expect(manifest.artifact('caw-main-android.apk')!.sha256, sha256Hex(target));
      expect(manifest.artifact('caw-main-android.apk')!.files.map((f) => f.path),
          containsAll(['assets/same.txt', 'lib/libapp.so', 'res/new.txt']));
      expect(manifest.patchFor('caw-main-android.apk', 'apk')!.baseSha256, sha256Hex(base));
      expect(manifest.patchFor('caw-main-windows.zip', 'files'), isNotNull);
      expect(manifest.patchFor('caw-main-windows.zip', 'apk'), isNull);
    });

    test('refuses other formats and skips entries out of shape or over the limits', () {
      expect(UpdateManifest.parse('junk'), isNull);
      expect(UpdateManifest.parse({'caw_update_manifest': 2}), isNull);
      final sha = 'a' * 64;
      final m = UpdateManifest.parse({
        'caw_update_manifest': 1,
        'version': 'x' * 100, // too long: dropped
        'artifacts': [
          {'asset': 'ok.apk', 'kind': 'apk', 'size': 3, 'sha256': sha, 'files': [
            {'path': 'a', 'size': 1, 'sha256': sha},
            {'path': 'b', 'size': -1, 'sha256': sha}, // bad size
            {'path': 'c', 'size': 1, 'sha256': 'XYZ'}, // bad hash
          ]},
          {'asset': '../evil', 'kind': 'apk', 'size': 3, 'sha256': sha}, // not an asset name
          {'asset': 'odd.bin', 'kind': 'exe', 'size': 3, 'sha256': sha}, // unknown kind
          {'asset': 'big.zip', 'kind': 'files', 'size': 3, 'sha256': sha,
            'files': List.generate(UpdateManifest.maxFiles + 1, (i) => {'path': 'f$i', 'size': 1, 'sha256': sha})},
        ],
        'patches': [
          {'asset': 'p.cawpatch', 'kind': 'apk', 'target': 'ok.apk', 'base_sha256': sha, 'size': 1, 'sha256': sha},
          {'asset': 'q.cawpatch', 'kind': 'apk', 'target': 'ok.apk', 'size': 1, 'sha256': sha}, // no base
        ],
      })!;
      expect(m.version, '');
      expect(m.artifacts.map((a) => a.asset), ['ok.apk']);
      expect(m.artifacts.single.files.map((f) => f.path), ['a']);
      expect(m.patches.map((p) => p.asset), ['p.cawpatch']);
    });

    test('paths a patch may write', () {
      for (final p in ['caw.exe', 'data/app.so', 'data/flutter_assets/x y.bin']) {
        expect(safeRelativePath(p), isTrue, reason: p);
      }
      for (final p in ['', '/etc/x', '../x', 'a/../b', 'a\\b', 'C:x', 'a//b', './a', 'a/.', 'a.', 'a\u0001']) {
        expect(safeRelativePath(p), isFalse, reason: p);
      }
      // Windows device names, with or without an extension, in any case and at any depth.
      for (final p in ['CON', 'nul', 'Aux.txt', 'prn.dll', 'data/COM1', 'data/com9.dll', 'LPT1', 'x/lpt9.so', 'nul .txt']) {
        expect(safeRelativePath(p), isFalse, reason: p);
      }
      for (final p in ['console.dll', 'com10', 'data/connect.txt', 'nully', 'lpt0']) {
        expect(safeRelativePath(p), isTrue, reason: p);
      }
      // The update's own folder.
      for (final p in ['.caw-update/stage.json', '.CAW-Update/files/caw.exe']) {
        expect(safeRelativePath(p), isFalse, reason: p);
      }
    });
  });

  group('patches', () {
    test('an APK patch rebuilds the target byte for byte from the old APK', () async {
      final b = File('${tmp.path}/base.apk')..writeAsBytesSync(base);
      final out = '${tmp.path}/out.apk';
      final got = rebuildSingleFile(
          patchPath: fixture('caw-main-android.cawpatch').path,
          basePath: b.path,
          baseSha256: sha256Hex(base),
          outPath: out,
          wantSha256: sha256Hex(target));
      expect(got, sha256Hex(target));
      expect(File(out).readAsBytesSync(), target);
    });

    test('refused against another base, for another result or when damaged, and nothing is left', () {
      final b = File('${tmp.path}/base.apk')..writeAsBytesSync(base);
      final out = '${tmp.path}/out.apk';
      String run(String patch, {String? baseSha, String? want}) => rebuildSingleFile(
          patchPath: patch, basePath: b.path, baseSha256: baseSha ?? sha256Hex(base), outPath: out, wantSha256: want ?? sha256Hex(target));
      final patch = fixture('caw-main-android.cawpatch').path;
      expect(() => run(patch, baseSha: 'b' * 64), throwsA(isA<PatchError>()));
      expect(() => run(patch, want: 'c' * 64), throwsA(isA<PatchError>()));
      // The right header but another base file's bytes: the copies rebuild something else.
      b.writeAsBytesSync(target);
      expect(() => run(patch), throwsA(isA<PatchError>()));
      expect(File(out).existsSync(), isFalse);
      b.writeAsBytesSync(base);
      // Truncated, and one byte flipped inside the compressed body.
      final bytes = fixture('caw-main-android.cawpatch').readAsBytesSync();
      final cut = File('${tmp.path}/cut.cawpatch')..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      expect(() => run(cut.path), throwsA(anything));
      final flipped = Uint8List.fromList(bytes)..[bytes.length - 40] ^= 0x55;
      final bad = File('${tmp.path}/bad.cawpatch')..writeAsBytesSync(flipped);
      expect(() => run(bad.path), throwsA(anything));
      expect(File(out).existsSync(), isFalse);
      final junk = File('${tmp.path}/junk.cawpatch')..writeAsStringSync('not a patch');
      expect(() => run(junk.path), throwsA(isA<PatchError>()));
    });
  });

  group('Windows staging and swap', () {
    Map<String, String> want() => {for (final f in manifest.artifact('caw-main-windows.zip')!.files) f.path: f.sha256};

    Future<Directory> installOld() async {
      final app = Directory('${tmp.path}/app')..createSync();
      await writeTree(app, unzip(base));
      return app;
    }

    test('stages only the changed files, swaps them in at the start, and deletes the old ones a start later', () async {
      final app = await installOld();
      final stage = WindowsStage(app);
      await stage.begin();
      final staged = stageFiles(
          patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want());
      expect(staged.keys.toSet(), {'lib/libapp.so', 'res/new.txt'});
      await stage.commit('Every change (abc1234)', staged);
      expect(await stage.ready, isTrue);
      expect(await stage.swapIn(), SwapResult.swapped);
      final now = await treeHashes(app);
      for (final e in want().entries) {
        expect(now[e.key], e.value, reason: e.key);
      }
      expect(File('${app.path}/lib/libapp.so.caw-old').existsSync(), isTrue);
      expect(await stage.takeNote(), contains('Updated to Every change (abc1234)'));
      expect(await stage.ready, isFalse);
      expect(await stage.swapIn(), SwapResult.nothing);
      expect(File('${app.path}/lib/libapp.so.caw-old').existsSync(), isFalse);
    });

    test('the relaunch after a swap passes the command-line arguments on (a file opened with C.A.W)', () async {
      final app = await installOld();
      final stage = WindowsStage(app);
      await stage.begin();
      final staged = stageFiles(
          patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want());
      await stage.commit('v2', staged);
      final started = <(String, List<String>)>[];
      final installer = WindowsUpdateInstaller(appDir: app, start: (exe, args) async => started.add((exe, args)));
      const args = [r'C:\Users\me\Songs\song.caw', '--flag'];
      final first = await installer.finishStaged(args);
      expect(first.relaunch, isTrue);
      expect(started, hasLength(1));
      expect(started.single.$1, Platform.resolvedExecutable);
      expect(started.single.$2, args);
      // Nothing staged: no relaunch, the note said once.
      final again = await installer.finishStaged(args);
      expect(again.relaunch, isFalse);
      expect(again.note, contains('Updated to v2'));
      expect(started, hasLength(1));
    });

    test('two files that differ only in case are refused (one file on Windows)', () async {
      final app = await installOld();
      final a = utf8.encode('one'), b = utf8.encode('two');
      final patch = File('${tmp.path}/case.cawpatch')
        ..writeAsBytesSync(dataPatch({'data/App.so': a, 'data/app.so': b}));
      final stage = WindowsStage(app);
      await stage.begin();
      expect(
          () => stageFiles(patchPath: patch.path, installDir: app.path, stageDir: stage.files.path, expected: {
                'data/App.so': sha256Hex(a),
                'data/app.so': sha256Hex(b),
              }),
          throwsA(isA<PatchError>().having((e) => e.message, 'message', contains('twice'))));
    });

    test('a start after an interrupted swap undoes only the files it began on', () async {
      final app = await installOld();
      final before = await treeHashes(app);
      final stage = WindowsStage(app);
      await stage.begin();
      final staged = stageFiles(
          patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want());
      await stage.commit('v2', staged);
      // The swap stopped after replacing lib/libapp.so and moving in the new res/new.txt.
      final swapping = File('${stage.root.path}/swapping');
      swapping.writeAsStringSync('${jsonEncode({'label': 'v2'})}\n'
          '${jsonEncode({'path': 'lib/libapp.so', 'added': false})}\n'
          '${jsonEncode({'path': 'res/new.txt', 'added': true})}\n'
          '{"path": "cut off');
      File('${app.path}/lib/libapp.so').renameSync('${app.path}/lib/libapp.so.caw-old');
      File('${stage.files.path}/lib/libapp.so').renameSync('${app.path}/lib/libapp.so');
      File('${stage.files.path}/res/new.txt').renameSync('${app.path}/res/new.txt');
      expect(await stage.swapIn(), SwapResult.failed);
      expect(await treeHashes(app), before);
      expect(File('${app.path}/res/new.txt').existsSync(), isFalse);
      expect(await stage.ready, isFalse);
    });

    test('recovery leaves alone a listed file the swap never reached, and its stale set-aside copy', () async {
      final app = await installOld();
      final stage = WindowsStage(app);
      await stage.begin();
      final staged = stageFiles(
          patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want());
      await stage.commit('v2', staged);
      // An earlier update's set-aside copy of res/new.txt, never deleted; the swap stopped after lib/libapp.so.
      File('${app.path}/res/new.txt.caw-old').writeAsStringSync('an earlier build');
      final before = await treeHashes(app);
      File('${stage.root.path}/swapping').writeAsStringSync('${jsonEncode({'label': 'v2'})}\n'
          '${jsonEncode({'path': 'lib/libapp.so', 'added': false})}\n');
      File('${app.path}/lib/libapp.so').renameSync('${app.path}/lib/libapp.so.caw-old');
      expect(await stage.swapIn(), SwapResult.failed);
      expect(await treeHashes(app), before);
      expect(File('${app.path}/res/new.txt').existsSync(), isFalse); // the stale copy did not come back
    });

    test('only set-aside files inside the app folder are deleted', () async {
      final app = await installOld();
      final outside = File('${tmp.path}/app-other/keep.caw-old')..createSync(recursive: true);
      final up = File('${tmp.path}/keep2.caw-old')..createSync();
      final inside = File('${app.path}/lib/libapp.so.caw-old')..writeAsStringSync('old');
      final stage = WindowsStage(app);
      await stage.root.create(recursive: true);
      File('${stage.root.path}/cleanup.json')
          .writeAsStringSync(jsonEncode([outside.path, '${app.path}/../keep2.caw-old', inside.path]));
      expect(await stage.swapIn(), SwapResult.nothing);
      expect(outside.existsSync(), isTrue); // shares the folder's name as a prefix, but is not inside it
      expect(up.existsSync(), isTrue);
      expect(inside.existsSync(), isFalse);
    });

    test('a file here that is not the base build is refused', () async {
      final app = await installOld();
      File('${app.path}/lib/libapp.so').writeAsStringSync('someone else\'s build');
      final stage = WindowsStage(app);
      await stage.begin();
      expect(
          () => stageFiles(
              patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want()),
          throwsA(isA<PatchError>()));
    });

    test('a move that fails puts every file back and drops the stage', () async {
      final app = await installOld();
      final before = await treeHashes(app);
      var moves = 0;
      final stage = WindowsStage(app, rename: (f, to) async {
        if (++moves == 3) throw const FileSystemException('in use');
        await f.rename(to);
      });
      await stage.begin();
      final staged = stageFiles(
          patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want());
      await stage.commit('v1', staged);
      expect(await stage.swapIn(), SwapResult.failed);
      expect(await treeHashes(app), before);
      expect(await stage.ready, isFalse);
      expect(await stage.takeNote(), contains('Download the full update'));
    });

    test('a damaged staged file is not swapped in', () async {
      final app = await installOld();
      final before = await treeHashes(app);
      final stage = WindowsStage(app);
      await stage.begin();
      final staged = stageFiles(
          patchPath: fixture('caw-main-windows.cawpatch').path, installDir: app.path, stageDir: stage.files.path, expected: want());
      await stage.commit('v1', staged);
      File('${stage.files.path}/res/new.txt').writeAsStringSync('changed after staging');
      expect(await stage.swapIn(), SwapResult.failed);
      expect(await treeHashes(app), before);
    });
  });

  group('the service', () {
    late FakeTransport transport;
    late Map<String, List<int>> served;

    /// A latest-main release with the full assets, the manifest and both patches, checksums in the notes.
    List<ReleaseInfo> releases({Map<String, List<int>> override = const {}}) {
      served = {
        'caw-main-android.apk': target,
        'caw-main-windows.zip': target,
        'caw-main-update.json': manifestBytes,
        'caw-main-android.cawpatch': fixture('caw-main-android.cawpatch').readAsBytesSync(),
        'caw-main-windows.cawpatch': fixture('caw-main-windows.cawpatch').readAsBytesSync(),
      };
      final notes = StringBuffer('Version: 9.0.0\nBuild: abc1234\n');
      for (final e in served.entries) {
        notes.writeln('SHA256 ${e.key}: ${sha256Hex(e.value)}');
      }
      for (final e in {...served, ...override}.entries) {
        transport.files['$prefix${e.key}'] = e.value;
      }
      return parseGitHubReleases([
        {
          'tag_name': tag,
          'body': notes.toString(),
          'assets': [
            for (final e in served.entries) {'name': e.key, 'size': e.value.length, 'browser_download_url': '$prefix${e.key}'},
          ],
        },
      ]);
    }

    UpdateService make(FakeInstaller installer, List<ReleaseInfo> list) => UpdateService(
        source: _List(list), fetcher: UpdateFetcher(transport: transport), installer: installer, version: '1.0.0', build: 'old0000')
      ..channel = UpdateChannel.everyChange;

    setUp(() => transport = FakeTransport());

    test('Android: the APK is rebuilt from the installed one, verified, and installed; the size line says so', () async {
      final apk = File('${tmp.path}/installed/base.apk')..createSync(recursive: true);
      apk.writeAsBytesSync(base);
      final installer = FakeInstaller(Directory('${tmp.path}/cache/updates'), platform: UpdatePlatform.android, apk: apk.path);
      final s = make(installer, releases());
      await s.check();
      final r = s.offer!;
      expect(await s.planFor(r), isNotNull);
      final patchSize = served['caw-main-android.cawpatch']!.length;
      expect(s.sizeLine(r), 'Update ${megabytes(patchSize)} instead of ${megabytes(target.length)}');
      await s.downloadAndInstall(r);
      expect(installer.installedBytes.single, target);
      expect(installer.installed.single.path, endsWith('caw-main-android.apk'));
      expect(transport.requested, isNot(contains('caw-main-android.apk')));
    });

    test('Android: a patch that does not match its checksum falls back to the full download', () async {
      final apk = File('${tmp.path}/installed/base.apk')..createSync(recursive: true);
      apk.writeAsBytesSync(base);
      final installer = FakeInstaller(Directory('${tmp.path}/cache/updates'), platform: UpdatePlatform.android, apk: apk.path);
      final damaged = Uint8List.fromList(fixture('caw-main-android.cawpatch').readAsBytesSync())..[20] ^= 1;
      final s = make(installer, releases(override: {'caw-main-android.cawpatch': damaged}));
      await s.check();
      await s.downloadAndInstall(s.offer!);
      expect(transport.requested, containsAllInOrder(['caw-main-android.cawpatch', 'caw-main-android.apk']));
      expect(installer.installedBytes.single, target);
    });

    test('Android: an installed build that is not the previous one gets the full download', () async {
      final apk = File('${tmp.path}/installed/base.apk')..createSync(recursive: true);
      apk.writeAsBytesSync(utf8.encode('an older build'));
      final installer = FakeInstaller(Directory('${tmp.path}/cache/updates'), platform: UpdatePlatform.android, apk: apk.path);
      final s = make(installer, releases());
      await s.check();
      expect(await s.planFor(s.offer!), isNull);
      expect(s.sizeLine(s.offer!), 'Download ${megabytes(target.length)}');
      await s.downloadAndInstall(s.offer!);
      expect(transport.requested, isNot(contains('caw-main-android.cawpatch')));
      expect(installer.installedBytes.single, target);
    });

    test('a release without a manifest: the full download, as before', () async {
      final apk = File('${tmp.path}/installed/base.apk')..createSync(recursive: true);
      apk.writeAsBytesSync(base);
      final installer = FakeInstaller(Directory('${tmp.path}/cache/updates'), platform: UpdatePlatform.android, apk: apk.path);
      final list = releases();
      final r = list.single;
      final bare = ReleaseInfo(
          tag: r.tag, version: r.version, notes: r.notes, rolling: true, build: r.build,
          assets: [for (final a in r.assets) if (a.name.endsWith('.apk')) a]);
      final s = make(installer, [bare]);
      await s.check();
      await s.downloadAndInstall(s.offer!);
      expect(transport.requested, ['caw-main-android.apk']);
      expect(installer.installedBytes.single, target);
    });

    test('Windows: the changed files are staged for the next start; nothing else downloads', () async {
      final app = Directory('${tmp.path}/app')..createSync();
      await writeTree(app, unzip(base));
      final installer = FakeInstaller(Directory('${tmp.path}/cache/updates'), platform: UpdatePlatform.windows, app: app);
      final s = make(installer, releases());
      await s.check();
      final o = await s.downloadAndInstall(s.offer!);
      expect(o.message, contains('is ready'));
      expect(transport.requested, isNot(contains('caw-main-windows.zip')));
      expect(installer.installed, isEmpty);
      expect(await WindowsStage(app).ready, isTrue);
      expect(await WindowsStage(app).swapIn(), SwapResult.swapped);
      final now = await treeHashes(app);
      for (final f in manifest.artifact('caw-main-windows.zip')!.files) {
        expect(now[f.path], f.sha256, reason: f.path);
      }
    });

    test('Windows: an app folder that differs falls back to the full zip', () async {
      final app = Directory('${tmp.path}/app')..createSync();
      await writeTree(app, unzip(base));
      File('${app.path}/assets/same.txt').writeAsStringSync('edited by hand');
      final installer = FakeInstaller(Directory('${tmp.path}/cache/updates'), platform: UpdatePlatform.windows, app: app);
      final s = make(installer, releases());
      await s.check();
      await s.downloadAndInstall(s.offer!);
      expect(transport.requested, containsAllInOrder(['caw-main-windows.cawpatch', 'caw-main-windows.zip']));
      expect(installer.installedBytes.single, target);
      expect(await WindowsStage(app).ready, isFalse);
    });
  });
}

class _List implements UpdateSource {
  _List(this.list);
  final List<ReleaseInfo> list;
  @override
  String get name => 'test';
  @override
  Future<List<ReleaseInfo>> releases() async => list;
}
