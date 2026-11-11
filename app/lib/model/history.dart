// The project's undo and redo history (UI plan: undo and redo in the transport): whole-project snapshots, one per
// burst of edits, so a drag or a run of typing undoes in one step.

/// Snapshots of the project as text (its JSON), oldest first. Plain values with no timers: the owner calls [begin] on
/// every edit and [settle] once the edits have paused, so a burst of edits is one step.
class ProjectHistory {
  ProjectHistory({this.limit = 100, this.maxChars = 48 << 20});

  /// The most steps kept; the oldest go first.
  final int limit;

  /// The most text the undo steps keep in all (#174): a project carrying large component states would otherwise hold
  /// a hundred copies of them in memory. Past it the oldest steps go, though the newest is always kept.
  final int maxChars;
  int _undoChars = 0;

  final List<String> _undo = [], _redo = [];
  String? _stable;
  bool _open = false;

  /// True while a burst is open too (once there is a project to go back to): its edit is undoable before it settles.
  bool get canUndo => _undo.isNotEmpty || (_open && _stable != null);
  bool get canRedo => _redo.isNotEmpty;

  /// A burst of edits is open: edited since the last [settle].
  bool get open => _open;

  /// A new project (or one just opened): no history, and [current] is where it stands.
  void reset(String current) {
    _undo.clear();
    _undoChars = 0;
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
    _push(before);
    _redo.clear();
  }

  /// The snapshot to go back to, given the project now stands at [current]; null when there is none.
  String? undo(String current) {
    if (_open) settle(current);
    if (_undo.isEmpty) return null;
    _redo.add(current);
    final back = _undo.removeLast();
    _undoChars -= back.length;
    return _stable = back;
  }

  /// The snapshot to go forward to; null when there is none.
  String? redo(String current) {
    if (_open) settle(current);
    if (_redo.isEmpty) return null;
    _push(current);
    return _stable = _redo.removeLast();
  }

  void _push(String snapshot) {
    _undo.add(snapshot);
    _undoChars += snapshot.length;
    while (_undo.length > limit || (_undoChars > maxChars && _undo.length > 1)) {
      _undoChars -= _undo.removeAt(0).length;
    }
  }
}
