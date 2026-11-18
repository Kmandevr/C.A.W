// The companion protocol's constants and body checks (docs/companion-protocol.md, version 1), shared by C.A.W and
// the companion app: the message kinds, the reply statuses, the 64 KiB body limit and the timeouts.
import 'dart:convert';

/// The protocol version this build speaks. A message with a higher `v` is answered `unsupported`.
const int companionProtocolVersion = 1;

/// A body's most UTF-8 bytes, in either direction.
const int companionMaxBodyBytes = 64 * 1024;

/// How long a bind may take before the companion counts as absent.
const Duration companionBindTimeout = Duration(seconds: 3);

/// How long after its last answer the main app keeps the companion bound.
const Duration companionIdleUnbind = Duration(seconds: 30);

/// One message kind: its `what` number on the wire and its name in the note.
enum CompanionKind {
  hello(1, 'hello'),
  updateStatus(2, 'update.status'),
  updateCheck(3, 'update.check'),
  updateOpen(4, 'update.open'),
  telemetryReport(5, 'telemetry.report'),
  telemetryGet(6, 'telemetry.get'),
  telemetryDelete(7, 'telemetry.delete'),
  feedbackPost(8, 'feedback.post'),
  trustQuery(9, 'trust.query'),
  knownBadVersion(10, 'knownbad.version');

  const CompanionKind(this.what, this.wire);
  final int what;
  final String wire;

  /// The kinds the companion answers by calling the relay, whose own request may take 20 s.
  bool get relay => this == telemetryReport || this == telemetryGet || this == telemetryDelete || this == feedbackPost;

  /// Kinds that only read: safe to answer in-app after a timeout. The others may already have been acted on.
  bool get readOnly =>
      this == hello || this == updateStatus || this == updateCheck || this == trustQuery || this == knownBadVersion;

  /// How long the request may take once bound.
  Duration get timeout => relay ? const Duration(seconds: 25) : const Duration(seconds: 10);

  static CompanionKind? byWhat(int what) {
    for (final k in values) {
      if (k.what == what) return k;
    }
    return null;
  }
}

/// A reply's `status`.
enum CompanionStatusCode {
  ok('ok'),
  unsupported('unsupported'),
  badRequest('bad_request'),
  refused('refused'),
  busy('busy'),
  error('error');

  const CompanionStatusCode(this.wire);
  final String wire;

  static CompanionStatusCode? byWire(Object? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// [body] as the wire's JSON text, or null when it can't be encoded or is over [companionMaxBodyBytes].
String? encodeCompanionBody(Map<String, Object?> body) {
  try {
    final text = jsonEncode(body);
    return utf8.encode(text).length > companionMaxBodyBytes ? null : text;
  } on JsonUnsupportedObjectError {
    return null;
  }
}

/// The wire's [text] as a JSON object, or null when it isn't text, is over [companionMaxBodyBytes] or isn't an object.
Map<String, Object?>? decodeCompanionBody(Object? text) {
  if (text is! String || text.length > companionMaxBodyBytes || utf8.encode(text).length > companionMaxBodyBytes) {
    return null;
  }
  try {
    final v = jsonDecode(text);
    return v is Map<String, Object?> ? v : (v is Map ? v.cast<String, Object?>() : null);
  } on FormatException {
    return null;
  }
}

/// A component fingerprint as `trust.query` takes it: 64 lower-case hex digits.
bool isFingerprint(Object? v) => v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v);
