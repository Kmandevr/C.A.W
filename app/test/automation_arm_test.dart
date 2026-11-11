// Per-parameter arm for automation writing (gap 4, REAPER's envelope arm): the Automate button writes only armed
// lanes (new ones start armed), Write mode leaves a disarmed lane alone, the flag is saved, and the lane header's arm
// button toggles it.
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/automation_writer.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/arrange/track_lanes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class PlayState extends AppState {
  bool playing = false;
  double at = 0;
  @override
  bool get transportOn => playing;
  @override
  double get playheadStep => at;

  void stop() {
    playing = false;
    stopPlayback();
  }
}

void main() {
  late PlayState s;
  late AutomationWriter w;
  LayerDoc keys() => s.project.layers.first;
  AutomationLaneDoc lane(String target) => keys().automation.firstWhere((a) => a.target == target);

  setUp(() {
    s = PlayState()
      ..project = (ProjectDoc(id: 'p', name: 'Arm')
        ..layers.add(LayerDoc(id: 'L1', name: 'Keys', color: 0, volume: 1, automation: [
          AutomationLaneDoc(target: 'volume', points: [AutomationPointDoc(step: 0, value: 1)], armed: false),
        ])));
    s.ready = true;
    s.starting = false;
    w = AutomationWriter(s, pointers: false)..setArmed(true);
    s.playing = true;
  });
  tearDown(() => w.dispose());

  test('the arm is saved, armed by default', () {
    final back = AutomationLaneDoc.fromJson(lane('volume').toJson());
    expect(back.armed, isFalse);
    expect(AutomationLaneDoc.fromJson(AutomationLaneDoc(target: 'pan').toJson()).armed, isTrue);
    final p = ProjectAutomationLaneDoc(targetType: 'component', target: 'mix', layerId: 'L1', component: 0, armed: false);
    expect(ProjectAutomationLaneDoc.fromJson(p.toJson()).armed, isFalse);
  });

  test('Touch skips a disarmed lane; a control with no lane yet is written', () {
    w.pointerDown();
    s.at = 4;
    s.mixLayer(keys(), volume: 0.5, pan: 0.5);
    s.at = 8;
    w.pointerUp();
    expect(lane('volume').points.length, 1);
    expect(lane('pan').points.length, greaterThan(1));
    expect(lane('pan').armed, isTrue);
  });

  test('Write leaves a disarmed lane alone, and writes it once armed', () {
    w.setMode(AutomationMode.write);
    s.at = 2;
    s.meters = const EngineMeters(playing: true);
    s.tick.value++;
    expect(s.suspendedLanes, isEmpty, reason: 'the disarmed lane keeps playing');
    s.at = 6;
    s.stop();
    expect(lane('volume').points.length, 1);
    lane('volume').armed = true;
    w.setMode(AutomationMode.touch);
    s.playing = true;
    w.pointerDown();
    s.at = 4;
    s.mixLayer(keys(), volume: 0.5);
    s.at = 6;
    w.pointerUp();
    expect(lane('volume').points.length, greaterThan(1));
  });

  testWidgets('the lane header\'s arm button toggles it', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: s,
      builder: (_, _) => TrackLaneHeaders(state: s, layer: keys(), indent: 0)))));
    final key = ValueKey('lane-arm-${automationKey('track', 'volume', layerId: 'L1')}');
    expect(find.byKey(key), findsOneWidget);
    await tester.tap(find.byKey(key));
    await tester.pump();
    expect(lane('volume').armed, isTrue);
    await tester.tap(find.byKey(key));
    await tester.pump();
    expect(lane('volume').armed, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });
}
