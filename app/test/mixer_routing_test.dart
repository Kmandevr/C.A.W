// General mixer routing (owner, 2026-11-18): output overrides, sends into tracks, feedback sends and their limiter,
// keys from tracks fed by sends; the loop rules, the project file (v5 unless v6 routing is used) and the engine JSON.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/routing_edit.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

// kick and snare at the top; bass inside the Group bus; two buses (Verb, Delay) at the end.
ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Mixer', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'kick', name: 'Kick', color: 0),
      LayerDoc(id: 'snare', name: 'Snare', color: 1),
      LayerDoc(id: 'grp', name: 'Group', color: 2, isFolder: true),
      LayerDoc(id: 'bass', name: 'Bass', color: 3, parentId: 'grp'),
      LayerDoc(id: 'verb', name: 'Verb', color: 4, isFolder: true),
      LayerDoc(id: 'dly', name: 'Delay', color: 5, isFolder: true),
      LayerDoc(id: 'org', name: 'Folder', color: 6, isFolder: true, busEnabled: false),
    ]);

LayerDoc _l(ProjectDoc p, String id) => p.layers.firstWhere((l) => l.id == id);

Map<String, dynamic> _engineLayer(ProjectDoc p, String id) =>
    ((jsonDecode(p.toEngineJson()) as Map)['layers'] as List).cast<Map<String, dynamic>>().firstWhere((l) => l['id'] == id);

ProjectDoc _reload(ProjectDoc p) => ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

AppState _state() {
  final s = AppState(settings: Settings());
  s.project = _project();
  s.starting = false;  // as after a project opens
  s.history.reset(jsonEncode(s.project.toJson()));
  return s;
}

void main() {
  group('the model fields', () {
    test('output, feedback and limiter round-trip and are written only off their defaults', () {
      final p = _project();
      _l(p, 'kick').output = 'verb';
      _l(p, 'snare').sends.add(SendDoc('kick', level: 0.3, feedback: true, limiter: false));
      _l(p, 'bass').sends.add(SendDoc('verb'));
      final j = p.toJson();
      final layers = (j['layers'] as List).cast<Map<String, dynamic>>();
      expect(layers[0]['output'], 'verb');
      expect(layers[1]['sends'], [{'to': 'kick', 'level': 0.3, 'feedback': true, 'limiter': false}]);
      expect(layers[3]['sends'], [{'to': 'verb', 'level': 0.5}]);
      expect(layers[3].containsKey('output'), isFalse);
      final back = _reload(p);
      expect(_l(back, 'kick').output, 'verb');
      expect(_l(back, 'bass').output, isNull);
      final s = _l(back, 'snare').sends.single;
      expect((s.to, s.level, s.feedback, s.limiter), ('kick', 0.3, true, false));
      final plain = _l(back, 'bass').sends.single;
      expect((plain.feedback, plain.limiter), (false, true));
    });

    test('a bad output or send flag reads as the default', () {
      final l = LayerDoc.fromJson({'id': 'x', 'output': 7, 'sends': [{'to': 'v', 'feedback': 'yes', 'limiter': 0}]});
      expect(l.output, isNull);
      expect(l.sends.single.feedback, isFalse);
      expect(l.sends.single.limiter, isTrue);
      expect(LayerDoc.fromJson({'id': 'x', 'output': ''}).output, isNull);
      expect(LayerDoc.fromJson({'id': 'x', 'output': 'b' * 300}).output, isNull);
    });
  });

  group('the file version', () {
    test('a v5 project saved again is byte-identical and stays v5', () {
      final p = _project();
      _l(p, 'kick').sends.add(SendDoc('verb', level: 0.25, pre: true, mute: true));
      _l(p, 'bass').sends.add(SendDoc('dly'));
      final first = jsonEncode(p.toJson());
      expect(jsonDecode(first)['caw_app_project'], 5);
      final again = jsonEncode(_reload(p).toJson());
      expect(again, first);
      for (final key in ['"output"', '"feedback"', '"limiter"']) {
        expect(first, isNot(contains(key)));
      }
    });

    test('the bundled default project saves at v7 (its effects are merged devices) and again byte for byte', () {
      final p = ProjectDoc.fromJson(jsonDecode(File('assets/projects/default.json').readAsStringSync()) as Map<String, dynamic>);
      final first = jsonEncode(p.toJson());
      expect(jsonDecode(first)['caw_app_project'], 7);
      expect(jsonEncode(_reload(p).toJson()), first);
    });

    test('each v6 routing field writes v6; taking it away writes v5 again', () {
      final p = _project();
      expect(p.savedFileVersion, 5);
      _l(p, 'kick').output = 'verb';
      expect(p.toJson()['caw_app_project'], 6);
      _l(p, 'kick').output = null;
      _l(p, 'kick').sends.add(SendDoc('snare'));  // a send into a track
      expect(p.toJson()['caw_app_project'], 6);
      _l(p, 'kick').sends.single.to = 'verb';     // into a bus: as before
      expect(p.toJson()['caw_app_project'], 5);
      _l(p, 'kick').sends.single.feedback = true;
      expect(p.toJson()['caw_app_project'], 6);
      _l(p, 'kick').sends.single
        ..feedback = false
        ..limiter = false;
      expect(p.toJson()['caw_app_project'], 6);
      _l(p, 'kick').sends.single.limiter = true;
      expect(p.toJson()['caw_app_project'], 5);
      // A send to a layer that is gone is no send into a track.
      _l(p, 'kick').sends.single.to = 'gone';
      expect(p.toJson()['caw_app_project'], 5);
    });

    test('this build reads v5 to v8 and refuses v9', () {
      final p = _project();
      _l(p, 'kick').output = 'verb';
      final v6 = p.toJson();
      expect(_l(ProjectDoc.fromJson(v6), 'kick').output, 'verb');
      final v5 = _project().toJson();
      expect(v5['caw_app_project'], 5);
      expect(ProjectDoc.fromJson(v5).layers, hasLength(7));
      expect(ProjectDoc.fromJson({...v6, 'caw_app_project': 7}).layers, hasLength(7));
      expect(ProjectDoc.fromJson({...v6, 'caw_app_project': 8}).layers, hasLength(7));
      expect(() => ProjectDoc.fromJson({...v6, 'caw_app_project': 9}), throwsA(isA<NewerProjectFormat>()));
      expect(ProjectDoc.fileVersion, 8);
      expect(ProjectDoc.mergedFileVersion, 7);
      expect(ProjectDoc.routingFileVersion, 6);
      expect(ProjectDoc.baseFileVersion, 5);
    });
  });

  group('the routing plan', () {
    test('an output override replaces the folder route; a looping or bus-less one leaves it', () {
      final p = _project();
      _l(p, 'bass').output = 'verb';   // out of its Group into the Verb bus
      _l(p, 'grp').output = 'bass';    // not a bus: left out
      _l(p, 'verb').output = 'org';    // a folder without a bus: left out
      var plan = RoutingPlan.of(p);
      expect(plan.outputOf(_l(p, 'bass')), 'verb');
      expect(plan.outputPlays(_l(p, 'bass')), isTrue);
      expect(plan.reaches('bass', 'grp'), isFalse, reason: 'the override takes the place of the folder route');
      expect(plan.outputPlays(_l(p, 'grp')), isFalse);
      expect(plan.outputOf(_l(p, 'verb')), isNull);
      // Verb → Delay, then Delay → Verb would loop: the first in track order plays, the second falls back.
      _l(p, 'verb').output = 'dly';
      _l(p, 'dly').output = 'verb';
      plan = RoutingPlan.of(p);
      expect(plan.outputOf(_l(p, 'verb')), 'dly');
      expect(plan.outputPlays(_l(p, 'dly')), isFalse);
      expect(plan.outputOf(_l(p, 'dly')), isNull);
      // A folder can't output into a bus inside it (that bus feeds it).
      final q = _project();
      q.layers.add(LayerDoc(id: 'sub', name: 'Sub', color: 0, isFolder: true, parentId: 'grp'));
      _l(q, 'grp').output = 'sub';
      expect(RoutingPlan.of(q).outputPlays(_l(q, 'grp')), isFalse);
      expect(RoutingPlan.of(q).canOutput(_l(q, 'grp'), 'sub'), isFalse);
      expect(RoutingPlan.of(q).canOutput(_l(q, 'grp'), 'verb'), isTrue);
    });

    test('an output override changes which sends loop', () {
      final p = _project();
      _l(p, 'verb').sends.add(SendDoc('grp'));  // Verb → Group: fine while Group goes to the master
      expect(RoutingPlan.of(p).sendPlays(_l(p, 'verb'), 0), isTrue);
      _l(p, 'grp').output = 'verb';             // Group → Verb now: the send would loop and is left out
      final plan = RoutingPlan.of(p);
      expect(plan.outputPlays(_l(p, 'grp')), isTrue, reason: 'outputs come before sends');
      expect(plan.sendPlays(_l(p, 'verb'), 0), isFalse);
      expect(_engineLayer(p, 'verb')['sends'], isNull);
      expect(_engineLayer(p, 'grp')['output'], 'verb');
    });

    test('a send can go into a track; one that would loop plays only as a feedback send', () {
      final p = _project();
      _l(p, 'kick').sends.add(SendDoc('snare'));
      _l(p, 'snare').sends.add(SendDoc('kick'));                   // closes kick → snare → kick: left out
      _l(p, 'snare').sends.add(SendDoc('verb'));
      _l(p, 'verb').sends.add(SendDoc('kick', feedback: true));    // closes a loop, but it is a feedback send
      final plan = RoutingPlan.of(p);
      expect(plan.sendPlays(_l(p, 'kick'), 0), isTrue);
      expect(plan.sendPlays(_l(p, 'snare'), 0), isFalse);
      expect(plan.sendPlays(_l(p, 'snare'), 1), isTrue);
      expect(plan.sendPlays(_l(p, 'verb'), 0), isTrue);
      expect(plan.canSend(_l(p, 'snare'), 'kick'), isFalse);
      expect(plan.canSendFeedback(_l(p, 'snare'), 'kick'), isTrue);
      // A feedback send is no edge: nothing it closes counts against the others.
      expect(plan.reaches('verb', 'kick'), isFalse);
      // Never into itself, a folder without a bus, or a missing layer, feedback or not.
      expect(plan.canSendFeedback(_l(p, 'kick'), 'kick'), isFalse);
      expect(plan.canSendFeedback(_l(p, 'kick'), 'org'), isFalse);
      expect(plan.canSendFeedback(_l(p, 'kick'), 'gone'), isFalse);
      expect(plan.canSendFeedback(_l(p, 'org'), 'kick'), isFalse, reason: 'a bus-less folder carries no sound');
      expect(_engineLayer(p, 'kick')['sends'], [{'to': 'snare', 'level': 0.5}]);
      expect(_engineLayer(p, 'snare')['sends'], [{'to': 'verb', 'level': 0.5}], reason: 'no unbroken loop reaches the engine');
      expect(_engineLayer(p, 'verb')['sends'], [{'to': 'kick', 'level': 0.5, 'feedback': true}]);
    });

    test('a limiter turned off reaches the engine only as the send says', () {
      final p = _project();
      _l(p, 'verb').sends.add(SendDoc('dly', feedback: true, limiter: false));
      expect(_engineLayer(p, 'verb')['sends'], [{'to': 'dly', 'level': 0.5, 'feedback': true, 'limiter': false}]);
    });

    test('a key may come from a track fed by sends, but never closes a loop', () {
      final p = _project();
      final duck = ComponentUseDoc('org.caw.ducker')..key = ComponentKeyDoc('snare');
      _l(p, 'kick').sends.add(SendDoc('snare'));
      _l(p, 'bass').components.add(duck);
      var plan = RoutingPlan.of(p);
      expect(plan.keyPlays(_l(p, 'bass'), duck), isTrue);
      // The bass sending into the snare: a key from the snare would hear the bass itself.
      _l(p, 'bass').sends.add(SendDoc('snare'));
      plan = RoutingPlan.of(p);
      expect(plan.canKey(_l(p, 'bass'), 'snare'), isFalse);
      expect(plan.keyPlays(_l(p, 'bass'), duck), isFalse);
      // Through a feedback send it is no loop the key closes (the send is no edge).
      _l(p, 'bass').sends.single.feedback = true;
      expect(RoutingPlan.of(p).keyPlays(_l(p, 'bass'), duck), isTrue);
    });

    test('the engine gets an output only when it plays', () {
      final p = _project();
      _l(p, 'kick').output = 'verb';
      _l(p, 'snare').output = 'org';
      expect(_engineLayer(p, 'kick')['output'], 'verb');
      expect(_engineLayer(p, 'snare').containsKey('output'), isFalse);
      expect(_engineLayer(p, 'bass').containsKey('output'), isFalse);
      expect(_engineLayer(p, 'bass')['parent'], 'grp', reason: 'parent keeps meaning the folder');
    });
  });

  group('straight to the master', () {
    test('@master takes a track in a bus folder to the master: plan, engine JSON, file and edit', () {
      final p = _project();
      final bass = _l(p, 'bass');
      bass.output = LayerDoc.toMaster;
      final plan = RoutingPlan.of(p);
      expect(plan.outputPlays(bass), isTrue);
      expect(plan.outputOf(bass), isNull);
      expect(plan.reaches('bass', 'grp'), isFalse);
      // With the bass out of its Group, the Group may send into the bass.
      expect(plan.canSend(_l(p, 'grp'), 'bass'), isTrue);
      expect(_engineLayer(p, 'bass')['output'], '@master');
      expect(_engineLayer(p, 'bass')['parent'], 'grp');
      expect(p.usesRoutingV6, isTrue);
      expect(p.toJson()['caw_app_project'], 6);
      expect(_l(_reload(p), 'bass').output, '@master');
      // A bus-less folder carries nothing, so it has no output to set.
      _l(p, 'org').output = LayerDoc.toMaster;
      expect(RoutingPlan.of(p).outputPlays(_l(p, 'org')), isFalse);
      expect(_engineLayer(p, 'org').containsKey('output'), isFalse);
    });

    test('setOutput(@master) is one undo step and outputTargets offers it only off the master', () {
      final s = _state();
      final bass = _l(s.project, 'bass');
      expect(s.outputTargets(_l(s.project, 'kick')).map((t) => t.id), isNot(contains('@master')));
      expect(s.setOutput(bass, LayerDoc.toMaster), isTrue);
      expect(s.outputOf(bass), isNull);
      s.endUndoStep();
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'bass').output, isNull);
      expect(s.outputOf(_l(s.project, 'bass'))?.id, 'grp');
    });
  });

  group('the edits', () {
    test('setOutput: buses without a loop, null for the default, one undo step', () {
      final s = _state();
      final bass = _l(s.project, 'bass');
      final grp = _l(s.project, 'grp');
      expect(s.outputOf(bass)?.id, 'grp');
      expect(s.outputTargets(bass).map((t) => t.id), ['@master', 'grp', 'verb', 'dly']);
      expect(s.outputTargets(bass).first.bus, isNull);
      expect(s.outputTargets(grp).map((t) => t.id), ['verb', 'dly'], reason: 'not itself; already on the master');
      expect(s.setOutput(bass, 'verb'), isTrue);
      expect(s.outputOf(bass)?.id, 'verb');
      s.endUndoStep();
      expect(s.setOutput(bass, 'org'), isFalse, reason: 'no bus');
      expect(s.setOutput(bass, 'kick'), isFalse, reason: 'a track is no output');
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'bass').output, isNull);
      expect(s.outputOf(_l(s.project, 'bass'))?.id, 'grp');
      // Delay → Verb makes Verb → Delay a loop.
      expect(s.setOutput(_l(s.project, 'dly'), 'verb'), isTrue);
      expect(s.outputTargets(_l(s.project, 'verb')).map((t) => t.id), isNot(contains('dly')));
      expect(s.setOutput(_l(s.project, 'verb'), 'dly'), isFalse);
      expect(s.setOutput(_l(s.project, 'dly'), null), isTrue);
      expect(_l(s.project, 'dly').output, isNull);
    });

    test('addSend into a track, sendChoices marks what only feedback can reach', () {
      final s = _state();
      final kick = _l(s.project, 'kick');
      final snare = _l(s.project, 'snare');
      expect(s.addSend(kick, 'snare')?.to, 'snare');
      s.endUndoStep();
      expect(s.addSend(kick, 'snare'), isNull, reason: 'already there');
      expect(s.addSend(snare, 'kick'), isNull, reason: 'a plain send would loop');
      final choices = {for (final c in s.sendChoices(snare)) c.layer.id: c.feedbackOnly};
      expect(choices, {'kick': true, 'grp': false, 'bass': false, 'verb': false, 'dly': false});
      expect(s.sendTargets(snare).map((b) => b.id), ['grp', 'verb', 'dly'], reason: 'sendTargets stays buses only');
      final fb = s.addSend(snare, 'kick', feedback: true);
      expect(fb?.feedback, isTrue);
      s.endUndoStep();
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'snare').sends, isEmpty);
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'kick').sends, isEmpty);
    });

    test('setSendFeedback and setSendLimiter: one undo step each; a plain send may not close a loop', () {
      final s = _state();
      final kick = _l(s.project, 'kick');
      final snare = _l(s.project, 'snare');
      s.addSend(kick, 'snare');
      s.addSend(snare, 'kick', feedback: true);
      s.endUndoStep();
      expect(s.setSendFeedback(snare, 0, false), isFalse, reason: 'it would loop');
      expect(snare.sends.single.feedback, isTrue);
      expect(s.setSendFeedback(kick, 0, true), isTrue);
      s.endUndoStep();
      // Both are feedback sends now: either may go back to plain, not both.
      expect(s.setSendFeedback(snare, 0, false), isTrue);
      s.endUndoStep();
      expect(s.setSendFeedback(kick, 0, false), isFalse);
      s.setSendLimiter(snare, 0, false);
      expect(snare.sends.single.limiter, isFalse);
      s.endUndoStep();
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'snare').sends.single.limiter, isTrue);
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'snare').sends.single.feedback, isTrue);
      expect(s.undo(), isTrue);
      expect(_l(s.project, 'kick').sends.single.feedback, isFalse);
    });

    test('a removed send into a track and the engine index skip what does not play', () {
      final s = _state();
      final kick = _l(s.project, 'kick');
      final snare = _l(s.project, 'snare');
      s.addSend(kick, 'snare');
      snare.sends.add(SendDoc('kick'));  // loops: never pushed
      snare.sends.add(SendDoc('verb'));
      expect(s.engineSendIndex(snare, 0), isNull);
      expect(s.engineSendIndex(snare, 1), 0);
      s.removeSend(kick, 0);
      expect(s.engineSendIndex(snare, 0), 0, reason: 'with the kick send gone it closes no loop');
      expect(s.keySources(_l(s.project, 'bass')).map((l) => l.id), contains('snare'));
    });
  });
}
