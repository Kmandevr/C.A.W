// A project's C++ components: own code builds and loads, other code waits for a choice, builds are reused.
import 'dart:io';

import 'package:caw/engine/component_bench.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/component_bench.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/native_components.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/cpp_build.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late NativeTrustStore trust;
  late List<String> builds;
  late List<({String path, String id, bool reload})> loads;
  late NativeComponentManager manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('caw-native-components');
    trust = NativeTrustStore(File('${dir.path}/trust.json'));
    builds = [];
    loads = [];
    var n = 0;
    manager = NativeComponentManager(
      trust: trust,
      cacheFile: File('${dir.path}/builds.json'),
      build: (project, component) async {
        builds.add(component.componentId);
        if (component.files['src/x.cpp'] == 'broken') {
          return const CppBuildResult(success: false, exitCode: 1, output: 'error', diagnostics: []);
        }
        final path = '${dir.path}/${component.componentId}-${n++}.so';
        await File(path).writeAsString('ELF');
        return CppBuildResult(success: true, exitCode: 0, output: '', diagnostics: const [], artifactPath: path);
      },
      load: ({required artifactPath, required expectedComponentId, required trust, bool reload = false}) async {
        loads.add((path: artifactPath, id: expectedComponentId, reload: reload));
        return NativeComponentLoadResult(ok: true, componentId: expectedComponentId);
      },
    );
  });
  tearDown(() => dir.delete(recursive: true));

  CppComponentDoc component(String id, String source) =>
      CppComponentDoc(id: id, name: id, componentId: 'org.me.$id', files: {'src/x.cpp': source});

  test('own code builds and loads; code from elsewhere waits for the user; blocked code never builds', () async {
    final mine = component('delay', 'int a;');
    final theirs = component('fuzz', 'int b;');
    final banned = component('evil', 'int c;');
    trust.markAuthored(mine);
    trust.remember('org.me.evil', NativeTrustStore.sourceFingerprint(banned), NativeComponentTrust.blocked);
    final project = ProjectDoc(id: 'p', name: 'P', bpm: 120, cppComponents: [mine, theirs, banned]);
    final status = await manager.prepare(project);
    expect(status.loaded, ['org.me.delay']);
    expect(status.needsTrust.single.componentId, 'org.me.fuzz');
    expect(status.blocked, ['org.me.evil']);
    expect(builds, ['org.me.delay']);
    expect(loads.single.reload, isFalse);
    // Trusting it lets the next pass build and load it.
    trust.remember('org.me.fuzz', NativeTrustStore.sourceFingerprint(theirs), NativeComponentTrust.trusted);
    final again = await manager.prepare(project);
    expect(again.loaded, containsAll(['org.me.delay', 'org.me.fuzz']));
    expect(builds, ['org.me.delay', 'org.me.fuzz']);  // the loaded one wasn't rebuilt
  });

  // Security review (2026-11-13): revoking trust stops the plug-in benchmark at once.
  test('a trusted component loads and is benchable; blocked or forgotten, it is neither listed nor run', () async {
    final theirs = component('fuzz', 'int b;');
    final fp = NativeTrustStore.sourceFingerprint(theirs);
    trust.remember('org.me.fuzz', fp, NativeComponentTrust.trusted);
    final project = ProjectDoc(id: 'p', name: 'P', bpm: 120, cppComponents: [theirs]);
    expect((await manager.prepare(project)).loaded, ['org.me.fuzz']);
    final state = AppState(settings: Settings());
    addTearDown(state.dispose);
    state.project = project;
    state.nativeComponents = manager;
    final listed = componentBenchTargets(state);
    expect(listed.single.componentId, 'org.me.fuzz');
    expect(listed.single.request.trusted, isTrue);

    // Blocked after the target was listed: starting it sends no trust, and the engine's binding refuses it unrun.
    trust.remember('org.me.fuzz', fp, NativeComponentTrust.blocked);
    expect(listed.single.request.trusted, isFalse);
    final refused = await const EngineComponentBench().start(listed.single.request).result;
    expect(refused['ok'], isFalse);
    expect('${refused['error']}', contains('Trust'));
    expect(componentBenchTargets(state), isEmpty);
    // The next pass drops what the engine had of it: no artifact for the Build tools or the bench.
    final status = await manager.prepare(project);
    expect(status.blocked, ['org.me.fuzz']);
    expect(manager.artifactOf('org.me.fuzz'), isNull);
    expect(manager.loaded, isEmpty);
    expect(componentBenchTargets(state), isEmpty);

    // Forgotten (asks again): the same.
    trust.remember('org.me.fuzz', fp, NativeComponentTrust.trusted);
    await manager.prepare(project);
    expect(componentBenchTargets(state), hasLength(1));
    trust.forget('org.me.fuzz');
    expect(componentBenchTargets(state), isEmpty);
    expect((await manager.prepare(project)).needsTrust.single.componentId, 'org.me.fuzz');
    expect(manager.artifactOf('org.me.fuzz'), isNull);
    // Trusted again, it reloads (the engine still has the old load).
    trust.remember('org.me.fuzz', fp, NativeComponentTrust.trusted);
    await manager.prepare(project);
    expect(loads.last.reload, isTrue);
  });

  test('an unchanged component reuses its build; an edit rebuilds and reloads', () async {
    final mine = component('delay', 'int a;');
    trust.markAuthored(mine);
    final project = ProjectDoc(id: 'p', name: 'P', bpm: 120, cppComponents: [mine]);
    await manager.prepare(project);
    mine.files['src/x.cpp'] = 'int a = 1;';
    trust.markAuthored(mine);  // the editor marks the user's edit
    await manager.prepare(project);
    expect(builds.length, 2);
    expect(loads.last.reload, isTrue);
    // A new session (a reopened app) with the same sources reuses the cached build.
    final next = NativeComponentManager(trust: trust, cacheFile: File('${dir.path}/builds.json'),
        build: manager.build, load: manager.load);
    await next.prepare(project);
    expect(builds.length, 2);
    expect(loads.last.path, loads[1].path);
  });

  test('a build that fails is reported with its result', () async {
    final mine = component('delay', 'broken');
    trust.markAuthored(mine);
    final status = await manager.prepare(ProjectDoc(id: 'p', name: 'P', bpm: 120, cppComponents: [mine]));
    expect(status.buildFailed.keys, ['org.me.delay']);
    expect(status.ready, isFalse);
    expect(loads, isEmpty);
  });
}
