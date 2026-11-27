// AppState's patterns (Build): selecting, editing and running modules, and the library's folders, tags and searches.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of '../app_state.dart';

extension AppStateLibrary on AppState {
  // ---------- patterns (Build) ----------

  void selectModule(String id) {
    selectedModuleId = id;
    if (previewOnly) _sync();
    notifyListeners();
  }

  /// Selects a channel for shared workspace inspectors without changing its processing state.
  void selectLayer(LayerDoc layer) {
    selectedLayerId = layer.id;
    selectedClipId = null;
    selectedClipIds.clear();
    notifyListeners();
  }

  void editSource(String id, String source) {
    final m = project.module(id);
    if (m == null || m.source == source) return;
    final wasEdited = m.edited;
    m.source = source;
    // The text lives in the editor; the rest of the app only shows whether the module has unrun edits.
    if (m.edited != wasEdited) {
      _changed(engine: false);
    } else {
      _save();
    }
    _scheduleLive(id);
  }

  /// Auto-update: after the pause set in the settings, code that compiles swaps in by itself (at the swap timing).
  /// Code with an error waits for the next edit; light mode waits while playing, so swaps then happen on Run only.
  void _scheduleLive(String id) {
    _liveTimer?.cancel();
    if (!settings.liveUpdate || engine == null) return;
    _liveTimer = Timer(Duration(milliseconds: settings.liveDelayMs), () async {
      final m = project.module(id);
      if (_disposed || m == null || !m.edited || (settings.lightMode && meters.playing)) return;
      // The project compile is the check; avoid compiling the same source twice.
      await run(id);
    });
  }

  /// Run: hot-swap valid code; on failure keep the last good engine source and expose the module error.
  Future<ModuleInfo?> run(String id) async {
    final m = project.module(id);
    if (m == null || engine == null) return null;
    final source = m.source;
    final key = '${project.id}:$id';
    final lastGoodSource = _lastGoodRunSources[key] ?? m.runSource;
    m.runSource = source;
    _syncTimer?.cancel();
    await _syncNow();

    final result = info[id];
    final current = project.module(id);
    if (engineError == null && result?.ok == true) {
      _lastGoodRunSources[key] = source;
      if (current != null && current.source == source) {
        final name = headerValue(source, 'name');
        if (name != null && name.isNotEmpty) current.name = name;
      }
    } else if (current != null && current.runSource == source) {
      // Keep invalid editor text pending while the engine continues with the previous good source.
      current.runSource = lastGoodSource;
    }
    _save();
    notifyListeners();
    return result;
  }

  String _freeModuleName(String base) {
    var name = base;
    var n = 2;
    while (project.modules.any((x) => x.name == name)) {
      name = '$base ${n++}';
    }
    return name;
  }

  String addModule(PatternTemplate t) {
    final m = moduleFromPattern(t);
    m.name = _freeModuleName(m.name);
    project.modules.add(m);
    selectedModuleId = m.id;
    _changed();
    return m.id;
  }

  String _normalizeLibraryPath(String path) {
    if (path.length > 512) throw ArgumentError.value(path, 'path', 'Folder path is too long.');
    final parts = path.split('/').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
    if (parts.length > 32 || parts.any((part) => part == '.' || part == '..' || part.length > 64 || part.contains(String.fromCharCode(92)))) {
      throw ArgumentError.value(path, 'path', 'Folder paths cannot contain traversal segments.');
    }
    return parts.join('/');
  }

  /// Creates a user-named virtual library folder and any missing parents.
  bool createLibraryFolder(String path) {
    final normalized = _normalizeLibraryPath(path);
    if (normalized.isEmpty) return false;
    final parts = normalized.split('/');
    if (parts.asMap().entries.every((entry) => project.libraryFolders.contains(parts.take(entry.key + 1).join('/')))) {
      return false;
    }
    _recordLibraryUndo();
    var changed = false;
    for (var i = 1; i <= parts.length; i++) {
      final parent = parts.take(i).join('/');
      if (!project.libraryFolders.contains(parent)) {
        project.libraryFolders.add(parent);
        changed = true;
      }
    }
    if (changed) {
      project.libraryFolders.sort();
      _changed(engine: false);
    }
    return changed;
  }

  /// Renames a folder and all descendants without moving or deleting their modules.
  bool renameLibraryFolder(String oldPath, String newPath) {
    final oldValue = _normalizeLibraryPath(oldPath);
    final newValue = _normalizeLibraryPath(newPath);
    if (oldValue.isEmpty || newValue.isEmpty || !project.libraryFolders.contains(oldValue)) return false;
    if (oldValue == newValue) return true;
    if (newValue.startsWith('$oldValue/') || project.libraryFolders.contains(newValue)) return false;
    _recordLibraryUndo();
    project.libraryFolders = project.libraryFolders.map((path) =>
      path == oldValue ? newValue : path.startsWith('$oldValue/') ? '$newValue${path.substring(oldValue.length)}' : path
    ).toSet().toList();
    final newParts = newValue.split('/');
    for (var i = 1; i < newParts.length; i++) {
      final parentPath = newParts.take(i).join('/');
      if (!project.libraryFolders.contains(parentPath)) project.libraryFolders.add(parentPath);
    }
    project.libraryFolders.sort();
    for (final module in project.modules) {
      if (module.folderPath == oldValue) {
        module.folderPath = newValue;
      } else if (module.folderPath.startsWith('$oldValue/')) {
        module.folderPath = '$newValue${module.folderPath.substring(oldValue.length)}';
      }
    }
    _changed(engine: false);
    return true;
  }

  /// Deletes a folder node and returns its modules/children to its parent folder.
  bool deleteLibraryFolder(String path) {
    final normalized = _normalizeLibraryPath(path);
    if (normalized.isEmpty || !project.libraryFolders.contains(normalized)) return false;
    final parent = normalized.contains('/') ? normalized.substring(0, normalized.lastIndexOf('/')) : '';
    _recordLibraryUndo();
    project.libraryFolders.removeWhere((folder) => folder == normalized || folder.startsWith('$normalized/'));
    for (final module in project.modules) {
      if (module.folderPath == normalized || module.folderPath.startsWith('$normalized/')) {
        module.folderPath = parent;
      }
    }
    _changed(engine: false);
    return true;
  }

  /// Moves a module into a user-owned library folder; an empty path means the project root.
  bool moveModuleToFolder(String moduleId, String folderPath) {
    final module = project.module(moduleId);
    if (module == null) return false;
    final normalized = _normalizeLibraryPath(folderPath);
    if (normalized.isNotEmpty && !project.libraryFolders.contains(normalized)) return false;
    if (module.folderPath == normalized) return true;
    _recordLibraryUndo();
    module.folderPath = normalized;
    _changed(engine: false);
    return true;
  }

  bool moveModulesToFolder(Iterable<String> moduleIds, String folderPath) {
    final normalized = _normalizeLibraryPath(folderPath);
    if (normalized.isNotEmpty && !project.libraryFolders.contains(normalized)) return false;
    final ids = moduleIds.toSet();
    final targets = project.modules.where((module) => ids.contains(module.id) && module.folderPath != normalized).toList();
    if (targets.isEmpty) return false;
    _recordLibraryUndo();
    var changed = false;
    for (final module in project.modules) {
      if (ids.contains(module.id) && module.folderPath != normalized) {
        module.folderPath = normalized;
        changed = true;
      }
    }
    if (changed) _changed(engine: false);
    return changed;
  }

  void setModuleTags(String moduleId, List<String> tags) => setModulesTags([moduleId], tags);

  /// Applies one tag set to multiple modules as a single undoable library operation.
  bool setModulesTags(Iterable<String> moduleIds, List<String> tags) {
    final ids = moduleIds.toSet();
    final seen = <String>{};
    final nextTags = [
      for (final raw in tags)
        if (raw.trim().isNotEmpty && raw.trim().length <= 48 && seen.add(raw.trim().toLowerCase()))
          raw.trim(),
    ].take(16).toList();
    final targets = project.modules.where((module) => ids.contains(module.id) &&
        !listEquals(module.tags, nextTags)).toList();
    if (targets.isEmpty) return false;
    _recordLibraryUndo();
    for (final module in targets) {
      module.tags = List.of(nextTags);
    }
    _changed(engine: false);
    return true;
  }

  bool saveLibrarySearch(String name, String query) {
    final key = name.trim();
    final value = query.trim();
    if (key.isEmpty || value.isEmpty || key.length > 64 || value.length > 256) return false;
    if (!project.savedLibrarySearches.containsKey(key) && project.savedLibrarySearches.length >= 32) return false;
    if (project.savedLibrarySearches[key] == value) return true;
    _recordLibraryUndo();
    project.savedLibrarySearches[key] = value;
    _changed(engine: false);
    return true;
  }

  void deleteLibrarySearch(String name) {
    if (!project.savedLibrarySearches.containsKey(name)) return;
    _recordLibraryUndo();
    project.savedLibrarySearches.remove(name);
    _changed(engine: false);
  }

  void renameModule(String id, String name) {
    final m = project.module(id);
    if (m == null || name.trim().isEmpty) return;
    m.name = name.trim();
    _changed(engine: false);
  }

  void deleteModule(String id) {
    project.modules.removeWhere((m) => m.id == id);
    for (final l in project.layers) {
      if (l.patternId == id) l.patternId = null;
      l.clips.removeWhere((clip) => clip.patternId == id);
    }
    if (selectedModuleId == id) selectedModuleId = project.modules.isEmpty ? null : project.modules.first.id;
    _pruneClipSelection();
    _changed();
  }

  void setPreviewOnly(bool on) {
    previewOnly = on;
    _changed(engine: true);
  }

  /// Whether [moduleId] is one of the project's patterns (every module is, once a project has loaded; #160).
  bool isPattern(String moduleId) {
    final m = project.module(moduleId);
    return m != null && (isPatternSource(m.runSource) || isPatternSource(m.source));
  }
}
