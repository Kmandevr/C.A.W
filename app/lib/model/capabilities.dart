// A C++ component's declared capabilities: the fixed ids, the manifest's rules (as CMake and the engine check them), the canonical bytes a build embeds, and the manifest edit the "Needs" form makes.
import 'dart:convert';

/// The capability ids, in the scan's order (docs/native-module-sdk.md "Declaring capabilities").
const capabilityIds = [
  'internet',
  'read_files',
  'write_files',
  'start_programs',
  'load_code',
  'make_code',
  'android_system',
  'background_threads',
  'encryption',
  'input_spying',
  'packed',
];

/// One entry of `caw-component.json`'s "capabilities": what the component needs and its author's reason.
class CapabilityDeclaration {
  const CapabilityDeclaration(this.id, this.reason, [this.sites = const []]);

  final String id;
  final String reason;

  /// Only for `internet`: the host names it talks to (1 to 8), or empty.
  final List<String> sites;

  Map<String, Object> toJson() => {'id': id, 'reason': reason, if (sites.isNotEmpty) 'sites': sites};

  @override
  bool operator ==(Object other) =>
      other is CapabilityDeclaration && other.id == id && other.reason == reason && _sameList(other.sites, sites);

  @override
  int get hashCode => Object.hash(id, reason, Object.hashAll(sites));
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The rules, as `caw_add_component` (engine/cmake/CAWComponent.cmake) and the engine's scan
/// (engine/src/scan/declarations.cpp) apply them, and the one canonical form both builds write.
abstract final class Capabilities {
  static const maxEntries = 16;
  static const maxSites = 8;
  static const maxReasonChars = 200;
  static const maxCanonicalBytes = 16383;

  /// Why [reason] can't be used, or null: 1 to 200 characters (Unicode code points), no control characters
  /// (C0, DEL, C1) and no unpaired surrogate (it must be valid UTF-8 once written).
  static String? reasonProblem(String reason) {
    var chars = 0;
    for (final cp in reason.runes) {
      if (cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp <= 0x9F)) return 'no line breaks or control characters';
      if (cp >= 0xD800 && cp <= 0xDFFF) return 'a character that can\'t be written';
      chars++;
    }
    if (chars < 1) return 'say why it needs this';
    if (chars > maxReasonChars) return 'at most $maxReasonChars characters';
    return null;
  }

  /// A lowercase DNS name: labels of a-z, 0-9 and '-' (not first or last, at most 63), joined by single dots;
  /// at most 253 characters.
  static bool validHost(String h) {
    if (h.isEmpty || h.length > 253) return false;
    var label = 0;
    for (var i = 0; i < h.length; i++) {
      final c = h.codeUnitAt(i);
      if (c == 0x2E) {
        if (label == 0 || h.codeUnitAt(i - 1) == 0x2D) return false;
        label = 0;
        continue;
      }
      final ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || (c == 0x2D && label > 0);
      if (!ok || ++label > 63) return false;
    }
    return label > 0 && h.codeUnitAt(h.length - 1) != 0x2D;
  }

  /// The manifest's "capabilities" value ([present] false when the key is missing: nothing declared).
  /// Throws [FormatException] for anything the CMake build refuses.
  static List<CapabilityDeclaration> parse(Object? value, {bool present = true}) {
    if (!present) return const [];
    if (value is! List) throw const FormatException('caw-component.json: "capabilities" must be a list');
    if (value.length > maxEntries) {
      throw const FormatException('caw-component.json: a component declares at most $maxEntries capabilities');
    }
    final seen = <String>{};
    final out = <CapabilityDeclaration>[];
    for (final (i, entry) in value.indexed) {
      if (entry is! Map) throw FormatException('caw-component.json: capability $i is not an object');
      for (final key in entry.keys) {
        if (key != 'id' && key != 'reason' && key != 'sites') {
          throw FormatException('caw-component.json: capability $i has the unknown key "$key"');
        }
      }
      final id = entry['id'];
      if (id is! String || !capabilityIds.contains(id)) {
        throw FormatException('caw-component.json: capability $i has a missing or unknown id '
            '(one of: ${capabilityIds.join(', ')})');
      }
      if (!seen.add(id)) throw FormatException('caw-component.json: the capability $id is declared twice');
      final reason = entry['reason'];
      if (reason is! String || reasonProblem(reason) != null) {
        throw FormatException('caw-component.json: the capability $id needs a reason of 1 to $maxReasonChars '
            'characters with no control characters');
      }
      var sites = const <String>[];
      if (entry.containsKey('sites')) {
        final list = entry['sites'];
        if (id != 'internet' || list is! List || list.isEmpty || list.length > maxSites) {
          throw const FormatException('caw-component.json: only internet lists sites, 1 to $maxSites host names');
        }
        for (final s in list) {
          if (s is! String || !validHost(s)) {
            throw FormatException('caw-component.json: the site "$s" is not a lowercase host name');
          }
        }
        sites = List.unmodifiable(list.cast<String>());
      }
      out.add(CapabilityDeclaration(id, reason, sites));
    }
    if (canonicalBytes(out).length > maxCanonicalBytes) {
      throw const FormatException('caw-component.json: the capability declarations are larger than 16 KiB');
    }
    return List.unmodifiable(out);
  }

  /// The capabilities a manifest text declares (FormatException when it isn't a manifest or they are invalid).
  static List<CapabilityDeclaration> ofManifest(String text) {
    final j = jsonDecode(text);
    if (j is! Map) throw const FormatException('caw-component.json is not a JSON object');
    return parse(j['capabilities'], present: j.containsKey('capabilities'));
  }

  static String _escape(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  /// The canonical declaration JSON: no whitespace; only `"` and `\` escaped; everything else as is.
  static String canonical(List<CapabilityDeclaration> list) {
    final b = StringBuffer('{"format":"caw.capabilities","version":1,"capabilities":[');
    for (final (i, d) in list.indexed) {
      if (i > 0) b.write(',');
      b.write('{"id":"${d.id}","reason":"${_escape(d.reason)}"');
      if (d.sites.isNotEmpty) b.write(',"sites":[${d.sites.map((s) => '"${_escape(s)}"').join(',')}]');
      b.write('}');
    }
    b.write(']}');
    return b.toString();
  }

  /// [canonical] as the UTF-8 bytes the section holds (before its one NUL).
  static List<int> canonicalBytes(List<CapabilityDeclaration> list) => utf8.encode(canonical(list));

  /// CMake's `string(MAKE_C_IDENTIFIER "caw_component_<id>")`: the default target name of a component.
  static String targetName(String componentId) {
    final s = 'caw_component_$componentId'.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return RegExp(r'^[0-9]').hasMatch(s) ? '_$s' : s;
  }

  /// The `<target>_capabilities.cpp` source `caw_add_component` generates: the bytes and one NUL in the section
  /// `caw_caps` (ELF) or `.cawcap` (PE), kept by `used` and, where the compiler has it, `retain`.
  static String generatedSource(List<CapabilityDeclaration> list, {String from = 'caw-component.json'}) {
    final bytes = canonicalBytes(list).map((b) => '0x${b.toRadixString(16).padLeft(2, '0')},').join();
    final array = '{${bytes}0}';
    return '// Generated by the in-app build from $from: the component\'s capability declarations, read by the '
        'engine\'s pre-load scan before the library is loaded.\n'
        '#if defined(_MSC_VER)\n'
        '#pragma section(".cawcap", read)\n'
        'extern "C" __declspec(allocate(".cawcap")) const unsigned char caw_component_capabilities[] = $array;\n'
        '#elif defined(_WIN32)\n'
        '__attribute__((used, section(".cawcap"))) static const unsigned char caw_component_capabilities[] = $array;\n'
        '#elif !defined(__APPLE__)\n'
        '#if defined(__has_attribute)\n'
        '#if __has_attribute(retain)\n'
        '__attribute__((retain))\n'
        '#endif\n'
        '#endif\n'
        '__attribute__((used, section("caw_caps"))) static const unsigned char caw_component_capabilities[] = $array;\n'
        '#endif\n';
  }

  /// [manifestText] with its "capabilities" replaced by [list] (removed when empty), every other key kept in
  /// its order. Throws [FormatException] when the text isn't a JSON object.
  static String writeToManifest(String manifestText, List<CapabilityDeclaration> list) {
    final j = jsonDecode(manifestText);
    if (j is! Map<String, dynamic>) throw const FormatException('caw-component.json is not a JSON object');
    final out = <String, dynamic>{};
    var placed = false;
    for (final e in j.entries) {
      if (e.key == 'capabilities') {
        if (list.isNotEmpty) out['capabilities'] = [for (final d in list) d.toJson()];
        placed = true;
      } else {
        out[e.key] = e.value;
      }
    }
    if (!placed && list.isNotEmpty) out['capabilities'] = [for (final d in list) d.toJson()];
    return '${const JsonEncoder.withIndent('  ').convert(out)}\n';
  }
}
