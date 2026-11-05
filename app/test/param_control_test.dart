// Tests the inspector's parameter rows: a number's value can be typed (clamped and snapped, bad entries refused), and
// a double-tap still resets it to the default.
import 'package:caw/engine/engine.dart';
import 'package:caw/ui/param_control.dart';
import 'package:caw/ui/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cutoff = ParamInfo('cutoff', 0.5, 0, 1, step: 0.25);

  test('typed parameter values are finite, clamped to the range and snapped to the step', () {
    expect(parseParam('0.6', cutoff), 0.5);
    expect(parseParam(' 0.9 ', cutoff), 1.0);
    expect(parseParam('0,5', cutoff), 0.5);
    expect(parseParam('5', cutoff), 1.0);
    expect(parseParam('-2', cutoff), 0.0);
    expect(parseParam('NaN', cutoff), isNull);
    expect(parseParam('Infinity', cutoff), isNull);
    expect(parseParam('high', cutoff), isNull);
    expect(parseParam('0.37', const ParamInfo('free', 0, 0, 1)), 0.37);
  });

  testWidgets('tap a number to type it; a bad entry is refused; double-tap resets', (tester) async {
    var value = 0.25;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) => ParamControl(param: cutoff, value: value, color: Colors.green,
        onChanged: (v) => setState(() => value = v)),
    ))));

    await tester.tap(find.text('0.25'));
    await tester.pump(kDoubleTapTimeout); // a single tap counts once no second tap can follow
    await tester.pumpAndSettle();
    expect(find.text('cutoff (0.00 to 1.00)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'high');
    await tester.tap(find.text('Set'));
    await tester.pump();
    expect(find.text('Not a value'), findsOneWidget);
    expect(value, 0.25);
    await tester.enterText(find.byType(TextField), '0.8');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(value, 0.75);
    expect(find.text('0.75'), findsOneWidget);

    await tester.tap(find.text('0.75'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('0.75'));
    await tester.pumpAndSettle();
    expect(value, 0.5, reason: 'a double-tap resets to the default');
    expect(find.byType(TextField), findsNothing, reason: 'and opens no dialog');
  });

  testWidgets('setting the shown value unedited keeps the unrounded value', (tester) async {
    var value = 0.123;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParamControl(
      param: const ParamInfo('free', 0, 0, 1), value: value, color: Colors.green, onChanged: (v) => value = v))));
    await tester.tap(find.text('0.12'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(value, 0.123);
  });
}
