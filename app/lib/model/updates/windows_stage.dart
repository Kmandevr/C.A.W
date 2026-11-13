// A Windows small update kept beside the app (`<app folder>/.caw-update/`) until the next start, when the changed
// files are swapped in: each current file renamed aside, the new one moved into place, everything put back on any
// failure, the set-aside files deleted on a later start.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as paths;

import '../sha256.dart';
import 'patch_format.dart';

/// What the start found and did.
enum SwapResult { nothing, swapped, failed }

/// File moves, replaceable in tests (to make one fail).
typedef RenameFile = Future<void> Function(File from, String to);

Future<void> _rename(File from, String to) async => from.rename(to);

class WindowsStage {
  WindowsStage(this.installDir, {RenameFile? rename}) : _move = rename ?? _rename;

  /// The folder caw.exe runs from.
  final Directory installDir;
  final RenameFile _move;

  String get _sep => Platform.pathSeparator;
  Directory get root => Directory('${installDir.path}$_sep.caw-update');

  /// Where the new files are written before the swap (on the same drive as the app, so a move is a rename).
  Directory get files => Directory('${root.path}${_sep}files');
  File get _stage => File('${root.path}${_sep}stage.json');
  File get _swapping => File('${root.path}${_sep}swapping');
  File get _cleanup => File('${root.path}${_sep}cleanup.json');
  File get _note => File('${root.path}${_sep}note.txt');

  String _local(String rel) => '${installDir.path}$_sep${rel.replaceAll('/', _sep)}';
  String _staged(String rel) => '${files.path}$_sep${rel.replaceAll('/', _sep)}';

  /// Whether a complete update waits for the next start.
  Future<bool> get ready => _stage.exists();

  /// Starts a stage afresh (an earlier one, complete or not, is dropped).
  Future<void> begin() async {
    await clear();
    await files.create(recursive: true);
  }

  /// Marks the staged [staged] files (path → SHA-256) complete for [label]: written last, so a half-written stage is
  /// never swapped in.
  Future<void> commit(String label, Map<String, String> staged) async {
    final tmp = File('${_stage.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'caw_stage': 1,
      'label': label,
      'files': [for (final e in staged.entries) {'path': e.key, 'sha256': e.value}],
    }));
    await tmp.rename(_stage.path);
  }

  /// Drops the stage (not the cleanup list of set-aside files).
  Future<void> clear() async {
    for (final f in [_stage, File('${_stage.path}.tmp'), _swapping]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      if (await files.exists()) await files.delete(recursive: true);
    } catch (_) {}
  }

  /// The note the last swap left for this start ("Updated to …"), taken once.
  Future<String?> takeNote() async {
    try {
      if (!await _note.exists()) return null;
      final n = await _note.readAsString();
      await _note.delete();
      return n.length > 300 ? n.substring(0, 300) : n;
    } catch (_) {
      return null;
    }
  }

  Future<void> _leaveNote(String note) async {
    try {
      await root.create(recursive: true);
      await _note.writeAsString(note);
    } catch (_) {}
  }

  /// At the start: deletes files set aside by an earlier swap, then swaps a complete stage in. A stage that does not
  /// read, does not hash to its list, or a move that fails puts everything back and is dropped ([SwapResult.failed],
  /// with a note saying to download the whole update).
  Future<SwapResult> swapIn() async {
    await _deleteSetAside();
    final List<({String path, String sha256})> list;
    String label;
    try {
      if (await _swapping.exists()) {
        // The last start stopped mid-swap: put back only the files its progress lines say it began on.
        await _rollBack(await _progress());
        await clear();
        await _leaveNote('An update could not be finished, so C.A.W was left as it was. Download the full update.');
        return SwapResult.failed;
      }
      final read = await _read();
      if (read == null) {
        if (await root.exists() && await files.exists()) await clear(); // a stage that never completed
        return SwapResult.nothing;
      }
      (label, list) = read;
    } catch (_) {
      await clear();
      return SwapResult.failed;
    }
    // Every staged file still hashes to the list (off this isolate).
    final paths = [for (final f in list) _staged(f.path)];
    final hashes = await Isolate.run(() => [for (final p in paths) File(p).existsSync() ? sha256OfFileSync(p) : null]);
    for (var i = 0; i < list.length; i++) {
      if (hashes[i] != list[i].sha256) {
        await clear();
        await _leaveNote('The staged update for $label was damaged and was dropped. Download the full update.');
        return SwapResult.failed;
      }
    }
    final done = <({String path, bool added})>[];
    try {
      await _swapping.writeAsString('${jsonEncode({'label': label})}\n', flush: true);
      for (final f in list) {
        final target = File(_local(f.path));
        final aside = '${target.path}.caw-old';
        // A set-aside file from an earlier update goes before this file's progress line, so recovery never
        // mistakes it for this swap's.
        if (await File(aside).exists()) await File(aside).delete();
        await target.parent.create(recursive: true);
        final step = (path: f.path, added: !await target.exists());
        await _swapping.writeAsString('${jsonEncode({'path': step.path, 'added': step.added})}\n',
            mode: FileMode.append, flush: true);
        done.add(step);
        if (!step.added) await _move(target, aside);
        await _move(File(_staged(f.path)), target.path);
      }
    } catch (_) {
      await _rollBack(done);
      await clear();
      await _leaveNote('The update to $label could not replace C.A.W\'s files, so they were left as they were. '
          'Download the full update.');
      return SwapResult.failed;
    }
    await _remember([for (final d in done) if (!d.added) '${_local(d.path)}.caw-old']);
    await clear();
    await _leaveNote('Updated to $label (only the changed files were downloaded).');
    return SwapResult.swapped;
  }

  Future<(String, List<({String path, String sha256})>)?> _read() async {
    if (!await _stage.exists()) return null;
    final j = jsonDecode(await _stage.readAsString());
    if (j is! Map || j['caw_stage'] != 1 || j['files'] is! List) throw const FormatException('stage');
    final label = j['label'] is String ? j['label'] as String : 'the update';
    final out = <({String path, String sha256})>[];
    for (final f in (j['files'] as List).take(PatchLimits.maxFiles)) {
      if (f is! Map || f['path'] is! String || f['sha256'] is! String) throw const FormatException('stage');
      final p = f['path'] as String;
      if (!safeRelativePath(p)) throw const FormatException('stage');
      out.add((path: p, sha256: f['sha256'] as String));
    }
    return (label.length > 80 ? label.substring(0, 80) : label, out);
  }

  /// The files an interrupted swap began on, from its progress lines (a cut-off last line is skipped).
  Future<List<({String path, bool added})>> _progress() async {
    final out = <({String path, bool added})>[];
    try {
      for (final line in (await _swapping.readAsLines()).take(PatchLimits.maxFiles + 1)) {
        try {
          final j = jsonDecode(line);
          if (j is Map && j['path'] is String && j['added'] is bool && safeRelativePath(j['path'] as String)) {
            out.add((path: j['path'] as String, added: j['added'] as bool));
          }
        } on FormatException {
          // A line cut off by the stop: the file it names was not touched yet.
        }
      }
    } catch (_) {}
    return out;
  }

  /// Undoes [steps] newest first: a file new in this update is deleted, a replaced one is put back from its
  /// set-aside copy (when the stop came before it was set aside, the original is still in place).
  Future<void> _rollBack(List<({String path, bool added})> steps) async {
    for (final step in steps.reversed) {
      final target = File(_local(step.path));
      final aside = File('${target.path}.caw-old');
      try {
        if (step.added) {
          if (await target.exists()) await target.delete();
        } else if (await aside.exists()) {
          if (await target.exists()) await target.delete();
          await aside.rename(target.path);
        }
      } catch (_) {}
    }
  }

  Future<void> _remember(List<String> paths) async {
    try {
      final old = await _cleanupList();
      await _cleanup.writeAsString(jsonEncode([...old, ...paths]));
    } catch (_) {}
  }

  Future<List<String>> _cleanupList() async {
    try {
      if (!await _cleanup.exists()) return [];
      final j = jsonDecode(await _cleanup.readAsString());
      return j is List ? [for (final p in j.take(PatchLimits.maxFiles)) if (p is String && p.endsWith('.caw-old')) p] : [];
    } catch (_) {
      return [];
    }
  }

  /// Deletes the files an earlier swap set aside; one still in use (the previous process closing) waits for the next.
  Future<void> _deleteSetAside() async {
    final left = <String>[];
    final base = paths.canonicalize(installDir.path);
    for (final p in await _cleanupList()) {
      if (!paths.isWithin(base, paths.canonicalize(p))) continue; // only inside the app's folder
      try {
        if (await File(p).exists()) await File(p).delete();
      } catch (_) {
        left.add(p);
      }
    }
    try {
      if (left.isEmpty) {
        if (await _cleanup.exists()) await _cleanup.delete();
      } else {
        await _cleanup.writeAsString(jsonEncode(left));
      }
    } catch (_) {}
  }
}
