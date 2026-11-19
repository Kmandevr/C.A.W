// The Delay (Digital, Ping-pong) and Reverb (Hall, Shimmer) merged devices' pages: echo taps in ping-pong lanes and the decay picture, each under its variant cards.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../engine/component_info.dart';
import '../../../feedback.dart';
import '../../../motion.dart';
import '../../../theme.dart';
import '../../device_controls.dart';
import '../../device_scope.dart';
import '../../kit/controls.dart';
import '../../kit/feel.dart';
import '../../kit/hero.dart';
import '../effect_page.dart';
import '../space_editors.dart' show DelayHero, ReverbHero, delayModeIcon, delaySeconds;
import 'space_delay_modes.dart';
import 'space_devices.dart';

// ---------------------------------------------------------------------------------------------------------------
// Delay

/// The Delay: Digital and Ping-pong as cards; the echoes on a left and a right lane (drag the first tap sideways for
/// the time, from division to division in sync, up and down for the feedback); Sync or Time, the Digital's own mode,
/// Freeze; then feedback, the filters and ducking, the rest under MORE.
class DelayDevicePage extends StatelessWidget {
  const DelayDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final cards = VariantCards(height: 50, icon: (c, r, i, col) =>
        i >= 2 ? delayNewModeIcon(c, r.deflate(2), i, col) : delayModeIcon(c, r, i == 0 ? 0 : 1, col));
    if (variantOf(context) >= 2) return DelayModesPage(cards: cards);
    final digital = variantOf(context) == 0;
    final free = _isFree(t.param('sync'), t.value('sync'));
    final dual = digital && t.value('mode').round() == 2;
    return mergedPage(context, 'delay',
      cards: cards,
      hero: HeroWithMeters(height: 190, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 190,
        caption: digital ? 'ECHOES' : 'PING-PONG',
        grid: false,
        readout: Builder(builder: (context) => Text(_ms(delaySeconds(scope, 'sync', 'time')))),
        child: const DelayHero(),
      )),
      rows: [
        controlsRow([
          const SyncTimeToggle(),
          if (!free) const DeviceChoice('sync', maxSegments: 0),
          if (digital) const DeviceToggle('freeze', label: 'Freeze', icon: Icons.ac_unit),
        ]),
        if (digital) controlsRow([smallLabel('MODE'), const DeviceChoice('mode', maxSegments: 3)]),
      ],
      knobs: KnobRow([
        if (free) 'time',
        'feedback',
        if (digital) ...['low_cut', 'high_cut', 'duck'] else 'cross',
      ], size: 50, labels: const {'duck': 'Ducking', 'cross': 'Ping-pong'}),
      more: digital ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (dual) Padding(padding: const EdgeInsets.only(bottom: 6), child: controlsRow([
          smallLabel('RIGHT'), DeviceChoice('sync_r', maxSegments: 0, color: scope.secondary)])),
        KnobRow([
          if (dual && _isFree(t.param('sync_r'), t.value('sync_r'))) 'time_r',
          if (!dual) 'offset',
          'drive', 'mod_depth', 'mod_rate',
        ], size: 42, labels: const {'offset': 'R offset', 'mod_depth': 'Mod depth', 'mod_rate': 'Mod rate', 'time_r': 'R time'}),
      ]) : null,
    );
  }

  static String _ms(double s) => s < 1 ? '${(s * 1000).round()} ms' : '${s.toStringAsFixed(2)} s';
}

bool _isFree(ComponentParameterInfo? p, double v) => p == null || formatParamValue(p, v) == 'Free';

/// Sync or Time for a delay's `sync` choice: Time is its Free choice (the time knob plays), Sync goes back to the
/// division it had (its default the first time).
class SyncTimeToggle extends StatefulWidget {
  const SyncTimeToggle({super.key, this.paramId = 'sync'});
  final String paramId;

  @override
  State<SyncTimeToggle> createState() => _SyncTimeToggleState();
}

class _SyncTimeToggleState extends State<SyncTimeToggle> {
  double? _last; // the division before Time was picked

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final p = t.param(widget.paramId);
    if (p == null || !p.isChoice) return const SizedBox.shrink();
    final freeAt = p.choices.indexOf('Free');
    if (freeAt < 0) return const SizedBox.shrink();
    final free = (t.value(p.id) - p.min).round() == freeAt;
    final c = scope.accent;
    Widget seg(String label, bool on, VoidCallback tap, Key key) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: on ? null : () {
        DeviceFeel.tap();
        tap();
      },
      child: Pressable(glow: c, radius: 14, child: AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: on ? c.withValues(alpha: 0.22) : Colors.transparent,
          border: Border.all(color: on ? c : Colors.transparent)),
        child: Text(label, style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w800,
            color: on ? Neon.text : Neon.dim)),
      )),
    );
    return Semantics(label: 'Sync or time', value: free ? 'Time' : 'Sync', child: Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: Neon.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('SYNC', !free, () {
          final back = _last ?? (p.defaultValue == p.min + freeAt ? p.min + math.min(p.choices.length - 1, freeAt + 1) : p.defaultValue);
          t.set(p.id, back);
        }, ValueKey('sync-toggle-${p.id}-sync')),
        seg('TIME', free, () {
          _last = t.value(p.id);
          t.set(p.id, p.min + freeAt);
        }, ValueKey('sync-toggle-${p.id}-time')),
      ]),
    ));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Reverb

/// The Reverb: Hall and Shimmer as cards; the decay picture (pre-delay, early reflections, the tail to −60 dB; drag
/// sideways for the decay, up and down for the size); Freeze (Hall) or the shimmer's shift; size and decay, then
/// pre-delay, damping and width; the rest under MORE.
class ReverbDevicePage extends StatelessWidget {
  const ReverbDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final hall = variantOf(context) == 0;
    return mergedPage(context, 'reverb',
      cards: VariantCards(icon: _algorithmIcon, height: 50),
      hero: HeroWithMeters(height: 200, gr: false, hero: HeroCanvas(
        color: scope.accent,
        height: 200,
        caption: hall ? 'HALL' : 'SHIMMER',
        grid: false,
        readout: Builder(builder: (context) =>
            Text('${formatParamValue(t.param('decay'), t.value('decay'))} · size ${(t.value('size') * 100).round()}%')),
        child: const ReverbHero(),
      )),
      rows: [
        if (hall) Row(children: [
          const DeviceToggle('freeze', label: 'Freeze', icon: Icons.ac_unit),
          const Spacer(),
          DeviceDisplay(builder: (context, f) => Text(
              f?.values['wet_db'] == null ? '' : 'WET ${f!.values['wet_db']!.toStringAsFixed(1)} dB',
              style: Neon.code(size: 10, color: Neon.dim))),
        ])
        else controlsRow([smallLabel('SHIFT'), const DeviceChoice('shift', maxSegments: 6)]),
      ],
      knobs: Column(mainAxisSize: MainAxisSize.min, children: [
        KnobRow(['size', 'decay', if (!hall) 'amount'], size: 52),
        const KnobRow(['predelay', 'damping', 'width'], size: 46),
      ]),
      more: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (hall) const ParamGrid(only: ['predelay_sync']),
        KnobRow(hall ? const ['low_cut', 'high_cut', 'mod', 'mod_rate', 'duck'] : const ['tone', 'low_cut', 'mod'], size: 42,
            labels: const {'mod': 'Mod depth', 'mod_rate': 'Mod rate', 'duck': 'Ducking', 'tone': 'Tone',
              'low_cut': 'Low cut'}),
      ]),
    );
  }
}

/// The algorithms' icons: Hall a long smooth tail, Shimmer a tail with rising layers.
void _algorithmIcon(Canvas canvas, Rect r, int index, Color color) {
  final base = r.bottom - 2;
  final p = Paint()
    ..color = color
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;
  for (var k = 0; k < 14; k++) {
    final x = r.left + r.width * (k + 0.5) / 14;
    final env = math.exp(-k / (index == 0 ? 5.0 : 7.0));
    canvas.drawLine(Offset(x, base), Offset(x, base - (r.height - 4) * env * (k.isEven ? 1 : 0.8)), p..color = color.withValues(alpha: 0.4 + 0.6 * env));
  }
  if (index == 1) {
    for (var k = 1; k <= 2; k++) {
      iconCurve(canvas, Rect.fromLTWH(r.left, r.top + r.height * (0.5 - k * 0.2), r.width, r.height * 0.25), color,
          (x) => 0.6 * math.sin((x + 1) * math.pi * (2 + 2 * k)), width: 1.2);
    }
  }
}
