// Engine integration over dart:ffi: needs CAW_LIB pointing at a desktop build of the engine library (CI sets it).
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

  test('native component loading requires an explicit trust choice', () async {
    final engine = Engine.create();
    late final NativeComponentLoadResult blocked;
    try {
      blocked = await engine.loadNativeComponent(
        artifactPath: '/not/opened/while/blocked.so',
        expectedComponentId: 'org.caw.tests.blocked',
        trust: NativeComponentTrust.blocked,
      );
    } catch (error, stack) {
      fail('Blocked native component load threw: $error\\n$stack');
    }
    expect(blocked.ok, isFalse);
    expect(blocked.error, contains('blocked'), reason: 'Blocked result: ${blocked.error}');
    // A blocked component is never listed; only the engine's built-in Library components are.
    final listed = await engine.nativeComponents();
    expect(listed.where((c) => c.id == 'org.caw.tests.blocked'), isEmpty);
    expect(listed.every((c) => c.builtin), isTrue);

    final isolated = await engine.loadNativeComponent(
      artifactPath: '/not/opened/while/isolated.so',
      expectedComponentId: 'org.caw.tests.isolated',
      trust: NativeComponentTrust.isolated,
    );
    expect(isolated.ok, isFalse);
    expect(isolated.error, contains('Isolated'), reason: 'Isolated result: ${isolated.error}');

    final pending = engine.loadNativeComponent(
      artifactPath: '/not/opened/while/dispose-is-pending.so',
      expectedComponentId: 'org.caw.tests.dispose',
      trust: NativeComponentTrust.blocked,
    );
    engine.dispose();
    final afterDisposeRequest = await pending;
    expect(afterDisposeRequest.ok, isFalse);
    expect(afterDisposeRequest.error, contains('blocked'), reason: 'Disposed-engine result: ${afterDisposeRequest.error}');
  }, skip: skip);

  test('a project cannot use a native component before an explicit trust load', () async {
    final engine = Engine.create();
    await expectLater(
      engine.setProject('{"caw_project":1,"master_components":["org.caw.tests.not-loaded"]}'),
      throwsA(predicate((error) => error is StateError && error.message.contains('not loaded'))),
    );
    engine.dispose();
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
    final midiOut = '${dir.path}/acid.mid';
    final midiSource = line.source;
    final midiPath = midiOut;
    const midiBpm = 140.0;
    const midiBeatsPerBar = 4;
    final midiError = await Isolate.run(() => Engine.exportPattern(midiSource, midiPath, bpm: midiBpm, beatsPerBar: midiBeatsPerBar));
    expect(midiError, isNull);
    final midiBytes = await File(midiOut).readAsBytes();
    expect(String.fromCharCodes(midiBytes.sublist(0, 4)), 'MThd');
    final out = '${dir.path}/acid.wav';
    final job = RenderJob.start(RenderRequest(projectJson: p.toEngineJson(), kind: ExportKind.loop, outPath: out));
    expect(await job.result, isNull);
    expect(await File(out).length(), greaterThan(100000));
    await dir.delete(recursive: true);
  }, skip: skip);

  test('a C++ instrument plays a track\'s notes, takes knob moves live and exports', () async {
    final e = Engine.create();
    final list = await e.nativeComponents();
    final synth = list.firstWhere((c) => c.id == 'org.caw.synth.basic');
    expect(synth.builtin, isTrue);
    expect(synth.role, 'instrument');
    expect(synth.isInstrument, isTrue);
    expect(list.where((c) => c.id == 'org.caw.chorus').single.isInstrument, isFalse);
    final p = ProjectDoc(id: 'p', name: 'T', modules: [
      ModuleDoc(id: 'n', name: 'Line', source: '---\nkind: pattern\nname: Line\nlength: 16\n---\n0 C3 4 1\n4 G3 4 0.8\n'),
    ], layers: [
      LayerDoc(id: 'l', name: 'Synth', color: 0, patternId: 'n')..setInstrument('org.caw.synth.basic'),
    ]);
    p.layers.single.instrument!.params['cutoff'] = 900;
    final result = await e.setProject(p.toEngineJson(playableComponents: {'org.caw.synth.basic'}));
    expect(result['n']!.ok, isTrue);
    expect(e.setComponentParam('l', ProjectDoc.instrumentIndex, 'cutoff', 1500), isTrue);
    expect(e.setComponentParam('l', 0, 'cutoff', 1500), isFalse, reason: 'index 0 names the inserts, which are empty');
    expect(e.setComponentBypass('l', ProjectDoc.instrumentIndex, false), isTrue);
    expect(e.componentStates('l').keys, contains(ProjectDoc.instrumentIndex));
    // Display data (#173): the basic synth publishes none; there is no insert 0.
    final shown = Float32List(16);
    expect(e.componentDisplay('l', ProjectDoc.instrumentIndex, shown), 0);
    expect(e.componentDisplay('l', 0, shown), -1);
    e.dispose();
    final dir = await Directory.systemTemp.createTemp('caw');
    final out = '${dir.path}/synth.wav';
    final job = RenderJob.start(RenderRequest(projectJson: p.toEngineJson(), kind: ExportKind.loop, outPath: out));
    expect(await job.result, isNull);
    final bytes = await File(out).readAsBytes();
    expect(bytes.length, greaterThan(100000));
    // Not silent: some 32-bit or 16-bit sample past the header is non-zero.
    expect(bytes.skip(1000).any((b) => b != 0), isTrue);
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
