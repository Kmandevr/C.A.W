// Desktop input next to touch: a mouse drag starts at once (a finger still holds), the wheel steps a knob with one
// change a burst, Esc and the Back button close a closable page (Settings), Ctrl+1/2/3 follow the rail, the hint words.
import 'package:caw/actions/actions.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/knob.dart';
import 'package:caw/ui/page_closer.dart';
import 'package:caw/ui/pointer_input.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(PointerInput.reset);

  Future<List<String>> pumpDraggable(WidgetTester tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      HoldDraggable<String>(
        data: 'x',
        onDragStarted: () => log.add('start'),
        feedback: const SizedBox(width: 20, height: 20),
        child: GestureDetector(onTap: () => log.add('tap'),
            child: const ColoredBox(key: ValueKey('drag-me'), color: Colors.red, child: SizedBox(width: 80, height: 40))),
      ),
      const SizedBox(height: 100),
      DragTarget<String>(onAcceptWithDetails: (d) => log.add('drop ${d.data}'),
          builder: (_, _, _) => const ColoredBox(key: ValueKey('target'), color: Colors.blue,
              child: SizedBox(width: 80, height: 80))),
    ]))));
    return log;
  }

  testWidgets('a mouse drags at once; a finger has to hold first; a click is still a tap', (tester) async {
    final log = await pumpDraggable(tester);
    final from = tester.getCenter(find.byKey(const ValueKey('drag-me')));
    final to = tester.getCenter(find.byKey(const ValueKey('target')));

    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await mouse.moveTo(from + const Offset(0, 20));
    await tester.pump();
    expect(log, ['start'], reason: 'no hold with a mouse');
    await mouse.moveTo(to);
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(log, ['start', 'drop x']);

    log.clear();
    final finger = await tester.startGesture(from);
    await finger.moveTo(from + const Offset(0, 20));
    await tester.pump(const Duration(milliseconds: 600));
    await finger.up();
    await tester.pump();
    expect(log, isNot(contains('start')), reason: 'a finger that moves at once does not drag');

    log.clear();
    await tester.tap(find.byKey(const ValueKey('drag-me')), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(log, ['tap']);

    log.clear();
    final held = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 600));
    await held.moveTo(to);
    await tester.pump();
    await held.up();
    await tester.pump();
    expect(log, ['start', 'drop x'], reason: 'touch keeps the hold-then-drag');
  });

  testWidgets('the wheel steps a knob (Shift finer) and ends each burst with one change', (tester) async {
    var value = 0.5;
    var ends = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: StatefulBuilder(
      builder: (context, setState) => Knob(value: value, min: 0, max: 1, label: 'Amount',
          onChanged: (v) => setState(() => value = v), onChangeEnd: () => ends++),
    )))));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(find.byType(Knob))));
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(value, closeTo(0.53, 1e-9), reason: 'three turns up: three hundredths');
    expect(ends, 0, reason: 'the burst goes on');
    await tester.pump(WheelSteps.burstGap);
    expect(ends, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 20)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(value, closeTo(0.528, 1e-9), reason: 'Shift: a fifth of a step, down');
    await tester.pump(WheelSteps.burstGap);
    expect(ends, 2);
  });

  testWidgets('Esc and the mouse Back button close Settings; a page that is not closable stays', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final closer = PageCloserObserver();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      theme: Neon.theme(),
      navigatorObservers: [closer],
      builder: (_, child) => PageCloser(observer: closer, child: child!),
      home: const Scaffold(body: Text('home')),
    ));
    void openSettings() => nav.currentState!.push(MaterialPageRoute<void>(settings: closablePage,
        builder: (_) => SettingsPage(settings: Settings(), onEditKeys: (_) async {})));

    openSettings();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('home'), findsOneWidget);

    openSettings();
    await tester.pumpAndSettle();
    final back = await tester.startGesture(const Offset(600, 400), kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
    await back.up();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing, reason: 'the Back button');

    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('roll'))));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('roll'), findsOneWidget, reason: 'only closable pages close');
  });

  test('Ctrl+1/2/3 go to Build, Files and Arrange, in the rail order, under the current names', () {
    final reg = ActionRegistry.standard();
    final keys = Keymap.defaults(reg);
    KeySeq k(String s) => KeySeq.parse(s);
    expect(keys.lookup(Area.global, k('Ctrl+1')), const ActionRef.action('view.builder'));
    expect(keys.lookup(Area.global, k('Ctrl+2')), const ActionRef.action('view.files'));
    expect(keys.lookup(Area.global, k('Ctrl+3')), const ActionRef.action('view.arranger'));
    expect(reg['view.builder']!.name, 'Go to Build');
    expect(reg['view.files']!.name, 'Go to Files');
    expect(reg['view.arranger']!.name, 'Go to Arrange');
    expect(reg['view.exporter']!.defaultKeys, isEmpty, reason: 'Ctrl+3 is Arrange now');
    for (final d in reg.all) {
      for (final key in d.defaultKeys) {
        expect(RegExp(r'^Ctrl\+[4-9]$').hasMatch(key), isFalse, reason: '${d.id}: no retired workspace keys');
      }
    }
  });

  testWidgets('hint words follow the input: click and right-click with a mouse, tap and long-press with a finger',
      (tester) async {
    await tester.pumpWidget(const SizedBox());
    expect((PointerInput.tap, PointerInput.hold), ('tap', 'long-press'), reason: 'the test platform is a phone');
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(10, 10)));
    expect((PointerInput.tapCap, PointerInput.hold), ('Click', 'right-click'));
    await tester.tapAt(const Offset(10, 10));
    expect(PointerInput.tap, 'tap');
  });
}
