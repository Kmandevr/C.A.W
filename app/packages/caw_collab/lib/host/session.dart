// A session's identity and access settings: its id, the project's owner, public or private (a password hash),
// invites by the hash of their secret, the host's version, and the state a successor host continues from.
import 'dart:convert';

import 'package:caw_services/sha256.dart';

import '../ids.dart';
import '../ops.dart';
import 'password.dart';
import 'permissions.dart';
import 'versions.dart';

/// Whether anyone who reaches the session may join (public) or only those with the password or an invite
/// (private).
enum Lobby { public, private }

final _sessionId = RegExp(r'^[0-9A-Za-z_-]{1,64}$');

/// Whether [id] is a session id: 1 to 64 characters of base64url.
///
/// Assumption: the design names a session id (in invites) without a format.
bool isValidSessionId(String id) => _sessionId.hasMatch(id);

/// The hash an invite's secret is kept as. The secret is 128 random bits, so a fast hash suffices.
String inviteSecretHash(String secret) => sha256Hex(utf8.encode(secret));

/// What a host is started with.
class SessionConfig {
  SessionConfig({
    required this.sessionId,
    required this.owner,
    required this.hostApp,
    required this.fileVersion,
    this.lobby = Lobby.public,
    this.password,
    Map<String, Role> invites = const {},
    this.hostMember,
  }) : invites = Map.of(invites) {
    if (!isValidSessionId(sessionId)) throw ArgumentError.value(sessionId, 'sessionId');
    if (!AuthorIds.isValid(owner)) throw ArgumentError.value(owner, 'owner');
    if (hostMember != null && !AuthorIds.isValid(hostMember!)) throw ArgumentError.value(hostMember, 'hostMember');
    if (lobby == Lobby.private && password == null && invites.isEmpty) {
      throw ArgumentError('a private session needs a password or an invite');
    }
  }

  final String sessionId;

  /// The project owner's device key id. Hosting never changes it (hosting is not owning).
  final String owner;

  /// The hosting app's version, named in version refusals.
  final String hostApp;

  /// The project's `fileVersion`; the schema hash comes from the host's schema.
  final int fileVersion;
  final Lobby lobby;

  /// The password, kept only as a salted slow hash.
  final PasswordHash? password;

  /// Invites: the hash of each secret ([inviteSecretHash]) and the role it gives.
  final Map<String, Role> invites;

  /// The hosting device's own member key, when the host is a participant (it is never its own successor).
  final String? hostMember;

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'owner': owner,
        'hostApp': hostApp,
        'fileVersion': fileVersion,
        'lobby': lobby.name,
        if (password != null) 'password': password!.encoded,
        'invites': {for (final e in invites.entries) e.key: e.value.wire},
        if (hostMember != null) 'hostMember': hostMember,
      };

  /// Reads a config from stored or received JSON; throws [FormatException] when it is malformed.
  static SessionConfig fromJson(Object? json, {String? hostApp, String? hostMember, bool keepHostMember = true}) {
    if (json is! Map) throw const FormatException('a session config is not an object');
    T field<T>(String k) {
      final v = json[k];
      if (v is! T) throw FormatException('session config $k is malformed');
      return v;
    }

    final lobby = Lobby.values.where((l) => l.name == json['lobby']).firstOrNull;
    if (lobby == null) throw const FormatException('session config lobby is malformed');
    final pw = json['password'];
    final password = pw == null ? null : (pw is String ? PasswordHash.parse(pw) : null);
    if (pw != null && password == null) throw const FormatException('session config password is malformed');
    final inv = field<Map>('invites');
    final invites = <String, Role>{};
    for (final e in inv.entries) {
      final r = e.value is String ? Role.byWire(e.value as String) : null;
      if (e.key is! String || r == null) throw const FormatException('session config invites are malformed');
      invites[e.key as String] = r;
    }
    final hm = json['hostMember'];
    try {
      return SessionConfig(
        sessionId: field<String>('sessionId'),
        owner: field<String>('owner'),
        hostApp: hostApp ?? field<String>('hostApp'),
        fileVersion: field<int>('fileVersion'),
        lobby: lobby,
        password: password,
        invites: invites,
        hostMember: hostMember ?? (keepHostMember && hm is String ? hm : null),
      );
    } on ArgumentError catch (e) {
      throw FormatException('session config: ${e.message}');
    }
  }
}

/// What a successor needs to continue the session as its next host: the config, every member's grants, and the
/// epoch and sequence the sender was at. The host sends it to ranked successors only.
///
/// Assumption: this includes the password hash, so a successor keeps the session private. Every successor
/// already holds the whole project, which is what the password protects.
class SessionState {
  const SessionState({required this.config, required this.grants, required this.epoch, required this.seq});
  final SessionConfig config;
  final Map<String, List<Grant>> grants;
  final int epoch;
  final int seq;

  Map<String, Object?> toJson() => {
        'config': config.toJson(),
        'grants': {for (final e in grants.entries) e.key: [for (final g in e.value) g.toJson()]},
        'epoch': epoch,
        'seq': seq,
      };

  static SessionState fromJson(Object? json) {
    if (json is! Map) throw const FormatException('a session state is not an object');
    final g = json['grants'], epoch = json['epoch'], seq = json['seq'];
    if (g is! Map || epoch is! int || seq is! int || epoch < 0 || seq < 0) throw const FormatException('a session state is malformed');
    return SessionState(config: SessionConfig.fromJson(json['config']), grants: grantsFromJson(g), epoch: epoch, seq: seq);
  }
}

/// Members' grants from JSON (`{member: [{capability, scope}]}`); throws [FormatException] when malformed.
Map<String, List<Grant>> grantsFromJson(Map json) {
  final out = <String, List<Grant>>{};
  for (final e in json.entries) {
    final k = e.key, v = e.value;
    if (k is! String || !AuthorIds.isValid(k) || v is! List) throw const FormatException('grants are malformed');
    out[k] = [for (final x in v) grantFromJson(x)];
  }
  return out;
}

Grant grantFromJson(Object? x) {
  if (x is! Map) throw const FormatException('a grant is not an object');
  final c = x['capability'] is String ? Capability.byWire(x['capability'] as String) : null;
  final s = x['scope'];
  if (c == null || s is! String || !NodeIds.isValid(s)) throw const FormatException('a grant is malformed');
  return Grant(c, s);
}

/// The host's own version facts for admission.
VersionInfo hostVersion(SessionConfig config, String schemaHash) => VersionInfo(
    appVersion: config.hostApp,
    format: ProjectFormat(fileVersion: config.fileVersion, schemaHash: schemaHash),
    protocol: collabProtocol);
