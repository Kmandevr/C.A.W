import 'package:caw/actions/actions.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/touch_quick_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('quick action buttons run actions directly', (tester) async {
    final registry = ActionRegistry.standard();
    final keymap = Keymap.defaults(registry);
    final calls = <ActionRef>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TouchQuickActions(
          area: Area.builder,
          keymap: keymap,
          defaults: Keymap.defaults(registry),
          registry: registry,
          onRun: calls.add,
          onSave: () async {},
        ),
      ),
    ));

    await tester.tap(find.text('Play / stop'));
    expect(calls, [ActionRef.action('transport.playstop')]);
  });

  testWidgets('quick actions can add and persist an action', (tester) async {
    final registry = ActionRegistry.standard();
    final keymap = Keymap.defaults(registry);
    var saves = 0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TouchQuickActions(
          area: Area.builder,
          keymap: keymap,
          defaults: Keymap.defaults(registry),
          registry: registry,
          onRun: (_) {},
          onSave: () async => saves++,
        ),
      ),
    ));

    await tester.tap(find.byTooltip('Customize quick actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tap tempo'));
    await tester.pumpAndSettle();

    expect(keymap.toolbars[Area.builder], contains(ActionRef.action('transport.tap')));
    expect(saves, 1);
  });
}
