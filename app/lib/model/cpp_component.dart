// Project-owned C++ component sources and pinned dependency metadata; paths stay relative to the project.
class CppComponentDoc {
  CppComponentDoc({
    required this.id,
    required this.name,
    required this.componentId,
    Map<String, String>? files,
    Map<String, String>? dependencies,
  })  : files = files ?? {},
        dependencies = dependencies ?? {};

  /// App-local identity for this component entry.
  final String id;

  /// Human-readable name shown in the project and Library.
  String name;

  /// Stable SDK descriptor ID exported by the compiled component.
  String componentId;

  /// Project-relative files, including CMakeLists.txt, caw.component, sources and headers.
  /// Content is kept with the project so autosave, restore points and handoff preserve it.
  final Map<String, String> files;

  /// Dependency name to exact pinned version; no floating versions are stored.
  final Map<String, String> dependencies;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'component_id': componentId,
        'files': files,
        'dependencies': dependencies,
      };

  static CppComponentDoc fromJson(Map<String, dynamic> json) => CppComponentDoc(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? 'C++ component',
        componentId: (json['component_id'] as String?) ?? '',
        files: {
          for (final entry in ((json['files'] as Map?) ?? const {}).entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        },
        dependencies: {
          for (final entry in ((json['dependencies'] as Map?) ?? const {}).entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        },
      );

  /// Rejects paths that could escape a component's project directory when materialized.
  static bool isSafeRelativePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path.contains(':')) {
      return false;
    }
    final parts = path.split('/');
    return parts.every((part) => part.isNotEmpty && part != '.' && part != '..');
  }
}
