// Every device's footer (device shell): its output meter with a clip light, Mix and Output; and the FX chain rows' tiny live visual. Both run only while on screen.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../engine/component_info.dart';
import '../../../model/device_slot_audio.dart';
import '../../../model/device_target.dart';
import '../../arrange/knob.dart' show Taper;
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import 'hero.dart' show DeviceDisplay;
import 'param_watch.dart';

/// The device's Mix parameter (`mix`), or null.
ComponentParameterInfo? mixParam(NativeComponentInfo? info) => info?.param('mix');

/// The device's Output parameter (`output`, a multiband's `out_gain`), or null.
ComponentParameterInfo? outputParam(NativeComponentInfo? info) => info?.param('output') ?? info?.param('out_gain');

/// Whether [t] has a footer: a meter (the engine meters slots) or a Mix or Output knob.
bool hasDeviceFooter(DeviceTarget t) =>
    DeviceSlotAudio.meterFor(t) || mixParam(t.info) != null || outputParam(t.info) != null;

/// The footer under a device: its output meter and clip light (when the engine meters slots), then Mix and Output
/// where the device has them. Inside a [DeviceScope].
class DeviceFooter extends StatelessWidget {
  const DeviceFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    if (!hasDeviceFooter(t)) return const SizedBox.shrink();
    final mix = mixParam(t.info), out = outputParam(t.info);
    return Container(
      key: const ValueKey('device-footer'),
      height: 46,
      padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scope.accent.withValues(alpha: 0.18)))),
      child: Row(children: [
        // The meter takes the room left, up to 320 dp (a wide screen's footer would stretch it across).
        if (DeviceSlotAudio.meterFor(t)) Flexible(flex: 4, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320),
          child: SlotMeter(target: t, color: scope.accent))),
        const Spacer(),
        if (mix != null) FooterKnob(param: mix, label: 'MIX'),
        if (out != null) FooterKnob(param: out, label: 'OUT'),
      ]),
    );
  }
}

/// A small knob with its name and value beside it (the footer, the FX chain rows).
class FooterKnob extends StatelessWidget {
  const FooterKnob({super.key, required this.param, required this.label, this.size = 22, this.showLabel = true,
    this.where = 'footer'});
  final ComponentParameterInfo param;
  final String label;
  final double size;
  final bool showLabel;

  /// Where it sits, for its key: `footer-knob-mix`, `row-knob-mix`.
  final String where;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return Padding(padding: const EdgeInsets.only(left: 6), child: Row(mainAxisSize: MainAxisSize.min, children: [
      DeviceKnob(param.id, size: size, labels: false, knobKey: ValueKey('$where-knob-${param.id}')),
      if (showLabel) ParamWatch(target: scope.target, builder: (context) => SizedBox(width: 44, child: Column(
        mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w800, color: Neon.dim)),
        Text(formatParamValue(param, scope.target.value(param.id)), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Neon.code(size: 10, color: scope.accent)),
      ]))),
    ]));
  }
}

/// A device slot's output meter: the peak with a slow fall and a clip light that stays lit until tapped. It reads
/// [DeviceSlotAudio] on a ticker (stopped while the device is off screen). [compact]: a thin bar only.
class SlotMeter extends StatefulWidget {
  const SlotMeter({super.key, required this.target, required this.color, this.compact = false});
  final DeviceTarget target;
  final Color color;
  final bool compact;

  @override
  State<SlotMeter> createState() => _SlotMeterState();
}

class _SlotMeterState extends State<SlotMeter> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_tick);

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }
  final _level = ValueNotifier<double>(0); // 0..1 of the meter's −60..+6 dB span
  bool _clip = false;
  Duration _last = Duration.zero;

  @override
  void dispose() {
    _ticker.dispose();
    _level.dispose();
    super.dispose();
  }

  void _tick(Duration at) {
    if (at - _last < const Duration(milliseconds: 33)) return;
    final dt = (at - _last).inMicroseconds / 1e6;
    _last = at;
    final peak = DeviceSlotAudio.current?.outputPeak(widget.target);
    final pos = peak == null || peak <= 0 ? 0.0 : meterPosition(20 * math.log(peak) / math.ln10);
    // Up at once, down at about 20 dB a second (a third of the span).
    final fall = math.max(0.0, _level.value - dt * 20 / 66);
    _level.value = math.max(pos, fall);
    if (peak != null && peak >= 1.0 && !_clip) setState(() => _clip = true);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final bar = ValueListenableBuilder<double>(valueListenable: _level, builder: (context, v, _) => CustomPaint(
      painter: _MeterPainter(v, c), size: Size.infinite));
    if (widget.compact) return SizedBox(height: 6, child: bar);
    return Row(key: const ValueKey('device-meter'), children: [
      const Text('OUT', style: TextStyle(fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w800, color: Neon.dim)),
      const SizedBox(width: 6),
      Expanded(child: SizedBox(height: 8, child: bar)),
      const SizedBox(width: 6),
      Tooltip(message: _clip ? 'It went over 0 dB: tap to clear' : 'Lights when the output goes over 0 dB',
        child: GestureDetector(
          key: const ValueKey('device-clip'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _clip = false),
          child: SizedBox(width: 22, height: 30, child: Center(child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 10, height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: _clip ? Neon.pink : Neon.ink.withValues(alpha: 0.12),
              boxShadow: _clip ? [BoxShadow(color: Neon.pink.withValues(alpha: 0.7), blurRadius: 8)] : null),
          ))))),
    ]);
  }
}

/// A level in dB on the meter's span: −60 dB at 0, +6 dB at 1 (0 dB at about 0.91).
double meterPosition(double db) => ((db + 60) / 66).clamp(0.0, 1.0);

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.v, this.color);
  final double v;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height / 2));
    canvas.drawRRect(r, Paint()..color = Neon.ink.withValues(alpha: 0.08));
    if (v <= 0) return;
    final w = size.width * v;
    final zero = size.width * meterPosition(0);
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Rect.fromLTWH(0, 0, math.min(w, zero), size.height), Paint()..color = color.withValues(alpha: 0.85));
    if (w > zero) canvas.drawRect(Rect.fromLTWH(zero, 0, w - zero, size.height), Paint()..color = Neon.pink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.v != v || old.color != color;
}

/// The FX chain row's tiny live visual: the slot's output level when the engine meters slots, else the level the
/// device's own display reports, else a still sketch of its first knobs. Live only while on screen.
class DeviceMiniVisual extends StatelessWidget {
  const DeviceMiniVisual({super.key, this.width = 44});
  final double width;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target, c = scope.accent;
    Widget box(Widget child) => SizedBox(key: const ValueKey('device-mini'), width: width, height: 20, child: child);
    if (DeviceSlotAudio.meterFor(t)) {
      return box(Center(child: SlotMeter(target: t, color: c, compact: true)));
    }
    return box(DeviceDisplay(builder: (context, f) {
      final db = f?.outputDb;
      if (db != null) {
        return Center(child: SizedBox(height: 6, child: CustomPaint(painter: _MeterPainter(meterPosition(db), c),
          size: Size.infinite)));
      }
      return ParamWatch(target: t, builder: (context) => CustomPaint(painter: _Sketch(_knobs(t), c, t.bypass)));
    }));
  }

  static List<double> _knobs(DeviceTarget t) {
    final info = t.info;
    if (info == null) return const [];
    return [
      for (final p in info.knobs.where((p) => !p.isChoice).take(6))
        Taper(p.min, p.max, exponential: p.exponential).position(t.value(p.id)),
    ];
  }
}

/// A row of short bars, one per knob, as high as the knob is turned.
class _Sketch extends CustomPainter {
  _Sketch(this.values, this.color, this.off);
  final List<double> values;
  final Color color;
  final bool off;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final w = size.width / values.length;
    final paint = Paint()..color = color.withValues(alpha: off ? 0.25 : 0.7);
    for (var i = 0; i < values.length; i++) {
      final h = math.max(2.0, size.height * values[i]);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * w + 1, size.height - h, w - 2, h), const Radius.circular(1.5)),
        paint);
    }
  }

  @override
  bool shouldRepaint(_Sketch old) =>
      old.color != color || old.off != off || old.values.length != values.length ||
      [for (var i = 0; i < values.length; i++) old.values[i] != values[i]].any((x) => x);
}
