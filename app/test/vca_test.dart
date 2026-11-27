// VCA groups (lib/model/vca.dart): saved and read back, sent to the engine, members leaving with their layer, undo.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/vca.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'VCA test', layers: [
      LayerDoc(id: 'a', name: 'Kick', color: 0),
      LayerDoc(id: 'b', name: 'Snare', color: 1),
      LayerDoc(id: 'c', name: 'Bass', color: 2),
    ]);

ProjectDoc roundTrip(ProjectDoc p) => ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

Map<String, dynamic> engineJson(ProjectDoc p) => jsonDecode(p.toEngineJson()) as Map<String, dynamic>;

void main() {
  test('a project without groups saves and sends as before', () {
    final p = project();
    final saved = p.toJson();
    expect(saved.containsKey('vca_groups'), isFalse);
    expect(saved['caw_app_project'], ProjectDoc.baseFileVersion);
    expect(engineJson(p).containsKey('vca_groups'), isFalse);
    final back = roundTrip(p);
    expect(back.vcaGroups, isEmpty);
    expect(jsonEncode(back.toJson()), jsonEncode(saved));
  });

  test('groups round trip and save as v8', () {
    final p = project();
    final g = p.createVcaGroup(['a', 'b', 'a', 'zz'], name: 'Drums')!;
    expect(g.id, startsWith('v'));
    expect(g.members, ['a', 'b']);  // each once, layers only
    g
      ..volume = 0.5
      ..mute = true
      ..automation = AutomationLaneDoc(target: 'volume', points: [AutomationPointDoc(step: 0, value: 1), AutomationPointDoc(step: 16, value: 0.25)]);
    final saved = jsonEncode(p.toJson());
    expect(jsonDecode(saved)['caw_app_project'], ProjectDoc.fileVersion);
    final back = ProjectDoc.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    final h = back.vcaGroups.single;
    expect((h.id, h.name, h.volume, h.mute, h.solo), (g.id, 'Drums', 0.5, true, false));
    expect(h.members, ['a', 'b']);
    expect([for (final pt in h.automation!.points) pt.value], [1, 0.25]);
    expect(jsonEncode(back.toJson()), saved);
  });

  test('untrusted files are held to the limits', () {
    final j = project().toJson()
      ..['vca_groups'] = [
        for (var i = 0; i < 40; i++) {'id': 'g$i', 'volume': 99, 'members': ['a', 3, 'a']},
        {'id': 'g0'},  // a repeat id is dropped
        'nonsense',
      ];
    final p = ProjectDoc.fromJson(j);
    expect(p.vcaGroups, hasLength(kMaxVcaGroups));
    expect(p.vcaGroups.first.volume, kMaxMixGain);
    expect(p.vcaGroups.first.members, ['a']);
    expect(p.createVcaGroup(['a']), isNull);  // full
  });

  test('the engine gets the groups with the members that are layers', () {
    final p = project();
    final g = p.createVcaGroup(['a', 'c'])!..solo = true;
    g.members.add('gone');
    final e = engineJson(p)['vca_groups'] as List;
    expect(e, hasLength(1));
    final entry = e.single as Map<String, dynamic>;
    expect((entry['id'], entry['volume'], entry['mute'], entry['solo']), (g.id, 1.0, false, true));
    expect(entry['members'], ['a', 'c']);
    expect(entry.containsKey('automation'), isFalse);
    g.automation = AutomationLaneDoc(target: 'volume', points: [AutomationPointDoc(step: 4, value: 0.5)]);
    final lane = ((engineJson(p)['vca_groups'] as List).single as Map)['automation'] as List;
    expect((lane.single as Map)['points'], [{'step': 4.0, 'value': 0.5}]);
  });

  group('AppState edits', () {
    late AppState s;
    setUp(() {
      s = AppState(settings: Settings());
      s.project = project();
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
    });
    tearDown(() => s.dispose());

    test('a deleted layer leaves its groups', () {
      final g = s.createVcaGroup(['a', 'b'])!;
      s.removeLayer(s.project.layers.firstWhere((l) => l.id == 'a'));
      expect((engineJson(s.project)['vca_groups'] as List).single['members'], ['b']);
      final back = roundTrip(s.project);
      expect(back.vcaGroup(g.id)!.members, ['b']);
    });

    test('each edit is one undo step', () {
      s.selectedLayerId = 'c';
      final g = s.createVcaGroup()!;
      expect(g.members, ['c']);
      s.history.settle(jsonEncode(s.project.toJson()));
      s.renameVcaGroup(g.id, 'Bass VCA');
      s.history.settle(jsonEncode(s.project.toJson()));
      s.mixVca(g.id, volume: 0.25, mute: true);
      s.history.settle(jsonEncode(s.project.toJson()));
      s.addVcaMember(g.id, 'a');
      s.history.settle(jsonEncode(s.project.toJson()));
      s.removeVcaMember(g.id, 'c');
      s.history.settle(jsonEncode(s.project.toJson()));
      expect(s.project.vcaGroup(g.id)!.members, ['a']);
      expect(s.undo(), isTrue);
      expect(s.project.vcaGroup(g.id)!.members, ['c', 'a']);
      expect(s.undo(), isTrue);
      expect(s.project.vcaGroup(g.id)!.members, ['c']);
      expect(s.undo(), isTrue);
      expect((s.project.vcaGroup(g.id)!.volume, s.project.vcaGroup(g.id)!.mute), (1.0, false));
      expect(s.undo(), isTrue);
      expect(s.project.vcaGroup(g.id)!.name, 'VCA 1');
      s.deleteVcaGroup(g.id);
      expect(s.project.vcaGroups, isEmpty);
      expect(s.undo(), isTrue);
      expect(s.project.vcaGroup(g.id), isNotNull);
      expect(s.undo(), isTrue);
      expect(s.project.vcaGroups, isEmpty);
    });
  });

  test('the engine takes the groups and moves one live', () async {
    final p = project();
    for (final l in p.layers) {
      l.setInstrument('org.caw.synth.flagship');
    }
    final g = p.createVcaGroup(['a', 'b'])!;
    final e = Engine.create();
    await e.setProject(p.toEngineJson());
    expect(e.lastProjectWarnings, isEmpty);
    expect(e.setVca(g.id, 0.5, false, true), isTrue);
    expect(e.setVca('nope', 0.5, false, false), isFalse);
    e.dispose();
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
