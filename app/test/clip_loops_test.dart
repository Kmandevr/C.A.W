// A MIDI clip's own loop point and its clip automation (owner, 2026-11-11): the engine JSON, the unrolled lanes
// (loop repeats, source offset, a moved or lengthened clip, the track lane outside the clip), and moving a lane
// between the clip and the track, each one undo step.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_edit.dart';
import 'package:caw/model/clip_automation.dart';
import 'package:caw/model/clip_loop_edit.dart';
import 'package:caw/model/pattern_doc.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

// An 8-step pattern.
const _source = '---\nkind: pattern\nname: Riff\nlength: 8\n---\n0 C3 1 1\n5 E3 1 1\n';

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Clip loop test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _source),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [
        ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16),
      ]),
    ]);

Map<String, dynamic> engine(ProjectDoc p) => jsonDecode(p.toEngineJson()) as Map<String, dynamic>;
List<(double, double)> pts(List<AutomationPointDoc> l) => [for (final p in l) (p.step, p.value)];
List<(double, double)> jsonPts(Map<String, dynamic> lane) =>
    [for (final p in lane['points'] as List) (((p as Map)['step'] as num).toDouble(), (p['value'] as num).toDouble())];

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
  });
  tearDown(() => s.dispose());

  LayerDoc layer() => s.project.layers.first;
  ClipDoc clip() => layer().clips.first;
  Map<String, dynamic> engineLayer() => (engine(s.project)['layers'] as List).first as Map<String, dynamic>;
  Map<String, dynamic>? engineLane(String target) => ((engineLayer()['automation'] as List).cast<Map<String, dynamic>>())
      .where((l) => l['target'] == target).firstOrNull;

  group('loop point', () {
    test('the project and the engine carry it; unset plays at the pattern length as before', () {
      expect((engineLayer()['clips'] as List).first, isNot(contains('loop_steps')));
      expect(clip().toJson(), isNot(contains('loop_steps')));
      expect(s.project.clipLoopSteps(clip()), 8);
      s.setClipLoop(layer(), clip(), 4);
      expect(clip().loopSteps, 4);
      expect(((engineLayer()['clips'] as List).first as Map)['loop_steps'], 4);
      expect(ClipDoc.fromJson(clip().toJson()).loopSteps, 4);
      expect(s.project.clipLoopSteps(clip()), 4);
      s.setClipLoop(layer(), clip(), null);
      expect(clip().loopSteps, isNull);
    });

    test('setting it is one undo step', () {
      s.endUndoStep();
      s.setClipLoop(layer(), clip(), 3);
      expect(s.undo(), isTrue);
      expect(clip().loopSteps, isNull);
      expect(s.redo(), isTrue);
      expect(clip().loopSteps, 3);
    });

    test('a split and a duplicate keep it, and the notes written out follow it', () {
      s.setClipLoop(layer(), clip(), 4);
      final notes = clipNotes(PatternDoc.parse(_source).doc!, clip(), 4)!;
      // The note at step 5 is past the loop point: only the C3 every 4 steps plays.
      expect([for (final n in notes) n.at.toDouble()], [0, 4, 8, 12]);
      s.duplicateClip(layer(), clip(), linked: true);
      expect(layer().clips.last.loopSteps, 4);
    });
  });

  group('clip automation unrolled for the engine', () {
    void lane(List<(double, double)> points, {String target = 'volume'}) {
      clip().automation.add(ClipAutomationLaneDoc(targetType: 'track', target: target,
          points: [for (final (a, b) in points) AutomationPointDoc(step: a, value: b)]));
    }

    test('repeats every loop, with the track\'s value outside the clip', () {
      layer().volume = 0.5;
      s.setClipLoop(layer(), clip(), 4);
      lane([(0, 0.0), (4, 1.0)]);
      expect(jsonPts(engineLane('volume')!), [
        (0, 0.5), (16, 0.5), (16, 0.0), (20, 1.0), (20, 0.0), (24, 1.0), (24, 0.0), (28, 1.0), (28, 0.0), (32, 1.0),
        (32, 0.5),
      ]);
    });

    test('starts at the source offset, inside the loop', () {
      layer().volume = 0.5;
      clip().sourceOffsetSteps = 6; // 8-step loop: the first pass plays clip time 6..8, then 0..8 twice
      lane([(0, 0.0), (8, 0.8)]);
      final got = jsonPts(engineLane('volume')!);
      expect(got.sublist(0, 2), [(0, 0.5), (16, 0.5)]);
      expect(got[2].$1, 16);
      expect(got[2].$2, closeTo(0.6, 1e-9));
      expect(got.sublist(3, 6), [(18, 0.8), (18, 0.0), (26, 0.8)]);
      expect(got.last, (32, 0.5));
    });

    test('a moved clip takes its automation along; a longer one repeats it', () {
      lane([(0, 0.2), (8, 0.6)]);
      s.moveClip(layer(), clip(), 40);
      var got = jsonPts(engineLane('volume')!);
      expect(got.firstWhere((p) => p.$2 == 0.2).$1, 40);
      s.resizeClip(layer(), clip(), 24);
      got = jsonPts(engineLane('volume')!);
      expect([for (final p in got) if (p.$2 == 0.2) p.$1], [40, 48, 56], reason: 'three passes of the 8-step loop');
      expect(got.last.$1, 64);
    });

    test('the clip lane wins inside the clip, the track lane elsewhere; a muted clip adds nothing', () {
      layer().automation.add(AutomationLaneDoc(target: 'pan', points: [
        AutomationPointDoc(step: 0, value: -1), AutomationPointDoc(step: 64, value: 1)]));
      lane([(0, 0.0)], target: 'pan');
      final got = jsonPts(engineLane('pan')!);
      // The track lane reaches 0 at step 32 too, so the clip's end needs no jump.
      expect(got, [(0, -1.0), (16, -0.5), (16, 0.0), (24, 0.0), (32, 0.0), (64, 1.0)]);
      clip().mute = true;
      expect(jsonPts(engineLane('pan')!), [(0, -1.0), (64, 1.0)]);
    });

    test('an instrument lane becomes a project lane on the track', () {
      layer().instrument = ComponentUseDoc('org.caw.test.osc', {'level': 0.3});
      clip().automation.add(ClipAutomationLaneDoc(targetType: 'instrument', target: 'level',
          points: [AutomationPointDoc(step: 0, value: 0.9)]));
      final lanes = (engine(s.project)['automation'] as List).cast<Map<String, dynamic>>();
      final level = lanes.singleWhere((l) => l['target'] == 'level');
      expect(level['layer'], 'a');
      expect(jsonPts(level), [(0, 0.3), (16, 0.3), (16, 0.9), (24, 0.9), (32, 0.9), (32, 0.3)]);
    });

    test('a 1-step loop over a long clip stays bounded', () {
      s.setClipLoop(layer(), clip(), 1);
      clip().lengthSteps = 1 << 20;
      lane([(0, 0.0), (1, 1.0)]);
      expect((engineLane('volume')!['points'] as List).length, lessThanOrEqualTo(kMaxClipLanePoints * 2));
    });
  });

  group('moving a lane', () {
    test('clip to track: the clip\'s passes become the track lane; one undo step', () {
      layer().volume = 0.5;
      s.setClipLoop(layer(), clip(), 4);
      final l = s.addClipLane(layer(), clip(), 'track', 'volume')!;
      expect(pts(l.points), [(0, 0.5), (4, 0.5)]);
      s.updateClipLanePoint(layer(), clip(), l, 0, 0, 0.0);
      s.endUndoStep();
      s.moveClipLaneToTrack(layer(), clip(), l);
      expect(clip().automation, isEmpty);
      final track = layer().automation.single;
      expect(track.target, 'volume');
      expect(pts(track.points).first, (0, 0.5));
      expect([for (final p in track.points) if (p.value == 0.0) p.step], [16, 20, 24, 28]);
      expect(s.undo(), isTrue);
      expect(layer().automation, isEmpty);
      expect(layer().clips.first.automation.single.points.first.value, 0.0);
    });

    test('track to clip: the values over the clip\'s first loop, in clip time', () {
      layer().automation.add(AutomationLaneDoc(target: 'volume', points: [
        AutomationPointDoc(step: 16, value: 0.0), AutomationPointDoc(step: 20, value: 1.0),
        AutomationPointDoc(step: 30, value: 0.0)]));
      expect(s.moveTrackLaneToClip(layer(), clip(), automationKey('track', 'volume', layerId: 'a')), isTrue);
      expect(layer().automation, isEmpty);
      final l = clip().automation.single;
      expect(pts(l.points), [(0, 0.0), (4, 1.0), (8, 0.6)]);
    });
  });
}
