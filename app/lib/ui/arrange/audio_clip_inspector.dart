// The focus view's Clip tab on an audio track: the selected audio clip's settings (gain, pitch, fades and their
// curves, fixed or musical, the stretch, reverse, loop, mute, lock, takes) over the whole file's waveform, or the
// track's input and an import button when it has no clip.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/project.dart';
import '../audio_file_actions.dart';
import '../haptics.dart';
import '../theme.dart';
import 'audio_input_ui.dart';
import 'audio_waveform.dart';
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
      // The whole file, the part this clip plays lit.
      if (asset != null && asset.seconds > 0)
        SizedBox(height: 56, child: LayoutBuilder(builder: (context, box) {
          final per = asset.seconds / math.max(1, box.maxWidth);
          final used = clip.sourceSeconds(p.bpm, asset.bpm);
          final from = clip.reverse ? asset.seconds - clip.offsetSeconds - used : clip.offsetSeconds;
          return Stack(children: [
            Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(4)))),
            Positioned.fill(child: CustomPaint(key: const ValueKey('audio-inspector-wave'), painter: AudioClipPainter(
              peaks: () => WaveformCache.instance.peaks(state.audioIo, asset.path, asset.seconds, per),
              window: ClipWindow(offset: 0, perPixel: per, fileSeconds: asset.seconds),
              color: Neon.dim, gain: 1, fadeIn: 0, fadeOut: 0, inCurve: FadeCurve.linear, outCurve: FadeCurve.linear,
              path: asset.path))),
            Positioned(left: (from / per).clamp(0, box.maxWidth), top: 0, bottom: 0,
              width: math.max(2.0, math.min(used, asset.seconds) / per),
              child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.22), border: Border.all(color: color))))),
          ]);
        })),
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
      SegmentedButton<AudioClipMode>(
        key: const ValueKey('audio-mode'),
        segments: const [
          ButtonSegment(value: AudioClipMode.fixed, label: Text('Fixed'), icon: Icon(Icons.timer_outlined, size: 16),
              tooltip: 'Plays at the file\'s speed: a tempo change moves it, never stretches it'),
          ButtonSegment(value: AudioClipMode.musical, label: Text('Musical'), icon: Icon(Icons.music_note, size: 16),
              tooltip: 'Follows the tempo, locked to the bars'),
        ],
        selected: {clip.mode},
        onSelectionChanged: (v) { Haptics.tick(); state.setAudioMode(layer, clip, v.first); }),
      const SizedBox(height: 6),
      SegmentedButton<AudioStretch>(
        key: const ValueKey('audio-stretch'),
        segments: const [
          ButtonSegment(value: AudioStretch.wsola, label: Text('Keep pitch'), tooltip: 'Time-stretch (WSOLA)'),
          ButtonSegment(value: AudioStretch.varispeed, label: Text('Varispeed'), tooltip: 'Pitch moves with speed'),
        ],
        selected: {clip.stretch},
        onSelectionChanged: (v) { Haptics.tick(); state.setAudioStretch(layer, clip, v.first); }),
      row('Pitch', Row(children: [
        IconButton(key: const ValueKey('audio-pitch-down'), iconSize: 18, icon: const Icon(Icons.remove),
            onPressed: () { Haptics.tick(); state.setAudioPitch(layer, clip, clip.pitch - 1); }),
        Expanded(child: Slider(key: const ValueKey('audio-pitch-slider'), min: -24, max: 24, divisions: 48,
            value: clip.pitch.clamp(-24.0, 24.0),
            onChanged: (v) => state.editLayer(layer, (_) => setAudioClipPitch(clip, v)),
            onChangeEnd: (_) => state.endUndoStep())),
        IconButton(key: const ValueKey('audio-pitch-up'), iconSize: 18, icon: const Icon(Icons.add),
            onPressed: () { Haptics.tick(); state.setAudioPitch(layer, clip, clip.pitch + 1); }),
      ]), value: '${clip.pitch > 0 ? '+' : ''}${clip.pitch.round()} st'),
      if (!clip.fixed)
        row('Source', Slider(key: const ValueKey('audio-source-bpm'), min: 40, max: 240, divisions: 200,
            value: clip.sourceTempo(p.bpm, asset?.bpm).clamp(40.0, 240.0),
            onChanged: (v) => state.editLayer(layer, (_) => clip.sourceBpm = v.roundToDouble()),
            onChangeEnd: (_) => state.endUndoStep()),
            value: '${clip.sourceTempo(p.bpm, asset?.bpm).round()} BPM'),
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
