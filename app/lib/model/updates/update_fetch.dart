// Network for updates: the release list (one capped JSON request, no redirects) and an asset download (https,
// allowed hosts on every redirect, a size cap, progress and cancel) over a small transport tests replace.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'releases.dart';

/// One answer from [UpdateTransport]: the status, a redirect's target, the announced length and the body.
class UpdateResponse {
  UpdateResponse({required this.status, this.location, this.length = -1, required this.body, this.close});
  final int status;
  final String? location;
  final int length;
  final Stream<List<int>> body;

  /// Drops the connection without reading the rest (a refused redirect, a cancel).
  final void Function()? close;
}

/// A GET without following redirects. Only these headers are sent: no token, nothing about the user.
abstract class UpdateTransport {
  Future<UpdateResponse> get(Uri url, {required Map<String, String> headers, required Duration timeout});
}

/// [UpdateTransport] over dart:io's HttpClient.
class IoUpdateTransport implements UpdateTransport {
  IoUpdateTransport([HttpClient? client]) : _client = client ?? HttpClient();
  final HttpClient _client;

  @override
  Future<UpdateResponse> get(Uri url, {required Map<String, String> headers, required Duration timeout}) async {
    _client.connectionTimeout = timeout;
    _client.userAgent = null; // only the header below
    final req = await _client.getUrl(url).timeout(timeout);
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(timeout);
    return UpdateResponse(
      status: res.statusCode,
      location: res.headers.value(HttpHeaders.locationHeader),
      length: res.contentLength,
      body: res,
      close: () => res.detachSocket().then((s) => s.destroy(), onError: (Object _) {}),
    );
  }
}

/// Raised for any failed update request; the check fails quietly on it.
class UpdateFetchError implements Exception {
  const UpdateFetchError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Cancels a running download ([UpdateFetcher.download]).
class DownloadCancel {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];
  bool get cancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}

/// The generic client name sent with every request (no app or user details).
const String updateUserAgent = 'CAW-app';

class UpdateFetcher {
  UpdateFetcher({UpdateTransport? transport}) : transport = transport ?? IoUpdateTransport();
  final UpdateTransport transport;

  static const timeout = Duration(seconds: 10);
  static const maxJsonBytes = 256 * 1024;
  static const maxDownloadBytes = 300 * 1024 * 1024;

  /// GETs [url] (https only, no redirects) and decodes it as JSON, refusing more than [maxJsonBytes].
  Future<Object?> getJson(Uri url) async {
    if (url.scheme != 'https') throw const UpdateFetchError('Not https');
    final UpdateResponse res;
    try {
      res = await transport.get(url,
          headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': updateUserAgent}, timeout: timeout);
    } on Object catch (e) {
      throw UpdateFetchError('Offline or unreachable ($e)');
    }
    if (res.status != 200) {
      res.close?.call();
      throw UpdateFetchError('The update source answered ${res.status}');
    }
    final bytes = await _read(res, maxJsonBytes).timeout(timeout, onTimeout: () {
      res.close?.call();
      throw const UpdateFetchError('Timed out');
    });
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const UpdateFetchError('Not JSON');
    }
  }

  Future<List<int>> _read(UpdateResponse res, int max) async {
    if (res.length > max) {
      res.close?.call();
      throw const UpdateFetchError('Too large');
    }
    final out = <int>[];
    await for (final chunk in res.body) {
      out.addAll(chunk);
      if (out.length > max) {
        res.close?.call();
        throw const UpdateFetchError('Too large');
      }
    }
    return out;
  }

  /// Downloads [url] into [to] (through a `.part` file, renamed when whole). Every hop, the first and each
  /// redirect, must pass [allowedDownload]; at most 5 redirects and [maxBytes]. [progress] gets bytes so far and
  /// the expected total (or -1). [cancel] stops it and deletes the partial file.
  Future<File> download(Uri url, File to,
      {void Function(int got, int total)? progress, DownloadCancel? cancel, int maxBytes = maxDownloadBytes}) async {
    var hop = url;
    UpdateResponse? res;
    for (var i = 0; ; i++) {
      if (!allowedDownload(hop)) throw UpdateFetchError('Download refused: ${hop.host} is not an allowed host');
      if (cancel?.cancelled ?? false) throw const DownloadCancelled();
      try {
        res = await transport.get(hop, headers: const {'User-Agent': updateUserAgent}, timeout: timeout);
      } on Object catch (e) {
        throw UpdateFetchError('Offline or unreachable ($e)');
      }
      if (res.status >= 300 && res.status < 400) {
        res.close?.call();
        final next = res.location == null ? null : hop.resolve(res.location!);
        if (next == null || i >= 5) throw const UpdateFetchError('Too many or empty redirects');
        hop = next;
        continue;
      }
      break;
    }
    final r = res;
    if (r.status != 200) {
      r.close?.call();
      throw UpdateFetchError('The download answered ${r.status}');
    }
    if (r.length > maxBytes) {
      r.close?.call();
      throw const UpdateFetchError('The download is larger than allowed');
    }
    final part = File('${to.path}.part');
    await part.parent.create(recursive: true);
    final sink = part.openWrite();
    var got = 0;
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    void stop(Object error) {
      if (done.isCompleted) return;
      done.completeError(error);
      unawaited(sub.cancel());
      r.close?.call();
    }
    cancel?._listeners.add(() => stop(const DownloadCancelled()));
    sub = r.body.listen((chunk) {
      got += chunk.length;
      if (got > maxBytes) return stop(const UpdateFetchError('The download is larger than allowed'));
      sink.add(chunk);
      progress?.call(got, r.length);
    }, onError: (Object e) => stop(UpdateFetchError('The download broke off ($e)')), onDone: () {
      if (!done.isCompleted) done.complete();
    }, cancelOnError: true);
    try {
      await done.future;
      await sink.close();
      if (r.length >= 0 && got != r.length) throw const UpdateFetchError('The download is incomplete');
      if (await to.exists()) await to.delete();
      return await part.rename(to.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }
}
