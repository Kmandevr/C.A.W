import 'dart:convert';

import 'package:caw/platform/cpp_toolchain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> manifest({
    String host = 'android-arm64',
    String mode = 'in_process',
    String? entryLibrary = 'lib/libcaw_clang.so',
    String? executable,
    int? androidMinApi = 26,
    List<Map<String, Object>>? artifacts,
  }) => {
    'format': 'caw.toolchain',
    'version': 1,
    'id': 'llvm-clang-android-arm64',
    'host': host,
    'execution_mode': mode,
    'compiler_version': 'clang-20.1.0',
    'sdk_version': '1.0.0',
    if (androidMinApi != null) 'android_min_api': androidMinApi,
    if (entryLibrary != null) 'entry_library': entryLibrary,
    if (executable != null) 'compiler_executable': executable,
    'artifacts': artifacts ?? [
      {'path': 'lib/libcaw_clang.so', 'sha256': 'a' * 64, 'size_bytes': 1024},
    ],
  };

  test('accepts Android compiler delivered as an in-process native library', () {
    final parsed = CppToolchainManifest.fromJson(manifest());
    expect(parsed.host, 'android-arm64');
    expect(parsed.executionMode, CppToolchainExecutionMode.inProcess);
    expect(parsed.entryLibrary, 'lib/libcaw_clang.so');
    expect(parsed.compilerExecutable, isNull);
    expect(CppToolchainManifest.fromJson(parsed.toJson()).entryLibrary, parsed.entryLibrary);
  });

  test('accepts desktop compiler executable manifests', () {
    final parsed = CppToolchainManifest.fromJson(manifest(
      host: 'linux-x64',
      mode: 'process',
      entryLibrary: null,
      androidMinApi: null,
      executable: 'bin/clang++',
      artifacts: [
        {'path': 'bin/clang++', 'sha256': 'b' * 64, 'size_bytes': 2048},
      ],
    ));
    expect(parsed.executionMode, CppToolchainExecutionMode.process);
    expect(parsed.compilerExecutable, 'bin/clang++');
  });

  test('rejects Android process execution and standalone compiler paths', () {
    expect(
      () => CppToolchainManifest.fromJson(manifest(mode: 'process')),
      throwsFormatException,
    );
    expect(
      () => CppToolchainManifest.fromJson(manifest(executable: 'bin/clang++')),
      throwsFormatException,
    );
  });

  test('rejects desktop in-process mode', () {
    expect(
      () => CppToolchainManifest.fromJson(manifest(
        host: 'windows-x64',
        mode: 'in_process',
        entryLibrary: null,
        androidMinApi: null,
        executable: 'bin/clang++.exe',
        artifacts: [
          {'path': 'bin/clang++.exe', 'sha256': 'c' * 64, 'size_bytes': 1},
        ],
      )),
      throwsFormatException,
    );
  });

  test('rejects traversal, absolute paths and duplicate artifact paths', () {
    for (final unsafe in ['../clang', '/data/clang', r'bin\clang', 'C:clang']) {
      expect(
        () => CppToolchainManifest.fromJson(manifest(
          entryLibrary: unsafe,
          artifacts: [{'path': unsafe, 'sha256': 'd' * 64, 'size_bytes': 10}],
        )),
        throwsFormatException,
      );
    }
    expect(
      () => CppToolchainManifest.fromJson(manifest(artifacts: [
        {'path': 'lib/libcaw_clang.so', 'sha256': 'e' * 64, 'size_bytes': 10},
        {'path': 'lib/libcaw_clang.so', 'sha256': 'f' * 64, 'size_bytes': 20},
      ])),
      throwsFormatException,
    );
  });

  test('requires valid SHA-256 and positive artifact size', () {
    for (final artifact in [
      {'path': 'lib/libcaw_clang.so', 'sha256': 'not-a-hash', 'size_bytes': 10},
      {'path': 'lib/libcaw_clang.so', 'sha256': 'a' * 64, 'size_bytes': 0},
    ]) {
      expect(
        () => CppToolchainManifest.fromJson(manifest(artifacts: [artifact])),
        throwsFormatException,
      );
    }
  });

  test('decodes JSON and rejects unknown manifest versions', () {
    expect(CppToolchainManifest.decode(jsonEncode(manifest())).host, 'android-arm64');
    final unsupported = manifest()..['version'] = 2;
    expect(() => CppToolchainManifest.fromJson(unsupported), throwsFormatException);
  });
}
