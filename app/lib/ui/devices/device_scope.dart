// What every control in a device editor shares: the device, its mod matrix, the source being dragged, value text.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../engine/component_info.dart';
import '../../model/device_target.dart';
import '../../model/mod_matrix.dart';
import '../motion.dart';
import '../theme.dart';

/// Hands the device editor's state to its controls.
class DeviceScope extends InheritedWidget {
  const DeviceScope({super.key, required this.target, required this.matrix, required this.dragging,
    required this.accent, Color? secondary, required this.focusSource, this.openSource, this.inline = false,
    this.assigning, this.selectedSlot, required super.child})
      : secondary = secondary ?? accent;

  final DeviceTarget target;

  /// The device's mod matrix, or null when it has none.
  final ModMatrix? matrix;

  /// The mod source being dragged onto a knob (every knob it can reach lights up), or null.
  final ValueNotifier<ModSource?> dragging;

  /// The device's colour, and its family's second colour (the right channel, the output, a gradient's end).
  final Color accent, secondary;

  /// Assign mode (a tapped source chip): while set, every knob the source can reach pulses and a tap on one adds
  /// or removes that route. Null when the editor has no assign mode.
  final ValueNotifier<ModSource?>? assigning;

  /// The route (its slot) last dropped, tapped or edited: the one a knob's ring drag or a two-finger drag sets.
  final ValueNotifier<int?>? selectedSlot;

  /// The source the MOD page shows (a tapped chip picks it).
  final ValueNotifier<ModSource> focusSource;

  /// Shows [ModSource]'s page (the editor's MOD tab), when the editor has one.
  final ValueChanged<ModSource>? openSource;

  /// The device is shown inline in the FX stack ([DeviceInline]) rather than in its own editor: pages lay out
  /// without scrolling and heroes are compact.
  final bool inline;

  /// Whether [context] is inside an inline device (no dependency: the scope rebuilds its controls on every change).
  static bool isInline(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DeviceScope>()?.inline ?? false;

  static DeviceScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DeviceScope>();

  /// Makes route [slot] the selected one (what a ring or two-finger drag on its knob sets).
  static void maybeSelect(BuildContext context, int slot) {
    final s = context.getInheritedWidgetOfExactType<DeviceScope>()?.selectedSlot;
    if (s != null) s.value = slot;
  }

  /// The same scope over [child] with a fresh [matrix] (a sheet over the editor, rebuilt on every change).
  DeviceScope copyWith({ModMatrix? matrix, ValueChanged<ModSource>? openSource, required Widget child}) => DeviceScope(
    target: target, matrix: matrix ?? this.matrix, dragging: dragging, accent: accent, secondary: secondary,
    focusSource: focusSource, openSource: openSource ?? this.openSource, inline: inline, assigning: assigning, selectedSlot: selectedSlot, child: child);

  static DeviceScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<DeviceScope>();
    assert(s != null, 'a device control outside a DeviceScope');
    return s!;
  }

  @override
  // The editor rebuilds the scope only when the device changed (a value, undo, the catalog), and every control
  // reads its values through it, so each rebuild reaches them (an effect has no mod matrix whose new object would).
  bool updateShouldNotify(DeviceScope old) => true;
}

/// A source's colour: envelopes in greens, LFOs in blues, random pink, the note's own sources yellow; each
/// envelope and LFO its own shade, so several rings on one knob tell apart (as Vital colours each modulator).
Color modSourceColor(ModSource s) => switch (s) {
      ModSource.env1 => Neon.green,
      ModSource.env2 => Color.lerp(Neon.green, Neon.blue, 0.5)!,
      ModSource.env3 => Color.lerp(Neon.green, Neon.yellow, 0.55)!,
      ModSource.lfo1 => Neon.blue,
      ModSource.lfo2 => Color.lerp(Neon.blue, Neon.violet, 0.6)!,
      ModSource.lfo3 => Color.lerp(Neon.blue, Colors.white, 0.5)!,
      ModSource.random => Neon.pink,
      ModSource.none => Neon.dim,
      _ => Neon.yellow,
    };

/// A value as a short readout: choices by name, Hz as Hz or kHz, seconds as ms below one, a 0..1 value with no unit
/// as a percentage, a −1..1 pan as L/C/R.
String formatParamValue(ComponentParameterInfo? p, double v, {bool pan = false}) {
  if (p == null) return v.toStringAsFixed(2);
  if (p.isChoice) {
    final i = (v - p.min).round().clamp(0, p.choices.length - 1);
    return p.choices[i];
  }
  if (pan || p.id.endsWith('pan')) {
    if (v.abs() < 0.005) return 'C';
    return '${(v.abs() * 100).round()}${v < 0 ? 'L' : 'R'}';
  }
  switch (p.unit) {
    case 'Hz':
      return v >= 1000 ? '${(v / 1000).toStringAsFixed(v >= 10000 ? 1 : 2)}k' : (v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 10 ? 1 : 2));
    case 's':
      return v < 1 ? '${(v * 1000).toStringAsFixed(v < 0.01 ? 1 : 0)} ms' : '${v.toStringAsFixed(2)} s';
    case 'dB':
      return '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}';
    case 'ct':
      return '${v.round()} ct';
    case 'st':
      return '${v > 0 ? '+' : ''}${v.round()} st';
  }
  if (p.step >= 1) return '${v > 0 && p.min < 0 ? '+' : ''}${v.round()}';
  if (p.min == 0 && p.max == 1) return '${(v * 100).round()}%';
  if (p.min == -1 && p.max == 1) return '${v > 0 ? '+' : ''}${(v * 100).round()}%';
  final range = p.max - p.min;
  return v.toStringAsFixed(range > 20 ? 0 : (range > 2 ? 1 : 2));
}

/// A short knob label: the descriptor's name without its section ("Osc 1 detune" → "detune"), capitalised.
String shortParamLabel(ComponentParameterInfo? p, String fallback) {
  final name = p?.label ?? fallback;
  final m = RegExp(r'^(Osc|Filter|Env|LFO|Mod|Band) \d+ ').firstMatch(name);
  final s = m == null ? name : name.substring(m.end);
  return s.isEmpty ? name : s[0].toUpperCase() + s.substring(1);
}

/// A section heading inside a device card: small capitals, spaced.
class DeviceHeading extends StatelessWidget {
  const DeviceHeading(this.text, {super.key, this.color = Neon.dim, this.trailing});
  final String text;
  final Color color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => SizedBox(height: 22, child: Row(children: [
    Text(text, style: TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: color)),
    const SizedBox(width: 8),
    if (trailing != null) Expanded(child: Align(alignment: Alignment.centerRight, child: trailing)),
  ]));
}

/// A device card: a see-through panel with a thin outline in [color], a title row and [child].
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.title, required this.child, this.color = Neon.blue, this.actions = const [],
    this.dimmed = false, this.leading});
  final String title;
  final Widget child;
  final Color color;
  final List<Widget> actions;
  final bool dimmed;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: const Duration(milliseconds: 120),
    opacity: dimmed ? 0.5 : 1,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
          Color.lerp(Neon.panel, color, 0.12)!.withValues(alpha: 0.7),
          Color.lerp(Neon.panel, color, 0.03)!.withValues(alpha: 0.6),
        ]),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: [
          color.withValues(alpha: 0.9), color.withValues(alpha: 0.0)]))),
        Padding(padding: const EdgeInsets.fromLTRB(10, 2, 8, 8), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            SizedBox(height: 32, child: Row(children: [
              ?leading,
              if (leading != null) const SizedBox(width: 6),
              Text(title, style: TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: color,
                shadows: [Shadow(color: color.withValues(alpha: 0.5), blurRadius: 8)])),
              const SizedBox(width: 8),
              Expanded(child: Align(alignment: Alignment.centerRight,
                child: Row(mainAxisSize: MainAxisSize.min, children: [for (final a in actions) Flexible(child: a)]))),
            ])),
            child,
          ])),
      ]),
    ),
  );
}

/// [child] growing and shrinking to its size over [Motion.standard] (no animation with motion Off: a zero-length
/// AnimatedSize would mark itself dirty inside its own layout).
Widget foldSize(BuildContext context, Widget child) {
  final d = Motion.fade(Motion.standard, Motion.of(context));
  if (d == Duration.zero) return child;
  return AnimatedSize(duration: d, curve: Curves.easeOutCubic, alignment: Alignment.topCenter, child: child);
}

/// A device card that folds to its title row (an accordion section, so a page expands in place instead of
/// opening another screen): a tap on the title row opens or closes it, with [summary] (what it is set to) beside
/// the title. [actions] (a type picker) lead its body. It remembers being open per [storageId] in the route's page storage.
class DeviceExpandCard extends StatefulWidget {
  const DeviceExpandCard({super.key, required this.storageId, required this.title, required this.child,
    this.color = Neon.blue, this.summary, this.leading, this.actions = const [], this.dimmed = false,
    this.initiallyOpen = false, this.open});
  final String storageId, title;
  final String? summary;
  final Widget child;
  final Color color;
  final Widget? leading;
  final List<Widget> actions;
  final bool dimmed, initiallyOpen;

  /// Opens or closes it from outside (a source opened from the strip); null leaves it to the user.
  final ValueListenable<bool>? open;

  @override
  State<DeviceExpandCard> createState() => DeviceExpandCardState();
}

class DeviceExpandCardState extends State<DeviceExpandCard> {
  late bool _open;

  bool get isOpen => _open;

  @override
  void initState() {
    super.initState();
    _open = PageStorage.maybeOf(context)?.readState(context, identifier: 'expand-${widget.storageId}') as bool? ??
        widget.initiallyOpen;
    widget.open?.addListener(_external);
  }

  @override
  void didUpdateWidget(DeviceExpandCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) {
      oldWidget.open?.removeListener(_external);
      widget.open?.addListener(_external);
    }
  }

  @override
  void dispose() {
    widget.open?.removeListener(_external);
    super.dispose();
  }

  void _external() {
    final v = widget.open!.value;
    if (v != _open) set(v);
    if (v) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 250), alignment: 0.05);
      });
    }
  }

  void set(bool open) {
    setState(() => _open = open);
    PageStorage.maybeOf(context)?.writeState(context, open, identifier: 'expand-${widget.storageId}');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    final level = Motion.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: widget.dimmed ? 0.55 : 1,
      child: AnimatedContainer(
        duration: Motion.fade(Motion.standard, level),
        margin: const EdgeInsets.only(bottom: 10),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
            Color.lerp(Neon.panel, c, _open ? 0.14 : 0.08)!.withValues(alpha: 0.75),
            Color.lerp(Neon.panel, c, 0.03)!.withValues(alpha: 0.6),
          ]),
          border: Border.all(color: c.withValues(alpha: _open ? 0.45 : 0.25)),
          boxShadow: _open ? [BoxShadow(color: c.withValues(alpha: 0.12), blurRadius: 16)] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: [
            c.withValues(alpha: 0.9), c.withValues(alpha: 0.0)]))),
          InkWell(
            key: ValueKey('expand-${widget.storageId}'),
            onTap: () {
              Motion.tick();
              set(!_open);
            },
            child: Padding(padding: const EdgeInsets.fromLTRB(10, 4, 4, 4), child: SizedBox(height: 40, child: Row(children: [
              ?widget.leading,
              if (widget.leading != null) const SizedBox(width: 6),
              Text(widget.title, style: TextStyle(fontSize: 12, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: c,
                shadows: [Shadow(color: c.withValues(alpha: 0.5), blurRadius: 8)])),
              const SizedBox(width: 8),
              Expanded(child: widget.summary == null ? const SizedBox.shrink() : Text(widget.summary!, maxLines: 1,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Neon.dim))),
              AnimatedRotation(turns: _open ? 0.5 : 0, duration: Motion.fade(Motion.small, level),
                child: Icon(Icons.expand_more, size: 22, color: c)),
            ]))),
          ),
          foldSize(context, _open
              ? Padding(padding: const EdgeInsets.fromLTRB(10, 0, 8, 10), child: widget.actions.isEmpty ? widget.child
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                      Wrap(spacing: 8, runSpacing: 6, children: widget.actions),
                      const SizedBox(height: 6),
                      widget.child,
                    ]))
              : const SizedBox(width: double.infinity)),
        ]),
      ),
    );
  }
}

/// Lays [children] out in columns of at least [minWidth] each when there is room, else stacked.
class DeviceColumns extends StatelessWidget {
  const DeviceColumns({super.key, required this.children, this.minWidth = 320, this.gap = 8});
  final List<Widget> children;
  final double minWidth, gap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final n = math.max(1, math.min(children.length, (box.maxWidth / minWidth).floor()));
    if (n == 1) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += n) {
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var k = 0; k < n; k++) ...[
          if (k > 0) SizedBox(width: gap),
          Expanded(child: i + k < children.length ? children[i + k] : const SizedBox.shrink()),
        ],
      ]));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  });
}
