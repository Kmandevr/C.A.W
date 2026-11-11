// Model tests: project files round-trip, the engine JSON uses run code, header parsing and layer length choices.
import 'dart:convert';

import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/project.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc sample() => ProjectDoc(id: 'p1', name: 'Test', bpm: 140, globals: {'swing': 0.2}, modules: [
      ModuleDoc(id: 'm1', name: 'Lead', source: 't*2', runSource: 't', params: {'shift': 6}),
      ModuleDoc(id: 'fx', name: 'Crush', source: '---\nkind: effect\n---\nin'),
    ], layers: [
      LayerDoc(id: 'l1', name: 'Lead', color: 2, generatorId: 'm1', effectIds: ['fx'], lengthSteps: 48, volume: 0.5, pan: -0.3, solo: true),
      LayerDoc(id: 'l2', name: 'Notes', color: 1, generatorId: 'm1', patternId: 'pat'),
    ]);

void main() {
  test('a new C++ effect starts from the blank pass-through template with a valid manifest', () {
    final c = CppComponentDoc.blankEffect(id: 'c1', name: 'My "Delay"');
    expect(c.componentId, 'local.my-delay.c1');
    expect(c.files.keys, containsAll(['caw-component.json', 'src/effect.cpp']));
    final manifest = jsonDecode(c.files['caw-component.json']!) as Map<String, dynamic>;
    expect(manifest['format'], 'caw.component');
    expect((manifest['component'] as Map)['id'], c.componentId);
    expect((manifest['component'] as Map)['name'], 'My "Delay"');
    expect(manifest['sources'], ['src/effect.cpp']);
    final source = c.files['src/effect.cpp']!;
    expect(source, contains('d.id = "local.my-delay.c1";'));
    expect(source, contains("d.name = \"My 'Delay'\";"));  // safe inside the C++ string
    expect(source, contains('CAW_EXPORT_COMPONENT(MyDelay, kDescriptor)'));
  });

  test('native components on tracks and the master round-trip and reach the engine with their values', () {
    final p = ProjectDoc(id: 'p', name: 'P', bpm: 120, layers: [LayerDoc(id: 'l', name: 'L', color: 0)]);
    p.layers.first.components = [ComponentUseDoc('org.x.gain', {'left': 2})];
    p.masterComponents = [ComponentUseDoc('org.x.verb')];
    final again = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(again.layers.first.components.single.id, 'org.x.gain');
    expect(again.layers.first.components.single.params, {'left': 2.0});
    expect(again.masterComponents.single.id, 'org.x.verb');
    final engine = jsonDecode(p.toEngineJson()) as Map<String, dynamic>;
    expect(engine['master_components'], ['org.x.verb']);  // a bare id, as before
    expect((engine['layers'] as List).first['components'], [
      {'id': 'org.x.gain', 'params': {'left': 2.0}},
    ]);
    // Bad entries are dropped, not trusted: no id, a non-finite value.
    final bad = ComponentUseDoc.listFromJson([
      {'params': {}},
      {'id': 'org.y', 'params': {'a': 'loud', 'b': 1}},
      7,
    ]);
    expect(bad.single.id, 'org.y');
    expect(bad.single.params, {'b': 1.0});
  });

  test('components the engine has not loaded are left out, and their lanes renumbered', () {
    final p = ProjectDoc(id: 'p', name: 'P', bpm: 120, layers: [LayerDoc(id: 'l', name: 'L', color: 0)]);
    p.layers.first.components = [ComponentUseDoc('org.x.untrusted'), ComponentUseDoc('org.x.gain')];
    p.automation.addAll([
      ProjectAutomationLaneDoc(targetType: 'component', target: 'a', layerId: 'l', component: 0, points: [AutomationPointDoc(step: 0, value: 1)]),
      ProjectAutomationLaneDoc(targetType: 'component', target: 'b', layerId: 'l', component: 1, points: [AutomationPointDoc(step: 0, value: 1)]),
    ]);
    final engine = jsonDecode(p.toEngineJson(playableComponents: {'org.x.gain'})) as Map<String, dynamic>;
    expect((engine['layers'] as List).first['components'], ['org.x.gain']);
    final lanes = (engine['automation'] as List).cast<Map<String, dynamic>>();
    expect(lanes.single['target'], 'b');
    expect(lanes.single['component'], 0);
  });

  test('component bypass, state and automation lanes reach the engine and come back', () {
    final p = ProjectDoc(id: 'p', name: 'P', bpm: 120, layers: [LayerDoc(id: 'l', name: 'L', color: 0)]);
    p.layers.first.components = [ComponentUseDoc('org.x.gain', {}, true)];
    p.automation.add(ProjectAutomationLaneDoc(
        targetType: 'component', target: 'left', layerId: 'l', component: 0, points: [AutomationPointDoc(step: 0, value: 1)]));
    p.storeComponentStates((layer) => layer == 'l' ? {0: (state: 'CgAAAAAAAAA=', version: 7)} : const {});
    final engine = jsonDecode(p.toEngineJson()) as Map<String, dynamic>;
    expect((engine['layers'] as List).first['components'], [
      {'id': 'org.x.gain', 'bypass': true, 'state': 'CgAAAAAAAAA=', 'state_version': 7},
    ]);
    final lane = (engine['automation'] as List).single as Map<String, dynamic>;
    expect(lane['target_type'], 'component');
    expect(lane['layer'], 'l');
    expect(lane['component'], 0);
    final again = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(again.layers.first.components.single.bypass, isTrue);
    expect(again.layers.first.components.single.stateVersion, 7);
    expect(again.automation.single.component, 0);
  });

  test('a spacer under a track is saved with the project, never sent to the engine, and clamped', () {
    final p = sample();
    p.layers.first.spaceBelow = 40;
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.layers.first.spaceBelow, 40);
    expect(back.layers.last.spaceBelow, 0);
    expect(jsonEncode(p.toEngineJson()), isNot(contains('space_below')));
    expect(LayerDoc.fromJson({'id': 'x', 'space_below': 'big'}).spaceBelow, 0);
    expect(LayerDoc.fromJson({'id': 'x', 'space_below': 9999}).spaceBelow, LayerDoc.maxSpaceBelow);
    expect(LayerDoc.fromJson({'id': 'x', 'space_below': -5}).spaceBelow, 0);
  });

  test('project file round-trips', () {
    final p = sample();
    // Keep this round-trip focused on the current clip format. The legacy pointer
    // migration is covered separately below.
    p.layers[1].patternId = null;
    p.layers[1].clips.add(ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 32));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(back.toJson()), jsonEncode(p.toJson()));
    expect(back.modules.first.edited, isTrue);
    expect(back.layers.first.chain, ['m1', 'fx']);
  });

  test('folder hierarchy and automation survive app and engine serialization', () {
    final p = sample();
    p.layers.add(LayerDoc(id: 'group', name: 'Group', color: 3, isFolder: true, busEnabled: true));
    p.layers[0].parentId = 'group';
    p.layers[1].automation.add(AutomationLaneDoc(target: 'pan', points: [
      AutomationPointDoc(step: 0, value: -1), AutomationPointDoc(step: 16, value: 1),
    ]));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.layers[0].parentId, 'group');
    expect(back.layers.last.isFolder, isTrue);
    expect(back.layers[1].automation.single.points.last.value, 1);
    final engine = jsonDecode(back.toEngineJson()) as Map<String, dynamic>;
    final layers = engine['layers'] as List;
    expect(layers[0]['parent'], 'group');
    expect(layers.last['folder'], isTrue);
    expect((layers[1]['automation'] as List).single['target'], 'pan');
  });

  test('project parameter and global automation round-trip through app and engine JSON', () {
    final p = sample();
    p.automation.add(ProjectAutomationLaneDoc(targetType: 'param', moduleId: 'm1',
      target: 'shift', points: [AutomationPointDoc(step: 0, value: 2),
        AutomationPointDoc(step: 128, value: 8)]));
    p.automation.add(ProjectAutomationLaneDoc(targetType: 'global', target: 'swing',
      points: [AutomationPointDoc(step: 0, value: 0), AutomationPointDoc(step: 64, value: 0.5)]));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.automation, hasLength(2));
    expect(back.automation.first.moduleId, 'm1');
    final engine = jsonDecode(back.toEngineJson()) as Map<String, dynamic>;
    expect(engine['automation'], hasLength(2));
    expect(engine['loop_bars'], 8);
    expect(engine['automation'][0]['target_type'], 'param');
    expect(engine['automation'][1]['target_type'], 'global');
  });

  test('loading keeps every automation lane and point (F7, owner 2026-11-04)', () {
    final p = sample();
    for (var i = 0; i < 257; i++) {
      p.automation.add(ProjectAutomationLaneDoc(targetType: 'global', target: 'g$i',
        points: [AutomationPointDoc(step: 0, value: 0)]));
    }
    p.automation.first.points = [for (var i = 0; i < 129; i++) AutomationPointDoc(step: i * 0.5, value: i / 129)];
    p.layers.first.automation.add(AutomationLaneDoc(target: 'volume',
      points: [for (var i = 0; i < 129; i++) AutomationPointDoc(step: i * 0.5, value: 0.5)]));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.automation, hasLength(257));
    expect(back.automation.first.points, hasLength(129));
    expect(back.layers.first.automation.single.points, hasLength(129));
  });

  test('projects without project automation remain valid', () {
    final legacy = sample().toJson()..remove('automation');
    final back = ProjectDoc.fromJson(legacy);
    expect(back.automation, isEmpty);
    expect((jsonDecode(back.toEngineJson()) as Map<String, dynamic>)['automation'], isEmpty);
  });

  test('legacy pattern layers migrate once into clip instances', () {
    final old = sample().toJson()..['caw_app_project'] = 1;
    final oldLayer = (old['layers'] as List)[1] as Map<String, dynamic>;
    oldLayer['pattern'] = 'pat';
    oldLayer['clips'] = [];
    final migrated = ProjectDoc.fromJson(old);
    expect(migrated.layers[1].clips, hasLength(1));
    expect(migrated.layers[1].clips.single.patternId, 'pat');
    expect(migrated.layers[1].patternId, isNull);
    final saved = ProjectDoc.fromJson(migrated.toJson());
    expect(saved.layers[1].clips, hasLength(1));

    // The current file version can still contain an older pattern pointer from a partial upgrade.
    final currentVersionLegacy = sample().toJson()..['caw_app_project'] = ProjectDoc.fileVersion;
    final currentLayer = (currentVersionLegacy['layers'] as List)[1] as Map<String, dynamic>;
    currentLayer['pattern'] = 'pat';
    currentLayer['clips'] = [];
    final recovered = ProjectDoc.fromJson(currentVersionLegacy);
    expect(recovered.layers[1].clips.single.patternId, 'pat');
    recovered.layers[1].clips.clear();
    final emptyLayer = (jsonDecode(recovered.toEngineJson()) as Map<String, dynamic>)['layers'] as List;
    expect((emptyLayer[1] as Map).containsKey('pattern'), isFalse);

    final stalePointer = sample().toJson()..['caw_app_project'] = ProjectDoc.fileVersion;
    final staleLayer = (stalePointer['layers'] as List)[1] as Map<String, dynamic>;
    staleLayer['pattern'] = 'pat';
    staleLayer['clips'] = [
      {'id': 'c1', 'pattern': 'pat', 'start_steps': 0, 'length_steps': 64},
    ];
    final normalized = ProjectDoc.fromJson(stalePointer);
    expect(normalized.layers[1].patternId, isNull);
    expect(normalized.layers[1].clips, hasLength(1));
  });

  test('engine JSON carries the code last run and the layer chain', () {
    final j = jsonDecode(sample().toEngineJson()) as Map<String, dynamic>;
    expect(j['caw_project'], 1);
    expect((j['modules'] as List).first['source'], 't');
    final layer = (j['layers'] as List).first as Map<String, dynamic>;
    expect(layer['chain'], ['m1', 'fx']);
    expect(layer['length_steps'], 48);
    expect(layer.containsKey('pattern'), isFalse);
    expect((j['layers'] as List)[1].containsKey('pattern'), isFalse);
    expect(((j['layers'] as List)[1]['clips'] as List).single['pattern'], 'pat');
    expect(j['audition_only'], false);
    expect(j['globals'], {'swing': 0.2});
    expect((j['modules'] as List).first['name'], 'Lead');
    expect([j['key_root'], j['key_scale']], [9, 1]);  // A minor
    final none = jsonDecode((sample()..key = 'None').toEngineJson()) as Map<String, dynamic>;
    expect(none.containsKey('key_root'), isFalse);
    expect((sample()..key = 'C# minor').keyNumbers, (1, 1));
    expect((sample()..key = 'Bb major').keyNumbers, (10, 0));
    final a = jsonDecode(sample().toEngineJson(audition: ['m1'], auditionOnly: true)) as Map<String, dynamic>;
    expect(a['audition'], {'chain': ['m1']});
    final ap = jsonDecode(sample().toEngineJson(audition: ['m1'], auditionPattern: 'pat')) as Map<String, dynamic>;
    expect(ap['audition'], {'chain': ['m1'], 'pattern': 'pat'});
    expect(a['audition_only'], true);
    // A C++ instrument and its effects audition as a track plays them; one not loaded is left out.
    final synth = ComponentUseDoc('org.caw.synth.flagship', {'flt1_cutoff': 800});
    final width = ComponentUseDoc('org.caw.stereo.width', {'width': 1.5});
    final c = jsonDecode(sample().toEngineJson(
        auditionInstrument: synth, auditionComponents: [width], auditionPattern: 'pat', auditionOnly: true)) as Map<String, dynamic>;
    expect(c['audition'], {'chain': [], 'pattern': 'pat', 'instrument': synth.toJson(), 'components': [width.toJson()]});
    expect(c['audition_only'], true);
    final unloaded = jsonDecode(sample().toEngineJson(
        auditionInstrument: ComponentUseDoc('com.me.synth'), auditionOnly: true, playableComponents: {})) as Map<String, dynamic>;
    expect(unloaded['audition'], {'chain': []});
  });

  test('songs keep clips, automation and loop length past 64 bars (F7.2, owner 2026-11-04)', () {
    final raw = sample().toJson();
    raw['beats_per_bar'] = 3;
    raw['loop_bars'] = 1000;
    final layers = raw['layers'] as List;
    (layers[0] as Map)['clips'] = [
      {'id': 'late', 'pattern': 'pat', 'start_steps': 100000,
       'length_steps': 50000, 'source_offset_steps': 900},
    ];
    raw['automation'] = [
      {'target_type': 'global', 'target': 'swing', 'points': [{'step': 300000, 'value': 1}]},
    ];
    final imported = ProjectDoc.fromJson(raw);
    final clip = imported.layers[0].clips.single;
    expect([clip.startSteps, clip.lengthSteps, clip.sourceOffsetSteps], [100000, 50000, 900]);
    expect(imported.loopBars, 1000);
    expect(imported.arrangementEndSteps, 300000);
    expect(imported.timelineSteps, 300000);
    final engine = jsonDecode(imported.toEngineJson()) as Map<String, dynamic>;
    expect(engine['loop_bars'], 25000);  // reaches the last automation point (300000 / 12)
  });

  test('positions past the 32-bit step count are brought inside it on load', () {
    final raw = sample().toJson();
    raw['beats_per_bar'] = 3;
    raw['loop_bars'] = 1 << 40;
    (raw['layers'] as List)[0]['clips'] = [
      {'id': 'far', 'pattern': 'pat', 'start_steps': 1 << 40, 'length_steps': 64},
    ];
    final imported = ProjectDoc.fromJson(raw);
    expect(imported.maxLoopBars, 2147483647 ~/ 12);
    expect(imported.maxArrangementSteps, 2147483640);
    expect(imported.loopBars, imported.maxLoopBars);
    final clip = imported.layers[0].clips.single;
    expect(clip.startSteps, 2147483639);
    expect(clip.startSteps + clip.lengthSteps, imported.maxArrangementSteps);
    final engine = jsonDecode(imported.toEngineJson()) as Map<String, dynamic>;
    expect(engine['loop_bars'], imported.maxLoopBars);
  });

  test('a meter the engine cannot play is brought into its 1..16 beats on load', () {
    for (final beats in [0, -3, 1 << 30]) {
      final raw = sample().toJson()..['beats_per_bar'] = beats;
      final imported = ProjectDoc.fromJson(raw);
      expect(imported.beatsPerBar, beats < 1 ? 1 : 16);
      expect(jsonDecode(imported.toEngineJson())['loop_bars'], greaterThanOrEqualTo(1));
    }
  });

  test('automation editors reach every track point and the playhead uses the engine loop', () {
    final p = sample();  // 4/4, 4 bars
    p.layers.first.automation.add(AutomationLaneDoc(target: 'pan',
      points: [AutomationPointDoc(step: 0, value: 0), AutomationPointDoc(step: 500000, value: 1)]));
    expect(p.timelineSteps, 500000);
    expect(p.arrangementEndSteps, 64);  // track lanes don't lengthen the engine loop
    p.layers.first.clips.add(ClipDoc(id: 'c', patternId: 'pat', startSteps: 70, lengthSteps: 3));
    expect(p.arrangementEndSteps, 73);
    expect(p.engineLoopSteps, 80);  // whole bars, as toEngineJson sends them
    expect(p.songSeconds, closeTo(80 * 15.0 / p.bpm, 1e-9));  // the seconds readout and export follow the song end
    expect(jsonDecode(p.toEngineJson())['loop_bars'], 5);
  });

  test('imported library metadata rejects unsafe paths and bounds tags', () {
    final raw = sample().toJson();
    final modules = raw['modules'] as List;
    final module = modules.first as Map<String, dynamic>;
    module['folder_path'] = '../../outside';
    module['tags'] = ['  clean  ', List.filled(100, 'x').join(), ...List.generate(40, (i) => 'tag$i')];
    raw['library_folders'] = ['Synths/Kicks', '../outside', 'x' * 600];
    final imported = ProjectDoc.fromJson(raw);

    expect(imported.modules.first.folderPath, isEmpty);
    expect(imported.modules.first.tags, hasLength(16));
    expect(imported.modules.first.tags.first, 'clean');
    expect(imported.modules.first.tags.every((tag) => tag.length <= 48), isTrue);
    expect(imported.libraryFolders, containsAll(['Synths', 'Synths/Kicks']));
    expect(imported.libraryFolders.any((path) => path.contains('..')), isFalse);
  });

  test('C++ component sources and pinned dependencies round-trip with the project', () {
    final p = sample();
    p.cppComponents.add(CppComponentDoc(
      id: 'native-1',
      name: 'Stereo shaper',
      componentId: 'caw.examples.stereo-shaper',
      files: {
        'CMakeLists.txt': 'cmake_minimum_required(VERSION 3.22)',
        'caw.component': 'schema_version: 1',
        'src/stereo_shaper.cpp': 'class StereoShaper {};',
        'include/stereo_shaper.hpp': '#pragma once',
      },
      dependencies: {'fmt': '11.0.2'},
    ));

    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    final component = back.cppComponents.single;
    expect(component.id, 'native-1');
    expect(component.componentId, 'caw.examples.stereo-shaper');
    expect(component.files['src/stereo_shaper.cpp'], 'class StereoShaper {};');
    expect(component.dependencies, {'fmt': '11.0.2'});
    expect(jsonDecode(back.toEngineJson()).containsKey('cpp_components'), isFalse);
  });

  test('older project files without C++ components remain valid', () {
    final legacy = sample().toJson()..remove('cpp_components');
    final back = ProjectDoc.fromJson(legacy);
    expect(back.cppComponents, isEmpty);
  });

  test('C++ project paths cannot escape the project directory', () {
    expect(CppComponentDoc.isSafeRelativePath('src/component.cpp'), isTrue);
    expect(CppComponentDoc.isSafeRelativePath('include/caw/component.hpp'), isTrue);
    for (final path in ['', '/tmp/out.cpp', '../outside.cpp', 'src/../../outside.cpp',
      r'src\\outside.cpp', r'C:\\outside.cpp', 'src/./component.cpp']) {
      expect(CppComponentDoc.isSafeRelativePath(path), isFalse, reason: path);
    }
  });

  test('header values', () {
    const src = '---\ncaw: 1\nkind: effect  # comment\nname: Fold\n---\nin';
    expect(headerValue(src, 'kind'), 'effect');
    expect(headerValue(src, 'name'), 'Fold');
    expect(headerValue('t*2', 'name'), isNull);
  });

  test('loop seconds and length choices follow the meter', () {
    final p = ProjectDoc(id: 'x', name: 'x', bpm: 120, beatsPerBar: 3, loopBars: 2);
    expect(p.loopSteps, 24);
    expect(p.maxArrangementSteps, 2147483640);
    expect(p.timelineSteps, 768);  // automation editors show at least 64 bars
    expect(p.loopSeconds, closeTo(3.0, 1e-9));
    final c = lengthChoices(12);
    expect(c.first.$1, 0);
    expect(c.firstWhere((e) => e.$2 == '1 bar').$1, 12);
  });
}
