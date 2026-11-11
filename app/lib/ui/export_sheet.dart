// The Export sheet (roadmap 0.3, 6.4, 6.5): mix, stems, regions or the selection to WAV with format, loudness, tail,
// dither and names, a queue with progress and cancel, and the results saved through the system picker.
import 'dart:io';

import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/project.dart';
import '../model/settings.dart';
import '../model/song_export.dart';
import '../platform/save_copy.dart';
import 'feedback.dart';
import 'glass.dart';
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';
import 'widgets.dart';

/// The sheet's accent pair (the exporter's yellow into pink), as a device family's would be.
Color get _accent => Neon.yellow;
Color get _second => Neon.pink;

/// Opens the Export sheet over [context] for [state]'s project.
Future<void> showSongExportSheet(BuildContext context, AppState state, {ExportQueue? queue}) async {
  final q = queue ?? await sharedExportQueue();
  if (!context.mounted) return;
  await showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.92),
      child: SongExportPanel(state: state, queue: q),
    ),
  );
}

/// The project's name as the files' {project}, following Settings › Export › File names.
String exportProjectName(ProjectDoc p, ExportNaming naming, {DateTime? now}) {
  final safe = p.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '');
  final base = safe.isEmpty ? 'CAW' : safe;
  switch (naming) {
    case ExportNaming.project:
      return base;
    case ExportNaming.dated:
      final t = now ?? DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      return '${base}_${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    case ExportNaming.detailed:
      return '${base}_${p.bpm.toStringAsFixed(p.bpm == p.bpm.roundToDouble() ? 0 : 1)}bpm';
  }
}

/// The stems a project has: tracks that play (an instrument) and folder buses.
List<({String id, String name, String kind})> projectStems(ProjectDoc p, StemSet set) => [
      for (final l in p.layers)
        if (!l.isFolder && l.instrument != null && set != StemSet.buses)
          (id: l.id, name: l.name, kind: 'track')
        else if (l.isFolder && l.busEnabled && set != StemSet.tracks)
          (id: l.id, name: l.name, kind: 'bus'),
    ];

/// The sheet's contents: the options, the Render button and the queue.
class SongExportPanel extends StatefulWidget {
  const SongExportPanel({super.key, required this.state, required this.queue});
  final AppState state;
  final ExportQueue queue;

  @override
  State<SongExportPanel> createState() => _SongExportPanelState();
}

class _SongExportPanelState extends State<SongExportPanel> {
  late SongExportOptions o = _initial();
  late final TextEditingController _pattern = TextEditingController(text: o.pattern);
  String? _message;
  bool _messageIsError = false;

  AppState get s => widget.state;
  ProjectDoc get p => s.project;

  // The last options used, with Settings › Export's rate and depth the first time.
  SongExportOptions _initial() {
    final q = widget.queue;
    if (q.hasLast) return q.last.copy();
    return SongExportOptions(
      sampleRate: SongExportOptions.sampleRates.contains(s.settings.exportSampleRate) ? s.settings.exportSampleRate : 48000,
      bitDepth: s.settings.exportFloat32 ? 32 : 24,
    );
  }

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  bool get _hasLoop => p.hasLoopRange;
  bool get _hasSelection {
    final a = s.timeSelectionStart, b = s.timeSelectionEnd;
    return a != null && b != null && a != b;
  }

  List<MarkerDoc> get _regions => [for (final m in p.markers) if (m.isRegion) m];

  bool _rangeAvailable(ExportRange r) => switch (r) {
        ExportRange.song => true,
        ExportRange.loop => _hasLoop,
        ExportRange.selection => _hasSelection,
        ExportRange.regions => _regions.isNotEmpty,
      };

  ExportRange get _range => _rangeAvailable(o.range) ? o.range : ExportRange.song;

  List<ExportSpan> _spans() => switch (_range) {
        ExportRange.song => const [],
        ExportRange.loop => [ExportSpan(p.loopStartSteps, p.loopEndSteps)],
        ExportRange.selection => [
            ExportSpan(
                s.timeSelectionStart! < s.timeSelectionEnd! ? s.timeSelectionStart! : s.timeSelectionEnd!,
                s.timeSelectionStart! < s.timeSelectionEnd! ? s.timeSelectionEnd! : s.timeSelectionStart!)
          ],
        ExportRange.regions => [for (final m in _regions) ExportSpan(m.startSteps, m.endSteps!, m.name)],
      };

  String _bars(int steps) {
    final bar = p.stepsPerBar;
    return steps % bar == 0 ? '${steps ~/ bar} bars' : '$steps steps';
  }

  String _describeRange() {
    String at(int st) => '${st ~/ p.stepsPerBar + 1}.${st % p.stepsPerBar ~/ 4 + 1}';
    switch (_range) {
      case ExportRange.song:
        return 'The whole song, ${_bars(p.engineLoopSteps)} from the start.';
      case ExportRange.loop:
        return 'The loop range, ${at(p.loopStartSteps)} to ${at(p.loopEndSteps)}, once through.';
      case ExportRange.selection:
        final sp = _spans().first;
        return 'The time selection, ${at(sp.start)} to ${at(sp.end)} (${_bars(sp.end - sp.start)}).';
      case ExportRange.regions:
        final n = _regions.length;
        return '$n region${n == 1 ? '' : 's'}, a set of files each: ${_regions.map((r) => r.name).join(', ')}.';
    }
  }

  List<String> _names() {
    final project = exportProjectName(p, s.settings.exportNaming);
    final stems = [for (final st in projectStems(p, o.stems)) (name: st.name, kind: st.kind)];
    final regions = _range == ExportRange.regions ? [for (final r in _regions) r.name] : const [''];
    return previewNames(o, project: project, stems: o.hasStems ? stems : const [], regions: regions);
  }

  void _set(VoidCallback change) {
    Haptics.tap();
    setState(change);
  }

  void _render() {
    final names = _names();
    if (o.hasStems && projectStems(p, o.stems).isEmpty) {
      Haptics.error();
      setState(() {
        _message = o.stems == StemSet.buses ? 'This project has no buses.' : 'This project has no tracks to stem.';
        _messageIsError = true;
      });
      return;
    }
    o.pattern = _pattern.text.trim().isEmpty ? SongExportOptions.defaultPattern : _pattern.text.trim();
    final opts = o.copy()..range = _range;
    final request = songRenderRequest(opts, project: exportProjectName(p, s.settings.exportNaming), spans: _spans());
    final title = '${p.name.isEmpty ? 'Song' : p.name} · ${o.source.label}'
        '${o.hasStems ? ' (${o.stems.label.toLowerCase()})' : ''} · ${_range.label} · '
        '${o.bitDepth == 32 ? '32-bit float' : '${o.bitDepth}-bit'} · ${o.sampleRate ~/ 1000 == o.sampleRate / 1000 ? o.sampleRate ~/ 1000 : (o.sampleRate / 1000).toStringAsFixed(1)} kHz';
    final added = widget.queue.add(title: title, projectJson: p.toEngineJson(), request: request);
    widget.queue.remember(opts);
    if (added) {
      Haptics.drop();
    } else {
      Haptics.error();
    }
    setState(() {
      _message = added ? 'Queued ${names.length} file${names.length == 1 ? '' : 's'}.' : 'The queue is full (50 renders).';
      _messageIsError = !added;
    });
  }

  @override
  Widget build(BuildContext context) {
    final names = _names();
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(12, 0, 12, 16 + MediaQuery.viewInsetsOf(context).bottom),
      children: [
        const _SheetHeader(),
        _Section('SOURCE', children: [
          _Tiles<ExportSource>(
            keyPrefix: 'source',
            values: ExportSource.values,
            selected: o.source,
            label: (v) => v.label,
            icon: (v) => switch (v) {
              ExportSource.mix => Icons.graphic_eq,
              ExportSource.stems => Icons.view_stream,
              ExportSource.mixAndStems => Icons.library_music_outlined,
            },
            onPick: (v) => _set(() => o.source = v),
          ),
          if (o.hasStems) ...[
            const SizedBox(height: 6),
            _Tiles<StemSet>(
              keyPrefix: 'stems',
              values: StemSet.values,
              selected: o.stems,
              label: (v) => '${v.label} · ${projectStems(p, v).length}',
              height: 40,
              onPick: (v) => _set(() => o.stems = v),
            ),
            const _Note('Each stem is what its track or bus sends on, after its effects, volume and pan, with the '
                "master's volume. Stems that reach the master add up to the mix; master effects stay on the mix only."),
          ],
        ]),
        _Section('RANGE', children: [
          _Tiles<ExportRange>(
            keyPrefix: 'range',
            values: ExportRange.values,
            selected: _range,
            label: (v) => v.label,
            enabled: _rangeAvailable,
            height: 40,
            onPick: (v) => _set(() => o.range = v),
          ),
          _Note(_describeRange()),
        ]),
        _Section('TAIL', children: [
          _Tiles<ExportTail>(
            keyPrefix: 'tail',
            values: ExportTail.values,
            selected: o.tail,
            label: (v) => v.label,
            height: 40,
            onPick: (v) => _set(() => o.tail = v),
          ),
          if (o.tail == ExportTail.seconds)
            _Stepper(label: 'Seconds', value: o.tailSeconds, step: 0.5, min: 0, max: 60, unit: 's',
                onChanged: (v) => setState(() => o.tailSeconds = v)),
          _Note(switch (o.tail) {
            ExportTail.none => 'Files end exactly at the range end.',
            ExportTail.seconds => 'Notes release and effects ring for this long after the end.',
            ExportTail.silence => 'Renders on after the end until everything is quiet (at most 30 s). Every file '
                'gets the same length.',
          }),
        ]),
        _Fold(title: 'FORMAT · ${o.bitDepth == 32 ? '32F' : o.bitDepth} · ${o.sampleRate / 1000} kHz', children: [
          _Tiles<int>(
            keyPrefix: 'rate',
            values: SongExportOptions.sampleRates,
            selected: o.sampleRate,
            label: (v) => '${v / 1000} kHz',
            height: 40,
            onPick: (v) => _set(() => o.sampleRate = v),
          ),
          const SizedBox(height: 6),
          _Tiles<int>(
            keyPrefix: 'bits',
            values: SongExportOptions.bitDepths,
            selected: o.bitDepth,
            label: (v) => v == 32 ? '32-bit float' : '$v-bit',
            height: 40,
            onPick: (v) => _set(() => o.bitDepth = v),
          ),
          if (o.bitDepth == 16) ...[
            const SizedBox(height: 8),
            _Pill(key: const ValueKey('export-dither'), label: 'TPDF DITHER', on: o.dither,
                onTap: () => _set(() => o.dither = !o.dither)),
          ],
          const _Note('WAV. 16-bit adds dither (+-1 step of triangular noise) so quiet fades stay smooth.'),
        ]),
        _Fold(title: 'LOUDNESS · ${switch (o.loudness) {
          ExportLoudness.off => 'OFF',
          ExportLoudness.peak => '${o.peakTarget.toStringAsFixed(1)} dBFS',
          ExportLoudness.lufs => '${o.lufsTarget.toStringAsFixed(1)} LUFS',
        }}', children: [
          _Tiles<ExportLoudness>(
            keyPrefix: 'loud',
            values: ExportLoudness.values,
            selected: o.loudness,
            label: (v) => v.label,
            height: 40,
            onPick: (v) => _set(() => o.loudness = v),
          ),
          if (o.loudness == ExportLoudness.peak)
            _Stepper(label: 'Peak', value: o.peakTarget, step: 0.5, min: -24, max: 0, unit: 'dBFS',
                onChanged: (v) => setState(() => o.peakTarget = v)),
          if (o.loudness == ExportLoudness.lufs) ...[
            _Stepper(label: 'Target', value: o.lufsTarget, step: 1, min: -40, max: -5, unit: 'LUFS',
                onChanged: (v) => setState(() => o.lufsTarget = v)),
            _Stepper(label: 'Ceiling', value: o.ceiling, step: 0.5, min: -12, max: 0, unit: 'dBTP',
                onChanged: (v) => setState(() => o.ceiling = v)),
          ],
          const _Note('Normalising sets one gain from the mix and gives it to every file, so stems still add up.'),
        ]),
        _Fold(title: 'NAMES · ${names.length} FILE${names.length == 1 ? '' : 'S'}', children: [
          TextField(
            key: const ValueKey('export-pattern'),
            controller: _pattern,
            style: Neon.code(size: 13),
            decoration: const InputDecoration(isDense: true, labelText: 'Pattern',
                helperText: '{project} {stem} {region} {kind} {index}'),
            onChanged: (v) => setState(() => o.pattern = v.trim().isEmpty ? SongExportOptions.defaultPattern : v.trim()),
          ),
          const SizedBox(height: 6),
          for (final n in names.take(6)) Text(n, style: Neon.code(size: 12, color: _accent)),
          if (names.length > 6) Text('and ${names.length - 6} more', style: const TextStyle(color: Neon.dim, fontSize: 11)),
        ]),
        const SizedBox(height: 12),
        Pressable(
          glow: _accent,
          child: FilledButton.icon(
            key: const ValueKey('export-render'),
            style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Neon.bg,
                minimumSize: const Size.fromHeight(52)),
            onPressed: _render,
            icon: const Icon(Icons.download),
            label: Text('Render ${names.length} file${names.length == 1 ? '' : 's'}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_message!, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _messageIsError ? Neon.pink : Neon.green, fontSize: 12)),
          ),
        const SizedBox(height: 8),
        ExportQueueView(queue: widget.queue),
      ],
    );
  }
}

/// The sheet's faceplate: a title over the accent stripe, as a device's.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.ios_share, size: 18, color: _accent),
            const SizedBox(width: 8),
            const Text('EXPORT SONG', style: TextStyle(fontSize: 13, letterSpacing: 1.6, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Container(height: 3, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2),
              gradient: LinearGradient(colors: [_accent, _second]))),
        ]),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(title,
              style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: _accent))),
          ...children,
        ]),
      );
}

/// The device kit's "More" fold, for the sheet's less used sections.
class _Fold extends StatefulWidget {
  const _Fold({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            Haptics.tap();
            setState(() => _open = !_open);
          },
          child: SizedBox(height: 44, child: Row(children: [
            AnimatedRotation(turns: _open ? 0.25 : 0, duration: Motion.fade(Motion.small, Motion.of(context)),
                child: Icon(Icons.chevron_right, size: 18, color: _accent)),
            const SizedBox(width: 4),
            Text(widget.title, style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: _accent)),
            const SizedBox(width: 8),
            Expanded(child: Container(height: 1, color: _accent.withValues(alpha: 0.2))),
          ])),
        ),
        if (_open) Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children)),
      ]);
}

/// A row of big choice tiles (the device kit's mode tiles): a glow on the chosen one, a dip while pressed.
class _Tiles<T> extends StatelessWidget {
  const _Tiles({required this.keyPrefix, required this.values, required this.selected, required this.label,
      required this.onPick, this.icon, this.enabled, this.height = 54});
  final String keyPrefix;
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final IconData Function(T)? icon;
  final bool Function(T)? enabled;
  final void Function(T) onPick;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Row(children: [
          for (var k = 0; k < values.length; k++)
            Expanded(child: Padding(
              padding: EdgeInsets.only(right: k < values.length - 1 ? 4 : 0),
              child: _tile(context, values[k]),
            )),
        ]),
      );

  Widget _tile(BuildContext context, T v) {
    final on = v == selected;
    final ok = enabled?.call(v) ?? true;
    final c = _accent;
    return Semantics(
      button: true,
      selected: on,
      enabled: ok,
      label: label(v),
      child: GestureDetector(
        key: ValueKey('$keyPrefix-${v is Enum ? v.name : v}'),
        behavior: HitTestBehavior.opaque,
        onTap: ok && !on ? () => onPick(v) : null,
        child: Pressable(enabled: ok, glow: c, child: AnimatedContainer(
          duration: Motion.fade(Motion.small, Motion.of(context)),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: on ? c.withValues(alpha: 0.2) : Colors.white.withValues(alpha: ok ? 0.03 : 0.0),
            border: Border.all(color: on ? c : Neon.line.withValues(alpha: ok ? 1 : 0.4), width: on ? 1.5 : 1),
            boxShadow: on ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 10)] : null,
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (icon != null) Icon(icon!(v), size: 18, color: on ? c : (ok ? Neon.dim : Neon.dim.withValues(alpha: 0.4))),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Text(label(v).toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9.5, letterSpacing: 0.3, fontWeight: FontWeight.w800,
                    color: on ? Neon.text : (ok ? Neon.dim : Neon.dim.withValues(alpha: 0.4))))),
          ]),
        )),
      ),
    );
  }
}

/// An on/off pill (the device kit's toggle).
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Semantics(toggled: on, label: label, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Pressable(glow: _accent, radius: 18, child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: on ? _accent.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: on ? _accent : Neon.line),
              boxShadow: on ? [BoxShadow(color: _accent.withValues(alpha: 0.3), blurRadius: 10)] : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.power_settings_new, size: 15, color: on ? _accent : Neon.dim),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w800,
                  color: on ? Neon.text : Neon.dim)),
            ]),
          )),
        )),
      );
}

/// A value with − and + buttons, 48 dp each.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.step, required this.min, required this.max,
      required this.unit, required this.onChanged});
  final String label, unit;
  final double value, step, min, max;
  final void Function(double) onChanged;

  void _by(double d) {
    final v = (value + d).clamp(min, max).toDouble();
    if (v == value) {
      Haptics.threshold();
      return;
    }
    Haptics.tick();
    onChanged(v);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          SizedBox(width: 64, child: Text(label, style: const TextStyle(color: Neon.dim, fontSize: 12))),
          IconButton(key: ValueKey('step-$label-down'), onPressed: () => _by(-step), icon: const Icon(Icons.remove)),
          Expanded(child: Text('${value.toStringAsFixed(1)} $unit', textAlign: TextAlign.center,
              style: Neon.code(size: 14, color: _accent))),
          IconButton(key: ValueKey('step-$label-up'), onPressed: () => _by(step), icon: const Icon(Icons.add)),
        ]),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: const TextStyle(color: Neon.dim, fontSize: 11)),
      );
}

/// The export queue: each render's progress and cancel while it runs, and its files to save when done.
class ExportQueueView extends StatefulWidget {
  const ExportQueueView({super.key, required this.queue});
  final ExportQueue queue;

  @override
  State<ExportQueueView> createState() => _ExportQueueViewState();
}

class _ExportQueueViewState extends State<ExportQueueView> {
  String? _message;

  @override
  void initState() {
    super.initState();
    widget.queue.onFinished = (job) {
      switch (job.state) {
        case ExportJobState.done:
          Haptics.drop();
        case ExportJobState.failed:
          Haptics.error();
        default:
          break;
      }
    };
  }

  Future<void> _save(ExportJob job, [ExportedFile? only]) async {
    final files = only != null ? [only] : job.files;
    try {
      if (files.length == 1) {
        final f = files.first;
        final saved = await saveCopyOf(File(f.path), name: f.name, mimeType: 'audio/wav', extension: 'wav');
        if (mounted) setState(() => _message = saved ? 'Saved ${f.name}' : 'Not saved (picker closed).');
      } else {
        final n = await saveCopiesToFolder([for (final f in files) (File(f.path), f.name)]);
        if (mounted) setState(() => _message = n < 0 ? 'Not saved (picker closed).' : 'Saved $n files.');
      }
      Haptics.tap();
    } catch (e) {
      Haptics.error();
      if (mounted) setState(() => _message = 'Save failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.queue,
        builder: (context, _) {
          final q = widget.queue;
          final jobs = q.jobs.reversed.toList();
          if (jobs.isEmpty) return const SizedBox.shrink();
          return NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('RENDERS · ${jobs.length}',
                  style: const TextStyle(color: Neon.blue, fontWeight: FontWeight.w800, fontSize: 12))),
              if (q.busy || jobs.any((j) => j.state == ExportJobState.queued))
                TextButton(key: const ValueKey('export-cancel-all'), onPressed: () {
                  Haptics.tap();
                  q.cancelAll();
                }, child: const Text('Cancel all')),
              if (jobs.any((j) => j.finished))
                TextButton(onPressed: () {
                  Haptics.tap();
                  q.clearFinished();
                }, child: const Text('Clear')),
            ]),
            for (final job in jobs) _JobTile(job: job, queue: q, onSave: _save),
            if (_message != null)
              Text(_message!, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Neon.green, fontSize: 11)),
          ]));
        },
      );
}

class _JobTile extends StatefulWidget {
  const _JobTile({required this.job, required this.queue, required this.onSave});
  final ExportJob job;
  final ExportQueue queue;
  final Future<void> Function(ExportJob, [ExportedFile?]) onSave;

  @override
  State<_JobTile> createState() => _JobTileState();
}

class _JobTileState extends State<_JobTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final q = widget.queue;
    final status = switch (job.state) {
      ExportJobState.queued => 'Waiting',
      ExportJobState.running => 'Rendering ${(job.progress * 100).round()} %',
      ExportJobState.done => '${job.files.length} file${job.files.length == 1 ? '' : 's'}',
      ExportJobState.failed => job.error ?? 'Failed',
      ExportJobState.cancelled => 'Cancelled',
    };
    return Padding(
      key: ValueKey('export-job-${job.id}'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11,
                color: job.state == ExportJobState.failed ? Neon.pink : Neon.dim)),
          ])),
          if (!job.finished)
            IconButton(key: ValueKey('export-cancel-${job.id}'), tooltip: 'Cancel', onPressed: () {
              Haptics.tap();
              q.cancel(job);
            }, icon: const Icon(Icons.close)),
          if (job.state == ExportJobState.failed || job.state == ExportJobState.cancelled)
            IconButton(tooltip: 'Try again', onPressed: () {
              Haptics.tap();
              q.retry(job);
            }, icon: const Icon(Icons.refresh)),
          if (job.state == ExportJobState.done) ...[
            if (job.files.length > 1)
              IconButton(tooltip: 'Files', onPressed: () {
                Haptics.tap();
                setState(() => _open = !_open);
              }, icon: Icon(_open ? Icons.expand_less : Icons.expand_more)),
            FilledButton.tonal(key: ValueKey('export-save-${job.id}'), onPressed: () => widget.onSave(job),
                child: Text(job.files.length > 1 ? 'Save all' : 'Save')),
          ],
          if (job.finished)
            IconButton(tooltip: 'Remove', onPressed: () {
              Haptics.tap();
              q.remove(job);
            }, icon: const Icon(Icons.delete_outline)),
        ]),
        if (job.state == ExportJobState.running) Bar(value: job.progress, color: _accent, height: 6),
        if (_open && job.state == ExportJobState.done)
          for (final f in job.files)
            Row(children: [
              Expanded(child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Neon.code(size: 12))),
              Text(f.lufs > -199 ? '${f.lufs.toStringAsFixed(1)} LUFS' : '${f.peakDb.toStringAsFixed(1)} dB',
                  style: const TextStyle(color: Neon.dim, fontSize: 10)),
              IconButton(tooltip: 'Save ${f.name}', onPressed: () => widget.onSave(job, f),
                  icon: const Icon(Icons.save_alt, size: 18)),
            ]),
      ]),
    );
  }
}
