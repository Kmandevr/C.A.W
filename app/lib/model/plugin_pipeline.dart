// The plug-in page's pipeline for one C++ component: Write → Build → Test → Export, each step's status, one-line result and the next thing to do, read from its CppWorkbench.
import 'cpp_diagnostics.dart';
import 'cpp_workbench.dart';

enum PluginStepKind { write, build, test, export }

/// How a step reads at a glance.
enum PluginStepState {
  /// Done and up to date.
  done,

  /// Done, with something to look at (warnings, a CHECK verdict).
  warn,
  failed,
  notRun,

  /// Done once, but the code (or the build) changed since.
  outdated,
  running,
}

/// What the page's primary button does next.
enum PluginNext { fixErrors, build, test, reviewTests, export }

class PluginStep {
  const PluginStep(this.kind, this.state, this.summary);
  final PluginStepKind kind;
  final PluginStepState state;

  /// The step's key result in one line.
  final String summary;

  bool get settled => state == PluginStepState.done || state == PluginStepState.warn;
}

String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// The four steps of [w] as they stand now.
class PluginPipeline {
  PluginPipeline(this.w);
  final CppWorkbench w;

  /// The latest build is loaded and made from the code as it is now.
  bool get buildCurrent =>
      w.phase != CppBuildPhase.failed && w.phase != CppBuildPhase.building && w.builtRevision == w.codeRevision &&
      w.artifactPath != null;

  /// The last test ran on the current build.
  bool get testCurrent {
    final t = w.lastTest;
    return t != null && buildCurrent && t.build == w.builds && t.revision == w.builtRevision;
  }

  /// The latest build passed the test suite (a CHECK verdict counts as passing).
  bool get testedOk => testCurrent && w.lastTest!.verdict != PluginCheck.fail;

  List<CppDiagnostic> get errors => [for (final d in w.diagnostics) if (d.isError) d];

  PluginStep get write {
    final errors = w.errorCount, warnings = w.warningCount, files = w.texts.length;
    if (errors > 0) {
      return PluginStep(PluginStepKind.write, PluginStepState.failed,
          '${_plural(errors, 'error')}${warnings > 0 ? ', ${_plural(warnings, 'warning')}' : ''} in the code');
    }
    if (warnings > 0) return PluginStep(PluginStepKind.write, PluginStepState.warn, '${_plural(warnings, 'warning')} · ${_plural(files, 'file')}');
    if (w.checking) return PluginStep(PluginStepKind.write, PluginStepState.running, 'Checking…');
    return PluginStep(PluginStepKind.write, PluginStepState.done, '${_plural(files, 'file')} · no problems found');
  }

  PluginStep get build {
    if (w.phase == CppBuildPhase.building) return const PluginStep(PluginStepKind.build, PluginStepState.running, 'Building…');
    if (w.phase == CppBuildPhase.failed) {
      return PluginStep(PluginStepKind.build, PluginStepState.failed, w.buildMessage ?? 'The build failed.');
    }
    if (w.artifactPath == null || w.builtRevision == null) {
      return const PluginStep(PluginStepKind.build, PluginStepState.notRun, 'Not built yet');
    }
    if (!buildCurrent) return const PluginStep(PluginStepKind.build, PluginStepState.outdated, 'Out of date: the code changed since');
    final label = w.builds == 0 ? 'Built (loaded with the project)' : (w.buildMessage ?? 'Built');
    if (w.warningCount > 0) return PluginStep(PluginStepKind.build, PluginStepState.warn, '$label · ${_plural(w.warningCount, 'warning')}');
    return PluginStep(PluginStepKind.build, PluginStepState.done, label);
  }

  PluginStep get test {
    final t = w.lastTest;
    if (w.artifactPath == null) return const PluginStep(PluginStepKind.test, PluginStepState.notRun, 'Needs a build first');
    if (t == null) return const PluginStep(PluginStepKind.test, PluginStepState.notRun, 'Not run on this build');
    if (!testCurrent) {
      return PluginStep(PluginStepKind.test, PluginStepState.outdated, 'Out of date: tested an older build (${t.summary})');
    }
    return PluginStep(PluginStepKind.test, switch (t.verdict) {
      PluginCheck.pass => PluginStepState.done,
      PluginCheck.warn => PluginStepState.warn,
      PluginCheck.fail => PluginStepState.failed,
    }, t.summary);
  }

  PluginStep get export {
    final e = w.lastExport;
    if (e == null) {
      return PluginStep(PluginStepKind.export, PluginStepState.notRun,
          w.isInstrument ? 'CLAP, VST3 or a sample pack' : 'CLAP or VST3');
    }
    if (e.revision != w.codeRevision) {
      return PluginStep(PluginStepKind.export, PluginStepState.outdated, 'Out of date: ${e.target} · ${e.file} has older code');
    }
    return PluginStep(PluginStepKind.export, PluginStepState.done, 'Saved ${e.target} · ${e.file}');
  }

  List<PluginStep> get steps => [write, build, test, export];

  /// A warning for the export step (shown, never blocking): the latest build hasn't passed the tests.
  String? get exportWarning {
    if (testedOk) return null;
    if (!buildCurrent) return 'The latest code isn\'t built: the export uses the code as it is now, untested.';
    if (!testCurrent) return 'This build hasn\'t been tested yet. You can still export.';
    return 'This build failed its tests. You can still export.';
  }

  /// The one thing to do next, in pipeline order.
  PluginNext get next {
    if (w.errorCount > 0 && w.phase != CppBuildPhase.building) return PluginNext.fixErrors;
    if (!buildCurrent) return PluginNext.build;
    if (!testCurrent) return PluginNext.test;
    if (w.lastTest!.verdict == PluginCheck.fail) return PluginNext.reviewTests;
    return PluginNext.export;
  }

  /// Which step [next] belongs to.
  PluginStepKind get nextStep => switch (next) {
        PluginNext.fixErrors => PluginStepKind.write,
        PluginNext.build => PluginStepKind.build,
        PluginNext.test || PluginNext.reviewTests => PluginStepKind.test,
        PluginNext.export => PluginStepKind.export,
      };
}
