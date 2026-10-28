// Exporter: render a loop, a free-length take, a one-shot or a wavetable to WAV, then save it with the system picker.
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

class ExporterScreen extends StatefulWidget {
  const ExporterScreen({super.key, required this.state});
  final AppState state;

  @override
  State<ExporterScreen> createState() => _ExporterScreenState();
}

class _ExporterScreenState extends State<ExporterScreen> {
  ExportKind _kind = ExportKind.loop;
  int _rate = 48000;
  bool _float = false;
  double _seconds = 8;
  String? _layerId;
  String? _moduleId;
  String? _param;
  int _frames = 64;
  RenderJob? _job;
  Timer? _poll;
  String? _message;
  bool _messageIsError = false;

  AppState get s => widget.state;

  @override
  void dispose() {
    _poll?.cancel();
    _job?.cancel();
    super.dispose();
  }

  String _safe(String n) => n.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '');

  String _fileName() {
    final p = s.project;
    final base = _safe(p.name).isEmpty ? 'CAW' : _safe(p.name);
    final bpm = p.bpm.toStringAsFixed(p.bpm == p.bpm.roundToDouble() ? 0 : 1);
    switch (_kind) {
      case ExportKind.loop:
        return '${base}_${bpm}bpm_${p.loopBars}bars.wav';
      case ExportKind.free:
        return '${base}_${bpm}bpm_${_seconds.toStringAsFixed(0)}s.wav';
      case ExportKind.oneShot:
        final l = p.layers.where((l) => l.id == _layerId).firstOrNull;
        return '${base}_${_safe(l?.name ?? 'layer')}.wav';
      case ExportKind.wavetable:
        final m = p.module(_moduleId);
        return '${base}_${_safe(m?.name ?? 'table')}_${_frames}f.wav';
    }
  }

  Future<void> _export() async {
    final p = s.project;
    final target = switch (_kind) {
      ExportKind.oneShot => _layerId ?? '',
      ExportKind.wavetable => _moduleId ?? '',
      _ => '',
    };
    if ((_kind == ExportKind.oneShot || _kind == ExportKind.wavetable) && target.isEmpty) {
      setState(() {
        _message = _kind == ExportKind.oneShot ? 'Pick a layer first.' : 'Pick a module first.';
        _messageIsError = true;
      });
      return;
    }
    final tmp = await getTemporaryDirectory();
    final name = _fileName();
    final path = '${tmp.path}${Platform.pathSeparator}$name';
    final job = RenderJob.start(RenderRequest(
      projectJson: p.toEngineJson(),
      kind: _kind,
      outPath: path,
      sampleRate: _rate,
      float32: _float,
      seconds: _seconds,
      target: target,
      param: _param ?? '',
      frames: _frames,
    ));
    setState(() {
      _job = job;
      _message = null;
    });
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => setState(() {}));
    final err = await job.result;
    _poll?.cancel();
    if (!mounted) return;
    setState(() => _job = null);
    if (err != null) {
      setState(() {
        _message = err == 'cancelled' ? 'Export cancelled.' : 'Export failed: $err';
        _messageIsError = err != 'cancelled';
      });
      return;
    }
    final file = File(path);
    final bytes = await file.readAsBytes();
    Uri? saved;
    try {
      saved = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'audio/wav', type: FileType.audio);
    } catch (e) {
      setState(() {
        _message = 'Could not save: $e';
        _messageIsError = true;
      });
      return;
    } finally {
      if (await file.exists()) await file.delete();
    }
    if (!mounted) return;
    setState(() {
      _message = saved == null ? 'Not saved (picker closed).' : 'Saved $name';
      _messageIsError = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = s.project;
    final layers = p.layers.where((l) => l.generatorId != null).toList();
    if (_layerId == null || !layers.any((l) => l.id == _layerId)) _layerId = layers.firstOrNull?.id;
    final modules = p.modules.where((m) => s.info[m.id]?.ok ?? false).toList();
    if (_moduleId == null || !modules.any((m) => m.id == _moduleId)) {
      _moduleId = (modules.where((m) => !s.isEffect(m.id)).firstOrNull ?? modules.firstOrNull)?.id;
    }
    final params = s.info[_moduleId]?.params ?? const <ParamInfo>[];
    if (_param != null && !params.any((x) => x.name == _param)) _param = null;
    final busy = _job != null;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), children: [
      const Heading('What to export'),
      SegmentedButton<ExportKind>(
        segments: const [
          ButtonSegment(value: ExportKind.loop, label: Text('Loop')),
          ButtonSegment(value: ExportKind.free, label: Text('Length')),
          ButtonSegment(value: ExportKind.oneShot, label: Text('One-shot')),
          ButtonSegment(value: ExportKind.wavetable, label: Text('Table')),
        ],
        selected: {_kind},
        showSelectedIcon: false,
        onSelectionChanged: busy ? null : (v) => setState(() => _kind = v.first),
      ),
      const SizedBox(height: 12),
      NeonPanel(
        color: Neon.yellow,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_describe(), style: const TextStyle(color: Neon.dim)),
          const SizedBox(height: 8),
          if (_kind == ExportKind.free)
            Row(children: [
              const Text('Seconds'),
              Expanded(
                child: Slider(
                  value: _seconds,
                  min: 1,
                  max: 120,
                  divisions: 119,
                  activeColor: Neon.yellow,
                  onChanged: (v) => setState(() => _seconds = v),
                ),
              ),
              Text(_seconds.toStringAsFixed(0), style: Neon.code(color: Neon.yellow)),
            ]),
          if (_kind == ExportKind.oneShot)
            DropdownButton<String>(
              value: _layerId,
              hint: const Text('No layers with a generator'),
              items: [for (final l in layers) DropdownMenuItem(value: l.id, child: Text(l.name))],
              onChanged: (v) => setState(() => _layerId = v),
            ),
          if (_kind == ExportKind.wavetable) ...[
            DropdownButton<String>(
              value: _moduleId,
              hint: const Text('No compiled modules'),
              items: [for (final m in modules) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: (v) => setState(() => _moduleId = v),
            ),
            Row(children: [
              const Text('Sweep '),
              DropdownButton<String?>(
                value: _param,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('nothing')),
                  for (final x in params) DropdownMenuItem<String?>(value: x.name, child: Text(x.name)),
                ],
                onChanged: (v) => setState(() => _param = v),
              ),
              const SizedBox(width: 16),
              const Text('Frames '),
              DropdownButton<int>(
                value: _frames,
                items: [for (final f in [1, 8, 16, 32, 64, 128, 256]) DropdownMenuItem(value: f, child: Text('$f'))],
                onChanged: (v) => setState(() => _frames = v!),
              ),
            ]),
          ],
          Wrap(spacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<int>(
              value: _rate,
              items: const [
                DropdownMenuItem(value: 44100, child: Text('44.1 kHz')),
                DropdownMenuItem(value: 48000, child: Text('48 kHz')),
              ],
              onChanged: busy ? null : (v) => setState(() => _rate = v!),
            ),
            if (_kind != ExportKind.wavetable)
              DropdownButton<bool>(
                value: _float,
                items: const [
                  DropdownMenuItem(value: false, child: Text('24-bit')),
                  DropdownMenuItem(value: true, child: Text('32-bit float')),
                ],
                onChanged: busy ? null : (v) => setState(() => _float = v!),
              ),
          ]),
          const SizedBox(height: 4),
          Text(_fileName(), style: Neon.code(size: 13, color: Neon.yellow)),
        ]),
      ),
      const SizedBox(height: 16),
      if (busy) ...[
        Bar(value: _job!.progress, color: Neon.yellow, height: 6),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _job!.cancel, child: const Text('Cancel')),
      ] else
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: Neon.yellow, foregroundColor: Neon.bg, minimumSize: const Size.fromHeight(52)),
          onPressed: _export,
          icon: const Icon(Icons.download),
          label: const Text('Export WAV', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, style: TextStyle(color: _messageIsError ? Neon.pink : Neon.green)),
        ),
      const SizedBox(height: 12),
      const Text('Exports are bit-exact with playback: same code, seed and settings give the same file on any device.',
          style: TextStyle(color: Neon.dim, fontSize: 12)),
    ]);
  }

  String _describe() {
    final p = s.project;
    switch (_kind) {
      case ExportKind.loop:
        return 'The whole mix, exactly ${p.loopBars} bars at ${p.bpm.toStringAsFixed(1)} BPM '
            '(${p.loopSeconds.toStringAsFixed(3)} s), with loop points. Drops onto Reaper\'s grid.';
      case ExportKind.free:
        return 'The whole mix from the start, for as long as you like.';
      case ExportKind.oneShot:
        return 'One pass of one layer on its own, with the silent end trimmed.';
      case ExportKind.wavetable:
        return 'Single-cycle frames of 2048 samples for wavetable synths, sweeping a param across the frames.';
    }
  }
}
