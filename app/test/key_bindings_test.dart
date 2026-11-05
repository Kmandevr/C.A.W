// Tests the key bindings editor: give an action a key by pressing it or typing it, see what it would replace, remove a
// key, reset an action and every key, and the result saved as a keymap over the defaults.
import 'package:caw/actions/actions.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/key_bindings.dart';
import 'package:caw/ui/key_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const play = ActionRef.action('transport.playstop');
  final space = KeySeq.parse('Space');

  Future<(Keymap, Keymap, List<int>)> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final registry = ActionRegistry.standard();
    final defaults = Keymap.defaults(registry);
    final keymap = defaults.copy();
    final saves = [0];
    await tester.pumpWidget(MaterialApp(home: KeyBindingsPage(
      registry: registry, keymap: () => keymap, defaults: defaults, onSave: () async => saves[0]++)));
    await tester.enterText(find.byKey(const ValueKey('keys-search')), 'Play / pause');
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Play / pause'));
    await tester.pumpAndSettle();
    return (keymap, defaults, saves);
  }

  testWidgets('a pressed key is added, a key is removed, and the action resets to its default', (tester) async {
    final (keymap, defaults, saves) = await open(tester);
    expect(find.byKey(const ValueKey('key-Space')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-key')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('P'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('key-set')));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, KeySeq.parse('P')), play);
    expect(saves[0], 1);

    await tester.tap(find.byTooltip('Remove Space'));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, space), isNull);
    expect(keymap.serialize(base: defaults), contains(RegExp(r'global\s+Space\s+-')),
        reason: 'the saved file removes the default key');

    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, space), play);
    expect(keymap.lookup(Area.global, KeySeq.parse('P')), isNull);
  });

  testWidgets('a typed key shows what it would replace, and setting it moves the key', (tester) async {
    final (keymap, _, _) = await open(tester);
    await tester.tap(find.byKey(const ValueKey('add-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('key-typed')), 'nonsense key');
    await tester.pump();
    expect(find.text('Not a key'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('key-typed')), 'Ctrl+Z');
    await tester.pump();
    expect(find.text('Replaces Undo on Ctrl+Z'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('key-set')));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, KeySeq.parse('Ctrl+Z')), play);
  });

  testWidgets('Reset all puts every key back after a confirmation', (tester) async {
    final (keymap, _, _) = await open(tester);
    await tester.tap(find.byTooltip('Remove Space'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byKey(const ValueKey('add-key')))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, space), play);
  });

  testWidgets('the action list opens the editor, and a key set there runs through the router', (tester) async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    final router = GlobalKey<KeyRouterState>();
    await tester.pumpWidget(MaterialApp(home: KeyRouter(key: router, state: s, screenArea: Area.arranger, onView: (_) {},
      child: const Scaffold(body: SizedBox.expand()))));
    await tester.pump();
    router.currentState!.showActionList(router.currentContext!);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit keys'));
    await tester.pumpAndSettle();
    expect(find.text('Key bindings'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('keys-search')), 'Go to Mixer');
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'Go to Mixer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('key-typed')), 'Alt+M');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('key-set')));
    await tester.pumpAndSettle();
    expect(router.currentState!.vim.keymap.lookup(Area.global, KeySeq.parse('Alt+M')),
        const ActionRef.action('view.mixer'));
  });

  test('typed keys match what the keyboard sends', () {
    expect(typedKeys('Shift+/')!.format(), '/');
    expect(typedKeys('Shift+?')!.format(), '?');
    expect(typedKeys('Shift+1'), isNull, reason: 'Shift+1 types "!"');
    expect(typedKeys('Ctrl+Shift+1')!.format(), 'Ctrl+Shift+1');
    expect(typedKeys('Shift+A')!.format(), 'Shift+A');
    expect(typedKeys('Shift+Tab')!.format(), 'Shift+Tab');
    expect(typedKeys('G G')!.format(), 'G G');
    expect(typedKeys('not a key'), isNull);
  });

  testWidgets('a plain digit is refused, and holding a key counts once', (tester) async {
    final (keymap, _, _) = await open(tester);
    await tester.tap(find.byKey(const ValueKey('add-key')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(find.text('K'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('key-typed')), '3');
    await tester.pump();
    expect(find.text('A plain digit is a count; use it with Ctrl or Alt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('key-set')));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, KeySeq.parse('3')), isNull);
  });

  testWidgets('resetting an action leaves a default key another action has since been given', (tester) async {
    final (keymap, _, _) = await open(tester);
    keymap.bind(Area.global, space, const ActionRef.action('edit.undo'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-key')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('key-typed')), 'P');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('key-set')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    expect(keymap.lookup(Area.global, space), const ActionRef.action('edit.undo'));
    expect(find.text('Space stays on Undo'), findsOneWidget);
  });
}
