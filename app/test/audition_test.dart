// Solo preview (the audition) of a pattern plays it through the C++ instrument and effects of a track that uses it.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a pattern previews through its track\'s C++ instrument and effects', () {
    final synth = ComponentUseDoc('org.caw.synth.flagship', {'flt1_cutoff': 800});
    final width = ComponentUseDoc('org.caw.stereo.width', {'width': 1.5});
    final s = AppState()
      ..project = ProjectDoc(id: 'p', name: 'T', modules: [
        ModuleDoc(id: 'pat', name: 'Riff', source: '---\nkind: pattern\n---\n0 C4 4 1\n'),
      ], layers: [
        LayerDoc(id: 'lead', name: 'Lead', color: 0, instrument: synth, components: [width],
            clips: [ClipDoc(id: 'c', patternId: 'pat')]),
      ]);
    s.selectedModuleId = 'pat';
    final pv = s.preview!;
    expect(pv.chain, isEmpty);
    expect(pv.pattern, 'pat');
    expect(pv.instrument, same(synth));
    expect(pv.components, [width]);
    final json = jsonDecode(s.project.toEngineJson(
        audition: pv.chain, auditionPattern: pv.pattern, auditionInstrument: pv.instrument,
        auditionComponents: pv.components, auditionOnly: true)) as Map<String, dynamic>;
    expect((json['audition'] as Map)['instrument'], synth.toJson());
    expect(json['audition_only'], true);
  });
}
