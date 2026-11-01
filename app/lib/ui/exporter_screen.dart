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
  bool _advanced = false;
  int _rate = 48000;
  bool _float = false;
  double _seconds = 8;
  String? _layerId;
  String? _moduleId;
  String? _patternId;
  String? _param;
  int _frames = 64;
  RenderJob? _job;
  bool _midiBusy = false;
  bool _saving = false;
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
      case ExportKind.midi:
        final m = p.module(_patternId);
        return '${base}_${_safe(m?.name ?? 'pattern')}.mid';
    }
  }

  Future<void> _export() async {
    if (_job != null || _midiBusy) return;
    if (_kind == ExportKind.midi) {
      await _exportMidi();
      return;
    }
    final p = s.project;
    final target = switch (_kind) {
      ExportKind.oneShot => _layerId ?? '',
      ExportKind.wavetable => _moduleId ?? '',
      ExportKind.midi => _patternId ?? '',
      _ => '',
    };
    if ((_kind == ExportKind.oneShot || _kind == ExportKind.wavetable) && target.isEmpty) {
      setState(() {
        _message = _kind == ExportKind.oneShot ? 'Pick a layer first.' : 'Pick a module first.';
        _messageIsError = true;
      });
      return;
    }

    File? file;
    RenderJob? job;
    try {
      final tmp = await getTemporaryDirectory();
      final name = _fileName();
      final path = '${tmp.path}${Platform.pathSeparator}$name';
      file = File(path);
      job = RenderJob.start(RenderRequest(
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
      if (!mounted) {
        job.cancel();
        return;
      }
      setState(() {
        _job = job;
        _message = null;
      });
      _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });

      final error = await job.result;
      _poll?.cancel();
      _poll = null;
      if (!mounted) return;
      if (error != null) {
        setState(() {
          _message = error == 'cancelled' ? 'Export cancelled.' : 'Export failed: $error';
          _messageIsError = error != 'cancelled';
        });
        return;
      }

      final bytes = await file.readAsBytes();
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'audio/wav',
        type: FileType.audio,
      );
      if (!mounted) return;
      setState(() {
        _message = saved == null ? 'Not saved (picker closed).' : 'Saved $name';
        _messageIsError = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _message = 'Export failed: $e';
        _messageIsError = true;
      });
    } finally {
      _poll?.cancel();
      _poll = null;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Temporary-file cleanup must not hide the original export result.
        }
      }
      if (mounted) setState(() => _job = null);
    }
  }

  Future<void> _exportMidi() async {
    final module = s.project.module(_patternId);
    if (module == null || !s.isPattern(module.id)) {
      setState(() { _message = 'Choose a valid MIDI pattern first.'; _messageIsError = true; });
      return;
    }
    if (_job != null || _midiBusy || _saving) return;
    setState(() { _midiBusy = true; _message = null; });
    File? file;
    try {
      final tmp = await getTemporaryDirectory();
      final name = _fileName();
      file = File('${tmp.path}${Platform.pathSeparator}$name');
      final error = Engine.exportPattern(module.source, file.path,
        bpm: s.project.bpm, beatsPerBar: s.project.beatsPerBar);
      if (error != null) throw StateError(error);
      final bytes = await file.readAsBytes();
      final saved = await FilePicker.saveFile(fileName: name, bytes: bytes,
        mimeType: 'audio/midi', type: FileType.custom, allowedExtensions: const ['mid']);
      if (!mounted) return;
      setState(() { _message = saved == null ? 'Not saved (picker closed).' : 'Saved $name'; _messageIsError = false; });
    } catch (e) {
      if (mounted) setState(() { _message = 'MIDI export failed: $e'; _messageIsError = true; });
    } finally {
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // A failed temporary-file cleanup is non-fatal to the export result.
        }
      }
      if (mounted) setState(() => _midiBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = s.project;
    final layers = p.layers.where((l) => l.generatorId != null).toList();
    if (_layerId == null || !layers.any((l) => l.id == _layerId)) _layerId = layers.firstOrNull?.id;
    final modules = p.modules.where((m) => (s.info[m.id]?.ok ?? false) && !s.isLibrary(m.id)).toList();
    final patterns = p.modules.where((m) => s.isPattern(m.id)).toList();
    if (_patternId == null || !patterns.any((m) => m.id == _patternId)) _patternId = patterns.firstOrNull?.id;
    if (_moduleId == null || !modules.any((m) => m.id == _moduleId)) {
      _moduleId = (modules.where((m) => s.isGenerator(m.id)).firstOrNull ?? modules.firstOrNull)?.id;
    }
    final params = s.info[_moduleId]?.params ?? const <ParamInfo>[];
    if (_param != null && !params.any((x) => x.name == _param)) _param = null;
    final busy = _job != null || _midiBusy || _saving;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), children: [
      const Heading('Export mode'),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Quick Export'), icon: Icon(Icons.bolt)),
          ButtonSegment(value: true, label: Text('Advanced'), icon: Icon(Icons.tune)),
        ],
        selected: {_advanced},
        showSelectedIcon: false,
        onSelectionChanged: busy ? null : (v) => setState(() {
          _advanced = v.first;
          if (!_advanced) _kind = ExportKind.loop;
        }),
      ),
      if (_advanced) ...[
        const SizedBox(height: 12),
        const Heading('What to export'),
        SegmentedButton<ExportKind>(
          segments: const [
            ButtonSegment(value: ExportKind.loop, label: Text('Loop')),
            ButtonSegment(value: ExportKind.free, label: Text('Length')),
            ButtonSegment(value: ExportKind.oneShot, label: Text('One-shot')),
            ButtonSegment(value: ExportKind.wavetable, label: Text('Table')),
            ButtonSegment(value: ExportKind.midi, label: Text('MIDI')),
          ],
          selected: {_kind},
          showSelectedIcon: false,
          onSelectionChanged: busy ? null : (v) => setState(() => _kind = v.first),
        ),
      ],
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
                  onChanged: busy ? null : (v) => setState(() => _seconds = v),
                ),
              ),
              Text(_seconds.toStringAsFixed(0), style: Neon.code(color: Neon.yellow)),
            ]),
          if (_kind == ExportKind.oneShot)
            DropdownButton<String>(
              value: _layerId,
              hint: const Text('No layers with a generator'),
              items: [for (final l in layers) DropdownMenuItem(value: l.id, child: Text(l.name))],
              onChanged: busy ? null : (v) => setState(() => _layerId = v),
            ),
          if (_kind == ExportKind.midi)
            DropdownButton<String>(
              value: _patternId,
              hint: const Text('No MIDI patterns in this project'),
              items: [for (final m in patterns) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: busy ? null : (v) => setState(() => _patternId = v),
            ),
          if (_kind == ExportKind.wavetable) ...[
            DropdownButton<String>(
              value: _moduleId,
              hint: const Text('No compiled modules'),
              items: [for (final m in modules) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: busy ? null : (v) => setState(() => _moduleId = v),
            ),
            Row(children: [
              const Text('Sweep '),
              DropdownButton<String?>(
                value: _param,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('nothing')),
                  for (final x in params) DropdownMenuItem<String?>(value: x.name, child: Text(x.name)),
                ],
                onChanged: busy ? null : (v) => setState(() => _param = v),
              ),
              const SizedBox(width: 16),
              const Text('Frames '),
              DropdownButton<int>(
                value: _frames,
                items: [for (final f in [1, 8, 16, 32, 64, 128, 256]) DropdownMenuItem(value: f, child: Text('$f'))],
                onChanged: busy ? null : (v) => setState(() => _frames = v!),
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
            if (_kind != ExportKind.wavetable && _kind != ExportKind.midi)
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
      if (_job != null) ...[
        Bar(value: _job!.progress, color: Neon.yellow, height: 6),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: _job!.cancel, child: const Text('Cancel')),
      ] else if (_midiBusy || _saving) ...[
        const LinearProgressIndicator(minHeight: 4),
        const SizedBox(height: 10),
        Text(_midiBusy ? 'Preparing MIDI file…' : 'Preparing export destination…',
          style: const TextStyle(color: Neon.dim, fontSize: 12)),
      ] else
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: Neon.yellow, foregroundColor: Neon.bg, minimumSize: const Size.fromHeight(52)),
          onPressed: _export,
          icon: const Icon(Icons.download),
          label: Text(!_advanced ? 'Quick Export' : _kind == ExportKind.midi ? 'Export MIDI' : 'Export WAV',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
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
      case ExportKind.midi:
        return 'Export a project pattern as a standard MIDI file using the project tempo and time signature.';
    }
  }
}
