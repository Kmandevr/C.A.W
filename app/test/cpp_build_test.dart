import 'dart:io';

import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/storage.dart';
import 'package:caw/platform/cpp_build.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses Clang and GCC diagnostics with file, line and column', () {
    final diagnostics = parseCppBuildDiagnostics(
      'src/stereo.cpp:12:7: error: use of undeclared identifier \\'gain\\'\\n'
      'include/stereo.hpp:4:2: warning: unused parameter \\'frames\\'',
    );

    expect(diagnostics, hasLength(2));
    expect(diagnostics.first.file, 'src/stereo.cpp');
    expect(diagnostics.first.line, 12);
    expect(diagnostics.first.column, 7);
    expect(diagnostics.first.severity, 'error');
    expect(diagnostics.first.message, contains('undeclared identifier'));
    expect(diagnostics.last.severity, 'warning');
  });

  test('parses MSVC and CMake diagnostics', () {
    final diagnostics = parseCppBuildDiagnostics(
      r'C:\\work\\stereo.cpp(5,9): error C2143: syntax error: missing semicolon' '\\n'
      'CMake Error at CMakeLists.txt:12 (add_library):\\n'
      '  Cannot find source file: missing.cpp',
    );

    expect(diagnostics, hasLength(2));
    expect(diagnostics.first.file, r'C:\\work\\stereo.cpp');
    expect(diagnostics.first.line, 5);
    expect(diagnostics.first.column, 9);
    expect(diagnostics.first.code, 'C2143');
    expect(diagnostics.last.file, 'CMakeLists.txt');
    expect(diagnostics.last.line, 12);
    expect(diagnostics.last.code, 'CMAKE');
    expect(diagnostics.last.message, contains('missing.cpp'));
  });

  test('builds a manifest-driven C++ component locally and reuses its build directory', () async {
    if (!Platform.isLinux) return;
    final cmakeCheck = await Process.run('cmake', ['--version']);
    final compilerCheck = await Process.run('c++', ['--version']);
    if (cmakeCheck.exitCode != 0 || compilerCheck.exitCode != 0) return;

    final temporary = await Directory.systemTemp.createTemp('caw-cpp-build-');
    addTearDown(() => temporary.delete(recursive: true));
    final root = Directory('${temporary.path}${Platform.pathSeparator}projects');
    await root.create(recursive: true);
    final sdk = Directory('${temporary.path}${Platform.pathSeparator}sdk');
    final sdkCmake = Directory('${sdk.path}${Platform.pathSeparator}lib${Platform.pathSeparator}cmake${Platform.pathSeparator}CAW');
    await sdkCmake.create(recursive: true);

    var repoRoot = Directory.current;
    while (!File('${repoRoot.path}${Platform.pathSeparator}engine${Platform.pathSeparator}cmake${Platform.pathSeparator}CAWComponent.cmake').existsSync()) {
      final parent = repoRoot.parent;
      if (parent.path == repoRoot.path) throw StateError('Could not locate the CAW repository root for the SDK fixture.');
      repoRoot = parent;
    }
    final helper = File('${repoRoot.path}${Platform.pathSeparator}engine${Platform.pathSeparator}cmake${Platform.pathSeparator}CAWComponent.cmake');
    await helper.copy('${sdkCmake.path}${Platform.pathSeparator}CAWComponent.cmake');
    await File('${sdkCmake.path}${Platform.pathSeparator}CAWConfig.cmake').writeAsString(
      'add_library(CAW::SDK INTERFACE IMPORTED)\\n'
      r'include("${CMAKE_CURRENT_LIST_DIR}/CAWComponent.cmake")' '\\n',
    );
    await File('${sdkCmake.path}${Platform.pathSeparator}CAWConfigVersion.cmake').writeAsString(
      'set(PACKAGE_VERSION "1.0")\\n'
      'if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)\\n'
      '  set(PACKAGE_VERSION_COMPATIBLE FALSE)\\n'
      'else()\\n'
      '  set(PACKAGE_VERSION_COMPATIBLE TRUE)\\n'
      'endif()\\n',
    );

    final component = CppComponentDoc(
      id: 'native-component',
      name: 'Local test component',
      componentId: 'org.caw.tests.local',
      files: {
        'CMakeLists.txt': 'cmake_minimum_required(VERSION 3.22)\\n'
            'project(caw_local_component LANGUAGES CXX)\\n'
            'find_package(CAW 1.0 CONFIG REQUIRED)\\n'
            r'caw_add_component(MANIFEST "${CMAKE_CURRENT_SOURCE_DIR}/caw-component.json" TARGET caw_local_component)' '\\n',
        'caw-component.json': '{\\n'
            '  "format": "caw.component",\\n'
            '  "version": 1,\\n'
            '  "component": {"id": "org.caw.tests.local", "name": "Local test"},\\n'
            '  "sources": ["src/component.cpp"]\\n'
            '}\\n',
        'src/component.cpp': 'extern "C" int caw_component_value() { return 42; }\\n',
      },
    );
    final project = ProjectDoc(
      id: 'local-cpp-project',
      name: 'Local C++ build test',
      cppComponents: [component],
    );
    final storage = ProjectStorage(root);
    final buildService = CppComponentBuildService(storage);

    final first = await buildService.build(
      project: project,
      component: component,
      cmakeExecutable: 'cmake',
      sdkDirectory: sdk.path,
      parallelJobs: 1,
    );
    expect(first.success, isTrue, reason: first.output);
    final buildDirectory = await storage.prepareCppBuildDirectory(project.id, component.id);
    expect(await File('${buildDirectory.path}${Platform.pathSeparator}CMakeCache.txt').exists(), isTrue);
    expect(await File('${buildDirectory.path}${Platform.pathSeparator}artifacts${Platform.pathSeparator}caw_local_component.so').exists(), isTrue);
    expect((await storage.load(project.id))?.cppComponents.single.files['src/component.cpp'],
        contains('return 42'));

    component.files['src/component.cpp'] = 'extern "C" int caw_component_value() { return 43; }\\n';
    final second = await buildService.build(
      project: project,
      component: component,
      cmakeExecutable: 'cmake',
      sdkDirectory: sdk.path,
      parallelJobs: 1,
    );
    expect(second.success, isTrue, reason: second.output);
    final reusedDirectory = await storage.prepareCppBuildDirectory(project.id, component.id);
    expect(reusedDirectory.path, buildDirectory.path);
    expect(await File('${reusedDirectory.path}${Platform.pathSeparator}CMakeCache.txt').exists(), isTrue);
    expect((await storage.load(project.id))?.cppComponents.single.files['src/component.cpp'],
        contains('return 43'));
  });

  test('rejects a zero or negative parallel build budget', () async {
    final runner = CppComponentBuildRunner();
    for (final jobs in [0, -1]) {
      await expectLater(
        runner.build(
          cmakeExecutable: 'cmake',
          projectDirectory: '.',
          buildDirectory: 'build',
          sdkDirectory: 'sdk',
          parallelJobs: jobs,
        ),
        throwsArgumentError,
      );
    }
  });
}
