// Parsing of caw_engine_components results into typed component descriptors.
import 'dart:convert';

import 'package:caw/engine/component_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a component descriptor with ports, choices, flags and UI controls', () {
    final json = jsonDecode('''
{"ok":true,"components":[{"id":"org.example.drive","name":"Drive","version":3,"role":"effect",
 "latency_frames":32,"tail_frames":null,"max_state_bytes":16,"custom_ui_id":"",
 "ports":[{"id":"in","type":"audio","input":true,"layout":"stereo","channels":2,"summing":false},
          {"id":"out","type":"audio","input":false,"layout":"stereo","channels":2,"summing":false}],
 "parameters":[{"id":"mode","name":"Mode","unit":"","default":0,"min":0,"max":2,"step":1,"curve":"linear",
   "smoothing_frames":0,"automatable":true,"modulatable":false,"midi_mappable":true,"choices":["Clean","Warm","Crush"]},
  {"id":"cutoff","name":"","unit":"Hz","default":1000,"min":20,"max":20000,"step":0,"curve":"exponential",
   "smoothing_frames":64,"automatable":true,"modulatable":true,"midi_mappable":false,"choices":[]}],
 "ui_controls":[{"id":"mode","label":"Mode","parameter_id":"mode","kind":"dropdown","min":0,"max":2}]}]}
''') as Map<String, dynamic>;
    final list = NativeComponentInfo.listFromJson(json);
    expect(list, hasLength(1));
    final c = list.single;
    expect(c.label, 'Drive');
    expect(c.version, 3);
    expect(c.role, 'effect');
    expect(c.latencyFrames, 32);
    expect(c.tailFrames, isNull);  // never falls silent
    expect(c.ports.first.layout, 'stereo');
    expect(c.ports.first.channels, 2);
    expect(c.ports.last.input, isFalse);
    final mode = c.parameters.first;
    expect(mode.isChoice, isTrue);
    expect(mode.choices, ['Clean', 'Warm', 'Crush']);
    expect(mode.modulatable, isFalse);
    final cutoff = c.parameters.last;
    expect(cutoff.label, 'cutoff');  // no display name: the id
    expect(cutoff.exponential, isTrue);
    expect(cutoff.midiMappable, isFalse);
    expect(c.uiControls.single.kind, 'dropdown');
  });

  test('an error result lists no components', () {
    expect(NativeComponentInfo.listFromJson({'ok': false, 'error': 'no engine', 'components': []}), isEmpty);
  });
}
