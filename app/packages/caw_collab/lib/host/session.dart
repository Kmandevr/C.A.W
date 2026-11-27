// A session's identity and access settings: its id, the project's owner, public or private (a password hash),
// invites by the hash of their secret, the migration secret that proves a successor host, and the state a
// successor continues from.
import 'dart:convert';
import 'dart:math';

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
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Whether [id] is a session id: 1 to 64 characters of base64url.
///
/// Assumption: the design names a session id (in invites) without a format.
bool isValidSessionId(String id) => _sessionId.hasMatch(id);

/// The hash a secret with 128 bits or more of randomness is kept as (an invite's secret, a member token). Such a
/// secret can't be guessed, so a fast hash suffices.
String secretHash(String secret) => sha256Hex(utf8.encode(secret));

/// The hash an invite's secret is kept as.
String inviteSecretHash(String secret) => secretHash(secret);

/// 32 random bytes as 64 lowercase hex digits.
String randomSecret([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// One invite: the role it gives, how many more joins it admits, when it expires and who made it.
class Invite {
  Invite({required this.role, this.usesLeft = 1, this.expiresAt, this.createdBy});
  final Role role;
  int usesLeft;

  /// Milliseconds since the epoch; null until the host stamps it with its default lifetime.
  int? expiresAt;
  final String? createdBy;

  Map<String, Object?> toJson() => {
        'role': role.wire,
        'usesLeft': usesLeft,
        if (expiresAt != null) 'expiresAt': expiresAt,
        if (createdBy != null) 'createdBy': createdBy,
      };

  static Invite fromJson(Object? json) {
    if (json is! Map) throw const FormatException('an invite is not an object');
    final role = json['role'] is String ? Role.byWire(json['role'] as String) : null;
    final uses = json['usesLeft'], exp = json['expiresAt'], by = json['createdBy'];
    if (role == null || uses is! int || uses < 1 || (exp != null && exp is! int) || (by != null && (by is! String || !AuthorIds.isValid(by)))) {
      throw const FormatException('an invite is malformed');
    }
    return Invite(role: role, usesLeft: uses, expiresAt: exp as int?, createdBy: by as String?);
  }
}

/// What a host is started with.
class SessionConfig {
  SessionConfig({
    required this.sessionId,
    required this.owner,
    required this.hostApp,
    required this.fileVersion,
    this.lobby = Lobby.public,
    this.password,
    Map<String, Invite> invites = const {},
    this.hostMember,
    String? migrationSecret,
  })  : invites = Map.of(invites),
        migrationSecret = migrationSecret ?? randomSecret() {
    if (!isValidSessionId(sessionId)) throw ArgumentError.value(sessionId, 'sessionId');
    if (!AuthorIds.isValid(owner)) throw ArgumentError.value(owner, 'owner');
    if (hostMember != null && !AuthorIds.isValid(hostMember!)) throw ArgumentError.value(hostMember, 'hostMember');
    if (!_hex64.hasMatch(this.migrationSecret)) throw ArgumentError('the migration secret is not 64 hex digits');
    for (final h in this.invites.keys) {
      if (!_hex64.hasMatch(h)) throw ArgumentError('an invite hash is not a SHA-256');
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

  /// The password, kept only as a salted slow hash. A private session without one admits only members it knows
  /// and invites.
  final PasswordHash? password;

  /// Invites by the hash of their secret ([inviteSecretHash]).
  final Map<String, Invite> invites;

  /// The hosting device's own member key, when the host is a participant (it is never its own successor).
  final String? hostMember;

  /// The secret a successor host proves itself with ([fenceProof]); only successors receive it, and it changes
  /// when a member is removed.
  String migrationSecret;

  /// This config without the lobby's secrets (the password hash and the invites), for a successor that may not
  /// manage access.
  SessionConfig withoutLobbySecrets() => SessionConfig(
      sessionId: sessionId, owner: owner, hostApp: hostApp, fileVersion: fileVersion, lobby: lobby,
      hostMember: hostMember, migrationSecret: migrationSecret);

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'owner': owner,
        'hostApp': hostApp,
        'fileVersion': fileVersion,
        'lobby': lobby.name,
        if (password != null) 'password': password!.encoded,
        'invites': {for (final e in invites.entries) e.key: e.value.toJson()},
        if (hostMember != null) 'hostMember': hostMember,
        'migrationSecret': migrationSecret,
      };

  /// Reads a config from stored or received JSON; throws [FormatException] when it is malformed.
  static SessionConfig fromJson(Object? json, {String? hostApp, String? hostMember, bool keepHostMember = true, int maxInvites = 1 << 16}) {
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
    if (pw != null && password == null) throw const FormatException('session config password is malformed or too weak');
    final inv = field<Map>('invites');
    if (inv.length > maxInvites) throw const FormatException('session config has too many invites');
    final invites = <String, Invite>{};
    for (final e in inv.entries) {
      if (e.key is! String) throw const FormatException('session config invites are malformed');
      invites[e.key as String] = Invite.fromJson(e.value);
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
        migrationSecret: field<String>('migrationSecret'),
      );
    } on ArgumentError catch (e) {
      throw FormatException('session config: ${e.message}');
    }
  }
}

/// The proof a host at [epoch] of session [sessionId] is a successor: an HMAC-SHA256 under the session's
/// migration secret, which only successors hold.
String fenceProof(String migrationSecret, String sessionId, int epoch) =>
    hmacSha256(utf8.encode(migrationSecret), utf8.encode('caw-fence|$sessionId|$epoch')).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// What a successor needs to continue the session as its next host: the config (with the lobby's secrets only for
/// a successor that may manage access), every member's grants and token hash, and the epoch and sequence the
/// sender was at. The host sends it to ranked successors only.
class SessionState {
  const SessionState({required this.config, required this.grants, required this.tokens, required this.epoch, required this.seq});
  final SessionConfig config;
  final Map<String, List<Grant>> grants;

  /// Each known member's token hash ([secretHash]), so members rejoin the successor with their tokens.
  final Map<String, String> tokens;
  final int epoch;
  final int seq;

  Map<String, Object?> toJson() => {
        'config': config.toJson(),
        'grants': {for (final e in grants.entries) e.key: [for (final g in e.value) g.toJson()]},
        'tokens': tokens,
        'epoch': epoch,
        'seq': seq,
      };

  static SessionState fromJson(Object? json) {
    if (json is! Map) throw const FormatException('a session state is not an object');
    final g = json['grants'], t = json['tokens'], epoch = json['epoch'], seq = json['seq'];
    if (g is! Map || t is! Map || epoch is! int || seq is! int || epoch < 0 || seq < 0) throw const FormatException('a session state is malformed');
    final tokens = <String, String>{};
    for (final e in t.entries) {
      if (e.key is! String || !AuthorIds.isValid(e.key as String) || e.value is! String || !_hex64.hasMatch(e.value as String)) {
        throw const FormatException('session state tokens are malformed');
      }
      tokens[e.key as String] = e.value as String;
    }
    return SessionState(config: SessionConfig.fromJson(json['config']), grants: grantsFromJson(g), tokens: tokens, epoch: epoch, seq: seq);
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
