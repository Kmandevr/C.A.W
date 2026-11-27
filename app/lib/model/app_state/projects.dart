// AppState's undo and projects: history, library and automation undo, restore points, and opening, switching and trashing projects.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of '../app_state.dart';

class _LibrarySnapshot {
  _LibrarySnapshot(ProjectDoc project)
      : folders = List.of(project.libraryFolders),
        searches = Map.of(project.savedLibrarySearches),
        moduleFolders = {for (final module in project.modules) module.id: module.folderPath},
        moduleTags = {for (final module in project.modules) module.id: List.of(module.tags)};

  final List<String> folders;
  final Map<String, String> searches;
  final Map<String, String> moduleFolders;
  final Map<String, List<String>> moduleTags;
}

class _AutomationSnapshot {
  _AutomationSnapshot(ProjectDoc project)
      : projectLanes = [for (final lane in project.automation)
          ProjectAutomationLaneDoc.fromJson(lane.toJson())],
        trackLanes = {for (final layer in project.layers) layer.id: [
          for (final lane in layer.automation) AutomationLaneDoc.fromJson(lane.toJson()),
        ]},
        clipLanes = {for (final layer in project.layers) for (final clip in layer.clips) clip.id: [
          for (final lane in clip.automation) lane.copy(),
        ]};

  final List<ProjectAutomationLaneDoc> projectLanes;
  final Map<String, List<AutomationLaneDoc>> trackLanes;
  final Map<String, List<ClipAutomationLaneDoc>> clipLanes;
}

extension AppStateProjects on AppState {
  bool get canUndoLibrary => _libraryUndo.isNotEmpty;

  bool get canRedoLibrary => _libraryRedo.isNotEmpty;

  void _recordLibraryUndo() {
    _libraryUndo.add(_LibrarySnapshot(project));
    if (_libraryUndo.length > 50) _libraryUndo.removeAt(0);
    _libraryRedo.clear();
  }

  void _restoreLibrarySnapshot(_LibrarySnapshot snapshot) {
    project.libraryFolders = List.of(snapshot.folders);
    project.savedLibrarySearches = Map.of(snapshot.searches);
    for (final module in project.modules) {
      final folder = snapshot.moduleFolders[module.id];
      if (folder != null) module.folderPath = folder;
      final tags = snapshot.moduleTags[module.id];
      if (tags != null) module.tags = List.of(tags);
    }
  }

  bool undoLibraryOperation() {
    if (_libraryUndo.isEmpty) return false;
    _libraryRedo.add(_LibrarySnapshot(project));
    _restoreLibrarySnapshot(_libraryUndo.removeLast());
    _changed(engine: false);
    return true;
  }

  bool redoLibraryOperation() {
    if (_libraryRedo.isEmpty) return false;
    _libraryUndo.add(_LibrarySnapshot(project));
    _restoreLibrarySnapshot(_libraryRedo.removeLast());
    _changed(engine: false);
    return true;
  }
  String _snapshot({bool reuse = false}) {
    final c = _encoded;
    if (reuse && c != null && c.gen == _docGen && identical(c.project, project)) return c.text;
    final text = jsonEncode(project.toJson());
    _encoded = (gen: _docGen, project: project, text: text);
    return text;
  }

  void _recordHistory() {
    if (starting || _restoring) return;
    EasterEggs.instance.streakBroken();
    final could = (history.canUndo, history.canRedo);
    history.begin();
    // Drags save without notifying (so they stay light); the transport's buttons still need to see a flip.
    if ((history.canUndo, history.canRedo) != could) notifyListeners();
    _historyTimer?.cancel();
    if (_historyHeld) return; // a take of automation writing: it settles when the take ends
    _historyTimer = Timer(const Duration(milliseconds: 600), () {
      final was = (history.canUndo, history.canRedo);
      history.settle(_snapshot(reuse: true));
      if ((history.canUndo, history.canRedo) != was) notifyListeners();
    });
  }

  bool get canUndo => history.canUndo;
  bool get canRedo => history.canRedo;

  bool get _historyHeld => _historyHolds > 0;

  /// Goes back one step of project edits (the transport's undo, Ctrl+Z outside an editor with its own).
  bool undo() {
    final done = _restore(history.undo(_snapshot()));
    if (done) EasterEggs.instance.undone();
    return done;
  }

  bool redo() {
    EasterEggs.instance.streakBroken();
    return _restore(history.redo(_snapshot()));
  }

  bool _restore(String? snapshot) {
    _historyTimer?.cancel();
    if (snapshot == null) return false;
    _restoring = true;
    try {
      // The project's own stats (time spent, the last export) are not edits: an undo keeps them.
      final spent = project.timeSpentSeconds, exported = project.lastExport;
      project = ProjectDoc.fromJson(jsonDecode(snapshot) as Map<String, dynamic>)
        ..timeSpentSeconds = spent
        ..lastExport = exported;
      // The other undo stacks and the last good Run sources describe the project before the restore.
      _lastGoodRunSources.clear();
      _libraryUndo.clear();
      _libraryRedo.clear();
      _automationUndo.clear();
      _automationRedo.clear();
      masterValueTick.value++;
      // Ticks of modules and layers the restore removed are dropped (left to their widgets, which go with them).
      _moduleValueTicks.removeWhere((id, _) => project.module(id) == null);
      _layerValueTicks.removeWhere((id, _) => id != masterLayerId && project.layers.every((l) => l.id != id));
      for (final n in _moduleValueTicks.values) { n.value++; }
      for (final n in _layerValueTicks.values) { n.value++; }
      timeSelectionStart = timeSelectionEnd = timeSelectionAnchor = null;
      previewOnly = false;
      if (project.layers.every((l) => l.id != selectedLayerId)) selectedLayerId = null;
      if (project.module(selectedModuleId) == null) {
        selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
      }
      selectedClipId = null;
      selectedClipIds.clear();
      _changed();
    } finally {
      _restoring = false;
    }
    return true;
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    if (starting) return; // the placeholder before the first project opens is never saved
    // Native effects' running state (save_state) goes into the project, so a reload or an export starts from it.
    final e = engine;
    if (e != null) {
      project.storeComponentStates(e.componentStates);
      _docGen++;
    }
    _foldTimeSpent();
    final storage = _storage;
    if (storage != null) await storage.save(project, json: _snapshot());
  }

  /// Adds the time counted since the last save to the project (whole seconds; the rest keeps counting).
  void _foldTimeSpent() {
    final whole = _spent.elapsed.inSeconds;
    if (whole <= 0) return;
    project.timeSpentSeconds += whole;
    _spent.reset();
    _docGen++;
  }

  /// An export of project [projectId] finished: the card in Files shows it as the last export.
  void noteExported(String projectId, {DateTime? at}) {
    if (project.id != projectId) return;
    project.lastExport = (at ?? DateTime.now()).toUtc();
    _docGen++;
    _save();
  }

  Future<bool> createRestorePoint() async {
    final storage = _storage;
    if (storage == null || starting) return false;
    await flush();
    await storage.createRestorePoint(project, keep: settings.restorePointsKept);
    return true;
  }

  Future<List<RestorePointSummary>> listRestorePoints() async =>
      await _storage?.listRestorePoints(project.id) ?? const [];

  /// A restore point of every saved project, the open one saved first (before installing an older C.A.W). Returns
  /// how many were made. They live in the app's own storage: an Android uninstall deletes them too.
  Future<int> backUpAllProjects() async {
    final storage = _storage;
    if (storage == null) return 0;
    await flush();
    var made = 0;
    for (final summary in await listProjects()) {
      try {
        final doc = await storage.load(summary.id);
        if (doc == null) continue;
        await storage.createRestorePoint(doc, keep: settings.restorePointsKept);
        made++;
      } catch (_) {
        // A project this version can't read (damaged, or from a newer version) is left as it is.
      }
    }
    return made;
  }

  Future<bool> restoreProjectVersion(String restorePointId) async {
    final storage = _storage;
    if (storage == null || starting) return false;
    final snapshot = await storage.loadRestorePoint(project.id, restorePointId);
    if (snapshot == null) return false;
    await storage.createRestorePoint(project, keep: settings.restorePointsKept);
    await _switchTo(snapshot);
    return true;
  }


  void _changed({bool engine = true}) {
    if (engine) _sync();
    _save();
    notifyListeners();
  }

  void beginAutomationGesture() {
    if (_automationGestureOpen) return;
    _pushAutomationUndo();
    _automationGestureOpen = true;
  }

  void endAutomationGesture() => _automationGestureOpen = false;

  void _pushAutomationUndo() {
    if (_automationGestureOpen) return;
    _automationUndo.add(_AutomationSnapshot(project));
    if (_automationUndo.length > 64) _automationUndo.removeAt(0);
    _automationRedo.clear();
  }

  void _restoreAutomationSnapshot(_AutomationSnapshot snapshot) {
    project.automation = snapshot.projectLanes;
    for (final layer in project.layers) {
      layer.automation = snapshot.trackLanes[layer.id] ?? [];
      for (final clip in layer.clips) {
        if (snapshot.clipLanes[clip.id] case final lanes?) clip.automation = [for (final lane in lanes) lane.copy()];
      }
    }
  }

  bool get canUndoAutomation => _automationUndo.isNotEmpty;
  bool get canRedoAutomation => _automationRedo.isNotEmpty;

  bool undoAutomation() {
    if (_automationUndo.isEmpty) return false;
    _automationRedo.add(_AutomationSnapshot(project));
    _restoreAutomationSnapshot(_automationUndo.removeLast());
    _changed();
    return true;
  }

  bool redoAutomation() {
    if (_automationRedo.isEmpty) return false;
    _automationUndo.add(_AutomationSnapshot(project));
    _restoreAutomationSnapshot(_automationRedo.removeLast());
    _changed();
    return true;
  }

  /// Saves the music video's setup and shots ([ProjectDoc.musicVideo]) with the project; nothing the engine plays.
  void setMusicVideo(Map<String, dynamic> json) {
    project.musicVideo = json;
    _changed(engine: false);
  }

  Future<List<ProjectSummary>> listProjects() async => await _storage?.list() ?? const [];

  /// Looks for the open project's files on this device again ([missingFiles]).
  Future<void> checkMissingFiles() async {
    final opened = project;
    final missing = await findMissingFiles(opened);
    if (!identical(project, opened) || _disposed) return;
    final before = missingFiles.map((m) => m.key).join('|');
    missingFiles = missing;
    if (missing.map((m) => m.key).join('|') != before) notifyListeners();
  }

  /// Builds (or reuses a build of) and loads the project's C++ effects under the trust rules, then sends the
  /// project again so they play. Runs after the project opens, so the rest of it plays at once. Code from elsewhere
  /// waits in [nativeStatus.needsTrust] for the user's Trust or Block.
  Future<void> prepareNativeComponents() async {
    final manager = nativeComponents;
    if (manager == null || project.cppComponents.isEmpty) return;
    final opened = project;
    final status = await manager.prepare(opened);
    if (!identical(project, opened) || _disposed) return;  // another project opened meanwhile
    nativeStatus = status;
    notifyListeners();
    if (status.loaded.isNotEmpty) await _syncNow();
  }

  /// New project: the template Settings › Projects and export names, else blank (with its tempo and meter).
  Future<void> newProject() async => _switchTo(await _named(newProjectDoc()));

  /// New project from template [t] (the project menu's New from template).
  Future<void> newProjectFromTemplate(TemplateDoc t) async => _switchTo(await _named(projectFromTemplate(t)));

  /// [p] with a generated name ("Low Roost") unless Settings › Projects and export turned them off; never a name a
  /// saved project has.
  Future<ProjectDoc> _named(ProjectDoc p) async {
    if (!settings.generatedProjectNames) return p;
    final taken = [for (final s in await listProjects()) s.name, project.name];
    return p..name = generateProjectName(taken);
  }

  Future<void> openProject(String id) async {
    final ProjectDoc? p;
    try {
      p = await _storage?.load(id);
    } on NewerProjectFormat catch (e) {
      openError = e.toString();
      notifyListeners();
      return;
    }
    if (p != null) await _switchTo(p);
  }

  /// Imports a portable project as a new project ID ([id], else a fresh one) so it cannot overwrite an existing saved
  /// project. [prepare] sees the copy before it opens (a package relinks its unpacked files there).
  Future<void> importProject(ProjectDoc imported, {String? id, void Function(ProjectDoc copy)? prepare}) {
    final copy = ProjectDoc.fromJson(imported.toJson()..['id'] = id ?? newId('p'))..droppedModules = imported.droppedModules;
    prepare?.call(copy);
    return _switchTo(copy);
  }

  Future<void> duplicateProject() async {
    final copy = ProjectDoc.fromJson(project.toJson()..['id'] = newId('p'))..created = null;
    copy.name = '${project.name} copy';
    await _switchTo(copy);
  }

  Future<void> deleteProject(String id) async {
    if (id == project.id) _saveTimer?.cancel();
    await _storage?.delete(id);
    if (id == project.id) await _leaveGoneProject();
  }

  /// After the open project was deleted: the newest other one opens (or the default project), and the deleted one
  /// is not saved again on the way out. A newest one in a newer format is left alone; the default opens instead.
  Future<void> _leaveGoneProject() async {
    final rest = await listProjects();
    ProjectDoc? next;
    try {
      next = rest.isEmpty ? null : await _storage?.load(rest.first.id);
    } on NewerProjectFormat {
      next = null;
    }
    await _switchTo(next ?? starterProject(), saveCurrent: false);
  }

  /// Files › Projects' Delete: moves projects [ids] to the library's trash (undoable with [restoreProjects] until the
  /// batch is purged). The open project is saved first and then left as [deleteProject] leaves it.
  Future<TrashBatch?> trashProjects(List<String> ids) async {
    final storage = _storage;
    if (storage == null || ids.isEmpty) return null;
    final open = ids.contains(project.id);
    if (open) {
      await flush();
      _saveTimer?.cancel();
    }
    final batch = await storage.library.trash(ids);
    if (open) await _leaveGoneProject();
    savedProjects = await listProjects();
    notifyListeners();
    return batch;
  }

  /// Undo of [trashProjects]: the projects come back (into their folders); the open project stays open.
  Future<int> restoreProjects(TrashBatch batch) async {
    final n = await _storage?.library.restore(batch) ?? 0;
    savedProjects = await listProjects();
    notifyListeners();
    return n;
  }
}
