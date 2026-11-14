// The plug-in benchmark's engine binding (API 30, #197): a built-in timed through the worker pool (needs CAW_LIB).
import 'dart:io';

import 'package:caw/engine/component_bench.dart';
import 'package:caw/model/component_bench.dart';
import 'package:caw/model/component_bench_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('with the engine: a built-in benchmarked, its result parsed (needs CAW_LIB)', () async {
    const backend = EngineComponentBench(seconds: 0.1);
    final job = backend.start(const ComponentBenchRequest(componentId: 'org.caw.chorus', instrument: false, name: 'Chorus'));
    final json = await job.result;
    expect(json['ok'], isTrue, reason: '${json['error']}');
    expect(json['tool'], 'caw_component_bench');
    expect((json['component'] as Map)['kind'], 'effect');
    expect(job.fraction, 1.0);
    final ids = [for (final c in json['checks'] as List) (c as Map)['id']];
    expect(ids, containsAll(['allocations', 'denormals', 'block_size_scaling', 'sample_rate_scaling', 'param_change_cost', 'silence_cost']));
    final parsed = ComponentBenchResult.parse(json);
    expect(parsed.error, isNull);

    // Cancelled: the job says so.
    final slow = const EngineComponentBench(seconds: 10)
        .start(const ComponentBenchRequest(componentId: 'org.caw.reverb.pro', instrument: false));
    slow.cancel();
    final cancelled = await slow.result;
    expect(cancelled['ok'] == true || cancelled['stop_reason'] == 'cancelled', isTrue);

    // Not a component the engine knows: refused with a reason.
    final unknown = await backend.start(const ComponentBenchRequest(componentId: 'org.example.none', instrument: false)).result;
    expect(unknown['ok'], isFalse);
    expect('${unknown['error']}', isNotEmpty);
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true ? 'set CAW_LIB to the built engine library' : null);
}
