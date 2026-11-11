// The Build tools' real engine calls over dart:ffi (needs CAW_LIB): a testing-suite run and a sample pack with progress and cancel.
import 'dart:io';

import 'package:caw/engine/build_tools.dart';
import 'package:caw/engine/engine.dart' show NativeComponentTrust;
import 'package:caw/ui/cpp/test_suite_screen.dart' show TestSuiteResult;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('the testing suite measures a built-in effect, with a null test against bypass and a WAV for the scope', () async {
    final dir = await Directory.systemTemp.createTemp('caw-test-');
    addTearDown(() => dir.delete(recursive: true));
    final r = await runComponentTest({
      'component': {'id': 'org.caw.distortion', 'params': {'drive': 8}},
      'signal': {'type': 'sine', 'frequency': 1000, 'seconds': 0.5},
      'bypass': true,
      'write_wav': 'output.wav',
    }, outputDir: dir.path);
    expect(r['ok'], isTrue, reason: '${r['error']}');
    expect(r['bypass']['depth_db'], isA<num>());
    expect(File('${dir.path}/output.wav').existsSync(), isTrue);
    final parsed = TestSuiteResult.fromJson(r);
    expect(parsed.cards, isNotEmpty);
    expect(parsed.spectrum, isNotEmpty);
    // A request may not choose its own trust.
    final refused = await runComponentTest({
      'component': {'id': 'x.y', 'library': '/nowhere.so', 'trust': 'trusted'},
    }, trust: NativeComponentTrust.trusted);
    expect(refused['ok'], isFalse);
  }, skip: skip);

  test('a sample pack renders named WAVs and an SFZ, reports progress, and stops when cancelled', () async {
    final dir = await Directory.systemTemp.createTemp('caw-pack-');
    addTearDown(() => dir.delete(recursive: true));
    final job = SamplePackJob.start({
      'instrument': 'org.caw.synth.flagship',
      'output_dir': dir.path,
      'name': 'lead',
      'notes': [48, 60],
      'velocities': [100],
      'hold_seconds': 0.2,
      'max_seconds': 2,
      'sfz': true,
    });
    final r = await job.result;
    expect(r['ok'], isTrue, reason: '${r['error']}');
    expect(job.progress, 1);
    expect([for (final f in r['files'] as List) f['file']], ['lead_C3_100.wav', 'lead_C4_100.wav']);
    expect(File('${dir.path}/lead.sfz').existsSync(), isTrue);

    final big = SamplePackJob.start({
      'instrument': 'org.caw.synth.flagship',
      'output_dir': '${dir.path}/big',
      'notes': {'from': 24, 'to': 96, 'step': 1},
      'hold_seconds': 2,
      'max_files': 256,
    });
    big.cancel();
    final c = await big.result;
    expect(c['ok'], isFalse);
  }, skip: skip);
}
