// Play-ahead intent (play_ahead_intent.dart): a device page open, a finger on a track's FX chain, a held key, an armed
// input and a device edit each reach the engine's caw_engine_play_ahead_intent through the one helper (a fake engine).
import 'dart:typed_data';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/templates.dart';
import 'package:caw/model/collab/project_ops.dart';
import 'package:caw/model/live_midi.dart';
import 'package:caw/model/mixer_fx.dart' show masterLayerId;
import 'package:caw/model/play_ahead_intent.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart' show builtinInfos;
import 'use_like_owner/harness.dart' show RecordingEngine;

/// Records the intents the app sends (and takes the rest as the harness's engine does).
class IntentEngine extends RecordingEngine {
  final intents = <(String, AheadIntent)>[];

  @override
  void playAheadIntent(String layerId, AheadIntent intent) => intents.add((layerId, intent));

  @override
  bool get audioOn => true;
  @override
  bool noteOn(String layerId, int id, double pitch, double velocity) => true;
  @override
  bool noteOff(int id) => true;
  @override
  bool notesOff() => true;
  @override
  int componentDisplay(String? layerId, int index, Float32List out) => 0;

  /// What is held per track now, as the engine counts it.
  Map<String, int> get holds {
    final m = <String, int>{};
    for (final (id, i) in intents) {
      if (i == AheadIntent.hold) m[id] = (m[id] ?? 0) + 1;
      if (i == AheadIntent.release) m[id] = (m[id] ?? 0) - 1;
    }
    return m..removeWhere((_, n) => n == 0);
  }
}

(AppState, LayerDoc, IntentEngine) _state() {
  final s = AppState(settings: Settings());
  Motion.setting = MotionLevel.off;
  s.project = s.newProjectDoc();
  s.componentCatalog.set(builtinInfos());
  final layer = LayerDoc(id: 'a', name: 'Track 1', color: 2);
  s.project.layers.add(layer);
  s.setNativeInstrument(layer, 'org.caw.synth.flagship');
  s.addNativeEffect(layer, 'org.caw.eq');
  final e = IntentEngine();
  s.engine = e;
  return (s, layer, e);
}

void main() {
  test('owners hold sets; the engine sees one hold and one release each, never the master', () {
    final e = IntentEngine();
    final i = PlayAheadIntent(() => e);
    i.hold(#page, 'a');
    i.hold(#finger, 'a');
    i.hold(#page, 'a');  // already held by this owner: nothing sent
    expect(e.holds, {'a': 2});
    i.holdSet(#page, {'b', masterLayerId});
    expect(e.holds, {'a': 1, 'b': 1});
    i.release(#finger);
    i.release(#page);
    i.release(#page);
    expect(e.holds, isEmpty);
    i.edit('a');
    i.edit(null);
    i.edit(masterLayerId);
    expect(e.intents.last, ('a', AheadIntent.edit));
    expect(e.intents.where((x) => x.$2 == AheadIntent.edit), hasLength(1));
  });

  test('a new engine hears the holds the app has now', () {
    final (s, _, e) = _state();
    s.aheadIntent.hold(#page, 'a');
    s.aheadIntent.hold(#finger, 'a');
    final next = IntentEngine();
    s.engine = next;
    expect(next.holds, {'a': 2});
    s.aheadIntent.release(#page);
    expect(next.holds, {'a': 1});
    expect(e.holds, {'a': 2}, reason: 'the old engine hears nothing more');
  });

  test('a held key, a device edit, a MIDI-armed track and an armed input send intent', () {
    final (s, layer, e) = _state();
    addTearDown(s.dispose);  // previewOn wakes the meter poller; stop it before the test ends
    s.previewOn('a', 7, 60, 0.8);
    expect(e.holds, {'a': 1});
    s.previewOff(7);
    expect(e.holds, isEmpty);
    s.apply(ProjectSet(layer.components.first.uid, OpField.param('gain1'), 3.0));
    expect(e.intents.last, ('a', AheadIntent.edit), reason: 'the touch goes before the value');
    final midi = LiveMidi(s, null);
    midi.armedLayerId = 'a';
    expect(e.holds, {'a': 1});
    midi.armedLayerId = null;
    expect(e.holds, isEmpty);
    s.aheadIntent.holdSet(#input, {'a'});  // engine_sync's armed or monitored inputs, after each update
    expect(e.holds, {'a': 1});
  });

  testWidgets('the device page holds its track while open; a finger on the FX chain while down', (tester) async {
    final (s, layer, e) = _state();
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return FxStack(state: s, layer: layer);
    }))));
    expect(e.holds, isEmpty);
    final g = await tester.startGesture(tester.getCenter(find.byType(FxStack)));
    await tester.pump();
    expect(e.holds, {'a': 1}, reason: 'a finger down on the chain');
    await g.up();
    await tester.pump();
    expect(e.holds, isEmpty);
    openDeviceEditor(ctx, s, layer, 0);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceEditor), findsOneWidget);
    expect(e.holds, {'a': 1}, reason: 'the page is open');
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DeviceEditor), findsNothing);
    expect(e.holds, isEmpty, reason: 'closed: the 3 s start');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));  // the chain's pending timers
  });
}
