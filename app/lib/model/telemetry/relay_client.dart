// The caw-telemetry relay's endpoints (beta readiness plan H3, H4) over dart:io's HttpClient, behind a small
// interface so tests use a fake. Every request carries X-CAW-App-Key; nothing else identifies the device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telemetry_config.dart';

/// One answer from the relay. [status] 0 means the request never got an answer (offline, a timeout, TLS).
class RelayResponse {
  const RelayResponse(this.status, {this.body = '', this.retryAfter, this.sentBody = true});

  /// No answer. [sentBody]: whether the request had gone out whole first (a timeout waiting for the answer), so the
  /// relay may have it; false for a DNS failure or a refused connection.
  const RelayResponse.offline({bool sentBody = false}) : this(0, sentBody: sentBody);

  final int status;
  final bool sentBody;

  /// Whether this try could have reached the relay (an answer, or a request that went out whole).
  bool get mayHaveArrived => status != 0 || sentBody;
  final String body;

  /// The `Retry-After` header as a wait, when there was one.
  final Duration? retryAfter;

  bool get offline => status == 0;

  /// 429 and 503 ask the app to back off (H3, H5).
  bool get backOff => status == 429 || status == 503;

  Map<String, Object?>? get json {
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }
}

/// Sends one request. [body] is JSON text or null.
abstract class RelayHttp {
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body});
}

/// The longest wait a relay can ask for; anything longer is cut to it.
const maxRetryAfter = Duration(hours: 24);

/// `Retry-After` (RFC 9110 §10.2.3): delay-seconds or an HTTP date, read against [now], held between none and
/// [maxRetryAfter] (a number too big for an int counts as the most). Null when absent or unreadable.
Duration? parseRetryAfter(String? value, DateTime now) {
  if (value == null) return null;
  final v = value.trim();
  if (RegExp(r'^\d+$').hasMatch(v)) {
    final seconds = v.length > 9 ? null : int.parse(v);
    if (seconds == null || seconds >= maxRetryAfter.inSeconds) return maxRetryAfter;
    return Duration(seconds: seconds);
  }
  try {
    final d = HttpDate.parse(v).difference(now);
    if (d.isNegative) return Duration.zero;
    return d > maxRetryAfter ? maxRetryAfter : d;
  } catch (_) {
    return null;
  }
}

/// The real transport: HTTPS through dart:io, 20 s at most per request, answers cut at 64 KB.
class IoRelayHttp implements RelayHttp {
  IoRelayHttp({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  static const _timeout = Duration(seconds: 20);
  static const _maxAnswer = 64 * 1024;

  @override
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body}) async {
    if (url.scheme != 'https') return const RelayResponse.offline();
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..userAgent = 'caw-app';
    var sent = false;
    try {
      final req = await client.openUrl(method, url).timeout(_timeout);
      // A redirect is never followed (the request would go somewhere the build didn't name): its 3xx is a failure.
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final answer = req.close();
      sent = true; // from here the relay may have the request, whatever happens to the answer
      final res = await answer.timeout(_timeout);
      final chunks = <int>[];
      await for (final c in res.timeout(_timeout)) {
        chunks.addAll(c);
        if (chunks.length > _maxAnswer) break;
      }
      return RelayResponse(res.statusCode,
          body: utf8.decode(chunks, allowMalformed: true),
          retryAfter: parseRetryAfter(res.headers.value('retry-after'), _now()));
    } on SocketException {
      return RelayResponse.offline(sentBody: sent);
    } on HandshakeException {
      return const RelayResponse.offline();
    } on HttpException {
      return RelayResponse.offline(sentBody: sent);
    } on TimeoutException {
      return RelayResponse.offline(sentBody: sent);
    } on TlsException {
      return const RelayResponse.offline();
    } finally {
      client.close(force: true);
    }
  }
}

/// H3 and H4 as calls.
class RelayClient {
  RelayClient(this.config, this.http);
  final TelemetryConfig config;
  final RelayHttp http;

  Map<String, String> get _headers => {'X-CAW-App-Key': config.appKey, 'Accept': 'application/json'};

  Future<RelayResponse> _call(String method, String path, [String? body]) => config.canSend
      ? http.send(method, config.endpoint(path), headers: _headers, body: body)
      : Future.value(const RelayResponse.offline());

  /// H3 `POST /v1/report`: 202 accepted.
  Future<RelayResponse> postReport(String json) => _call('POST', '/v1/report', json);

  /// H3 `GET /v1/report/<receipt>`: 200 published, 202 queued, 404 unknown or deleted.
  Future<RelayResponse> getReport(String receipt) => _call('GET', '/v1/report/$receipt');

  /// H3 `POST /v1/delete` with up to 100 items: 202 `{"deleted":n}`.
  Future<RelayResponse> delete(List<({String receipt, String deleteKey})> items) => _call('POST', '/v1/delete',
      jsonEncode({'items': [for (final i in items) {'receipt': i.receipt, 'deleteKey': i.deleteKey}]}));

  /// H4 `POST /v1/feedback`: 201 `{"issue":url}`, 202 queued.
  Future<RelayResponse> postFeedback(String json) => _call('POST', '/v1/feedback', json);
}
