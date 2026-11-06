// Tests local CMake build diagnostics and command-runner input validation.
import 'package:caw/platform/cpp_build.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses Clang and GCC diagnostics with file, line and column', () {
    final diagnostics = parseCppBuildDiagnostics(
      'src/stereo.cpp:12:7: error: use of undeclared identifier \'gain\'\n'
      'include/stereo.hpp:4:2: warning: unused parameter \'frames\'',
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
      r'C:\work\stereo.cpp(5,9): error C2143: syntax error: missing semicolon' '\n'
      'CMake Error at CMakeLists.txt:12 (add_library):\n'
      '  Cannot find source file: missing.cpp',
    );

    expect(diagnostics, hasLength(2));
    expect(diagnostics.first.file, r'C:\work\stereo.cpp');
    expect(diagnostics.first.line, 5);
    expect(diagnostics.first.column, 9);
    expect(diagnostics.first.code, 'C2143');
    expect(diagnostics.last.file, 'CMakeLists.txt');
    expect(diagnostics.last.line, 12);
    expect(diagnostics.last.code, 'CMAKE');
    expect(diagnostics.last.message, contains('missing.cpp'));
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
