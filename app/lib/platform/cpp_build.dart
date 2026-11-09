// Runs the local CMake build for a saved C++ component and converts compiler output to app diagnostics.
import 'dart:convert';
import 'dart:io';

import '../model/cpp_component.dart';
import '../model/project.dart';
import '../model/storage.dart';

class CppBuildDiagnostic {
  const CppBuildDiagnostic({
    required this.severity,
    required this.message,
    this.file,
    this.line,
    this.column,
    this.code,
  });

  final String severity;
  final String message;
  final String? file;
  final int? line;
  final int? column;
  final String? code;
}

class CppBuildResult {
  const CppBuildResult({
    required this.success,
    required this.exitCode,
    required this.output,
    required this.diagnostics,
  });

  final bool success;
  final int exitCode;
  final String output;
  final List<CppBuildDiagnostic> diagnostics;
}

/// Joins project persistence, safe source materialization and the local CMake runner.
class CppComponentBuildService {
  CppComponentBuildService(this._storage, {CppComponentBuildRunner? runner})
      : runner = runner ?? CppComponentBuildRunner();

  final ProjectStorage _storage;
  final CppComponentBuildRunner runner;

  Future<CppBuildResult> build({
    required ProjectDoc project,
    required CppComponentDoc component,
    required String cmakeExecutable,
    required String sdkDirectory,
    required int parallelJobs,
    String configuration = 'Release',
    String? toolchainFile,
    String? androidAbi,
    String? androidPlatform,
    Map<String, String>? environment,
  }) async {
    if (!project.cppComponents.any((candidate) => identical(candidate, component))) {
      throw ArgumentError.value(component.id, 'component', 'Must belong to the project being built.');
    }
    // Preserve the user's latest source before any external build tool is started.
    await _storage.save(project);
    final sourceDirectory = await _storage.materializeCppComponent(project, component);
    final buildDirectory = await _storage.prepareCppBuildDirectory(project.id, component.id);
    return runner.build(
      cmakeExecutable: cmakeExecutable,
      projectDirectory: sourceDirectory.path,
      buildDirectory: buildDirectory.path,
      sdkDirectory: sdkDirectory,
      parallelJobs: parallelJobs,
      configuration: configuration,
      toolchainFile: toolchainFile,
      androidAbi: androidAbi,
      androidPlatform: androidPlatform,
      environment: environment,
    );
  }
}

/// Parses Clang/GCC, MSVC and CMake diagnostics without losing file/line information.
List<CppBuildDiagnostic> parseCppBuildDiagnostics(String output) {
  final diagnostics = <CppBuildDiagnostic>[];
  final gcc = RegExp(r'^(.*?):(\d+):(\d+):\s*(fatal error|error|warning|note):\s*(.*)$');
  final msvc = RegExp(r'^(.*)\((\d+),(\d+)\):\s*(fatal error|error|warning|note)\s*([A-Z]+\d+)?\s*:\s*(.*)$');
  final cmake = RegExp(r'^CMake (Error|Warning) at (.*):(\d+) \(([^)]+)\):(.*)$');
  final lines = output.split(RegExp(r'\r?\n'));

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    var match = gcc.firstMatch(line);
    if (match != null) {
      diagnostics.add(CppBuildDiagnostic(
        file: match.group(1),
        line: int.parse(match.group(2)!),
        column: int.parse(match.group(3)!),
        severity: match.group(4) == 'fatal error' ? 'error' : match.group(4)!,
        message: match.group(5)!,
      ));
      continue;
    }

    match = msvc.firstMatch(line);
    if (match != null) {
      diagnostics.add(CppBuildDiagnostic(
        file: match.group(1),
        line: int.parse(match.group(2)!),
        column: int.parse(match.group(3)!),
        severity: match.group(4) == 'fatal error' ? 'error' : match.group(4)!,
        code: match.group(5),
        message: match.group(6)!,
      ));
      continue;
    }

    match = cmake.firstMatch(line);
    if (match != null) {
      final detail = match.group(5)!.trim();
      diagnostics.add(CppBuildDiagnostic(
        file: match.group(2),
        line: int.parse(match.group(3)!),
        severity: match.group(1)!.toLowerCase(),
        code: 'CMAKE',
        message: detail.isNotEmpty
            ? detail
            : index + 1 < lines.length
                ? lines[index + 1].trim()
                : match.group(4)!,
      ));
    }
  }
  return diagnostics;
}

/// Invokes CMake directly on desktop; Android must use its in-process compiler module.
class CppComponentBuildRunner {
  CppComponentBuildRunner({bool? isAndroid}) : _isAndroid = isAndroid ?? Platform.isAndroid;

  final bool _isAndroid;

  Future<CppBuildResult> build({
    required String cmakeExecutable,
    required String projectDirectory,
    required String buildDirectory,
    required String sdkDirectory,
    required int parallelJobs,
    String configuration = 'Release',
    String? toolchainFile,
    String? androidAbi,
    String? androidPlatform,
    Map<String, String>? environment,
  }) async {
    if (parallelJobs < 1) throw ArgumentError.value(parallelJobs, 'parallelJobs', 'Must be at least one.');
    if (_isAndroid) {
      const message = 'Android C++ builds require the bundled in-process Clang toolchain; process-based CMake execution is disabled.';
      return const CppBuildResult(
        success: false,
        exitCode: 126,
        output: message,
        diagnostics: [
          CppBuildDiagnostic(
            severity: 'error',
            code: 'CAW_ANDROID_TOOLCHAIN_UNAVAILABLE',
            message: message,
          ),
        ],
      );
    }

    final configureArgs = [
      '-S', projectDirectory,
      '-B', buildDirectory,
      '-DCMAKE_PREFIX_PATH=$sdkDirectory',
      '-DCMAKE_BUILD_TYPE=$configuration',
    ];
    if (toolchainFile != null) configureArgs.add('-DCMAKE_TOOLCHAIN_FILE=$toolchainFile');
    if (androidAbi != null) configureArgs.add('-DANDROID_ABI=$androidAbi');
    if (androidPlatform != null) configureArgs.add('-DANDROID_PLATFORM=$androidPlatform');

    final output = StringBuffer();
    var exitCode = await _run(cmakeExecutable, configureArgs, projectDirectory, environment, output);
    if (exitCode == 0) {
      exitCode = await _run(
        cmakeExecutable,
        ['--build', buildDirectory, '--config', configuration, '--parallel', '$parallelJobs'],
        projectDirectory,
        environment,
        output,
      );
    }

    final text = output.toString();
    final diagnostics = parseCppBuildDiagnostics(text);
    if (exitCode != 0 && diagnostics.isEmpty) {
      final lines = text.trim().split(RegExp(r'\r?\n'));
      diagnostics.add(CppBuildDiagnostic(
        severity: 'error',
        code: 'CAW_BUILD_FAILED',
        message: lines.isEmpty || lines.last.isEmpty
            ? 'C.A.W. component build failed without a compiler diagnostic.'
            : lines.last,
      ));
    }
    return CppBuildResult(success: exitCode == 0, exitCode: exitCode, output: text, diagnostics: diagnostics);
  }

  Future<int> _run(
    String executable,
    List<String> arguments,
    String workingDirectory,
    Map<String, String>? environment,
    StringBuffer output,
  ) async {
    try {
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: false,
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;
      output
        ..write(await stdout)
        ..write(await stderr);
      return exitCode;
    } on ProcessException catch (error) {
      output.writeln(error.message);
      return error.errorCode == 0 ? 127 : error.errorCode;
    }
  }
}
