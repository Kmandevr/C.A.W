// What audio recording tells the user, around the transport: "Keep take?" with Undo after each recording, its one-line
// problems (permission, dropped frames), and, when a project opens, the takes a crash left unfinished to add back.
import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/audio_engine.dart';
import '../model/app_state.dart';
import '../model/audio_edit.dart';
import '../model/audio_record.dart';
import 'haptics.dart';
import 'panel_motion.dart';

class AudioRecordFeedback extends StatefulWidget {
  const AudioRecordFeedback({super.key, required this.state, required this.child, this.recorder});
  final AppState state;
  final Widget child;

  /// The recorder to follow ([AudioRecorder.current] by default).
  final AudioRecorder? recorder;

  @override
  State<AudioRecordFeedback> createState() => _AudioRecordFeedbackState();
}

/// The project ids whose recordings folder was already checked this run (one dialog per project, per app run).
final Set<String> _checked = {};

class _AudioRecordFeedbackState extends State<AudioRecordFeedback> {
  AudioRecorder? get r => widget.recorder ?? AudioRecorder.current;
  AudioRecording? _shown;
  String? _project;

  @override
  void initState() {
    super.initState();
    r?.lastRecording.addListener(_recorded);
    r?.message.addListener(_message);
    widget.state.addListener(_projectChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _projectChanged());
  }

  @override
  void dispose() {
    r?.lastRecording.removeListener(_recorded);
    r?.message.removeListener(_message);
    widget.state.removeListener(_projectChanged);
    super.dispose();
  }

  void _recorded() {
    final rec = r, t = rec?.lastRecording.value;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (rec == null || t == null || identical(t, _shown) || messenger == null || t.clipIds.isEmpty) return;
    _shown = t;
    Haptics.drop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('audio-take-toast'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        content: Text(t.takes > t.clipIds.length
            ? 'Keep take? ${t.takes} takes in ${t.clipIds.length} clip${t.clipIds.length == 1 ? '' : 's'} (the take chip steps through them)'
            : 'Keep take? ${t.clipIds.length} audio clip${t.clipIds.length == 1 ? '' : 's'} recorded'),
        action: SnackBarAction(label: 'Undo', onPressed: () => rec.discard(t)),
      ));
  }

  void _message() {
    final text = r?.message.value;
    if (text == null || !mounted) return;
    r!.message.value = null;
    Haptics.error();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  /// A project opened: its recordings folder is checked once for takes a crash left.
  void _projectChanged() {
    final s = widget.state, rec = r;
    if (rec == null || !s.ready || s.starting) return;
    final id = s.project.id;
    if (id == _project) return;
    _project = id;
    if (!_checked.add(id)) return;
    unawaited(_recover(rec, id));
  }

  Future<void> _recover(AudioRecorder rec, String projectId) async {
    final List<RecordedAudioTake> takes;
    try {
      takes = await rec.recover();
    } catch (_) {
      return;
    }
    if (takes.isEmpty || !mounted || widget.state.project.id != projectId) return;
    final add = await showRecoveredTakes(context, takes);
    if (add == true && mounted) {
      final placed = rec.placeTakes(takes, recovered: true);
      Haptics.drop();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('Added ${placed.clipIds.length} recovered clip${placed.clipIds.length == 1 ? '' : 's'}')));
    } else if (mounted) {
      // Kept for later: Files › Audio files lists them (they would not be offered again).
      for (final t in takes) {
        widget.state.addAssetFor(t.path, recorded: true, seconds: t.seconds);
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Asks whether to add the takes a crash left (each named, with its length) to the project.
Future<bool?> showRecoveredTakes(BuildContext context, List<RecordedAudioTake> takes) => showDialog<bool>(
      context: context, animationStyle: dialogAnimation(context),
      builder: (context) => AlertDialog(
        key: const ValueKey('audio-recovery'),
        title: const Text('Recover recordings?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('C.A.W stopped while recording. ${takes.length} take${takes.length == 1 ? ' was' : 's were'} saved up to '
              'that moment.'),
          const SizedBox(height: 8),
          for (final t in takes.take(6))
            Text('• ${t.path.split(RegExp(r'[/\\]')).last} · ${t.seconds.toStringAsFixed(1)} s',
                style: const TextStyle(fontSize: 12)),
          if (takes.length > 6) Text('and ${takes.length - 6} more', style: const TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep in Files')),
          FilledButton(key: const ValueKey('audio-recovery-add'), onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Add as clips')),
        ],
      ),
    );
