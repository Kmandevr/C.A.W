// Engine integration over dart:ffi: needs CAW_LIB pointing at a desktop build of the engine library (CI sets it).
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('templates, check, project sync and render work through the C API', () async {
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
}
