// The apply(op) seam (lib/model/collab/project_ops.dart): each op and its inverse round-trip to the same project,
// ops read back from their JSON, refused ops change nothing, and AppState's edits go through it.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/clip_automation.dart';
import 'package:caw/model/collab/project_ops.dart';
import 'package:caw/model/instance_ids.dart';
import 'package:caw/model/mixer_fx.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/vca.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc _project() {
  final p = ProjectDoc(id: 'p', name: 'p', bpm: 120, modules: [
    ModuleDoc(id: 'm1', name: 'M', source: '---\nkind: pattern\n---\n'),
  ], layers: [
    LayerDoc(id: 'a', name: 'A', color: 0,
        components: [ComponentUseDoc('org.caw.eq', {'gain': 0.5}), ComponentUseDoc('org.caw.delay')],
        noteComponents: [ComponentUseDoc('org.caw.filter')],
        instrument: ComponentUseDoc('org.caw.drums', {'level': 0.7}),
        sends: [SendDoc('f')],
        automation: [AutomationLaneDoc(target: 'volume', points: [
          AutomationPointDoc(step: 0, value: 0.5), AutomationPointDoc(step: 8, value: 0.9)])],
        clips: [ClipDoc(id: 'c1', patternId: 'm1', startSteps: 0, lengthSteps: 16, automation: [
          ClipAutomationLaneDoc(targetType: 'component', target: 'time', component: 1,
              points: [AutomationPointDoc(step: 1, value: 0.2)]),
        ])],
        audioClips: [AudioClipDoc(id: 'ac1', assetId: 'x', startSteps: 4)]),
    LayerDoc(id: 'b', name: 'B', color: 1, components: [ComponentUseDoc('org.caw.comp')]),
    LayerDoc(id: 'f', name: 'F', color: 2, isFolder: true),
    LayerDoc(id: 'f1', name: 'F1', color: 3, parentId: 'f'),
    LayerDoc(id: 'f2', name: 'F2', color: 4, parentId: 'f'),
  ], masterComponents: [ComponentUseDoc('org.caw.limiter')])
    ..automation = [
      ProjectAutomationLaneDoc(targetType: 'component', target: 'time', layerId: 'a', component: 1,
          points: [AutomationPointDoc(step: 0, value: 0.1), AutomationPointDoc(step: 4, value: 0.9)]),
      ProjectAutomationLaneDoc(targetType: 'component', target: 'gain', layerId: 'a', component: 0),
      ProjectAutomationLaneDoc(targetType: 'noteComponent', target: 'cutoff', layerId: 'a', component: 0),
    ]
    ..modulators = [ModulatorDoc(id: 'lfo', name: 'LFO', componentId: 'org.caw.mod.lfo')]
    ..modLinks = [ModLinkDoc(id: 1, source: 'lfo', target: const ModTarget.component('a', 1, 'time'))];
  p.createVcaGroup(['a', 'f1'], name: 'G');
  p.settleIds();
  return p;
}

String _json(ProjectDoc p) => jsonEncode(p.toJson());

LayerDoc _layer(ProjectDoc p, String id) => p.layers.firstWhere((l) => l.id == id);

/// Applies [op], then its inverse (back to the start), then the inverse's inverse (the change again: a redo) and
/// its inverse once more. Each must apply, the project must come back exactly, and the redo must change it. The
/// project is read as JSON only at the start and between whole round trips: a save settles ids, and settling a
/// half-done edit (a clip lane on a clip just moved to another track) is the snapshot undo's business, not the op's.
ProjectDoc _roundTrip(ProjectOp op, {ProjectDoc? project, void Function(ProjectDoc p)? check}) {
  final p = project ?? _project();
  final start = _json(p);
  final inverse = p.applyOp(op);
  expect(inverse, isNotNull, reason: '$op applies');
  check?.call(p);
  final redo = p.applyOp(inverse!);
  expect(redo, isNotNull, reason: 'its inverse applies');
  expect(_json(p), start, reason: 'applying $op then its inverse returns the project it started from');
  final undo = p.applyOp(redo!);
  expect(undo, isNotNull, reason: 'the inverse of the inverse applies');
  expect(_json(p), isNot(start), reason: '$op changes the project');
  expect(p.applyOp(undo!), isNotNull);
  expect(_json(p), start, reason: 'and undoing the redo returns it again');
  return p;
}

void main() {
  group('each op and its inverse round-trip', () {
    test('the mix: tracks, the master, VCA groups and sends', () {
      _roundTrip(const ProjectSet('a', OpField.volume, 0.25), check: (p) => expect(_layer(p, 'a').volume, 0.25));
      _roundTrip(const ProjectSet('a', OpField.pan, -0.5));
      _roundTrip(const ProjectSet('b', OpField.mute, true));
      _roundTrip(const ProjectSet('b', OpField.solo, true));
      _roundTrip(const ProjectSet(kMasterNode, OpField.volume, 0.5), check: (p) => expect(p.master, 0.5));
      final p = _project();
      final g = p.vcaGroups.single.id;
      for (final (field, value) in [(OpField.volume, 0.3), (OpField.mute, true), (OpField.solo, true)]) {
        _roundTrip(ProjectSet(g, field, value), project: p);
      }
      final send = _layer(p, 'a').sends.single.uid;
      _roundTrip(ProjectSet(send, OpField.level, 1.5), project: p,
          check: (q) => expect(_layer(q, 'a').sends.single.level, 1.5));
      _roundTrip(ProjectSet(send, OpField.pre, true), project: p);
      _roundTrip(ProjectSet(send, OpField.mute, true), project: p);
    });

    test('parameters, bypass and auto gain of every kind of device', () {
      final p = _project();
      final a = _layer(p, 'a');
      _roundTrip(ProjectSet(a.components[0].uid, OpField.param('gain'), 0.9), project: p);
      // A value the device didn't hold: its inverse takes it out again (the knob shows its default).
      _roundTrip(ProjectSet(a.components[1].uid, OpField.param('time'), 0.4), project: p,
          check: (q) => expect(_layer(q, 'a').components[1].params['time'], 0.4));
      expect(a.components[1].params.containsKey('time'), isFalse);
      _roundTrip(ProjectSet(a.instrument!.uid, OpField.param('level'), 0.1), project: p);
      _roundTrip(ProjectSet(a.noteComponents[0].uid, OpField.param('cutoff'), 0.3), project: p);
      _roundTrip(ProjectSet(p.masterComponents[0].uid, OpField.param('ceiling'), 0.8), project: p);
      _roundTrip(ProjectSet(a.components[0].uid, OpField.bypass, true), project: p);
      _roundTrip(ProjectSet(p.masterComponents[0].uid, OpField.autoGain, true), project: p);
      _roundTrip(ProjectSet(a.components[0].uid, OpField.param('gain'), null), project: p,
          check: (q) => expect(_layer(q, 'a').components[0].params, isEmpty));
    });

    test('clip moves and resizes, and the lanes that follow them', () {
      _roundTrip(const ProjectSet('c1', OpField.start, 32));
      _roundTrip(const ProjectSet('c1', OpField.length, 8));
      _roundTrip(const ProjectSet('c1', OpField.offset, 2));
      _roundTrip(const ProjectSet('ac1', OpField.start, 12.5));
      final p = _project()..automationFollowsClips = true;
      final lane = _layer(p, 'a').automation.single;
      final follow = clipFollowOps(p, _layer(p, 'a'), [(0, 16)], 16);
      expect(follow.map((o) => o.node), containsAll([lane.uid, p.automation.first.uid]));
      for (final op in follow) {
        _roundTrip(op, project: p);
      }
      _roundTrip(const ProjectMove('c1', 'b', OpList.clips, 0), project: p,
          check: (q) => expect(_layer(q, 'b').clips.single.id, 'c1'));
      _roundTrip(const ProjectMove('ac1', 'b', OpList.audioClips, 0), project: p);
    });

    test('devices added, removed and moved, with their lanes and links', () {
      _roundTrip(ProjectInsert('b', OpList.components, 0, ComponentUseDoc('org.caw.chorus')));
      _roundTrip(ProjectInsert(kMasterNode, OpList.components, 1, ComponentUseDoc('org.caw.eq')));
      _roundTrip(ProjectInsert('a', OpList.noteComponents, 0, ComponentUseDoc('org.caw.drive')));
      final p = _project();
      final a = _layer(p, 'a');
      final delay = a.components[1].uid, eq = a.components[0].uid;
      // Removing the delay takes its project lane, its clip lane and its modulation link; the inverse brings all back.
      _roundTrip(ProjectDelete(delay), project: p, check: (q) {
        expect(q.automation.where((l) => l.device == delay), isEmpty);
        expect(_layer(q, 'a').clips.single.automation, isEmpty);
        expect(q.modLinks, isEmpty);
      });
      _roundTrip(ProjectDelete(a.noteComponents[0].uid), project: p);
      _roundTrip(ProjectDelete(p.masterComponents[0].uid), project: p);
      _roundTrip(ProjectMove(eq, 'a', OpList.components, 1), project: p,
          check: (q) => expect(q.automation[1].component, 1, reason: 'its lane follows it'));
      // To the master: the eq's lane goes with it (as mixer_fx.dart's dropFx); back again, all as it was.
      _roundTrip(ProjectMove(eq, kMasterNode, OpList.components, 1), project: p, check: (q) {
        final lane = q.automation.firstWhere((l) => l.device == eq);
        expect((lane.layerId, lane.component), (null, 1));
      });
      _roundTrip(ProjectMove(delay, 'b', OpList.components, 0), project: p);
      _roundTrip(ProjectMove(delay, 'a', OpList.noteComponents, 1), project: p);
      _roundTrip(ProjectMove(a.noteComponents[0].uid, 'a', OpList.components, 0), project: p);
    });

    test('tracks added, removed and moved', () {
      _roundTrip(ProjectInsert(kProjectNode, OpList.layers, 2, LayerDoc(id: 'n', name: 'N', color: 5)));
      // A removed folder lets its tracks go to its own folder; a removed track leaves its VCA group.
      _roundTrip(const ProjectDelete('f'), check: (p) => expect(_layer(p, 'f1').parentId, isNull));
      _roundTrip(const ProjectDelete('a'), check: (p) => expect(p.layers.map((l) => l.id), isNot(contains('a'))));
      // A save between the delete and its inverse lets the track leave its group; the inverse puts it back.
      final p = _project();
      final back = p.applyOp(const ProjectDelete('a'))!;
      _json(p);
      expect(p.vcaGroups.single.members, ['f1']);
      p.applyOp(back);
      expect(p.vcaGroups.single.members, ['a', 'f1']);
      _roundTrip(const ProjectMove('f', kProjectNode, OpList.layers, 0),
          check: (p) => expect([for (final l in p.layers) l.id], ['f', 'f1', 'f2', 'a', 'b']));
      _roundTrip(const ProjectMove('b', 'f', OpList.layers, 4), check: (p) {
        expect([for (final l in p.layers) l.id], ['a', 'f', 'f1', 'f2', 'b']);
        expect(_layer(p, 'b').parentId, 'f');
      });
      _roundTrip(const ProjectMove('f2', 'f', OpList.layers, 0, withInside: false));
    });
  });

  test('ops read back from their JSON, as a remote op would arrive', () {
    final base = _project();
    ProjectDoc copy() => ProjectDoc.fromJson(jsonDecode(_json(base)) as Map<String, dynamic>);
    final a = _layer(base, 'a');
    final ops = <ProjectOp>[
      const ProjectSet('a', OpField.volume, 0.5),
      ProjectSet(a.components[0].uid, OpField.param('gain'), 0.25),
      ProjectSet(a.automation.single.uid, OpField.points, [AutomationPointDoc(step: 2, value: 0.4)]),
      ProjectInsert('b', OpList.components, 0, ComponentUseDoc('org.caw.chorus', {'rate': 0.5})),
      ProjectInsert(kProjectNode, OpList.layers, 1, LayerDoc(id: 'n', name: 'N', color: 5)),
      ProjectMove(a.components[1].uid, kMasterNode, OpList.components, 0),
      const ProjectMove('f2', 'f', OpList.layers, 0, withInside: false),
      const ProjectDelete('b'),
    ];
    for (final op in ops) {
      final remote = ProjectOp.fromJson(jsonDecode(jsonEncode(op.toJson())));
      expect(remote, op);
      // Applied from its JSON (ids kept through a save and load), it changes the project as the op itself does.
      final here = copy(), there = copy();
      expect(here.applyOp(op), isNotNull);
      expect(there.applyOp(remote!), isNotNull);
      expect(_json(there), _json(here), reason: '$op');
    }
    expect(ProjectOp.fromJson({'op': 'insert', 'parent': 'b', 'list': 'components', 'index': 0, 'kind': 'device',
        'node': {'uid': 'nonsense', 'device': 'org.caw.eq'}}), isNull, reason: 'a malformed device id');
    expect(ProjectOp.fromJson('set'), isNull);
    expect(ProjectOp.fromJson({'op': 'grow', 'node': 'a'}), isNull);
  });

  test('an op that names nothing, or the wrong kind of value, changes nothing', () {
    final p = _project();
    final start = _json(p);
    final a = _layer(p, 'a');
    for (final op in <ProjectOp>[
      const ProjectSet('zz', OpField.volume, 0.5),
      const ProjectSet('a', OpField.volume, 'loud'),
      const ProjectSet('a', OpField.mute, 1),
      const ProjectSet('a', OpField.volume, double.nan),
      const ProjectSet(kMasterNode, OpField.mute, true),
      const ProjectSet('c1', OpField.length, 0),
      const ProjectSet('c1', OpField.start, 1.5),
      const ProjectSet('a', 'colour', 3),
      ProjectSet(a.components[0].uid, OpField.param('gain'), 'x'),
      ProjectDelete(a.instrument!.uid),  // an instrument is replaced, not removed (setNativeInstrument)
      const ProjectDelete('zz'),
      ProjectInsert('a', OpList.components, 0, a.components[0]),  // already in the project
      ProjectInsert('zz', OpList.components, 0, ComponentUseDoc('org.caw.eq')),
      ProjectInsert(kProjectNode, OpList.layers, 0, LayerDoc(id: 'a', name: 'A again', color: 0)),
      const ProjectMove('f', 'f1', OpList.layers, 0),  // a folder into its own track
      const ProjectMove('c1', 'zz', OpList.clips, 0),
      const ProjectMove('c1', 'b', OpList.audioClips, 0),
      ProjectMove(a.components[0].uid, 'zz', OpList.components, 0),
    ]) {
      expect(p.applyOp(op), isNull, reason: '$op');
    }
    expect(_json(p), start);
  });

  group('AppState edits go through ProjectOps.apply', () {
    late AppState s;
    setUp(() {
      s = AppState(settings: Settings());
      s.project = _project();
      s.starting = false;
      s.history.reset(_json(s.project));
    });
    tearDown(() => s.dispose());

    test('apply returns the inverses, and applying them returns the project to what it was', () {
      final start = _json(s.project);
      final a = _layer(s.project, 'a');
      final undo = s.applyAll([
        const ProjectSet('a', OpField.volume, 0.2),
        ProjectSet(a.components[0].uid, OpField.param('gain'), 0.1),
        const ProjectMove('c1', 'b', OpList.clips, 0),
        ProjectDelete(a.components[1].uid),
        const ProjectMove('f', kProjectNode, OpList.layers, 0),
      ]);
      expect(undo, hasLength(5));
      expect(_layer(s.project, 'b').clips.single.id, 'c1');
      s.applyAll(undo);
      expect(_json(s.project), start);
      expect(s.apply(const ProjectSet('zz', OpField.volume, 1)), isEmpty);
    });

    test('a knob drag step changes only the value; a fader saves; a structural edit saves and redraws', () {
      var redraws = 0;
      s.addListener(() => redraws++);
      final a = _layer(s.project, 'a');
      s.setNativeParamLive(a, 0, 'gain', 0.3);
      expect(a.components[0].params['gain'], 0.3);
      expect(redraws, 0);
      expect(s.history.canUndo, isFalse, reason: 'a drag step opens no undo step: the commit does');
      s.mixLayer(a, volume: 0.4);
      expect(a.volume, 0.4);
      expect(s.history.canUndo, isTrue, reason: 'a fader saves (its undo burst opens)');
      final before = redraws;
      s.removeNativeEffect(a, 1);
      expect(redraws, before + 1);
      expect(s.project.modLinks, isEmpty);
    });

    test('the edit methods name things by id: a reorder between edits keeps each aimed at its own', () {
      final a = _layer(s.project, 'a');
      final eq = a.components[0];
      s.moveNativeEffect(a, 0, 1);
      expect(a.components[1], same(eq));
      s.setNativeBypass(a, 1, true);
      expect(eq.bypass, isTrue);
      final copy = ComponentUseDoc('org.caw.eq');
      expect(s.dropFx(FxSlotDrag('a', 1), _layer(s.project, 'b'), move: true), isTrue);
      expect(_layer(s.project, 'b').components.last, same(eq));
      s.insertNativeEffect(masterLayerOf(s.project), copy);
      expect(s.project.masterComponents.last, same(copy));
    });
  });
}
