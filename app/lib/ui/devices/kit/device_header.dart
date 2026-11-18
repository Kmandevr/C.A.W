// Every device's header (device shell): power, the name in its family's colour, the preset bar, A/B, the auto gain ear and the ⋯ menu; one line on wide screens, two on a phone.
import 'package:flutter/material.dart';

import '../../../model/device_slot_audio.dart';
import '../../../model/device_target.dart';
import '../../theme.dart';
import 'device_menu.dart';
import 'device_style.dart';
import 'feel.dart';
import 'preset_browser.dart';
import 'presets.dart';

/// A device's header: [leading] (the FX chain's drag handle, the editor's back or close), power, the name in
/// [color] (tap: [onTitle]) over [subtitle], the preset bar (‹ name › ★), A/B, the auto gain ear (when the engine
/// has it) and ⋯, then the host's [actions]. Below [wideAt] dp the preset bar, A/B and the ear go on a second line.
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

  @override
  Widget build(BuildContext context) => GestureDetector(
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
            Text(t.label, key: const ValueKey('device-name'), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: nameSize, fontWeight: FontWeight.w800, color: color,
                shadows: [Shadow(color: color.withValues(alpha: 0.45), blurRadius: 8)])),
            if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, color: Neon.dim)),
          ])),
        )),
        if (wide) ...[presets, ...tools],
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
  Widget build(BuildContext context) {
    final t = widget.target, color = widget.color;
    final b = DeviceAB.isB(t);
    Widget side(String label, bool isB) => GestureDetector(
      key: ValueKey('device-ab-${label.toLowerCase()}'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DeviceFeel.tap();
        DeviceAB.select(t, isB);
        setState(() {});
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
        setState(() {});
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
  late final _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  String? _trim;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // The trim, read about four times a second while shown (a ticker: it stops while the device is off screen).
  void _tick(Duration at) {
    if (at - _last < const Duration(milliseconds: 250)) return;
    _last = at;
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
    tooltip: 'More: copy, paste, randomize, history, reset',
    padding: EdgeInsets.zero,
    iconSize: 20,
    color: Neon.dim,
    onPressed: () {
      DeviceFeel.tap();
      showDeviceMenu(context, target, color);
    },
    icon: const Icon(Icons.more_horiz))));
}
