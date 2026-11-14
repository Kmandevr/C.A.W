// A fake plug-in benchmark backend for tests: answers each request with a fixture's JSON (or a held job to cancel).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/component_bench.dart';

Map<String, dynamic> benchFixture(String name) =>
    jsonDecode(File('test/fixtures/component_bench_$name.json').readAsStringSync()) as Map<String, dynamic>;

class FakeComponentBench implements ComponentBenchBackend {
  FakeComponentBench({this.json, this.hold = false});

  /// The answer; by default the instrument fixture for an instrument, else the effect one.
  final Map<String, dynamic>? json;

  /// Keeps each job running until it is cancelled.
  final bool hold;
  final List<ComponentBenchRequest> started = [];

  @override
  ComponentBenchJob start(ComponentBenchRequest request) {
    started.add(request);
    return _Job(json ?? benchFixture(request.instrument ? 'instrument' : 'effect'), hold);
  }
}

class _Job implements ComponentBenchJob {
  _Job(Map<String, dynamic> json, bool hold) {
    if (!hold) _done.complete(json);
  }
  final _done = Completer<Map<String, dynamic>>();
  @override
  double get fraction => 0.4;
  @override
  void cancel() {
    if (!_done.isCompleted) _done.complete({'ok': false, 'stop_reason': 'cancelled', 'error': 'cancelled'});
  }

  @override
  Future<Map<String, dynamic>> get result => _done.future;
}
