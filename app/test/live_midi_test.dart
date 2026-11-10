// Tests MIDI keyboard input: parsing messages, playing the selected track, and a recorded take becoming a pattern
// clip at the bar where recording began.
import 'dart:async';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMidi implements MidiInput {
  final notes = StreamController<MidiMessage>.broadcast(sync: true);
  final names = StreamController<List<String>>.broadcast(sync: true);
  @override
  Stream<MidiMessage> get messages => notes.stream;
  @override
  Stream<List<String>> get devices => names.stream;
}

class WatchedState extends AppState {
  final on = <(String, double, double)>[];
  int offs = 0;
  @override
  void previewOn(String layerId, int id, double pitch, double velocity) => on.add((layerId, pitch, velocity));
  @override
  void previewOff(int id) => offs++;
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
}
