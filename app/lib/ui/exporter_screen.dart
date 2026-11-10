// Exporter: render a loop, a free-length take, a one-shot or a wavetable to WAV, then save it with the system picker.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/project.dart';
import '../platform/save_copy.dart';
import '../model/settings.dart';
import 'theme.dart';
import 'widgets.dart';

class _QueuedExport {
  const _QueuedExport({
    required this.fileName,
    required this.projectJson,
    required this.kind,
    required this.sampleRate,
    required this.float32,
    required this.seconds,
    required this.target,
    required this.param,
    required this.frames,
    required this.patternSource,
    required this.bpm,
    required this.beatsPerBar,
  });

  final String fileName, projectJson, target, param, patternSource;
  final ExportKind kind;
  final int sampleRate, frames, beatsPerBar;
  final bool float32;
  final double seconds, bpm;
}

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
  String? _profileName;
  final List<_QueuedExport> _queue = [];
  bool _queueRunning = false;
  bool _cancelQueueRequested = false;
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
        // With the loop range on, the export is that range (the engine's loop export bounds).
        final steps = p.loopsRange ? p.loopEndSteps - p.loopStartSteps : p.engineLoopSteps;
        final bars = steps % p.stepsPerBar == 0 ? '${steps ~/ p.stepsPerBar}bars' : '${steps}steps';
        return '${base}_${bpm}bpm_$bars.wav';
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

  void _applyProfile(ExportProfile profile) {
    setState(() {
      _profileName = profile.name;
      _kind = ExportKind.values.firstWhere((kind) => kind.name == profile.kind,
        orElse: () => ExportKind.loop);
      _advanced = true;
      _rate = profile.sampleRate;
      _float = profile.float32;
      _seconds = profile.seconds;
      _frames = profile.frames;
    });
  }

  void _applyHistory(ExportHistoryEntry entry) {
    setState(() {
      _profileName = null;
      _kind = ExportKind.values.firstWhere((kind) => kind.name == entry.kind,
        orElse: () => ExportKind.loop);
      _advanced = true;
      _rate = entry.sampleRate;
      _float = entry.float32;
      _seconds = entry.seconds;
      _frames = entry.frames;
      if (entry.kind == ExportKind.oneShot.name &&
          s.project.layers.any((layer) => layer.id == entry.target)) {
        _layerId = entry.target;
      }
      if (entry.kind == ExportKind.wavetable.name &&
          s.project.modules.any((module) => module.id == entry.target)) {
        _moduleId = entry.target;
      }
      if (entry.kind == ExportKind.midi.name &&
          s.project.module(entry.target) != null && s.isPattern(entry.target)) {
        _patternId = entry.target;
      }
      _param = entry.param.isEmpty ? null : entry.param;
    });
  }

  Future<void> _saveProfile() async {
    final controller = TextEditingController(text: _profileName ?? 'My export');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save export profile'),
        content: TextField(controller: controller, autofocus: true,
          maxLength: 64, decoration: const InputDecoration(labelText: 'Profile name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save profile')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final profile = ExportProfile(name: name.trim(), kind: _kind.name,
      sampleRate: _rate, float32: _float, seconds: _seconds, frames: _frames);
    try {
      final saved = await s.settings.saveExportProfile(profile);
      if (mounted) {
        setState(() {
          _profileName = saved ? profile.name : null;
          if (!saved) {
            _message = 'Profile limit reached (32) or the name is invalid.';
            _messageIsError = true;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Profile could not be saved: $e';
          _messageIsError = true;
        });
      }
    }
  }

  Future<void> _deleteProfile() async {
    final name = _profileName;
    if (name == null) return;
    try {
      await s.settings.deleteExportProfile(name);
      if (mounted) setState(() => _profileName = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Profile could not be deleted: $e';
          _messageIsError = true;
        });
      }
    }
  }

  void _addToQueue() {
    if (_queue.length >= 50) {
      setState(() { _message = 'Export queue limit reached (50 items).'; _messageIsError = true; });
      return;
    }
    final pattern = s.project.module(_patternId);
    final target = switch (_kind) {
      ExportKind.oneShot => _layerId ?? '',
      ExportKind.wavetable => _moduleId ?? '',
      ExportKind.midi => pattern?.id ?? '',
      _ => '',
    };
    if ((_kind == ExportKind.oneShot && target.isEmpty) ||
        (_kind == ExportKind.wavetable && target.isEmpty) ||
        (_kind == ExportKind.midi && (pattern == null || !s.isPattern(pattern.id)))) {
      setState(() { _message = 'Choose a valid export target before queueing.'; _messageIsError = true; });
      return;
    }
    final item = _QueuedExport(
      fileName: _fileName(),
      projectJson: s.project.toEngineJson(),
      kind: _kind,
      sampleRate: _rate,
      float32: _float,
      seconds: _seconds,
      target: target,
      param: _param ?? '',
      frames: _frames,
      patternSource: pattern?.source ?? '',
      bpm: s.project.bpm,
      beatsPerBar: s.project.beatsPerBar,
    );
    setState(() {
      _queue.add(item);
      _message = 'Added ${item.fileName} to the export queue.';
      _messageIsError = false;
    });
  }

  void _cancelQueue() {
    _cancelQueueRequested = true;
    _job?.cancel();
  }

  Future<bool> _runQueuedItem(_QueuedExport item) async {
    File? file;
    try {
      final tmp = await getTemporaryDirectory();
      final path = '${tmp.path}${Platform.pathSeparator}${item.fileName}';
      final outputFile = File(path);
      file = outputFile;
      if (item.kind == ExportKind.midi) {
        final source = item.patternSource;
        final bpm = item.bpm;
        final beatsPerBar = item.beatsPerBar;
        final error = await Isolate.run(() => Engine.exportPattern(source, path,
          bpm: bpm, beatsPerBar: beatsPerBar));
        if (error != null) throw StateError(error);
        if (_cancelQueueRequested) return false;
      } else {
        final job = RenderJob.start(RenderRequest(
          projectJson: item.projectJson,
          kind: item.kind,
          outPath: path,
          sampleRate: item.sampleRate,
          float32: item.float32,
          seconds: item.seconds,
          target: item.target,
          param: item.param,
          frames: item.frames,
        ));
        if (!mounted) {
          job.cancel();
          return false;
        }
        setState(() => _job = job);
        _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (mounted) setState(() {});
        });
        final error = await job.result;
        if (error != null) {
          if (mounted) {
            setState(() {
              _message = error == 'cancelled' ? 'Queued export cancelled.' : 'Queued export failed: $error';
              _messageIsError = error != 'cancelled';
            });
          }
          return false;
        }
      }

      if (!mounted) return false;
      setState(() => _saving = true);
      final midi = item.kind == ExportKind.midi;
      final saved = await saveCopyOf(outputFile,
          name: item.fileName, mimeType: midi ? 'audio/midi' : 'audio/wav', extension: midi ? 'mid' : 'wav');
      if (!saved) {
        if (mounted) {
          setState(() { _message = 'Queue paused: destination picker closed.'; _messageIsError = false; });
        }
        return false;
      }
      String? warning;
      try {
        await s.settings.recordExport(ExportHistoryEntry(
          fileName: item.fileName,
          kind: item.kind.name,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          sampleRate: item.sampleRate,
          float32: item.float32,
          seconds: item.seconds,
          frames: item.frames,
          target: item.target,
          param: item.param,
        ));
      } catch (e) {
        warning = 'Export saved, but history could not be updated: $e';
      }
      if (mounted) {
        setState(() {
          _message = warning ?? 'Saved ${item.fileName}';
          _messageIsError = warning != null;
        });
      }
      return true;
    } catch (e) {
      if (mounted) setState(() { _message = 'Queued export failed: $e'; _messageIsError = true; });
      return false;
    } finally {
      _poll?.cancel();
      _poll = null;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Temporary-file cleanup must not hide the export result.
        }
      }
      if (mounted) {
        setState(() {
          _job = null;
          _saving = false;
        });
      }
    }
  }

  Future<void> _runQueue() async {
    if (_queueRunning || _queue.isEmpty) return;
    _cancelQueueRequested = false;
    setState(() { _queueRunning = true; _message = null; });
    final total = _queue.length;
    var completed = 0;
    try {
      while (_queue.isNotEmpty && mounted && !_cancelQueueRequested) {
        final item = _queue.first;
        if (mounted) {
          setState(() {
            _message = 'Queue ${completed + 1} of $total · ${item.fileName}';
            _messageIsError = false;
          });
        }
        final saved = await _runQueuedItem(item);
        if (!saved) break;
        if (mounted) setState(() => _queue.removeAt(0));
        completed++;
      }
      if (mounted && _cancelQueueRequested) {
        setState(() { _message = 'Queue cancelled. Remaining items were kept.'; _messageIsError = false; });
      }
    } finally {
      if (mounted) setState(() => _queueRunning = false);
    }
  }

  Future<String?> _recordExport(String fileName) async {
    try {
      await s.settings.recordExport(ExportHistoryEntry(
        fileName: fileName,
        kind: _kind.name,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        sampleRate: _rate,
        float32: _float,
        seconds: _seconds,
        frames: _frames,
        target: switch (_kind) {
          ExportKind.oneShot => _layerId ?? '',
          ExportKind.wavetable => _moduleId ?? '',
          ExportKind.midi => _patternId ?? '',
          _ => '',
        },
        param: _param ?? '',
      ));
      return null;
    } catch (e) {
      return 'Export saved, but history could not be updated: $e';
    }
  }

  Future<void> _export() async {
    if (_job != null || _midiBusy || _saving || _queueRunning) return;
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
    try {
      final tmp = await getTemporaryDirectory();
      final name = _fileName();
      final path = '${tmp.path}${Platform.pathSeparator}$name';
      final outputFile = File(path);
      file = outputFile;
      final startedJob = RenderJob.start(RenderRequest(
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
        startedJob.cancel();
        return;
      }
      setState(() {
        _job = startedJob;
        _message = null;
      });
      _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });

      final error = await startedJob.result;
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

      final saved = await saveCopyOf(outputFile, name: name, mimeType: 'audio/wav', extension: 'wav');
      final historyWarning = saved ? await _recordExport(name) : null;
      if (!mounted) return;
      setState(() {
        _message = historyWarning ?? (!saved ? 'Not saved (picker closed).' : 'Saved $name');
        _messageIsError = historyWarning != null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Export failed: $e';
          _messageIsError = true;
        });
      }
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
      final source = module.source;
      final bpm = s.project.bpm;
      final beatsPerBar = s.project.beatsPerBar;
      final outputPath = file.path;
      final error = await Isolate.run(() => Engine.exportPattern(source, outputPath,
        bpm: bpm, beatsPerBar: beatsPerBar));
      if (error != null) throw StateError(error);
      final saved = await saveCopyOf(file, name: name, mimeType: 'audio/midi', extension: 'mid');
      final historyWarning = saved ? await _recordExport(name) : null;
      if (!mounted) return;
      setState(() {
        _message = historyWarning ?? (!saved ? 'Not saved (picker closed).' : 'Saved $name');
        _messageIsError = historyWarning != null;
      });
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
    final layers = p.layers.where((l) => l.generatorId != null || l.instrument != null).toList();
    if (_layerId == null || !layers.any((l) => l.id == _layerId)) _layerId = layers.firstOrNull?.id;
    final modules = p.modules.where((m) => (s.info[m.id]?.ok ?? false) && !s.isLibrary(m.id)).toList();
    final patterns = p.modules.where((m) => s.isPattern(m.id)).toList();
    if (_patternId == null || !patterns.any((m) => m.id == _patternId)) _patternId = patterns.firstOrNull?.id;
    if (_moduleId == null || !modules.any((m) => m.id == _moduleId)) {
      _moduleId = (modules.where((m) => s.isGenerator(m.id)).firstOrNull ?? modules.firstOrNull)?.id;
    }
    final params = s.info[_moduleId]?.params ?? const <ParamInfo>[];
    if (_param != null && !params.any((x) => x.name == _param)) _param = null;
    final busy = _job != null || _midiBusy || _saving || _queueRunning;
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
      const SizedBox(height: 12),
      ListenableBuilder(
        listenable: s.settings,
        builder: (context, _) {
          final profiles = s.settings.exportProfiles;
          final history = s.settings.exportHistory.take(5).toList();
          final selectedProfile = profiles.any((profile) => profile.name == _profileName)
            ? _profileName : null;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('EXPORT PROFILES', style: TextStyle(color: Neon.blue, fontWeight: FontWeight.w800)),
              Row(children: [
                Expanded(child: DropdownButton<String>(
                  value: selectedProfile,
                  isExpanded: true,
                  hint: const Text('Choose a saved profile'),
                  underline: const SizedBox.shrink(),
                  items: [for (final profile in profiles)
                    DropdownMenuItem(value: profile.name, child: Text(profile.name))],
                  onChanged: busy ? null : (name) {
                    final profile = profiles.where((item) => item.name == name).firstOrNull;
                    if (profile != null) _applyProfile(profile);
                  },
                )),
                IconButton(tooltip: 'Save current export profile',
                  onPressed: busy ? null : _saveProfile, icon: const Icon(Icons.bookmark_add_outlined)),
                IconButton(tooltip: 'Delete selected export profile',
                  onPressed: busy || selectedProfile == null ? null : _deleteProfile,
                  icon: const Icon(Icons.delete_outline)),
              ]),
            ])),
            if (history.isNotEmpty) ...[
              const SizedBox(height: 8),
              NeonPanel(color: Neon.yellow, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('RECENT EXPORTS', style: TextStyle(color: Neon.yellow, fontWeight: FontWeight.w800)),
                for (final entry in history)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${entry.kind} · ${entry.sampleRate ~/ 1000} kHz · ${DateTime.fromMillisecondsSinceEpoch(entry.createdAtMs).toLocal()}',
                      style: const TextStyle(color: Neon.dim, fontSize: 10)),
                    trailing: TextButton(
                      onPressed: busy ? null : () => _applyHistory(entry),
                      child: const Text('Use settings'),
                    ),
                  ),
              ])),
            ],
          ]);
        },
      ),
      if (_advanced) ...[
        const SizedBox(height: 12),
        const Heading('What to export'),
        LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return InputDecorator(
              decoration: const InputDecoration(labelText: 'Export type'),
              child: DropdownButtonHideUnderline(child: DropdownButton<ExportKind>(
                value: _kind,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: ExportKind.loop, child: Text('Loop')),
                  DropdownMenuItem(value: ExportKind.free, child: Text('Length')),
                  DropdownMenuItem(value: ExportKind.oneShot, child: Text('One-shot')),
                  DropdownMenuItem(value: ExportKind.wavetable, child: Text('Wavetable')),
                  DropdownMenuItem(value: ExportKind.midi, child: Text('MIDI')),
                ],
                onChanged: busy ? null : (value) {
                  if (value != null) setState(() => _kind = value);
                },
              )),
            );
          }
          return SegmentedButton<ExportKind>(
            segments: const [
              ButtonSegment(value: ExportKind.loop, label: Text('Loop')),
              ButtonSegment(value: ExportKind.free, label: Text('Length')),
              ButtonSegment(value: ExportKind.oneShot, label: Text('One-shot')),
              ButtonSegment(value: ExportKind.wavetable, label: Text('Table')),
              ButtonSegment(value: ExportKind.midi, label: Text('MIDI')),
            ],
            selected: {_kind},
            showSelectedIcon: false,
            onSelectionChanged: busy ? null : (value) => setState(() => _kind = value.first),
          );
        }),
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
              isExpanded: true,
              hint: const Text('No layers with a generator'),
              items: [for (final l in layers) DropdownMenuItem(value: l.id, child: Text(l.name))],
              onChanged: busy ? null : (v) => setState(() => _layerId = v),
            ),
          if (_kind == ExportKind.midi)
            DropdownButton<String>(
              value: _patternId,
              isExpanded: true,
              hint: const Text('No MIDI patterns in this project'),
              items: [for (final m in patterns) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: busy ? null : (v) => setState(() => _patternId = v),
            ),
          if (_kind == ExportKind.wavetable) ...[
            DropdownButton<String>(
              value: _moduleId,
              isExpanded: true,
              hint: const Text('No compiled modules'),
              items: [for (final m in modules) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: busy ? null : (v) => setState(() => _moduleId = v),
            ),
            LayoutBuilder(builder: (context, constraints) {
              final sweep = DropdownButton<String?>(
                value: _param,
                isExpanded: constraints.maxWidth < 560,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('nothing')),
                  for (final x in params) DropdownMenuItem<String?>(value: x.name,
                    child: Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: busy ? null : (v) => setState(() => _param = v),
              );
              final frames = DropdownButton<int>(
                value: _frames,
                isExpanded: constraints.maxWidth < 560,
                items: [for (final f in [1, 8, 16, 32, 64, 128, 256]) DropdownMenuItem(value: f, child: Text('$f'))],
                onChanged: busy ? null : (v) => setState(() => _frames = v!),
              );
              if (constraints.maxWidth < 560) {
                return Column(children: [
                  Row(children: [const SizedBox(width: 54, child: Text('Sweep')),
                    Expanded(child: sweep)]),
                  Row(children: [const SizedBox(width: 54, child: Text('Frames')),
                    Expanded(child: frames)]),
                ]);
              }
              return Row(children: [const Text('Sweep '), sweep, const SizedBox(width: 16),
                const Text('Frames '), frames]);
            }),
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
        OutlinedButton(onPressed: _queueRunning ? _cancelQueue : _job!.cancel,
          child: Text(_queueRunning ? 'Cancel queue' : 'Cancel export')),
      ] else if (_midiBusy || _saving || _queueRunning) ...[
        const LinearProgressIndicator(minHeight: 4),
        const SizedBox(height: 10),
        Text(_queueRunning ? 'Export queue running…' : _midiBusy ? 'Preparing MIDI file…' : 'Preparing export destination…',
          style: const TextStyle(color: Neon.dim, fontSize: 12)),
        if (_queueRunning)
          OutlinedButton(onPressed: _cancelQueue, child: const Text('Cancel queue')),
      ] else
        Row(children: [
          Expanded(child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Neon.yellow, foregroundColor: Neon.bg, minimumSize: const Size.fromHeight(52)),
            onPressed: _export,
            icon: const Icon(Icons.download),
            label: Text(!_advanced ? 'Quick Export' : _kind == ExportKind.midi ? 'Export MIDI' : 'Export WAV',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          )),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : _addToQueue,
            icon: const Icon(Icons.playlist_add),
            label: const Text('Queue'),
          ),
        ]),
      if (_queue.isNotEmpty) ...[
        const SizedBox(height: 12),
        NeonPanel(color: Neon.blue, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('EXPORT QUEUE · ${_queue.length}', style: const TextStyle(color: Neon.blue, fontWeight: FontWeight.w800))),
            TextButton(onPressed: busy ? null : () => setState(() => _queue.clear()), child: const Text('Clear')),
            FilledButton.tonal(onPressed: busy ? null : _runQueue, child: const Text('Run queue')),
          ]),
          for (final item in _queue)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item.kind.name} · ${item.sampleRate ~/ 1000} kHz',
                style: const TextStyle(color: Neon.dim, fontSize: 10)),
              trailing: IconButton(
                tooltip: 'Remove queued export',
                onPressed: busy ? null : () => setState(() => _queue.remove(item)),
                icon: const Icon(Icons.close),
              ),
            ),
        ])),
      ],
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_message!, style: TextStyle(color: _messageIsError ? Neon.pink : Neon.green)),
        ),
    ]);
  }

  /// A song position as bar.beat (1-based), the ruler's numbering.
  static String _barBeat(ProjectDoc p, int steps) => '${steps ~/ p.stepsPerBar + 1}.${steps % p.stepsPerBar ~/ 4 + 1}';

  String _describe() {
    final p = s.project;
    switch (_kind) {
      case ExportKind.loop when p.loopsRange:
        final seconds = (p.loopEndSteps - p.loopStartSteps) * 15.0 / p.bpm;
        return 'The loop range drawn on the ruler, from bar ${_barBeat(p, p.loopStartSteps)} to '
            '${_barBeat(p, p.loopEndSteps)} (${seconds.toStringAsFixed(3)} s), as it sounds when it repeats. '
            'Turn the loop range off in Arrange to export the whole song.';
      case ExportKind.loop:
        return 'The whole mix, exactly ${p.engineLoopSteps ~/ p.stepsPerBar} bars at ${p.bpm.toStringAsFixed(1)} BPM '
            '(${p.songSeconds.toStringAsFixed(3)} s), with loop points. Drops onto Reaper\'s grid.';
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
