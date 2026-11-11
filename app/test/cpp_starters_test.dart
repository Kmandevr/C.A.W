// The C++ starters bundled in the app match examples/cpp/starters, and a copy gets its own component id.
// CAW_UPDATE_STARTERS=1 flutter test test/cpp_starters_test.dart rewrites lib/model/cpp_starters_sources.dart.
import 'dart:io';

import 'package:caw/model/cpp_starters.dart';
import 'package:caw/model/cpp_starters_sources.dart';
import 'package:caw/platform/cpp_compiler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The starters on disk: folder -> {path in the folder -> text}, the manifest and the sources it lists.
Map<String, Map<String, String>> _onDisk() {
  final root = Directory('../examples/cpp/starters');
  final out = <String, Map<String, String>>{};
  final folders = root.listSync().whereType<Directory>().where((d) => File('${d.path}/caw-component.json').existsSync()).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final d in folders) {
    final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final files = <String, String>{'caw-component.json': File('${d.path}/caw-component.json').readAsStringSync()};
    for (final f in Directory('${d.path}/src').listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
      files['src/${f.uri.pathSegments.last}'] = f.readAsStringSync();
    }
    out[name] = files;
  }
  return out;
}

String _generate(Map<String, Map<String, String>> starters) {
  final b = StringBuffer()
    ..writeln('// The C++ starters\' files, generated from examples/cpp/starters by test/cpp_starters_test.dart; do not edit.')
    ..writeln('// Regenerate: CAW_UPDATE_STARTERS=1 flutter test test/cpp_starters_test.dart')
    ..writeln()
    ..writeln('/// Folder name -> {path in the component -> text}.')
    ..writeln('const cppStarterSources = <String, Map<String, String>>{');
  for (final s in starters.entries) {
    b.writeln("  '${s.key}': {");
    for (final f in s.value.entries) {
      if (f.value.contains("'''")) throw StateError('${s.key}/${f.key} contains a triple quote');
      b.writeln("    '${f.key}': r'''${f.value}''',");
    }
    b.writeln('  },');
  }
  b.writeln('};');
  return b.toString();
}

void main() {
  test('the bundled starters are the ones in examples/cpp/starters', () {
    final disk = _onDisk();
    if (Platform.environment['CAW_UPDATE_STARTERS'] == '1') {
      File('lib/model/cpp_starters_sources.dart').writeAsStringSync(_generate(disk));
      return;
    }
    expect(disk.keys, isNotEmpty);
    expect(cppStarterSources, disk,
        reason: 'run CAW_UPDATE_STARTERS=1 flutter test test/cpp_starters_test.dart after changing a starter');
  });

  test('a starter reads its name, summary and kind, and a copy has its own id everywhere', () {
    final bass = cppStarters.firstWhere((s) => s.folder == 'bass');
    expect(bass.name, 'Bass');
    expect(bass.summary, startsWith('A filtered saw bass'));
    expect(bass.instrument, isTrue);
    expect(cppStarters.firstWhere((s) => s.folder == 'glitch-fx').instrument, isFalse);
    final copy = bass.copy(id: 'cpp7', displayName: 'Bass 2');
    expect(copy.componentId, 'local.bass.cpp7');
    expect(copy.files.values.any((t) => t.contains('org.caw.starter.bass')), isFalse);
    expect(copy.files['caw-component.json'], contains('"local.bass.cpp7"'));
    expect(copy.files['src/bass.cpp'], contains('d.id = "local.bass.cpp7";'));
    final manifest = CppComponentManifest.parse(copy.files['caw-component.json']!);
    expect(manifest.id, 'local.bass.cpp7');
    expect(manifest.sources, ['src/bass.cpp']);
  });
}
