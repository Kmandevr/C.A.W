// Plug-in export (#162): packs a project C++ component as a CMake project that builds a CLAP or VST3 plug-in with the SDK's caw_add_clap_plugin or caw_add_vst3_plugin, plus a GitHub Actions workflow for the desktop targets, as a .zip.
import 'dart:convert';
import 'dart:typed_data';

import 'cpp_component.dart';

/// The plug-in formats the SDK builds: CLAP (`caw_add_clap_plugin`, a single file) and VST3 (`caw_add_vst3_plugin`,
/// a `.vst3` bundle folder), both for Linux and Windows (docs/native-module-sdk.md).
enum PluginFormat {
  clap('CLAP', '.clap', 'caw_add_clap_plugin', 'clap', 'CLAP', 'FETCHCONTENT_SOURCE_DIR_CAW_CLAP'),
  vst3('VST3', '.vst3', 'caw_add_vst3_plugin', 'vst3', 'VST3', 'FETCHCONTENT_SOURCE_DIR_CAW_VST3');

  const PluginFormat(this.label, this.extension, this.cmakeFunction, this.targetSuffix, this.headers, this.offlineVariable);
  final String label, extension, cmakeFunction, targetSuffix, headers, offlineVariable;

  bool get available => true;

  /// Why a format can't be picked, or null.
  String? get unavailableReason => available ? null : 'The engine has no $label wrapper yet.';

  /// The plug-in folders a desktop DAW scans, for the README and the screen: CLAP's from the CLAP headers'
  /// `clap/entry.h`, VST3's from Steinberg's "Plug-in Locations" page (read 2026-11-11).
  List<(String, String)> get folders => switch (this) {
        clap => const [('Windows', r'C:\Program Files\Common Files\CLAP'), ('Linux', '~/.clap')],
        vst3 => const [('Windows', r'C:\Program Files\Common Files\VST3'), ('Linux', '~/.vst3')],
      };
}

/// The desktop targets. A phone can't build or host desktop plug-ins, so the package's workflow builds them on
/// GitHub's runners.
enum PluginTarget {
  windowsX64('Windows x64', 'windows-latest', 'windows-x64'),
  linuxX64('Linux x64', 'ubuntu-latest', 'linux-x64'),
  // A macOS .clap is a bundle, which caw_add_clap_plugin doesn't build yet.
  macos('macOS', 'macos-latest', 'macos');

  const PluginTarget(this.label, this.runner, this.slug);
  final String label, runner, slug;

  bool get available => this != PluginTarget.macos;
}

/// The C.A.W repository the workflow builds the SDK from (public), and the branch it uses unless told otherwise.
const cawRepository = 'Kmandevr/C.A.W';
const cawDefaultRef = 'Main';

/// What the user sets on the export screen.
class PluginExportSettings {
  const PluginExportSettings({required this.name, required this.vendor, required this.version, this.url = '',
    this.format = PluginFormat.clap, this.targets = const {PluginTarget.windowsX64, PluginTarget.linuxX64}});
  final String name, vendor, version, url;
  final PluginFormat format;
  final Set<PluginTarget> targets;

  /// The file name the plug-in gets (without extension): lower case letters, digits and dashes.
  String get fileName {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'plugin' : s;
  }

  /// Problems that stop the export (CMake refuses quotes, backslashes, semicolons and newlines in these fields).
  List<String> get problems => [
        if (name.trim().isEmpty) 'Give the plug-in a name.',
        if (vendor.trim().isEmpty) 'Give a vendor (your name or label).',
        if (!RegExp(r'^\d+(\.\d+){0,3}$').hasMatch(version.trim())) 'Version is numbers with dots, such as 1.0.0.',
        for (final (label, v) in [('Name', name), ('Vendor', vendor), ('URL', url)])
          if (RegExp('["\\\\;\\n\\r]').hasMatch(v)) '$label can\'t contain quotes, backslashes or semicolons.',
        if (!format.available) format.unavailableReason!,
        if (!targets.any((t) => t.available)) 'Pick at least one target.',
      ];
}

/// The package's files, by path inside the zip (all under one top folder named after the plug-in).
Map<String, String> pluginPackageFiles(CppComponentDoc component, PluginExportSettings s) {
  final top = '${s.fileName}-plugin';
  final targets = [for (final t in PluginTarget.values) if (s.targets.contains(t) && t.available) t];
  final target = 'caw_component_${s.fileName.replaceAll('-', '_')}';
  final f = s.format;
  final file = '${s.fileName}${f.extension}';
  final cmake = '''# Builds "${s.name}" as a ${f.label} plug-in with the C.A.W SDK (exported from C.A.W).
cmake_minimum_required(VERSION 3.22)
project(${target}_plugin LANGUAGES CXX)

find_package(CAW 1.0 CONFIG REQUIRED)

# The component library C.A.W loads, from the component's own manifest and sources.
caw_add_component(MANIFEST "\${CMAKE_CURRENT_SOURCE_DIR}/component/caw-component.json" TARGET $target)

# The same code as a ${f.label} plug-in: $file next to the library (configuring fetches the ${f.headers} headers).
${f.cmakeFunction}(TARGET ${target}_${f.targetSuffix} COMPONENT $target
  OUTPUT_NAME "${s.fileName}" VENDOR "${s.vendor.trim()}" VERSION "${s.version.trim()}"${s.url.trim().isEmpty ? '' : ' URL "${s.url.trim()}"'})
''';
  final workflow = '''# Builds the plug-in for each desktop target on GitHub's runners and keeps the $file ${f == PluginFormat.vst3 ? 'bundle' : 'file'} as run artifacts.
name: Build plug-in
on:
  push:
  workflow_dispatch:
    inputs:
      caw_ref:
        description: C.A.W branch, tag or commit whose SDK to build against
        default: $cawDefaultRef
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
${[for (final t in targets) '          - { os: ${t.runner}, name: ${t.slug} }'].join('\n')}
    runs-on: \${{ matrix.os }}
    steps:
      - uses: actions/checkout@v7
      - uses: actions/checkout@v7
        with:
          repository: $cawRepository
          ref: \${{ inputs.caw_ref || '$cawDefaultRef' }}
          path: caw
      - name: Build and install the C.A.W SDK
        run: |
          cmake -S caw/engine -B sdk-build -DCMAKE_BUILD_TYPE=Release -DCAW_AUDIO=OFF -DCAW_TOOLS=OFF
          cmake --build sdk-build --config Release --parallel
          cmake --install sdk-build --config Release --prefix sdk
      - name: Build the plug-in
        run: |
          cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="\${{ github.workspace }}/sdk"
          cmake --build build --config Release --parallel
      - uses: actions/upload-artifact@v7
        with:
          name: ${s.fileName}-\${{ matrix.name }}
          path: ${f == PluginFormat.vst3 ? 'build/artifacts/$file' : 'build/artifacts/**/*.clap'}
          if-no-files-found: error
''';
  final deps = component.dependencies.entries.map((e) => '- ${e.key} ${e.value}').join('\n');
  final readme = '''# ${s.name}

A ${f.label} plug-in made from the C.A.W C++ component `${component.componentId}`, by ${s.vendor.trim()}, version ${s.version.trim()}.
Targets: ${targets.map((t) => t.label).join(', ')}.

## Build it on GitHub (no PC needed)

1. Create a new repository on GitHub and upload everything in this folder to it, keeping the `.github` folder.
2. The **Build plug-in** workflow runs on every push (or from the Actions tab: Run workflow).
3. When the run finishes, download `${s.fileName}-<target>` from the run's Artifacts and unzip it: inside is `$file`${f == PluginFormat.vst3 ? ' (a folder: the VST3 bundle)' : ''}.

The workflow builds the C.A.W SDK from `$cawRepository` at `$cawDefaultRef`. For a build that never changes, run it with
`caw_ref` set to a fixed commit.

## Build it on a desktop

Install the C.A.W SDK (`cmake -S engine -B sdk-build -DCAW_AUDIO=OFF -DCAW_TOOLS=OFF`, build it, then
`cmake --install sdk-build --prefix <sdk>`), then in this folder:

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=<sdk>
    cmake --build build --config Release

${f == PluginFormat.vst3 ? vst3Readme(file) : clapReadme(file)}
${deps.isEmpty ? '' : '\n## Dependencies\n\nThe component lists these pinned dependencies; the package does not fetch them:\n\n$deps\n'}''';
  return {
    '$top/CMakeLists.txt': cmake,
    '$top/README.md': readme,
    '$top/.github/workflows/build-plugin.yml': workflow,
    for (final e in component.files.entries)
      if (CppComponentDoc.isSafeRelativePath(e.key)) '$top/component/${e.key}': e.value,
  };
}

/// The README's build-offline and install part for a `.clap` ([file]).
String clapReadme(String file) => '''Configuring downloads the CLAP headers (MIT licence) from GitHub; offline, set `FETCHCONTENT_SOURCE_DIR_CAW_CLAP` to a
checkout of free-audio/clap.

## Load it in a DAW

Copy `$file` into a CLAP folder, then let your DAW rescan its plug-ins. The standard folders (from the CLAP
headers, `clap/entry.h`):

- Windows: `%COMMONPROGRAMFILES%\\CLAP` (usually `C:\\Program Files\\Common Files\\CLAP`) or
  `%LOCALAPPDATA%\\Programs\\Common\\CLAP`
- Linux: `~/.clap` or `/usr/lib/clap`

Hosts also search the folders in a `CLAP_PATH` environment variable. The plug-in shows under the component's own
name with the host's generic parameter controls (there is no custom editor window). macOS isn't built yet.''';

/// The README's build-offline and install part for a `.vst3` bundle ([file]).
String vst3Readme(String file) => '''Configuring downloads the VST3 interface headers (steinbergmedia/vst3_pluginterfaces, MIT licence) from GitHub; offline,
set `FETCHCONTENT_SOURCE_DIR_CAW_VST3` to a checkout of that repository in a folder named `pluginterfaces`.

## Load it in a DAW

`$file` is a folder (a VST3 bundle): copy the whole folder into a VST3 folder, then let your DAW rescan its plug-ins.
The standard folders (Steinberg's VST 3 documentation, "Plug-in Locations"):

- Windows: `C:\\Program Files\\Common Files\\VST3`, or for your user only `%LOCALAPPDATA%\\Programs\\Common\\VST3`
- Linux: `~/.vst3`, `/usr/lib/vst3` or `/usr/local/lib/vst3`

The plug-in shows under the component's own name with the host's generic parameter controls (there is no custom
editor window). macOS isn't built yet.''';

/// A plain zip (stored, no compression) of [files] (path to text), with fixed times so the same input gives the same
/// bytes.
Uint8List zipStore(Map<String, String> files) {
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var count = 0;
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  const time = 0, date = (2026 - 1980) << 9 | 1 << 5 | 1; // 2026-01-01 00:00
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final data = utf8.encode(e.value);
    final crc = crc32(data);
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0x0800); // UTF-8 names
    u16(out, 0);
    u16(out, time);
    u16(out, date);
    u32(out, crc);
    u32(out, data.length);
    u32(out, data.length);
    u16(out, name.length);
    u16(out, 0);
    out.add(name);
    out.add(data);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, time);
    u16(central, date);
    u32(central, crc);
    u32(central, data.length);
    u32(central, data.length);
    u16(central, name.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(name);
    count++;
  }
  final centralAt = out.length, centralBytes = central.takeBytes();
  out.add(centralBytes);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, count);
  u16(out, count);
  u32(out, centralBytes.length);
  u32(out, centralAt);
  u16(out, 0);
  return out.takeBytes();
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// CRC-32 (IEEE), as zip uses.
int crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
