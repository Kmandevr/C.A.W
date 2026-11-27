// Instance ids (lib/model/instance_ids.dart): kept through save and load, made for older files, untrusted ones
// replaced, lanes and links aimed at their device by id, and never in the engine's copy.
import 'dart:convert';

import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/clip_automation.dart';
import 'package:caw/model/instance_ids.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc _project() {
  final eq = ComponentUseDoc('org.caw.eq', {'gain': 0.5});
  final delay = ComponentUseDoc('org.caw.delay')..samples = [ComponentSampleDoc(0, builtin: 'Crash')];
  return ProjectDoc(id: 'p', name: 'p', bpm: 120, modules: [
    ModuleDoc(id: 'm1', name: 'M', source: '---\nkind: pattern\n---\n'),
  ], layers: [
    LayerDoc(id: 'a', name: 'A', color: 0, components: [eq, delay], instrument: ComponentUseDoc('org.caw.drums'),
        sends: [SendDoc('b')],
        automation: [AutomationLaneDoc(target: 'volume', points: [AutomationPointDoc(step: 0, value: 0.5)])],
        clips: [ClipDoc(id: 'c1', patternId: 'm1', startSteps: 0, lengthSteps: 16, automation: [
          ClipAutomationLaneDoc(targetType: 'component', target: 'time', component: 1,
              points: [AutomationPointDoc(step: 1, value: 0.2)]),
        ])]),
    LayerDoc(id: 'b', name: 'B', color: 1, isFolder: true),
  ], masterComponents: [ComponentUseDoc('org.caw.limiter')])
    ..automation = [
      ProjectAutomationLaneDoc(targetType: 'component', target: 'gain', layerId: 'a', component: 0,
          points: [AutomationPointDoc(step: 0, value: 0.1), AutomationPointDoc(step: 4, value: 0.9)]),
    ]
    ..modulators = [ModulatorDoc(id: 'lfo', name: 'LFO', componentId: 'org.caw.mod.lfo')]
    ..modLinks = [ModLinkDoc(id: 1, source: 'lfo', target: const ModTarget.component('a', 1, 'time'))];
}

ProjectDoc _reload(ProjectDoc p) => ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

/// Every instance id in [p], in project order.
List<String> _ids(ProjectDoc p) => [
      for (final c in p.masterComponents) c.uid,
      for (final l in p.layers) ...[
        ?l.instrument?.uid,
        for (final c in [...l.components, ...l.noteComponents]) ...[c.uid, for (final s in c.samples) s.uid],
        for (final s in l.sends) s.uid,
        for (final lane in l.automation) ...[lane.uid, for (final q in lane.points) q.uid],
        for (final clip in l.clips)
          for (final lane in clip.automation) ...[lane.uid, for (final q in lane.points) q.uid],
      ],
      for (final lane in p.automation) ...[lane.uid, for (final q in lane.points) q.uid],
    ];

/// [json] (a saved project) with every instance id taken out, as a file from before them.
Map<String, dynamic> _withoutIds(Map<String, dynamic> json) {
  Object? strip(Object? x) => switch (x) {
        final Map m => <String, dynamic>{
            for (final e in m.entries)
              if (!const {'uid', 'device', 'component_uids', 'note_component_uids', 'instrument_uid',
                  'master_component_uids', 'send_uids'}.contains(e.key))
                e.key: strip(e.value),
          },
        final List l => [for (final e in l) strip(e)],
        _ => x,
      };
  return strip(jsonDecode(jsonEncode(json))) as Map<String, dynamic>;
}

void main() {
  group('instance ids', () {
    test('each has its prefix and 8 base-36 characters, and a project uses each once', () {
      final p = _project();
      final ids = _ids(p);
      expect(ids.toSet(), hasLength(ids.length));
      final a = p.layers.first;
      expect(InstanceIds.valid(a.components.first.uid, 'd'), isTrue);
      expect(InstanceIds.valid(a.components[1].samples.single.uid, 'cs'), isTrue);
      expect(InstanceIds.valid(a.sends.single.uid, 's'), isTrue);
      expect(InstanceIds.valid(a.automation.single.uid, 'al'), isTrue);
      expect(InstanceIds.valid(a.automation.single.points.single.uid, 'ap'), isTrue);
      expect(InstanceIds.valid('dABCDEFGH', 'd'), isFalse);
      expect(InstanceIds.valid('d1234567', 'd'), isFalse);
      expect(InstanceIds.valid('d123456789', 'd'), isFalse);
      expect(InstanceIds.valid('s12345678', 'd'), isFalse);
    });

    test('kept through save and load, and the second save is byte for byte the first', () {
      final p = _project();
      final before = _ids(p);
      final first = jsonEncode(p.toJson());
      final read = _reload(p);
      expect(_ids(read), before);
      expect(read.automation.single.device, read.layers.first.components.first.uid);
      expect(read.modLinks.single.target.device, read.layers.first.components[1].uid);
      expect(read.layers.first.clips.single.automation.single.device, read.layers.first.components[1].uid);
      expect(jsonEncode(read.toJson()), first);
    });

    test('a file without ids reads as before and gets them; its entries and indexes are saved as they were', () {
      final p = _project();
      final old = _withoutIds(p.toJson());
      final read = ProjectDoc.fromJson(jsonDecode(jsonEncode(old)) as Map<String, dynamic>);
      final ids = _ids(read);
      expect(ids.toSet(), hasLength(ids.length));
      expect(read.automation.single.device, read.layers.first.components.first.uid, reason: 'migrated from the index');
      expect(read.modLinks.single.target.device, read.layers.first.components[1].uid);
      final saved = read.toJson();
      // What an older build reads is unchanged: the chains' entries, the lanes' and links' indexes.
      expect(_withoutIds(saved), old);
      expect((saved['automation'] as List).single['component'], 0);
      expect((((saved['layers'] as List).first as Map)['components'] as List).first,
          {'id': 'org.caw.eq', 'params': {'gain': 0.5}});
      expect(((saved['master_components'] as List).single), 'org.caw.limiter', reason: 'a bare id as before');
    });

    test('the engine\'s copy has no ids, the same as for a file without them', () {
      final p = _project();
      final old = ProjectDoc.fromJson(_withoutIds(p.toJson()));
      final engine = p.toEngineJson();
      expect(engine, old.toEngineJson());
      for (final key in ['"uid"', '"device"', '_uids"', '"instrument_uid"']) {
        expect(engine, isNot(contains(key)));
      }
    });

    test('a malformed, too long or repeated id read from a file is replaced', () {
      final json = _project().toJson();
      final layer = (json['layers'] as List).first as Map<String, dynamic>;
      final eqUid = (layer['component_uids'] as List).first as String;
      layer['component_uids'] = [eqUid, eqUid];  // the delay claims the EQ's id
      layer['instrument_uid'] = 'd${'x' * 5000}';
      layer['send_uids'] = ['not an id'];
      json['master_component_uids'] = [42];
      final lane = (json['automation'] as List).single as Map<String, dynamic>;
      final points = lane['points'] as List;
      points[1]['uid'] = points[0]['uid'];
      final read = ProjectDoc.fromJson(json);
      final a = read.layers.first;
      expect(a.components.first.uid, eqUid, reason: 'the first keeps it');
      expect(a.components[1].uid, isNot(eqUid));
      expect(InstanceIds.valid(a.instrument!.uid, 'd'), isTrue);
      expect(InstanceIds.valid(a.sends.single.uid, 's'), isTrue);
      expect(InstanceIds.valid(read.masterComponents.single.uid, 'd'), isTrue);
      final ids = _ids(read);
      expect(ids.toSet(), hasLength(ids.length));
      expect(read.automation.single.device, eqUid, reason: 'the lane stays on the EQ');
    });

    test('a lane\'s and link\'s device id decides over a stale index; one naming nothing leaves the index', () {
      final json = _project().toJson();
      final lane = (json['automation'] as List).single as Map<String, dynamic>;
      final link = (json['modulation'] as List).single as Map<String, dynamic>;
      lane['component'] = 1;  // stale: the id names the EQ at 0
      (link['target'] as Map)['index'] = 0;  // stale: the id names the delay at 1
      var read = ProjectDoc.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(read.automation.single.component, 0);
      expect(read.modLinks.single.target.index, 1);
      lane['device'] = 'dzzzzzzzz';
      read = ProjectDoc.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(read.automation.single.component, 1, reason: 'no device has that id: the index decides');
      expect(read.automation.single.device, read.layers.first.components[1].uid);
    });

    test('a reorder keeps lanes, clip lanes and links on their device, by id', () {
      final p = _project();
      final a = p.layers.first;
      final eq = a.components.first, delay = a.components[1];
      final before = List.of(a.components);
      a.components
        ..clear()
        ..addAll([delay, eq]);
      followComponentLanes(p, 'a', before);
      expect((p.automation.single.component, p.automation.single.device), (1, eq.uid));
      expect((a.clips.single.automation.single.component, a.clips.single.automation.single.device), (0, delay.uid));
      expect((p.modLinks.single.target.index, p.modLinks.single.target.device), (0, delay.uid));
      // Saved and read again, they still aim at the same devices.
      final read = _reload(p);
      expect(read.automation.single.device, read.layers.first.components[1].uid);
      expect(read.layers.first.components[1].uid, eq.uid);
    });

    test('a copy is a new device; the same entry read again from a snapshot is the same one', () {
      final p = _project();
      final eq = p.layers.first.components.first;
      expect(ComponentUseDoc.fromJson(eq.toJson())!.uid, isNot(eq.uid));
      final send = p.layers.first.sends.single;
      expect(SendDoc.fromJson(send.toJson())!.uid, isNot(send.uid));
      expect(SendDoc.listFromJson([send.toJson()], [send.uid]).single.uid, send.uid);
      final point = p.automation.single.points.first;
      expect(point.copy(step: 3).uid, point.uid, reason: 'a moved point is the same point');
      expect(point.copy(fresh: true).uid, isNot(point.uid));
      final lane = p.layers.first.clips.single.automation.single;
      expect(lane.copy().uid, lane.uid);
      expect(lane.copy(fresh: true).uid, isNot(lane.uid));
    });

    test('ids repeated by an edit in place are made unique again', () {
      final p = _project();
      final lane = p.automation.single;
      lane.points.add(lane.points.first.copy(step: 8));  // a copy keeping its source's id
      p.settleIds();
      final ids = _ids(p);
      expect(ids.toSet(), hasLength(ids.length));
      expect(lane.points.first.uid, isNot(lane.points.last.uid));
    });
  });
}
