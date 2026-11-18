// The engine's pre-load scan of a native component (caw_engine_scan_component, API 37) as typed Dart: its verdict, what it declares and what the scan found.
import 'dart:convert';

/// The scan's verdict: clean (silent), notice, warning (shown before Trusted), blocked (it can't load).
enum ScanVerdict { clean, notice, warning, blocked }

/// One capability the component declares in its caw-component.json, built into the binary.
class ScanDeclared {
  const ScanDeclared({required this.id, required this.title, required this.reason, this.sites = const []});
  final String id, title, reason;
  final List<String> sites;
}

/// One thing the scan saw in the file.
class ScanFinding {
  const ScanFinding({
    required this.capability,
    required this.title,
    required this.kind,
    required this.evidence,
    required this.certain,
    required this.warning,
    required this.declared,
    required this.blocks,
  });

  final String capability, title, kind, evidence;

  /// `certain`: the binary has it; otherwise a hint (the bytes suggest it).
  final bool certain;

  /// The severity as this host weighs it: a warning, else a notice.
  final bool warning;
  final bool declared, blocks;
}

/// The whole scan result (docs/engine.md "Pre-load scan", JSON).
class ComponentScan {
  const ComponentScan({
    required this.ok,
    this.error = '',
    this.sha256 = '',
    this.verdict = ScanVerdict.clean,
    this.reason = '',
    this.graceApplied = false,
    this.declarations = 'absent',
    this.declared = const [],
    this.blockedBy = const [],
    this.findings = const [],
  });

  final bool ok;
  final String error;
  final String sha256;
  final ScanVerdict verdict;
  final String reason;

  /// Loaded under legacy grace: a build from before 1.0.7 the user trusted, its findings warnings, not blocks.
  final bool graceApplied;

  /// `absent` (no section: a build from before 1.0.7), `valid` or `invalid`.
  final String declarations;
  final List<ScanDeclared> declared;

  /// The capability ids that block it.
  final List<String> blockedBy;
  final List<ScanFinding> findings;

  bool get blocked => !ok || verdict == ScanVerdict.blocked;

  /// Parses the engine's JSON; anything that isn't the expected shape is a failed scan, never a clean one.
  static ComponentScan fromJsonText(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) return const ComponentScan(ok: false, error: 'the scan returned no result');
      return fromJson(j);
    } on FormatException {
      return const ComponentScan(ok: false, error: 'the scan returned no result');
    }
  }

  static ComponentScan fromJson(Map<String, dynamic> j) {
    if (j['ok'] != true) return ComponentScan(ok: false, error: _s(j['error'], 'the scan failed'));
    List<Map<String, dynamic>> maps(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];
    List<String> strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];
    final verdict = ScanVerdict.values.where((v) => v.name == j['verdict']).firstOrNull;
    // An unknown verdict is treated as blocked: a newer engine's word for something worse is never read as clean.
    return ComponentScan(
      ok: true,
      sha256: _s(j['sha256']),
      verdict: verdict ?? ScanVerdict.blocked,
      reason: _s(j['reason']),
      graceApplied: j['grace_applied'] == true,
      declarations: _s(j['declarations'], 'absent'),
      declared: [
        for (final d in maps(j['declared']))
          ScanDeclared(id: _s(d['id']), title: _s(d['title']), reason: _s(d['reason']), sites: strings(d['sites'])),
      ],
      blockedBy: strings(j['blocked_by']),
      findings: [
        for (final f in maps(j['findings']))
          ScanFinding(
            capability: _s(f['capability']),
            title: _s(f['title']),
            kind: _s(f['kind']),
            evidence: _s(f['evidence']),
            certain: f['strength'] == 'certain',
            warning: f['severity'] != 'notice',
            declared: f['declared'] == true,
            blocks: f['blocks'] == true,
          ),
      ],
    );
  }

  static String _s(Object? v, [String fallback = '']) => v is String ? v : fallback;
}
