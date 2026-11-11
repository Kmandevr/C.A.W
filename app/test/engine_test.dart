// Engine integration over dart:ffi: needs CAW_LIB pointing at a desktop build of the engine library (CI sets it).
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/pattern_templates.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('project sync, pattern results and render work through the C API', () async {
    final kick = PatternTemplate('kick', '---\nkind: pattern\nname: Kick\nlength: 4\n---\n0 C2 1 1\n');
    final e = Engine.create();
    final p = ProjectDoc(id: 'p', name: 'T', modules: [
      ModuleDoc(id: 'k', name: 'Kick', source: kick.source),
      ModuleDoc(id: 'x', name: 'Broken', source: 'sin('),
    ], layers: [
      LayerDoc(id: 'l', name: 'Kick', color: 0, instrument: ComponentUseDoc('org.caw.drums'), patternId: 'k'),
    ]);
    final result = await e.setProject(p.toEngineJson());
    expect(result['k']!.ok, isTrue);
    expect(result['k']!.isPattern, isTrue);
    expect(result['k']!.name, 'Kick');
    expect(result['x']!.ok, isFalse, reason: 'not a pattern: the .caw sound modules are gone (#160)');
    expect(result['x']!.line, 1);
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

  test('device MIDI (API 15): bytes and UMP words reach a track, an unknown track takes none, nothing drops', () async {
    final e = Engine.create();
    final p = ProjectDoc(id: 'p', name: 'T', layers: [LayerDoc(id: 'l', name: 'Keys', color: 0)])
      ..layers.first.instrument = ComponentUseDoc('org.caw.synth.flagship', {});
    await e.setProject(p.toEngineJson());
    final now = e.midiClockNs;
    expect(now, greaterThan(0));
    expect(e.midiBytes('l', [0x90, 60, 100, 0xA0, 60, 50, 0xC0, 3], now), 3);
    expect(e.midiUmp('l', [0x00200000, 0x40903C00, 0xFFFF0000], now), 1, reason: 'the JR timestamp is skipped');
    expect(e.midiBytes('nope', [0x90, 60, 100], 0), 0);
    e.setMidiOptions(mpe: true, bendRange: 12);
    e.midiRelease();
    expect(e.midiDropped, 0);
    expect(e.positionAt(now), -1, reason: 'stopped');
    e.dispose();
  }, skip: skip);

  test('an instrument plays the notes of a pattern, and a broken pattern says where', () async {
    final line = patternTemplates.firstWhere((t) => t.file == 'acid-line.caw');
    final p = ProjectDoc(id: 'p', name: 'T', modules: [
      ModuleDoc(id: 'n', name: 'Line', source: line.source),
      ModuleDoc(id: 'b', name: 'Broken', source: '---\nkind: pattern\n---\n0 H2 1'),
    ], layers: [
      LayerDoc(id: 'l', name: 'Acid', color: 0, instrument: ComponentUseDoc('org.caw.synth.flagship'), patternId: 'n'),
    ]);
    final e = Engine.create();
    final result = await e.setProject(p.toEngineJson());
    expect(result['n']!.ok, isTrue);
    expect(result['n']!.isPattern, isTrue);
    expect(result['n']!.noteCount, 11);
    expect(result['b']!.ok, isFalse);
    expect(result['b']!.line, 4);
    e.dispose();
    p.modules.removeLast();
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
    final synth = list.firstWhere((c) => c.id == 'org.caw.synth.flagship');
    expect(synth.builtin, isTrue);
    expect(synth.role, 'instrument');
    expect(synth.isInstrument, isTrue);
    expect(list.where((c) => c.id == 'org.caw.chorus').single.isInstrument, isFalse);
    final p = ProjectDoc(id: 'p', name: 'T', modules: [
      ModuleDoc(id: 'n', name: 'Line', source: '---\nkind: pattern\nname: Line\nlength: 16\n---\n0 C3 4 1\n4 G3 4 0.8\n'),
    ], layers: [
      LayerDoc(id: 'l', name: 'Synth', color: 0, patternId: 'n')..setInstrument('org.caw.synth.flagship'),
    ]);
    p.layers.single.instrument!.params['flt1_cutoff'] = 900;
    final result = await e.setProject(p.toEngineJson(playableComponents: {'org.caw.synth.flagship'}));
    expect(result['n']!.ok, isTrue);
    expect(e.setComponentParam('l', ProjectDoc.instrumentIndex, 'flt1_cutoff', 1500), isTrue);
    expect(e.setComponentParam('l', 0, 'flt1_cutoff', 1500), isFalse, reason: 'index 0 names the inserts, which are empty');
    expect(e.setComponentBypass('l', ProjectDoc.instrumentIndex, false), isTrue);
    expect(e.componentStates('l').keys, contains(ProjectDoc.instrumentIndex));
    // Display data (#173): Flagship publishes none; there is no insert 0.
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
}
