// Integration tests for the app's native hardware policy and workload scheduler.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/engine/execution.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('hardware profile and workload plans come from the native engine', () {
    final hardware = EngineExecutionPolicy.hardwareProfile;
    expect(hardware.logicalCores, inInclusiveRange(1, 256));
    expect(hardware.memoryBudgetMiB, inInclusiveRange(0, 8192));

    final audition = EngineExecutionPolicy.plan(workload: EngineWorkload.interactiveAudition);
    expect(audition.workerThreads, 1);
    expect(audition.maxConcurrentJobs, 1);
    expect(audition.latencySensitive, isTrue);
    expect(audition.yieldToForeground, isTrue);

    final unknown = EngineExecutionPolicy.plan(workload: EngineWorkload.offlineRender, allowGpu: true);
    final offline = EngineExecutionPolicy.plan(
      workload: EngineWorkload.offlineRender,
      pressure: EnginePressure.normal,
    );
    final hot = EngineExecutionPolicy.plan(
      workload: EngineWorkload.offlineRender,
      pressure: EnginePressure.thermalHot,
    );
    expect(unknown.workerThreads, greaterThanOrEqualTo(1));
    expect(unknown.yieldToForeground, isTrue);
    expect(unknown.allowGpu, isFalse);
    expect(offline.workerThreads, greaterThanOrEqualTo(unknown.workerThreads));
    expect(offline.maxConcurrentJobs, offline.workerThreads);
    expect(offline.preferredBatchFrames, 4096);
    expect(hot.workerThreads, 1);
    expect(hot.yieldToForeground, isTrue);

    EngineExecutionPolicy.updateRuntimeSignals(
      pressure: EnginePressure.thermalCritical,
      foreground: true,
      audioActive: true,
    );
    final busyPreview = EngineExecutionPolicy.plan(workload: EngineWorkload.interactivePreview);
    expect(busyPreview.workerThreads, 1);
    expect(busyPreview.yieldToForeground, isTrue);
    EngineExecutionPolicy.updateRuntimeSignals(
      pressure: EnginePressure.unknown,
      foreground: true,
      audioActive: false,
    );

    final idle = EngineExecutionPolicy.plan(workload: EngineWorkload.idle);
    expect(idle.workerThreads, 0);
    expect(idle.maxConcurrentJobs, 0);
    expect(idle.preferredBatchFrames, 0);
    expect(idle.allowGpu, isFalse);
  }, skip: skip);

  test('native worker pool runs concurrent renders', () async {
    final pool = NativeEngineWorkPool.shared;
    final plan = pool.apply(workload: EngineWorkload.interactivePreview);
    expect(plan.workerThreads, greaterThanOrEqualTo(1));
    expect(plan.maxConcurrentJobs, greaterThanOrEqualTo(1));

    final dir = await Directory.systemTemp.createTemp('caw');
    const project = '{"caw_project":1,"layers":[{"id":"t","instrument":{"id":"org.caw.test.osc"}}]}';
    final jobs = [
      for (final name in ['a', 'b'])
        RenderJob.start(RenderRequest(projectJson: project, kind: ExportKind.free, outPath: '${dir.path}/$name.wav', seconds: 0.2)),
    ];
    final results = await Future.wait([for (final j in jobs) j.result]);
    expect(results, [null, null]);
    expect(File('${dir.path}/a.wav').existsSync() && File('${dir.path}/b.wav').existsSync(), isTrue);
    await dir.delete(recursive: true);
  }, skip: skip);

  test('project updates run as native jobs and report each pattern', () async {
    final e = Engine.create();
    final result = await e.setProject('{"caw_project":1,"modules":[{"id":"p","source":"---\\nkind: pattern\\n---\\n0 C4 1 1\\n"}]}');
    expect(result['p']!.ok, isTrue);
    expect(result['p']!.noteCount, 1);
    e.dispose();
  }, skip: skip);
}
