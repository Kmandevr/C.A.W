// The real loading steps at launch (AppState.init reports them), for the startup screen's ticking list.
import 'package:flutter/foundation.dart';

/// What the app does at launch, in order: each is reported by [AppState.init] as it starts and ends.
enum StartupStep {
  engine('Starting audio engine'),
  components('Loading C++ components'),
  projects('Reading saved projects'),
  project('Opening project');

  const StartupStep(this.label);
  final String label;
}

/// Where launch is: the steps begun, the steps ended (and which failed), and the name of the project being opened.
class StartupProgress extends ChangeNotifier {
  final Set<StartupStep> _begun = {}, _done = {}, _failed = {};

  /// The open project's name once it is known, shown on the last step ("Opening Mid tempo").
  String? projectName;

  bool begun(StartupStep step) => _begun.contains(step);
  bool done(StartupStep step) => _done.contains(step);
  bool failed(StartupStep step) => _failed.contains(step);

  /// The steps shown so far, in order (a step shows from when it begins).
  List<StartupStep> get shown => [for (final s in StartupStep.values) if (_begun.contains(s)) s];

  void begin(StartupStep step, {String? project}) {
    if (project != null) projectName = project;
    if (_begun.add(step) || project != null) notifyListeners();
  }

  /// [step] ended; [ok] false marks it failed (the app still opens and says why).
  void finish(StartupStep step, {bool ok = true}) {
    _begun.add(step);
    final changed = _done.add(step) | (!ok && _failed.add(step));
    if (changed) notifyListeners();
  }
}
