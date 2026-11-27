// Clip automation's add mode (owner, 1.1.0 requirement, built 1.1.4): a clip lane overrides the track's or project's
// lane inside the clip (as before) or adds its offset from the target's neutral to it; the JSON, the merge, clamping,
// overlaps, loops, the point bound, copies, ids and the undoable edit.
import 'dart:convert';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/automation_curve.dart';
import 'package:caw/model/clip_automation.dart';
import 'package:caw/model/clip_loop_edit.dart';
import 'package:caw/model/instance_ids.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = '---\nkind: pattern\nname: Riff\nlength: 8\n---\n0 C3 1 1\n5 E3 1 1\n';

AutomationPointDoc _p(double step, double value, [AutomationCurve curve = AutomationCurve.linear]) =>
    AutomationPointDoc(step: step, value: value, curve: curve);

ClipDoc _clip(int start, int length, {bool loop = false}) =>
    ClipDoc(id: 'c$start', patternId: 'pat', startSteps: start, lengthSteps: length, loop: loop);

ClipLaneSpan _span(ClipDoc clip, List<AutomationPointDoc> local, int loop, ClipLaneMode mode) =>
    clipLaneSpan(clip, local, loop, mode: mode);

double _v(List<AutomationPointDoc> lane, double at) => laneValueAt(lane, at, double.nan);

final _pan = clipAddRuleFor('track', 'pan'), _volume = clipAddRuleFor('track', 'volume');
const _add = ClipLaneMode.add, _over = ClipLaneMode.override;

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Add mode test', modules: [
      ModuleDoc(id: 'pat', name: 'Riff', source: _source),
    ], layers: [
      LayerDoc(id: 'a', name: 'Keys', color: 0, clips: [_clip(16, 16)]),
    ]);

void main() {
  group('the file', () {
    test('mode absent reads override; an old file saves byte for byte as it was', () {
      final lane = ClipAutomationLaneDoc(targetType: 'component', target: 'mix', component: 1, device: newId(InstanceIds.device),
          points: [_p(0, 0.2), _p(4, 0.8, AutomationCurve.step)]);
      final saved = jsonEncode(lane.toJson(withIds: true));
      expect(saved, isNot(contains('mode')));
      final read = ClipAutomationLaneDoc.fromJson(jsonDecode(saved) as Map<String, dynamic>)!;
      expect(read.mode, _over);
      expect(jsonEncode(read.toJson(withIds: true)), saved);
      // A whole project with a clip lane, through the project file.
      final p = _project();
      p.layers.first.clips.first.automation.add(ClipAutomationLaneDoc(targetType: 'track', target: 'pan',
          points: [_p(0, 0), _p(8, 0.5)]));
      final file = jsonEncode(p.toJson());
      expect(file, isNot(contains('"mode"')));
      expect(jsonEncode(ProjectDoc.fromJson(jsonDecode(file) as Map<String, dynamic>).toJson()), file);
    });

    test('add is written and read back; an unknown mode reads override', () {
      final lane = ClipAutomationLaneDoc(targetType: 'track', target: 'pan', points: [_p(0, 0.1)], mode: _add);
      expect(lane.toJson()['mode'], 'add');
      expect(ClipAutomationLaneDoc.fromJson(lane.toJson())!.mode, _add);
      for (final odd in ['multiply', 3, null, 'ADD']) {
        expect(ClipAutomationLaneDoc.fromJson({...lane.toJson(), 'mode': odd})!.mode, _over, reason: '$odd');
      }
    });

    test('copies keep the mode; a fresh copy gets new ids, a plain one keeps them', () {
      final lane = ClipAutomationLaneDoc(targetType: 'track', target: 'volume', points: [_p(0, 1), _p(4, 0.5)], mode: _add);
      final same = lane.copy(), fresh = lane.copy(fresh: true);
      expect((same.mode, fresh.mode), (_add, _add));
      expect(same.uid, lane.uid);
      expect([for (final p in same.points) p.uid], [for (final p in lane.points) p.uid]);
      expect(fresh.uid, isNot(lane.uid));
      expect(fresh.points.first.uid, isNot(lane.points.first.uid));
    });
  });

  group('the merge', () {
    test('override is unchanged: the clip lane plays instead of the base', () {
      final base = [_p(0, -0.5), _p(32, 0.5)];
      final merged = mergeClipLanes(base, 0, [_span(_clip(8, 8), [_p(0, 0.2), _p(8, 0.2)], 8, _over)], rule: _pan);
      expect(_v(merged, 10), closeTo(0.2, 1e-12));
      expect(_v(merged, 4), closeTo(-0.375, 1e-12));
    });

    test('add over a base lane: base plus the offset, exact at both lanes\' breakpoints', () {
      // Base pan: a ramp with a kink at 12 (inside the clip); clip lane: centre, up to +0.3 at its step 2, back.
      final base = [_p(0, -0.5), _p(12, 0.1), _p(32, -0.1)];
      final local = [_p(0, 0), _p(2, 0.3), _p(8, 0)];
      final merged = mergeClipLanes(base, 0, [_span(_clip(8, 8), local, 8, _add)], rule: _pan);
      for (final at in [8.0, 9.0, 10.0, 11.0, 12.0, 13.5, 15.0, 15.999]) {
        expect(_v(merged, at), closeTo(_v(base, at) + _v(local, at - 8), 1e-9), reason: 'step $at');
      }
      expect(merged.map((p) => p.step), containsAll([8.0, 10.0, 12.0, 16.0]));
      expect(_v(merged, 4), closeTo(_v(base, 4), 1e-12), reason: 'outside the clip the base plays');
      expect(_v(merged, 20), closeTo(_v(base, 20), 1e-12));
    });

    test('a flat clip lane at the neutral changes nothing', () {
      final base = [_p(0, 0.2), _p(32, 0.9)];
      for (final (rule, centre) in [(_pan, 0.0), (_volume, 1.0)]) {
        final merged = mergeClipLanes(base, 0, [_span(_clip(8, 8), [_p(0, centre), _p(8, centre)], 8, _add)], rule: rule);
        for (var at = 0.0; at < 32; at += 0.5) {
          expect(_v(merged, at), closeTo(_v(base, at), 1e-9));
        }
      }
      // A parameter's neutral is the base's value where the clip starts (0.375 at step 8).
      final param = mergeClipLanes(base, 0, [_span(_clip(8, 8), [_p(0, 0.375)], 8, _add)]);
      expect(_v(param, 12), closeTo(_v(base, 12), 1e-9));
      final up = mergeClipLanes(base, 0, [_span(_clip(8, 8), [_p(0, 0.475)], 8, _add)]);
      expect(_v(up, 12), closeTo(_v(base, 12) + 0.1, 1e-9));
    });

    test('volume adds in decibels: a gain of 0.5 is 6 dB down from the base, two ramps follow the product', () {
      final base = [_p(0, 0.25), _p(32, 1.25)];
      final half = mergeClipLanes(base, 0, [_span(_clip(8, 8), [_p(0, 0.5)], 8, _add)], rule: _volume);
      expect(_v(half, 12), closeTo(_v(base, 12) * 0.5, 1e-9));
      final ramp = [_p(0, 0.5), _p(8, 2)];
      final both = mergeClipLanes(base, 0, [_span(_clip(8, 8), ramp, 8, _add)], rule: _volume);
      for (final at in [8.0, 9.3, 12.0, 14.7]) {
        expect(_v(both, at), closeTo(_v(base, at) * _v(ramp, at - 8), 0.01), reason: 'step $at');
      }
    });

    test('with no base lane it adds to the flat base value', () {
      final merged = mergeClipLanes(const [], 0.4, [_span(_clip(8, 8), [_p(0, -0.2), _p(8, 0.2)], 8, _add)], rule: _pan);
      expect(_v(merged, 8), closeTo(0.2, 1e-12));
      expect(_v(merged, 12), closeTo(0.4, 1e-12));
      expect(_v(merged, 20), closeTo(0.4, 1e-12));
      expect(_v(merged, 0), closeTo(0.4, 1e-12));
    });

    test('the sum is clamped to the target\'s range, with a point where a ramp meets the edge', () {
      final pan = mergeClipLanes(const [], 0.5, [_span(_clip(0, 8), [_p(0, 0), _p(8, 0.8)], 8, _add)], rule: _pan);
      expect(_v(pan, 2), closeTo(0.7, 1e-12));
      expect(_v(pan, 5), closeTo(1, 1e-12), reason: '0.5 + 0.8 * 5/8 reaches 1 at step 5');
      expect(pan.map((p) => p.step), contains(5.0));
      expect(_v(pan, 7), 1);
      expect(_v(pan, 7.999), 1);
      final low = mergeClipLanes(const [], -0.9, [_span(_clip(0, 8), [_p(0, -0.5)], 8, _add)], rule: _pan);
      expect(_v(low, 4), -1);
      final loud = mergeClipLanes(const [], 3, [_span(_clip(0, 8), [_p(0, 2)], 8, _add)], rule: _volume);
      expect(_v(loud, 4), kMaxMixGain);
    });

    test('overlapping clips: the later start wins whatever its mode; an add clip adds to the base, not the clip', () {
      final base = [_p(0, 0)];
      final over = _span(_clip(0, 16), [_p(0, 0.9)], 16, _over), add = _span(_clip(8, 4), [_p(0, 0.1)], 4, _add);
      final m = mergeClipLanes(base, 0, [over, add], rule: _pan);
      expect(_v(m, 4), closeTo(0.9, 1e-12));
      expect(_v(m, 10), closeTo(0.1, 1e-12), reason: 'base 0 + 0.1, not 0.9 + 0.1');
      expect(_v(m, 14), closeTo(0.9, 1e-12), reason: 'after the add clip the override under it plays again');
      // The other way round: an override inside an add clip.
      final add2 = _span(_clip(0, 16), [_p(0, 0.3)], 16, _add), over2 = _span(_clip(8, 4), [_p(0, -0.6)], 4, _over);
      final m2 = mergeClipLanes([_p(0, 0.2)], 0, [add2, over2], rule: _pan);
      expect(_v(m2, 4), closeTo(0.5, 1e-12));
      expect(_v(m2, 10), closeTo(-0.6, 1e-12));
      expect(_v(m2, 14), closeTo(0.5, 1e-12));
    });

    test('a looped clip adds every pass, from the loop\'s start each time', () {
      final base = [_p(0, 0.1)];
      final local = [_p(0, 0), _p(4, 0.4)];
      final m = mergeClipLanes(base, 0, [_span(_clip(16, 16, loop: true), local, 4, _add)], rule: _pan);
      for (final pass in [16.0, 20.0, 24.0, 28.0]) {
        expect(_v(m, pass), closeTo(0.1, 1e-12), reason: 'pass at $pass starts at the loop\'s first value');
        expect(_v(m, pass + 2), closeTo(0.3, 1e-12));
      }
      expect(_v(m, 40), closeTo(0.1, 1e-12));
    });

    test('add parts past the cap are thinned evenly, the same each time, and the base after them is kept', () {
      final base = [_p(0, 0), for (var i = 1; i < 1000; i++) _p(4 + i * 0.008, (i % 2) * 0.2), _p(20, 0.5), _p(32, -0.5)];
      final local = [for (var i = 0; i <= 1000; i++) _p(i * 0.0079, (i % 3) * 0.1)];
      List<AutomationPointDoc> run() =>
          mergeClipLanes(base, 0, [_span(_clip(4, 8), local, 8, _add)], rule: _pan, cap: 200);
      final a = run(), b = run();
      expect(a.length, lessThanOrEqualTo(200));
      expect(a.where((p) => p.step > 4 && p.step < 12).length, greaterThan(100));
      expect([for (final p in a) (p.step, p.value)], [for (final p in b) (p.step, p.value)]);
      expect(_v(a, 4), closeTo(_v(base, 4) + _v(local, 0), 1e-12), reason: 'the span\'s ends stay exact');
      expect(_v(a, 16), closeTo(_v(base, 16), 1e-12));
      expect((a.last.step, a.last.value), (32.0, -0.5), reason: 'the base after the clip is never cut');
      // Under the cap every breakpoint of both lanes inside the clip is sampled.
      final full = mergeClipLanes(base, 0, [_span(_clip(4, 8), local, 8, _add)], rule: _pan);
      expect(full.where((p) => p.step > 4 && p.step < 12).length, greaterThan(1000));
    });

    test('a step lane adds one point per jump, as many as it overrides with', () {
      final local = [for (var i = 0; i < 64; i++) _p(i * 0.25, (i % 4) * 0.1, AutomationCurve.step)];
      final over = mergeClipLanes([_p(0, 0.2)], 0, [_span(_clip(0, 16), local, 16, _over)], rule: _pan);
      final add = mergeClipLanes([_p(0, 0.2)], 0, [_span(_clip(0, 16), local, 16, _add)], rule: _pan);
      expect(add.length, lessThanOrEqualTo(over.length + 2));
      for (var at = 0.0; at < 16; at += 0.125) {
        expect(_v(add, at), closeTo(0.2 + _v(local, at), 1e-12), reason: 'step $at');
      }
    });

    test('a long looped step lane at the point budget keeps the base lane after the clip', () {
      // 4 step points a 1-step loop over a clip of 2^15 steps: clipLaneSpan fills the whole budget.
      final local = [for (var i = 0; i < 4; i++) _p(i * 0.25, i * 0.1, AutomationCurve.step)];
      final clip = _clip(0, 1 << 15, loop: true);
      final span = _span(clip, local, 1, _add);
      expect(span.points.length, greaterThanOrEqualTo(kMaxClipLanePoints));
      final end = (1 << 15).toDouble();
      final after = [for (var i = 0; i < 2000; i++) _p(end + 1 + i, (i % 5) * 0.1)];
      final base = [_p(0, -0.3), _p(end, -0.3), ...after];
      final m = mergeClipLanes(base, 0, [span], rule: _pan);
      expect(m.length, lessThanOrEqualTo(kMaxClipLanePoints * 2));
      final tail = [for (final p in m) if (p.step > end) (p.step, p.value)];
      expect(tail, [for (final p in after) (p.step, p.value)]);
      expect(_v(m, 100.5), closeTo(-0.3 + 0.2, 1e-12));
    });

    test('a curved lane of 65,536 points stays in the cap and keeps the base after it', () {
      final local = [for (var i = 0; i < kMaxClipLanePoints; i++) _p(i / 16, (i % 7) * 0.05, AutomationCurve.slow)];
      final len = kMaxClipLanePoints ~/ 16;
      final after = [for (var i = 0; i < 500; i++) _p(len + 1.0 + i, (i % 3) * 0.2)];
      final base = [for (var i = 0; i < len; i += 2) _p(i.toDouble(), 0.1, AutomationCurve.fast), ...after];
      final m = mergeClipLanes(base, 0, [_span(_clip(0, len), local, len, _add)], rule: _pan);
      expect(m.length, lessThanOrEqualTo(kMaxClipLanePoints * 2));
      // (The base's bent segment from inside the clip to its first point after is followed in pieces, as before.)
      expect([for (final p in m) if (p.step >= len + 1) (p.step, p.value)], [for (final p in after) (p.step, p.value)]);
    });

    test('several add clips and overlaps share the cap; the base around them is kept', () {
      final base = [for (var i = 0; i <= 100; i++) _p(i * 1.0, (i % 2) * 0.1)];
      List<AutomationPointDoc> dense(int n) => [for (var i = 0; i < n; i++) _p(i * 0.05, (i % 3) * 0.1)];
      final spans = [
        _span(_clip(10, 20), dense(400), 20, _add),
        _span(_clip(20, 20), dense(400), 20, _add), // overlaps the first
        _span(_clip(25, 5), [_p(0, 0.7)], 5, _over), // an override inside both
        _span(_clip(50, 20), dense(400), 20, _add),
      ];
      final m = mergeClipLanes(base, 0, spans, rule: _pan, cap: 600);
      expect(m.length, lessThanOrEqualTo(600));
      expect(_v(m, 27), closeTo(0.7, 1e-12));
      for (final at in [0.0, 5.0, 9.0, 45.0, 75.0, 90.5, 100.0]) {
        expect(_v(m, at), closeTo(_v(base, at), 1e-12), reason: 'base at $at');
      }
      expect(_v(m, 10), closeTo(_v(base, 10), 1e-12), reason: 'an add span starts at the base plus its first value, 0');
    });
  });

  group('the project', () {
    late AppState s;
    setUp(() {
      s = AppState(settings: Settings());
      s.project = _project();
      s.starting = false;
      s.history.reset(jsonEncode(s.project.toJson()));
    });
    tearDown(() => s.dispose());

    LayerDoc layer() => s.project.layers.first;
    ClipDoc clip() => layer().clips.first;
    List<AutomationPointDoc> engineVolume() {
      final j = jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>;
      final lanes = ((j['layers'] as List).first as Map)['automation'] as List;
      final lane = lanes.cast<Map<String, dynamic>>().firstWhere((l) => l['target'] == 'volume');
      return [for (final p in lane['points'] as List) AutomationPointDoc.fromJson(p as Map<String, dynamic>)];
    }

    test('the engine gets the sum: volume with no track lane adds to the fader', () {
      layer().volume = 0.5;
      final lane = s.addClipLane(layer(), clip(), 'track', 'volume')!;
      s.updateClipLanePoint(layer(), clip(), lane, 0, 0, 0.5);
      s.updateClipLanePoint(layer(), clip(), lane, 1, 8, 0.5);
      expect(_v(engineVolume(), 20), closeTo(0.5, 1e-12), reason: 'override: the clip lane plays');
      s.setClipLaneMode(layer(), clip(), lane, _add);
      expect(_v(engineVolume(), 20), closeTo(0.25, 1e-12), reason: 'add: 6 dB down from the fader');
      expect(_v(engineVolume(), 8), closeTo(0.5, 1e-12));
    });

    test('setting the mode is one undo step and leaves the ids alone', () {
      final lane = s.addClipLane(layer(), clip(), 'track', 'pan')!;
      final ids = (lane.uid, [for (final p in lane.points) p.uid].join(','));
      s.endUndoStep();
      s.setClipLaneMode(layer(), clip(), lane, _add);
      expect(clip().automation.single.mode, _add);
      expect(s.undo(), isTrue);
      final back = clip().automation.single;
      expect(back.mode, _over);
      expect((back.uid, [for (final p in back.points) p.uid].join(',')), ids);
      expect(s.redo(), isTrue);
      expect(clip().automation.single.mode, _add);
      expect(clip().automation.single.uid, ids.$1);
      // The same mode again is no step: one undo still goes back to override.
      s.setClipLaneMode(layer(), clip(), clip().automation.single, _add);
      expect(s.undo(), isTrue);
      expect(clip().automation.single.mode, _over);
    });

    test('a duplicated clip keeps the mode under new ids; moving to the track bakes the sum', () {
      layer().volume = 0.8;
      final lane = s.addClipLane(layer(), clip(), 'track', 'volume')!;
      s.setClipLaneMode(layer(), clip(), lane, _add);
      final copy = lane.copy(fresh: true);
      expect((copy.mode, copy.uid == lane.uid), (_add, false));
      for (var i = 0; i < lane.points.length; i++) {
        s.updateClipLanePoint(layer(), clip(), lane, i, lane.points[i].step, 0.5);
      }
      s.endUndoStep();
      s.moveClipLaneToTrack(layer(), clip(), lane);
      final track = layer().automation.single.points;
      expect(_v(track, 20), closeTo(0.4, 1e-12));
      expect(_v(track, 8), closeTo(0.8, 1e-12));
    });
  });
}
