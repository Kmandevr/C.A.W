// The link to the companion app (docs/companion-protocol.md), one implementation per platform: Android binds its
// service over the caw/companion channel (CompanionClient.kt); everywhere else there is none and the in-app path runs.
import 'dart:async';
import 'dart:io';

import 'package:caw_services/companion/companion_protocol.dart';
import 'package:flutter/services.dart';

/// Whether the companion answered this run's `hello`.
enum CompanionStatus { unknown, absent, present }

/// How one request ended, from the main app's side.
enum CompanionOutcome { ok, absent, timeout, unsupported, refused, badRequest, busy, error }

/// One reply: how it ended and, when [ok], the body.
class CompanionReply {
  const CompanionReply(this.outcome, {this.body = const {}, this.detail});
  const CompanionReply.absent() : this(CompanionOutcome.absent);
  final CompanionOutcome outcome;
  final Map<String, Object?> body;

  /// A short reason for anything but [ok] (for an error line).
  final String? detail;

  bool get ok => outcome == CompanionOutcome.ok;

  /// Absent or not speaking this kind or version: the caller takes today's in-app path.
  bool get fallBack => outcome == CompanionOutcome.absent || outcome == CompanionOutcome.unsupported;
}

abstract class CompanionLink {
  /// The link main() chose for this run; none until then (tests, goldens).
  static CompanionLink current = NoCompanionLink();

  CompanionStatus get status;

  /// Asks the companion who it is; afterwards [status] is [CompanionStatus.present] or [CompanionStatus.absent].
  Future<CompanionReply> hello();

  /// Sends one request of [kind]; never throws. Absent (or not yet known to be present after [hello]) answers
  /// [CompanionOutcome.absent] without trying.
  Future<CompanionReply> request(CompanionKind kind, Map<String, Object?> body);

  /// [status], asking once ([hello]) when it is not known yet.
  Future<CompanionStatus> probe() async {
    if (status == CompanionStatus.unknown) await hello();
    return status;
  }
}

/// The platform's link: Android's service, or none.
CompanionLink platformCompanionLink() => Platform.isAndroid ? AndroidCompanionLink() : NoCompanionLink();

/// No companion (Windows, Linux, tests): everything takes the in-app path.
class NoCompanionLink extends CompanionLink {
  @override
  CompanionStatus get status => CompanionStatus.absent;

  @override
  Future<CompanionReply> hello() async => const CompanionReply.absent();

  @override
  Future<CompanionReply> request(CompanionKind kind, Map<String, Object?> body) async => const CompanionReply.absent();
}

/// Android: `CompanionClient.kt` binds the companion's service (3 s), sends one Message and checks the reply's sender
/// before answering. Its map is checked again here: the version, the id and the body's size and shape.
class AndroidCompanionLink extends CompanionLink {
  AndroidCompanionLink({MethodChannel? channel, this._slack = const Duration(seconds: 2)})
      : _channel = channel ?? const MethodChannel('caw/companion');
  final MethodChannel _channel;

  /// Beyond the bind and request timeouts, for the channel itself; past it the request counts as timed out.
  final Duration _slack;
  var _status = CompanionStatus.unknown;
  var _nextId = 1;
  Future<CompanionReply>? _hello;

  @override
  CompanionStatus get status => _status;

  @override
  Future<CompanionReply> hello() => _hello ??= () async {
        final r = await _send(CompanionKind.hello, const {});
        // Only a proper answer counts as present; a companion that times out, refuses or speaks another version is
        // treated as absent for this run, so nothing waits on it again.
        _status = r.ok ? CompanionStatus.present : CompanionStatus.absent;
        return r.ok ? r : (r.outcome == CompanionOutcome.absent ? r : CompanionReply(CompanionOutcome.absent, detail: r.detail));
      }();

  @override
  Future<CompanionReply> request(CompanionKind kind, Map<String, Object?> body) async {
    if (kind == CompanionKind.hello) return hello();
    if (await probe() != CompanionStatus.present) return const CompanionReply.absent();
    return _send(kind, body);
  }

  Future<CompanionReply> _send(CompanionKind kind, Map<String, Object?> body) async {
    final text = encodeCompanionBody(body);
    if (text == null) return const CompanionReply(CompanionOutcome.badRequest, detail: 'the request is too large');
    final id = _nextId++;
    final Object? answer;
    try {
      answer = await _channel.invokeMethod<Object?>('request', {
        'what': kind.what,
        'v': companionProtocolVersion,
        'id': id,
        'body': text,
        'timeoutMs': kind.timeout.inMilliseconds,
      }).timeout(companionBindTimeout + kind.timeout + _slack);
    } on TimeoutException {
      return const CompanionReply(CompanionOutcome.timeout, detail: 'the companion app did not answer');
    } on PlatformException catch (e) {
      return CompanionReply(CompanionOutcome.absent, detail: e.code);
    } on MissingPluginException {
      return const CompanionReply.absent();
    }
    return readReply(answer, id);
  }

  /// The channel's answer to request [id] as a reply (public for tests).
  static CompanionReply readReply(Object? answer, int id) {
    if (answer is! Map) return const CompanionReply(CompanionOutcome.error, detail: 'no answer');
    switch (answer['outcome']) {
      case 'absent':
        return const CompanionReply.absent();
      case 'timeout':
        return const CompanionReply(CompanionOutcome.timeout, detail: 'the companion app did not answer');
      case 'refused':
        // The reply's sender failed the caller check (CompanionCallerCheck.kt).
        return const CompanionReply(CompanionOutcome.refused, detail: 'the reply did not come from the companion app');
      case 'reply':
        break;
      default:
        return const CompanionReply(CompanionOutcome.error, detail: 'an unknown answer');
    }
    final v = answer['v'];
    if (v is! int || v > companionProtocolVersion) {
      return const CompanionReply(CompanionOutcome.unsupported, detail: 'another protocol version');
    }
    if (answer['id'] != id) return const CompanionReply(CompanionOutcome.error, detail: 'an answer to another request');
    final status = CompanionStatusCode.byWire(answer['status']);
    final body = decodeCompanionBody(answer['body']);
    switch (status) {
      case CompanionStatusCode.ok:
        return body == null
            ? const CompanionReply(CompanionOutcome.error, detail: 'an unreadable answer')
            : CompanionReply(CompanionOutcome.ok, body: body);
      case CompanionStatusCode.unsupported:
        return const CompanionReply(CompanionOutcome.unsupported, detail: 'the companion app does not know this');
      case CompanionStatusCode.badRequest:
        return const CompanionReply(CompanionOutcome.badRequest, detail: 'the companion app refused the request');
      case CompanionStatusCode.refused:
        return const CompanionReply(CompanionOutcome.refused, detail: 'the companion app refused C.A.W');
      case CompanionStatusCode.busy:
        return const CompanionReply(CompanionOutcome.busy, detail: 'the companion app asks to wait');
      case CompanionStatusCode.error:
      case null:
        return const CompanionReply(CompanionOutcome.error, detail: 'the companion app failed');
    }
  }
}
