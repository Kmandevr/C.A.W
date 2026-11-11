// MIDI record modes (gap 3): overdub adds notes into the clip under them, replace clears the clip's notes over the
// time recorded first, notes outside any clip make a new clip, the toast's Undo takes it all back; and the take
// chip steps through a loop recording's takes.
import 'dart:async';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/record_modes.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:caw/ui/arrange/take_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMidi implements MidiInput {
  final notes = StreamController<MidiMessage>.broadcast(sync: true);
  final names = StreamController<List<String>>.broadcast(sync: true);
  @override
  Stream<MidiMessage> get messages => notes.stream;
  @override
  Stream<List<String>> get devices => names.stream;
}

class QuietState extends AppState {
  QuietState() : super(settings: Settings());
  @override
  void previewOn(String layerId, int id, double pitch, double velocity) {}
  @override
  void previewOff(int id) {}
}

const riff = '---\ncaw: 1\nkind: pattern\nname: Riff\nlength: 16\n---\n0 C3 2 1\n8 E3 2 1\n';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Modes', modules: [
      ModuleDoc(id: 'riff', name: 'Riff', source: riff),
    ], layers: [
      LayerDoc(id: 'k', name: 'Keys', color: 0, clips: [ClipDoc(id: 'c', patternId: 'riff', startSteps: 16, lengthSteps: 32)]),
    ]);

void main() {
  late QuietState s;
  late FakeMidi midi;
  late LiveMidi live;
  setUp(() {
    s = QuietState()..project = project();
    midi = FakeMidi();
    live = LiveMidi(s, midi);
  });
  tearDown(() {
    live.dispose();
    s.dispose();
  });

  LayerDoc keys() => s.project.layers.single;
  List<(double, double)> notesOf(String id) => [
        for (final n in PatternDoc.parse(s.project.module(id)!.source).doc!.notes) (n.at.toDouble(), n.pitch),
      ]..sort((a, b) => a.$1.compareTo(b.$1));

  /// Records [pitch] from step [on] to [off] (song steps), starting at [from] and stopping at [stop].
  void record(double from, List<(int, double, double)> played, double stop) {
    s.pausedStep = from;
    live.toggleRecord('k');
    for (final (pitch, on, off) in played) {
      s.pausedStep = on;
      midi.notes.add(MidiMessage(0x90, pitch, 100));
      s.pausedStep = off;
      midi.notes.add(MidiMessage(0x80, pitch, 0));
    }
    s.pausedStep = stop;
    live.toggleRecord();
  }

  test('the record mode is a setting, takes by default', () {
    expect(Settings().midiRecordMode, MidiRecordMode.takes);
    final back = Settings()..fromJson((Settings()..midiRecordMode = MidiRecordMode.replace).toJson());
    expect(back.midiRecordMode, MidiRecordMode.replace);
  });

  test('overdub adds the notes into the clip they were played over, looping into its pattern', () {
    s.settings.midiRecordMode = MidiRecordMode.overdub;
    // Step 20 is the clip's step 4; step 36 is its step 20, which is step 4 of the pattern's second loop.
    record(18, [(67, 20, 22), (72, 36, 37)], 40);
    expect(keys().clips, hasLength(1));
    expect(notesOf('riff'), [(0.0, 48.0), (4.0, 67.0), (4.0, 72.0), (8.0, 52.0)]);
    expect(live.lastTake.value!.restore.keys, ['riff']);
    live.discardTake();
    expect(s.project.module('riff')!.source, riff);
  });

  test('replace clears the notes heard over the time recorded, then adds', () {
    s.settings.midiRecordMode = MidiRecordMode.replace;
    // Recording 22..28 (pattern steps 6..12) covers the E3 at 8, not the C3 at 0.
    record(22, [(60, 23, 24)], 28);
    expect(notesOf('riff'), [(0.0, 48.0), (7.0, 60.0)]);
  });

  test('notes outside any clip become a new clip, as in the default mode', () {
    s.settings.midiRecordMode = MidiRecordMode.overdub;
    record(64, [(60, 66, 68)], 70);
    expect(keys().clips, hasLength(2));
    final made = keys().clips.last;
    expect(made.startSteps, 64);
    expect(s.project.module('riff')!.source, riff);
    live.discardTake();
    expect(keys().clips, hasLength(1));
  });

  test('takes mode makes a new clip over the old one', () {
    record(18, [(67, 20, 22)], 24);
    expect(keys().clips, hasLength(2));
    expect(s.project.module('riff')!.source, riff);
  });

  group('takes', () {
    setUp(() {
      s.project.modules.addAll([
        ModuleDoc(id: 't1', name: 'Take 1', source: riff),
        ModuleDoc(id: 't2', name: 'Take 2', source: riff),
        ModuleDoc(id: 't3', name: 'Take 3', source: riff),
      ]);
      keys().clips.single
        ..takes = ['t1', 't2', 't3']
        ..patternId = 't3';
    });

    test('stepping wraps round', () {
      final c = keys().clips.single;
      s.stepTake(keys(), c, 1);
      expect(c.patternId, 't1');
      s.stepTake(keys(), c, -1);
      expect(c.patternId, 't3');
      s.selectTake(keys(), c, 1);
      expect(c.patternId, 't2');
    });

    testWidgets('the chip shows n/N; its arrows and a swipe step', (tester) async {
      final c = keys().clips.single;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: ListenableBuilder(listenable: s,
        builder: (_, _) => TakeChip(state: s, layer: keys(), clip: c, color: Colors.green))))));
      expect(find.text('3/3'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);
      await tester.drag(find.byKey(ValueKey('take-chip-${c.id}')), const Offset(56, 0)); // past the drag slop, then one 24 px step
      await tester.pump();
      expect(c.patternId, 't3');
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
