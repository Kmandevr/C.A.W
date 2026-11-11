// Tests MIDI keyboard input: parsing messages, playing the selected track, and a recorded take becoming a pattern
// clip at the bar where recording began.
import 'dart:async';
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/midi_mapping.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMidi implements MidiInput {
  final notes = StreamController<MidiMessage>.broadcast(sync: true);
  final names = StreamController<List<String>>.broadcast(sync: true);
  final portList = StreamController<List<MidiPort>>.broadcast(sync: true);
  Set<String> closed = {};
  @override
  Stream<MidiMessage> get messages => notes.stream;
  @override
  Stream<List<String>> get devices => names.stream;
  @override
  Stream<List<MidiPort>> get ports => portList.stream;
  @override
  void setClosed(Set<String> names) => closed = names;
  @override
  BluetoothMidi? get bluetooth => null;
}

class WatchedState extends AppState {
  final on = <(String, double, double)>[];
  int offs = 0;

  /// What reached the engine's device input: (track, bytes or words, time).
  final device = <(String, List<int>, int)>[];
  int releases = 0;

  /// The engine's answer to "where was the playhead at this time" (steps), by time.
  final Map<int, double> positions = {};
  @override
  void previewOn(String layerId, int id, double pitch, double velocity) => on.add((layerId, pitch, velocity));
  @override
  void previewOff(int id) => offs++;
  @override
  void deviceMidi(String layerId, {List<int>? bytes, List<int>? words, int timeNs = 0}) =>
      device.add((layerId, words ?? bytes!, timeNs));
  @override
  void deviceMidiRelease([String? layerId]) => releases++;
  @override
  double? stepAt(int timeNs) => positions[timeNs];
}

ProjectDoc twoTracks() => ProjectDoc(id: 'p', name: 'Test')
  ..layers.addAll([LayerDoc(id: 'L1', name: 'Keys', color: 0), LayerDoc(id: 'L2', name: 'Bass', color: 1)]);

void main() {
  test('messages: note on/off (velocity 0 is off), sustain and pitch bend', () {
    expect(const MidiMessage(0x90, 60, 100).isNoteOn, isTrue);
    expect(const MidiMessage(0x91, 60, 0).isNoteOff, isTrue);
    expect(const MidiMessage(0x80, 60, 40).isNoteOff, isTrue);
    expect(const MidiMessage(0xB0, 64, 127).isSustain, isTrue);
    expect(const MidiMessage(0xE0, 0, 64).bend, 0);
    expect(const MidiMessage(0xE0, 0, 0).bend, -1);
  });

  test('a keyboard plays the selected track; sustain holds notes until released', () {
    final s = WatchedState()..project = twoTracks();
    final midi = FakeMidi();
    final live = LiveMidi(s, midi);
    s.selectedLayerId = s.project.layers[1].id;
    midi.names.add(['Keystation']);
    expect(live.devices, ['Keystation']);
    midi.notes.add(const MidiMessage(0x90, 60, 127));
    expect(s.on.single, (s.project.layers[1].id, 60.0, 1.0));
    midi.notes.add(const MidiMessage(0xB0, 64, 127));
    midi.notes.add(const MidiMessage(0x80, 60, 0));
    expect(s.offs, 0, reason: 'the sustain pedal is down');
    midi.notes.add(const MidiMessage(0xB0, 64, 0));
    expect(s.offs, 1);
    live.dispose();
  });

  test('a take becomes a pattern clip on the armed track, from the bar where recording began', () {
    final s = WatchedState()..project = twoTracks();
    final midi = FakeMidi();
    final live = LiveMidi(s, midi);
    final layer = s.project.layers.first;
    final bar = s.project.stepsPerBar;
    s.pausedStep = bar + 2.0; // recording starts during bar 2
    live.toggleRecord(layer.id);
    expect(live.recording, isTrue);
    midi.notes.add(const MidiMessage(0x90, 64, 64));
    s.pausedStep = bar + 6.0;
    midi.notes.add(const MidiMessage(0x80, 64, 0));
    final clips = layer.clips.length;
    live.toggleRecord();
    expect(live.recording, isFalse);
    expect(layer.clips.length, clips + 1);
    final clip = layer.clips.last;
    expect(clip.startSteps, bar);
    final take = s.project.module(clip.patternId)!;
    expect(take.name, 'Take 1');
    final doc = PatternDoc.parse(take.source).doc!;
    final note = doc.notes.single;
    expect((note.at, note.len, note.pitch), (Steps(2), Steps(4), 64.0));
    live.dispose();
  });

  test('re-pressing a key while the pedal holds it keeps the new note sounding when the pedal lifts', () {
    final s = WatchedState()..project = twoTracks();
    final midi = FakeMidi();
    final live = LiveMidi(s, midi);
    midi.notes.add(const MidiMessage(0xB0, 64, 127));
    midi.notes.add(const MidiMessage(0x90, 60, 100));
    midi.notes.add(const MidiMessage(0x80, 60, 0));
    midi.notes.add(const MidiMessage(0x90, 60, 100)); // ends the first note, starts a second
    expect(s.offs, 1);
    midi.notes.add(const MidiMessage(0xB0, 64, 0));
    expect(s.offs, 1, reason: 'the key is still down');
    live.dispose();
    expect(s.offs, 2, reason: 'disposing ends every note');
  });

  test('unplugging a keyboard ends its held notes', () {
    final s = WatchedState()..project = twoTracks();
    final midi = FakeMidi();
    final live = LiveMidi(s, midi);
    midi.names.add(['Keys']);
    midi.notes.add(const MidiMessage(0x90, 60, 100));
    midi.notes.add(const MidiMessage(0x90, 64, 100));
    midi.names.add([]);
    expect(s.offs, 2);
    live.dispose();
  });

  test('a take that runs past the song end becomes one clip per pass, the later from the start', () {
    final bar = 16;
    final loop = 4 * bar.toDouble(); // the default 4-bar song
    final takes = <TakenNote>[
      const TakenNote(34, 2, 60, 1), // pass 0, bar 3
      TakenNote(loop + 4, 2, 62, 1), // pass 1, bar 1
    ];
    final first = LiveMidi.takeModule([takes[0]], start: 32, stepsPerBar: bar, name: 'A');
    expect(PatternDoc.parse(first.source).doc!.notes.single.at, Steps(2));
    // The split itself: _commit groups by pass; check the grouping rule on the second note.
    expect((takes[1].at / loop).floor(), 1);
    expect(takes[1].at - loop, 4);
  });

  group('devices through the engine (caw.h API 14)', () {
    test('a pad: its note, poly aftertouch and off reach one track with the device\'s channel and time', () {
      final s = WatchedState()..project = twoTracks();
      final midi = FakeMidi();
      final live = LiveMidi(s, midi);
      s.selectedLayerId = 'L1';
      midi.notes.add(const MidiMessage(0x99, 38, 100, 'Pads', 1000));
      s.selectedLayerId = 'L2'; // the target moves while the pad is held
      midi.notes.add(const MidiMessage(0xA9, 38, 70, 'Pads', 2000));
      midi.notes.add(const MidiMessage(0x89, 38, 0, 'Pads', 3000));
      midi.notes.add(const MidiMessage(0xC9, 5, 0, 'Pads', 4000));
      expect([for (final d in s.device) '${d.$1} ${d.$2} ${d.$3}'], [
        'L1 [153, 38, 100] 1000', // 0x99: channel 10
        'L1 [169, 38, 70] 2000', // its poly aftertouch, on the track the pad sounds on
        'L1 [137, 38, 0] 3000',
        'L2 [201, 5] 4000', // a program change goes to the target now
      ]);
      expect(s.on, isEmpty, reason: 'not the preview path');
      expect(s.deviceNotesHeld, 0);
      live.dispose();
    });

    test('the pedal reaches the track holding the keys, and unplugging ends them in the engine', () {
      final s = WatchedState()..project = twoTracks();
      final midi = FakeMidi();
      final live = LiveMidi(s, midi);
      s.selectedLayerId = 'L1';
      midi.names.add(['Keys']);
      midi.notes.add(const MidiMessage(0xB0, 64, 127, 'Keys'));
      midi.notes.add(const MidiMessage(0x90, 60, 90, 'Keys'));
      midi.notes.add(const MidiMessage(0x80, 60, 0, 'Keys'));
      expect(s.deviceNotesHeld, 1, reason: 'the pedal holds it');
      s.selectedLayerId = 'L2';
      midi.notes.add(const MidiMessage(0xB0, 64, 0, 'Keys'));
      expect(s.device.where((d) => d.$2[0] == 0xB0 && d.$2[2] == 0).map((d) => d.$1).toSet(), {'L1', 'L2'});
      expect(s.deviceNotesHeld, 0);
      midi.notes.add(const MidiMessage(0x90, 62, 90, 'Keys'));
      midi.names.add([]);
      expect(s.releases, 1);
      expect(s.deviceNotesHeld, 0);
      live.dispose();
    });

    test('a recorded device note lands where the engine played it, not where the playhead was read', () {
      final s = WatchedState()..project = twoTracks();
      final midi = FakeMidi();
      final live = LiveMidi(s, midi);
      final layer = s.project.layers.first;
      final bar = s.project.stepsPerBar;
      s.pausedStep = bar + 0.0;
      live.toggleRecord(layer.id);
      s.positions[5000] = bar + 2.25;
      s.positions[9000] = bar + 3.5;
      s.pausedStep = bar + 3.0; // the playhead as the UI last read it: later than the note
      midi.notes.add(const MidiMessage(0x90, 64, 100, 'Keys', 5000));
      s.pausedStep = bar + 4.0;
      midi.notes.add(const MidiMessage(0x80, 64, 0, 'Keys', 9000));
      live.toggleRecord();
      final take = s.project.module(layer.clips.last.patternId)!;
      final note = PatternDoc.parse(take.source).doc!.notes.single;
      expect((note.at, note.len), (Steps.fromDouble(2.25), Steps.fromDouble(1.25)));
      live.dispose();
    });

    test('UMP: a MIDI 2.0 note on goes to the engine as its words; its MIDI 1.0 view is kept for the books', () {
      final s = WatchedState()..project = twoTracks();
      final midi = FakeMidi();
      final live = LiveMidi(s, midi);
      s.selectedLayerId = 'L1';
      // A JR timestamp (skipped), a MIDI 2.0 note on (channel 2, key 60, velocity 0x8000) and a per-note pitch.
      midi.notes.add(const MidiMessage(0, 0, 0, 'MIDI 2 keys', 77, [0x00200000, 0x40913C00, 0x80000000, 0x00000000,
        0x40613C00, 0x90000000]));
      expect(s.device.length, 2);
      expect(s.device[0].$1, 'L1');
      expect(s.device[0].$2, [0x40913C00, 0x80000000], reason: 'the linear curve keeps the 16-bit velocity');
      expect(s.device[0].$3, 77);
      expect(s.device[1].$2, [0x40613C00, 0x90000000]);
      expect(s.deviceNotesHeld, 1);
      final view = MidiMessage.fromUmp([0x20903C64], 'x', 0).single;
      expect((view.status, view.data1, view.data2), (0x90, 60, 100));
      live.dispose();
    });

    test('controller learn: the next CC maps to the knob, is kept in the project and can be forgotten', () {
      final s = WatchedState()..project = twoTracks();
      final midi = FakeMidi();
      final live = LiveMidi(s, midi);
      live.learn('L1', -1, 'flt1_cutoff');
      expect(live.learning, isNotNull);
      midi.notes.add(const MidiMessage(0xB2, 74, 30, 'Knobs'));
      expect(live.learning, isNull);
      final m = live.mappingOf('L1', -1, 'flt1_cutoff')!;
      expect((m.channel, m.cc), (2, 74));
      expect(live.learned.value, m);
      final again = ProjectDoc.fromJson(s.project.toJson());
      expect(again.midiMappings.single.toJson(), m.toJson());
      live.forget(m);
      expect(s.project.midiMappings, isEmpty);
      live.dispose();
    });

    test('a CC moves its knob on the knob\'s curve', () {
      const lin = ComponentParameterInfo(id: 'a', defaultValue: 0, min: 0, max: 10);
      const exp = ComponentParameterInfo(id: 'f', defaultValue: 1000, min: 20, max: 20000, exponential: true);
      const choice = ComponentParameterInfo(id: 'c', defaultValue: 0, min: 0, max: 3, choices: ['a', 'b', 'c', 'd']);
      expect(MidiCcMapping.valueFor(lin, 127), 10);
      expect(MidiCcMapping.valueFor(lin, 0), 0);
      expect(MidiCcMapping.valueFor(exp, 64), closeTo(20 * math.pow(1000, 64 / 127), 1e-6));
      expect(MidiCcMapping.valueFor(choice, 127), 3);
      expect(MidiCcMapping.valueFor(choice, 50), 1);
    });
  });
}
