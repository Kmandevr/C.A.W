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
  /// A new effect from the one blank template (owner, 2026-11-09): a stereo pass-through that builds and plays as
  /// it is, with its manifest. [id] is the app-local entry id; the stable component id comes from [name].
  static CppComponentDoc blankEffect({required String id, required String name}) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final entry = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    final componentId = 'local.${slug.isEmpty ? 'effect' : slug}.$entry';
    final className = name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final type = className.isEmpty || RegExp(r'^[0-9]').hasMatch(className) ? 'Effect' : className;
    // Safe inside a C++ string literal and a // comment.
    final display = name.replaceAll(RegExp(r'[\x00-\x1f\\]'), '').replaceAll('"', "'");
    return CppComponentDoc(id: id, name: name, componentId: componentId, files: {
      'caw-component.json': '{\n  "format": "caw.component",\n  "version": 1,\n'
          '  "component": {"id": "$componentId", "name": ${_jsonString(name)}},\n'
          '  "sources": ["src/effect.cpp"]\n}\n',
      'src/effect.cpp': '''// $display: a stereo effect. It passes its input through; change process() to shape the sound.
#include <caw/component.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {caw::stereoInput("in"), caw::stereoOutput("out")};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "$componentId";
    d.ports = kPorts;
    d.portCount = 2;
    d.name = "$display";
    d.role = caw::ModuleRole::Effect;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

class $type final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }

    void process(const caw::StereoProcessBlock& block) noexcept override {
        for (uint32_t i = 0; i < block.frames; ++i) {
            block.outputLeft[i] = block.inputLeft[i];
            block.outputRight[i] = block.inputRight[i];
        }
    }
};

}  // namespace

CAW_EXPORT_COMPONENT($type, kDescriptor)
''',
    });
  }

  static String _jsonString(String s) {
    final b = StringBuffer('"');
    for (final c in s.runes) {
      if (c == 0x22 || c == 0x5c) {
        b.write('\\${String.fromCharCode(c)}');
      } else if (c < 0x20) {
        b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
      } else {
        b.writeCharCode(c);
      }
    }
    return (b..write('"')).toString();
  }

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
