// Keys through the router (counts and macros in the piano roll, code-editor Vim), auto-update, light mode and MIDI
// files (needs CAW_LIB).
import 'dart:io';

import 'package:caw/actions/keys.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/actions/actions.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  AppState app() {
    final s = AppState();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    s.ready = true;
    s.starting = false;
    return s;
  }

  Steps firstAt(ModuleDoc m) => PatternDoc.parse(m.source).doc!.notes.first.at;

  testWidgets('in the roll a count repeats a key and a recorded macro replays', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = app();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n');
    s.project.modules.add(m);
    await tester.pumpWidget(MaterialApp(
      home: KeyRouter(
        state: s,
        screenArea: Area.builder,
        onView: (_) {},
        child: Scaffold(body: PatternEditor(state: s, module: m)),
      ),
    ));
    await tester.tapAt(const Offset(120, 200));
    await tester.pump(const Duration(milliseconds: 200));
    final start = firstAt(m);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.pump(const Duration(milliseconds: 200));
    expect(firstAt(m), start + Steps(3), reason: m.source);

    final router = tester.state<KeyRouterState>(find.byType(KeyRouter));
    router.vim.area = Area.pattern;
    for (final k in ['Alt+Q', 'A', 'D', 'D', 'Alt+Q']) {
      router.vim.handleKey(KeyChord.parse(k));
    }
    router.vim.handleKey(KeyChord.parse('@'));
    router.vim.handleKey(KeyChord.parse('A'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(firstAt(m), start + Steps(7), reason: m.source); // 3, then 2 while recording, then 2 more on replay
    expect(router.vim.keymap.macros['a']?.steps.length, 2);
    s.dispose();
  }, skip: skip);

  testWidgets('code-editor Vim: delete a line and paste it back, typing only in insert mode', (tester) async {
    final s = app();
    s.settings.vimCode = true;
    final m = ModuleDoc(id: 'c', name: 'c', source: 'one\ntwo\n');
    s.project.modules.add(m);
    s.selectedModuleId = m.id;
    final router = GlobalKey<KeyRouterState>();
    final text = TextEditingController(text: m.source);
    final focus = FocusNode();
    await tester.pumpWidget(MaterialApp(
      home: KeyRouter(
        key: router,
        state: s,
        screenArea: Area.builder,
        onView: (_) {},
        child: Scaffold(body: TextField(controller: text, focusNode: focus, maxLines: null)),
      ),
    ));
    // The Builder registers the code editor; here a small stand-in does the same through the router.
    String yank = '';
    router.currentState!.register(Area.code, focus, (id, count, arg) {
      final t = text.text;
      if (id == 'code.vim.deleteLine') {
        final e = t.indexOf('\n') + 1;
        yank = t.substring(0, e);
        text.text = t.substring(e);
        return true;
      }
      if (id == 'code.vim.paste') {
        text.text = t + yank;
        return true;
      }
      return id == 'code.vim.insert';
    });
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK); // normal mode: unbound keys don't type
    expect(text.text, 'one\ntwo\n');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    expect(router.currentState!.vim.mode, VimMode.insert);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(router.currentState!.vim.mode, VimMode.normal);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    expect(text.text, 'two\n');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    expect(text.text, 'two\none\n');
    s.dispose();
  }, skip: skip);

  test('auto-update swaps code that compiles after the pause, and light mode waits while playing', () async {
    final s = app();
    s.settings.liveDelayMs = 50;
    final kick = s.project.modules.first;
    s.editSource(kick.id, '${kick.source}\n// edited');
    // Engine compilation runs on a worker isolate; wait for the observable state transition
    // instead of assuming a fixed duration that can be too short on a busy CI runner.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (kick.edited && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(kick.edited, isFalse);
    final invalidSource = '${kick.source}\n((('; // doesn't compile: waits
    s.editSource(kick.id, invalidSource);
    // The async run temporarily copies the attempted source into runSource. Wait for
    // the failed compile to restore the last-good source instead of guessing its duration.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final failureDeadline = DateTime.now().add(const Duration(seconds: 5));
    while (!kick.edited && DateTime.now().isBefore(failureDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(kick.edited, isTrue);
    s.settings.lightMode = true;
    s.meters = const EngineMeters(playing: true);
    s.editSource(kick.id, '${kick.runSource}\n// light');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(kick.edited, isTrue);
    expect(s.project.toEngineJson(voices: 4), contains('"voices":4'));
    s.dispose();
  }, skip: skip);

  test('a pattern exported as .mid and as a MIDI 2.0 clip imports back with the same notes', () {
    if (skip) return;
    const src = '---\nkind: pattern\n---\n0 C3 1\n2 E3,G3 2 0.5\n';
    final dir = Directory.systemTemp.createTempSync('caw_midi');
    for (final clip in [false, true]) {
      final path = '${dir.path}/p${clip ? 2 : 1}';
      expect(Engine.exportPattern(src, path, clip: clip), isNull);
      final back = PatternDoc.parse(Engine.patternFromMidi(File(path).readAsBytesSync())).doc!;
      expect(back.notes.map((n) => (n.at, n.pitch)).toList(), [(Steps(0), 48.0), (Steps(2), 52.0), (Steps(2), 55.0)]);
    }
    expect(() => Engine.patternFromMidi(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    dir.deleteSync(recursive: true);
  });
}
