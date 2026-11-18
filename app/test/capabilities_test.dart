// Declared capabilities in the in-app build: the manifest's rules, the canonical bytes against the engine's golden, the generated section source, and (with CAW_LIB) a real build the engine's scan reads.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/capabilities.dart';
import 'package:caw/platform/cpp_compiler.dart';
import 'package:flutter_test/flutter_test.dart';

// The engine's fixture and its golden bytes (docs/native-module-sdk.md "Declaring capabilities"), from app/.
const _fixture = '../engine/tests/fixtures/declared';
const _golden = '../engine/tests/references/capabilities.canonical';

const _base = '{"format":"caw.component","version":1,"component":{"id":"org.me.x"},"sources":["a.cpp"]';
List<CapabilityDeclaration> _caps(String list) => CppComponentManifest.parse('$_base,"capabilities":$list}').capabilities;

void main() {
  test('the fixture manifest gives exactly the golden canonical bytes', () {
    final manifest = CppComponentManifest.parse(File('$_fixture/caw-component.json').readAsStringSync());
    final golden = File(_golden).readAsBytesSync();
    expect(Capabilities.canonicalBytes(manifest.capabilities), golden);
    // The generated source holds those bytes and one NUL, in the section the scan reads.
    final source = Capabilities.generatedSource(manifest.capabilities);
    final hex = [...golden.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')},'), '0'].join();
    expect(source, contains('caw_component_capabilities[] = {$hex};'));
    expect(source, contains('__attribute__((used, section("caw_caps")))'));
    expect(source, contains('__attribute__((retain))'));
    expect(source, contains('#pragma section(".cawcap", read)'));
    expect(Capabilities.targetName('org.caw.tests.declared'), 'caw_component_org_caw_tests_declared');
  });

  test('nothing declared is an empty list, still embedded', () {
    expect(CppComponentManifest.parse('$_base}').capabilities, isEmpty);
    expect(Capabilities.canonical(const []), '{"format":"caw.capabilities","version":1,"capabilities":[]}');
    expect(_caps('[]'), isEmpty);
  });

  test('the manifest rules are CMake\'s and the engine\'s', () {
    expect(_caps('[{"id":"internet","reason":"presets","sites":["a.example.com"]}]').single.sites, ['a.example.com']);
    for (final bad in [
      '{}', // not a list
      'null',
      '[{"id":"network","reason":"x"}]', // unknown id
      '[{"id":"internet","reason":"x"},{"id":"internet","reason":"y"}]', // twice
      '[{"id":"internet"}]', // no reason
      '[{"id":"internet","reason":""}]',
      '[{"id":"internet","reason":"${'a' * 201}"}]',
      '[{"id":"internet","reason":"line\\nbreak"}]',
      '[{"id":"internet","reason":"c1 \\u0085"}]',
      '[{"id":"internet","reason":"lone \\ud800"}]',
      '[{"id":"internet","reason":"x","why":"y"}]', // unknown key
      '[{"id":"read_files","reason":"x","sites":["a.com"]}]', // sites only for internet
      '[{"id":"internet","reason":"x","sites":[]}]',
      '[{"id":"internet","reason":"x","sites":["A.com"]}]',
      '[{"id":"internet","reason":"x","sites":["-a.com"]}]',
      '[{"id":"internet","reason":"x","sites":["a..com"]}]',
      '[{"id":"internet","reason":"x","sites":["${'a' * 64}.com"]}]',
      '[{"id":"internet","reason":"x","sites":${jsonEncode([for (var i = 0; i < 9; i++) 'h$i.com'])}}]',
      jsonEncode([for (final id in [...capabilityIds, ...capabilityIds].take(17)) {'id': id, 'reason': 'x'}]),
      '["internet"]',
    ]) {
      expect(() => _caps(bad), throwsFormatException, reason: bad);
    }
    // 200 characters count code points, not bytes or UTF-16 units.
    expect(_caps('[{"id":"internet","reason":"${'é' * 200}"}]').single.reason.runes.length, 200);
    expect(_caps('[{"id":"internet","reason":"${'🎵' * 200}"}]'), hasLength(1));
  });

  test('the Needs form\'s edit keeps the rest of the manifest and removes an empty list', () {
    const text = '{\n  "format": "caw.component",\n  "version": 1,\n  "component": {"id": "org.me.x"},\n'
        '  "sources": ["a.cpp"]\n}\n';
    final added = Capabilities.writeToManifest(text, const [CapabilityDeclaration('write_files', 'saves loops')]);
    final j = jsonDecode(added) as Map<String, dynamic>;
    expect(j.keys, ['format', 'version', 'component', 'sources', 'capabilities']);
    expect(Capabilities.ofManifest(added).single, const CapabilityDeclaration('write_files', 'saves loops'));
    expect(jsonDecode(Capabilities.writeToManifest(added, const [])), isNot(contains('capabilities')));
  });

  group('a build', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('caw-caps'));
    tearDown(() async {
      if (Platform.isLinux) await Process.run('chmod', ['-R', 'u+w', root.path]);
      await root.delete(recursive: true);
    });

    test('compiles the generated declarations source with the component', () async {
      final source = '${root.path}/src';
      await Directory(source).create(recursive: true);
      await File('$source/caw-component.json').writeAsString('$_base,"capabilities":[{"id":"background_threads","reason":"loads"}]}');
      final compiler = _Recorder('${root.path}/tc');
      final result = await CppSourceBuilder(compiler).build(sourceDirectory: source, outputDirectory: '${root.path}/out');
      expect(result.success, isTrue, reason: result.output);
      final generated = '$source/.caw-build/caw_component_org_me_x_capabilities.cpp';
      expect(compiler.args, contains(generated));
      expect(compiler.args.indexOf(generated), lessThan(compiler.args.indexOf('-o')));
      expect(File(generated).readAsStringSync(), contains('0x62,0x61,0x63,0x6b')); // "back"
    });

    test('of the engine\'s fixture is read by the engine\'s scan as declared (needs CAW_LIB and clang++)', () async {
      final cxx = Platform.environment['CXX'] ?? 'clang++';
      final manifest = CppComponentManifest.parse(File('$_fixture/caw-component.json').readAsStringSync());
      final capsFile = File('${root.path}/caps.cpp')..writeAsStringSync(Capabilities.generatedSource(manifest.capabilities));
      final emptyFile = File('${root.path}/empty.cpp')..writeAsStringSync(Capabilities.generatedSource(const []));
      Future<String> build(String name, List<String> extra) async {
        final out = '${root.path}/$name.so';
        final r = await Process.run(cxx, ['-std=c++20', '-O1', '-fPIC', '-shared', '-fvisibility=hidden',
            '-I../engine/include', '$_fixture/src/declared.cpp', ...extra, '-o', out]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return out;
      }

      final declared = await build('declared', [capsFile.path]);
      final scan = await scanComponentFile(declared);
      expect(scan.ok, isTrue, reason: scan.error);
      expect(scan.declarations, 'valid');
      expect(scan.declared.map((d) => d.id), ['background_threads', 'internet']);
      expect(scan.declared.last.sites, ['presets.example.com', 'cdn.example.org']);
      expect(scan.declared.first.reason, 'Renders the "tail" on a worker; see C:\\presets; café');
      expect(scan.verdict, isNot(ScanVerdict.blocked));

      // Declaring nothing: its thread blocks it.
      final none = await scanComponentFile(await build('none', [emptyFile.path]));
      expect(none.declarations, 'valid');
      expect(none.verdict, ScanVerdict.blocked);
      expect(none.blockedBy, contains('background_threads'));

      // No section at all (a build from before 1.0.7): blocked, unless the user trusted it then.
      final old = await build('old', const []);
      expect((await scanComponentFile(old)).declarations, 'absent');
      expect((await scanComponentFile(old)).verdict, ScanVerdict.blocked);
      final graced = await scanComponentFile(old, legacyGraceSha256: 'unused-by-the-scan');
      expect(graced.graceApplied, isTrue);
      expect(graced.verdict, isNot(ScanVerdict.blocked));
    },
        skip: Platform.environment['CAW_LIB']?.isNotEmpty != true ||
            Process.runSync('which', [Platform.environment['CXX'] ?? 'clang++']).exitCode != 0);
  });
}

class _Recorder implements CppCompiler {
  _Recorder(this.toolchain);
  final String toolchain;
  List<String> args = const [];

  @override
  Future<String> toolchainDirectory() async => toolchain;

  @override
  Future<({int code, String output})> run(List<String> a) async {
    args = a;
    await File(a[a.indexOf('-o') + 1]).writeAsString('ELF');
    return (code: 0, output: '');
  }
}
