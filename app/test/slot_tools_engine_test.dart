// Per-slot auto gain and output meters through the real engine (API 39; needs CAW_LIB): the bindings' symbols and
// CawSlotMeter's layout over dart:ffi.
import 'dart:ffi';
import 'dart:io';

import 'package:caw/engine/bindings.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  test('a +6 dB utility with auto gain on is trimmed by about -6 dB, and its slot meter reads', () {
    final b = Bindings.instance;
    final e = b.create(48000);
    final project = ('{"bpm":120,"loop_bars":4,"master":1,"layers":[{"id":"t","volume":1,'
            '"instrument":{"id":"org.caw.test.osc","params":{"shape":3,"level":0.2}},'
            '"components":[{"id":"org.caw.utility","params":{"gain":6},"auto_gain":true},'
            '{"id":"org.caw.utility","params":{"gain":20}}]}]}')
        .toNativeUtf8();
    final layer = 't'.toNativeUtf8();
    final left = calloc<Float>(256), right = calloc<Float>(256);
    final trim = calloc<Float>();
    final meter = calloc<CawSlotMeterStruct>();
    try {
      final r = b.setProject(e, project);
      expect(r.toDartString(), contains('"ok":true'));
      b.free(r);
      b.play(e);
      for (var k = 0; k < 48000 * 8 ~/ 256; k++) {
        b.process(e, left, right, 256);
      }
      expect(b.componentAutoGain(e, layer, 0, trim), 1);
      expect(trim.value, closeTo(-6, 0.2));
      expect(b.componentAutoGain(e, layer, 1, trim), 1);
      expect(trim.value, 0);  // off
      expect(b.componentAutoGain(e, layer, 7, trim), -1);
      expect(b.setComponentAutoGain(e, layer, 0, 0), 1);
      expect(b.setComponentAutoGain(e, layer, 7, 1), 0);
      expect(b.componentMeter(e, layer, 1, meter), 1);
      expect(meter.ref.peakL, greaterThan(1));  // +20 dB on 0.2 noise: over full scale
      expect(meter.ref.peakR, greaterThan(1));
      expect(meter.ref.clipped, 1);
      expect(b.componentMeter(e, layer, 1, meter), 1);  // read: reset
      expect(meter.ref.peakL, 0);
      expect(meter.ref.clipped, 0);
      expect(b.componentMeter(e, layer, 9, meter), -1);
    } finally {
      b.destroy(e);
      for (final p in [project, layer]) {
        calloc.free(p);
      }
      calloc.free(left);
      calloc.free(right);
      calloc.free(trim);
      calloc.free(meter);
    }
  }, skip: skip);
}
