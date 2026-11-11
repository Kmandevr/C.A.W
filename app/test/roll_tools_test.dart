// The piano roll's tools from WP-K2: closing an empty pattern writes nothing; the quantize sheet; step input; the
// connect and tremolo generators (needs CAW_LIB).
import 'dart:io';

import 'dart:async';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

/// A MIDI keyboard for the test; members the interface may grow are empty streams (getters) or do nothing.
class _Keyboard implements MidiInput {
  final _c = StreamController<MidiMessage>.broadcast();
  void play(int status, int a, int b) => _c.add(MidiMessage(status, a, b, 'Test keys'));
  @override
  Stream<MidiMessage> get messages => _c.stream;
  @override
  Stream<List<String>> get devices => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => i.isGetter ? const Stream<Never>.empty() : null;
}

List<PatternNote> _notes(ModuleDoc m) => PatternDoc.parse(m.source).doc!.notes;

Future<void> _menu(WidgetTester tester, String item) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  final entry = find.ancestor(of: find.text(item), matching: find.byWidgetPredicate((w) => w is PopupMenuEntry)).first;
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<AppState> _state(String source, {String id = 'line'}) async {
  final s = AppState();
  s.engine = Engine.create();
  s.project = s.starterProject();
  s.project.modules.add(ModuleDoc(id: id, name: id, source: source));
  s.ready = true;
  s.starting = false;
  return s;
}

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  testWidgets('closing a truly empty pattern writes nothing and trips no assertion (#169)', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = await _state('');
    final m = s.project.module('line')!;
    final show = ValueNotifier(true);
    // The app rebuilds on every AppState change, as the Build tabs do.
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: Listenable.merge([s, show]),
                builder: (_, _) => show.value ? PatternEditor(state: s, module: m) : const SizedBox()))));
    show.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(m.source, '', reason: 'an unedited empty pattern stays empty');
    s.dispose();
  }, skip: skip != null);

  testWidgets('an edit still pending when the roll closes is written after the frame, without an assertion', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = await _state('');
    final m = s.project.module('line')!;
    final show = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(
                listenable: Listenable.merge([s, show]),
                builder: (_, _) => show.value ? PatternEditor(state: s, module: m) : const SizedBox()))));
    await tester.tapAt(const Offset(120, 200)); // draws a note; the write waits 150 ms
    show.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(m.source.split('---').last.trim(), isNotEmpty, reason: m.source);
    s.dispose();
  }, skip: skip != null);

  testWidgets('the quantize sheet previews on the roll, Apply is one undo step, Cancel puts the notes back', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = await _state('---\nkind: pattern\n---\n0.4 C3 1\n1.3 D3 1\n');
    final m = s.project.module('line')!;
    final before = m.source;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await _menu(tester, 'Quantize…');
    expect(find.text('Quantize 2 notes'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(m.source, before, reason: 'the preview is only on screen');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(m.source, before);
    // Swing all the way: the second note goes to the swung line at 1.5.
    await _menu(tester, 'Quantize…');
    await tester.drag(find.byKey(const ValueKey('quantize-swing')), const Offset(600, 0));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_notes(m).map((n) => n.at), [Steps.zero, Steps(3, 2)], reason: m.source);
    s.dispose();
  }, skip: skip != null);

  testWidgets('step input: the roll keys enter notes a grid step apart, held keys make a chord, Rest skips',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    // A note far right puts C3 four rows from the top.
    final s = await _state('---\nkind: pattern\n---\n32 C3 1\n');
    final m = s.project.module('line')!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await _menu(tester, 'Step input');
    expect(find.byKey(const ValueKey('roll-step-bar')), findsOneWidget);
    // Rows under the toolbar (48), the step bar (36) and the ruler (20), 16 px each: C3 at 176, D3 144, E3 112.
    await tester.tapAt(const Offset(20, 176));
    await tester.pump();
    final d = await tester.startGesture(const Offset(20, 144));
    final e = await tester.startGesture(const Offset(20, 112));
    await d.up();
    await e.up();
    await tester.pump();
    await tester.tap(find.text('Rest'));
    await tester.pump();
    await tester.tapAt(const Offset(20, 176));
    await tester.pump(const Duration(milliseconds: 300));
    final entered = _notes(m).where((n) => n.at < Steps(32)).map((n) => (n.at.toDouble(), n.pitch, n.len.toDouble()));
    expect(entered, [(0.0, 48.0, 1.0), (1.0, 50.0, 1.0), (1.0, 52.0, 1.0), (3.0, 48.0, 1.0)], reason: m.source);
    // A MIDI keyboard enters notes too, through the app's MIDI input.
    final keys = _Keyboard();
    LiveMidi.current = LiveMidi(s, keys);
    await tester.tap(find.text('Done'));
    await tester.pump();
    await _menu(tester, 'Step input');
    keys.play(0x90, 60, 100);
    keys.play(0x80, 60, 0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_notes(m).where((n) => n.pitch == 60).map((n) => n.at), [Steps(4)], reason: m.source);
    await tester.tap(find.text('Done'));
    await tester.pump();
    keys.play(0x90, 62, 100);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_notes(m).where((n) => n.pitch == 62), isEmpty, reason: 'off: the keyboard only plays');
    LiveMidi.current?.dispose();
    LiveMidi.current = null;
    s.dispose();
  }, skip: skip != null);

  testWidgets('the menu connects notes and makes a tremolo, with a preview that follows its controls', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    final s = await _state('---\nkind: pattern\n---\n0 C3 2\n4 E3 2\n');
    final m = s.project.module('line')!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    await _menu(tester, 'Connect notes');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_notes(m).first.len, Steps(4), reason: m.source);
    expect(_notes(m).first.expr.bend.last.v, 4, reason: m.source);
    await _menu(tester, 'Tremolo…');
    final preview = find.byKey(const ValueKey('tremolo-preview'));
    expect(preview, findsOneWidget);
    CustomPaint paint() => tester.widget<CustomPaint>(find.descendant(of: preview, matching: find.byType(CustomPaint)));
    final sine = paint().painter;
    await tester.tap(find.text('Square'));
    await tester.pump();
    expect(paint().painter!.shouldRepaint(sine!), isTrue, reason: 'the preview follows the wave');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_notes(m).every((n) => n.expr.press.isNotEmpty), isTrue, reason: m.source);
    s.dispose();
  }, skip: skip != null);

  testWidgets('goldens: the quantize sheet with a live preview and the step bar, at phone size', (tester) async {
    final s = await _state('---\nkind: pattern\n---\n0.4 C3 1\n1.3 D3 1\n2.6 E3 1\n3.8 G3 2\n');
    final m = s.project.module('line')!;
    await pumpGolden(tester, Scaffold(body: SafeArea(child: PatternEditor(state: s, module: m))), goldenSizes['phone']!);
    await _menu(tester, 'Step input');
    await tester.pumpAndSettle();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_step_input_phone.png'));
    await tester.tap(find.text('Done'));
    await _menu(tester, 'Quantize…');
    await tester.drag(find.byKey(const ValueKey('quantize-swing')), const Offset(80, 0));
    await tester.pumpAndSettle();
    await expectLater(goldenScreen, matchesGoldenFile('goldens/roll_quantize_phone.png'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    s.dispose();
  }, skip: skip != null);
}
