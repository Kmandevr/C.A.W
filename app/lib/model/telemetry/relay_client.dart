// The caw-telemetry relay's endpoints (beta readiness plan H3, H4) over dart:io's HttpClient, behind a small
// interface so tests use a fake. Every request carries X-CAW-App-Key; nothing else identifies the device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telemetry_config.dart';

/// One answer from the relay. [status] 0 means the request never got an answer (offline, a timeout, TLS).
class RelayResponse {
  const RelayResponse(this.status, {this.body = '', this.retryAfter});
  const RelayResponse.offline() : this(0);

  final int status;
  final String body;

  /// The `Retry-After` header as a wait, when there was one.
  final Duration? retryAfter;

  bool get offline => status == 0;

  /// 429 and 503 ask the app to back off (H3, H5).
  bool get backOff => status == 429 || status == 503;

  Map<String, Object?>? get json {
    try {
      final v = jsonDecode(body);
      return v is Map<String, Object?> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

/// Sends one request. [body] is JSON text or null.
abstract class RelayHttp {
  Future<RelayResponse> send(String method, Uri url, {required Map<String, String> headers, String? body});
}

/// `Retry-After` (RFC 9110 §10.2.3): delay-seconds or an HTTP date, read against [now]. Null when absent or unreadable.
Duration? parseRetryAfter(String? value, DateTime now) {
  if (value == null) return null;
  final v = value.trim();
  final seconds = int.tryParse(v);
  if (seconds != null) return seconds < 0 ? Duration.zero : Duration(seconds: seconds);
  try {
    final at = HttpDate.parse(v);
    final d = at.difference(now);
    return d.isNegative ? Duration.zero : d;
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
    try {
      final req = await client.openUrl(method, url).timeout(_timeout);
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(_timeout);
      final chunks = <int>[];
      await for (final c in res.timeout(_timeout)) {
        chunks.addAll(c);
        if (chunks.length > _maxAnswer) break;
      }
      return RelayResponse(res.statusCode,
          body: utf8.decode(chunks, allowMalformed: true),
          retryAfter: parseRetryAfter(res.headers.value('retry-after'), _now()));
    } on SocketException {
      return const RelayResponse.offline();
    } on HandshakeException {
      return const RelayResponse.offline();
    } on HttpException {
      return const RelayResponse.offline();
    } on TimeoutException {
      return const RelayResponse.offline();
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
