// The C++ Builder: diagnostics, completion, the debounced check, the compiler queue, versions and the SDK reference.
import 'dart:async';
import 'dart:io';

import 'package:caw/model/app_state.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/cpp_completion.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/cpp_diagnostics.dart';
import 'package:caw/model/cpp_reference.dart';
import 'package:caw/model/cpp_versions.dart';
import 'package:caw/model/cpp_workbench.dart';
import 'package:caw/model/native_components.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/platform/cpp_build.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/cpp_compiler.dart';
import 'package:caw/ui/cpp/code_style.dart';
import 'package:flutter/painting.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records each call; answers with [reply] (given the arguments).
class FakeCompiler implements CppCompiler {
  FakeCompiler(this.toolchain, {this.reply});
  final String toolchain;
  final ({int code, String output}) Function(List<String> args)? reply;
  final calls = <List<String>>[];

  @override
  Future<String> toolchainDirectory() async => toolchain;

  @override
  Future<({int code, String output})> run(List<String> args) async {
    calls.add(args);
    return reply?.call(args) ?? (code: 0, output: '');
  }
}

// Real Clang 18 output (-fdiagnostics-print-source-range-info -fno-caret-diagnostics), 2026-11-10.
const clangOutput = '''
/work/src/effect.cpp:1:17: error: use of undeclared identifier 'undefined_name'
/work/src/effect.cpp:2:24:{2:22-2:29}: warning: adding 'int' to a string does not append to the string [-Wstring-plus-int]
/work/src/effect.cpp:2:24: note: use array indexing to silence this warning
/work/src/effect.cpp:2:22:{2:22-2:29}: error: cannot initialize return object of type 'int' with an rvalue of type 'const char *'
/work/include/helper.hpp:9:3: fatal error: 'missing.h' file not found
2 errors generated.
''';

void main() {
  group('diagnostics', () {
    test('Clang lines become problems in project paths, with ranges; notes are left out', () {
      final d = parseClangDiagnostics(clangOutput, sourceDirectory: '/work');
      expect(d, hasLength(4));
      expect(d[0], const CppDiagnostic(
          file: 'src/effect.cpp', line: 1, column: 17, severity: CppSeverity.error, message: "use of undeclared identifier 'undefined_name'"));
      expect(d[1].severity, CppSeverity.warning);
      expect((d[1].endLine, d[1].endColumn), (2, 29));
      expect(d[2].column, 22);
      expect(d[3].file, 'include/helper.hpp');
      expect(d[3].isError, isTrue);
      // A header seen through two sources is reported once.
      expect(parseClangDiagnostics('$clangOutput$clangOutput', sourceDirectory: '/work'), hasLength(4));
    });

    test('grouped by file with errors first; the error count steps through errors and wraps', () {
      final d = parseClangDiagnostics(clangOutput, sourceDirectory: '/work');
      final g = groupDiagnostics(d, order: ['src/effect.cpp']);
      expect(g.keys, ['src/effect.cpp', 'include/helper.hpp']);
      expect(g['src/effect.cpp']!.map((x) => x.severity), [CppSeverity.error, CppSeverity.error, CppSeverity.warning]);
      final order = ['src/effect.cpp', 'include/helper.hpp'];
      expect(nextError(d, order: order)!.line, 1);
      expect(nextError(d, file: 'src/effect.cpp', line: 1, column: 17, order: order)!.line, 2);
      expect(nextError(d, file: 'src/effect.cpp', line: 2, column: 22, order: order)!.file, 'include/helper.hpp');
      expect(nextError(d, file: 'include/helper.hpp', line: 9, column: 3, order: order)!.line, 1);
      expect(nextError(const []), isNull);
    });

    test('marks underline the range, or the word at the column, and squiggles keep the colours', () {
      final d = parseClangDiagnostics(clangOutput, sourceDirectory: '/work');
      final marks = marksFor(d, 'src/effect.cpp', ['int f(){ return undefined_name + 1; }', 'int g(int a){ return a + "x"; }']);
      expect(marks[0]!.single.start, 16);
      expect(marks[0]!.single.end, 30); // the word
      expect(marks[1]!.map((m) => (m.start, m.end)), [(21, 28), (21, 28)]);
      final span = decorateSpan(
          const TextSpan(style: TextStyle(fontSize: 12), children: [TextSpan(text: 'int '), TextSpan(text: 'bad', style: TextStyle(color: Color(0xFF00FF00)))]),
          const [LineMark(4, 7, CppSeverity.error)]);
      expect(span.toPlainText(), 'int bad');
      final bad = span.children!.last as TextSpan;
      expect(bad.text, 'bad');
      expect(bad.style!.decorationStyle, TextDecorationStyle.wavy);
      expect(bad.style!.color, const Color(0xFF00FF00));
    });
  });

  group('completion', () {
    test('the context knows the word, the trigger and what it qualifies', () {
      final dot = CppCompletionContext.at('    p.def', 9);
      expect((dot.prefix, dot.trigger, dot.qualifier), ('def', '.', 'p'));
      final ns = CppCompletionContext.at('x = caw::lib::', 14);
      expect((ns.prefix, ns.trigger, ns.qualifier), ('', '::', 'lib'));
      expect(CppCompletionContext.at('a->', 3).trigger, '->');
      expect(CppCompletionContext.at('// p.', 5).trigger, 'none');
      expect(CppCompletionContext.at('ret', 3).opensAutomatically, isTrue);
      expect(CppCompletionContext.at('r', 1).opensAutomatically, isFalse);
    });

    test('the instant list: members after a dot, a namespace after ::, keywords, the file and the knobs', () {
      List<String> labels(String line, {String file = '', List<CppCompletion> knobs = const []}) =>
          staticCompletions(CppCompletionContext.at(line, line.length), file, knobs: knobs).map((c) => c.label).toList();
      expect(labels('p.def'), contains('defaultValue'));
      // The bare list holds the 40 shortest of the Library's names; longer ones come with the letters typed.
      expect(labels('caw::lib::'), contains('drive'));
      expect(labels('caw::lib::'), hasLength(40));
      expect(labels('caw::lib::Ping'), contains('PingPongDelay'));
      expect(labels('caw::lib::note'), contains('noteSeconds'));
      expect(labels('caw::lib::uni'), contains('unisonLayout'));
      expect(labels('caw::lib::'), isNot(contains('ModuleDescriptor')));
      expect(labels('ret'), contains('return'));
      expect(labels('fee', file: 'double feedbackAmount = 0;'), contains('feedbackAmount'));
      final knob = labels('ga', knobs: const [CppCompletion('gain', detail: '0..2 dB')]);
      expect(knob.first, 'gain');
    });

    test("Clang's results are parsed (real output) and lead the merged list", () {
      const out = '''
COMPLETION: automatable : [#bool#]automatable
COMPLETION: defaultValue : [#double#]defaultValue
COMPLETION: operator= : [#ParameterDescriptor &#]operator=(<#const ParameterDescriptor &#>)
COMPLETION: ParameterDescriptor : ParameterDescriptor::
COMPLETION: ~ParameterDescriptor : [#void#]~ParameterDescriptor()
COMPLETION: process : [#bool#]process(<#const AudioProcessBlock &block#>)
''';
      final c = parseClangCompletions(out);
      expect(c.map((x) => x.label), ['automatable', 'defaultValue', 'process']);
      expect(c[1].detail, 'double');
      expect(c[2].detail, 'bool (const AudioProcessBlock &block)');
      expect(parseClangCompletions(out, prefix: 'def').single.label, 'defaultValue');
      final merged = mergeCompletions(c, const [CppCompletion('defaultValue', detail: 'double'), CppCompletion('minimum')]);
      expect(merged.map((x) => x.label), ['automatable', 'defaultValue', 'process', 'minimum']);
    });
  });

  test('every SDK name in the reference is declared in the shipped headers', () {
    final headers = Directory('../engine/include/caw')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.hpp'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    for (final e in cppReference) {
      expect(RegExp('\\b${RegExp.escape(e.name)}\\b').hasMatch(headers), isTrue, reason: '${e.qualified} is not in the SDK');
    }
  });

  test('every built-in in the Library is registered in the engine with those knobs', () {
    // Every engine/src/builtin_*.cpp: the components, instruments, flagship and effects suite.
    final src = (Directory('../engine/src').listSync().whereType<File>().map((f) => f.path)
            .where((p) => RegExp(r'builtin_[a-z_]+\.cpp$').hasMatch(p)).toList()..sort())
        .map((p) => File(p).readAsStringSync())
        .join('\n');
    for (final b in cppBuiltins) {
      expect(src, contains('"${b.id}"'), reason: '${b.id} is not a built-in');
      for (final k in b.knobs) {
        expect(src, contains('"$k"'), reason: '${b.id} has no knob $k');
      }
    }
    // Internal components (ModuleRegistry::addInternal) play by id but are never listed, so the Library leaves them out.
    const internal = {'org.caw.downmix', 'org.caw.test.osc'};
    final ids = RegExp(r'"(org\.caw\.[a-z.]+)"').allMatches(src).map((m) => m.group(1)).toSet().difference(internal);
    expect(ids, cppBuiltins.map((b) => b.id).toSet(), reason: 'a built-in is missing from the Library');
  });

  test('check and completion arguments share the build flags, compile nothing and link nothing', () {
    final m = CppComponentManifest.parse(
        '{"format":"caw.component","version":1,"component":{"id":"a.b"},"sources":["src/e.cpp"],"compileDefinitions":["N=2"]}');
    final check = CppSourceBuilder.checkArguments(toolchain: '/tc', sourceDirectory: '/s', manifest: m);
    expect(check, containsAll(['/tc/bin/clang++', '-fsyntax-only', '-std=c++20', '-ffp-contract=off', '-I/tc/caw-sdk/include', '-DN=2', '/s/src/e.cpp']));
    expect(check, isNot(contains('-o')));
    expect(check, isNot(contains('-shared')));
    final complete = CppSourceBuilder.completionArguments(
        toolchain: '/tc', sourceDirectory: '/s', manifest: m, source: 'src/e.cpp', line: 3, column: 7);
    expect(complete, containsAllInOrder(['-Xclang', '-code-completion-at=/s/src/e.cpp:3:7', '/s/src/e.cpp']));
  });

  test('the compiler queue runs one call at a time, drops superseded checks and retries a busy reply', () async {
    var busy = 1;
    final gate = Completer<void>();
    final order = <String>[];
    final inner = FakeCompiler('/tc', reply: (a) {
      order.add(a.first);
      if (a.first == 'busy' && busy-- > 0) return (code: SerialCppCompiler.busyCode, output: 'busy');
      return (code: 0, output: a.first);
    });
    final q = SerialCppCompiler(_Gated(inner, gate.future), busyRetryDelay: Duration.zero);
    final build = q.run(['build']);
    final old = q.runLatest(['check 1'], key: 'check');
    final latest = q.runLatest(['check 2'], key: 'check');
    final retried = q.run(['busy']);
    gate.complete();
    expect((await build).output, 'build');
    expect(await old, isNull);
    expect((await latest)!.output, 'check 2');
    expect((await retried).code, 0);
    expect(order, ['build', 'check 2', 'busy', 'busy']);
  });

  group('versions', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw-cpp-versions'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('each build keeps a numbered version; unchanged code adds none; the last 20 stay', () async {
      final store = CppVersionStore(dir);
      final v1 = await store.add('p1', 'c1', {'a.cpp': '1'}, at: DateTime(2026, 11, 10, 14, 5));
      expect(v1.label, 'Build 1 · 14:05');
      expect((await store.add('p1', 'c1', {'a.cpp': '1'})).number, 1);
      for (var i = 2; i <= 25; i++) {
        await store.add('p1', 'c1', {'a.cpp': '$i'});
      }
      final all = await store.list('p1', 'c1');
      expect(all, hasLength(20));
      expect(all.first.number, 6);
      expect(all.last.files, {'a.cpp': '25'});
      expect(await store.list('p1', 'other'), isEmpty);
      File('${dir.path}/p1/c1.json').writeAsStringSync('{damaged');
      expect(await store.list('p1', 'c1'), isEmpty);
    });

    test('restoring a version puts its files back into the editor and the project', () async {
      final state = AppState(settings: Settings());
      final doc = CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz');
      state.project.cppComponents.add(doc);
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
      final w = state.cppWorkbench('cpp1');
      final original = Map.of(w.texts);
      final store = CppVersionStore(Directory('${dir.path}/versions'));
      await store.add(state.project.id, 'cpp1', original);
      w.edit('src/effect.cpp', '// changed');
      await w.save();
      expect(doc.files['src/effect.cpp'], '// changed');
      final before = w.revision;
      await w.restore((await w.versions()).first);
      expect(w.texts, original);
      expect(state.project.cppComponents.single.files, original);
      expect(w.revision, before + 1);
      // The code before the restore was kept as a version too.
      expect((await w.versions()).map((v) => v.files['src/effect.cpp']), contains('// changed'));
      w.dispose();
    });
  });

  group('Build', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw-cpp-build'));
    tearDown(() => dir.deleteSync(recursive: true));

    (AppState, List<String>) setUpState({required bool fail}) {
      final state = AppState(settings: Settings());
      final loads = <String>[];
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
      state.nativeComponents = NativeComponentManager(
        trust: NativeTrustStore(File('${dir.path}/trust.json')),
        cacheFile: File('${dir.path}/builds.json'),
        build: (project, component) async {
          if (fail) {
            return const CppBuildResult(
                success: false,
                exitCode: 1,
                output: "src/effect.cpp:30:9: error: expected ';' after expression\n",
                diagnostics: []);
          }
          final path = '${dir.path}/${component.componentId}.so';
          File(path).writeAsStringSync('ELF');
          return CppBuildResult(success: true, exitCode: 0, output: '', diagnostics: const [], artifactPath: path);
        },
        load: ({required artifactPath, required expectedComponentId, required trust, bool reload = false}) async {
          loads.add('$expectedComponentId ${trust.name}');
          return NativeComponentLoadResult(ok: true, componentId: expectedComponentId);
        },
      );
      return (state, loads);
    }

    test('code from elsewhere: no live check reads it, and a duplicate of it still asks for trust', () async {
      final (state, _) = setUpState(fail: false);
      final compiler = FakeCompiler('/tc');
      state.cppServices = CppBuilderServices(compiler: compiler, workDirectory: () async => dir);
      final foreign = CppComponentDoc.blankEffect(id: 'cpp7', name: 'Imported');
      state.project.cppComponents.add(foreign);
      final w = CppWorkbench(state, 'cpp7');
      await w.check();
      expect(compiler.calls, isEmpty, reason: 'untrusted code is not compiled, even to check it');
      expect(w.checkNote, contains('trust'));
      expect(await w.clangCompletions('src/effect.cpp', 0, 0, prefix: ''), isEmpty);
      final key = state.duplicateAsset(state.cppAssets.single)!;
      final copy = state.assetByKey(key)!.cpp!;
      final trust = state.nativeComponents!.trust;
      expect(trust.decide(copy.componentId, NativeTrustStore.sourceFingerprint(copy)), isNull,
          reason: 'duplicating does not make code from elsewhere the user\'s own');
      // A trusted original's copy is the user's own.
      trust.markAuthored(foreign);
      final key2 = state.duplicateAsset(state.cppAssets.firstWhere((a) => a.cpp == foreign))!;
      final copy2 = state.assetByKey(key2)!.cpp!;
      expect(trust.decide(copy2.componentId, NativeTrustStore.sourceFingerprint(copy2)), NativeComponentTrust.trusted);
      w.dispose();
    });

    test('a new effect builds and loads as trusted, and the build keeps a version', () async {
      final (state, loads) = setUpState(fail: false);
      final doc = state.newCppEffect(name: 'Fuzz');
      final w = state.cppWorkbench(doc.id);
      expect(w.own, isTrue);
      expect(await w.build(), isTrue);
      expect(w.phase, CppBuildPhase.built);
      expect(loads, ['${doc.componentId} trusted']);
      expect(w.buildMessage, startsWith('Built · Build 1'));
      expect((await w.versions()).single.files, doc.files);
      w.dispose();
    });

    test("a failed build shows Clang's errors; code from elsewhere asks before it builds", () async {
      final (state, loads) = setUpState(fail: true);
      final doc = CppComponentDoc.blankEffect(id: 'cpp9', name: 'Shared');
      state.project.cppComponents.add(doc);
      final w = state.cppWorkbench('cpp9');
      expect(w.own, isFalse);
      expect(await w.build(), isFalse, reason: 'not the user\'s code: ask first');
      expect(w.phase, CppBuildPhase.idle);
      expect(await w.build(trustConfirmed: true), isTrue);
      expect(w.phase, CppBuildPhase.failed);
      expect(w.diagnostics.single.line, 30);
      expect(w.errorCount, 1);
      expect(loads, isEmpty);
      w.dispose();
    });
  });

  group('the live check', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('caw-cpp-check'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('runs once about a second after typing stops (more typing cancels it) and marks the errors', () async {
      String? compiled;
      final compiler = FakeCompiler('/tc', reply: (args) {
        final source = args.last; // <workspace>/src/effect.cpp
        compiled = File(source).readAsStringSync(); // the workspace is removed once the check is done
        return (code: 1, output: "$source:3:5:{3:5-3:9}: error: unknown type name 'flot'\n");
      });
      final state = AppState(settings: Settings());
      state.project.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
      state.cppServices = CppBuilderServices(compiler: compiler, workDirectory: () async => dir);
      final w = CppWorkbench(state, 'cpp1', checkDelay: const Duration(milliseconds: 80), saveDelay: const Duration(milliseconds: 40));
      for (var i = 0; i < 4; i++) {
        w.edit('src/effect.cpp', '// typing $i');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(compiler.calls, isEmpty, reason: 'typing keeps the check waiting');
      }
      expect(w.checkScheduled, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(compiler.calls, hasLength(1));
      expect(compiler.calls.single, containsAll(['-fsyntax-only', '/tc/bin/clang++']));
      expect(compiler.calls.single, isNot(contains('-o')));
      // The check compiled the editor's code, written to the app-private workspace.
      expect(compiled, '// typing 3');
      expect(w.diagnostics.single, const CppDiagnostic(
          file: 'src/effect.cpp', line: 3, column: 5, endLine: 3, endColumn: 9, startColumn: 5, severity: CppSeverity.error,
          message: "unknown type name 'flot'"));
      expect(w.errorCount, 1);
      // Autosave wrote the code into the project component (no project undo step).
      expect(state.project.cppComponents.single.files['src/effect.cpp'], '// typing 3');
      expect(state.canUndo, isFalse);
      w.dispose();
    });

    test('completion points Clang at the word start in UTF-8 bytes, past non-ASCII text', () async {
      final compiler = FakeCompiler('/tc');
      final state = AppState(settings: Settings());
      state.project.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
      state.cppServices = CppBuilderServices(compiler: compiler, workDirectory: () async => dir);
      final w = CppWorkbench(state, 'cpp1');
      w.edit('src/effect.cpp', 'x = 1; // 20°C µs\nfoo.ba');
      await w.clangCompletions('src/effect.cpp', 1, 6, prefix: 'ba');
      expect(compiler.calls.single.join(' '), contains('src/effect.cpp:2:5'));
      w.edit('src/effect.cpp', '// °µ\nx.ab');
      compiler.calls.clear();
      await w.clangCompletions('src/effect.cpp', 0, 5, prefix: '');
      // "// °µ" is 5 UTF-16 units but 7 bytes: the column is byte 8.
      expect(compiler.calls.single.join(' '), contains('src/effect.cpp:1:8'));
      w.dispose();
    });

    test('a session belongs to its project: another project with the same entry id keeps its own code', () async {
      final state = AppState(settings: Settings());
      final a = state.project;
      a.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
      final wa = state.cppWorkbench('cpp1');
      wa.edit('src/effect.cpp', '// project A');
      await wa.save();
      final b = ProjectDoc(id: 'other', name: 'B')..cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
      state.project = b;
      state.notifyListeners();
      expect(b.cppComponents.single.files['src/effect.cpp'], isNot('// project A'));
      final wb = state.cppWorkbench('cpp1');
      expect(identical(wa, wb), isFalse);
      wb.edit('src/effect.cpp', '// project B');
      await wb.save();
      expect(a.cppComponents.single.files['src/effect.cpp'], '// project A');
      wa.dispose();
      wb.dispose();
    });

    test('without the in-app compiler the check only says so', () async {
      final state = AppState(settings: Settings());
      state.project.cppComponents.add(CppComponentDoc.blankEffect(id: 'cpp1', name: 'Fuzz'));
      state.cppServices = CppBuilderServices(compiler: null, workDirectory: () async => dir);
      final w = state.cppWorkbench('cpp1');
      await w.check();
      expect(w.checkNote, contains('in-app compiler'));
      expect(w.diagnostics, isEmpty);
      w.dispose();
    });
  });
}

/// Holds every call until [gate] opens, so calls queue up.
class _Gated implements CppCompiler {
  _Gated(this.inner, this.gate);
  final CppCompiler inner;
  final Future<void> gate;
  @override
  Future<String> toolchainDirectory() => inner.toolchainDirectory();
  @override
  Future<({int code, String output})> run(List<String> args) async {
    await gate;
    return inner.run(args);
  }
}
