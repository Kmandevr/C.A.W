// Every device's header (device shell): power, the name in its family's colour, its CPU and latency (and the armed badge), the preset bar, A/B, the auto gain ear, the "?" field guide and the ⋯ menu; one line on wide screens, two on a phone.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../model/device_slot_audio.dart';
import '../../../model/device_target.dart';
import '../../capped_ticker.dart';
import '../../motion.dart';
import '../../theme.dart';
import 'device_menu.dart';
import 'device_style.dart';
import 'feel.dart';
import 'field_guide.dart';
import 'preset_browser.dart';
import 'presets.dart';

/// A device's header: [leading] (the FX chain's drag handle, the editor's back or close), power, the name in
/// [color] (tap: [onTitle]) over [subtitle], the preset bar (‹ name › ★), A/B, the auto gain ear (when the engine
/// has it), "?" (the field guide) and ⋯, then the host's [actions]. Below [wideAt] dp the preset bar, A/B and the ear go on a second line.
class DeviceHeader extends StatelessWidget {
  const DeviceHeader({super.key, required this.target, required this.color, this.style, this.leading,
    this.actions = const [], this.onTitle, this.titleKey, this.powerKey, this.presetKey, this.subtitle,
    this.onMenu, this.onDrag, this.shortcuts = false, this.wideAt = 640, this.nameSize = 13});
  final DeviceTarget target;
  final Color color;
  final DeviceStyle? style;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onTitle;
  final Key? titleKey, powerKey, presetKey;
  final String? subtitle;

  /// A long-press or right-click on the header (the FX chain's options menu).
  final void Function(Offset at)? onMenu;

  /// A drag on the header (the floating window moves).
  final ValueChanged<Offset>? onDrag;

  /// Ctrl+S saves the preset (the full editor).
  final bool shortcuts;
  final double wideAt;
  final double nameSize;

  // Its own Material and layer (1.1.1): a tap's ink ripple (⋯, ?, the name) animates for about a second, and on
  // the page's Material it repainted the whole device page on every frame of it; here it repaints the header alone.
  @override
  Widget build(BuildContext context) => RepaintBoundary(child: Material(type: MaterialType.transparency, child: _build(context)));

  Widget _build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPressStart: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
    onSecondaryTapUp: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
    onPanUpdate: onDrag == null ? null : (d) => onDrag!(d.delta),
    child: LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= wideAt;
      final t = target;
      final presets = DevicePresetChip(target: t, color: color, bar: true, shortcuts: shortcuts, chipKey: presetKey,
        maxWidth: wide ? 300 : box.maxWidth);
      final tools = <Widget>[
        const SizedBox(width: 4),
        DeviceABSwitch(target: t, color: color),
        DeviceAutoGainButton(target: t, color: color),
      ];
      final first = SizedBox(height: 44, child: Row(children: [
        leading ?? const SizedBox(width: 6),
        DevicePowerButton(target: t, powerKey: powerKey),
        Expanded(child: InkWell(
          key: titleKey,
          onTap: onTitle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Column(
            mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            LayoutBuilder(builder: (context, name) => Row(children: [
              Flexible(flex: 4, child: Text(t.label, key: const ValueKey('device-name'), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: nameSize, fontWeight: FontWeight.w800, color: color,
                  shadows: [Shadow(color: color.withValues(alpha: 0.45), blurRadius: 8)]))),
              // The badge shrinks rather than overflow a narrow header.
              if (t.info?.isAutoStacc ?? false) ...[const SizedBox(width: 6),
                const Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: AutoStaccBadge(small: true)))],
              // Zero wide while the engine has no cost for it, so the name keeps its room; at most half the line.
              ConstrainedBox(constraints: BoxConstraints(maxWidth: (name.maxWidth * 0.5).clamp(0.0, 120.0)),
                child: FittedBox(fit: BoxFit.scaleDown, child: RepaintBoundary(child: DeviceCostReadout(target: t, color: color)))),
            ])),
            if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, color: Neon.dim)),
          ])),
        )),
        if (wide) ...[presets, ...tools],
        DeviceGuideButton(target: t, color: color),
        DeviceMoreButton(target: t, color: color),
        ...actions,
      ]));
      if (wide) return first;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        first,
        SizedBox(height: 36, child: Padding(padding: const EdgeInsets.only(left: 4, right: 4), child: Row(children: [
          Expanded(child: Row(children: [presets])),
          ...tools,
        ]))),
      ]);
    }),
  );
}

/// The device's cost, small and quiet beside its name: its CPU share ("1.2%") and the latency it adds ("48 ms"), and
/// a "Live" badge while its track is armed and it plays its near-zero-delay version. Read through
/// [DeviceSlotAudio.cost] four times a second while the header is on screen (no read off screen; the engine stops
/// timing the chain 2 s after the last read); nothing while the engine has no cost for it.
class DeviceCostReadout extends StatefulWidget {
  const DeviceCostReadout({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  /// The armed badge's tooltip.
  static const armedTip = 'Plays a near-zero-delay version while this track is armed; playback and export use the full one';

  @override
  State<DeviceCostReadout> createState() => _DeviceCostReadoutState();
}

class _DeviceCostReadoutState extends State<DeviceCostReadout> {
  // A timer, not a ticker: four reads a second without asking for frames in between.
  Timer? _timer;
  DeviceCost? _cost;

  @override
  void initState() {
    super.initState();
    _cost = _read();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  DeviceCost? _read() => DeviceSlotAudio.current?.cost(widget.target);

  void _tick() {
    // Off screen (a hidden tab or route): no read, so the engine stops timing the chain.
    if (!mounted || !TickerMode.valuesOf(context).enabled) return;
    final c = _read();
    if (c?.cpuShare != _cost?.cpuShare || c?.latencyMs != _cost?.latencyMs || c?.armed != _cost?.armed ||
        (c == null) != (_cost == null)) {
      setState(() => _cost = c);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _cost;
    final fade = Motion.fade(Motion.standard, Motion.of(context));
    return AnimatedSwitcher(duration: fade, child: c == null ? const SizedBox.shrink(key: ValueKey('none')) : Row(
      key: const ValueKey('device-cost'), mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(width: 6),
      Tooltip(message: 'CPU (share of one core) and the delay this device adds, which the track compensates',
        waitDuration: const Duration(milliseconds: 600),
        child: Text('${formatCpu(c.cpuShare)} · ${formatLatency(c.latencyMs)}', key: const ValueKey('device-cost-text'),
          maxLines: 1, style: Neon.code(size: 9, color: Neon.dim))),
      AnimatedSize(duration: fade, child: !c.armed ? const SizedBox.shrink() : Padding(
        padding: const EdgeInsets.only(left: 5),
        child: Tooltip(message: DeviceCostReadout.armedTip, child: Container(
          key: const ValueKey('device-armed-badge'),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(6),
            color: Neon.pink.withValues(alpha: 0.14), border: Border.all(color: Neon.pink.withValues(alpha: 0.6))),
          child: Text('Live', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: Neon.text)))))),
    ]));
  }
}

/// A CPU share (0.01 = 1 % of one core) as the header shows it: "1.2%", "<0.1%", "–" until measured.
String formatCpu(double? share) {
  if (share == null || !share.isFinite || share < 0) return '– CPU';
  final pc = share * 100;
  if (pc < 0.05) return '<0.1%';
  return '${pc < 10 ? pc.toStringAsFixed(1) : pc.round()}%';
}

/// A latency in ms as the header shows it: "0 ms", "4.9 ms", "48 ms".
String formatLatency(double ms) {
  if (!ms.isFinite || ms <= 0.05) return '0 ms';
  return '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms';
}

/// The device's power button: green and glowing while it plays, dim while bypassed.
class DevicePowerButton extends StatelessWidget {
  const DevicePowerButton({super.key, required this.target, this.powerKey, this.size = 36});
  final DeviceTarget target;
  final Key? powerKey;
  final double size;

  @override
  Widget build(BuildContext context) {
    final off = target.bypass;
    return SizedBox(width: size, height: size, child: IconButton(
      key: powerKey ?? const ValueKey('device-bypass'),
      tooltip: off ? 'Turn on ${target.label}' : 'Bypass ${target.label}',
      padding: EdgeInsets.zero,
      iconSize: 18,
      color: off ? Neon.dim : Neon.green,
      onPressed: () {
        DeviceFeel.tap();
        target.setBypass(!off);
      },
      icon: Icon(Icons.power_settings_new, shadows: off ? null : [Shadow(color: Neon.green, blurRadius: 6)])));
  }
}

/// A/B compare: a tap on a side loads it (keeping the side left); a hold copies A to B.
class DeviceABSwitch extends StatefulWidget {
  const DeviceABSwitch({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  State<DeviceABSwitch> createState() => _DeviceABSwitchState();
}

class _DeviceABSwitchState extends State<DeviceABSwitch> {
  @override
  // Rebuilt when the side changes in any view of the device, or its values change (undo), not on a knob step.
  Widget build(BuildContext context) => PresetChanges(target: widget.target, also: DeviceAB.changes, builder: _build);

  Widget _build(BuildContext context) {
    final t = widget.target, color = widget.color;
    final b = DeviceAB.isB(t);
    Widget side(String label, bool isB) => GestureDetector(
      key: ValueKey('device-ab-${label.toLowerCase()}'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DeviceFeel.tap();
        DeviceAB.select(t, isB);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 24, height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6),
          color: b == isB ? color.withValues(alpha: 0.25) : Colors.transparent),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: b == isB ? Neon.text : Neon.dim)),
      ),
    );
    return Tooltip(message: 'Compare two settings: tap to switch, hold to copy A to B',
      waitDuration: const Duration(milliseconds: 600), child: GestureDetector(
      key: const ValueKey('device-ab'),
      onLongPress: () {
        DeviceFeel.detent();
        DeviceAB.copyAToB(t);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(duration: Duration(seconds: 2),
          content: Text('Copied A to B')));
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Neon.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [side('A', false), side('B', true)]),
      )));
  }
}

/// Auto gain (the ear): lit while the device's auto gain is on, with the trim it applies as a number; a tap switches
/// it. Nothing while the engine has no per-slot auto gain ([DeviceSlotAudio]).
class DeviceAutoGainButton extends StatefulWidget {
  const DeviceAutoGainButton({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  State<DeviceAutoGainButton> createState() => _DeviceAutoGainButtonState();
}

class _DeviceAutoGainButtonState extends State<DeviceAutoGainButton> with SingleTickerProviderStateMixin {
  // Four reads a second, no frames asked for in between (CappedTicker).
  late final _ticker = CappedTicker(_tick, maxHz: 4, vsync: this);
  String? _trim;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // The trim, read about four times a second while shown (a ticker: it stops while the device is off screen).
  void _tick(Duration at) {
    final text = _read();
    if (text != _trim) setState(() => _trim = text);
  }

  String? _read() {
    final a = DeviceSlotAudio.current;
    if (a == null || !a.autoGain(widget.target)) return null;
    return formatTrim(a.autoGainTrimDb(widget.target));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: DeviceSlotAudio.changes,
    builder: (context, _, _) {
      if (!DeviceSlotAudio.autoGainFor(widget.target)) {
        if (_ticker.isActive) _ticker.stop();
        return const SizedBox.shrink();
      }
      final on = DeviceSlotAudio.current!.autoGain(widget.target);
      if (on && !_ticker.isActive) {
        _ticker.start();
      } else if (!on && _ticker.isActive) {
        _ticker.stop();
      }
      _trim = on ? _read() : null;
      final c = on ? widget.color : Neon.dim;
      return Tooltip(message: on ? 'Auto gain on: the output is kept as loud as the input' : 'Auto gain off',
        child: InkWell(
          key: const ValueKey('device-autogain'),
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            DeviceFeel.tap();
            DeviceSlotAudio.toggleAutoGain(widget.target);
          },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), child: Row(
            mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.hearing : Icons.hearing_disabled_outlined, size: 17, color: c),
            if (on) ...[
              const SizedBox(width: 3),
              Text(_trim ?? '0.0 dB', key: const ValueKey('device-autogain-trim'),
                style: Neon.code(size: 10, color: c)),
            ],
          ])),
        ));
    },
  );
}

/// A trim in dB as the ear shows it: "+1.5 dB", "−3.0 dB".
String formatTrim(double? db) {
  if (db == null || !db.isFinite) return '0.0 dB';
  final v = (db * 10).round() / 10;
  return '${v > 0 ? '+' : v < 0 ? '−' : ''}${v.abs().toStringAsFixed(1)} dB';
}

/// The header's ⋯: the device menu (device_menu.dart).
class DeviceMoreButton extends StatelessWidget {
  const DeviceMoreButton({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(width: 36, height: 36, child: Builder(builder: (context) => IconButton(
    key: const ValueKey('device-more'),
    tooltip: 'More: copy, paste, happy accident, randomize, history, reset',
    padding: EdgeInsets.zero,
    iconSize: 20,
    color: Neon.dim,
    onPressed: () {
      DeviceFeel.tap();
      showDeviceMenu(context, target, color);
    },
    icon: const Icon(Icons.more_horiz))));
}
