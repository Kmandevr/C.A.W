// Volume faders like REAPER's: a dB taper over the linear gain, dB labels and typing, fine drags, double-tap 0 dB.
import 'package:caw/ui/volume_fader.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the taper: -inf at the bottom, 0 dB at the top while the engine stops at 0 dB, dB in the log of travel', () {
    expect(VolumeTaper.gain(0), 0);
    expect(VolumeTaper.gain(1), 1);
    expect(VolumeTaper.position(1), 1);
    expect(VolumeTaper.position(2), 1, reason: 'above the engine\'s maximum it stays at the top');
    // On REAPER's full travel 0 dB sits at three quarters and +12 dB at the top.
    expect(VolumeTaper.top, closeTo(0.75, 1e-9));
    // Half of REAPER's full travel (two thirds of this one) is about -17 dB; every value comes back.
    expect(VolumeTaper.db(VolumeTaper.gain(2 / 3)), closeTo(-16.9, 0.1));
    for (final g in [0.001, 0.1, 0.5, 0.8, 1.0]) {
      expect(VolumeTaper.gain(VolumeTaper.position(g)), closeTo(g, 1e-9));
    }
  });

  test('labels and typed levels in dB', () {
    expect(VolumeTaper.label(1), '0.0 dB');
    expect(VolumeTaper.label(0.5), '-6.0 dB');
    expect(VolumeTaper.label(0), '-inf dB');
    expect(VolumeTaper.parse('-6'), closeTo(0.501, 0.001));
    expect(VolumeTaper.parse('-12 dB'), closeTo(0.251, 0.001));
    expect(VolumeTaper.parse('-inf'), 0);
    expect(VolumeTaper.parse('+6'), 1, reason: 'clamped to the engine\'s 0 dB');
    expect(VolumeTaper.parse('loud'), isNull);
  });

  testWidgets('a drag follows the travel, Shift makes it fine, a double-tap is 0 dB', (tester) async {
    var gain = 0.25;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 40, height: 216,
      child: StatefulBuilder(builder: (context, setState) => VolumeFader(key: const ValueKey('f'), value: gain,
        label: 'Level', onChanged: (v) => setState(() => gain = v))))))));
    final f = find.byKey(const ValueKey('f'));
    final p0 = VolumeTaper.position(gain);
    // 200 px of track: 40 px up is a fifth of the travel (the slop is taken from where the finger went down).
    final g = await tester.startGesture(tester.getCenter(f));
    await g.moveBy(const Offset(0, -20));
    await g.moveBy(const Offset(0, -40));
    await g.up();
    await tester.pump();
    final p1 = VolumeTaper.position(gain);
    expect(p1 - p0, closeTo(0.2, 0.11));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final h = await tester.startGesture(tester.getCenter(f), kind: PointerDeviceKind.mouse);
    await h.moveBy(const Offset(0, -20));
    await h.moveBy(const Offset(0, -40));
    await h.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    final fine = VolumeTaper.position(gain) - p1;
    expect(fine, greaterThan(0));
    expect(fine, lessThan(0.07), reason: 'a fifth of a plain drag');
    await tester.tap(f);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(f);
    await tester.pumpAndSettle();
    expect(gain, 1, reason: 'double-tap: 0 dB');
  });
}
