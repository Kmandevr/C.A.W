// Builds a C++ component's sources into a loadable library with the in-app compiler (Clang and LLD), offline.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../model/cpp_component.dart';
import 'cpp_build.dart';

/// The compiler itself: on Android a library in its own process (CompilerService), reached over a channel.
abstract class CppCompiler {
  /// The compiler's data (headers, sysroot, runtime libraries), unpacked if needed. Throws [StateError] when
  /// this build of the app has no compiler.
  Future<String> toolchainDirectory();

  /// Runs one clang command line (argv[0] is `<toolchain>/bin/clang++`): the exit code and every diagnostic.
  Future<({int code, String output})> run(List<String> args);
}

/// This device's in-app compiler, or null where there is none (desktop builds use the CMake runner).
CppCompiler? platformCppCompiler() => Platform.isAndroid ? AndroidCppCompiler() : null;

class AndroidCppCompiler implements CppCompiler {
  static const _channel = MethodChannel('caw/compiler');
  String? _toolchain;

  @override
  Future<String> toolchainDirectory() async {
    final cached = _toolchain;
    if (cached != null) return cached;
    try {
      final dir = await _channel.invokeMethod<String>('installToolchain');
      if (dir == null) throw StateError('the C++ compiler is not available');
      return _toolchain = dir;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? 'the C++ compiler is not available');
    }
  }

  @override
  Future<({int code, String output})> run(List<String> args) async {
    final result = await _channel.invokeMapMethod<String, Object?>('run', {'args': args});
    return (code: (result?['code'] as int?) ?? 1, output: (result?['output'] as String?) ?? '');
  }
}

/// What `caw-component.json` says about a build (the same manifest the CMake helper reads).
class CppComponentManifest {
  const CppComponentManifest({required this.id, required this.sources, this.includeDirectories = const [], this.definitions = const []});

  final String id;
  final List<String> sources;
  final List<String> includeDirectories;
  final List<String> definitions;

  static final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
  static final _definitionPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(=[^\s"]*)?$');

  /// Throws [FormatException] for anything the build can't take safely (unsafe paths, no sources).
  static CppComponentManifest parse(String text) {
    final j = jsonDecode(text);
    if (j is! Map<String, dynamic> || j['format'] != 'caw.component' || j['version'] != 1) {
      throw const FormatException('caw-component.json must be a caw.component version 1 manifest');
    }
    final id = (j['component'] as Map?)?['id'];
    if (id is! String || !_idPattern.hasMatch(id)) throw const FormatException('caw-component.json needs a component id');
    List<String> paths(String key) {
      final list = j[key];
      if (list == null) return const [];
      if (list is! List || list.any((p) => p is! String || !CppComponentDoc.isSafeRelativePath(p))) {
        throw FormatException('caw-component.json: every entry of "$key" must be a project-relative path');
      }
      return list.cast<String>();
    }

    final sources = paths('sources');
    if (sources.isEmpty) throw const FormatException('caw-component.json lists no sources');
    final definitions = j['compileDefinitions'];
    if (definitions != null &&
        (definitions is! List || definitions.any((d) => d is! String || !_definitionPattern.hasMatch(d)))) {
      throw const FormatException('caw-component.json: compileDefinitions must be NAME or NAME=value');
    }
    return CppComponentManifest(
      id: id,
      sources: sources,
      includeDirectories: paths('includeDirectories'),
      definitions: (definitions as List?)?.cast<String>() ?? const [],
    );
  }
}

/// Compiles a materialized component directory into `<id>-<n>.so` with the in-app compiler. Each build gets a new
/// file, so a rebuild can be loaded next to the playing one (the system loader returns an already-loaded path).
class CppSourceBuilder {
  CppSourceBuilder(this.compiler, {this.optimize = true});

  final CppCompiler compiler;
  final bool optimize;

  /// The arguments for one build, for tests and the build log.
  static List<String> arguments({
    required String toolchain,
    required String sourceDirectory,
    required CppComponentManifest manifest,
    required String output,
    bool optimize = true,
  }) {
    // Clang's headers live in lib/clang/<major version>, as the bundle lays them out.
    final clangDir = Directory('$toolchain/lib/clang');
    final clangVersion =
        clangDir.existsSync() ? clangDir.listSync().whereType<Directory>().map((d) => d.path.split('/').last).firstOrNull : null;
    return [
      '$toolchain/bin/clang++', // the C++ driver: it links the C++ library
      '--target=aarch64-linux-android26',
      '--sysroot=$toolchain/sysroot',
      if (clangVersion != null) '-resource-dir=$toolchain/lib/clang/$clangVersion',
      '-std=c++20',
      optimize ? '-O2' : '-O0',
      '-fPIC',
      '-shared',
      '-static-libstdc++',
      // The engine's floating-point rules, so a component sounds the same on every device (CAW::SDK passes them too).
      '-ffp-contract=off',
      '-fno-fast-math',
      '-fvisibility=hidden',
      '-fno-color-diagnostics',
      '-I$toolchain/caw-sdk/include',
      for (final dir in manifest.includeDirectories) '-I$sourceDirectory/$dir',
      for (final d in manifest.definitions) '-D$d',
      for (final source in manifest.sources) '$sourceDirectory/$source',
      '-o',
      output,
    ];
  }

  Future<CppBuildResult> build({required String sourceDirectory, required String outputDirectory}) async {
    CppComponentManifest manifest;
    try {
      manifest = CppComponentManifest.parse(await File('$sourceDirectory/caw-component.json').readAsString());
    } on FileSystemException {
      return _failure('CAW_MANIFEST', 'The component has no caw-component.json.');
    } on FormatException catch (e) {
      return _failure('CAW_MANIFEST', e.message);
    }
    String toolchain;
    try {
      toolchain = await compiler.toolchainDirectory();
    } on StateError catch (e) {
      return _failure('CAW_COMPILER_UNAVAILABLE', e.message);
    }
    await Directory(outputDirectory).create(recursive: true);
    final output = '$outputDirectory/${manifest.id}-${DateTime.now().microsecondsSinceEpoch}.so';
    final run = await compiler.run(arguments(
        toolchain: toolchain, sourceDirectory: sourceDirectory, manifest: manifest, output: output, optimize: optimize));
    // Paths in diagnostics read as the project's own (src/main.cpp), not the private workspace.
    final text = run.output.replaceAll('$sourceDirectory/', '');
    final diagnostics = parseCppBuildDiagnostics(text);
    if (run.code != 0 || !await File(output).exists()) {
      return CppBuildResult(
        success: false,
        exitCode: run.code == 0 ? 1 : run.code,
        output: text,
        diagnostics: diagnostics.isNotEmpty || run.code == 0
            ? diagnostics
            : [CppBuildDiagnostic(severity: 'error', code: 'CAW_COMPILER', message: _firstLine(text) ?? 'The build failed.')],
      );
    }
    // Code loaded from app storage is read-only (Android 14 requires it for dynamically loaded code).
    if (!makeReadOnly(output)) {
      return _failure('CAW_ARTIFACT_MODE', 'The built library could not be made read-only, so it was not loaded.');
    }
    await _removeOlderBuilds(outputDirectory, manifest.id, keep: output);
    return CppBuildResult(success: true, exitCode: 0, output: text, diagnostics: diagnostics, artifactPath: output);
  }

  // Older builds of the component: the newest one before this stays (it may still be playing while this loads).
  static Future<void> _removeOlderBuilds(String directory, String id, {required String keep}) async {
    final builds = Directory(directory)
        .listSync()
        .whereType<File>()
        .where((f) => f.path != keep && f.uri.pathSegments.last.startsWith('$id-') && f.path.endsWith('.so'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in builds.skip(1)) {
      try {
        await old.delete();
      } on FileSystemException {
        // Still mapped somewhere: removed after a later build.
      }
    }
  }

  static String? _firstLine(String text) {
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return null;
  }

  static CppBuildResult _failure(String code, String message) => CppBuildResult(
        success: false,
        exitCode: 1,
        output: message,
        diagnostics: [CppBuildDiagnostic(severity: 'error', code: code, message: message)],
      );
}

/// chmod 0444 through libc (Android and Linux), so dynamically loaded code can't be changed in place.
bool makeReadOnly(String path) {
  if (!(Platform.isAndroid || Platform.isLinux)) return true;
  final chmod = DynamicLibrary.process().lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');
  final p = path.toNativeUtf8();
  try {
    return chmod(p, 0x124) == 0; // 0444
  } finally {
    calloc.free(p);
  }
}
