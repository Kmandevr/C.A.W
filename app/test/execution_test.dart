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

  test('native worker pool runs concurrent source checks and returns results', () async {
    final pool = NativeEngineWorkPool.shared;
    final plan = pool.apply(workload: EngineWorkload.interactivePreview);
    expect(plan.workerThreads, greaterThanOrEqualTo(1));
    expect(plan.maxConcurrentJobs, greaterThanOrEqualTo(1));

    final first = pool.submitCheck('sin(t)').result;
    final second = pool.submitCheck('square(t)').result;
    final results = await Future.wait([first, second]);
    expect(results.every((result) => result != null && result.contains('"ok":true')), isTrue);
  }, skip: skip);

  test('module checks run as native preview jobs', () async {
    final checked = await Engine.checkAsync('sin(t)');
    expect(checked.ok, isTrue);
  }, skip: skip);
}
