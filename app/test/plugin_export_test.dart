// Plug-in export (#162): the package's CMake project and workflow, the zip writer, and (with CAW_SDK_DIR set to an installed SDK) a real CLAP build of the package.
import 'dart:io';
import 'dart:typed_data';

import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/plugin_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final component = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Space Echo');
  const settings = PluginExportSettings(name: 'Space Echo', vendor: 'Me', version: '1.2.0', url: 'https://example.org');

  test('settings check what CMake would refuse', () {
    expect(settings.problems, isEmpty);
    expect(settings.fileName, 'space-echo');
    expect(const PluginExportSettings(name: 'A', vendor: 'B "C"', version: '1').problems, hasLength(1));
    expect(const PluginExportSettings(name: 'A', vendor: 'B', version: 'one').problems, hasLength(1));
    expect(const PluginExportSettings(name: 'A', vendor: 'B', version: '1', format: PluginFormat.vst3).problems,
        ['The engine has no VST3 wrapper yet.']);
    expect(const PluginExportSettings(name: 'A', vendor: 'B', version: '1', targets: {PluginTarget.macos}).problems,
        ['Pick at least one target.']);
  });

  test('the package holds the component, a CMake project and a workflow for the chosen targets', () {
    final files = pluginPackageFiles(component, const PluginExportSettings(name: 'Space Echo', vendor: 'Me',
        version: '1.2.0', targets: {PluginTarget.linuxX64}));
    expect(files.keys, containsAll(['space-echo-plugin/CMakeLists.txt', 'space-echo-plugin/README.md',
      'space-echo-plugin/.github/workflows/build-plugin.yml', 'space-echo-plugin/component/caw-component.json',
      'space-echo-plugin/component/src/effect.cpp']));
    final cmake = files['space-echo-plugin/CMakeLists.txt']!;
    expect(cmake, contains('caw_add_clap_plugin(TARGET caw_component_space_echo_clap COMPONENT caw_component_space_echo'));
    expect(cmake, contains('VENDOR "Me" VERSION "1.2.0"'));
    final workflow = files['space-echo-plugin/.github/workflows/build-plugin.yml']!;
    expect(workflow, contains('ubuntu-latest'));
    expect(workflow, isNot(contains('windows-latest')));
  });

  test('crc32 and the stored zip', () {
    expect(crc32('123456789'.codeUnits), 0xcbf43926);
    final zip = zipStore({'a/b.txt': 'hello', 'c.txt': ''});
    final d = ByteData.sublistView(zip);
    expect(d.getUint32(0, Endian.little), 0x04034b50);
    final end = zip.length - 22;
    expect(d.getUint32(end, Endian.little), 0x06054b50);
    expect(d.getUint16(end + 10, Endian.little), 2);
    expect(zipStore({'x': 'y'}), zipStore({'x': 'y'})); // the same bytes every time
  });

  final sdk = Platform.environment['CAW_SDK_DIR'];
  test('the package builds a .clap against the installed SDK', () async {
    final dir = await Directory.systemTemp.createTemp('caw-plugin-');
    addTearDown(() => dir.delete(recursive: true));
    final zip = File('${dir.path}/p.zip')..writeAsBytesSync(zipStore(pluginPackageFiles(component, settings)));
    final unzip = await Process.run('unzip', ['-q', zip.path, '-d', dir.path]);
    expect(unzip.exitCode, 0, reason: '${unzip.stderr}');
    final src = '${dir.path}/space-echo-plugin';
    // Offline, point FETCHCONTENT_SOURCE_DIR_CAW_CLAP at a CLAP checkout (the engine build's _deps/caw_clap-src).
    final clap = Platform.environment['FETCHCONTENT_SOURCE_DIR_CAW_CLAP'];
    final configure = await Process.run('cmake', ['-S', src, '-B', '$src/build', '-DCMAKE_BUILD_TYPE=Release',
      '-DCMAKE_PREFIX_PATH=$sdk', if (clap != null) '-DFETCHCONTENT_SOURCE_DIR_CAW_CLAP=$clap']);
    expect(configure.exitCode, 0, reason: '${configure.stdout}${configure.stderr}');
    final build = await Process.run('cmake', ['--build', '$src/build', '--config', 'Release']);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    expect(File('$src/build/artifacts/space-echo.clap').existsSync(), isTrue);
  }, skip: sdk == null || sdk.isEmpty ? 'set CAW_SDK_DIR to an installed C.A.W SDK' : null, timeout: const Timeout(Duration(minutes: 5)));
}
