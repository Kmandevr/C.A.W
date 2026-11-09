// The in-app C++ build: the manifest, the compiler's arguments, diagnostics, read-only results and old builds.
import 'dart:io';

import 'package:caw/platform/cpp_compiler.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCompiler implements CppCompiler {
  FakeCompiler(this.toolchain, {this.code = 0, this.output = '', this.available = true});
  final String toolchain;
  final int code;
  final String output;
  final bool available;
  List<String>? lastArgs;

  @override
  Future<String> toolchainDirectory() async {
    if (!available) throw StateError('this build of C.A.W does not include the C++ compiler');
    return toolchain;
  }

  @override
  Future<({int code, String output})> run(List<String> args) async {
    lastArgs = args;
    if (code == 0) await File(args[args.indexOf('-o') + 1]).writeAsString('ELF');
    return (code: code, output: output);
  }
}

const manifest = '{"format":"caw.component","version":1,"component":{"id":"org.me.delay","name":"Delay"},'
    '"sources":["src/delay.cpp"],"includeDirectories":["include"],"compileDefinitions":["TAPS=4"]}';

void main() {
  late Directory root;
  late String source, out, toolchain;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('caw-cpp-compiler');
    source = '${root.path}/src-dir';
    out = '${root.path}/build';
    toolchain = '${root.path}/toolchain';
    await Directory('$source/src').create(recursive: true);
    await Directory('$toolchain/lib/clang/23').create(recursive: true);
    await File('$source/caw-component.json').writeAsString(manifest);
  });
  tearDown(() async {
    // The read-only build files: give back write permission so the directory can go.
    if (Platform.isLinux) await Process.run('chmod', ['-R', 'u+w', root.path]);
    await root.delete(recursive: true);
  });

  test('the manifest is read like the CMake helper reads it, and unsafe entries are refused', () {
    final m = CppComponentManifest.parse(manifest);
    expect(m.id, 'org.me.delay');
    expect(m.sources, ['src/delay.cpp']);
    expect(m.includeDirectories, ['include']);
    expect(m.definitions, ['TAPS=4']);
    expect(() => CppComponentManifest.parse(manifest.replaceFirst('src/delay.cpp', '../escape.cpp')), throwsFormatException);
    expect(() => CppComponentManifest.parse(manifest.replaceFirst('TAPS=4', 'X; rm')), throwsFormatException);
    expect(() => CppComponentManifest.parse('{"format":"caw.component","version":1,"component":{"id":"a"},"sources":[]}'),
        throwsFormatException);
  });

  test('a build compiles every source for Android arm64 with the engine float rules into a read-only library', () async {
    final compiler = FakeCompiler(toolchain);
    final result = await CppSourceBuilder(compiler).build(sourceDirectory: source, outputDirectory: out);
    expect(result.success, isTrue, reason: result.output);
    final args = compiler.lastArgs!;
    expect(args.first, '$toolchain/bin/clang');
    expect(args, containsAll(['--target=aarch64-linux-android26', '--sysroot=$toolchain/sysroot', '-shared', '-static-libstdc++',
        '-ffp-contract=off', '-fno-fast-math', '-resource-dir=$toolchain/lib/clang/23', '-I$toolchain/caw-sdk/include',
        '-I$source/include', '-DTAPS=4', '$source/src/delay.cpp']));
    final artifact = result.artifactPath!;
    expect(artifact, startsWith('$out/org.me.delay-'));
    expect(artifact, endsWith('.so'));
    if (Platform.isLinux) expect((await File(artifact).stat()).modeString(), 'r--r--r--');
  });

  test('compile errors come back at their lines, in project paths', () async {
    final compiler = FakeCompiler(toolchain, code: 1, output: "$source/src/delay.cpp:12:3: error: use of undeclared identifier 'retun'\n");
    final result = await CppSourceBuilder(compiler).build(sourceDirectory: source, outputDirectory: out);
    expect(result.success, isFalse);
    expect(result.diagnostics.single.file, 'src/delay.cpp');
    expect(result.diagnostics.single.line, 12);
    expect(result.diagnostics.single.column, 3);
    expect(result.diagnostics.single.message, contains('retun'));
  });

  test('a compiler crash is one plain error, and an app without the compiler says so', () async {
    final crashed = await CppSourceBuilder(FakeCompiler(toolchain, code: -1, output: 'error: the C++ compiler stopped unexpectedly'))
        .build(sourceDirectory: source, outputDirectory: out);
    expect(crashed.diagnostics.single.message, contains('stopped unexpectedly'));
    final missing = await CppSourceBuilder(FakeCompiler(toolchain, available: false)).build(sourceDirectory: source, outputDirectory: out);
    expect(missing.diagnostics.single.code, 'CAW_COMPILER_UNAVAILABLE');
  });

  test('each build is a new file, and only the newest previous build is kept', () async {
    final builder = CppSourceBuilder(FakeCompiler(toolchain));
    final paths = <String>[];
    for (var i = 0; i < 4; i++) {
      paths.add((await builder.build(sourceDirectory: source, outputDirectory: out)).artifactPath!);
    }
    expect(paths.toSet().length, 4);
    final left = Directory(out).listSync().map((f) => f.path).toSet();
    expect(left, {paths[2], paths[3]});
  });
}
