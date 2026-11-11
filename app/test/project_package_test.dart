// The .caw project file (#159) and packaging: the dependency scan, export and import round trip, old .cawproj files,
// unsafe and oversized archives, the checklist sheet, and the missing-files banner with Locate….
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/native_components.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/project_dependencies.dart';
import 'package:caw/model/project_package.dart';
import 'package:caw/model/sampler.dart';
import 'package:caw/model/sha256.dart';
import 'package:caw/model/user_presets.dart';
import 'package:caw/model/zip_archive.dart';
import 'package:caw/platform/cpp_build.dart';
import 'package:caw/ui/files/project_file_actions.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n, int seed) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 0xFF]);

/// A zip written by hand, so a test can give it names and sizes this app's writer refuses.
Uint8List _rawZip(List<(String name, List<int> data, int declaredSize, int method)> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final (name, data, size, method) in files) {
    final n = utf8.encode(name);
    final offset = out.length;
    final crc = crc32(method == 8 ? ZLibDecoder(raw: true).convert(data) : data);
    ByteData header(int length, int sig) => ByteData(length)..setUint32(0, sig, Endian.little);
    final l = header(30, 0x04034b50)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, size, Endian.little)
      ..setUint16(26, n.length, Endian.little);
    out..add(l.buffer.asUint8List())..add(n)..add(data);
    final c = header(46, 0x02014b50)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, size, Endian.little)
      ..setUint16(28, n.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central..add(c.buffer.asUint8List())..add(n);
  }
  final start = out.length, cd = central.takeBytes();
  out.add(cd);
  final e = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, cd.length, Endian.little)
    ..setUint32(16, start, Endian.little);
  out.add(e.buffer.asUint8List());
  return out.takeBytes();
}

void main() {
  late Directory tmp;
  late AppState state;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('caw-package-test');
    state = AppState()..starting = false;
    state.userPresets = UserPresetStore(null);
  });
  tearDown(() async {
    state.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  String file(String name, List<int> bytes) {
    final f = File('${tmp.path}${Platform.pathSeparator}$name')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  NativeComponentManager manager() => NativeComponentManager(
        trust: NativeTrustStore(File('${tmp.path}/trust.json')),
        cacheFile: File('${tmp.path}/native-builds.json'),
        build: (_, _) async => const CppBuildResult(success: false, exitCode: 1, output: 'not in tests', diagnostics: []),
        load: ({required artifactPath, required expectedComponentId, required trust, reload = false}) async =>
            const NativeComponentLoadResult(ok: false, error: 'not in tests'),
      );

  final fuzz = CppComponentDoc(id: 'c1', name: 'Fuzz', componentId: 'com.example.fuzz',
      files: {'CMakeLists.txt': 'project(fuzz)', 'src/fuzz.cpp': '// fuzz\nint x = 1;'});

  /// A project with an audio clip, a drum pad sample, a sampler zone, a C++ effect and a plug-in nobody has.
  ProjectDoc project(String audio, String kick, String zone) => ProjectDoc(
        id: 'p-original',
        name: 'Packed song',
        assets: [AudioAssetDoc(id: 'a1', path: audio, name: 'loop')],
        cppComponents: [CppComponentDoc.fromJson(fuzz.toJson())],
        layers: [
          LayerDoc(id: 'l1', name: 'Loop', color: 0, audioClips: [AudioClipDoc(id: 'ac1', assetId: 'a1')],
              components: [ComponentUseDoc('com.example.fuzz')]),
          LayerDoc(id: 'l2', name: 'Drums', color: 1,
              instrument: ComponentUseDoc('org.caw.drums')..samples = [ComponentSampleDoc(0, path: kick)]),
          LayerDoc(id: 'l3', name: 'Keys', color: 2,
              instrument: ComponentUseDoc(samplerComponentId, {}, false, SamplerState([SamplerZone(path: zone)]).toBase64()),
              components: [ComponentUseDoc('com.vendor.compressor')]),
        ],
      );

  test('the dependency scan lists every kind with its users, size and whether it is here', () async {
    final audio = file('loop.wav', _bytes(1000, 1)), kick = file('kick.wav', _bytes(200, 2));
    state.project = project(audio, kick, '${tmp.path}/gone.wav');
    final deps = scanProjectDependencies(state.project, builtBinary: (_) => file('libfuzz.so', _bytes(64, 3)));
    Map<String, ProjectDependency> by(DependencyKind k) => {for (final d in deps) if (d.kind == k) d.name: d};
    expect(by(DependencyKind.audio)['loop.wav']!.usedBy, ['Loop']);
    expect(by(DependencyKind.audio)['loop.wav']!.size, 1000);
    expect(by(DependencyKind.sample)['kick.wav']!.usedBy, ['Drums']);
    final gone = by(DependencyKind.sample)['gone.wav']!;
    expect((gone.found, gone.isMissingFile), (false, true));
    expect(gone.usedBy, ['Keys']);
    final source = by(DependencyKind.source).values.single;
    expect((source.embedded, source.packageable), (true, false));
    expect(source.usedBy, ['Loop']);
    expect(by(DependencyKind.binary).values.single.size, 64);
    final plugin = by(DependencyKind.plugin)['com.vendor.compressor']!;
    expect(plugin.packageable, isFalse);
    expect(plugin.usedBy, ['Keys']);
    final missing = await findMissingFiles(state.project);
    expect(missing.map((m) => m.name), ['gone.wav']);
  });

  test('export then import: files, C++ source and build, preset and theme come back; ids are new', () async {
    final audioBytes = _bytes(5000, 7), kickBytes = _bytes(300, 9), zoneBytes = _bytes(700, 4), lib = _bytes(4096, 5);
    final audio = file('src/loop 120bpm.wav', audioBytes), kick = file('src/kick.wav', kickBytes);
    final zone = file('src/zone.wav', zoneBytes);
    final libPath = file('build/libfuzz.so', lib);
    state.nativeComponents = manager();
    await File('${tmp.path}/native-builds.json')
        .writeAsString(jsonEncode({'com.example.fuzz': {NativeTrustStore.sourceFingerprint(fuzz): libPath}}));
    state.project = project(audio, kick, zone);
    state.userPickedFiles.addAll([audio, kick, zone]); // as an SFZ's samples are: picked by the user
    state.userPresets.put(UserPreset(id: 'up_1', kind: UserPresetKind.device, name: 'Warm fuzz',
        device: const PresetDevice('com.example.fuzz', {'drive': 0.5}), modified: DateTime.utc(2026)));
    await state.settings.saveTheme(calmNeon.copyWith(name: 'Night shift', profile: {'look.font': 'mono'}));

    final deps = await state.projectDependencies();
    expect(deps.map((d) => d.kind).toSet(), containsAll(DependencyKind.values.where((k) => k != DependencyKind.impulse)));
    final out = await Directory('${tmp.path}/out').create();
    final caw = await state.writeProjectFile(deps, {for (final d in deps) d.key}, into: out);
    expect(caw.path, endsWith('.caw'));
    expect(ZipReader.looksLikeZip(await caw.openRead(0, 4).first), isTrue);
    // No device path of a packaged file travels in the package.
    final zip = ZipReader.open(caw.path);
    final packedJson = utf8.decode(zip.readBytes(zip['project.json']!));
    zip.close();
    expect(packedJson, isNot(contains(tmp.path)));

    // The other device: the originals are gone, the preset name is taken, the theme isn't there.
    await Directory('${tmp.path}/src').delete(recursive: true);
    await Directory('${tmp.path}/build').delete(recursive: true);
    state.nativeComponents = manager();
    ImportedBinary? asked;
    final result = await state.importProjectFile(caw.path, askBinaryTrust: (b) async {
      asked = b;
      return NativeComponentTrust.trusted;
    });
    expect(result, isNotNull);
    final p = state.project;
    expect(p.id, isNot('p-original'));
    expect(p.name, 'Packed song');
    expect(await File(p.assets.single.path).readAsBytes(), audioBytes);
    expect(p.assets.single.path, startsWith(state.audioDirectory.path));
    expect(await File(p.layers[1].instrument!.samples.single.path!).readAsBytes(), kickBytes);
    final zonePath = SamplerState.fromBase64(p.layers[2].instrument!.state).zones.single.path;
    expect(await File(zonePath).readAsBytes(), zoneBytes);
    expect(p.cppComponents.single.files, fuzz.files);
    expect(result!.filesUnpacked, 3);
    // The build went through the trust prompt, once, and is used for those sources.
    expect(asked?.componentId, 'com.example.fuzz');
    expect(asked?.sha256, sha256Hex(lib));
    final adopted = await state.nativeComponents!.builtArtifact(p.cppComponents.single);
    expect(await File(adopted!).readAsBytes(), lib);
    // Presets join the user's (renamed on a clash); the theme is offered, not applied.
    expect(result.presetsAdded, ['Warm fuzz 2']);
    expect(result.theme?.name, 'Night shift');
    expect(result.theme?.profile['look.font'], 'mono');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(state.missingFiles, isEmpty);

    // A second import of the same build doesn't ask again (remembered for its fingerprint).
    var askedAgain = false;
    await state.importProjectFile(caw.path, askBinaryTrust: (_) async {
      askedAgain = true;
      return null;
    });
    expect(askedAgain, isFalse);
  });

  test('a project with only its source exports as plain JSON .caw, and an old .cawproj imports', () async {
    state.project = ProjectDoc(id: 'p1', name: 'Plain', bpm: 133, cppComponents: [fuzz]);
    final deps = await state.projectDependencies();
    final caw = await state.writeProjectFile(deps, {for (final d in deps) d.key}, into: tmp);
    final text = await caw.readAsString();
    expect(text.trimLeft().startsWith('{'), isTrue);
    expect(jsonDecode(text)['cpp_components'], isNotEmpty);

    final legacy = File('${tmp.path}/old.cawproj')
      ..writeAsStringSync(jsonEncode(ProjectDoc(id: 'old', name: 'Old one', bpm: 99).toJson()));
    await state.importProjectFile(legacy.path);
    expect((state.project.name, state.project.bpm), ('Old one', 99));
    expect(state.project.id, isNot('old'));

    final notProject = File('${tmp.path}/x.caw')..writeAsStringSync('{"hello": 1}');
    expect(state.importProjectFile(notProject.path), throwsFormatException);
  });

  test('unsafe and oversized archives are refused before anything is written', () async {
    for (final name in ['../evil.wav', '/abs.wav', 'assets/../../x', 'C:/win.wav', 'assets\\x.wav', 'assets/.hidden']) {
      final f = File('${tmp.path}/slip.caw')..writeAsBytesSync(_rawZip([(name, [1, 2, 3], 3, 0)]));
      expect(() => ZipReader.open(f.path), throwsA(isA<ZipException>()), reason: name);
      await expectLater(state.importProjectFile(f.path), throwsFormatException, reason: name);
    }
    // Declared too large for the limits.
    final big = File('${tmp.path}/big.caw')..writeAsBytesSync(_rawZip([('assets/a.wav', _bytes(100, 1), 100, 0)]));
    expect(() => ZipReader.open(big.path, limits: const ZipLimits(maxEntryBytes: 50)), throwsA(isA<ZipException>()));
    expect(() => ZipReader.open(big.path, limits: const ZipLimits(maxTotalBytes: 50)), throwsA(isA<ZipException>()));
    expect(() => ZipReader.open(big.path, limits: const ZipLimits(maxEntries: 0)), throwsA(isA<ZipException>()));
    // A deflated entry that inflates past the size it declared (a zip bomb) stops at that size.
    final packed = ZLibEncoder(raw: true).convert(List.filled(100000, 0));
    final bomb = File('${tmp.path}/bomb.caw')..writeAsBytesSync(_rawZip([('assets/a.wav', packed, 10, 8)]));
    final reader = ZipReader.open(bomb.path);
    expect(() => reader.readBytes(reader.entries.single), throwsA(isA<ZipException>()));
    expect(() => reader.extract(reader.entries.single, '${tmp.path}/bomb.out'), throwsA(isA<ZipException>()));
    expect(File('${tmp.path}/bomb.out').existsSync(), isFalse);
    reader.close();

    // A manifest pointing a packaged file outside its folder is skipped, never extracted.
    final manifest = jsonEncode({'format': packageFormat, 'version': 1, 'dependencies': [
      {'kind': 'audio', 'name': 'x.wav', 'reference': '/x.wav', 'path': 'project.json', 'packaged': true},
    ]});
    final sneaky = File('${tmp.path}/sneaky.caw')..writeAsBytesSync(_rawZip([
      ('manifest.json', utf8.encode(manifest), utf8.encode(manifest).length, 0),
      ('project.json', utf8.encode(jsonEncode(ProjectDoc(id: 'x', name: 'Sneaky').toJson())),
          utf8.encode(jsonEncode(ProjectDoc(id: 'x', name: 'Sneaky').toJson())).length, 0),
    ]));
    final r = await state.importProjectFile(sneaky.path);
    expect(r!.filesUnpacked, 0);
    expect(r.notes.single, contains('Skipped'));
  });

  test('a packaged build loads only while its own Trust stands', () async {
    final lib = file('native-imports/p/libfuzz.so', _bytes(512, 1));
    final loaded = <String>[];
    var builds = 0;
    final m = NativeComponentManager(
      trust: NativeTrustStore(File('${tmp.path}/trust.json')),
      cacheFile: File('${tmp.path}/native-builds.json'),
      build: (_, _) async {
        builds++;
        return const CppBuildResult(success: false, exitCode: 1, output: '', diagnostics: []);
      },
      load: ({required artifactPath, required expectedComponentId, required trust, reload = false}) async {
        loaded.add(artifactPath);
        return const NativeComponentLoadResult(ok: true);
      },
    );
    final fp = NativeTrustStore.sourceFingerprint(fuzz);
    final sha = sha256Hex(File(lib).readAsBytesSync());
    await m.adoptImportedBuild(fuzz.componentId, fp, lib, sha);
    m.trust.remember(fuzz.componentId, fp, NativeComponentTrust.trusted);
    final p = ProjectDoc(id: 'p', name: 'P', cppComponents: [fuzz]);
    await m.prepare(p);
    expect(loaded, [lib]);
    expect(builds, 0);
    // Blocked afterwards (or the file swapped for another): it builds from source instead.
    m.trust.remember(fuzz.componentId, NativeComponentManager.importedLibraryKey(sha), NativeComponentTrust.blocked);
    final again = NativeComponentManager(trust: m.trust, cacheFile: m.cacheFile, build: m.build, load: m.load);
    await again.prepare(p);
    expect((loaded.length, builds), (1, 1));
  });

  test('only plain local absolute paths are looked at', () {
    for (final ok in ['/data/user/0/app/a.wav', r'C:\Users\me\a.wav', 'C:/x/a.wav', '/a b/c (1).wav']) {
      expect(isSafeLocalPath(ok), isTrue, reason: ok);
    }
    for (final bad in [r'\\attacker\share\a.wav', '//host/x.wav', r'\\?\C:\a.wav', r'\\.\pipe\x', '\\\\host/x',
        'smb://host/a.wav', 'file:///etc/passwd', 'http://x/a.wav', 'a.wav', 'sub/a.wav', '/a/../b.wav', '/a/./b',
        r'C:\a.wav:stream', 'C:a.wav', '', '/a\u0000b']) {
      expect(isSafeLocalPath(bad), isFalse, reason: bad);
    }
  });

  test('a project naming network or device paths opens with them missing, never probed', () async {
    final unc = r'\\attacker\share\kick.wav';
    final json = ProjectDoc(id: 'x', name: 'Remote', assets: [AudioAssetDoc(id: 'a', path: unc, name: 'kick')], layers: [
      LayerDoc(id: 'l', name: 'Hits', color: 0, audioClips: [AudioClipDoc(id: 'c', assetId: 'a')],
          instrument: ComponentUseDoc('org.caw.drums')..samples = [ComponentSampleDoc(0, path: '//host/snare.wav')]),
    ]).toJson();
    final f = File('${tmp.path}/remote.caw')..writeAsStringSync(jsonEncode(json));
    await state.importProjectFile(f.path);
    await state.checkMissingFiles();
    final p = state.project;
    expect(p.assets.single.path, startsWith(state.audioDirectory.path));
    expect(p.assets.single.path, endsWith('kick.wav'));
    expect(p.layers.single.instrument!.samples.single.path, endsWith('snare.wav'));
    expect(isSafeLocalPath(p.layers.single.instrument!.samples.single.path!), isTrue);
    expect(state.missingFiles.map((m) => m.name).toSet(), {'kick.wav', 'snare.wav'});
    // A project already on disk gets the same treatment when it opens.
    await state.importProject(ProjectDoc.fromJson(json), prepare: (_) {});
    expect(isSafeLocalPath(state.project.assets.single.path), isTrue);
  });

  test('a reference outside the project is listed as outside, never hashed or packaged', () async {
    final own = file('own.wav', _bytes(100, 1)), other = file('other-project/secret.wav', _bytes(100, 2));
    state.project = ProjectDoc(id: 'p', name: 'Mixed', assets: [
      AudioAssetDoc(id: 'a', path: own, name: 'own'), AudioAssetDoc(id: 'b', path: other, name: 'secret')]);
    state.userPickedFiles.add(own);
    final deps = await state.projectDependencies();
    final outside = deps.singleWhere((d) => d.name == 'secret.wav');
    expect((outside.outside, outside.packageable, outside.size), (true, false, 0));
    final caw = await state.writeProjectFile(deps, {for (final d in deps) d.key}, into: tmp);
    final zip = ZipReader.open(caw.path);
    final manifest = jsonDecode(utf8.decode(zip.readBytes(zip['manifest.json']!))) as Map;
    expect(zip.entries.map((e) => e.name), isNot(contains(contains('secret'))));
    zip.close();
    final row = (manifest['dependencies'] as List).cast<Map>().singleWhere((e) => e['name'] == 'secret.wav');
    expect((row['packaged'], row['outside'], row.containsKey('sha256')), (false, true, false));
  });

  test('a manifest listing one file twice is refused; unpacking stops at the running total', () async {
    final wav = _bytes(3000, 1);
    final projectJson = utf8.encode(jsonEncode(ProjectDoc(id: 'x', name: 'Bomb',
        assets: [AudioAssetDoc(id: 'a', path: 'package:assets/a.wav', name: 'a')]).toJson()));
    Uint8List pkg(List<Map<String, Object?>> deps, List<(String, List<int>, int, int)> more) {
      final manifest = utf8.encode(jsonEncode({'format': packageFormat, 'version': 1, 'dependencies': deps}));
      return _rawZip([('manifest.json', manifest, manifest.length, 0), ('project.json', projectJson, projectJson.length, 0),
          ...more]);
    }
    final tag = 'budget${DateTime.now().microsecondsSinceEpoch}';
    Map<String, Object?> listing(String path) => {'kind': 'audio', 'name': '$tag-${path.split('/').last}',
        'reference': 'package:$path', 'path': path, 'packaged': true};
    final twice = File('${tmp.path}/twice.caw')
      ..writeAsBytesSync(pkg([listing('assets/a.wav'), listing('assets/a.wav')], [('assets/a.wav', wav, wav.length, 0)]));
    await expectLater(state.importProjectFile(twice.path), throwsA(isA<FormatException>()
        .having((e) => e.message, 'message', contains('more than once'))));
    // More listings than files in the archive.
    final more = File('${tmp.path}/more.caw')
      ..writeAsBytesSync(pkg([for (final n in ['a', 'b', 'c', 'd']) listing('assets/$n.wav')],
          [('assets/a.wav', wav, wav.length, 0)]));
    await expectLater(state.importProjectFile(more.path), throwsFormatException);
    // Three files of 3000 bytes under a 7000-byte budget: the third stops it, and the two written are removed.
    final three = File('${tmp.path}/three.caw')..writeAsBytesSync(pkg(
        [listing('assets/a.wav'), listing('assets/b.wav'), listing('assets/c.wav')],
        [('assets/a.wav', wav, wav.length, 0), ('assets/b.wav', wav, wav.length, 0), ('assets/c.wav', wav, wav.length, 0)]));
    final before = state.project.id;
    await expectLater(state.importProjectFile(three.path, maxUnpackBytes: 7000 + 2000),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('more than this app takes'))));
    expect(state.project.id, before, reason: 'nothing opened');
    final audioRoot = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}caw-audio');
    final left = audioRoot.existsSync()
        ? audioRoot.listSync(recursive: true).whereType<File>().where((f) => f.path.contains(tag))
        : const <File>[];
    expect(left, isEmpty, reason: 'the files written before the budget ran out are removed');
    await state.importProjectFile(three.path); // within the real limits it opens
    expect(state.project.assets.single.path, isNot(startsWith('package:')));
  });

  testWidgets('the checklist: Package everything, sources always in, the total follows the boxes', (tester) async {
    final deps = [
      ProjectDependency(key: 'a', kind: DependencyKind.audio, name: 'loop.wav', path: '/x', size: 2048, found: true,
          usedBy: ['Loop']),
      ProjectDependency(key: 'b', kind: DependencyKind.binary, name: 'Fuzz build', path: '/y', size: 1024 * 1024, found: true),
      ProjectDependency(key: 's', kind: DependencyKind.source, name: 'Fuzz (C++ source)', size: 10, found: true, embedded: true),
      ProjectDependency(key: 'm', kind: DependencyKind.sample, name: 'gone.wav', path: '/z'),
    ];
    Set<String>? picked;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () async => picked = await showGlassSheet<Set<String>>(context: context, isScrollControlled: true,
            builder: (_) => PackageChecklist(projectName: 'Song', projectBytes: 1000, deps: deps)),
        child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Audio · used by Loop · 2 KB · found'), findsOneWidget);
    expect(find.textContaining('· missing'), findsOneWidget);
    expect(find.text('File size about 3 KB'), findsOneWidget); // project + the audio ticked by default
    CheckboxListTile tile(String key) => tester.widget(find.byKey(ValueKey('package-$key')));
    expect((tile('s').value, tile('s').onChanged), (true, null));
    expect(tile('m').onChanged, isNull);
    expect(tile('b').value, isFalse);
    await tester.tap(find.byKey(const ValueKey('package-everything')));
    await tester.pump();
    expect(tile('b').value, isTrue);
    expect(find.text('File size about 1.0 MB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('package-a')));
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('package-everything'))).value, isFalse);
    await tester.tap(find.byKey(const ValueKey('package-export')));
    await tester.pumpAndSettle();
    expect(picked, {'b'});
  });

  testWidgets('a missing file shows the banner; Locate… checks the hash and relinks by name', (tester) async {
    late String gone, wrong, right;
    final good = _bytes(800, 3);
    await tester.runAsync(() async {
      gone = '${tmp.path}/elsewhere/kick.wav';
      wrong = file('wrong/kick.wav', _bytes(800, 4));
      right = file('right/kick.wav', good);
      state.knownFileHashes[gone] = sha256Hex(good);
      await state.importProject(ProjectDoc(id: 'm', name: 'Missing', assets: [AudioAssetDoc(id: 'a', path: gone, name: 'kick')],
          layers: [LayerDoc(id: 'l', name: 'Hits', color: 0, audioClips: [AudioClipDoc(id: 'c', assetId: 'a')])]),
          prepare: (copy) {});
      await state.checkMissingFiles();
    });
    expect(state.missingFiles.single.usedBy, ['Hits']);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: state,
        builder: (_, _) => state.missingFiles.isEmpty ? const Text('all here') : MissingFilesBanner(state: state)))));
    expect(find.text('Missing: kick.wav (silent until found)'), findsOneWidget);

    ProjectFilePicker.pickAudio = ({required bool many}) async => [wrong];
    await tester.runAsync(() => locateMissingFiles(tester.element(find.byType(MissingFilesBanner)), state));
    expect(state.missingFiles, isNotEmpty, reason: 'a file with other bytes is not the one the package listed');
    expect(state.audioDirectory.existsSync() ? state.audioDirectory.listSync().whereType<File>() : const <File>[], isEmpty,
        reason: 'the refused copy is deleted');

    ProjectFilePicker.pickAudio = ({required bool many}) async => [right];
    await tester.runAsync(() => locateMissingFiles(tester.element(find.byType(MissingFilesBanner)), state));
    await tester.pump();
    expect(find.text('all here'), findsOneWidget);
    final linked = state.project.assets.single.path;
    expect(linked, startsWith(state.audioDirectory.path));
    expect(File(linked).readAsBytesSync(), good);
  });
}
