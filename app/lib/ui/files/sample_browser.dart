// Files › Samples (#229): linked folders' samples as rows with a waveform, tempo and key, filters, and the preview strip (tap previews, double tap adds).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../engine/sample_preview_io.dart';
import '../../model/app_state.dart';
import '../../model/audio_edit.dart';
import '../../model/device_target.dart';
import '../../model/music_key.dart';
import '../../model/project.dart' show LayerDoc;
import '../../model/sample_library.dart';
import '../../model/sample_names.dart';
import '../../model/sample_use.dart';
import '../arrange/audio_waveform.dart';
import '../devices/drums/drums_pads.dart' show DrumsSelection;
import '../frame/sections.dart' show AssetDrag, AssetKind;
import '../glass.dart';
import '../motion.dart';
import '../pointer_input.dart';
import '../theme.dart';
import '../tokens.dart';
import 'asset_views.dart' show MenuEntry, showCompactMenu;
import '../crow.dart';

/// The selected pad of a track's Drums, for the double tap's target.
int? selectedDrumPad(AppState state, LayerDoc layer) =>
    DrumsSelection.of(DeviceTarget(state, layer.id, DeviceTarget.instrumentSlot)).pad.value;

/// "1:05", "0.42 s".
String sampleLength(double? s, {bool approx = false}) {
  if (s == null) return '';
  final t = s < 10 ? '${s.toStringAsFixed(2)} s' : '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';
  return approx ? '~$t' : t;
}

String _bpmText(double bpm) => bpm == bpm.roundToDouble() ? bpm.toStringAsFixed(0) : bpm.toStringAsFixed(1);

/// The sample browser: [folderId] is one linked folder (null: all of them).
class SampleBrowserView extends StatefulWidget {
  const SampleBrowserView({super.key, required this.state, this.folderId});
  final AppState state;
  final String? folderId;

  @override
  State<SampleBrowserView> createState() => _SampleBrowserViewState();
}

class _SampleBrowserViewState extends State<SampleBrowserView> with SingleTickerProviderStateMixin {
  final _q = SampleQuery();
  final _search = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Samples');
  final _scroll = ScrollController();
  final _preview = ValueNotifier<PreviewState>(const PreviewState());
  late final Ticker _ticker = createTicker((_) => _poll());
  List<SampleEntry> _shown = const [];
  SampleEntry? _current;
  int _playingSeq = -1;
  bool _sync = true;
  static double _volume = 0.8;

  /// Preview through the selected track's effects (owner, 2026-11-17: optional, off by default).
  static bool _throughTrack = false;
  Timer? _changeSoon;
  DateTime _changedAt = DateTime(0);
  String? _message;
  Timer? _saveSoon;

  AppState get state => widget.state;
  SampleLibrary get lib => state.sampleLibrary;

  static const rowHeight = 56.0;

  @override
  void initState() {
    super.initState();
    lib.addListener(_libraryChanged);
    unawaited(lib.load().then((_) => _recompute()));
    _recompute();
  }

  @override
  void didUpdateWidget(SampleBrowserView old) {
    super.didUpdateWidget(old);
    if (old.folderId != widget.folderId) {
      _q.folder = null;
      _recompute();
    }
  }

  @override
  void dispose() {
    lib.removeListener(_libraryChanged);
    if (_playingSeq > 0) _stop();
    _ticker.dispose();
    _saveSoon?.cancel();
    _changeSoon?.cancel();
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    _preview.dispose();
    super.dispose();
  }

  /// Indexing a big folder reports every batch: the list is filtered and sorted again at most every 300 ms (the
  /// first change at once, the last one always).
  void _libraryChanged() {
    if (!mounted) return;
    const gap = Duration(milliseconds: 300);
    final now = DateTime.now();
    if (_changeSoon == null && now.difference(_changedAt) >= gap) {
      _changedAt = now;
      setState(_recompute);
      return;
    }
    _changeSoon ??= Timer(gap, () {
      _changeSoon = null;
      _changedAt = DateTime.now();
      if (mounted) setState(_recompute);
    });
  }

  /// The track the preview goes through when [_throughTrack] is on: the selected one, unless it is a folder.
  String? get _throughLayer {
    if (!_throughTrack) return null;
    final l = state.project.layers.where((l) => l.id == state.selectedLayerId).firstOrNull;
    return l == null || l.isFolder ? null : l.id;
  }

  Iterable<SampleEntry> get _all => widget.folderId == null ? lib.allEntries : lib.entries(widget.folderId!);

  void _recompute() {
    _shown = _q.apply(_all);
  }

  void _query(void Function() change) => setState(() {
        change();
        _recompute();
      });

  // ---------- preview ----------

  void _poll() {
    final s = state.samplePreview.state();
    _preview.value = s;
    if (!s.playing && s.seq >= _playingSeq && _playingSeq > 0) {
      _ticker.stop();
      state.samplePreviewing = false;
      _playingSeq = -1;
      setState(() {});
    }
  }

  bool _isPlaying(SampleEntry e) => identical(_current, e) && _playingSeq > 0;

  Future<void> _play(SampleEntry e, {double start = 0}) async {
    setState(() {
      _current = e;
      _message = null;
    });
    if (state.engine != null) {
      final error = state.openAudioForPreview();
      if (error != null) return _say(error);
    }
    final path = await lib.pathOf(e);
    if (!mounted || !identical(_current, e)) return;
    if (path == null) return _say('${e.name} can\'t be reached: is its folder still there?');
    final ratio = previewRatio(e, state.project.bpm, sync: _sync);
    final sync = _sync && state.transportOn ? (e.kind == SampleKind.loop ? 'bar' : 'beat') : 'now';
    state.samplePreviewing = true;
    final r = await state.samplePreview.play(path, startSeconds: start, ratio: ratio, sync: sync,
        loop: e.kind == SampleKind.loop, volume: _volume, layer: _throughLayer);
    if (!mounted) return;
    if (r['ok'] != true) {
      state.samplePreviewing = false;
      return _say('Can\'t play ${e.name}: ${r['error'] ?? 'unknown error'}');
    }
    final secs = r['seconds'];
    if (secs is num && secs > 0 && (e.seconds == null || e.secondsApprox)) {
      e.seconds = secs.toDouble();
      e.secondsApprox = false;
      if (e.kind == null) inferKindFromLength(e);
    }
    // The engine numbers each start; the ticker stops once that start has finished playing.
    final seq = r['seq'];
    _playingSeq = seq is int && seq > 0 ? seq : state.samplePreview.state().seq + 1;
    if (!_ticker.isActive) unawaited(_ticker.start());
    setState(() {});
    // What the names and metadata didn't give, estimated from the audio now that it is loaded.
    unawaited(state.detectSampleValues([e], limit: 1).then((_) => _saveIndexSoon(e.root)));
  }

  void _saveIndexSoon(String root) {
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(seconds: 2), () => lib.saveIndex(root));
  }

  void _stop() {
    state.samplePreview.stop();
    state.samplePreviewing = false;
    _playingSeq = -1;
    if (_ticker.isActive) _ticker.stop();
  }

  void _toggle(SampleEntry e) {
    if (_isPlaying(e)) {
      setState(_stop);
    } else {
      unawaited(_play(e));
    }
  }

  /// Auto-play next: the arrow keys and a swipe on the strip.
  void _step(int by) {
    if (_shown.isEmpty) return;
    final at = _current == null ? -1 : _shown.indexOf(_current!);
    final next = (at + by).clamp(0, _shown.length - 1);
    if (next == at) return;
    final e = _shown[next];
    unawaited(_play(e));
    // Keep it in view.
    if (_scroll.hasClients) {
      final top = next * rowHeight, view = _scroll.position.viewportDimension;
      final off = _scroll.offset;
      if (top < off || top + rowHeight > off + view) {
        final to = (top - view / 2 + rowHeight / 2).clamp(0.0, _scroll.position.maxScrollExtent);
        final d = Motion.move(Motion.standard, Motion.of(context));
        d == Duration.zero ? _scroll.jumpTo(to) : _scroll.animateTo(to, duration: d, curve: Curves.easeOut);
      }
    }
  }

  void _say(String text) {
    if (!mounted) return;
    setState(() => _message = text);
  }

  // ---------- adding ----------

  SampleTarget get _target => state.sampleTarget(selectedPad: (l) => selectedDrumPad(state, l));

  Future<void> _add(SampleEntry e) async {
    Motion.tick();
    final line = await state.addSample(e, _target);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(line), duration: const Duration(seconds: 2)));
    setState(() {});
  }

  Future<void> _menu(SampleEntry e, Offset at) async {
    Motion.tick();
    final choice = await showCompactMenu<String>(context, at, [
      MenuEntry('add', Icons.add_circle_outline, _target.label),
      MenuEntry('preview', _isPlaying(e) ? Icons.stop : Icons.play_arrow, _isPlaying(e) ? 'Stop preview' : 'Preview'),
      if (e.folder.isNotEmpty) MenuEntry('folder', Icons.folder_open, 'Show its folder'),
      MenuEntry('similar', Icons.tune, 'Same key and tempo'),
    ]);
    if (!mounted) return;
    switch (choice) {
      case 'add':
        await _add(e);
      case 'preview':
        _toggle(e);
      case 'folder':
        _query(() => _q.folder = e.folder);
      case 'similar':
        _query(() {
          _q.keys
            ..clear()
            ..addAll([?e.key]);
          _q.keyMatch = KeyMatch.compatible;
          if (e.bpm != null) {
            _q.bpmMin = e.bpm! - 3;
            _q.bpmMax = e.bpm! + 3;
          }
        });
    }
  }

  // ---------- linking ----------

  Future<void> _link() async {
    final (lf, error) = await lib.linkPicked();
    if (!mounted) return;
    if (error != null) _say(error);
    if (lf != null) _say('Linked ${lf.name}: reading its files…');
  }

  Future<void> _refresh() async {
    final ids = widget.folderId == null ? [for (final f in lib.folders) f.id] : [widget.folderId!];
    await Future.wait(ids.map(lib.refresh));
  }

  // ---------- building ----------

  @override
  Widget build(BuildContext context) {
    final folders = lib.folders;
    if (folders.isEmpty) return _empty();
    final lf = widget.folderId == null ? null : lib.folder(widget.folderId!);
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
          _step(1);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
          _step(-1);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.space && _current != null) {
          _toggle(_current!);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.enter && _current != null) {
          unawaited(_add(_current!));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(children: [
        _header(),
        _filterBar(),
        _status(lf),
        Expanded(child: _list()),
        _strip(),
      ]),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_special_outlined, size: 40, color: Neon.dim),
            const SizedBox(height: Space.m),
            const Text('Link a folder of samples. Every project sees it, and its files are used where they are (nothing '
                'is copied).', textAlign: TextAlign.center, style: TextStyle(color: Neon.dim, fontSize: TypeScale.label)),
            const SizedBox(height: Space.m),
            FilledButton.icon(key: const ValueKey('samples-link'), onPressed: _link,
                icon: const Icon(Icons.create_new_folder_outlined), label: const Text('Link folder…')),
            if (_message != null) ...[
              const SizedBox(height: Space.s),
              Text(_message!, style: const TextStyle(color: Neon.yellow, fontSize: TypeScale.label)),
            ],
          ]),
        ),
      );

  Widget _header() => SizedBox(
        height: 44,
        child: Row(children: [
          const SizedBox(width: Space.s),
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                key: const ValueKey('samples-search'),
                controller: _search,
                style: const TextStyle(fontSize: TypeScale.label),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search samples',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(tooltip: 'Clear search', iconSize: 14, icon: const Icon(Icons.close),
                          onPressed: () => _query(() {
                                _q.text = '';
                                _search.clear();
                              })),
                  contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.s)),
                ),
                onChanged: (v) => _query(() => _q.text = v),
              ),
            ),
          ),
          Builder(builder: (c) => IconButton(
                key: const ValueKey('samples-sort'),
                tooltip: 'Sort: ${_sortLabel(_q.sort)}',
                icon: const Icon(Icons.sort, size: 20),
                onPressed: () async {
                  final box = c.findRenderObject() as RenderBox;
                  final next = await showCompactMenu<SampleSort>(context, box.localToGlobal(box.size.bottomLeft(Offset.zero)), [
                    for (final s in SampleSort.values) MenuEntry(s, s == _q.sort ? Icons.check : Icons.sort, _sortLabel(s)),
                  ]);
                  if (next == null || !mounted) return;
                  _query(() {
                    _q.descending = next == _q.sort ? !_q.descending : false;
                    _q.sort = next;
                  });
                },
              )),
          IconButton(
            key: const ValueKey('samples-link-more'),
            tooltip: 'Link folder…',
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            onPressed: _link,
          ),
          const SizedBox(width: Space.xs),
        ]),
      );

  static String _sortLabel(SampleSort s) => switch (s) {
        SampleSort.name => 'Name',
        SampleSort.bpm => 'Tempo',
        SampleSort.key => 'Key',
        SampleSort.type => 'Type',
        SampleSort.instrument => 'Instrument',
        SampleSort.length => 'Length',
        SampleSort.folder => 'Folder',
        SampleSort.recent => 'Newest',
      };

  // ---------- filters ----------

  Widget _chip(String key, String label, bool on, VoidCallback onTap, {VoidCallback? onClear}) => Padding(
        padding: const EdgeInsets.only(right: Space.xs),
        child: InputChip(
          key: ValueKey('samples-filter-$key'),
          label: Text(label, style: const TextStyle(fontSize: TypeScale.label)),
          selected: on,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onPressed: onTap,
          onDeleted: on ? onClear : null,
          deleteIconColor: Neon.dim,
        ),
      );

  Widget _filterBar() {
    final bpm = _q.bpmMin == null && _q.bpmMax == null
        ? 'BPM'
        : '${_q.bpmMin == null ? '' : _bpmText(_q.bpmMin!)}–${_q.bpmMax == null ? '' : _bpmText(_q.bpmMax!)} BPM';
    final key = _q.keys.isEmpty
        ? 'Key'
        : '${_q.keys.map((k) => k.short).take(2).join(', ')}${_q.keys.length > 2 ? '…' : ''}'
            '${_q.keyMatch == KeyMatch.exact ? '' : _q.keyMatch == KeyMatch.relative ? ' +rel' : ' +compatible'}';
    String setLabel<T>(Set<T> s, String none, String Function(T) name) =>
        s.isEmpty ? none : '${s.map(name).take(2).join(', ')}${s.length > 2 ? '…' : ''}';
    final length = _q.minSeconds == null && _q.maxSeconds == null
        ? 'Length'
        : '${_q.minSeconds == null ? '' : sampleLength(_q.minSeconds)}–${_q.maxSeconds == null ? '' : sampleLength(_q.maxSeconds)}';
    return SizedBox(
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        child: Row(children: [
          _chip('bpm', bpm, _q.bpmMin != null || _q.bpmMax != null, _bpmSheet,
              onClear: () => _query(() => _q.bpmMin = _q.bpmMax = null)),
          _chip('key', key, _q.keys.isNotEmpty, _keySheet, onClear: () => _query(_q.keys.clear)),
          _chip('type', setLabel(_q.kinds, 'Type', (k) => k == SampleKind.loop ? 'Loop' : 'One-shot'), _q.kinds.isNotEmpty,
              () => _pickSet<SampleKind>('Type', SampleKind.values, _q.kinds, (k) => k == SampleKind.loop ? 'Loop' : 'One-shot'),
              onClear: () => _query(_q.kinds.clear)),
          _chip('instrument', setLabel(_q.instruments, 'Instrument', (i) => i.label), _q.instruments.isNotEmpty,
              () => _pickSet<SampleInstrument>('Instrument', SampleInstrument.values, _q.instruments, (i) => i.label),
              onClear: () => _query(_q.instruments.clear)),
          _chip('length', length, _q.minSeconds != null || _q.maxSeconds != null, _lengthSheet,
              onClear: () => _query(() => _q.minSeconds = _q.maxSeconds = null)),
          _chip('folder', _q.folder?.isNotEmpty ?? false ? _q.folder!.split('/').last : 'Folder',
              _q.folder?.isNotEmpty ?? false, _folderSheet, onClear: () => _query(() => _q.folder = null)),
          _chip('tags', setLabel(_q.tags, 'Tags', (t) => t), _q.tags.isNotEmpty, () {
            final tags = filterChoices(_all).tags.toList()..sort();
            _pickSet<String>('Tags', tags, _q.tags, (t) => t);
          }, onClear: () => _query(_q.tags.clear)),
          Padding(
            padding: const EdgeInsets.only(right: Space.xs),
            child: FilterChip(
              key: const ValueKey('samples-filter-estimates'),
              label: const Text('Estimates', style: TextStyle(fontSize: TypeScale.label)),
              tooltip: 'Let estimated tempos and keys pass the filters',
              selected: _q.estimates,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onSelected: (v) => _query(() => _q.estimates = v),
            ),
          ),
          if (_q.active)
            TextButton(key: const ValueKey('samples-filter-clear'), onPressed: () => _query(() {
                  _q.clear();
                  _search.clear();
                }), child: const Text('Clear')),
        ]),
      ),
    );
  }

  Future<T?> _sheet<T>(String title, Widget Function(BuildContext, StateSetter) body) => showModalBottomSheet<T>(
        context: context,
        backgroundColor: Neon.panel,
        isScrollControlled: true,
        builder: (c) => SafeArea(
          child: StatefulBuilder(builder: (c, set) => Padding(
                padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.l),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title.toUpperCase(), style: TypeScale.heading()),
                  const SizedBox(height: Space.s),
                  Flexible(child: SingleChildScrollView(child: body(c, set))),
                ]),
              )),
        ),
      );

  void _pickSet<T>(String title, List<T> all, Set<T> chosen, String Function(T) label) {
    _sheet<void>(title, (c, set) => Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
          for (final v in all)
            FilterChip(
              label: Text(label(v)),
              selected: chosen.contains(v),
              showCheckmark: false,
              onSelected: (on) {
                set(() => on ? chosen.add(v) : chosen.remove(v));
                _query(() {});
              },
            ),
        ]));
  }

  void _bpmSheet() {
    final choices = filterChoices(_all);
    final lo = (choices.minBpm ?? 60).floorToDouble(), hi = math.max(lo + 1, (choices.maxBpm ?? 180).ceilToDouble());
    var range = RangeValues((_q.bpmMin ?? lo).clamp(lo, hi), (_q.bpmMax ?? hi).clamp(lo, hi));
    _sheet<void>('Tempo', (c, set) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_bpmText(range.start)}–${_bpmText(range.end)} BPM', style: TypeScale.number(size: TypeScale.body)),
          RangeSlider(
            values: range, min: lo, max: hi, divisions: (hi - lo).round().clamp(1, 1000),
            onChanged: (v) {
              set(() => range = v);
              _query(() {
                _q.bpmMin = v.start;
                _q.bpmMax = v.end;
              });
            },
          ),
          Wrap(spacing: Space.xs, children: [
            for (final b in [state.project.bpm])
              ActionChip(label: Text('Project ${_bpmText(b)} ±3'), onPressed: () {
                set(() => range = RangeValues((b - 3).clamp(lo, hi), (b + 3).clamp(lo, hi)));
                _query(() {
                  _q.bpmMin = b - 3;
                  _q.bpmMax = b + 3;
                });
              }),
            FilterChip(label: const Text('Half and double'), selected: _q.halfDouble, showCheckmark: false,
                onSelected: (v) {
                  set(() {});
                  _query(() => _q.halfDouble = v);
                }),
          ]),
        ]));
  }

  void _keySheet() {
    _sheet<void>('Key', (c, set) {
      Widget keyChip(MusicalKey k) => FilterChip(
            label: Text(k.short),
            selected: _q.keys.contains(k),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (on) {
              set(() => on ? _q.keys.add(k) : _q.keys.remove(k));
              _query(() {});
            },
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SegmentedButton<KeyMatch>(
          segments: const [
            ButtonSegment(value: KeyMatch.exact, label: Text('Exact')),
            ButtonSegment(value: KeyMatch.relative, label: Text('+ Relative')),
            ButtonSegment(value: KeyMatch.compatible, label: Text('+ Compatible')),
          ],
          selected: {_q.keyMatch},
          onSelectionChanged: (s) {
            set(() {});
            _query(() => _q.keyMatch = s.first);
          },
        ),
        const SizedBox(height: Space.s),
        Text('MAJOR', style: TypeScale.heading()),
        Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [for (final k in MusicalKey.all.where((k) => !k.minor)) keyChip(k)]),
        const SizedBox(height: Space.s),
        Text('MINOR', style: TypeScale.heading()),
        Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [for (final k in MusicalKey.all.where((k) => k.minor)) keyChip(k)]),
      ]);
    });
  }

  void _lengthSheet() {
    const presets = [(null, 1.0, 'Under 1 s'), (null, 4.0, 'Under 4 s'), (4.0, 30.0, '4–30 s'), (30.0, null, 'Over 30 s')];
    _sheet<void>('Length', (c, set) => Wrap(spacing: Space.xs, runSpacing: Space.xs, children: [
          for (final (lo, hi, label) in presets)
            ChoiceChip(
              label: Text(label),
              selected: _q.minSeconds == lo && _q.maxSeconds == hi,
              onSelected: (on) {
                set(() {});
                _query(() {
                  _q.minSeconds = on ? lo : null;
                  _q.maxSeconds = on ? hi : null;
                });
              },
            ),
        ]));
  }

  void _folderSheet() {
    final all = filterChoices(_all).folders;
    _sheet<void>('Folder', (c, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final f in all.take(400))
            ListTile(
              dense: true,
              title: Text(f, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: _q.folder == f,
              onTap: () {
                Navigator.pop(c);
                _query(() => _q.folder = f);
              },
            ),
        ]));
  }

  // ---------- status, list and strip ----------

  Widget _status(LinkedFolder? lf) {
    final ids = lf == null ? [for (final f in lib.folders) f.id] : [lf.id];
    final p = [for (final id in ids) ?lib.progress[id]];
    final running = p.where((x) => x.running).toList();
    final errors = [for (final x in p) ?x.error];
    final truncated = p.any((x) => x.truncated);
    final total = _all.length;
    final parts = <String>[
      '${_shown.length == total ? '$total' : '${_shown.length} of $total'} sample${total == 1 ? '' : 's'}',
      if (running.isNotEmpty)
        running.any((x) => x.listing)
            ? 'reading the folder…'
            : 'indexing ${running.fold(0, (a, x) => a + x.done)} of ${running.fold(0, (a, x) => a + x.total)}',
      if (truncated) 'only the first ${FolderLimitsText.files} files of a folder',
    ];
    final line = _message ?? errors.firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 2),
      child: Row(children: [
        Expanded(child: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Neon.dim, fontSize: TypeScale.caption))),
        if (line != null)
          Flexible(child: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end,
              style: const TextStyle(color: Neon.yellow, fontSize: TypeScale.caption))),
      ]),
    );
  }

  Widget _list() {
    final list = _shown.isEmpty
        ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
            Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: CrowEmptyState(
                  text: _all.isEmpty
                      ? (_search.text.trim().isEmpty
                          ? 'No audio files here yet. Pull down to read the folder again.'
                          // A search in an empty library: rare, so a light line (the writing guide's puns).
                          : 'Nothing to find in an empty nest yet. Pull down to read the folder again.')
                      : 'Nothing matches.'),
            ),
          ])
        : ListView.builder(
            key: const ValueKey('samples-list'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            itemExtent: rowHeight,
            itemCount: _shown.length,
            itemBuilder: (c, i) {
              final e = _shown[i];
              return SampleRow(
                key: ValueKey('sample:${e.root}/${e.rel}'),
                state: state,
                entry: e,
                selected: identical(e, _current),
                playing: _isPlaying(e),
                preview: _preview,
                onTap: () {
                  _focus.requestFocus();
                  _toggle(e);
                },
                onDoubleTap: () => _add(e),
                onMenu: (at) => _menu(e, at),
                onScrub: (seconds) {
                  if (_isPlaying(e)) {
                    state.samplePreview.seek(seconds);
                  } else {
                    unawaited(_play(e, start: seconds));
                  }
                },
              );
            },
          );
    return RefreshIndicator(onRefresh: _refresh, child: list);
  }

  Widget _strip() {
    final e = _current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.s, Space.xs, Space.s, Space.s),
      child: GestureDetector(
        key: const ValueKey('samples-strip'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 200) return;
          _step(v < 0 ? 1 : -1);
        },
        child: GlassPanel(
          child: LayoutBuilder(builder: (context, c) {
            // A phone's width: the volume without its icon and a shorter slider, so the name keeps some room.
            final narrow = c.maxWidth < 420;
            return SizedBox(
            height: 48,
            child: Row(children: [
              IconButton(key: const ValueKey('samples-prev'), tooltip: 'Previous', icon: const Icon(Icons.skip_previous, size: 20),
                  onPressed: _shown.isEmpty ? null : () => _step(-1)),
              IconButton(
                key: const ValueKey('samples-play'),
                tooltip: e != null && _isPlaying(e) ? 'Stop' : 'Play',
                icon: Icon(e != null && _isPlaying(e) ? Icons.stop : Icons.play_arrow, color: Neon.green),
                onPressed: e == null ? null : () => _toggle(e),
              ),
              IconButton(key: const ValueKey('samples-next'), tooltip: 'Next', icon: const Icon(Icons.skip_next, size: 20),
                  onPressed: _shown.isEmpty ? null : () => _step(1)),
              Expanded(
                child: Text(e == null ? 'Tap a sample to hear it, double tap to add it' : e.baseName,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: TypeScale.label, color: e == null ? Neon.dim : Neon.text)),
              ),
              Tooltip(
                message: 'Sync: loops play at the project tempo and start on the next bar while the song plays',
                child: FilterChip(
                  key: const ValueKey('samples-sync'),
                  label: const Text('Sync', style: TextStyle(fontSize: TypeScale.caption)),
                  selected: _sync,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (v) => setState(() => _sync = v),
                ),
              ),
              Tooltip(
                message: 'Preview through the selected track\'s effects',
                child: FilterChip(
                  key: const ValueKey('samples-through'),
                  label: const Text('FX', style: TextStyle(fontSize: TypeScale.caption)),
                  selected: _throughTrack,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (v) => setState(() => _throughTrack = v),
                ),
              ),
              if (!narrow) const Icon(Icons.volume_down, size: 16, color: Neon.dim),
              SizedBox(
                width: narrow ? 72 : 88,
                child: Slider(
                  key: const ValueKey('samples-volume'),
                  value: _volume,
                  onChanged: (v) {
                    setState(() => _volume = v);
                    state.samplePreview.setVolume(v);
                  },
                ),
              ),
            ]),
          );
          }),
        ),
      ),
    );
  }
}

/// The text of the folder file limit for the status line.
class FolderLimitsText {
  static const files = '50,000';
}

/// One sample: its waveform (drag along it to scrub while it plays), name and folder, tempo, key and length.
class SampleRow extends StatefulWidget {
  const SampleRow({super.key, required this.state, required this.entry, required this.selected, required this.playing,
      required this.preview, required this.onTap, required this.onDoubleTap, required this.onMenu, required this.onScrub});
  final AppState state;
  final SampleEntry entry;
  final bool selected, playing;
  final ValueListenable<PreviewState> preview;
  final VoidCallback onTap, onDoubleTap;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<double> onScrub;

  @override
  State<SampleRow> createState() => _SampleRowState();
}

class _SampleRowState extends State<SampleRow> {
  final _taps = ClickCounter();
  String? _path;
  bool _asked = false;
  Offset? _down;
  double _moved = 0;
  PointerDeviceKind _kind = PointerDeviceKind.touch;

  SampleEntry get e => widget.entry;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  void _resolve() {
    if (_asked) return;
    _asked = true;
    widget.state.sampleLibrary.pathOf(e).then((p) {
      if (mounted) setState(() => _path = p);
    });
  }

  void _tap() {
    if (_taps.twice) {
      widget.onDoubleTap();
    } else {
      widget.onTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = e.kind == SampleKind.loop ? Neon.blue : Neon.green;
    final wave = SizedBox(
      width: 84,
      height: 36,
      child: GestureDetector(
        key: ValueKey('scrub:${e.rel}'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => _scrub(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => _scrub(d.localPosition.dx),
        child: ValueListenableBuilder<PreviewState>(
          valueListenable: widget.preview,
          builder: (c, pv, _) => CustomPaint(
            painter: _RowWavePainter(
              peaks: () => _peaks(),
              path: _path,
              color: color,
              playhead: widget.playing && pv.length > 0 ? (pv.seconds / pv.length).clamp(0.0, 1.0) : null,
            ),
          ),
        ),
      ),
    );
    final body = AnimatedContainer(
      duration: Motion.fade(Motion.small, Motion.of(context)),
      margin: const EdgeInsets.symmetric(horizontal: Space.s, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: Space.s),
      decoration: BoxDecoration(
        color: widget.selected ? Neon.blue.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.s),
        border: Border.all(color: widget.selected ? Neon.blue.withValues(alpha: 0.5) : Colors.transparent),
      ),
      child: Row(children: [
        wave,
        const SizedBox(width: Space.s),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.baseName, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TypeScale.label, color: widget.playing ? Neon.green : Neon.text,
                    fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal)),
            Text([if (e.instrument != null) e.instrument!.label, if (e.kind != null) e.kind == SampleKind.loop ? 'Loop' : 'One-shot',
                  if (e.folder.isNotEmpty) e.folder].join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: TypeScale.caption, color: Neon.dim)),
          ]),
        ),
        const SizedBox(width: Space.xs),
        _value(e.bpm == null ? null : _bpmText(e.bpm!), e.bpmFrom, 'BPM', key: 'bpm'),
        _value(e.key?.short, e.keyFrom, 'Key', key: 'key', confidence: e.keyConfidence),
        SizedBox(
          width: 52,
          child: Text(sampleLength(e.seconds, approx: e.secondsApprox), textAlign: TextAlign.end,
              style: TypeScale.number(size: TypeScale.caption, color: Neon.dim)),
        ),
      ]),
    );
    final tappable = Listener(
      onPointerDown: (p) {
        _kind = p.kind;
        _taps.down(p, target: e);
      },
      onPointerUp: _taps.up,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _down = d.globalPosition,
        onTap: _tap,
        onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
        child: body,
      ),
    );
    final path = _path;
    if (path == null) return tappable;
    // Hold and move drags it onto a track, as Files' audio files (docs/app.md, Import); held still, the menu.
    return HoldDraggable<AssetDrag>(
      data: AssetDrag(AssetKind.audioFile, path, e.baseName),
      hapticFeedbackOnStart: false,
      onDragStarted: () {
        _moved = 0;
        Motion.tick();
        // The file's link goes with it: a drop adds the asset by this path (audio_edit.dart's addAssetFor).
        linkedPathHint[path] = (e.root, e.rel);
      },
      onDragUpdate: (d) => _moved += d.delta.distance,
      onDraggableCanceled: (_, offset) {
        if (_moved < 12 && !isMousePointer(_kind)) widget.onMenu(_down ?? offset);
      },
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
          decoration: BoxDecoration(color: Neon.panelHi.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(Radii.s),
              border: Border.all(color: color)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.graphic_eq_rounded, size: 18, color: color),
            const SizedBox(width: Space.xs),
            Text(e.baseName, style: const TextStyle(fontSize: TypeScale.label, color: Neon.text)),
          ]),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: body),
      child: tappable,
    );
  }

  PeakLevel? _peaks() {
    final p = _path, s = e.seconds;
    if (p == null || s == null || s <= 0) return null;
    return WaveformCache.instance.peaks(widget.state.audioIo, p, s, s / 84);
  }

  void _scrub(double x) {
    final s = e.seconds;
    if (s == null || s <= 0) return;
    widget.onScrub((x / 84).clamp(0.0, 1.0) * s);
  }

  /// A tempo or key: an estimate in italics with a "~" and its source in the tooltip.
  Widget _value(String? text, ValueSource? from, String what, {required String key, double? confidence}) {
    final estimate = from == ValueSource.detected;
    return SizedBox(
      width: 44,
      child: text == null
          ? const SizedBox.shrink()
          : Tooltip(
              message: '$what ${from?.label ?? ''}${confidence == null ? '' : ' (${(confidence * 100).round()}% sure)'}',
              child: Text(estimate ? '~$text' : text, key: ValueKey('$key:${e.rel}'), textAlign: TextAlign.end,
                  maxLines: 1, overflow: TextOverflow.clip,
                  style: TypeScale.number(size: TypeScale.caption, color: estimate ? Neon.dim : Neon.text)
                      .copyWith(fontStyle: estimate ? FontStyle.italic : FontStyle.normal)),
            ),
    );
  }
}

class _RowWavePainter extends CustomPainter {
  _RowWavePainter({required this.peaks, required this.path, required this.color, this.playhead})
      : super(repaint: path == null ? null : WaveformCache.instance.of(path));
  final PeakLevel? Function() peaks;
  final String? path;
  final Color color;
  final double? playhead;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final p = peaks();
    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    if (p == null || p.buckets == 0) {
      canvas.drawLine(Offset(0, mid), Offset(size.width, mid), paint..color = Neon.dim.withValues(alpha: 0.4));
    } else {
      final total = p.buckets * p.secondsPerBucket;
      for (var x = 0; x < size.width; x++) {
        final (lo, hi) = p.span(x / size.width * total, (x + 1) / size.width * total);
        canvas.drawLine(Offset(x + 0.5, mid - hi.clamp(-1.0, 1.0) * mid), Offset(x + 0.5, mid - lo.clamp(-1.0, 1.0) * mid), paint);
      }
    }
    final at = playhead;
    if (at != null) {
      final x = at * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
        ..color = Neon.text
        ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_RowWavePainter old) => old.path != path || old.playhead != playhead || old.color != color;
}
