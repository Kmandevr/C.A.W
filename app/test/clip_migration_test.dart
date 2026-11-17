// Format v4 -> v5 (#216): a v4 project's pattern text becomes MIDI on load without losing a note, and plays the same:
// every pattern of the engine's tests, the examples, the templates, the default project and one with every feature
// renders bit for bit the same before and after (the renders need CAW_LIB, a built engine library; CI sets it).
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/clip_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/pattern_templates.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

import 'clip_midi_test.dart' show kEverything;

/// Pattern texts from the engine's tests (whole C++ string literals), the examples, the templates and the default
/// project, plus [kEverything]; each parses.
List<(String, String)> corpus() {
  final out = <(String, String)>[('every feature', kEverything)];
  final literal = RegExp(r'"(---\\nkind: pattern(?:[^"\\]|\\[^\\])*)"');
  for (final f in Directory('../engine/tests').listSync().whereType<File>().where((f) => f.path.endsWith('.cpp'))) {
    for (final m in literal.allMatches(f.readAsStringSync())) {
      final text = m.group(1)!.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\t', '\t');
      out.add((f.uri.pathSegments.last, text));
    }
  }
  for (final f in Directory('../examples').listSync().whereType<File>().where((f) => f.path.endsWith('.caw'))) {
    out.add((f.uri.pathSegments.last, f.readAsStringSync()));
  }
  for (final t in patternTemplates) {
    out.add(('template ${t.file}', t.source));
  }
  final def = jsonDecode(File('assets/projects/default.json').readAsStringSync()) as Map<String, dynamic>;
  for (final m in (def['modules'] as List).cast<Map<String, dynamic>>()) {
    out.add(('default ${m['name']}', (m['run_source'] ?? m['source']) as String));
  }
  return [for (final c in out) if (PatternDoc.parse(c.$2).ok) c];
}

ProjectDoc _project(String source) => ProjectDoc(id: 'p', name: 'T', bpm: 128, modules: [
      ModuleDoc(id: 'm', name: 'P', source: source),
    ], layers: [
      LayerDoc(id: 'l', name: 'Synth', color: 0, patternId: 'm')..setInstrument('org.caw.synth.flagship'),
    ]);

/// [source] saved by C.A.W 1.0.4 (format v4, its text), opened and saved by this one (v5), and opened again.
ProjectDoc _migrated(String source) {
  final v4 = _project(source).toJson()
    ..['caw_app_project'] = 4
    ..['modules'] = [{'id': 'm', 'name': 'P', 'source': source, 'run_source': source, 'folder_path': '', 'tags': []}];
  final opened = ProjectDoc.fromJson(jsonDecode(jsonEncode(v4)) as Map<String, dynamic>);
  final v5 = jsonDecode(jsonEncode(opened.toJson())) as Map<String, dynamic>;
  expect(v5['caw_app_project'], 5);
  final stored = (v5['modules'] as List).single as Map<String, dynamic>;
  expect(stored.containsKey('source'), isFalse, reason: 'no pattern text is saved');
  expect(stored['midi'], isA<String>());
  return ProjectDoc.fromJson(v5);
}

void main() {
  final cases = corpus();

  test('the corpus covers the engine tests, examples, templates and default project', () {
    expect(cases.length, greaterThan(60));
    expect(cases.map((c) => c.$1), containsAll(['acid-line.caw', 'chords.caw', 'every feature', 'engine_rt_test.cpp']));
  });

  test('every v4 pattern converts on load with every note, comment and header line kept', () {
    for (final (where, old) in cases) {
      final a = PatternDoc.parse(old).doc!;
      final m = _migrated(old).modules.single;
      expect(m.edited, isFalse);
      final b = PatternDoc.parse(m.source).doc!;
      final x = a.sortedNotes, y = b.sortedNotes;
      expect(y.length, x.length, reason: where);
      for (var i = 0; i < x.length; i++) {
        // A rate or fade-in of vibrato without depth is the one thing text can't say again; it plays nothing.
        expect(y[i].sameAs(x[i]), isTrue, reason: '$where note $i: ${x[i]} became ${y[i]}');
      }
      expect(b.header, a.header, reason: where);
      expect(b.commentLayout().top, a.commentLayout().top, reason: where);
      expect(b.commentLayout().tail, a.commentLayout().tail, reason: where);
      // Opening the v5 file again gives the same text and saving it the same MIDI.
      expect(clipTextFromMidi(clipMidiFromText(m.source)!), m.source, reason: where);
    }
  });

  final lib = Platform.environment['CAW_LIB'];
  test('every pattern renders bit for bit the same before and after the migration', () async {
    final dir = await Directory.systemTemp.createTemp('caw-migrate');
    Future<List<int>> render(ProjectDoc p, String name) async {
      final out = '${dir.path}/$name.wav';
      final job = RenderJob.start(RenderRequest(
          projectJson: p.toEngineJson(playableComponents: {'org.caw.synth.flagship'}), kind: ExportKind.free, seconds: 4,
          outPath: out));
      expect(await job.result, isNull);
      return File(out).readAsBytes();
    }

    var sounding = 0;
    for (final (i, (where, old)) in cases.indexed) {
      final before = await render(_project(old), 'b$i');
      final after = await render(_migrated(old), 'a$i');
      expect(after.length, before.length, reason: where);
      expect(after, before, reason: '$where renders differently after the migration');
      if (before.skip(1000).any((b) => b != 0)) sounding++;
    }
    expect(sounding, greaterThan(cases.length ~/ 2), reason: 'the renders make sound');
    await dir.delete(recursive: true);
  }, skip: lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null, timeout: const Timeout(Duration(minutes: 10)));
}
