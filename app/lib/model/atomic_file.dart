// Writes a file through a temporary copy and a rename, one write at a time per path.
import 'dart:io';

final Map<String, Future<void>> _pending = {};

/// Replaces [file] with [text]: written to a temporary file, then renamed over it, so a crash never leaves half a
/// file. Writes to the same path run one after another in call order (the last call's text wins); two writes sharing
/// the temporary file could otherwise interleave and leave a broken or older file.
Future<void> writeFileAtomically(File file, String text, {bool flush = true}) {
  final key = file.absolute.path;
  final previous = _pending[key] ?? Future<void>.value();
  late final Future<void> mine;
  mine = previous.catchError((Object _) {}).then((_) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: flush);
    await tmp.rename(file.path);
  }).whenComplete(() {
    if (identical(_pending[key], mine)) _pending.remove(key);
  });
  _pending[key] = mine;
  return mine;
}

/// Completes once every write [writeFileAtomically] has queued for [file] so far has landed (at once when none is).
Future<void> atomicWritesDone(File file) =>
    (_pending[file.absolute.path] ?? Future<void>.value()).catchError((Object _) {});
