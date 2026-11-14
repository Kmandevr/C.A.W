// The focus view's Clip tab on an audio track: the sample editor over the selected audio clip's settings (gain,
// fades and their curves, Follows tempo, its tempo, stretch, pitch in semitones and cents, reverse, loop, mute, lock,
// takes), or the track's input and an import button when it has no clip.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/project.dart';
import '../../model/sample_edit.dart';
import '../audio_file_actions.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'audio_input_ui.dart';
import 'sample_editor.dart';
import 'take_chip.dart';
import 'track_color.dart';

class AudioClipInspector extends StatelessWidget {
  const AudioClipInspector({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: state, builder: (context, _) {
    final clip = state.focusedAudioClip(layer);
    final color = trackColor(state, layer);
    if (clip == null) {
      return ListView(key: const ValueKey('audio-inspector-empty'), padding: const EdgeInsets.all(12), children: [
        const Text('No audio clip on this track yet.', style: TextStyle(color: Neon.dim)),
        const SizedBox(height: 8),
        ListTile(key: const ValueKey('audio-inspector-import'), dense: true,
          leading: const Icon(Icons.graphic_eq_rounded, size: 18, color: Neon.green),
          title: const Text('Import audio onto this track'),
          subtitle: const Text('WAV, FLAC or MP3; or drag one from Files'),
          onTap: () => importAudioFiles(context, state, layer: layer)),
        AudioInputPanel(state: state, layer: layer),
      ]);
    }
    return _Inspector(key: ValueKey('audio-inspector-${clip.id}'), state: state, layer: layer, clip: clip, color: color);
  });
}

class _Inspector extends StatelessWidget {
  const _Inspector({super.key, required this.state, required this.layer, required this.clip, required this.color});
  final AppState state;
  final LayerDoc layer;
  final AudioClipDoc clip;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final asset = p.asset(clip.assetId);
    final seconds = clip.lengthAt(p.bpm) * 15 / p.bpm;
    Widget label(String t) => Padding(padding: const EdgeInsets.fromLTRB(0, 10, 0, 2),
        child: Text(t, style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800)));
    Widget row(String name, Widget child, {String? value}) => SizedBox(height: 40, child: Row(children: [
          SizedBox(width: 74, child: Text(name, style: const TextStyle(fontSize: 12))),
          Expanded(child: child),
          if (value != null) SizedBox(width: 64, child: Text(value, textAlign: TextAlign.right,
              style: Neon.code(size: 11, color: Neon.text))),
        ]));
    Widget curve(FadeCurve now, ValueChanged<FadeCurve> set, String key) => DropdownButton<FadeCurve>(
          key: ValueKey(key), value: now, isDense: true, underline: const SizedBox.shrink(),
          items: [for (final c in FadeCurve.values) DropdownMenuItem(value: c, child: Text(c.label, style: const TextStyle(fontSize: 12)))],
          onChanged: (c) { if (c != null) { Haptics.tick(); set(c); } });
    final maxFade = math.max(0.01, seconds);
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
      Row(children: [
        Icon(Icons.graphic_eq_rounded, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(state.audioClipName(clip), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w800, color: color))),
        if (clip.takes.length > 1) TakeChip.audio(state: state, layer: layer, audio: clip, color: color),
      ]),
      Text([
        if (asset == null) 'The file is missing' else asset.path.split(RegExp(r'[/\\]')).last,
        if ((asset?.seconds ?? 0) > 0) '${asset!.seconds.toStringAsFixed(2)} s file',
        '${seconds.toStringAsFixed(2)} s clip',
      ].join(' · '), style: const TextStyle(color: Neon.dim, fontSize: 11)),
      const SizedBox(height: 8),
      // The sample editor (batch 1.0.4): the whole file, big, with the clip's edges, fades and loop points, and
      // the tool row.
      SampleEditor(key: ValueKey('sample-editor-box-${clip.id}'), state: state, layer: layer, clip: clip, color: color),
      label('LEVEL'),
      row('Gain', Slider(key: const ValueKey('audio-gain-slider'), min: -60, max: 12,
          value: gainToDb(clip.gain).clamp(-60.0, 12.0),
          onChanged: (db) => state.editLayer(layer, (_) => clip.gain = dbToGain(db)),
          onChangeEnd: (_) => state.endUndoStep()), value: clip.gainLabel),
      row('Fade in', Slider(key: const ValueKey('audio-fade-in-slider'), min: 0, max: maxFade,
          value: clip.fadeIn.clamp(0.0, maxFade),
          onChanged: (v) => state.editLayer(layer, (_) => clip.fadeIn = math.min(v, maxFade - clip.fadeOut)),
          onChangeEnd: (_) => state.endUndoStep()), value: '${(clip.fadeIn * 1000).round()} ms'),
      Align(alignment: Alignment.centerRight, child: curve(clip.fadeInCurve,
          (c) => state.setAudioFades(layer, clip, inCurve: c), 'audio-fade-in-curve')),
      row('Fade out', Slider(key: const ValueKey('audio-fade-out-slider'), min: 0, max: maxFade,
          value: clip.fadeOut.clamp(0.0, maxFade),
          onChanged: (v) => state.editLayer(layer, (_) => clip.fadeOut = math.min(v, maxFade - clip.fadeIn)),
          onChangeEnd: (_) => state.endUndoStep()), value: '${(clip.fadeOut * 1000).round()} ms'),
      Align(alignment: Alignment.centerRight, child: curve(clip.fadeOutCurve,
          (c) => state.setAudioFades(layer, clip, outCurve: c), 'audio-fade-out-curve')),
      label('TIME AND PITCH'),
      _TimeAndPitch(state: state, layer: layer, clip: clip),
      label('CLIP'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        FilterChip(key: const ValueKey('audio-reverse'), label: const Text('Reverse'), selected: clip.reverse,
            onSelected: (_) { Haptics.tap(); state.reverseAudio(layer, clip); }),
        FilterChip(key: const ValueKey('audio-loop'), label: const Text('Loop'), selected: clip.loop,
            onSelected: (v) { Haptics.tap(); state.setAudioLoop(layer, clip, v); }),
        FilterChip(key: const ValueKey('audio-mute'), label: const Text('Mute'), selected: clip.mute,
            onSelected: (_) { Haptics.tap(); state.toggleAudioMute(layer, clip); }),
        FilterChip(key: const ValueKey('audio-lock'), label: const Text('Lock'), selected: clip.lock,
            onSelected: (_) { Haptics.tap(); state.toggleAudioLock(layer, clip); }),
        ActionChip(key: const ValueKey('audio-duplicate'), avatar: const Icon(Icons.copy, size: 16),
            label: const Text('Duplicate'), onPressed: () { Haptics.tap(); state.duplicateAudioClip(layer, clip); }),
        if (!clip.lock)
          ActionChip(key: const ValueKey('audio-delete'), avatar: const Icon(Icons.delete_outline, size: 16, color: Neon.pink),
              label: const Text('Delete'), onPressed: () { Haptics.tap(); state.removeAudioClip(layer, clip); }),
      ]),
      if (layer.audioClips.length > 1) ...[
        label('CLIPS ON THIS TRACK'),
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (final c in [...layer.audioClips]..sort((a, b) => a.startSteps.compareTo(b.startSteps)))
            ChoiceChip(visualDensity: VisualDensity.compact, label: Text(state.audioClipName(c)),
                selected: c.id == clip.id, onSelected: (_) => state.selectAudioClip(layer, c)),
        ]),
      ],
    ]);
  }
}

/// The clip tab's time and pitch (owner, 2026-11-14): the Follows tempo switch (off, with the reason, until the
/// clip's tempo is known), the clip's tempo (detected or typed), the stretch, Keep pitch or Varispeed, and pitch in
/// semitones and cents.
class _TimeAndPitch extends StatefulWidget {
  const _TimeAndPitch({required this.state, required this.layer, required this.clip});
  final AppState state;
  final LayerDoc layer;
  final AudioClipDoc clip;

  @override
  State<_TimeAndPitch> createState() => _TimeAndPitchState();
}

class _TimeAndPitchState extends State<_TimeAndPitch> {
  bool _detecting = false;
  String? _detectNote;

  AppState get s => widget.state;
  AudioClipDoc get c => widget.clip;

  Future<void> _detect() async {
    Haptics.tap();
    setState(() => _detecting = true);
    final est = await s.detectClipTempo(widget.layer, c);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      _detectNote = est == null ? 'Not sure of its tempo: type it in.'
          : 'Detected ${est.bpm.toStringAsFixed(1)} BPM (${(est.confidence * 100).round()}% sure).';
    });
  }

  Future<void> _type() async {
    final known = s.knownSourceBpm(c);
    var text = known == null ? '' : _bpmText(known);
    final v = await showDialog<double?>(context: context, builder: (context) => AlertDialog(
      title: const Text('Clip tempo'),
      content: TextFormField(key: const ValueKey('audio-tempo-field'), initialValue: text, autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'BPM', helperText: '20–999; empty: not known'),
          onChanged: (t) => text = t),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('audio-tempo-ok'), onPressed: () {
          final t = text.trim();
          Navigator.pop(context, t.isEmpty ? -1.0 : double.tryParse(t));
        }, child: const Text('OK')),
      ]));
    if (v == null || !mounted) return;
    s.setClipSourceBpm(widget.layer, c, v < 0 ? null : v);
  }

  static String _bpmText(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final p = s.project;
    final blocked = s.followsTempoBlocked(c);
    final known = s.knownSourceBpm(c);
    final semis = c.pitch.round(), cents = c.pitchCents - semis * 100;
    final seconds = c.lengthAt(p.bpm) * 15 / p.bpm;
    Widget row(String name, Widget child, {String? value}) => SizedBox(height: 40, child: Row(children: [
          SizedBox(width: 74, child: Text(name, style: const TextStyle(fontSize: 12))),
          Expanded(child: child),
          if (value != null) SizedBox(width: 64, child: Text(value, textAlign: TextAlign.right,
              style: Neon.code(size: 11, color: Neon.text))),
        ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(key: const ValueKey('audio-follows-tempo'), dense: true, contentPadding: EdgeInsets.zero,
        title: const Text('Follows tempo', style: TextStyle(fontSize: 13)),
        subtitle: Text(blocked ?? (c.followsTempo ? 'Locked to the bars from its tempo'
            : 'Plays at its own speed${c.stretchRatio != 1 ? ', stretched' : ''}'),
            key: const ValueKey('audio-follows-reason'), style: TextStyle(fontSize: 11,
                color: blocked != null ? Neon.yellow : Neon.dim)),
        value: c.followsTempo,
        onChanged: blocked != null && !c.followsTempo ? null : (v) {
          Haptics.tick();
          s.setAudioFollowsTempo(widget.layer, c, v);
        }),
      row('Tempo', Row(children: [
        TextButton(key: const ValueKey('audio-tempo'), onPressed: c.lock ? null : _type,
            child: Text(known == null ? 'Not known: set it' : '${_bpmText(known)} BPM${c.sourceBpm == null ? ' (file)' : ''}')),
        const Spacer(),
        IconButton(key: const ValueKey('audio-tempo-detect'), tooltip: 'Detect from its hits', iconSize: 18,
            onPressed: _detecting || c.lock ? null : _detect,
            icon: _detecting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_outlined)),
      ])),
      AnimatedSwitcher(duration: EditMotion.of(context, EditMotionKind.panels) ?? Duration.zero,
        child: _detectNote == null ? const SizedBox(key: ValueKey('tempo-note-none'))
            : Text(_detectNote!, key: ValueKey('tempo-note-$_detectNote'),
                style: const TextStyle(color: Neon.dim, fontSize: 11))),
      if (c.fixed)
        row('Stretch', Text('×${c.stretchRatio.toStringAsFixed(2)} · drag the clip\'s corner notch',
            key: const ValueKey('audio-stretch-ratio'), style: const TextStyle(color: Neon.dim, fontSize: 11)),
            value: '${seconds.toStringAsFixed(2)} s'),
      const SizedBox(height: 4),
      // Keep pitch is the clip's own keep-pitch algorithm (a WSOLA clip keeps its sound), else the new one.
      SegmentedButton<bool>(
        key: const ValueKey('audio-stretch'),
        segments: const [
          ButtonSegment(value: true, label: Text('Keep pitch'), tooltip: 'Time-stretch'),
          ButtonSegment(value: false, label: Text('Varispeed'), tooltip: 'Pitch moves with speed'),
        ],
        selected: {c.stretch.keepsPitch},
        onSelectionChanged: (v) {
          Haptics.tick();
          s.setAudioStretch(widget.layer, c, v.first ? AudioStretch.keepPitch : AudioStretch.varispeed);
        }),
      row('Pitch', Row(children: [
        IconButton(key: const ValueKey('audio-pitch-down'), iconSize: 18, icon: const Icon(Icons.remove),
            onPressed: () { Haptics.tick(); s.setAudioPitchCents(widget.layer, c, c.pitchCents - 100); }),
        Expanded(child: Slider(key: const ValueKey('audio-pitch-slider'), min: -24, max: 24, divisions: 48,
            value: semis.clamp(-24, 24).toDouble(),
            onChanged: (v) => s.editLayer(widget.layer, (_) => setAudioClipPitch(c, v.round() + cents / 100)),
            onChangeEnd: (_) => s.endUndoStep())),
        IconButton(key: const ValueKey('audio-pitch-up'), iconSize: 18, icon: const Icon(Icons.add),
            onPressed: () { Haptics.tick(); s.setAudioPitchCents(widget.layer, c, c.pitchCents + 100); }),
      ]), value: '${semis > 0 ? '+' : ''}$semis st'),
      row('Cents', Slider(key: const ValueKey('audio-cents-slider'), min: -50, max: 50, divisions: 100,
          value: cents.clamp(-50, 50).toDouble(),
          onChanged: (v) => s.editLayer(widget.layer, (_) => setAudioClipPitch(c, semis + v.round() / 100)),
          onChangeEnd: (_) => s.endUndoStep()), value: '${cents > 0 ? '+' : ''}$cents ct'),
    ]);
  }
}
