// An audio track's input in the arranger: the arm button (tap arms, asking for the microphone first; hold for the
// input), the input sheet (channel, mono or stereo, monitoring) and the input meter shown while armed.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/audio_clips.dart';
import '../../model/audio_edit.dart';
import '../../model/audio_record.dart';
import '../../model/project.dart';
import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// Arms [layer] or disarms it (the arm button, the track menu): arming opens the input with the permission.
Future<void> toggleAudioArm(BuildContext context, AppState state, LayerDoc layer) async {
  final rec = AudioRecorder.current;
  final on = !(layer.input?.armed ?? false);
  Haptics.tap();
  if (rec == null) {
    state.setAudioArmed(layer, on);
    return;
  }
  final ok = await rec.arm(layer, on);
  if (!ok && context.mounted) {
    Haptics.error();
    _say(context, rec.message.value ?? 'Audio input did not open.');
  }
}

/// The record-arm button on an audio track's header: red ring off, filled red armed. A long-press (right-click)
/// opens the input sheet.
class AudioArmButton extends StatelessWidget {
  const AudioArmButton({super.key, required this.state, required this.layer, this.size = 24});
  final AppState state;
  final LayerDoc layer;
  final double size;

  @override
  Widget build(BuildContext context) {
    final armed = layer.input?.armed ?? false;
    return Tooltip(
      message: armed ? 'Armed: Record records ${layer.input!.label} (hold for the input)' : 'Record arm (hold for the input)',
      child: Semantics(button: true, toggled: armed, label: 'Record arm ${layer.name}', excludeSemantics: true,
        child: GestureDetector(
          key: ValueKey('audio-arm-${layer.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => toggleAudioArm(context, state, layer),
          onLongPress: () => showAudioInputSheet(context, state, layer),
          onSecondaryTap: () => showAudioInputSheet(context, state, layer),
          child: SizedBox(width: size + 6, height: size, child: Center(child: Pressable(glow: Neon.pink, child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: size - 8, height: size - 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: armed ? Neon.pink : Colors.transparent,
              border: Border.all(color: armed ? Neon.pink : Neon.pink.withValues(alpha: 0.7), width: 1.6),
              boxShadow: armed ? Neon.glow(Neon.pink, strength: 0.45) : null),
          )))),
        )),
    );
  }
}

/// The input level of an armed track, a thin bar in the header (green, yellow near the top, red at clipping).
class AudioInputMeter extends StatelessWidget {
  const AudioInputMeter({super.key, required this.layer, this.height = 6});
  final LayerDoc layer;
  final double height;

  @override
  Widget build(BuildContext context) {
    final rec = AudioRecorder.current;
    if (rec == null) {
      return CustomPaint(key: ValueKey('audio-input-meter-${layer.id}'), size: Size(double.infinity, height),
          painter: InputMeterPainter(0));
    }
    return ValueListenableBuilder<List<double>>(valueListenable: rec.levels, builder: (context, _, _) {
      final v = rec.levelOf(layer);
      return CustomPaint(key: ValueKey('audio-input-meter-${layer.id}'), size: Size(double.infinity, height),
          painter: InputMeterPainter(v));
    });
  }
}

class InputMeterPainter extends CustomPainter {
  InputMeterPainter(this.level);
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2));
    canvas.drawRRect(r, Paint()..color = Colors.black.withValues(alpha: 0.35));
    // On a dB scale: -60..0 dB across the bar.
    final db = level <= 0.001 ? -60.0 : 20 * math.log(level) / math.ln10;
    final f = ((db + 60) / 60).clamp(0.0, 1.0);
    final color = level >= 1 ? Neon.pink : db > -6 ? Neon.yellow : Neon.green;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width * f, size.height), const Radius.circular(2)),
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant InputMeterPainter old) => old.level != level;
}

/// The track's input: which device channel(s), mono or stereo, and monitoring (off, auto, on).
Future<void> showAudioInputSheet(BuildContext context, AppState state, LayerDoc layer) {
  Haptics.tap();
  return showGlassSheet<void>(context: context, showDragHandle: true, isScrollControlled: true,
      builder: (_) => AudioInputPanel(state: state, layer: layer));
}

class AudioInputPanel extends StatelessWidget {
  const AudioInputPanel({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: state, builder: (context, _) {
    final input = layer.input ?? AudioInputDoc();
    final rec = AudioRecorder.current;
    final deviceChannels = rec == null ? 2 : math.max(1, rec.prefs.channels);
    Widget label(String t) => Padding(padding: const EdgeInsets.fromLTRB(0, 12, 0, 6),
        child: Text(t, style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800)));
    return SafeArea(child: Padding(
      key: const ValueKey('audio-input-panel'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${layer.name} · input', style: const TextStyle(fontWeight: FontWeight.w800))),
          AudioArmButton(state: state, layer: layer, size: 30),
        ]),
        if (rec != null && !rec.inputOpen)
          const Padding(padding: EdgeInsets.only(top: 4), child: Text('Input is off: arming turns it on (Settings › Audio '
              'picks the device).', style: TextStyle(color: Neon.dim, fontSize: 11))),
        label('CHANNEL'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var ch = 0; ch < math.max(1, deviceChannels - (input.channels == 2 ? 1 : 0)); ch++)
            ChoiceChip(key: ValueKey('audio-input-channel-$ch'), visualDensity: VisualDensity.compact,
              label: Text(input.channels == 2 ? '${ch + 1}+${ch + 2}' : '${ch + 1}'),
              selected: input.channel == ch,
              onSelected: (_) { Haptics.tick(); state.editInput(layer, (i) => i.channel = ch); }),
        ]),
        label('CHANNELS'),
        SegmentedButton<int>(
          key: const ValueKey('audio-input-width'),
          segments: [
            const ButtonSegment(value: 1, label: Text('Mono'), icon: Icon(Icons.mic_none, size: 16)),
            ButtonSegment(value: 2, label: const Text('Stereo'), icon: const Icon(Icons.surround_sound_outlined, size: 16),
                enabled: deviceChannels >= 2),
          ],
          selected: {input.channels},
          onSelectionChanged: (v) {
            Haptics.tick();
            state.editInput(layer, (i) {
              i.channels = v.first;
              if (i.channels == 2 && i.channel + 1 >= deviceChannels) i.channel = math.max(0, deviceChannels - 2);
            });
          }),
        label('MONITOR'),
        SegmentedButton<String>(
          key: const ValueKey('audio-input-monitor'),
          segments: const [
            ButtonSegment(value: 'off', label: Text('Off')),
            ButtonSegment(value: 'auto', label: Text('Auto'), tooltip: 'While armed and stopped, or while recording'),
            ButtonSegment(value: 'on', label: Text('On'), tooltip: 'Always hear the input through the track'),
          ],
          selected: {input.monitor},
          onSelectionChanged: (v) { Haptics.tick(); state.editInput(layer, (i) => i.monitor = v.first); }),
        const SizedBox(height: 4),
        const Text('Monitoring plays the input through the track\'s effects. Use headphones: a speaker feeds back into '
            'the microphone.', style: TextStyle(color: Neon.dim, fontSize: 11)),
        if (layer.input?.armed ?? false) ...[
          label('LEVEL'),
          AudioInputMeter(layer: layer, height: 8),
        ],
      ]),
    ));
  });
}
