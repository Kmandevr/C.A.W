// MIDI out (engine API 47) in the app's model: a track's midiOut round trips, existing files stay byte-identical,
// the engine JSON carries it without an instrument, effects or sends, the platform output is a no-op, and (with
// CAW_LIB) the engine queues the track's notes and the clock for a sender.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/project.dart';
import 'package:caw/platform/midi_output.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('midiOut round trips; a track without one saves exactly as before', () {
    final plain = LayerDoc(id: 't', name: 'T', color: 0);
    expect(plain.toJson().containsKey('midi_out'), isFalse);
    final before = jsonEncode(plain.toJson());
    final again = LayerDoc.fromJson(jsonDecode(before) as Map<String, dynamic>);
    expect(again.midiOut, isNull);
    expect(jsonEncode(again.toJson()), before);

    final l = LayerDoc(id: 'm', name: 'Synth', color: 1, midiOut: MidiOutDoc(port: 3, channel: 10, program: 7, bendRange: 12));
    final back = LayerDoc.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>);
    expect(back.midiOut!.port, 3);
    expect(back.midiOut!.channel, 10);
    expect(back.midiOut!.program, 7);
    expect(back.midiOut!.bendRange, 12);
    expect(l.toJson()['midi_out'], {'port': 3, 'channel': 10, 'program': 7, 'bend_range': 12.0});
    // Defaults stay out; untrusted values are held to their ranges.
    expect(MidiOutDoc().toJson(), {'port': 0, 'channel': 1});
    final wild = MidiOutDoc.fromJson({'port': 99, 'channel': -4, 'program': 300, 'bend_range': 0.1})!;
    expect([wild.port, wild.channel, wild.program, wild.bendRange], [15, 1, 127, 1.0]);
    expect(MidiOutDoc.fromJson('junk'), isNull);
    expect(LayerDoc.fromJson({'id': 'f', 'folder': true, 'midi_out': {'port': 1}}).midiOut, isNull);
  });

  test('the engine JSON sends midiOut instead of an instrument, effects or sends', () {
    final l = LayerDoc(id: 'm', name: 'Synth', color: 0,
        instrument: ComponentUseDoc('org.caw.synth.flagship'),
        components: [ComponentUseDoc('org.caw.filter')],
        midiOut: MidiOutDoc(port: 2, channel: 5));
    final p = ProjectDoc(id: 'p', name: 'P', bpm: 120, modules: [], layers: [l]);
    final layer = (jsonDecode(p.toEngineJson())['layers'] as List).single as Map<String, dynamic>;
    expect(layer['midiOut'], {'port': 2, 'channel': 5});
    expect(layer.containsKey('instrument'), isFalse);
    expect(layer.containsKey('components'), isFalse);
    expect(layer.containsKey('sends'), isFalse);
    // Without it the same track plays its instrument as before.
    l.midiOut = null;
    final inst = (jsonDecode(p.toEngineJson())['layers'] as List).single as Map<String, dynamic>;
    expect(inst.containsKey('midiOut'), isFalse);
    expect(jsonEncode(inst['instrument']), contains('org.caw.synth.flagship'));
  });

  test('the platform output is the no-op one until a sender is built', () async {
    final out = platformMidiOutput();
    expect(out.available, isFalse);
    out.send([const MidiOutEvent(1, 0, [0x90, 60, 100])]);
    await out.route(0, 'x');
    expect(await out.devices.isEmpty, isTrue);
    await out.close();
    expect(const MidiOutEvent(5, 1, [0xF8]), const MidiOutEvent(5, 1, [0xF8]));
  });

  test('with the engine: a MIDI-out track and the clock reach the drain (needs CAW_LIB)', () async {
    final e = Engine.create();
    final l = LayerDoc(id: 'm', name: 'Synth', color: 0, midiOut: MidiOutDoc(port: 1, channel: 2, program: 4));
    final p = ProjectDoc(id: 'p', name: 'P', bpm: 120, modules: [], layers: [l]);
    await e.setProject(p.toEngineJson());
    e.setMidiClockOut(1);
    e.setMidiOutPortOffset(1, 0);
    e.play();
    e.pullForTest(480);
    final got = e.midiOutDrain();
    expect(got.map((m) => m.bytes.first), containsAll([0xFA, 0xF8, 0xC1]));
    expect(got.firstWhere((m) => m.bytes.first == 0xC1).bytes, [0xC1, 4]);
    expect(e.midiOutDropped, 0);
    expect(e.midiClockIn(const [0xF8], 0), 1);
    expect(e.midiClockInBpm, 0);
    e.dispose();
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
