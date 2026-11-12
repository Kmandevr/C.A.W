// The default project (owner, 2026-11-12): the bundled "mid tempo" asset loads as the starter and the Mid tempo
// template, with fresh ids each time and every reference kept, and the engine plays it (with CAW_LIB).
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/default_project.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/templates.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDefaultProject);

  test('the starter is the bundled mid tempo project: 4 tracks with their instruments and effects', () {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    final p = s.starterProject();
    expect(p.name, 'mid tempo');
    expect([p.bpm, p.beatsPerBar, p.key], [90.0, 4, 'A minor']);
    expect(p.modules.map((m) => m.name), ['Pattern 1', 'Pattern 2', 'Pattern 3', 'Pattern 4']);
    expect(p.cppComponents, isEmpty, reason: 'the unused C++ effect was left out');
    final tracks = {for (final l in p.layers) l.name: l};
    expect(tracks.keys, ['Track 3', 'Bass', 'Drums', 'Layer 4']);
    String? inst(String n) => tracks[n]!.instrument?.id;
    List<String> fx(String n) => [for (final c in tracks[n]!.components) c.id];
    expect(inst('Track 3'), 'org.caw.synth.flagship');
    expect(fx('Track 3'), ['org.caw.ducker', 'org.caw.distortion']);
    expect(inst('Bass'), 'org.caw.synth.flagship');
    expect(tracks['Bass']!.instrument?.preset, 'Mono bass');
    expect(fx('Bass'), ['org.caw.distortion', 'org.caw.saturator', 'org.caw.ducker']);
    expect(inst('Drums'), 'org.caw.drums');
    expect(tracks['Drums']!.instrument?.preset, 'Kit: 808');
    expect(fx('Drums'), ['org.caw.distortion', 'org.caw.eq', 'org.caw.compressor']);
    expect(inst('Layer 4'), 'org.caw.synth.flagship');
    expect(fx('Layer 4'), ['org.caw.delay.pingpong']);
    expect(tracks['Bass']!.clips, hasLength(2));
  });

  test('two copies share no ids, and every reference names something in its own copy', () {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    final a = s.starterProject(), b = s.starterProject();
    Set<String> ids(ProjectDoc p) => {
          p.id,
          for (final m in p.modules) m.id,
          for (final l in p.layers) ...[l.id, for (final c in l.clips) c.id],
        };
    expect(ids(a).intersection(ids(b)), isEmpty);
    expect(ids(a), hasLength(1 + 4 + 4 + 5));
    // The asset's own ids are not reused either.
    final asset = jsonDecode(File(defaultProjectAsset).readAsStringSync()) as Map<String, dynamic>;
    expect(ids(a), isNot(contains(asset['id'])));
    expect(ids(a).intersection({for (final l in asset['layers'] as List) (l as Map)['id']}), isEmpty);
    for (final p in [a, b]) {
      final modules = {for (final m in p.modules) m.id};
      final layers = {for (final l in p.layers) l.id};
      for (final l in p.layers) {
        for (final c in l.clips) {
          expect(modules, contains(c.patternId), reason: '${l.name} clip');
        }
        if (l.patternId != null) expect(modules, contains(l.patternId));
        if (l.parentId != null) expect(layers, contains(l.parentId));
        for (final send in l.sends) {
          expect(layers, contains(send.to), reason: '${l.name} send');
        }
        for (final c in [...l.components, ?l.instrument]) {
          final key = c.key;
          if (key != null) expect(layers, contains(key.layer), reason: '${l.name} ${c.id} sidechain');
        }
      }
    }
  });

  test('ids are remapped consistently, references included', () {
    final p = projectWithFreshIds({
      'id': 'old', 'name': 'R',
      'modules': [{'id': 'm1', 'name': 'P', 'source': '---\nkind: pattern\nlength: 16\n---\n0 C3 1 1\n'}],
      'layers': [
        {'id': 'bus', 'name': 'Bus', 'folder': true, 'bus': true},
        {'id': 'kick', 'name': 'Kick', 'parent': 'bus', 'clips': [{'id': 'c1', 'pattern': 'm1', 'length_steps': 16}],
          'instrument': {'id': 'org.caw.drums'}},
        {'id': 'pad', 'name': 'Pad', 'sends': [{'to': 'bus'}],
          'components': [{'id': 'org.caw.ducker', 'params': {'mode': 0.0}, 'key': {'layer': 'kick'}}]},
      ],
    });
    final byName = {for (final l in p.layers) l.name: l};
    expect(p.id, isNot('old'));
    expect(byName.values.map((l) => l.id), everyElement(isNot(anyOf('bus', 'kick', 'pad'))));
    expect(byName['Kick']!.parentId, byName['Bus']!.id);
    expect(byName['Kick']!.clips.single.patternId, p.modules.single.id);
    expect(byName['Pad']!.sends.single.to, byName['Bus']!.id);
    expect(byName['Pad']!.components.single.key?.layer, byName['Kick']!.id);
    expect(byName['Pad']!.components.single.id, 'org.caw.ducker');
  });

  test('the bundled template is named after it, and first runs and New project get new project ids', () {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    final t = s.templateById(firstLoopTemplateId)!;
    expect(t.name, 'Mid tempo');
    expect(templateLabel(firstLoopTemplateId), 'Mid tempo');
    final a = s.projectFromTemplate(t), b = s.projectFromTemplate(t);
    expect(a.name, 'mid tempo');
    expect(a.id, isNot(b.id));
    expect(a.layers.first.id, isNot(b.layers.first.id));
  });

  test('the asset is listed in the bundle', () async {
    expect(await rootBundle.loadString(defaultProjectAsset), contains('"mid tempo"'));
  });

  final lib = Platform.environment['CAW_LIB'];
  test('the engine knows every component in it and plays it without errors', () async {
    final s = AppState(settings: Settings());
    addTearDown(s.dispose);
    final p = s.starterProject();
    final e = Engine.create();
    final result = await e.setProject(p.toEngineJson());
    for (final m in p.modules) {
      expect(result[m.id]?.ok, isTrue, reason: '${m.name}: ${result[m.id]?.error}');
    }
    final known = {for (final c in await e.nativeComponents()) c.id};
    for (final l in p.layers) {
      for (final c in [?l.instrument, ...l.components]) {
        expect(known, contains(c.id), reason: '${l.name} ${c.id}');
      }
    }
    e.dispose();
    // The whole song: 256 steps at 90 BPM is 42.7 s; every track plays in its last 10 s.
    final dir = await Directory.systemTemp.createTemp('caw-default');
    addTearDown(() => dir.delete(recursive: true));
    final out = '${dir.path}/default.wav';
    final job = RenderJob.start(RenderRequest(projectJson: p.toEngineJson(), kind: ExportKind.free, outPath: out,
        seconds: 43));
    expect(await job.result, isNull);
    final bytes = await File(out).readAsBytes();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    // 24-bit stereo samples after the header: something sounds, and nothing is pinned at full scale.
    final data = ByteData.sublistView(bytes, 44);
    var peak = 0;
    for (var i = 0; i + 3 <= data.lengthInBytes; i += 3) {
      var v = data.getUint8(i) | data.getUint8(i + 1) << 8 | data.getUint8(i + 2) << 16;
      if (v & 0x800000 != 0) v -= 0x1000000;
      if (v.abs() > peak) peak = v.abs();
    }
    expect(peak, greaterThan(1 << 12));
  }, skip: lib == null || lib.isEmpty, timeout: const Timeout(Duration(minutes: 3)));
}
