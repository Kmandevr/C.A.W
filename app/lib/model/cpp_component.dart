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

  /// A new instrument: a polyphonic sine with a short attack and release, played by the track's notes, with its
  /// `caw-component.json`. It derives from `caw::InstrumentProcessor` (caw/instrument.hpp).
  static CppComponentDoc blankInstrument({required String id, required String name}) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final entry = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    final componentId = 'local.${slug.isEmpty ? 'instrument' : slug}.$entry';
    final className = name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final type = className.isEmpty || RegExp(r'^[0-9]').hasMatch(className) ? 'Instrument' : className;
    final display = name.replaceAll(RegExp(r'[\x00-\x1f\\]'), '').replaceAll('"', "'");
    return CppComponentDoc(id: id, name: name, componentId: componentId, files: {
      'caw-component.json': '{\n  "format": "caw.component",\n  "version": 1,\n'
          '  "component": {"id": "$componentId", "name": ${_jsonString(name)}},\n'
          '  "sources": ["src/instrument.cpp"]\n}\n',
      'src/instrument.cpp': '''// $display: an instrument. Each note plays a sine with a short attack and release; change render() to make your sound.
#include <cmath>

#include <caw/component.hpp>
#include <caw/instrument.hpp>

namespace {

// An instrument: notes in, stereo out.
constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor volume() {
    caw::ParameterDescriptor p;
    p.id = "volume";
    p.name = "Volume";
    p.defaultValue = 0.5;
    p.smoothingFrames = 480;  // a knob move glides over 10 ms
    return p;
}
const caw::ParameterDescriptor kParams[] = {volume()};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "$componentId";
    d.name = "$display";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 1;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

class $type final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        voices_.clear();
        return true;
    }
    void reset() noexcept override { voices_.clear(); }

protected:
    // A note on, off or pitch change, on its exact frame. m.noteId says which note.
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            Voice& v = voices_.start(m.noteId);
            v.velocity = m.velocity;
            v.step = 440.0 * std::pow(2.0, (m.pitch - 69.0) / 12.0) / rate_;
        } else if (Voice* v = voices_.find(m.noteId)) {
            if (m.type == caw::NoteMessageType::Off) v->held = false;
            if (m.type == caw::NoteMessageType::Pitch) v->step = 440.0 * std::pow(2.0, (m.pitch - 69.0) / 12.0) / rate_;
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        const double fade = 1.0 / (0.01 * rate_);  // 10 ms attack and release
        for (Voice& v : voices_) {
            for (uint32_t i = 0; i < frames && v.active; ++i) {
                v.level = v.held ? std::fmin(1.0, v.level + fade) : v.level - fade;
                if (v.level <= 0.0) { v.active = false; v.level = 0.0; break; }
                const double y = std::sin(6.283185307179586 * v.phase) * v.level * v.velocity *
                                 caw::parameterAt(b, 0, offset + i, 0.5) * 0.3;
                v.phase += v.step;
                v.phase -= std::floor(v.phase);
                left[i] += static_cast<float>(y);
                right[i] += static_cast<float>(y);
            }
        }
    }

private:
    struct Voice {
        bool active = false, held = false;
        uint32_t noteId = 0;
        uint64_t age = 0;
        double level = 0, velocity = 1, phase = 0, step = 0;
    };
    caw::VoicePool<Voice, 8> voices_;
    double rate_ = 48000;
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
