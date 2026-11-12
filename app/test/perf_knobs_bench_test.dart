// Benchmarks a knob step in every built-in's editor (beta plan B4.5): widgets rebuilt per live step of each of its
// first six knobs, with motion off. The knob and the visuals that draw its value rebuild; the page around them
// doesn't (param_watch.dart). Prints a BENCH line per device; the counts are asserted so they can't grow back.
import 'package:caw/model/device_display.dart';
import 'package:caw/ui/devices/device_controls.dart';
import 'package:caw/ui/devices/kit/hero.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'perf_util.dart';

void main() {
  for (final info in builtinInfos()) {
    final id = info.id;
    testWidgets('$id: a knob step rebuilds the knob and its visuals', (tester) async {
      DeviceDisplaySource.current = FakeDisplay();
      MotionClock.hold = true;
      Motion.setting = MotionLevel.off;
      addTearDown(() { MotionClock.hold = false; Motion.setting = MotionLevel.full; });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = stateWith(id, make: PreviewState.new);
      // eq.dj overflows a 390 dp phone already (not this bench's concern); the test's own handler comes back at the end.
      final onError = FlutterError.onError;
      FlutterError.onError = (d) { if (!'${d.exception}'.contains('overflowed')) onError?.call(d); };
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) { ctx = c; return const SizedBox.expand(); }))));
      openDevice(ctx, s, id);
      for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 20)); }
      final knobs = tester.widgetList<DeviceKnob>(find.byType(DeviceKnob)).toList();
      final t = targetOf(s, id);
      final out = <String>[];
      for (final k in knobs.take(6)) {
        final p = t.param(k.paramId);
        if (p == null) continue;
        final c = await countFrames(tester, 4, onFrame: (i) async => t.setLive(p.id, p.min + (p.max - p.min) * (i + 1) / 5));
        t.commit();
        await tester.pump(const Duration(seconds: 1));
        out.add('${p.id}=${c.builds ~/ 4}');
      }
      // ignore: avoid_print
      print('BENCH $id knob step builds: ${out.join(' ')}');
      // A rack's knobs rebuild its page (its parameters choose its children); every other device's rebuild the
      // knob and its visuals (EQ's: the curve, the band strip, the readout and the band's controls). Ceilings about
      // 10 % over the counts in docs/performance.md (exact in the test VM).
      final ceiling = _ceilings[id] ?? 80;
      for (final o in out) {
        expect(int.parse(o.split('=').last), lessThanOrEqualTo(ceiling), reason: '$id $o');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      FlutterError.onError = onError;
      s.dispose();
    });
  }
}

/// The devices whose knob step rebuilds more than the 80 widgets most do (docs/performance.md, a knob step).
const _ceilings = {
  'org.caw.eq': 190, 'org.caw.ducker': 126, 'org.caw.bitcrush': 110,
  'org.caw.rack.fx': 1120, 'org.caw.rack.multiband': 670,
};
