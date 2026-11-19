// Per-slot cost through the real engine (API 44; needs CAW_LIB): caw_engine_component_cost's symbol, CawSlotCost's
// layout over dart:ffi, the measuring start, the latency now and the armed badge, through the bindings and Engine.
import 'dart:ffi';
import 'dart:io';

import 'package:caw/engine/bindings.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

String _project(bool armed) => '{"caw_project":1,"bpm":120,"loop_bars":1,"master":1,"layers":[{"id":"t","name":"T",'
    '"volume":1,"input":{"channel":0,"channels":1,"monitor":"auto","armed":$armed},"components":['
    '{"id":"org.caw.eq","params":{"variant":4,"b4_gain":6}},{"id":"org.caw.utility"}]}]}';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('a slot\'s cost: unmeasured first, then a share; the latency and the armed badge follow the track', () {
    final b = Bindings.instance;
    final e = b.create(48000);
    final layer = 't'.toNativeUtf8();
    final left = calloc<Float>(256), right = calloc<Float>(256);
    final cost = calloc<CawSlotCostStruct>();
    void set(bool armed) {
      final p = _project(armed).toNativeUtf8();
      final r = b.setProject(e, p);
      expect(r.toDartString(), contains('"ok":true'));
      b.free(r);
      calloc.free(p);
    }

    try {
      expect(sizeOf<CawSlotCostStruct>(), 20);
      set(false);
      cost.ref.structSize = sizeOf<CawSlotCostStruct>();
      expect(b.componentCost(e, layer, 0, cost), 1);
      expect(cost.ref.cpuShare, -1);  // the first read starts the measuring
      expect(cost.ref.latencyFrames, 2304);  // Linear at Normal
      expect(cost.ref.latencyMs, closeTo(48, 0.01));
      expect(cost.ref.armed, 0);
      b.play(e);
      for (var k = 0; k < 48000 ~/ 256; k++) {
        b.process(e, left, right, 256);
      }
      expect(b.componentCost(e, layer, 0, cost), 1);
      expect(cost.ref.cpuShare, inInclusiveRange(0, 1));
      expect(b.componentCost(e, layer, 9, cost), -1);
      set(true);  // armed with monitoring on auto: the minimum-phase bands, no delay, the badge
      expect(b.componentCost(e, layer, 0, cost), 1);
      expect(cost.ref.latencyFrames, 0);
      expect(cost.ref.armed, 1);
      expect(b.componentCost(e, layer, 1, cost), 1);
      expect(cost.ref.armed, 0);  // the utility has nothing to arm
    } finally {
      b.destroy(e);
      calloc.free(layer);
      calloc.free(left);
      calloc.free(right);
      calloc.free(cost);
    }
  }, skip: skip);
}
