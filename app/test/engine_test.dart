// Engine integration over dart:ffi: needs CAW_LIB pointing at a desktop build of the engine library (CI sets it).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('templates, check, native project jobs and native render jobs work through the C API', () async {
    final templates = Engine.templates();
    expect(templates.length, greaterThanOrEqualTo(7));
    final kick = templates.firstWhere((t) => t.file == 'kick.caw');
    final info = Engine.check(kick.source);
    expect(info.ok, isTrue);
    expect(info.params.map((p) => p.name), containsAll(['punch', 'decay']));
    final punch = info.params.firstWhere((p) => p.name == 'punch');
    expect(punch.tip, contains('pitch drops'));
    expect(punch.header, 'Kick');
    final rich = Engine.check('global swing = 0.1 in 0..0.5\nparam wave = saw in [sine, saw]\nparam on1 = on\nexport let x = 1\nwave');
    expect(rich.ok, isTrue);
    expect(rich.params[0].global, isTrue);
    expect(rich.params[1].kind, ParamKind.choice);
    expect(rich.params[1].choices, ['sine', 'saw']);
    expect(rich.params[2].kind, ParamKind.toggle);
    expect(rich.exports.single.name, 'x');
    final bad = Engine.check('t >>');
    expect(bad.ok, isFalse);
    expect(bad.line, 1);

    final e = Engine.create();
    final p = ProjectDoc(id: 'p', name: 'T', modules: [
      ModuleDoc(id: 'k', name: 'Kick', source: kick.source),
      ModuleDoc(id: 'x', name: 'Broken', source: 'sin('),
    ], layers: [
      LayerDoc(id: 'l', name: 'Kick', color: 0, generatorId: 'k', lengthSteps: 4),
    ]);
    final result = await e.setProject(p.toEngineJson());
    expect(result['k']!.ok, isTrue);
    expect(result['k']!.ref, 'kick');
    expect(result['k']!.exports.single.name, 'env');
    expect(result['x']!.ok, isFalse);
    expect(result['x']!.error, contains('line 1'));
    e.play();
    final m = e.meters();
    expect(m.loopLength, greaterThan(0));
    e.dispose();

    final dir = await Directory.systemTemp.createTemp('caw');
    final out = '${dir.path}/loop.wav';
    p.modules.removeLast();
    final job = RenderJob.start(RenderRequest(projectJson: p.toEngineJson(), kind: ExportKind.loop, outPath: out));
    expect(await job.result, isNull);
    final bytes = await File(out).readAsBytes();
    // 4 bars at 140 BPM, 48 kHz, stereo 24-bit: 329143 frames * 6 bytes plus headers.
    expect(bytes.length, greaterThan(329143 * 6));
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    await dir.delete(recursive: true);
  }, skip: skip);

  test('a generator plays the notes of a pattern', () async {
    final templates = Engine.templates();
    final synth = templates.firstWhere((t) => t.file == 'acid-synth.caw');
    final line = templates.firstWhere((t) => t.file == 'acid-line.caw');
    final info = Engine.check(line.source);
    expect(info.ok, isTrue);
    expect(info.isPattern, isTrue);
    expect(info.noteCount, 11);
    expect(Engine.check('---\nkind: pattern\n---\n0 H2 1').line, 4);
    final p = ProjectDoc(id: 'p', name: 'T', modules: [
      ModuleDoc(id: 's', name: 'Acid', source: synth.source),
      ModuleDoc(id: 'n', name: 'Line', source: line.source),
    ], layers: [
      LayerDoc(id: 'l', name: 'Acid', color: 0, generatorId: 's', patternId: 'n'),
    ]);
    final e = Engine.create();
    final result = await e.setProject(p.toEngineJson());
    expect(result['n']!.ok, isTrue);
    expect(result['s']!.warnings, isEmpty);
    e.dispose();
    final dir = await Directory.systemTemp.createTemp('caw');
    final out = '${dir.path}/acid.wav';
    final job = RenderJob.start(RenderRequest(projectJson: p.toEngineJson(), kind: ExportKind.loop, outPath: out));
    expect(await job.result, isNull);
    expect(await File(out).length(), greaterThan(100000));
    await dir.delete(recursive: true);
  }, skip: skip);

  test('the function library and library modules come through the C API', () {
    final lib = Library.builtIn;
    final adsr = lib.find('env.adsr')!;
    expect(adsr.category, 'Envelopes');
    expect(adsr.args.first.name, 'gate');
    expect(lib.find('drum.kick'), isNotNull);
    expect(lib.constants, contains('scale.minor'));
    final mine = Engine.check('---\nkind: library\nnamespace: mine\nname: Mine\n---\n/// Doubles.\n/// x: anything\nfn twice(x) = x * 2');
    expect(mine.ok, isTrue);
    expect(mine.isLibrary, isTrue);
    expect(mine.functions.single.name, 'mine.twice');
    expect(lib.withProject([mine]).find('mine.twice')!.category, 'Mine');
  }, skip: skip);
}
