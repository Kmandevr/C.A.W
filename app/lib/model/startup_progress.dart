// The real loading steps at launch (AppState.init reports them), for the startup screen's ticking list.
import 'package:flutter/foundation.dart';

/// What the app does at launch, in order: each is reported by [AppState.init] as it starts and ends.
enum StartupStep {
  engine('Starting audio engine'),
  projects('Reading saved projects'),
  components('Loading C++ components'),
  project('Opening project');

  const StartupStep(this.label);
  final String label;
}

/// Where launch is: the steps begun, the steps ended (and which failed), each step's count where one is known, and
/// the name of the project being opened.
class StartupProgress extends ChangeNotifier {
  final Set<StartupStep> _begun = {}, _done = {}, _failed = {};
  final Map<StartupStep, (int, int?)> _counts = {};

  /// The open project's name once it is known, shown on the last step ("Opening Mid tempo").
  String? projectName;

  bool begun(StartupStep step) => _begun.contains(step);
  bool done(StartupStep step) => _done.contains(step);
  bool failed(StartupStep step) => _failed.contains(step);

  /// [step]'s count so far: how many are done and, when known, of how many (null: no count).
  (int, int?)? countOf(StartupStep step) => _counts[step];

  /// The steps shown so far, in order (a step shows from when it begins).
  List<StartupStep> get shown => [for (final s in StartupStep.values) if (_begun.contains(s)) s];

  /// What [step]'s row says: its label with the project's name ("Opening Mid tempo") or its count ("Loading C++
  /// components 3/7", "Reading saved projects 12").
  String label(StartupStep step) {
    final name = projectName;
    if (step == StartupStep.project && name != null) return 'Opening $name';
    final count = _counts[step];
    if (count == null) return step.label;
    final (n, total) = count;
    return total == null ? '${step.label} $n' : '${step.label} $n/$total';
  }

  void begin(StartupStep step, {String? project}) {
    if (project != null) projectName = project;
    if (_begun.add(step) || project != null) notifyListeners();
  }

  /// [step] has done [n] things, of [total] when that is known ("3/7"); without a total, [n] is how many it found.
  void count(StartupStep step, int n, [int? total]) {
    if (_counts[step] == (n, total)) return;
    _counts[step] = (n, total);
    notifyListeners();
  }

  /// [step] ended; [ok] false marks it failed (the app still opens and says why).
  void finish(StartupStep step, {bool ok = true}) {
    _begun.add(step);
    final changed = _done.add(step) | (!ok && _failed.add(step));
    if (changed) notifyListeners();
  }
}
