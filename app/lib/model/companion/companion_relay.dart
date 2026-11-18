// Telemetry and feedback through the companion app when it is there (docs/companion-protocol.md): the four relay
// calls at the RelayClient level, as fixed kinds with no URL or method; absent, the in-app HTTPS client runs.
import 'dart:convert';

import 'package:caw_services/companion/companion_protocol.dart';
import 'package:caw_services/telemetry/relay_client.dart';

import '../../platform/companion_link.dart';

/// [RelayClient]'s calls sent as companion kinds; the in-app client (this class's own superclass, built from
/// [fallback]'s config and transport) when the companion is absent or doesn't know the kind.
class CompanionRelay extends RelayClient {
  CompanionRelay(this.link, RelayClient fallback) : super(fallback.config, fallback.http);
  final CompanionLink link;

  @override
  Future<RelayResponse> postReport(String json) =>
      _via(CompanionKind.telemetryReport, () => {'report': jsonDecode(json)}, () => super.postReport(json));

  @override
  Future<RelayResponse> getReport(String receipt) =>
      _via(CompanionKind.telemetryGet, () => {'receipt': receipt}, () => super.getReport(receipt));

  @override
  Future<RelayResponse> delete(List<({String receipt, String deleteKey})> items) => _via(
      CompanionKind.telemetryDelete,
      () => {'items': [for (final i in items) {'receipt': i.receipt, 'deleteKey': i.deleteKey}]},
      () => super.delete(items));

  @override
  Future<RelayResponse> postFeedback(String json) =>
      _via(CompanionKind.feedbackPost, () => {'feedback': jsonDecode(json)}, () => super.postFeedback(json));

  Future<RelayResponse> _via(
      CompanionKind kind, Map<String, Object?> Function() body, Future<RelayResponse> Function() inApp) async {
    // A build with no relay sends nothing either way, as today.
    if (!config.canSend) return const RelayResponse.offline();
    if (await link.probe() != CompanionStatus.present) return inApp();
    final Map<String, Object?> b;
    try {
      b = body();
    } on FormatException {
      return inApp(); // not JSON: the in-app client sends it as it always did
    }
    final r = await link.request(kind, b);
    if (r.ok) return relayAnswer(r.body);
    if (r.fallBack) return inApp();
    // The companion may have sent it: a try that may have arrived, never sent again in-app.
    if (r.outcome == CompanionOutcome.timeout) return const RelayResponse.offline(sentBody: true);
    if (r.outcome == CompanionOutcome.busy) return const RelayResponse(429);
    return const RelayResponse.offline();
  }

  /// A relay answer (`{"status", "body", "retryAfter", "sent"}`) as the in-app client would have read it.
  static RelayResponse relayAnswer(Map<String, Object?> a) {
    final status = a['status'];
    if (status is! int || status < 0 || status > 599) return const RelayResponse.offline();
    if (status == 0) return RelayResponse.offline(sentBody: a['sent'] == true);
    final body = a['body'];
    final ra = a['retryAfter'];
    return RelayResponse(status,
        body: body is String ? body : '',
        retryAfter: ra is int && ra >= 0
            ? (ra >= maxRetryAfter.inSeconds ? maxRetryAfter : Duration(seconds: ra))
            : null);
  }
}
