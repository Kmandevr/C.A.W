// Chirp's page (org.caw.pitchfix, live pitch correction; 1.1.0, Pitch family pink): the note line with snapping (the pitch in, the corrected pitch out, on a keyboard axis whose lit keys are the scale), key and scale, Speed, Humanize, Keep vibrato, Formant and Mix, and the clip pitch editor's button.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../model/audio_edit.dart';
import '../../../../model/pitch_clip.dart' show pitchCentsLabel, pitchNoteName;
import '../../../arrange/pitch_editor.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/hero.dart';
import '../../kit/repaint.dart';
import '../dyn_drive/common.dart' show ChoiceChips, chipWrap;
import '../modes_kit.dart' show LitPill;
import '../space/space_devices.dart' show mergedPage;
import 'voice_devices.dart' show DragHero, knobWrap, rawAt;

/// The engine's scales (lark_dsp.h, kScaleMasks), as pitch classes above the key; Custom (12) reads `note_*`.
const List<List<int>> larkScales = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  [0, 2, 4, 5, 7, 9, 11],
  [0, 2, 3, 5, 7, 8, 10],
  [0, 2, 3, 5, 7, 8, 11],
  [0, 2, 3, 5, 7, 9, 11],
  [0, 2, 3, 5, 7, 9, 10],
  [0, 1, 3, 5, 7, 8, 10],
  [0, 2, 4, 6, 7, 9, 11],
  [0, 2, 4, 5, 7, 9, 10],
  [0, 2, 4, 7, 9],
  [0, 3, 5, 7, 10],
  [0, 3, 5, 6, 7, 10],
];

/// Custom's note switches, C to B.
const larkNoteIds = ['note_c', 'note_cs', 'note_d', 'note_eb', 'note_e', 'note_f', 'note_fs', 'note_g', 'note_ab',
  'note_a', 'note_bb', 'note_b'];
const _noteLabels = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];

/// The pitch classes (0 = C) a note can snap to for [key], [scale] and Custom's [custom] switches.
Set<int> larkClasses(int key, int scale, List<bool> custom) {
  if (scale >= larkScales.length) return {for (var k = 0; k < 12; k++) if (custom[k]) k};
  return {for (final k in larkScales[scale]) (k + key) % 12};
}

/// The snap target of [midi] among [classes]: the nearest allowed note (none allowed: itself).
double larkTarget(double midi, Set<int> classes) {
  if (classes.isEmpty) return midi;
  var best = midi.roundToDouble(), d = double.infinity;
  for (var m = midi.floor() - 6; m <= midi.ceil() + 6; m++) {
    if (!classes.contains(m % 12)) continue;
    final x = (m - midi).abs();
    if (x < d) {
      d = x;
      best = m.toDouble();
    }
  }
  return best;
}

class LarkPage extends StatelessWidget {
  const LarkPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final custom = t.value('scale').round() >= larkScales.length;
    final hero = HeroCanvas(
      color: scope.accent,
      height: 230,
      caption: 'NOTE LINE',
      grid: false,
      readout: DeviceDisplay(builder: (context, f) {
        final raw = f?.raw;
        if (raw == null || raw.length < 154) return const Text('≈ drag: speed ↔ · humanize ↕');
        if (rawAt(raw, 2) < 0.5) return Text('— · ${rawAt(raw, 7).toStringAsFixed(0)} ms');
        final m = rawAt(raw, 3), target = rawAt(raw, 4);
        return Text('${pitchNoteName(m)} ${pitchCentsLabel(m)} → ${target < 0 ? '—' : pitchNoteName(target)}');
      }),
      child: DragHero(heroKey: 'lark-hero', x: 'speed', y: 'humanize', painter: (context, raw, active) {
        final s = DeviceScope.of(context);
        final tt = s.target;
        return LarkNoteLinePainter(
          raw: raw,
          classes: larkClasses(tt.value('key').round(), tt.value('scale').round(),
              [for (final id in larkNoteIds) tt.value(id) >= 0.5]),
          speed: tt.value('speed'),
          humanize: tt.value('humanize'),
          keepVibrato: tt.value('keep_vibrato') >= 0.5,
          color: s.accent,
          second: Neon.violet,
          active: active);
      }),
    );
    final layer = t.layer;
    final clip = layer == null ? null : pitchClipOf(t.state, layer);
    final edit = Row(children: [
      Expanded(child: LitPill(
        label: clip == null ? 'Edit pitch… (put an audio clip on this track)' : 'Edit pitch… · ${t.state.audioClipName(clip)}',
        icon: Icons.multiline_chart,
        on: false,
        height: 40,
        keyName: 'lark-edit-pitch',
        onTap: () {
          if (layer == null || clip == null) return;
          showPitchEditor(context, t.state, layer, clip);
        })),
    ]);
    return mergedPage(context, 'pitchfix',
      hero: hero,
      rows: [
        Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.end, children: const [
          DeviceChoice('key', label: 'Key'),
          DeviceChoice('scale', label: 'Scale'),
        ]),
        if (custom) chipWrap([for (var k = 0; k < 12; k++) DeviceToggle(larkNoteIds[k], label: _noteLabels[k])]),
        chipWrap([
          FittedBox(fit: BoxFit.scaleDown, child: ChoiceChips('target', title: 'TARGET')),
          const DeviceToggle('keep_vibrato', label: 'Keep vibrato'),
          const DeviceToggle('formant_keep', label: 'Formant keep'),
        ]),
        edit,
      ],
      knobs: knobWrap([
        DeviceKnob('speed', size: 64, label: 'Speed', color: scope.accent),
        const DeviceKnob('humanize', size: 50, label: 'Humanize'),
        const DeviceKnob('formant', size: 46, label: 'Formant'),
        const DeviceKnob('mix', size: 46, label: 'Mix'),
      ]),
      more: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const KnobRow(['low', 'high', 'sensitivity', 'output'], size: 42),
        chipWrap([const DeviceToggle('monitor', label: 'Low-latency monitoring')]),
      ]),
    );
  }
}

/// The note line: time across (the newest at the right), pitch up a keyboard axis whose keys in the scale are lit,
/// each allowed note a snap line; the pitch in (grey) and corrected out (in [color]) from the engine's history (64
/// hops, oldest first, −1 unvoiced: display floats 26.. and 90..), else a sung phrase ≈ corrected by the knobs.
class LarkNoteLinePainter extends CustomPainter {
  LarkNoteLinePainter({required this.raw, required this.classes, required this.speed, required this.humanize,
    required this.keepVibrato, required this.color, required this.second, required this.active});
  final List<double>? raw;
  final Set<int> classes;
  final double speed, humanize;
  final bool keepVibrato;
  final Color color, second;
  final bool active;

  static const int history = 64;
  static const double keyboard = 26;

  /// The demo phrase (≈): a voice gliding between notes with a scoop, vibrato and wander, [n] points over 1.6 s,
  /// and what the correction makes of it.
  static (List<double>, List<double>) demo(int n, Set<int> classes, double speedMs, double humanize, bool keepVibrato) {
    final input = <double>[], output = <double>[];
    const notes = [61.6, 64.3, 62.8, 66.2];
    var corr = 0.0, centre = notes.first, held = 0.0;
    const dt = 1.6;
    for (var i = 0; i < n; i++) {
      final t = i / n * dt;
      final seg = math.min(notes.length - 1, (t / dt * notes.length).floor());
      final local = t - seg * dt / notes.length;
      final from = seg == 0 ? notes.first - 0.8 : notes[seg - 1];
      final glide = from + (notes[seg] - from) * (1 - math.exp(-local / 0.05));
      final vib = 0.28 * math.sin(2 * math.pi * 5.5 * t) * math.min(1.0, local / 0.15);
      final m = glide + vib + 0.06 * math.sin(t * 9.1);
      input.add(m);
      if (local < dt / n) held = 0;
      held += dt / n;
      centre += (m - centre) * (keepVibrato ? 1 - math.exp(-dt / n / 0.08) : 1);
      final want = larkTarget(centre, classes) - (keepVibrato ? centre : m);
      final tau = speedMs / 1000 * (1 + 3 * humanize * math.min(1.0, held / 0.3));
      corr += tau <= 0 ? want - corr : (want - corr) * (1 - math.exp(-dt / n / tau));
      output.add(m + corr);
    }
    return (input, output);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = raw;
    final live = r != null && r.length >= 26 + 2 * history;
    List<double> input, output;
    if (live) {
      input = [for (var k = 0; k < history; k++) r[26 + k]];
      output = [for (var k = 0; k < history; k++) r[26 + history + k]];
    } else {
      (input, output) = demo(160, classes, speed, humanize, keepVibrato);
    }
    final voiced = [for (final v in [...input, ...output]) if (v > 0) v];
    final mid = voiced.isEmpty ? 62.0 : (voiced.reduce(math.min) + voiced.reduce(math.max)) / 2;
    final span = 13.0;
    final top = mid + span / 2;
    final area = Rect.fromLTRB(keyboard + 4, 22, size.width - 8, size.height - 8);
    double y(double m) => area.top + (top - m) / span * area.height;
    final lo = (top - span).floor(), hi = top.ceil();
    // Rows and the keyboard: the scale's keys lit, a snap line on each.
    for (var m = lo; m <= hi; m++) {
      final y0 = y(m + 0.5), y1 = y(m - 0.5);
      if (y1 < area.top || y0 > area.bottom) continue;
      final inScale = classes.contains(m % 12);
      final black = const {1, 3, 6, 8, 10}.contains(m % 12);
      final key = Rect.fromLTRB(4, math.max(area.top, y0 + 0.5), black ? keyboard * 0.7 : keyboard, math.min(area.bottom, y1 - 0.5));
      canvas.drawRRect(RRect.fromRectAndRadius(key, const Radius.circular(2)), Paint()
        ..color = inScale ? color.withValues(alpha: black ? 0.55 : 0.4) : (black ? Neon.bg : Neon.panelHi));
      final yc = y(m.toDouble());
      if (yc > area.top && yc < area.bottom) {
        canvas.drawLine(Offset(area.left, yc), Offset(area.right, yc), Paint()
          ..color = inScale ? color.withValues(alpha: 0.16) : Neon.ink.withAlpha(0x08)
          ..strokeWidth = inScale ? 1 : 0.6);
      }
      if (m % 12 == 0) paintLabel(canvas, 'C${m ~/ 12 - 1}', Offset(keyboard + 12, yc), Neon.dim, size: 7);
    }
    Path line(List<double> v) {
      final p = Path();
      var pen = false;
      for (var i = 0; i < v.length; i++) {
        if (v[i] <= 0) {
          pen = false;
          continue;
        }
        final pt = Offset(area.left + area.width * i / (v.length - 1), y(v[i]).clamp(area.top, area.bottom));
        pen ? p.lineTo(pt.dx, pt.dy) : p.moveTo(pt.dx, pt.dy);
        pen = true;
      }
      return p;
    }

    strokeGlow(canvas, line(input), Neon.dim, width: 1.3, glow: false);
    strokeGlow(canvas, line(output), color, width: active ? 2.6 : 2.1);
    // The newest corrected point and the note it snaps to.
    final last = output.lastWhere((v) => v > 0, orElse: () => -1);
    if (last > 0) {
      final at = Offset(area.right, y(last).clamp(area.top, area.bottom));
      paintHandle(canvas, at, color, active: active, r: 4.5);
      final target = larkTarget(last, classes);
      paintLabel(canvas, pitchNoteName(target), at + const Offset(-14, -11), color, size: 8, weight: FontWeight.w800);
    }
    paintLabel(canvas, live ? 'IN · OUT' : 'IN · OUT ≈', Offset(area.left + 2, size.height - 12), Neon.dim, size: 7);
  }

  @override
  bool shouldRepaint(covariant LarkNoteLinePainter o) => paintInputsChanged(
      [o.raw, o.classes.length, o.classes.fold<int>(0, (a, b) => a | 1 << b), o.speed, o.humanize, o.keepVibrato, o.color, o.active],
      [raw, classes.length, classes.fold<int>(0, (a, b) => a | 1 << b), speed, humanize, keepVibrato, color, active]);
}
