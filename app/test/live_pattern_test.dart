// A piano-roll drag heard while the song plays (#170): the project goes to the engine with the dragged pattern's text,
// and nothing else in the app changes (no save, no undo step, no listener notified). The engine part needs CAW_LIB.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  test('the engine project can carry a pattern text in place of its run source', () {
    final s = AppState();
    s.project = s.demoProject();
    final m = s.project.modules.first;
    final json = jsonDecode(s.project.toEngineJson(sourceOverrides: {m.id: 'live text'})) as Map<String, dynamic>;
    final modules = (json['modules'] as List).cast<Map<String, dynamic>>();
    expect(modules.firstWhere((x) => x['id'] == m.id)['source'], 'live text');
    for (final x in modules.where((x) => x['id'] != m.id)) {
      expect(x['source'], s.project.modules.firstWhere((y) => y.id == x['id']).runSource);
    }
    expect(m.runSource, isNot('live text'));
  });

  test('a live step built from the cached project matches a full build, and an edit between steps shows', () {
    final s = AppState();
    s.project = s.demoProject();
    s.starting = false;
    addTearDown(s.dispose);
    final m = s.project.modules.first;
    String full(String text) =>
        s.project.toEngineJson(voices: 32, swap: s.settings.swapTiming.name, sourceOverrides: {m.id: text});
    expect(s.liveEngineJson(m.id, 'a "quoted" step\n'), full('a "quoted" step\n'));
    // A knob moved live while the drag goes on (no save yet) and a volume change both reach the next step.
    s.setNativeParamLive(s.project.layers[3], 0, 'mix', 0.77);
    s.setInstrumentParamLive(s.project.layers.first, 'decay', 0.42);
    expect(s.liveEngineJson(m.id, 'b'), full('b'));
    s.mixLayer(s.project.layers[1], volume: 0.123);
    expect(s.liveEngineJson(m.id, 'c'), full('c'));
    expect(s.liveEngineJson(s.project.modules[1].id, 'd'),
        s.project.toEngineJson(voices: 32, swap: s.settings.swapTiming.name, sourceOverrides: {s.project.modules[1].id: 'd'}));
  });

  test('a live pattern step reaches the engine without touching the model or notifying', () async {
    final s = AppState();
    s.engine = Engine.create();
    s.project = s.demoProject();
    s.ready = true;
    s.starting = false;
    s.useAudioDevice = false;
    addTearDown(s.dispose);
    s.info = await s.engine!.setProject(s.project.toEngineJson());
    final pattern = s.project.modules.firstWhere((m) => headerValue(m.source, 'kind') == 'pattern');
    final source = pattern.source, runSource = pattern.runSource;
    var notified = 0;
    s.addListener(() => notified++);
    final edited = '${pattern.runSource.trimRight()}\n0 C4 4 1  bend 0:0 1:-12\n';
    await s.livePattern(pattern.id, edited);
    await s.livePattern(pattern.id, null); // a cancelled drag: the project as it is again
    expect(notified, 1); // only the resend of the project as it is tells the app
    expect(pattern.source, source);
    expect(pattern.runSource, runSource);
    expect(s.engineError, isNull);
  }, skip: skip);
}
