// The host's settings, every one with a working default, so hosting needs no choices (owner, 2026-11-27).
import '../limits.dart';
import 'password.dart';
import 'permissions.dart';

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
    this.opsPerSecond = 60,
    this.opBurst = 600,
    this.snapshotEveryOps = 500,
    this.snapshotEveryMs = 5 * 60 * 1000,
    this.resumeWindowMs = 24 * 60 * 60 * 1000,
    this.migration = true,
    this.whoMayHost = HostEligibility.anyone,
    this.defaultRole = Role.collaborator,
    this.passwordTriesPerMinute = 5,
    this.passwordIterations = PasswordHash.defaultIterations,
    this.dedupeMemory = 4096,
    this.maxBlobBytes = 1 << 30,
    this.blobQuotaBytes = 4 << 30,
    this.limits = CollabLimits.standard,
  });

  /// The most members connected at once; the project's owner is always let in.
  final int maxMembers;

  /// Each member's sustained op rate, and the burst a member may send at once (a token bucket).
  final int opsPerSecond;
  final int opBurst;

  /// A snapshot after this many ops, or after this long with at least one op since the last one.
  final int snapshotEveryOps;
  final int snapshotEveryMs;

  /// How long the host keeps a session's cache after its last activity or its end, for members to resume.
  final int resumeWindowMs;

  /// Whether hosting moves to the next ranked member when the host drops (on by default, owner 2026-11-27).
  final bool migration;

  /// Who may be ranked as a successor.
  final HostEligibility whoMayHost;

  /// The role a member who joins without an invite gets (an invite names its own role).
  ///
  /// Assumption: the design doesn't say; collaborator lets a "click Host and it just works" session edit at once,
  /// and the owner can narrow it with an access change.
  final Role defaultRole;

  /// Password tries one address may make in any 60 seconds.
  final int passwordTriesPerMinute;

  /// The iteration count for a new password hash.
  final int passwordIterations;

  /// How many recent `(device, clientSeq)` outcomes the host remembers per member to answer a resend exactly.
  final int dedupeMemory;

  /// The largest blob, and the most blob bytes one session may hold (the project package's 1 GiB per file and
  /// 4 GiB in total).
  final int maxBlobBytes;
  final int blobQuotaBytes;

  /// The caps on each op and batch.
  final CollabLimits limits;
}
