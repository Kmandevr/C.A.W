// Model tests: project files round-trip, the engine JSON uses run code, header parsing and layer length choices.
import 'dart:convert';

import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc sample() => ProjectDoc(id: 'p1', name: 'Test', bpm: 140, modules: [
      ModuleDoc(id: 'm1', name: 'Lead', source: 't*2', runSource: 't', params: {'shift': 6}),
      ModuleDoc(id: 'fx', name: 'Crush', source: '---\nkind: effect\n---\nin'),
    ], layers: [
      LayerDoc(id: 'l1', name: 'Lead', color: 2, generatorId: 'm1', effectIds: ['fx'], lengthSteps: 48, volume: 0.5, pan: -0.3, solo: true),
    ]);

void main() {
  test('project file round-trips', () {
    final p = sample();
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
    expect(back.modules.first.edited, isTrue);
    expect(back.layers.first.chain, ['m1', 'fx']);
  });

  test('engine JSON carries the code last run and the layer chain', () {
    final j = jsonDecode(sample().toEngineJson()) as Map<String, dynamic>;
    expect(j['caw_project'], 1);
    expect((j['modules'] as List).first['source'], 't');
    final layer = (j['layers'] as List).first as Map<String, dynamic>;
    expect(layer['chain'], ['m1', 'fx']);
    expect(layer['length_steps'], 48);
    expect(j['audition_only'], false);
    final a = jsonDecode(sample().toEngineJson(audition: ['m1'], auditionOnly: true)) as Map<String, dynamic>;
    expect(a['audition'], {'chain': ['m1']});
    expect(a['audition_only'], true);
  });

  test('header values', () {
    const src = '---\ncaw: 1\nkind: effect  # comment\nname: Fold\n---\nin';
    expect(headerValue(src, 'kind'), 'effect');
    expect(headerValue(src, 'name'), 'Fold');
    expect(headerValue('t*2', 'name'), isNull);
  });

  test('loop seconds and length choices follow the meter', () {
    final p = ProjectDoc(id: 'x', name: 'x', bpm: 120, beatsPerBar: 3, loopBars: 2);
    expect(p.loopSteps, 24);
    expect(p.loopSeconds, closeTo(3.0, 1e-9));
    final c = lengthChoices(12);
    expect(c.first.$1, 0);
    expect(c.firstWhere((e) => e.$2 == '1 bar').$1, 12);
  });
}
