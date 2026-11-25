// Timber removed (1.1.3): an old project's Timber tracks open as the new instruments, their lanes follow, and a one-time note says so.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc timberProject() {
  final p = ProjectDoc(id: 'old', name: 'Old Timber song');
  p.layers.add(LayerDoc(id: 'cello', name: 'Cello', color: 0)
    ..instrument = ComponentUseDoc('org.caw.timber', {'variant': 4, 'section': 2, 'pressure': 0.7}));
  p.layers.add(LayerDoc(id: 'organ', name: 'Organ', color: 0)
    ..instrument = ComponentUseDoc('org.caw.timber', {'variant': 2, 'rotary': 1}));
  p.automation.add(ProjectAutomationLaneDoc(targetType: 'instrument', layerId: 'cello', target: 'pressure'));
  p.automation.add(ProjectAutomationLaneDoc(targetType: 'instrument', layerId: 'organ', target: 'tone'));
  return p;
}

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final skip = lib == null || lib.isEmpty;

  test('Timber is a retired instrument: the engine converts it when a project opens', () {
    expect(ComponentUseDoc.retiredInstruments, contains('org.caw.timber'));
    expect(LayerDoc.newInstrumentValues, isNot(contains('org.caw.timber')));
  });

  test('a project with Timber opens as the new instruments, its lanes follow, and the note shows once (needs CAW_LIB)',
      () async {
    final s = AppState();
    s.engine = Engine.create();
    s.ready = true;
    s.starting = false;
    s.useAudioDevice = false;
    addTearDown(s.dispose);
    await s.importProject(timberProject());
    final layers = {for (final l in s.project.layers) l.id: l};
    expect(layers['cello']!.instrument!.id, 'org.caw.nightingale');
    expect(layers['cello']!.instrument!.params['variant'], 2);
    expect(layers['organ']!.instrument!.id, 'org.caw.synth.flagship');
    expect(layers['organ']!.instrument!.preset, 'Tonewheel organ');
    final lanes = s.project.automation.where((l) => l.targetType == 'instrument').toList();
    expect([for (final l in lanes) '${l.layerId}:${l.target}'], ['cello:pressure'],
        reason: 'the cello keeps its bow pressure lane; Kestrel has no Tone in the same units');
    expect(s.openNotice, AppState.timberNotice);
    // Saved, the project names Timber no more: opening it again says nothing.
    await s.importProject(ProjectDoc.fromJson(s.project.toJson()));
    expect(s.openNotice, isNull);
  }, skip: skip);
}
