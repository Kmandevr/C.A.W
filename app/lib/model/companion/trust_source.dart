// Where a native component's trust comes from: the local store (NativeTrustStore), with the companion app's
// known-bad list on top when it is there (docs/companion-protocol.md, trust.query). Known-bad always wins.
import 'package:caw_services/companion/companion_protocol.dart';

import '../../engine/engine.dart';
import '../../platform/companion_link.dart';
import '../native_trust.dart';

/// The trust for exactly one piece of code, and why it is blocked when a known-bad list says so.
class TrustDecision {
  const TrustDecision(this.trust, {this.knownBadReason});

  /// Null: not known yet, ask the user (as [NativeTrustStore.decide]).
  final NativeComponentTrust? trust;

  /// Set when the companion's known-bad list blocked it, with its reason (shown to the user).
  final String? knownBadReason;
  bool get knownBad => knownBadReason != null;
}

abstract class TrustSource {
  /// The local store's answer, unless a known-bad list blocks [fingerprint].
  Future<TrustDecision> decide(String componentId, String fingerprint);
}

/// [link] and [store] as a source: the companion's when a companion may be there, else the store alone.
TrustSource trustSourceFor(CompanionLink link, NativeTrustStore store) =>
    link is NoCompanionLink ? LocalTrustSource(store) : CompanionTrustSource(link, store);

/// The device's own choices only (today's behaviour).
class LocalTrustSource implements TrustSource {
  LocalTrustSource(this.store);
  final NativeTrustStore store;

  @override
  Future<TrustDecision> decide(String componentId, String fingerprint) async =>
      TrustDecision(store.decide(componentId, fingerprint));
}

/// Asks the companion first. Its `bad` blocks whatever the local choice; anything else (unknown, absent, a
/// timeout, an older companion, an odd answer) leaves the local choice in charge.
class CompanionTrustSource implements TrustSource {
  CompanionTrustSource(this.link, this.store);
  final CompanionLink link;
  final NativeTrustStore store;

  @override
  Future<TrustDecision> decide(String componentId, String fingerprint) async {
    final local = TrustDecision(store.decide(componentId, fingerprint));
    if (componentId.isEmpty || componentId.length > 200 || !isFingerprint(fingerprint)) return local;
    if (await link.probe() != CompanionStatus.present) return local;
    final r = await link.request(CompanionKind.trustQuery, {'component': componentId, 'sha256': fingerprint});
    if (!r.ok || r.body['verdict'] != 'bad') return local;
    final reason = r.body['reason'];
    return TrustDecision(NativeComponentTrust.blocked,
        knownBadReason: reason is String && reason.trim().isNotEmpty
            ? (reason.length > 300 ? reason.substring(0, 300) : reason)
            : 'It is on the known-bad list.');
  }
}
