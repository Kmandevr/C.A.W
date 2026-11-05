// The piano roll's note previews (owner, 2026-11-05): a tapped-in note plays its own length; a held or dragged note
// sounds until the finger lifts; a pitch change retriggers and a move in time doesn't; a selection sounds the notes
// that start first; a pitch point being dragged sounds at its pitch; "Hear notes" off is silent. Needs CAW_LIB.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/pattern_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the previews instead of only sending them.
class _Recorder extends AppState {
  final calls = <String>[];
  @override
  void previewOn(String layerId, int id, double pitch, double velocity) {
    calls.add('on $id ${pitch.round()}');
    super.previewOn(layerId, id, pitch, velocity);
  }

  @override
  void previewPitch(int id, double pitch) {
    calls.add('pitch $id ${pitch.round()}');
    super.previewPitch(id, pitch);
  }

  @override
  void previewOff(int id) {
    calls.add('off $id');
    super.previewOff(id);
  }

  List<String> get ons => calls.where((c) => c.startsWith('on')).toList();
  List<String> get offs => calls.where((c) => c.startsWith('off')).toList();
}

// At 1200 x 800: 44 px of keys, 28 px a step; the top note's row middle is at y = 140, a semitone is 16 px.
double _x(double step) => 44 + step * 28;
const _top = 140.0;

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  Future<(_Recorder, ModuleDoc)> open(WidgetTester tester, String body) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = _Recorder();
    s.engine = Engine.create();
    s.templates = Engine.templates();
    s.project = s.starterProject();
    final m = ModuleDoc(id: 'line', name: 'line', source: '---\nkind: pattern\n---\n$body');
    s.project.modules.add(m);
    // A layer with an instrument plays this pattern, so its notes have something to sound on.
    s.project.layers.firstWhere((l) => l.generatorId != null).clips.add(ClipDoc(id: 'clip-line', patternId: m.id));
    s.ready = true;
    s.starting = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PatternEditor(state: s, module: m))));
    return (s, m);
  }

  List<PatternNote> notes(ModuleDoc m) => PatternDoc.parse(m.source).doc!.notes;
  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(milliseconds: 300));

  test('Hear notes is on by default and saved', () {
    expect(const RollLook().hearNotes, isTrue);
    expect(RollLook.fromJson(const RollLook().copyWith(hearNotes: false).toJson()).hearNotes, isFalse);
    expect(RollLook.fromJson({'hear_notes': 'nope'}).hearNotes, isTrue);
  });

  testWidgets('a tapped-in note plays its own length; a held note sounds until it is let go', (tester) async {
    final (s, m) = await open(tester, '');
    expect(s.previewLayerFor(m.id), isNotNull);
    await tester.tapAt(const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 20));
    expect(s.ons, hasLength(1));
    expect(s.offs, isEmpty, reason: 'it plays on after the tap');
    // It ends once its length has played (within a frame).
    var ms = 20;
    while (s.offs.isEmpty && ms < 5000) {
      await tester.pump(const Duration(milliseconds: 5));
      ms += 5;
    }
    await settle(tester); // the edit reaches the module's source
    final secs = notes(m).single.len.toDouble() * 15 / s.project.bpm;
    expect(ms / 1000, closeTo(secs, 0.03), reason: s.calls.join(', '));
    // Holding an existing note: on at the touch, off at the lift.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    s.calls.clear();
    final g = await tester.startGesture(const Offset(300 + 2, 300));
    await tester.pump(const Duration(milliseconds: 200));
    expect((s.ons.length, s.offs.length), (1, 0), reason: s.calls.join(', '));
    await g.up();
    await settle(tester);
    expect(s.offs, hasLength(1), reason: s.calls.join(', '));
    s.dispose();
  }, skip: skip);

  testWidgets('a pitch change retriggers the note; a move in time does not', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    final g = await tester.startGesture(Offset(_x(2), _top));
    await tester.pump();
    await g.moveBy(const Offset(56, 0)); // two steps later, same pitch
    await tester.pump();
    expect(s.ons, hasLength(1), reason: s.calls.join(', '));
    await g.moveBy(const Offset(0, -32)); // two semitones up
    await tester.pump();
    expect(s.ons, hasLength(2), reason: s.calls.join(', '));
    final first = s.ons.first.split(' '), second = s.ons.last.split(' ');
    expect(second[1], first[1], reason: 'the same preview id: the old note ends first');
    expect(int.parse(second[2]) - int.parse(first[2]), 2);
    await g.up();
    await settle(tester);
    expect(s.offs, hasLength(1));
    expect(notes(m).single.at, Steps(2));
    s.dispose();
  }, skip: skip);

  testWidgets('a selection sounds the notes that start first, not the ones after', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n0 E3 4\n4 G3 4\n');
    // G3 is the top row (y = 140), E3 3 rows down, C3 7 rows down.
    await tester.tap(find.byTooltip('Select tool'));
    await tester.pump();
    await tester.dragFrom(Offset(_x(9), _top - 20), Offset(_x(0.5) - _x(9), _top + 7 * 16 + 10 - (_top - 20)));
    await tester.pump();
    await tester.tap(find.byTooltip('Draw tool'));
    await tester.pump();
    s.calls.clear();
    final g = await tester.startGesture(Offset(_x(6), _top));
    await tester.pump();
    expect(s.ons, hasLength(2), reason: 'C3 and E3 start first: ${s.calls.join(', ')}');
    await g.up();
    await settle(tester);
    expect(s.offs, hasLength(2));
    expect(notes(m), hasLength(3), reason: m.source);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    s.dispose();
  }, skip: skip);

  testWidgets('a pitch point being dragged sounds at its pitch; Hear notes off is silent', (tester) async {
    final (s, m) = await open(tester, '0 C3 4\n');
    final base = notes(m).single.pitch.round();
    await tester.tap(find.byTooltip('Curve tool'));
    await tester.pump();
    await tester.tapAt(const Offset(100, _top)); // selects the note
    await tester.pump(const Duration(milliseconds: 50));
    s.calls.clear();
    final g = await tester.startGesture(const Offset(130, _top));
    await tester.pump();
    await g.moveBy(const Offset(0, -24));
    await tester.pump();
    await g.moveBy(const Offset(0, -24)); // three semitones up in all
    await tester.pump();
    expect(s.ons, isNotEmpty, reason: s.calls.join(', '));
    expect(s.calls.where((c) => c.startsWith('pitch')).last.split(' ').last, '${base + 3}', reason: s.calls.join(', '));
    await g.up();
    await settle(tester);
    expect(s.offs, hasLength(1));
    // Off: nothing sounds.
    await tester.tap(find.byTooltip('Draw tool'));
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hear notes'));
    await tester.pumpAndSettle();
    expect(s.settings.roll.hearNotes, isFalse);
    s.calls.clear();
    await tester.tapAt(const Offset(600, 400));
    await settle(tester);
    expect(s.calls, isEmpty);
    s.dispose();
  }, skip: skip);
}
