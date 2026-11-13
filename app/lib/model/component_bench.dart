// The plug-in benchmark: the interface the engine's binding implements (API 30), the runner the screen watches, and the user's built plug-ins it can time. Results stay local, never telemetry.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'component_bench_result.dart';
import 'cpp_workbench.dart';
import 'stress_runner.dart';

/// One plug-in benchmark: a built component, by its library file and/or the id the engine loaded it as.
class ComponentBenchRequest {
  const ComponentBenchRequest({this.libraryPath, this.componentId = '', required this.instrument, this.name = ''});
  final String? libraryPath;
  final String componentId;
  final bool instrument;
  final String name;
}

/// A running plug-in benchmark (a CawJob of kind ComponentBench: status, cancel, wait, result and release reused).
abstract class ComponentBenchJob {
  /// 0..1 of the run (0 while the engine can't tell).
  double get fraction;
  void cancel();

  /// The engine's result JSON (contract section 4), or {'ok': false, 'error': ...}.
  Future<Map<String, dynamic>> get result;
}

/// Where plug-in benchmarks go: the engine's binding sets [current] (bench2-engine), tests pass a fake.
abstract class ComponentBenchBackend {
  static ComponentBenchBackend current = const NoComponentBench();
  ComponentBenchJob start(ComponentBenchRequest request);
}

/// An engine without the plug-in benchmark (before API 30): every run says so.
class NoComponentBench implements ComponentBenchBackend {
  const NoComponentBench();
  @override
  ComponentBenchJob start(ComponentBenchRequest request) => _Refused();
}

class _Refused implements ComponentBenchJob {
  @override
  double get fraction => 0;
  @override
  void cancel() {}
  @override
  final Future<Map<String, dynamic>> result =
      Future.value({'ok': false, 'error': 'This engine has no plug-in benchmark yet'});
}

/// A built plug-in the Benchmark can time.
class ComponentBenchTarget {
  const ComponentBenchTarget({required this.name, required this.componentId, this.libraryPath, required this.instrument});
  final String name, componentId;

  /// Null: not built (nothing to time).
  final String? libraryPath;
  final bool instrument;
  bool get built => libraryPath != null;
  String get kind => instrument ? 'instrument' : 'effect';

  ComponentBenchRequest get request =>
      ComponentBenchRequest(libraryPath: libraryPath, componentId: componentId, instrument: instrument, name: name);

  factory ComponentBenchTarget.of(CppWorkbench w) =>
      ComponentBenchTarget(name: w.name, componentId: w.componentId, libraryPath: w.artifactPath, instrument: w.isInstrument);
}

/// The project's built C++ components: an open editor's last build, else the library the engine loaded.
List<ComponentBenchTarget> componentBenchTargets(AppState state) {
  final out = <ComponentBenchTarget>[];
  for (final c in state.project.cppComponents) {
    final w = state.openCppWorkbench(c.id);
    if (w != null) {
      if (w.artifactPath != null) out.add(ComponentBenchTarget.of(w));
      continue;
    }
    final path = state.nativeComponents?.artifactOf(c.componentId);
    if (path == null) continue;
    out.add(ComponentBenchTarget(
        name: c.name,
        componentId: c.componentId,
        libraryPath: path,
        instrument: c.files.values.any((s) => s.contains('InstrumentProcessor'))));
  }
  return out;
}

/// Runs one plug-in benchmark at a time for a screen: progress, cancel, the parsed result. Nothing is sent anywhere.
class ComponentBenchRunner extends ChangeNotifier {
  ComponentBenchRunner({ComponentBenchBackend? backend, this.host}) : backend = backend ?? ComponentBenchBackend.current;
  final ComponentBenchBackend backend;

  /// The app's transport and device, set aside while it runs (as the Benchmark), so playback doesn't skew it.
  final StressHost? host;

  bool _running = false;
  bool get running => _running;
  double fraction = 0;
  ComponentBenchResult? result;
  ComponentBenchJob? _job;
  Timer? _poll;
  bool _disposed = false;

  void cancel() => _job?.cancel();

  Future<ComponentBenchResult> run(ComponentBenchRequest request) async {
    if (_running) throw StateError('a plug-in benchmark is already running');
    _running = true;
    fraction = 0;
    result = null;
    notifyListeners();
    host?.suspendForStress();
    ComponentBenchResult out;
    try {
      final job = backend.start(request);
      _job = job;
      _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
        fraction = job.fraction.clamp(0.0, 1.0);
        notifyListeners();
      });
      final json = await job.result;
      out = json['stop_reason'] == 'cancelled'
          ? ComponentBenchResult(error: 'You stopped it')
          : ComponentBenchResult.parse(json);
    } catch (e) {
      out = ComponentBenchResult(error: 'The benchmark failed: $e');
    } finally {
      _poll?.cancel();
      _poll = null;
      _job = null;
      host?.resumeAfterStress();
      _running = false;
    }
    result = out;
    fraction = 1;
    notifyListeners();
    return out;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _job?.cancel();
    super.dispose();
  }
}
