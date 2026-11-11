// Project modulation (#161): modulators and links in the project file and the engine JSON (unplayable parts and loops
// left out), links following their effect, the edits, and (with CAW_LIB) the engine taking and running them.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/routing.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectDoc _project() => ProjectDoc(id: 'p', name: 'Mod', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'kick', name: 'Kick', color: 0),
      LayerDoc(id: 'bass', name: 'Bass', color: 1, components: [ComponentUseDoc('org.caw.utility'), ComponentUseDoc('org.caw.filter')]),
      LayerDoc(id: 'verb', name: 'Verb', color: 3, isFolder: true),
    ]);

Map<String, dynamic> _engine(ProjectDoc p, {Set<String>? playable}) =>
    jsonDecode(p.toEngineJson(playableComponents: playable)) as Map<String, dynamic>;

void main() {
  test('modulators and links round-trip through the project file', () {
    final p = _project();
    p.modulators.add(ModulatorDoc(id: 'mod1', name: 'LFO', componentId: ModulatorKinds.lfo, params: {'rate': 2},
        layerId: 'bass', inputId: 'bass'));
    p.modulators.add(ModulatorDoc(id: 'mod2', name: 'Follower', componentId: ModulatorKinds.follower, inputId: 'kick',
        hears: 'audio', post: true));
    p.modLinks.add(ModLinkDoc(id: 1, source: 'mod1', target: const ModTarget.component('bass', 1, 'cutoff'),
        amount: 0.4, bipolar: true, curve: -0.5));
    p.modLinks.add(ModLinkDoc(id: 2, source: 'mod2', target: const ModTarget.volume('bass'), amount: -1));
    final back = ProjectDoc.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.modulators.length, 2);
    expect(back.modulators[0].params['rate'], 2);
    expect(back.modulators[1].hears, 'audio');
    expect(back.modulators[1].post, isTrue);
    expect(back.modLinks[0].target, const ModTarget.component('bass', 1, 'cutoff'));
    expect(back.modLinks[0].bipolar, isTrue);
    expect(back.modLinks[0].curve, -0.5);
    expect(back.modLinks[1].target, const ModTarget.volume('bass'));
  });

  test('the engine gets what can play: indices as its chain, no unloaded parts, no loops', () {
    final p = _project();
    p.modulators.add(ModulatorDoc(id: 'lfo', name: 'LFO', componentId: ModulatorKinds.lfo));
    p.modulators.add(ModulatorDoc(id: 'fol', name: 'Fol', componentId: ModulatorKinds.follower, inputId: 'kick', hears: 'audio'));
    p.modulators.add(ModulatorDoc(id: 'user', name: 'Mine', componentId: 'com.me.mod'));
    p.modLinks.addAll([
      ModLinkDoc(id: 1, source: 'lfo', target: const ModTarget.component('bass', 1, 'cutoff')),
      ModLinkDoc(id: 2, source: 'lfo', target: const ModTarget.component('bass', 0, 'gain')),
      ModLinkDoc(id: 3, source: 'fol', target: const ModTarget.volume('bass')),
      ModLinkDoc(id: 4, source: 'fol', target: const ModTarget.pan('kick')),  // hears kick and moves it: a loop
      ModLinkDoc(id: 5, source: 'user', target: const ModTarget.volume('bass')),
      ModLinkDoc(id: 6, source: 'lfo', target: const ModTarget.send('kick', 0)),  // no such send
    ]);
    // The utility isn't playing: the filter is the engine's component 0, and the link to the utility goes.
    final j = _engine(p, playable: {'org.caw.filter', ModulatorKinds.lfo, ModulatorKinds.follower});
    expect([for (final m in j['modulators'] as List) m['id']], ['lfo', 'fol']);
    final links = (j['modulation'] as List).cast<Map<String, dynamic>>();
    expect([for (final l in links) l['id']], [1, 3]);
    expect(links[0]['target'], {'type': 'component', 'layer': 'bass', 'index': 0, 'param': 'cutoff'});
    expect((j['modulators'] as List)[1]['input'], 'kick');
    expect((j['modulators'] as List)[1]['hears'], 'audio');
    expect(p.modulationLoops('fol', const ModTarget.pan('kick')), isTrue);
    expect(p.modulationLoops('fol', const ModTarget.pan('bass')), isFalse);
    expect(p.modulationLoops('lfo', const ModTarget.pan('kick')), isFalse);
    // A send that plays: its index as the engine's sends.
    p.layers[0].sends.add(SendDoc('verb'));
    final again = (_engine(p)['modulation'] as List).cast<Map<String, dynamic>>();
    expect(again.firstWhere((l) => l['id'] == 6)['target'], {'type': 'send', 'layer': 'kick', 'index': 0});
  });

  test('modulators moving each other in a loop are refused, and a project with none sends no fields', () {
    final p = _project();
    expect(_engine(p).containsKey('modulators'), isFalse);
    p.modulators.addAll([
      ModulatorDoc(id: 'a', name: 'A', componentId: ModulatorKinds.lfo),
      ModulatorDoc(id: 'b', name: 'B', componentId: ModulatorKinds.lfo),
    ]);
    p.modLinks.add(ModLinkDoc(id: 1, source: 'a', target: const ModTarget.modulator('b', 'rate')));
    expect(p.modulationLoops('b', const ModTarget.modulator('a', 'rate')), isTrue);
    expect(p.modulationLoops('a', const ModTarget.modulator('a', 'rate')), isTrue);
    expect(p.modulationLoops('b', const ModTarget.component('bass', 0, 'gain')), isFalse);
  });

  test('edits: add a modulator on a track, link its output by tap, follow the effect, remove it', () {
    final s = AppState(settings: Settings());
    s.project = _project();
    final bass = s.project.layers[1];
    final m = s.addModulator(ModulatorKinds.lfo, layerId: 'bass')!;
    expect(m.name, 'LFO');
    expect(m.inputId, 'bass');
    expect(s.addModulator(ModulatorKinds.lfo, layerId: 'bass')!.name, 'LFO 2');
    final link = s.toggleModLink(ModSourceRef(m.id, 0), const ModTarget.component('bass', 1, 'cutoff'))!;
    expect(link.bipolar, isTrue);  // an LFO swings both ways
    expect(s.project.linksTo(const ModTarget.component('bass', 1, 'cutoff')).single.id, link.id);
    // The filter moves to the front: the link goes with it.
    s.moveNativeEffect(bass, 1, 0);
    expect(link.target, const ModTarget.component('bass', 0, 'cutoff'));
    s.setModLinkAmountLive(link.id, 0.6);
    s.commitModulation();
    expect(s.modLink(link.id)!.amount, 0.6);
    // A second tap removes it.
    expect(s.toggleModLink(ModSourceRef(m.id, 0), const ModTarget.component('bass', 0, 'cutoff')), isNull);
    expect(s.project.modLinks, isEmpty);
    // Removing the modulator takes its links, and links into its knobs.
    final other = s.addModulator(ModulatorKinds.macros)!;
    expect(other.layerId, isNull);
    s.addModLink(ModSourceRef(other.id, 2), ModTarget.modulator(m.id, 'rate'));
    s.addModLink(ModSourceRef(m.id, 0), const ModTarget.volume('kick'));
    s.removeModulator(m.id);
    expect(s.project.modLinks, isEmpty);
    // The effect itself removed: links to it go too.
    s.addModLink(ModSourceRef(other.id, 0), const ModTarget.component('bass', 0, 'cutoff'));
    s.removeNativeEffect(bass, 0);
    expect(s.project.modLinks, isEmpty);
    expect(s.modTargetLabel(const ModTarget.volume('kick')), 'Kick · Volume');
    expect(s.modSourceLabel(ModSourceRef(other.id, 2)), 'Macros · M3');
  });

  test('the engine takes the project\'s modulators and links and runs them', () async {
    final p = _project();
    p.layers[0].instrument = ComponentUseDoc('org.caw.synth.flagship');
    p.layers[1].instrument = ComponentUseDoc('org.caw.synth.flagship');
    p.modulators.add(ModulatorDoc(id: 'lfo', name: 'LFO', componentId: ModulatorKinds.lfo, params: {'rate': 5}));
    p.modulators.add(ModulatorDoc(id: 'mac', name: 'Macros', componentId: ModulatorKinds.macros, params: {'macro1': 0.7}));
    p.modulators.add(ModulatorDoc(id: 'fol', name: 'Fol', componentId: ModulatorKinds.follower, inputId: 'kick', hears: 'audio'));
    p.modLinks.addAll([
      ModLinkDoc(id: 1, source: 'lfo', target: const ModTarget.component('bass', 1, 'cutoff'), bipolar: true),
      ModLinkDoc(id: 2, source: 'mac', target: const ModTarget.volume('bass'), amount: -0.2),
      ModLinkDoc(id: 3, source: 'fol', target: const ModTarget.instrument('bass', 'volume')),
      ModLinkDoc(id: 4, source: 'mac', output: 0, target: const ModTarget.modulator('lfo', 'rate')),
    ]);
    final e = Engine.create();
    await e.setProject(p.toEngineJson());
    expect(e.lastProjectWarnings.where((w) => w.contains('modulat')), isEmpty);
    expect(e.setModulatorParam('mac', 'macro1', 0.3), isTrue);
    expect(e.setModulatorParam('nope', 'macro1', 0.3), isFalse);
    expect(e.setModulationAmount(2, -0.5), isTrue);
    expect(e.setModulationAmount(99, -0.5), isFalse);
    e.dispose();
  }, skip: (Platform.environment['CAW_LIB'] ?? '').isEmpty ? 'set CAW_LIB to the built engine library' : null);
}
