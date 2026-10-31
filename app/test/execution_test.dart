// Integration tests for the app's native hardware policy and workload scheduler.
import 'dart:async';
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
    expect(hardware.memoryBudgetMiB, inInclusiveRange(64, 8192));

    final audition = EngineExecutionPolicy.plan(workload: EngineWorkload.interactiveAudition);
    expect(audition.workerThreads, 1);
    expect(audition.maxConcurrentJobs, 1);
    expect(audition.latencySensitive, isTrue);
    expect(audition.yieldToForeground, isTrue);

    final offline = EngineExecutionPolicy.plan(workload: EngineWorkload.offlineRender);
    final hot = EngineExecutionPolicy.plan(
      workload: EngineWorkload.offlineRender,
      pressure: EnginePressure.thermalHot,
    );
    expect(offline.workerThreads, greaterThanOrEqualTo(1));
    expect(offline.maxConcurrentJobs, offline.workerThreads);
    expect(offline.preferredBatchFrames, 4096);
    expect(hot.workerThreads, 1);
    expect(hot.yieldToForeground, isTrue);

    final idle = EngineExecutionPolicy.plan(workload: EngineWorkload.idle);
    expect(idle.workerThreads, 0);
    expect(idle.maxConcurrentJobs, 0);
    expect(idle.preferredBatchFrames, 0);
    expect(idle.allowGpu, isFalse);
  }, skip: skip);

  test('interactive engine work stays serialized by the native plan', () async {
    final scheduler = EngineWorkScheduler(maxPending: 4);
    final gate = Completer<void>();
    final started = <String>[];

    final first = scheduler.run(
      workload: EngineWorkload.interactiveAudition,
      task: () async {
        started.add('first');
        await gate.future;
        return 1;
      },
    );
    final second = scheduler.run(
      workload: EngineWorkload.interactiveAudition,
      task: () async {
        started.add('second');
        return 2;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(started, ['first']);
    gate.complete();
    expect(await first, 1);
    expect(await second, 2);
    expect(started, ['first', 'second']);
    expect(scheduler.active, 0);
    expect(scheduler.queued, 0);
  }, skip: skip);

  test('module checks can run as scheduled preview work', () async {
    final checked = await Engine.checkAsync('sin(t)');
    expect(checked.ok, isTrue);
  }, skip: skip);
}
