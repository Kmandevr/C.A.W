// Version admission: the collaboration protocol's version, a project format, and the rule that admits a member
// when the project format and the protocol's major version match, with a refusal that names what to update.

/// A `caw_collab` protocol version. A breaking change to how the host handles a session raises [major]; an
/// additive one (a new optional message or field) raises only [minor] and stays compatible.
class ProtocolVersion {
  const ProtocolVersion(this.major, this.minor);
  final int major;
  final int minor;

  /// `major.minor`, or null when [text] is not one.
  static ProtocolVersion? parse(String text) {
    final m = RegExp(r'^(\d{1,6})\.(\d{1,6})$').firstMatch(text);
    if (m == null) return null;
    return ProtocolVersion(int.parse(m[1]!), int.parse(m[2]!));
  }

  @override
  String toString() => '$major.$minor';

  @override
  bool operator ==(Object other) => other is ProtocolVersion && other.major == major && other.minor == minor;

  @override
  int get hashCode => Object.hash(major, minor);
}

/// The protocol this package speaks.
///
/// Assumption: the first version is 1.0; the design names the major/minor rule but no number.
const ProtocolVersion collabProtocol = ProtocolVersion(1, 0);

/// A project format: the app's project `fileVersion` and the shared tree's schema hash.
class ProjectFormat {
  const ProjectFormat({required this.fileVersion, required this.schemaHash});
  final int fileVersion;
  final String schemaHash;

  Map<String, Object?> toJson() => {'fileVersion': fileVersion, 'schemaHash': schemaHash};

  @override
  bool operator ==(Object other) => other is ProjectFormat && other.fileVersion == fileVersion && other.schemaHash == schemaHash;

  @override
  int get hashCode => Object.hash(fileVersion, schemaHash);
}

/// What a joining app says about itself in its handshake.
class VersionInfo {
  const VersionInfo({required this.appVersion, required this.format, required this.protocol});

  /// The app's version string; informational only (it never decides admission).
  final String appVersion;
  final ProjectFormat format;
  final ProtocolVersion protocol;
}

/// Why a version was refused: a stable [reason] code and a [message] naming what to update.
class VersionRefusal {
  const VersionRefusal(this.reason, this.message);
  final String reason;
  final String message;

  static const formatMismatch = 'format_mismatch';
  static const protocolMismatch = 'protocol_mismatch';
}

/// Whether a joiner with [joiner] may join a host with [host]: null to admit, or why not.
///
/// Only the project format (`fileVersion` and the schema hash) and the protocol's major version decide; the app
/// version, the engine and everything else never do (owner, 2026-11-27). The refusal names the side that is
/// behind and the version that fits: the host's app version when the joiner is behind, the joiner's when the
/// host is.
///
/// Assumption: when the `fileVersion`s are equal but the schema hashes differ, neither side can tell which is
/// newer, so the refusal names the host's app version.
VersionRefusal? versionRefusal(VersionInfo host, VersionInfo joiner) {
  if (joiner.protocol.major != host.protocol.major) {
    final joinerBehind = joiner.protocol.major < host.protocol.major;
    return VersionRefusal(
        VersionRefusal.protocolMismatch,
        joinerBehind
            ? 'This session uses session protocol ${host.protocol.major}.x and you have ${joiner.protocol}: '
                'update C.A.W to ${host.appVersion} or a later version with protocol ${host.protocol.major}.x.'
            : 'This session uses session protocol ${host.protocol} and you have ${joiner.protocol.major}.x: '
                'the host must update C.A.W to ${joiner.appVersion} or a later version with protocol ${joiner.protocol.major}.x.');
  }
  final hf = host.format, jf = joiner.format;
  if (hf.fileVersion != jf.fileVersion || hf.schemaHash != jf.schemaHash) {
    final joinerBehind = jf.fileVersion < hf.fileVersion || jf.fileVersion == hf.fileVersion;
    return VersionRefusal(
        VersionRefusal.formatMismatch,
        joinerBehind
            ? 'This session uses project format ${hf.fileVersion} (${_short(hf.schemaHash)}) and you have '
                '${jf.fileVersion} (${_short(jf.schemaHash)}): update C.A.W to ${host.appVersion} or a version with the same project format.'
            : 'This session uses project format ${hf.fileVersion} and you have ${jf.fileVersion}: the host must '
                'update C.A.W to ${joiner.appVersion} or a version with the same project format.');
  }
  return null;
}

String _short(String hash) => hash.length <= 8 ? hash : hash.substring(0, 8);
