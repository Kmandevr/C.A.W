// The merged effect devices in the app (FX consolidation, 1.0.8): old projects and presets open in the merged form, the file version, and the variant picker's reset.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/component_info.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/model/midi_mapping.dart';
import 'package:caw/model/mixer_fx.dart';
import 'package:caw/model/modulation.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/racks.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/user_presets.dart';
import 'package:caw/model/variant_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';

/// One old effect per family (and every family's old ids among them), as a 1.0.7 project held them.
const _bassFx = [
  'org.caw.dynamics', 'org.caw.saturator', 'org.caw.bitcrush', 'org.caw.geq', 'org.caw.ladder', 'org.caw.stereo.width',
  'org.caw.flanger', 'org.caw.autopan', 'org.caw.delay.pingpong', 'org.caw.shimmer', 'org.caw.pitchshift',
];

/// A 1.0.7 (v5) file: the demo's tracks with old effects on the bass, the lead's per-note FX and the master, and a
/// lane, a modulation link and a MIDI mapping on them.
Map<String, dynamic> _oldProjectJson() {
  final p = AppState(settings: Settings()).demoProject();
  for (final l in p.layers) {
    l.components = [];  // the demo's own effects are merged devices now
  }
  p.layers.firstWhere((l) => l.name == 'Lead').components = [ComponentUseDoc('org.caw.delay.pingpong', {'mix': 0.3})];
  final bass = p.layers.firstWhere((l) => l.name == 'Bass');
  bass.components = [for (final id in _bassFx) ComponentUseDoc(id, id == 'org.caw.saturator' ? {'drive': 9, 'mode': 2} : {})];
  p.layers.firstWhere((l) => l.name == 'Lead').noteComponents = [ComponentUseDoc('org.caw.ladder', {'cutoff': 900})];
  p.masterComponents = [ComponentUseDoc('org.caw.tilt', {'tilt': 3})];
  p.automation.add(ProjectAutomationLaneDoc(targetType: 'component', target: 'drive', layerId: bass.id, component: 1,
      points: [AutomationPointDoc(step: 0, value: 6), AutomationPointDoc(step: 16, value: 12)]));
  p.modulators.add(ModulatorDoc(id: 'm1', name: 'LFO 1', componentId: 'org.caw.mod.lfo'));
  p.modLinks.add(ModLinkDoc(id: 1, source: 'm1', target: ModTarget.component(bass.id, 4, 'cutoff'), amount: 0.3));
  p.midiMappings.add(MidiCcMapping(channel: 0, cc: 21, layerId: bass.id, slot: 2, paramId: 'bits'));
  p.midiMappings.add(MidiCcMapping(channel: 0, cc: 22, layerId: masterLayerId, slot: 0, paramId: 'tilt'));
  final j = p.toJson();
  expect(j['caw_app_project'], ProjectDoc.baseFileVersion, reason: 'an old project: nothing of v7');
  return jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
}

/// An old FX rack: the saturator in slot 1 and the delay in slot 2, an LFO route to the delay's feedback (its index
/// in the old flattened list), no `rack_layout`.
ComponentUseDoc _oldRack(Map<String, NativeComponentInfo> catalog) {
  final rack = catalog[fxRackId]!;
  final own = rack.parameters.takeWhile((p) => p.id != 'mod1_src').length;
  List<String> old(String id, int v) => [for (final p in catalog[id]!.variants[v].parameters) if (p.id != 'variant') p.id];
  final feedback = own + old('org.caw.drive', 1).length + old('org.caw.delay', 0).indexOf('feedback') + 1;
  return ComponentUseDoc(fxRackId, {
    's1_fx': rackChildHash('org.caw.saturator').toDouble(), 's1.drive': 12, 's1_on': 1,
    's2_fx': rackChildHash('org.caw.delay.pro').toDouble(), 's2.feedback': 0.4, 's2_on': 1,
    'mod1_src': 1, 'mod1_dst': feedback.toDouble(), 'mod1_amt': 0.5,
  });
}

void main() {
  final lib = Platform.environment['CAW_LIB'];
  final noLib = lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null;

  group('the table', () {
    test('every old id maps to a merged device and its variant, and each variant to one old page', () {
      // 1.1.0: org.caw.gate is a device's own id again (29 retired ids, as the engine's legacy table).
      expect(MergedDevices.variants.where((v) => v.retired && v.oldId != v.id), hasLength(29));
      // The Duck is a new variant (the Ducker's first since 1.1.0): a page id of its own, never an old id read from
      // a file.
      expect(MergedDevices.pageId('org.caw.duck', 0), MergedDevices.duckPageId);
      expect(MergedDevices.isRetired(MergedDevices.duckPageId), isFalse);
      expect(MergedDevices.of(MergedDevices.duckPageId), isNull);
      expect(MergedDevices.variantOf('org.caw.compressor', {'variant': 4}), 3, reason: 'Talon has four variants');
      // The split: Gate and Shape open their old pages under their new devices; the 1.0.9 indices move.
      expect(MergedDevices.pageId('org.caw.gate', 0), 'org.caw.gate');
      expect(MergedDevices.pageId('org.caw.tremolo', 2), 'org.caw.ducker');
      expect(MergedDevices.of('org.caw.ducker')!.id, 'org.caw.tremolo');
      expect(MergedDevices.isRetired('org.caw.gate'), isFalse, reason: 'a reused id is a device');
      expect(MergedDevices.talonMoves[4], (id: 'org.caw.duck', variant: 0));
      expect(MergedDevices.isLegacyTalon('org.caw.compressor', {'variant': 2}), isTrue);
      expect(MergedDevices.isLegacyTalon('org.caw.compressor', {'variant': 2, talonLayoutParam: 1}), isFalse);
      expect(MergedDevices.of('org.caw.saturator')!.id, 'org.caw.drive');
      expect(MergedDevices.of('org.caw.saturator')!.variant, 1);
      expect(MergedDevices.isRetired('org.caw.saturator'), isTrue);
      expect(MergedDevices.isRetired('org.caw.compressor'), isFalse, reason: 'a reused id is a device');
      expect(MergedDevices.pageId('org.caw.drive', 1), 'org.caw.saturator');
      expect(MergedDevices.pageId('org.caw.compressor', 0), 'org.caw.compressor');
      expect(MergedDevices.pageIdOf('org.caw.delay', {'variant': 1}), 'org.caw.delay.pingpong');
      expect(MergedDevices.pageIdOf('org.caw.comb', {'variant': 1}), 'org.caw.comb');
    });

    test('the Duck\'s ten display floats decode: input and key level, reduction, its settings', () {
      final f = decodeDisplay(MergedDevices.duckPageId, [-6, -9, -14, -12, 4.5, 7, -20, 0.5, 1, 1], 10);
      expect((f.inputDb, f.outputDb, f.gainReductionDb), (-6, -9, -4.5));
      expect(f.values, {'detector_db': -14, 'key_db': -12, 'gr': 4.5, 'gr_max': 7, 'threshold': -20, 'amount': 0.5,
          'detection': 1, 'sidechain': 1});
    });

    test('the table matches the fixture the engine dumped: each merged device\'s variants in order', () {
      final infos = {for (final c in builtinInfos()) c.id: c};
      for (final id in MergedDevices.ids) {
        final count = MergedDevices.variants.where((v) => v.id == id).length;
        expect(infos[id]!.variants, hasLength(count), reason: id);
        for (var v = 0; v < count; v++) {
          expect(infos[id]!.variants[v].variantIndex, v);
          expect(infos[id]!.variants[v].id, id);
        }
      }
    });
  });

  group('the file version', () {
    ProjectDoc project(List<ComponentUseDoc> fx) => ProjectDoc(id: 'p', name: 'p', bpm: 120, modules: [],
        layers: [LayerDoc(id: 'a', name: 'A', color: 0, components: fx)]);

    test('nothing merged: v5 as before, byte for byte; a reused id without a variant is still v5', () {
      final p = project([ComponentUseDoc('org.caw.compressor', {'ratio': 4}), ComponentUseDoc('org.caw.saturator')]);
      final first = jsonEncode(p.toJson());
      expect(jsonDecode(first)['caw_app_project'], 5);
      expect(jsonEncode(ProjectDoc.fromJson(jsonDecode(first) as Map<String, dynamic>).toJson()), first);
    });

    test('a new id, a variant or a rack writes v7; taking them away writes v5 again', () {
      final p = project([ComponentUseDoc('org.caw.drive')]);
      expect(p.toJson()['caw_app_project'], 7);
      p.layers.first.components = [ComponentUseDoc('org.caw.compressor', {'variant': 0})];
      expect(p.toJson()['caw_app_project'], 7, reason: 'an older engine refuses the parameter');
      p.layers.first.components = [ComponentUseDoc(fxRackId)];
      expect(p.toJson()['caw_app_project'], 7);
      expect(((p.toJson()['layers'] as List).first as Map)['components'], [
        {'id': fxRackId, 'params': {rackLayoutParam: rackLayoutCurrent}},
      ], reason: 'a rack always saves its layout, even with no other value');
      p.layers.first.components = [ComponentUseDoc('org.caw.compressor')];
      expect(p.toJson()['caw_app_project'], 5);
      // v6's routing and v7's merged devices: v7.
      p.layers.first.output = masterLayerId;
      p.layers.first.components = [ComponentUseDoc('org.caw.reverb')];
      expect(p.toJson()['caw_app_project'], 7);
    });

    test('an old rack read without the engine is written back as it was, not marked current', () {
      final old = {'id': fxRackId, 'params': {'s1_fx': rackChildHash('org.caw.saturator').toDouble(), 'mod1_dst': 40.0}};
      final p = ProjectDoc.fromJson({...project([]).toJson(), 'layers': [
        {...project([]).layers.first.toJson(rateOf: (_) => 0), 'components': [old]},
      ]});
      final use = p.layers.first.components.single;
      expect(use.legacyRack, isTrue);
      expect(use.needsResolving, isTrue);
      expect(use.toJson(), old);
      expect(p.toJson()['caw_app_project'], 5);
    });
  });

  group('user presets saved before the merge', () {
    tearDown(() => MergedDevices.resolver = null);

    test('a device preset of an old id resolves under the merged id and variant, with or without the engine', () {
      for (final resolver in [null, if (noLib == null) Engine.resolveComponent]) {
        MergedDevices.resolver = resolver;
        final d = PresetDevice.fromJson({'component': 'org.caw.saturator', 'params': {'drive': 5, 'mode': 3}})!;
        expect(d.componentId, 'org.caw.drive', reason: '$resolver');
        expect(d.params, {'drive': 5, 'mode': 3, 'variant': 1});
        // A Compressor preset from before 1.1.0 stays (its variant 0; the marker lives only on file); one of its
        // moved variants goes to its new device; a 1.1.0 one (marked) keeps Talon's numbering.
        final reused = PresetDevice.fromJson({'component': 'org.caw.compressor', 'params': {'ratio': 3}})!;
        expect(reused.componentId, 'org.caw.compressor');
        expect(reused.params, {'ratio': 3});
        expect(reused.toJson()['params'], {'ratio': 3, talonLayoutParam: talonLayoutCurrent});
        final up = PresetDevice.fromJson({'component': 'org.caw.compressor', 'params': {'variant': 2, talonLayoutParam: 1}})!;
        expect(up.componentId, 'org.caw.compressor');
        expect(up.params, {'variant': 2});
        final duck = PresetDevice.fromJson({'component': 'org.caw.compressor', 'params': {'variant': 4, 'amount': 0.6}})!;
        expect(duck.componentId, 'org.caw.duck', reason: '$resolver');
        expect(duck.params, {'variant': 0, 'amount': 0.6});
      }
    });

    test('an old rack preset is migrated by the engine: its children merged, its route on the same knob', () async {
      final e = Engine.create();
      final catalog = {for (final c in await e.nativeComponents()) c.id: c};
      e.dispose();
      MergedDevices.resolver = Engine.resolveComponent;
      final old = _oldRack(catalog);
      final d = PresetDevice.fromJson({'component': fxRackId, 'params': old.params})!;
      expect(d.params['s1_fx'], rackChildHash('org.caw.drive'));
      expect(d.params['s1.variant'], 1);
      expect(d.params[rackLayoutParam], rackLayoutCurrent);
      final info = rackInfo(catalog[fxRackId]!, d.params, catalog);
      expect(info.parameters[d.params['mod1_dst']!.round() - 1].id, 's2.feedback');
    }, skip: noLib);
  });

  group('an old project opens in the merged form', () {
    test('every family: ids and variants, lanes, links and MIDI mappings follow, and it saves only merged ids', () {
      final p = ProjectDoc.fromJson(_oldProjectJson());
      // Without the engine nothing is resolved and the file is written as it was read.
      expect(p.layers.firstWhere((l) => l.name == 'Bass').components.every((c) => c.needsResolving), isTrue);
      expect(p.resolveComponents(Engine.resolveComponent), isTrue);
      final bass = p.layers.firstWhere((l) => l.name == 'Bass');
      expect([for (final c in bass.components) '${c.id}#${c.params['variant']?.round()}'], [
        for (final id in _bassFx) '${MergedDevices.of(id)!.id}#${MergedDevices.of(id)!.variant}',
      ]);
      expect(bass.components[1].params, {'drive': 9, 'mode': 2, 'variant': 1}, reason: 'every value kept');
      final lead = p.layers.firstWhere((l) => l.name == 'Lead');
      expect((lead.noteComponents.single.id, lead.noteComponents.single.params['variant']), ('org.caw.filter', 1));
      expect((p.masterComponents.single.id, p.masterComponents.single.params['variant']), ('org.caw.eq', 3));
      // The lane, link and mappings stay on the same knobs (no parameter was renamed: the old ids are kept).
      final lane = p.automation.single;
      expect((lane.layerId, lane.component, lane.target), (bass.id, 1, 'drive'));
      expect((p.modLinks.single.target.index, p.modLinks.single.target.param), (4, 'cutoff'));
      expect([for (final m in p.midiMappings) (m.slot, m.paramId)], [(2, 'bits'), (0, 'tilt')]);
      // Once resolved, nothing more to do; saved, it names no retired id and is a v7 file.
      expect(p.resolveComponents(Engine.resolveComponent), isFalse);
      final saved = jsonEncode(p.toJson());
      for (final v in MergedDevices.variants.where((v) => v.oldId != v.id)) {
        expect(saved, isNot(contains('"${v.oldId}"')), reason: v.oldId);
      }
      expect(jsonDecode(saved)['caw_app_project'], ProjectDoc.mergedFileVersion);
      expect(jsonEncode(ProjectDoc.fromJson(jsonDecode(saved) as Map<String, dynamic>).toJson()), saved);
    }, skip: noLib);

    test('the engine plays the resolved project, and the same as the old one', () async {
      final old = ProjectDoc.fromJson(_oldProjectJson());
      final resolved = ProjectDoc.fromJson(_oldProjectJson())..resolveComponents(Engine.resolveComponent);
      Future<List<double>> peaks(ProjectDoc p) async {
        final e = Engine.create();
        await e.setProject(p.toEngineJson());
        expect(e.lastProjectWarnings, isEmpty);
        e.play();
        e.pullForTest(48000);
        final out = [for (var i = 0; i < p.layers.length; i++) e.layerMeter(i).peak];
        e.dispose();
        return out;
      }
      final a = await peaks(old), b = await peaks(resolved);
      final bass = resolved.layers.indexWhere((l) => l.name == 'Bass');
      expect(b[bass], greaterThan(0.001), reason: 'the bass plays through its merged effects');
      for (var i = 0; i < a.length; i++) {
        expect(b[i], closeTo(a[i], 1e-6), reason: resolved.layers[i].name);
      }
    }, skip: noLib);

    test('a rack keeps its routes on the same knobs and is saved with rack_layout', () async {
      final e = Engine.create();
      final catalog = {for (final c in await e.nativeComponents()) c.id: c};
      e.dispose();
      final p = ProjectDoc(id: 'p', name: 'p', bpm: 120, modules: [],
          layers: [LayerDoc(id: 'a', name: 'A', color: 0, components: [_oldRack(catalog)])]);
      // As a 1.0.7 file held it: no rack_layout (this build always writes one for a rack it made).
      final json = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      ((((json['layers'] as List).first as Map)['components'] as List).single['params'] as Map).remove(rackLayoutParam);
      final read = ProjectDoc.fromJson(json);
      expect(read.layers.first.components.single.legacyRack, isTrue);
      expect(read.resolveComponents(Engine.resolveComponent), isTrue);
      final rack = read.layers.first.components.single;
      expect(rack.legacyRack, isFalse);
      expect((rack.params['s1_fx'], rack.params['s1.variant']), (rackChildHash('org.caw.drive').toDouble(), 1));
      expect(rack.params['s2_fx'], rackChildHash('org.caw.delay').toDouble());
      expect(rack.params['s1.drive'], 12);
      final info = rackInfo(catalog[fxRackId]!, rack.params, catalog);
      expect(info.parameters[rack.params['mod1_dst']!.round() - 1].id, 's2.feedback');
      final saved = (((read.toJson()['layers'] as List).first as Map)['components'] as List).single as Map;
      expect((saved['params'] as Map)[rackLayoutParam], rackLayoutCurrent);
      expect(read.toJson()['caw_app_project'], 7);
    }, skip: noLib);

    test('a renamed or dropped parameter moves or drops its lane, link and mapping', () {
      final p = ProjectDoc.fromJson(_oldProjectJson());
      final bass = p.layers.firstWhere((l) => l.name == 'Bass');
      // A stand-in for a family whose migration renames (none does today): drive → gain, cutoff dropped.
      Map<String, dynamic>? resolve(Map<String, dynamic> entry) {
        final m = MergedDevices.of(entry['id'] as String)!;
        return {'ok': true, 'migrated': true, 'id': m.id, 'params': {...(entry['params'] as Map), 'variant': m.variant},
          'renamed': {'drive': 'gain'}, 'dropped': ['cutoff', 'bits'], 'keeps_state': true};
      }
      p.resolveComponents(resolve);
      expect(p.automation.single.target, 'gain');
      expect(p.modLinks, isEmpty);
      expect([for (final m in p.midiMappings) m.paramId], ['tilt']);
      expect(bass.components.every((c) => !MergedDevices.isRetired(c.id)), isTrue);
    });
  });

  group('the variant picker', () {
    AppState drive(Map<String, double> params) {
      final s = stateWith('org.caw.distortion');
      s.project.layers.first.components.single.params.addAll(params);
      return s;
    }

    test('a variant change resets the knobs the new variant doesn\'t share and is one undo step', () {
      final s = drive({'drive': 9, 'output': 0.8, 'mix': 0.5, 'shape': 2});
      final t = targetOf(s, 'org.caw.distortion');
      final layer = s.project.layers.first;
      s.project.automation.addAll([
        ProjectAutomationLaneDoc(targetType: 'component', target: 'drive', layerId: layer.id, component: 0),
        ProjectAutomationLaneDoc(targetType: 'component', target: 'mix', layerId: layer.id, component: 0),
      ]);
      s.starting = false;  // as after a project opens: edits are undo steps
      s.history.reset(jsonEncode(s.project.toJson()));
      expect(t.info!.variantIndex, 0);
      expect(s.setDeviceVariant(t, 1), isTrue);
      final use = layer.components.single;
      // Drive's `drive` (1..20 vs dB) and `output` (gain vs dB) differ in units; `shape` is Distortion's own; `mix`
      // is the same knob and stays.
      expect(use.params, {'mix': 0.5, 'variant': 1});
      expect(t.info!.variantIndex, 1);
      expect(t.value('drive'), t.param('drive')!.defaultValue);
      expect([for (final l in s.project.automation) l.target], ['mix'], reason: 'the lane on a reset knob goes');
      expect(s.setDeviceVariant(t, 1), isFalse, reason: 'already on it');
      expect(s.undo(), isTrue);
      expect(s.project.layers.first.components.single.params, {'variant': 0, 'drive': 9, 'output': 0.8, 'mix': 0.5, 'shape': 2});
      expect(s.project.automation, hasLength(2));
    });

    test('a delay\'s sync differs between Digital and Ping-pong, so it resets', () {
      final s = stateWith('org.caw.delay.pro');
      final t = targetOf(s, 'org.caw.delay.pro');
      s.project.layers.first.components.single.params.addAll({'sync': 9, 'mix': 0.4, 'feedback': 0.6});
      expect(s.setDeviceVariant(t, 1), isTrue);
      expect(s.project.layers.first.components.single.params, {'mix': 0.4, 'variant': 1});
    });

    test('variant is never a knob: not automatable, modulatable or learnable, and a knob move can\'t set it', () {
      final s = drive({});
      final t = targetOf(s, 'org.caw.distortion');
      final p = t.param('variant')!;
      expect((p.automatable, p.modulatable, p.midiMappable), (false, false, false));
      expect(t.info!.knobs.map((k) => k.id), isNot(contains('variant')));
      t.set('variant', 2);
      expect(s.project.layers.first.components.single.params['variant'], 0, reason: 'unchanged');
    });

    test('a merged device opens its variant\'s old page and display; the bar shows only with variants', () {
      final s = drive({});
      final t = targetOf(s, 'org.caw.distortion');
      expect(t.componentId, 'org.caw.drive');
      expect(MergedDevices.pageId(t.componentId!, t.info!.variantIndex), 'org.caw.distortion');
      s.setDeviceVariant(t, 2);
      expect(MergedDevices.pageId(t.componentId!, t.info!.variantIndex), 'org.caw.clipper');
      expect(builtinInfo('org.caw.bits').variants, isEmpty, reason: 'a variant descriptor holds no variants');
    });

    test('sameKnob compares id, range, step, unit and name', () {
      const a = ComponentParameterInfo(id: 'mix', name: 'Mix', defaultValue: 1, min: 0, max: 1);
      expect(sameKnob(a, a), isTrue);
      expect(sameKnob(a, const ComponentParameterInfo(id: 'mix', name: 'Mix', defaultValue: 0.5, min: 0, max: 1)), isTrue);
      expect(sameKnob(a, const ComponentParameterInfo(id: 'mix', name: 'Mix', unit: '%', defaultValue: 1, min: 0, max: 1)),
          isFalse);
      expect(sameKnob(a, const ComponentParameterInfo(id: 'mix', name: 'Mix', defaultValue: 1, min: 0, max: 2)), isFalse);
    });
  });

  test('a rack child\'s variant change keeps the rack\'s routes off the reset knobs', () {
    final s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'p', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'A', color: 0)]);
    s.componentCatalog.set(builtinInfos());
    final rack = s.addNativeEffect(s.project.layers.first, fxRackId)!;
    final t = DeviceTarget(s, 'a', 0);
    setRackValues(t, rackValuesWithSlot(t, rackSlots(fxRackId).first, 'org.caw.drive'));
    final child = RackChildTarget(t, rackSlots(fxRackId).first, 'org.caw.drive');
    child.set('mix', 0.3);
    child.set('drive', 7);
    final mixAt = t.info!.parameters.indexWhere((p) => p.id == 's1.mix') + 1;
    final driveAt = t.info!.parameters.indexWhere((p) => p.id == 's1.drive') + 1;
    setRackValues(t, {...rack.params, 'mod1_src': 1, 'mod1_dst': mixAt.toDouble(), 'mod1_amt': 0.5,
      'mod2_src': 1, 'mod2_dst': driveAt.toDouble(), 'mod2_amt': 0.5});
    expect(s.setDeviceVariant(child, 1), isTrue);
    expect(rack.params['s1.variant'], 1);
    expect(rack.params['s1.mix'], 0.3);
    expect(rack.params.containsKey('s1.drive'), isFalse);
    expect(t.info!.parameters[rack.params['mod1_dst']!.round() - 1].id, 's1.mix');
    expect(rack.params['mod2_dst'], 0, reason: 'the route to the reset drive is cleared');
    expect(child.info!.variantIndex, 1);
    expect(jsonEncode(rack.toJson()), contains('"$rackLayoutParam":4.0'));
  });
}
