// Everything a project depends on outside its own JSON (audio, samples, C++ builds, plug-ins, presets, the theme),
// what uses each and whether it is on this device; and relinking a moved or missing file (owner, 2026-11-11).
import 'dart:convert';
import 'dart:io';

import '../ui/theme.dart';
import 'cpp_component.dart';
import 'project.dart';
import 'sampler.dart';
import 'user_presets.dart';

/// What kind of file a dependency is. [source] and [impulse] live inside the project JSON, so they always travel.
enum DependencyKind { audio, sample, impulse, source, binary, plugin, preset, theme }

/// One dependency, as the export checklist and the missing-file banner show it.
class ProjectDependency {
  ProjectDependency({
    required this.key,
    required this.kind,
    required this.name,
    this.path,
    List<String>? usedBy,
    this.size = 0,
    this.found = false,
    this.embedded = false,
    this.componentId,
    this.presetId,
    this.outside = false,
  }) : usedBy = usedBy ?? [];

  /// Unique within one scan (`audio:<path>`, `source:<component>`...).
  final String key;
  final DependencyKind kind;
  final String name;

  /// The file on this device (null: none, such as a plug-in or something inside the project JSON).
  final String? path;

  /// The tracks (or Master, a modulator) that use it.
  final List<String> usedBy;
  int size;
  bool found;

  /// Carried inside the project JSON (C++ sources, a convolver's impulse): always included, never a separate file.
  final bool embedded;
  final String? componentId, presetId;

  /// A reference to a file outside this project's own folders (another project, the app's settings, anywhere the
  /// project names): never read, hashed or packaged.
  final bool outside;

  /// Whether the export can put it in the package: a file found here. Plug-ins have an unknown licence, so they
  /// are listed as needed and never packaged (no plug-in hosting is built either).
  bool get packageable => found && !embedded && !outside && kind != DependencyKind.plugin;

  /// A file the project plays that is not on this device: the banner offers Locate… and Replace….
  bool get isMissingFile =>
      !found && !outside && path != null && (kind == DependencyKind.audio || kind == DependencyKind.sample);
}

/// A plain local absolute path, safe to look at: `/…` or `C:\…`, without `.`/`..` parts, control characters or a
/// second colon. Refused: UNC and device paths (`\\host\share`, `//host`, `\\?\`, `\\.\`; on Windows looking at
/// one sends the user's credentials to that host), URLs and other schemes, and relative paths. A project's paths
/// are untrusted: every file-system call on one goes through this first.
bool isSafeLocalPath(String path) {
  if (path.isEmpty || path.length > 4096) return false;
  for (final c in path.codeUnits) {
    if (c < 0x20 || c == 0x7f) return false;
  }
  final s = path.replaceAll('\\', '/');
  if (s.startsWith('//')) return false;
  final drive = RegExp(r'^[A-Za-z]:/').hasMatch(s);
  if (!drive && !s.startsWith('/')) return false;
  if (s.substring(drive ? 2 : 0).contains(':')) return false;
  for (final part in s.split('/')) {
    if (part == '.' || part == '..') return false;
  }
  return true;
}

/// Replaces every path in [p] that [isSafeLocalPath] refuses with one in [missingDir] of the same file name, so it
/// shows as missing (Locate… finds it by name) and nothing ever looks at the original. [moved] hears each change.
/// Returns how many paths moved.
int quarantineUnsafePaths(ProjectDoc p, String missingDir, {void Function(String from, String to)? moved}) {
  final unsafe = <String>{};
  for (final a in p.assets) {
    if (!isSafeLocalPath(a.path)) unsafe.add(a.path);
  }
  for (final (_, use) in projectComponentUses(p)) {
    for (final s in use.samples) {
      if (s.path case final path? when !isSafeLocalPath(path)) unsafe.add(path);
    }
    if (use.id == samplerComponentId) {
      for (final z in SamplerState.fromBase64(use.state).zones) {
        if (!isSafeLocalPath(z.path)) unsafe.add(z.path);
      }
    }
  }
  final taken = <String>{};
  for (final from in unsafe) {
    var name = _baseName(from).replaceAll(RegExp(r'[^A-Za-z0-9 ._()+#-]'), '_');
    if (name.isEmpty || name.startsWith('.')) name = 'file$name';
    var to = '$missingDir${Platform.pathSeparator}$name';
    for (var n = 2; !taken.add(to.toLowerCase()); n++) {
      to = '$missingDir${Platform.pathSeparator}${name.replaceFirst(RegExp(r'(\.[^.]*)?$'), ' $n\$1')}';
    }
    relinkProjectPath(p, from, to);
    moved?.call(from, to);
  }
  return unsafe.length;
}

/// Whether [path] is inside one of [roots] (folders; compared without case where the system ignores it).
bool isInsideFolders(String path, List<String> roots) {
  if (!isSafeLocalPath(path)) return false;
  final fold = Platform.pathSeparator == '\\';
  String norm(String x) {
    final n = x.replaceAll('\\', '/');
    return fold ? n.toLowerCase() : n;
  }
  final p = norm(path);
  for (final r in roots) {
    final root = norm(r).endsWith('/') ? norm(r) : '${norm(r)}/';
    if (p.startsWith(root)) return true;
  }
  return false;
}

/// The ids of the built-in convolver (its impulse response is the component's saved state) and the sampler.
const convolverComponentId = 'org.caw.convolver';

/// Every component entry in [p], with who uses it: each track's instrument, per-note and insert effects, then the
/// master's.
Iterable<(String owner, ComponentUseDoc use)> projectComponentUses(ProjectDoc p) sync* {
  for (final l in p.layers) {
    if (l.instrument case final i?) yield (l.name, i);
    for (final c in l.noteComponents) {
      yield (l.name, c);
    }
    for (final c in l.components) {
      yield (l.name, c);
    }
  }
  for (final c in p.masterComponents) {
    yield ('Master', c);
  }
}

/// Every component id [p] uses (component entries and modulators), each with its users in order.
Map<String, List<String>> projectComponentUsers(ProjectDoc p) {
  final users = <String, List<String>>{};
  void add(String id, String owner) {
    final list = users.putIfAbsent(id, () => []);
    if (!list.contains(owner)) list.add(owner);
  }
  for (final (owner, use) in projectComponentUses(p)) {
    add(use.id, owner);
  }
  for (final m in p.modulators) {
    add(m.componentId, m.name);
  }
  return users;
}

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

int _fileSize(String path) {
  if (!isSafeLocalPath(path)) return -1;
  try {
    final f = File(path);
    return f.existsSync() ? f.lengthSync() : -1;
  } catch (_) {
    return -1;
  }
}

/// Lists [p]'s dependencies. [builtBinary] names the built library of a C++ component on this device (null: none);
/// [presets] are the user's presets (those for a device the project uses are offered); [theme] is the theme in
/// force when it is the user's own (a starter theme ships with the app); [isKnownComponent] says an id is one the
/// engine has (a built-in), so it is not taken for a plug-in. [isProjectFile] says a file belongs to the project
/// (its audio folder, the user's own picks); any other is listed as outside it, never looked at or packaged.
List<ProjectDependency> scanProjectDependencies(
  ProjectDoc p, {
  bool Function(String path)? isProjectFile,
  String? Function(CppComponentDoc component)? builtBinary,
  List<UserPreset> presets = const [],
  CawTheme? theme,
  bool Function(String id)? isKnownComponent,
}) {
  final out = <String, ProjectDependency>{};
  ProjectDependency file(DependencyKind kind, String path, String owner, {String? name}) {
    final key = 'file:$path';
    final dep = out.putIfAbsent(key, () {
      if (isProjectFile != null && !isProjectFile(path)) {
        return ProjectDependency(key: key, kind: kind, name: name ?? _baseName(path), path: path, outside: true);
      }
      final size = _fileSize(path);
      return ProjectDependency(key: key, kind: kind, name: name ?? _baseName(path), path: path,
          size: size < 0 ? 0 : size, found: size >= 0);
    });
    if (owner.isNotEmpty && !dep.usedBy.contains(owner)) dep.usedBy.add(owner);
    return dep;
  }

  // Audio files: each asset, used by the clips (and takes) that name it.
  for (final a in p.assets) {
    final users = [
      for (final l in p.layers)
        if (l.audioClips.any((c) => c.assetId == a.id || c.takes.contains(a.id))) l.name,
    ];
    final dep = file(DependencyKind.audio, a.path, '', name: _baseName(a.path));
    for (final u in users) {
      if (!dep.usedBy.contains(u)) dep.usedBy.add(u);
    }
    if (users.isEmpty && !dep.usedBy.contains('Files')) dep.usedBy.add('Files');
  }
  // Samples: the sampler's zones and every component's sample slots (the drums' pads); a convolver's impulse.
  for (final (owner, use) in projectComponentUses(p)) {
    if (use.id == samplerComponentId) {
      for (final z in SamplerState.fromBase64(use.state).zones) {
        file(DependencyKind.sample, z.path, owner);
      }
    }
    for (final s in use.samples) {
      if (s.path case final path?) file(DependencyKind.sample, path, owner);
    }
    if (use.id == convolverComponentId && use.state != null && use.state!.isNotEmpty) {
      final key = 'impulse:$owner:${out.length}';
      out[key] = ProjectDependency(key: key, kind: DependencyKind.impulse, name: 'Impulse response', usedBy: [owner],
          size: use.state!.length * 3 ~/ 4, found: true, embedded: true);
    }
  }
  // C++ components: the source (always in the project), and this device's build when there is one.
  final users = projectComponentUsers(p);
  final cppIds = <String>{};
  for (final c in p.cppComponents) {
    cppIds.add(c.componentId);
    var size = 0;
    for (final text in c.files.values) {
      size += utf8.encode(text).length;
    }
    out['source:${c.id}'] = ProjectDependency(key: 'source:${c.id}', kind: DependencyKind.source,
        name: '${c.name} (C++ source)', usedBy: [...?users[c.componentId]], size: size, found: true, embedded: true,
        componentId: c.componentId);
    final built = builtBinary?.call(c);
    if (built != null) {
      final n = _fileSize(built);
      if (n >= 0) {
        out['binary:${c.id}'] = ProjectDependency(key: 'binary:${c.id}', kind: DependencyKind.binary,
            name: '${c.name} (built for this device)', path: built, usedBy: [...?users[c.componentId]], size: n,
            found: true, componentId: c.componentId);
      }
    }
  }
  // Plug-ins: an id that is neither a built-in nor one of the project's C++ components.
  for (final e in users.entries) {
    final id = e.key;
    if (id.startsWith('org.caw.') || cppIds.contains(id) || (isKnownComponent?.call(id) ?? false)) continue;
    out['plugin:$id'] = ProjectDependency(key: 'plugin:$id', kind: DependencyKind.plugin, name: id,
        usedBy: e.value, componentId: id);
  }
  // The user's presets for the devices the project uses.
  for (final preset in presets) {
    final ids = preset.kind == UserPresetKind.device
        ? [preset.componentId]
        : [preset.instrument?.componentId, for (final e in preset.effects) e.componentId];
    final owners = <String>[
      for (final id in ids)
        if (id != null) ...?users[id],
    ];
    if (owners.isEmpty) continue;
    out['preset:${preset.id}'] = ProjectDependency(key: 'preset:${preset.id}', kind: DependencyKind.preset,
        name: preset.name, usedBy: owners.toSet().toList(), size: utf8.encode(preset.encode()).length, found: true,
        presetId: preset.id);
  }
  if (theme != null) {
    out['theme'] = ProjectDependency(key: 'theme', kind: DependencyKind.theme, name: '${theme.name} (theme)',
        usedBy: ['The app'], size: utf8.encode(theme.toFile()).length, found: true);
  }
  return out.values.toList();
}

/// The files [p] plays that are not on this device (audio, sampler zones, drum pads), checked off the UI thread's
/// way (each stat awaited).
Future<List<ProjectDependency>> findMissingFiles(ProjectDoc p) async {
  final paths = <String, (DependencyKind, List<String>)>{};
  void add(String path, DependencyKind kind, String owner) {
    final entry = paths.putIfAbsent(path, () => (kind, <String>[]));
    if (owner.isNotEmpty && !entry.$2.contains(owner)) entry.$2.add(owner);
  }
  for (final a in p.assets) {
    add(a.path, DependencyKind.audio, '');
    for (final l in p.layers) {
      if (l.audioClips.any((c) => c.assetId == a.id || c.takes.contains(a.id))) add(a.path, DependencyKind.audio, l.name);
    }
  }
  for (final (owner, use) in projectComponentUses(p)) {
    if (use.id == samplerComponentId) {
      for (final z in SamplerState.fromBase64(use.state).zones) {
        add(z.path, DependencyKind.sample, owner);
      }
    }
    for (final s in use.samples) {
      if (s.path case final path?) add(path, DependencyKind.sample, owner);
    }
  }
  final missing = <ProjectDependency>[];
  for (final e in paths.entries) {
    var there = false;
    if (isSafeLocalPath(e.key)) {
      try {
        there = await File(e.key).exists();
      } catch (_) {}
    }
    if (!there) {
      missing.add(ProjectDependency(key: 'file:${e.key}', kind: e.value.$1, name: _baseName(e.key), path: e.key,
          usedBy: e.value.$2));
    }
  }
  return missing;
}

/// Points every reference in [p] to the file [from] at [to] instead: audio assets, sample slots and sampler zones.
/// Returns how many references moved.
int relinkProjectPath(ProjectDoc p, String from, String to) {
  var moved = 0;
  for (final a in p.assets) {
    if (a.path == from) {
      a.path = to;
      moved++;
    }
  }
  for (final (_, use) in projectComponentUses(p)) {
    if (use.samples.any((s) => s.path == from)) {
      use.samples = [
        for (final s in use.samples) s.path == from ? ComponentSampleDoc(s.slot, path: to) : s,
      ];
      moved++;
    }
    if (use.id == samplerComponentId) {
      final zones = SamplerState.fromBase64(use.state);
      var changed = false;
      for (final z in zones.zones) {
        if (z.path == from) {
          z.path = to;
          changed = true;
          moved++;
        }
      }
      if (changed) use.state = zones.toBase64();
    }
  }
  return moved;
}
