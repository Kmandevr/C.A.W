// The host's settings, every one with a working default, so hosting needs no choices (owner, 2026-11-27).
import '../limits.dart';
import 'password.dart';
import 'permissions.dart';
import 'storage.dart';

/// Who may become host when hosting moves.
enum HostEligibility {
  /// Any member who can see the project.
  anyone,

  /// Members who may edit the project's content at its root.
  editors,

  /// Members who hold `manage_access` at the root (the owner, and whoever the owner gave it).
  managers,
}

/// The host core's settings. Networking settings (the port, router port opening, discovery, a relay) belong to
/// the standalone host and the app's host service, which come later.
///
/// Assumption: the design gives the snapshot cadence (500 ops or 5 minutes of activity), the resume window
/// (24 hours, a proposal), a phone host's member cap (8, a proposal) and "a few tries a minute" for passwords;
/// every other number here is this package's own choice.
class HostSettings {
  const HostSettings({
    this.maxMembers = 8,
    this.maxKnownMembers = 256,
    this.idleIdPruneMs = 60 * 60 * 1000,
    this.opsPerSecond = 60,
    this.opBurst = 600,
    this.messagesPerSecond = 50,
    this.messageBurst = 200,
    this.resumesPerMinute = 6,
    this.invitesPerMinute = 10,
    this.joinsPerMinute = 10,
    this.snapshotEveryOps = 500,
    this.snapshotEveryMs = 5 * 60 * 1000,
    this.resumeWindowMs = 24 * 60 * 60 * 1000,
    this.migration = true,
    this.whoMayHost = HostEligibility.editors,
    this.maxScore = 1000,
    this.defaultRole = Role.collaborator,
    this.passwordTriesPerMinute = 5,
    this.passwordTriesPerMinuteGlobal = 30,
    this.passwordChecksAtOnce = 1,
    this.passwordQueue = 8,
    this.passwordIterations = PasswordHash.defaultIterations,
    this.inviteTtlMs = 24 * 60 * 60 * 1000,
    this.maxInviteUses = 100,
    this.maxInvites = 64,
    this.maxGrantsPerMember = 256,
    this.dedupeMemory = 1024,
    this.maxTreeBytes = 64 * 1024 * 1024,
    this.maxBlobBytes = 1 << 30,
    this.blobQuotaBytes = 4 << 30,
    this.limits = CollabLimits.standard,
  });

  /// The most members connected at once; the project's owner is always let in.
  final int maxMembers;

  /// The most distinct members a session ever admits (removed ones included), so random ids can't grow it.
  final int maxKnownMembers;

  /// How long an id that never did anything (no confirmed op, never given access, not connected) is kept before
  /// the host forgets it, so minted ids can't fill [maxKnownMembers] for good.
  final int idleIdPruneMs;

  /// Each member's sustained op rate, and the burst a member may send at once (a token bucket).
  final int opsPerSecond;
  final int opBurst;

  /// Each connection's message rate of any kind; going past it ends the connection.
  final int messagesPerSecond;
  final int messageBurst;

  /// Resumes per member per minute (each may send a whole snapshot); more are ignored.
  final int resumesPerMinute;

  /// Invites a member may make per minute; more are ignored.
  final int invitesPerMinute;

  /// First admissions (of members the session doesn't know yet) per address or transport identity per minute.
  final int joinsPerMinute;

  /// A snapshot after this many ops, or after this long with at least one op since the last one.
  final int snapshotEveryOps;
  final int snapshotEveryMs;

  /// How long the host keeps a session's cache after its last activity or its end, for members to resume.
  final int resumeWindowMs;

  /// Whether hosting moves to the next ranked member when the host drops (on by default, owner 2026-11-27).
  final bool migration;

  /// Who may be ranked as a successor. Editors by default: the owner chooses the host (owner, 2026-11-27), and
  /// a viewer never becomes one.
  final HostEligibility whoMayHost;

  /// The highest capability score a member may report; higher ones count as this.
  final double maxScore;

  /// The role a member who joins without an invite gets (an invite names its own role).
  ///
  /// Assumption: the design doesn't say; collaborator lets a "click Host and it just works" session edit at once,
  /// and the owner can narrow it with an access change.
  final Role defaultRole;

  /// Password tries one address (or transport identity) may make in any 60 seconds, and all addresses together.
  final int passwordTriesPerMinute;
  final int passwordTriesPerMinuteGlobal;

  /// How many slow password checks run at once, and how many may wait; more are refused as busy.
  final int passwordChecksAtOnce;
  final int passwordQueue;

  /// The iteration count for a new password hash.
  final int passwordIterations;

  /// How long an invite lasts unless it says otherwise, the most uses one may have, and the most live at once.
  final int inviteTtlMs;
  final int maxInviteUses;
  final int maxInvites;

  /// The most grants one member may hold (an access op with more is refused).
  final int maxGrantsPerMember;

  /// How many recent `(device, clientSeq)` outcomes the host remembers per member to answer a resend exactly.
  final int dedupeMemory;

  /// The most bytes the tree may hold, counted as its JSON (tombstones included): the op that would pass it is
  /// refused, so a snapshot always fits [maxSnapshotBytes].
  final int maxTreeBytes;

  /// The largest blob, and the most blob bytes one session may hold (the project package's 1 GiB per file and
  /// 4 GiB in total).
  final int maxBlobBytes;
  final int blobQuotaBytes;

  /// The caps on each op and batch.
  final CollabLimits limits;

  /// The most bytes a snapshot of a session at these settings can take: the tree plus each known member's grants
  /// (about 80 bytes each), token and dedupe memory (about 120 bytes per outcome), the invites and 1 MiB of room.
  int get worstSnapshotBytes =>
      maxTreeBytes + maxKnownMembers * (maxGrantsPerMember * 80 + dedupeMemory * 120 + 512) + maxInvites * 256 + (1 << 20);

  /// Why these settings can't work, or null when they can.
  String? get problem {
    if (worstSnapshotBytes > maxSnapshotBytes) return 'a snapshot could reach $worstSnapshotBytes bytes, over $maxSnapshotBytes';
    if (maxMembers < 1 || maxKnownMembers < maxMembers) return 'the member caps are out of order';
    if (passwordChecksAtOnce < 1 || passwordQueue < 0) return 'the password check caps are out of range';
    if (passwordIterations < PasswordHash.floor) return 'password iterations are under ${PasswordHash.floor}';
    if (dedupeMemory < 1 || snapshotEveryOps < 1 || maxInviteUses < 1 || maxInvites < 1) return 'a count is under 1';
    return null;
  }
}
