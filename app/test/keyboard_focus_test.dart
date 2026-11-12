// The whole app from the keyboard (owner, 2026-11-11): areas with their own keys, Tab between them, Enter in and Esc
// out, the FX chain, device controls, the mixer, Settings and menus from a fake keyboard; the hint strip per context
// and after a rebinding; Vim keys' H J K L as the arrows; the transport's back-to-start; pages and sheets mid-exit.
import 'dart:convert';

import 'package:caw/actions/actions.dart';
import 'package:caw/actions/hints.dart';
import 'package:caw/actions/keymap.dart';
import 'package:caw/actions/keys.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/engine/engine.dart' show ModuleInfo;
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/cpp/build_section.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:caw/ui/arrange/mixer_card.dart';
import 'package:caw/ui/devices/kit/key_param.dart';
import 'package:caw/ui/frame/frame_widgets.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/settings/settings_deps.dart';
import 'package:caw/ui/settings/settings_registry.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/ui/keyboard/key_area.dart';
import 'package:caw/ui/keyboard/keyboard_layer.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/page_closer.dart';
import 'package:caw/ui/panel_motion.dart';
import 'package:caw/ui/settings/settings_page.dart';
import 'package:caw/ui/volume_fader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

void main() {
  late AppState s;
  late MotionLevel motion;
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off; // settled pumps without the device displays' tickers
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'Keys', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0),
      LayerDoc(id: 'b', name: 'Bass', color: 1),
    ]);
    s.ready = true;
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() {
    Motion.setting = motion;
    s.dispose();
  });

  final registry = ActionRegistry.standard();

  /// A widget test that lets the key badge's toast and the hint timers run out at its end.
  void keyTest(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
        await body(tester);
        await tester.pump(const Duration(seconds: 2));
      });
  KeySeq k(String keys) => KeySeq.parse(keys);

  /// The app's frame around [body]: the key router, and the keyboard layer over the navigator (menus, pages).
  Future<void> pumpApp(WidgetTester tester, Widget body, {Size size = const Size(1200, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final closer = PageCloserObserver();
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [closer],
      builder: (context, child) => PageCloser(observer: closer, child: KeyboardLayer(observer: closer, child: child!)),
      home: KeyRouter(state: s, screenArea: Area.arranger, onView: (_) {},
          child: Scaffold(body: ListenableBuilder(listenable: s, builder: (_, _) => body))),
    ));
    await tester.pump();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {bool shift = false, bool ctrl = false, bool alt = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(k);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  String? focusedLabel() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx == null ? null : itemText(ctx);
  }

  group('hint strip contents', () {
    test('each context lists its own keys, then Tab, Esc and the full list', () {
      final km = Keymap.defaults(registry);
      final fx = contextHints(registry, km, Area.fx);
      expect(fx.map((h) => h.label), containsAllInOrder(['Previous effect', 'Next effect', 'Open the effect', 'Bypass']));
      expect(fx.firstWhere((h) => h.label == 'Bypass').keys, 'Space');
      expect(fx.firstWhere((h) => h.label == 'Previous effect').keys, '↑ W');
      expect(fx.map((h) => h.label), containsAll(['Next area', 'Up a level', 'Action list']));
      final mixer = contextHints(registry, km, Area.mixer);
      expect(mixer.firstWhere((h) => h.label == 'Mute').keys, 'M');
      expect(mixer.firstWhere((h) => h.label == 'Solo').keys, 'S');
      final device = contextHints(registry, km, Area.device);
      expect(device.firstWhere((h) => h.label == 'Default value').keys, 'Home');
      expect(device.firstWhere((h) => h.label == 'Type a value').keys, 'Enter');
      final settings = contextHints(registry, km, Area.settings);
      expect(settings.firstWhere((h) => h.label == 'Toggle or press').keys, 'Space');
      // Menus: arrows only (letters jump to items), and no Tab or Esc entries of the page behind.
      final menu = contextHints(registry, km, Area.menu);
      expect(menu.map((h) => h.label), ['Previous item', 'Next item', 'Choose', 'Close']);
      for (final a in [Area.files, Area.tabs, Area.sections, Area.page]) {
        expect(contextHints(registry, km, a), isNotEmpty, reason: '$a');
      }
    });

    test('a rebinding shows in the strip, and Vim keys add H J K L to the arrows', () {
      final km = Keymap.defaults(registry);
      km.unbind(Area.fx, k('Space'), record: true);
      km.bind(Area.fx, k('B'), const ActionRef.action('fx.bypass'));
      expect(contextHints(registry, km, Area.fx).firstWhere((h) => h.label == 'Bypass').keys, 'B');
      final vim = contextHints(registry, km, Area.fx, vimKeys: true);
      expect(vim.firstWhere((h) => h.label == 'Previous effect').keys, '↑ K W');
      expect(vim.firstWhere((h) => h.label == 'Next effect').keys, '↓ J S');
      // The mixer binds S to solo itself; down's J still shows, and a letter an area binds is never offered.
      expect(contextHints(registry, km, Area.mixer, vimKeys: true).firstWhere((h) => h.label == 'Next control').keys, '↓ J');
    });

    keyTest('the strip shows the focused context\'s keys and follows a rebinding', (tester) async {
      s.addNativeEffect(s.project.layers.first, 'org.caw.utility');
      s.settings.keyHints = true;
      await pumpApp(tester, SizedBox(height: 600, child: FxStack(state: s, layer: s.project.layers.first)));
      await key(tester, LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byType(KeyHintStrip), findsOneWidget);
      final strip = tester.widget<KeyHintStrip>(find.byType(KeyHintStrip));
      expect(strip.hints.map((h) => h.label), contains('Bypass'));
      final router = tester.state<KeyRouterState>(find.byType(KeyRouter));
      router.keymap.unbind(Area.fx, k('Space'));
      router.keymap.bind(Area.fx, k('B'), const ActionRef.action('fx.bypass'));
      router.revision.value++;
      await tester.pump();
      await tester.pump();
      expect(tester.widget<KeyHintStrip>(find.byType(KeyHintStrip)).hints.firstWhere((h) => h.label == 'Bypass').keys, 'B');
      // Turned off in Settings, it goes.
      s.settings.keyHints = false;
      router.revision.value++;
      await tester.pump();
      await tester.pump();
      expect(find.byType(KeyHintStrip), findsNothing);
    });
  });

  group('areas', () {
    Widget twoAreas() => Column(children: [
          KeyArea(area: Area.page, label: 'Top', child: Column(children: [
            TextButton(onPressed: () {}, child: const Text('One')),
            TextButton(onPressed: () {}, child: const Text('Two')),
            TextButton(onPressed: () {}, child: const Text('Three')),
          ])),
          const SizedBox(height: 40),
          KeyArea(area: Area.page, label: 'Bottom', child: Row(children: [
            TextButton(onPressed: () {}, child: const Text('Left')),
            TextButton(onPressed: () {}, child: const Text('Right')),
          ])),
        ]);

    keyTest('Tab moves between areas in reading order, Enter goes in, arrows and WASD move, Esc comes out',
        (tester) async {
      await pumpApp(tester, twoAreas());
      await key(tester, LogicalKeyboardKey.tab);
      expect(KeyArea.focused?.label, 'Top');
      await key(tester, LogicalKeyboardKey.tab);
      expect(KeyArea.focused?.label, 'Bottom');
      await key(tester, LogicalKeyboardKey.tab, shift: true);
      expect(KeyArea.focused?.label, 'Top');
      await key(tester, LogicalKeyboardKey.enter);
      expect(focusedLabel(), 'One');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'Two');
      await key(tester, LogicalKeyboardKey.keyS);
      expect(focusedLabel(), 'Three');
      await key(tester, LogicalKeyboardKey.keyW);
      expect(focusedLabel(), 'Two');
      await key(tester, LogicalKeyboardKey.escape);
      expect(FocusManager.instance.primaryFocus, KeyArea.focused!.node, reason: 'Esc from a control: its area');
      // Every area and control is labelled for screen readers.
      expect(find.bySemanticsLabel('Top'), findsOneWidget);
      expect(find.bySemanticsLabel('Bottom'), findsOneWidget);
    });

    keyTest('Vim keys: H J K L do what the arrows do, only while on', (tester) async {
      await pumpApp(tester, twoAreas());
      await key(tester, LogicalKeyboardKey.tab);
      await key(tester, LogicalKeyboardKey.tab);
      await key(tester, LogicalKeyboardKey.enter);
      expect(focusedLabel(), 'Left');
      await key(tester, LogicalKeyboardKey.keyL);
      expect(focusedLabel(), 'Left', reason: 'Vim keys are off by default');
      s.settings.vimKeys = true;
      await key(tester, LogicalKeyboardKey.keyL);
      final byL = focusedLabel();
      await key(tester, LogicalKeyboardKey.keyH);
      final byH = focusedLabel();
      await key(tester, LogicalKeyboardKey.arrowRight);
      final byRight = focusedLabel();
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect([byL, byH, byRight, focusedLabel()], ['Right', 'Left', 'Right', 'Left']);
      // Up and down too: K and J into the area above and back are the arrows' moves.
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.tab, shift: true);
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.keyJ);
      expect(focusedLabel(), 'Two');
      await key(tester, LogicalKeyboardKey.keyK);
      expect(focusedLabel(), 'One');
    });

    keyTest('a menu: arrows move, a letter jumps to its item, Enter chooses, Esc closes', (tester) async {
      String? chosen;
      late BuildContext ctx;
      await pumpApp(tester, Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }));
      Future<void> open() async {
        chosen = null;
        showMenu<String>(context: ctx, position: const RelativeRect.fromLTRB(100, 100, 100, 100), items: [
          for (final n in ['Alpha', 'Beta', 'Gamma', 'Gold']) PopupMenuItem(value: n, child: Text(n)),
        ]).then((v) => chosen = v);
        await tester.pumpAndSettle();
      }

      await open();
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'Alpha');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'Beta');
      await key(tester, LogicalKeyboardKey.keyG);
      expect(focusedLabel(), 'Gamma');
      await key(tester, LogicalKeyboardKey.keyG);
      expect(focusedLabel(), 'Gold', reason: 'the same letter again: the next item it starts');
      await key(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen, 'Gold');

      await open();
      await key(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsNothing);
      expect(chosen, isNull);
    });
  });

  group('contexts', () {
    keyTest('FX chain: up/down select, Space bypasses, Ctrl+D duplicates, Alt+Up reorders, Delete removes',
        (tester) async {
      final l = s.project.layers.first;
      s.addNativeEffect(l, 'org.caw.utility');
      s.addNativeEffect(l, 'org.caw.eq');
      await pumpApp(tester, SizedBox(height: 800, child: FxStack(state: s, layer: l)));
      await key(tester, LogicalKeyboardKey.tab);
      expect(KeyArea.focused?.area, Area.fx);
      await key(tester, LogicalKeyboardKey.space);
      expect(l.components[0].bypass, isTrue, reason: 'the first effect is picked when the chain takes the focus');
      expect(s.transportOn, isFalse, reason: 'Space is the chain\'s here, not play');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.space);
      expect(l.components[1].bypass, isTrue);
      await key(tester, LogicalKeyboardKey.keyD, ctrl: true);
      expect(l.components.map((c) => c.id), ['org.caw.utility', 'org.caw.eq', 'org.caw.eq']);
      await key(tester, LogicalKeyboardKey.arrowUp, alt: true);
      await key(tester, LogicalKeyboardKey.arrowUp, alt: true);
      expect(l.components.map((c) => c.id), ['org.caw.eq', 'org.caw.utility', 'org.caw.eq']);
      await key(tester, LogicalKeyboardKey.delete);
      expect(l.components.map((c) => c.id), ['org.caw.utility', 'org.caw.eq']);
      expect(find.byKey(const ValueKey('key-ring-box')), findsOneWidget, reason: 'the picked effect wears the ring');
    });

    keyTest('FX chain: Enter opens the effect, and the device editor\'s keys move and change its controls',
        (tester) async {
      s = stateWith('org.caw.utility', make: () => s);
      final l = s.project.layers.first;
      await pumpApp(tester, SizedBox(height: 800, child: FxStack(state: s, layer: l)));
      await key(tester, LogicalKeyboardKey.tab);
      await key(tester, LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(KeyArea.focused?.area, Area.device, reason: 'the editor takes the focus');
      // To the first knob on a continuous travel (a stepped one has no finer step).
      bool continuous() {
        final k = KeyParam.focused;
        final p = k == null ? null : s.componentInfo('org.caw.utility')!.param(k.widget.paramId);
        return p != null && !p.isChoice && p.step == 0;
      }
      for (var i = 0; i < 40 && !continuous(); i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      final param = KeyParam.focused!;
      final id = param.widget.paramId;
      final p = s.componentInfo('org.caw.utility')!.param(id)!;
      final before = l.components.first.params[id] ?? p.defaultValue;
      await key(tester, LogicalKeyboardKey.arrowUp);
      final up = l.components.first.params[id]!;
      expect(up, greaterThan(before));
      await key(tester, LogicalKeyboardKey.home);
      expect(l.components.first.params[id], p.defaultValue);
      await key(tester, LogicalKeyboardKey.keyW);
      final coarse = l.components.first.params[id]! - p.defaultValue;
      await key(tester, LogicalKeyboardKey.home);
      await key(tester, LogicalKeyboardKey.arrowUp, shift: true);
      final fine = l.components.first.params[id]! - p.defaultValue;
      expect(fine, greaterThan(0));
      expect(fine, lessThan(coarse), reason: 'Shift is finer');
      await key(tester, LogicalKeyboardKey.minus);
      expect(l.components.first.params[id], lessThan(p.defaultValue + fine));
    });

    keyTest('mixer: left/right strips, up/down level and pan, +/- change, M and S', (tester) async {
      await pumpApp(tester, SizedBox(width: 900, height: 600, child: MixerCard(state: s, onClose: () {})));
      await key(tester, LogicalKeyboardKey.tab);
      expect(KeyArea.focused?.area, Area.mixer);
      final master = s.project.master;
      await key(tester, LogicalKeyboardKey.equal);
      expect(VolumeTaper.db(s.project.master), closeTo(VolumeTaper.db(master) + 1, 0.01), reason: 'the master first');
      await key(tester, LogicalKeyboardKey.arrowRight);
      final keys = s.project.layers.first;
      final v = keys.volume;
      await key(tester, LogicalKeyboardKey.minus);
      expect(VolumeTaper.db(keys.volume), closeTo(VolumeTaper.db(v) - 1, 0.01));
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.equal);
      expect(keys.pan, closeTo(0.05, 1e-9));
      await key(tester, LogicalKeyboardKey.home);
      expect(keys.pan, 0);
      await key(tester, LogicalKeyboardKey.keyM);
      expect(keys.mute, isTrue);
      await key(tester, LogicalKeyboardKey.keyD);
      await key(tester, LogicalKeyboardKey.keyS);
      expect(s.project.layers[1].solo, isTrue, reason: 'D moved to Bass; S is solo in the mixer');
      expect(find.textContaining('Pan'), findsWidgets, reason: 'the picked control is named on the strip');
    });

    keyTest('Settings: rows by arrows, Space toggles, Right turns a switch on and Left off', (tester) async {
      await pumpApp(tester, SettingsSectionBody(section: SettingsSection.keys, deps: SettingsDeps(settings: s.settings)));
      await key(tester, LogicalKeyboardKey.tab);
      expect(KeyArea.focused?.area, Area.settings);
      // Down to the Vim keys switch.
      for (var i = 0; i < 10 && focusedLabel() != 'Vim keys everywhere'; i++) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(), 'Vim keys everywhere');
      await key(tester, LogicalKeyboardKey.space);
      expect(s.settings.vimKeys, isTrue);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(s.settings.vimKeys, isFalse);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(s.settings.vimKeys, isFalse, reason: 'already off');
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(s.settings.vimKeys, isTrue);
    });
  });

  keyTest('Build: Ctrl+Shift+B the tabs (left/right switch them), Ctrl+Shift+E the explorer, Ctrl+Shift+Enter the editor',
      (tester) async {
    s.project.modules.addAll([
      ModuleDoc(id: 'riff', name: 'Riff', source: '---\nkind: pattern\n---\n0 A2 1 1'),
      ModuleDoc(id: 'beat', name: 'Beat', source: '---\nkind: pattern\n---\nc4'),
    ]);
    s.info['riff'] = const ModuleInfo(ok: true, kind: 'pattern');
    s.info['beat'] = const ModuleInfo(ok: true, kind: 'pattern');
    final sections = SectionController()
      ..openBuild(const BuildTab(BuildTabKind.pattern, 'riff'))
      ..openBuild(const BuildTab(BuildTabKind.pattern, 'beat'));
    addTearDown(sections.dispose);
    await pumpApp(tester, SectionScope(controller: sections, child: BuildSection(state: s)), size: const Size(1300, 900));
    await key(tester, LogicalKeyboardKey.keyB, ctrl: true, shift: true);
    expect(KeyArea.focused?.area, Area.tabs);
    final before = sections.activeBuildTab;
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(sections.activeBuildTab, isNot(before), reason: 'left steps to the other tab');
    await key(tester, LogicalKeyboardKey.keyE, ctrl: true, shift: true);
    expect(KeyArea.focused?.label, 'Explorer');
    await key(tester, LogicalKeyboardKey.keyE, ctrl: true, shift: true);
    await tester.pump();
    expect(find.byKey(const ValueKey('explorer sash')), findsNothing, reason: 'again: the explorer hides');
    await key(tester, LogicalKeyboardKey.enter, ctrl: true, shift: true);
    expect(KeyArea.focused?.label, 'Editor');
    await tester.pumpWidget(const SizedBox());
  });

  group('back to start', () {
    Future<void> pumpTransport(WidgetTester tester) => pumpApp(tester,
        Align(alignment: Alignment.bottomCenter, child: BottomTransport(state: s)), size: const Size(412, 800));

    keyTest('a tap goes to the loop start, a double tap on to the project start, and the views are asked',
        (tester) async {
      s.project
        ..loopRange = true
        ..loopStartSteps = 32
        ..loopEndSteps = 64;
      final asks = <RevealStartRequest>[];
      s.revealStartRequests.addListener(() => asks.add(s.revealStartRequests.value!));
      await pumpTransport(tester);
      s.seekTo(40);
      await tester.tap(find.byKey(const ValueKey('transport-start')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(s.playheadStep, 32);
      expect(asks.single.step, 32);
      expect(asks.single.always, isFalse, reason: 'the loop start: a view scrolls only if it is off screen');
      await tester.tap(find.byKey(const ValueKey('transport-start')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(s.playheadStep, 0);
      expect(asks.last.step, 0);
      expect(asks.last.always, isTrue, reason: 'the project start: the views glide back');
    });

    keyTest('without a loop a tap goes to the project start; Home and Ctrl+Home from the keyboard',
        (tester) async {
      final asks = <RevealStartRequest>[];
      s.revealStartRequests.addListener(() => asks.add(s.revealStartRequests.value!));
      await pumpTransport(tester);
      s.seekTo(24);
      await tester.tap(find.byKey(const ValueKey('transport-start')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(s.playheadStep, 0);
      expect(asks.single.always, isFalse, reason: 'one tap: a view scrolls only if the start is off its screen');
      s.project
        ..loopRange = true
        ..loopStartSteps = 16
        ..loopEndSteps = 32;
      s.seekTo(24);
      await key(tester, LogicalKeyboardKey.home);
      expect(s.playheadStep, 16);
      await key(tester, LogicalKeyboardKey.home, ctrl: true);
      expect(s.playheadStep, 0);
      expect(asks.last.always, isTrue, reason: 'Ctrl+Home reveals the project start');
      final tip = tester.widget<IconButton>(find.byKey(const ValueKey('transport-start'))).tooltip!;
      expect(tip, contains('Home'));
      expect(tip, contains('Ctrl+Home'));
    });
  });

  group('exits', () {
    keyTest('a page and a sheet are partly visible half way through their exit', (tester) async {
      Motion.setting = MotionLevel.full;
      EditMotion.feel = MotionFeel.presets['Calm']!; // the theme's own transition, not Material's
      addTearDown(() => EditMotion.feel = MotionFeel.subtle);
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      })));
      double opacityOf(Finder f) {
        final fades = find.ancestor(of: f, matching: find.byType(FadeTransition));
        return tester.widgetList<FadeTransition>(fades).map((t) => t.opacity.value).reduce((a, b) => a * b);
      }

      Navigator.of(ctx).push(panelRoute<void>(ctx, (_) => const Scaffold(body: Text('the page'))));
      await tester.pumpAndSettle();
      expect(opacityOf(find.text('the page')), 1);
      Navigator.of(ctx).pop();
      await tester.pump();
      await tester.pump(Motion.paced(pageTransition) ~/ 2);
      expect(find.text('the page'), findsOneWidget, reason: 'still on its way out');
      final mid = opacityOf(find.text('the page'));
      expect(mid, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(find.text('the page'), findsNothing);

      EditMotion.feel = MotionFeel.subtle;
      showGlassSheet<void>(context: ctx, builder: (_) => const SizedBox(height: 200, child: Text('the sheet')));
      await tester.pumpAndSettle();
      final shown = tester.getTopLeft(find.text('the sheet')).dy;
      Navigator.of(ctx).pop();
      await tester.pump();
      await tester.pump(sheetExit ~/ 2);
      expect(find.text('the sheet'), findsOneWidget, reason: 'still sliding away');
      final y = tester.getTopLeft(find.text('the sheet')).dy;
      expect(y, greaterThan(shown));
      expect(y, lessThan(900), reason: 'partly on screen');
      await tester.pumpAndSettle();
      expect(find.text('the sheet'), findsNothing);
    });
  });
}
