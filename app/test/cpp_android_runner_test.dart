import 'package:caw/platform/cpp_build.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android never attempts to launch the desktop CMake process runner', () async {
    final runner = CppComponentBuildRunner(isAndroid: true);
    final result = await runner.build(
      cmakeExecutable: '/data/user/0/com.kmandevr.caw/files/bin/cmake',
      projectDirectory: '/data/user/0/com.kmandevr.caw/files/project',
      buildDirectory: '/data/user/0/com.kmandevr.caw/files/build',
      sdkDirectory: '/data/user/0/com.kmandevr.caw/files/sdk',
      parallelJobs: 1,
    );

    expect(result.success, isFalse);
    expect(result.exitCode, 126);
    expect(result.diagnostics, hasLength(1));
    expect(result.diagnostics.single.code, 'CAW_ANDROID_TOOLCHAIN_UNAVAILABLE');
    expect(result.output, contains('in-process Clang toolchain'));
  });

  test('desktop keeps the process runner enabled', () async {
    final runner = CppComponentBuildRunner(isAndroid: false);
    final result = await runner.build(
      cmakeExecutable: '/path/that/does/not/exist/cmake',
      projectDirectory: '.',
      buildDirectory: 'build',
      sdkDirectory: 'sdk',
      parallelJobs: 1,
    );

    expect(result.success, isFalse);
    expect(result.diagnostics, isNotEmpty);
    expect(result.diagnostics.single.code, 'CAW_BUILD_FAILED');
  });
}
