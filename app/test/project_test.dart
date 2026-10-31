// Model tests: project files round-trip, the engine JSON uses run code, header parsing and layer length choices.
import 'dart:convert';

import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc sample() => ProjectDoc(id: 'p1', name: 'Test', bpm: 140, globals: {'swing': 0.2}, modules: [
      ModuleDoc(id: 'm1', name: 'Lead', source: 't*2', runSource: 't', params: {'shift': 6}),
      ModuleDoc(id: 'fx', name: 'Crush', source: '---\nkind: effect\n---\nin'),
    ], layers: [
      LayerDoc(id: 'l1', name: 'Lead', color: 2, generatorId: 'm1', effectIds: ['fx'], lengthSteps: 48, volume: 0.5, pan: -0.3, solo: true),
      LayerDoc(id: 'l2', name: 'Notes', color: 1, generatorId: 'm1', patternId: 'pat'),
    ]);

void main() {
  test('project file round-trips', () {
    final p = sample();
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
    expect(back.modules.first.edited, isTrue);
    expect(back.layers.first.chain, ['m1', 'fx']);
  });

  test('folder hierarchy and automation survive app and engine serialization', () {
    final p = sample();
    p.layers.add(LayerDoc(id: 'group', name: 'Group', color: 3, isFolder: true, busEnabled: true));
    p.layers[0].parentId = 'group';
    p.layers[1].automation.add(AutomationLaneDoc(target: 'pan', points: [
      AutomationPointDoc(step: 0, value: -1), AutomationPointDoc(step: 16, value: 1),
    ]));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.layers[0].parentId, 'group');
    expect(back.layers.last.isFolder, isTrue);
    expect(back.layers[1].automation.single.points.last.value, 1);
    final engine = jsonDecode(back.toEngineJson()) as Map<String, dynamic>;
    final layers = engine['layers'] as List;
    expect(layers[0]['parent'], 'group');
    expect(layers.last['folder'], isTrue);
    expect((layers[1]['automation'] as List).single['target'], 'pan');
  });

  test('legacy pattern layers migrate once into clip instances', () {
    final old = sample().toJson()..['caw_app_project'] = 1;
    final migrated = ProjectDoc.fromJson(old);
    expect(migrated.layers[1].clips, hasLength(1));
    expect(migrated.layers[1].clips.single.patternId, 'pat');
    expect(migrated.layers[1].patternId, isNull);
    final saved = ProjectDoc.fromJson(migrated.toJson());
    expect(saved.layers[1].clips, hasLength(1));

    // The current file version can still contain an older pattern pointer from a partial upgrade.
    final currentVersionLegacy = sample().toJson()..['caw_app_project'] = ProjectDoc.fileVersion;
    final recovered = ProjectDoc.fromJson(currentVersionLegacy);
    expect(recovered.layers[1].clips.single.patternId, 'pat');
    recovered.layers[1].clips.clear();
    final emptyLayer = (jsonDecode(recovered.toEngineJson()) as Map<String, dynamic>)['layers'] as List;
    expect((emptyLayer[1] as Map).containsKey('pattern'), isFalse);
  });

  test('engine JSON carries the code last run and the layer chain', () {
    final j = jsonDecode(sample().toEngineJson()) as Map<String, dynamic>;
    expect(j['caw_project'], 1);
    expect((j['modules'] as List).first['source'], 't');
    final layer = (j['layers'] as List).first as Map<String, dynamic>;
    expect(layer['chain'], ['m1', 'fx']);
    expect(layer['length_steps'], 48);
    expect(layer.containsKey('pattern'), isFalse);
    expect((j['layers'] as List)[1]['pattern'], 'pat');
    expect(j['audition_only'], false);
    expect(j['globals'], {'swing': 0.2});
    expect((j['modules'] as List).first['name'], 'Lead');
    expect([j['key_root'], j['key_scale']], [9, 1]);  // A minor
    final none = jsonDecode((sample()..key = 'None').toEngineJson()) as Map<String, dynamic>;
    expect(none.containsKey('key_root'), isFalse);
    expect((sample()..key = 'C# minor').keyNumbers, (1, 1));
    expect((sample()..key = 'Bb major').keyNumbers, (10, 0));
    final a = jsonDecode(sample().toEngineJson(audition: ['m1'], auditionOnly: true)) as Map<String, dynamic>;
    expect(a['audition'], {'chain': ['m1']});
    final ap = jsonDecode(sample().toEngineJson(audition: ['m1'], auditionPattern: 'pat')) as Map<String, dynamic>;
    expect(ap['audition'], {'chain': ['m1'], 'pattern': 'pat'});
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
