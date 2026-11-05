// The project's undo and redo history (UI plan: undo and redo in the transport): whole-project snapshots, one per
// burst of edits, so a drag or a run of typing undoes in one step.

/// Snapshots of the project as text (its JSON), oldest first. Plain values with no timers: the owner calls [begin] on
/// every edit and [settle] once the edits have paused, so a burst of edits is one step.
class ProjectHistory {
  ProjectHistory({this.limit = 100});

  /// The most steps kept; the oldest go first.
  final int limit;

  final List<String> _undo = [], _redo = [];
  String? _stable;
  bool _open = false;

  /// True while a burst is open too (once there is a project to go back to): its edit is undoable before it settles.
  bool get canUndo => _undo.isNotEmpty || (_open && _stable != null);
  bool get canRedo => _redo.isNotEmpty;

  /// A new project (or one just opened): no history, and [current] is where it stands.
  void reset(String current) {
    _undo.clear();
    _redo.clear();
    _stable = current;
    _open = false;
  }

  /// An edit is happening; the burst stays open until [settle].
  void begin() => _open = true;

  /// The burst is over and the project now stands at [current]. A burst that changed nothing (a save with no edit,
  /// such as Run on unedited code) adds no step and keeps redo; one that changed something records the project as it
  /// stood before, and clears redo.
  void settle(String current) {
    _open = false;
    final before = _stable;
    _stable = current;
    if (before == null || before == current) return;
    _undo.add(before);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// The snapshot to go back to, given the project now stands at [current]; null when there is none.
  String? undo(String current) {
    if (_open) settle(current);
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _stable = _undo.removeLast();
  }

  /// The snapshot to go forward to; null when there is none.
  String? redo(String current) {
    if (_open) settle(current);
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _stable = _redo.removeLast();
  }
}
