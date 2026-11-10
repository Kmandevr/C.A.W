// Knob taper: exponential parameters (`curve: exponential`) move little at the start of a knob's travel and a lot at
// the end; linear ones move evenly; a double-tap goes back to the default.
import 'dart:math' as math;

import 'package:caw/ui/arrange/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a log taper over a positive range, and back', () {
    const t = Taper(20, 20000, exponential: true);
    expect(t.value(0), closeTo(20, 1e-9));
    expect(t.value(1), closeTo(20000, 1e-6));
    expect(t.value(0.5), closeTo(632.46, 0.01), reason: 'the geometric middle');
    for (final v in [20.0, 100.0, 1000.0, 19999.0]) {
      expect(t.value(t.position(v)), closeTo(v, v * 1e-9));
    }
  });

  test('from zero the taper still starts fine; linear stays linear', () {
    const t = Taper(0, 2, exponential: true);
    expect(t.value(0), 0);
    expect(t.value(1), closeTo(2, 1e-9));
    expect(t.value(0.5), lessThan(0.1), reason: 'half the travel is well under half the range');
    expect(t.position(t.value(0.3)), closeTo(0.3, 1e-9));
    const l = Taper(0, 2);
    expect(l.value(0.5), 1);
    expect(l.position(1.5), 0.75);
  });

  testWidgets('an exponential knob dragged a quarter of the way moves far less than a linear one', (tester) async {
    var exp = 20.0, lin = 20.0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(builder: (context, setState) => Row(children: [
      Knob(key: const ValueKey('exp'), value: exp, min: 20, max: 20000, defaultValue: 1000, label: 'Cutoff',
        exponential: true, onChanged: (v) => setState(() => exp = v)),
      Knob(key: const ValueKey('lin'), value: lin, min: 20, max: 20000, label: 'Linear',
        onChanged: (v) => setState(() => lin = v)),
    ])))));
    // 200 px covers the travel; 18 px of slop is used up before the drag starts.
    await tester.drag(find.byKey(const ValueKey('exp')), const Offset(0, -68));
    await tester.drag(find.byKey(const ValueKey('lin')), const Offset(0, -68));
    await tester.pumpAndSettle();
    // The same travel t on both: linear 20 + t × 19980, exponential 20 × 1000^t.
    final t = (lin - 20) / 19980;
    expect(t, inInclusiveRange(0.2, 0.26));
    expect(exp, closeTo(20 * math.pow(1000, t), 2));
    await tester.tap(find.byKey(const ValueKey('exp')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('exp')));
    await tester.pumpAndSettle();
    expect(exp, 1000, reason: 'a double-tap resets it');
  });
}
