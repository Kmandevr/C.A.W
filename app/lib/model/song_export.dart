// The Export sheet's model: song-render options (source, range, format, loudness, tail, names), the engine request
// they make, and a queue of renders that survives restarts, run one after another as native worker-pool jobs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/execution.dart';

enum ExportSource {
  mix('Mix'),
  stems('Stems'),
  mixAndStems('Mix + stems');

  const ExportSource(this.label);
  final String label;
}

enum StemSet {
  tracks('Tracks'),
  buses('Buses'),
  both('Both');

  const StemSet(this.label);
  final String label;
}

enum ExportRange {
  song('Song'),
  loop('Loop'),
  selection('Selection'),
  regions('Regions');

  const ExportRange(this.label);
  final String label;
}

enum ExportLoudness {
  off('Off'),
  peak('Peak'),
  lufs('LUFS');

  const ExportLoudness(this.label);
  final String label;
}

enum ExportTail {
  none('None'),
  seconds('Seconds'),
  silence('Until silent');

  const ExportTail(this.label);
  final String label;
}

T _pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

double _num(Object? v, double fallback, double lo, double hi) =>
    v is num && v.isFinite ? v.toDouble().clamp(lo, hi).toDouble() : fallback;

/// What the sheet renders and how. The last used options are kept with the queue, so Export song repeats them.
class SongExportOptions {
  SongExportOptions({
    this.source = ExportSource.mix,
    this.stems = StemSet.tracks,
    this.range = ExportRange.song,
    this.sampleRate = 48000,
    this.bitDepth = 24,
    this.dither = true,
    this.loudness = ExportLoudness.off,
    this.peakTarget = -1.0,
    this.lufsTarget = -14.0,
    this.ceiling = -1.0,
    this.tail = ExportTail.silence,
    this.tailSeconds = 2.0,
    this.pattern = defaultPattern,
  });

  static const defaultPattern = '{project}_{region}_{stem}';
  static const sampleRates = [44100, 48000, 96000];
  static const bitDepths = [16, 24, 32];

  ExportSource source;
  StemSet stems;
  ExportRange range;
  int sampleRate, bitDepth;
  bool dither;
  ExportLoudness loudness;
  double peakTarget, lufsTarget, ceiling;
  ExportTail tail;
  double tailSeconds;
  String pattern;

  bool get mix => source != ExportSource.stems;
  bool get hasStems => source != ExportSource.mix;
  bool get tracks => hasStems && stems != StemSet.buses;
  bool get buses => hasStems && stems != StemSet.tracks;

  SongExportOptions copy() => SongExportOptions.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'source': source.name, 'stems': stems.name, 'range': range.name, 'sample_rate': sampleRate,
        'bit_depth': bitDepth, 'dither': dither, 'loudness': loudness.name, 'peak_target': peakTarget,
        'lufs_target': lufsTarget, 'ceiling': ceiling, 'tail': tail.name, 'tail_seconds': tailSeconds,
        'pattern': pattern,
      };

  static SongExportOptions fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    final rate = j['sample_rate'];
    final bits = j['bit_depth'];
    return SongExportOptions(
      source: _pick(ExportSource.values, j['source'], ExportSource.mix),
      stems: _pick(StemSet.values, j['stems'], StemSet.tracks),
      range: _pick(ExportRange.values, j['range'], ExportRange.song),
      sampleRate: rate is int && sampleRates.contains(rate) ? rate : 48000,
      bitDepth: bits is int && bitDepths.contains(bits) ? bits : 24,
      dither: j['dither'] is bool ? j['dither'] as bool : true,
      loudness: _pick(ExportLoudness.values, j['loudness'], ExportLoudness.off),
      peakTarget: _num(j['peak_target'], -1, -24, 0),
      lufsTarget: _num(j['lufs_target'], -14, -40, -5),
      ceiling: _num(j['ceiling'], -1, -12, 0),
      tail: _pick(ExportTail.values, j['tail'], ExportTail.silence),
      tailSeconds: _num(j['tail_seconds'], 2, 0, 60),
      pattern: j['pattern'] is String && (j['pattern'] as String).trim().isNotEmpty
          ? (j['pattern'] as String).trim() : defaultPattern,
    );
  }
}

/// A span of the song in sixteenth steps, named for regions.
class ExportSpan {
  const ExportSpan(this.start, this.end, [this.name = '']);
  final int start, end;
  final String name;
}

/// The engine's song-render request (docs/engine.md, "Song renders") without its `out_dir`, which the queue adds.
/// [spans] are the range's bounds: one for a selection or the loop, one per region; empty renders the whole song.
Map<String, dynamic> songRenderRequest(SongExportOptions o, {required String project, List<ExportSpan> spans = const []}) {
  final regions = o.range == ExportRange.regions;
  return {
    'project': project,
    'pattern': o.pattern,
    'mix': o.mix,
    'tracks': o.tracks,
    'buses': o.buses,
    'bounds': spans.isEmpty ? 'song' : regions ? 'regions' : 'selection',
    if (spans.isNotEmpty && !regions) ...{'start_steps': spans.first.start, 'end_steps': spans.first.end},
    if (spans.isNotEmpty && regions)
      'regions': [for (final s in spans) {'name': s.name, 'start_steps': s.start, 'end_steps': s.end}],
    'sample_rate': o.sampleRate,
    'bit_depth': o.bitDepth,
    'dither': o.dither && o.bitDepth == 16,
    'normalize': switch (o.loudness) { ExportLoudness.off => 'none', ExportLoudness.peak => 'peak', ExportLoudness.lufs => 'lufs' },
    if (o.loudness == ExportLoudness.peak) 'target': o.peakTarget,
    if (o.loudness == ExportLoudness.lufs) ...{'target': o.lufsTarget, 'ceiling': o.ceiling},
    'tail': switch (o.tail) { ExportTail.none => 'none', ExportTail.seconds => 'seconds', ExportTail.silence => 'silence' },
    if (o.tail == ExportTail.seconds) 'tail_seconds': o.tailSeconds,
  };
}

/// The file names a request will write (the engine's rule: tokens expanded, separators an empty token leaves
/// collapsed, characters other than letters, digits and . _ - # + made _, a repeat numbered _2).
List<String> previewNames(SongExportOptions o, {required String project, required List<({String name, String kind})> stems,
    List<String> regions = const ['']}) {
  final used = <String>{};
  String expand(String stem, String region, String kind, int index) {
    var s = o.pattern.replaceAll('{project}', project).replaceAll('{stem}', stem).replaceAll('{region}', region)
        .replaceAll('{kind}', kind).replaceAll('{index}', '$index');
    s = s.replaceAll(RegExp(r'[^A-Za-z0-9._#+-]'), '_').replaceAll('..', '.');
    s = s.replaceAll(RegExp(r'[_-]{2,}'), '_').replaceAll(RegExp(r'^[_.-]+|[_.-]+$'), '');
    if (s.isEmpty) s = 'export';
    var unique = s;
    for (var n = 2; used.contains(unique.toLowerCase()); n++) {
      unique = '${s}_$n';
    }
    used.add(unique.toLowerCase());
    return '$unique.wav';
  }

  final out = <String>[];
  var index = 0;
  for (final region in regions) {
    if (o.mix) out.add(expand('', region, 'mix', ++index));
    if (o.hasStems) {
      for (final stem in stems) {
        out.add(expand(stem.name, region, stem.kind, ++index));
      }
    }
  }
  return out;
}

enum ExportJobState { queued, running, done, failed, cancelled }

class ExportedFile {
  const ExportedFile({required this.name, required this.path, this.kind = 'mix', this.region = '', this.frames = 0,
      this.peakDb = -200, this.lufs = -200});
  final String name, path, kind, region;
  final int frames;
  final double peakDb, lufs;

  Map<String, dynamic> toJson() =>
      {'name': name, 'path': path, 'kind': kind, 'region': region, 'frames': frames, 'peak_db': peakDb, 'lufs': lufs};

  static ExportedFile? fromJson(Object? raw) {
    if (raw is! Map || raw['name'] is! String || raw['path'] is! String) return null;
    return ExportedFile(
      name: raw['name'] as String,
      path: raw['path'] as String,
      kind: raw['kind'] as String? ?? 'mix',
      region: raw['region'] as String? ?? '',
      frames: (raw['frames'] as num?)?.toInt() ?? 0,
      peakDb: (raw['peak_db'] as num?)?.toDouble() ?? -200,
      lufs: (raw['lufs'] as num?)?.toDouble() ?? -200,
    );
  }
}

/// One render in the queue: a snapshot of the project as it was queued and the request.
class ExportJob {
  ExportJob({required this.id, required this.title, required this.projectJson, required this.request,
      required this.createdMs, this.state = ExportJobState.queued, this.error, List<ExportedFile>? files})
      : files = files ?? [];
  final String id, title, projectJson;
  final Map<String, dynamic> request;
  final int createdMs;
  ExportJobState state;
  String? error;
  List<ExportedFile> files;

  /// 0..1 while it runs (not saved).
  double progress = 0;

  bool get finished => state == ExportJobState.done || state == ExportJobState.failed || state == ExportJobState.cancelled;

  Map<String, dynamic> toJson() => {
        'id': id, 'title': title, 'project': projectJson, 'request': request, 'created_ms': createdMs,
        'state': state.name, if (error != null) 'error': error, 'files': [for (final f in files) f.toJson()],
      };

  static ExportJob? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['project'] is! String || raw['request'] is! Map) return null;
    var state = _pick(ExportJobState.values, raw['state'], ExportJobState.queued);
    // A render the app closed during starts again.
    if (state == ExportJobState.running) state = ExportJobState.queued;
    return ExportJob(
      id: raw['id'] as String,
      title: raw['title'] as String? ?? 'Export',
      projectJson: raw['project'] as String,
      request: Map<String, dynamic>.from(raw['request'] as Map),
      createdMs: (raw['created_ms'] as num?)?.toInt() ?? 0,
      state: state,
      error: raw['error'] as String?,
      files: [for (final f in (raw['files'] is List ? raw['files'] as List : const [])) ?ExportedFile.fromJson(f)],
    );
  }
}

/// A running render: its progress (0..1), a way to stop it, and the engine's result (JSON, or an error message).
abstract class SongRenderHandle {
  double get progress;
  void cancel();
  Future<String?> get result;
}

class _NativeSongRender implements SongRenderHandle {
  _NativeSongRender(this._job);
  final NativeEngineJob _job;
  @override
  double get progress => _job.progress;
  @override
  void cancel() => _job.cancel();
  @override
  Future<String?> get result => _job.result;
}

typedef SongRenderStarter = SongRenderHandle Function(String projectJson, String requestJson);

SongRenderHandle startNativeSongRender(String projectJson, String requestJson) =>
    _NativeSongRender(NativeEngineWorkPool.shared.submitSong(projectJson: projectJson, requestJson: requestJson));

/// The export queue: renders run one after another off the UI isolate (native worker-pool jobs), each into its own
/// folder under [root]; the queue, the results and the last options are saved in `queue.json` there, so queued
/// renders and finished files survive a restart.
class ExportQueue extends ChangeNotifier {
  ExportQueue(this.root, {SongRenderStarter? starter}) : _start = starter ?? startNativeSongRender;

  static const maxJobs = 50;

  final Directory root;
  final SongRenderStarter _start;
  final List<ExportJob> jobs = [];
  SongExportOptions last = SongExportOptions();

  /// Options were used before ([last] holds them), so the sheet opens with them instead of Settings' defaults.
  bool hasLast = false;
  bool _loaded = false;
  SongRenderHandle? _running;
  ExportJob? _runningJob;
  Timer? _poll;
  Future<void> _writing = Future.value();
  int _counter = 0;

  /// Called with a job when it ends (done, failed or cancelled): the sheet's haptics and message.
  void Function(ExportJob job)? onFinished;

  File get _file => File('${root.path}${Platform.pathSeparator}queue.json');
  bool get busy => _runningJob != null;
  ExportJob? get runningJob => _runningJob;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString());
        if (j is Map) {
          last = SongExportOptions.fromJson(j['last']);
          hasLast = j['last'] is Map;
          jobs
            ..clear()
            ..addAll([for (final x in (j['jobs'] is List ? j['jobs'] as List : const [])) ?ExportJob.fromJson(x)]);
        }
      }
    } catch (_) {
      // A damaged queue file starts an empty queue; the renders' folders stay on disk.
    }
    notifyListeners();
    _next();
  }

  Future<void> _save() {
    final text = jsonEncode({'version': 1, 'last': last.toJson(), 'jobs': [for (final j in jobs) j.toJson()]});
    return _writing = _writing.then((_) async {
      try {
        await root.create(recursive: true);
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(_file.path);
      } catch (_) {
        // Saving the queue is best effort; the renders themselves are not affected.
      }
    });
  }

  /// Saves [options] as the ones Export song repeats.
  Future<void> remember(SongExportOptions options) {
    last = options.copy();
    hasLast = true;
    return _save();
  }

  /// Queues a render (and starts it when nothing else runs); false when the queue is full.
  bool add({required String title, required String projectJson, required Map<String, dynamic> request}) {
    if (jobs.where((j) => !j.finished).length >= maxJobs) return false;
    final id = '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${(_counter++).toRadixString(36)}';
    jobs.add(ExportJob(id: id, title: title, projectJson: projectJson, request: request,
        createdMs: DateTime.now().millisecondsSinceEpoch));
    notifyListeners();
    _save();
    _next();
    return true;
  }

  /// Stops a running render or takes a queued one off the queue (marked cancelled).
  void cancel(ExportJob job) {
    if (job == _runningJob) {
      _running?.cancel();
      return;
    }
    if (job.state == ExportJobState.queued) {
      job.state = ExportJobState.cancelled;
      notifyListeners();
      _save();
    }
  }

  /// Cancels everything queued and the running render.
  void cancelAll() {
    for (final j in jobs) {
      if (j.state == ExportJobState.queued) j.state = ExportJobState.cancelled;
    }
    _running?.cancel();
    notifyListeners();
    _save();
  }

  /// Puts a failed or cancelled render back on the queue.
  void retry(ExportJob job) {
    if (!job.finished || job.state == ExportJobState.done) return;
    job
      ..state = ExportJobState.queued
      ..error = null;
    notifyListeners();
    _save();
    _next();
  }

  /// Removes a finished render and its files.
  Future<void> remove(ExportJob job) async {
    if (!job.finished) return;
    jobs.remove(job);
    notifyListeners();
    await _save();
    try {
      final dir = Directory('${root.path}${Platform.pathSeparator}${job.id}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // A file another app holds open stays until the next clear.
    }
  }

  /// Removes every finished render.
  Future<void> clearFinished() async {
    for (final j in [...jobs.where((j) => j.finished)]) {
      await remove(j);
    }
  }

  void _next() {
    if (_runningJob != null) return;
    final job = jobs.where((j) => j.state == ExportJobState.queued).firstOrNull;
    if (job == null) return;
    _run(job);
  }

  Future<void> _run(ExportJob job) async {
    _runningJob = job;
    job
      ..state = ExportJobState.running
      ..progress = 0
      ..error = null;
    notifyListeners();
    String? out;
    try {
      final dir = Directory('${root.path}${Platform.pathSeparator}${job.id}');
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      final request = {...job.request, 'out_dir': dir.path};
      final handle = _start(job.projectJson, jsonEncode(request));
      _running = handle;
      _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
        job.progress = handle.progress;
        notifyListeners();
      });
      out = await handle.result;
    } catch (e) {
      out = '$e';
    } finally {
      _poll?.cancel();
      _poll = null;
      _running = null;
    }
    Object? parsed;
    try {
      parsed = out == null ? null : jsonDecode(out);
    } catch (_) {
      parsed = null;
    }
    if (parsed is Map && parsed['ok'] == true) {
      job
        ..state = ExportJobState.done
        ..progress = 1
        ..files = [for (final f in (parsed['files'] is List ? parsed['files'] as List : const [])) ?ExportedFile.fromJson(f)];
    } else {
      final message = parsed is Map ? parsed['error'] as String? : out;
      job
        ..state = message == 'cancelled' ? ExportJobState.cancelled : ExportJobState.failed
        ..error = message == 'cancelled' ? null : (message ?? 'the render failed');
    }
    _runningJob = null;
    notifyListeners();
    await _save();
    onFinished?.call(job);
    _next();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

ExportQueue? _shared;

/// The app's export queue, in the app's support folder (`exports/`), loaded on first use.
Future<ExportQueue> sharedExportQueue() async {
  if (_shared != null) return _shared!;
  final support = await getApplicationSupportDirectory();
  final queue = ExportQueue(Directory('${support.path}${Platform.pathSeparator}exports'));
  _shared = queue;
  await queue.load();
  return queue;
}
