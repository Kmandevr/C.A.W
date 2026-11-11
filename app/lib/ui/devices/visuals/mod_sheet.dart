// Modulation on touch: a route's card with a big amount slider, a knob's Modulation sheet, and assign mode's banner.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../feedback.dart';
import '../../glass.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../midi_learn.dart';
import '../kit/feel.dart';
import 'mod_routing.dart';

/// A route's amount as a full-width slider (46 dp tall): drag anywhere along it, sideways; the further the finger
/// moves up or down off the slider the finer the drag (a video scrubber), and a second finger is fine too. The
/// percentage is large in the middle; a tap on it types one. The bar grows from the centre: right is up, left down.
class ModAmountSlider extends StatefulWidget {
  const ModAmountSlider({super.key, required this.route, required this.matrix, this.height = 46});
  final ModRoute route;
  final ModMatrix matrix;
  final double height;

  @override
  State<ModAmountSlider> createState() => _ModAmountSliderState();
}

class _ModAmountSliderState extends State<ModAmountSlider> {
  double? _amount; // during a drag
  double _startY = 0;

  ModRoute get r => widget.route;

  void _start(DragStartDetails d) {
    DeviceFeel.grab();
    _startY = d.localPosition.dy;
    DeviceScope.maybeSelect(context, r.slot);
    setState(() => _amount = r.amount);
  }

  void _update(DragUpdateDetails d, double width) {
    final off = (d.localPosition.dy - _startY).abs();
    final scrub = off < 60 ? 1.0 : (off < 140 ? 0.4 : 0.15);
    final before = _amount ?? r.amount;
    var next = (before + 2 * d.delta.dx / width * scrub * DeviceFingers.fine).clamp(-1.0, 1.0);
    // A detent at zero: crossing it ticks and holds there for a moment.
    if (before != 0 && (next == 0 || (before > 0) != (next > 0))) {
      DeviceFeel.detent();
      if ((next - 0).abs() < 0.02) next = 0;
    }
    setState(() => _amount = next);
    widget.matrix.setAmountLive(r.slot, next);
  }

  void _end() {
    DeviceFeel.release();
    widget.matrix.target.commit();
    setState(() => _amount = null);
  }

  Future<void> _type() async {
    DeviceFeel.tap();
    final field = TextEditingController(text: (r.amount * 100).toStringAsFixed(0));
    final typed = await showDialog<double>(context: context, builder: (c) => AlertDialog(
      title: Text('${r.source.label} amount', style: const TextStyle(fontSize: 14)),
      content: TextField(
        key: const ValueKey('modamount-type'),
        controller: field,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: const InputDecoration(suffixText: '%', helperText: '−100 .. 100'),
        onSubmitted: (s) => Navigator.of(c).pop(double.tryParse(s.trim())),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(c).pop(double.tryParse(field.text.trim())), child: const Text('Set')),
      ],
    ));
    field.dispose();
    if (typed != null) widget.matrix.setAmount(r.slot, typed / 100);
  }

  @override
  Widget build(BuildContext context) {
    final c = modSourceColor(r.source);
    final amount = _amount ?? r.amount;
    return LayoutBuilder(builder: (context, box) => GestureDetector(
      key: ValueKey('modamount-${r.slot}'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: (d) => _update(d, box.maxWidth),
      onHorizontalDragEnd: (_) => _end(),
      onHorizontalDragCancel: () {
        if (_amount != null) _end();
      },
      child: Semantics(
        slider: true,
        label: '${r.source.label} amount',
        value: '${(amount * 100).round()}%',
        increasedValue: '${((amount + 0.01).clamp(-1.0, 1.0) * 100).round()}%',
        decreasedValue: '${((amount - 0.01).clamp(-1.0, 1.0) * 100).round()}%',
        onIncrease: () => widget.matrix.setAmount(r.slot, r.amount + 0.01),
        onDecrease: () => widget.matrix.setAmount(r.slot, r.amount - 0.01),
        child: AnimatedScale(
          scale: _amount != null && Motion.of(context) == MotionLevel.full ? 1.02 : 1,
          duration: Motion.fade(Motion.small, Motion.of(context)),
          child: SizedBox(height: widget.height, child: CustomPaint(
            painter: _AmountBar(amount, c, held: _amount != null, bipolar: r.bipolar),
            child: Center(child: GestureDetector(
              onTap: _type,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), child: Text(
                '${amount > 0 ? '+' : ''}${(amount * 100).round()}%',
                style: Neon.code(size: 15, color: Neon.text).copyWith(fontWeight: FontWeight.w800,
                  shadows: [Shadow(color: c, blurRadius: 8)]))),
            )),
          )),
        ),
      ),
    ));
  }
}

class _AmountBar extends CustomPainter {
  _AmountBar(this.amount, this.color, {required this.held, required this.bipolar});
  final double amount;
  final Color color;
  final bool held, bipolar;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    canvas.drawRRect(r, Paint()..color = Colors.white.withValues(alpha: 0.04));
    canvas.drawRRect(r, Paint()
      ..color = color.withValues(alpha: held ? 0.9 : 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = held ? 1.6 : 1);
    final mid = size.width / 2;
    canvas.save();
    canvas.clipRRect(r);
    final x = mid + amount * mid;
    final fill = Rect.fromLTRB(amount < 0 ? x : mid, 0, amount < 0 ? mid : x, size.height);
    canvas.drawRect(fill, Paint()
      ..shader = LinearGradient(colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.5)],
          begin: amount < 0 ? Alignment.centerRight : Alignment.centerLeft,
          end: amount < 0 ? Alignment.centerLeft : Alignment.centerRight).createShader(fill));
    // Bipolar: a faint mirror shows the route also swings the other way.
    if (bipolar && amount != 0) {
      final m = mid - amount * mid;
      canvas.drawRect(Rect.fromLTRB(amount < 0 ? mid : m, 0, amount < 0 ? m : mid, size.height),
          Paint()..color = color.withValues(alpha: 0.08));
    }
    canvas.restore();
    // Ticks at −100, −50, 0, 50, 100 %.
    for (var k = 0; k <= 4; k++) {
      final tx = size.width * k / 4;
      canvas.drawLine(Offset(tx, size.height - (k == 2 ? 12 : 6)), Offset(tx, size.height), Paint()
        ..color = Neon.dim.withValues(alpha: 0.6)
        ..strokeWidth = 1);
    }
    // The handle.
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x.clamp(3, size.width - 3), size.height / 2),
        width: 5, height: size.height - 10), const Radius.circular(3)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _AmountBar o) =>
      o.amount != amount || o.color != color || o.held != held || o.bipolar != bipolar;
}

/// One route as a card: the source (and, in the matrix, the knob it moves), the big amount slider, the polarity
/// ("+" up only, "±" both ways), what scales it, and remove. A tap selects it (the knob's ring drag sets it then).
class ModRouteCard extends StatelessWidget {
  const ModRouteCard({super.key, required this.route, required this.matrix, this.showDestination = true});
  final ModRoute route;
  final ModMatrix matrix;
  final bool showDestination;

  @override
  Widget build(BuildContext context) {
    final sel = DeviceScope.maybeOf(context)?.selectedSlot;
    if (sel == null) return _card(context, false);
    return ValueListenableBuilder<int?>(valueListenable: sel, builder: (context, s, _) => _card(context, s == route.slot));
  }

  Widget _card(BuildContext context, bool selected) {
    final r = route, m = matrix;
    final c = modSourceColor(r.source);
    final dst = m.target.param(r.paramId);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => DeviceScope.maybeSelect(context, r.slot),
      child: AnimatedContainer(
        key: ValueKey('modroute-${r.slot}'),
        duration: Motion.fade(Motion.small, Motion.of(context)),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: c.withValues(alpha: selected ? 0.12 : 0.06),
          border: Border.all(color: c.withValues(alpha: selected ? 0.8 : 0.3), width: selected ? 1.4 : 1),
          boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.2), blurRadius: 12)] : null),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 40, child: Row(children: [
            _SourceMenu(route: r, matrix: m),
            if (showDestination) ...[
              const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward, size: 14, color: Neon.dim)),
              Expanded(child: InkWell(
                key: ValueKey('modroute-dst-${r.slot}'),
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final d = await pickModDestination(context, m);
                  if (d != null) m.setDestination(r.slot, d);
                },
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8), child: Text(
                  dst?.label ?? r.paramId, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Neon.text))),
              )),
            ] else
              const Spacer(),
            _Polarity(route: r, matrix: m),
            IconButton(
              key: ValueKey('modroute-remove-${r.slot}'),
              tooltip: 'Remove this modulation',
              iconSize: 18,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              color: Neon.dim,
              onPressed: () {
                DeviceFeel.tap();
                m.remove(r.slot);
              },
              icon: const Icon(Icons.delete_outline)),
          ])),
          const SizedBox(height: 4),
          ModAmountSlider(route: r, matrix: m),
          if (m.hasVia) Padding(padding: const EdgeInsets.only(top: 6), child: _ViaRow(route: r, matrix: m)),
        ]),
      ),
    );
  }
}

/// The route's source as a coloured pill; a tap picks another source.
class _SourceMenu extends StatelessWidget {
  const _SourceMenu({required this.route, required this.matrix});
  final ModRoute route;
  final ModMatrix matrix;

  @override
  Widget build(BuildContext context) {
    final c = modSourceColor(route.source);
    return PopupMenuButton<ModSource>(
      key: ValueKey('modroute-src-${route.slot}'),
      tooltip: 'Change the source',
      onSelected: (s) {
        DeviceFeel.tap();
        matrix.setSource(route.slot, s);
      },
      itemBuilder: (_) => [
        for (final s in stripSources)
          PopupMenuItem(value: s, child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: modSourceColor(s))),
            const SizedBox(width: 8),
            Text(s.label, style: const TextStyle(fontSize: 13)),
          ])),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: c.withValues(alpha: 0.2),
          border: Border.all(color: c.withValues(alpha: 0.8))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c,
            boxShadow: [BoxShadow(color: c, blurRadius: 6)])),
          const SizedBox(width: 6),
          Text(route.source.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c)),
          Icon(Icons.arrow_drop_down, size: 16, color: c),
        ]),
      ),
    );
  }
}

/// "+" (moves the knob up only) or "±" (both ways), as two segments.
class _Polarity extends StatelessWidget {
  const _Polarity({required this.route, required this.matrix});
  final ModRoute route;
  final ModMatrix matrix;

  @override
  Widget build(BuildContext context) {
    final c = modSourceColor(route.source);
    Widget seg(String label, bool bipolar, String tip) => Tooltip(message: tip, child: GestureDetector(
      key: ValueKey('modroute-${bipolar ? 'bipolar' : 'unipolar'}-${route.slot}'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DeviceFeel.tap();
        if (route.bipolar != bipolar) matrix.setBipolar(route.slot, bipolar);
      },
      child: Pressable(glow: c, radius: 8, child: AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        width: 38, height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
          color: route.bipolar == bipolar ? c.withValues(alpha: 0.28) : Colors.transparent),
        child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900,
          color: route.bipolar == bipolar ? Neon.text : Neon.dim)),
      )),
    ));
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: Neon.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('+', false, 'Unipolar: moves the knob one way'),
        seg('±', true, 'Bipolar: swings both ways'),
      ]),
    );
  }
}

/// "Scaled by": a second source the amount is multiplied by (the mod wheel deepening a vibrato).
class _ViaRow extends StatelessWidget {
  const _ViaRow({required this.route, required this.matrix});
  final ModRoute route;
  final ModMatrix matrix;

  @override
  Widget build(BuildContext context) => Row(children: [
    const Text('Scaled by', style: TextStyle(fontSize: 11, color: Neon.dim)),
    const SizedBox(width: 8),
    PopupMenuButton<ModSource>(
      key: ValueKey('modroute-via-${route.slot}'),
      tooltip: 'Scale this amount by another source',
      onSelected: (s) {
        DeviceFeel.tap();
        matrix.setVia(route.slot, s);
      },
      itemBuilder: (_) => [
        for (final s in [ModSource.none, ...stripSources]) PopupMenuItem(value: s, child: Text(
          s == ModSource.none ? 'Nothing (full amount)' : s.label, style: const TextStyle(fontSize: 13))),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), border: Border.all(color: Neon.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(route.via == ModSource.none ? 'Nothing' : route.via.label, style: TextStyle(fontSize: 11,
            fontWeight: FontWeight.w700, color: route.via == ModSource.none ? Neon.dim : modSourceColor(route.via))),
          const Icon(Icons.arrow_drop_down, size: 16, color: Neon.dim),
        ]),
      ),
    ),
  ]);
}

/// Opens the Modulation sheet of [paramId]'s knob over the device (a bottom sheet, not a new page): its value (tap
/// to type), every route on it as a [ModRouteCard], and "+ Add source" chips for the sources not routed yet.
Future<void> showModulationSheet(BuildContext context, String paramId, {VoidCallback? onTypeValue}) {
  final scope = DeviceScope.of(context);
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 620),
    builder: (_) => ListenableBuilder(
      listenable: scope.target.tick,
      builder: (context, _) {
        final matrix = ModMatrix(scope.target);
        return scope.copyWith(matrix: matrix, child: _ModulationSheet(paramId: paramId, onTypeValue: onTypeValue));
      },
    ),
  );
}

class _ModulationSheet extends StatelessWidget {
  const _ModulationSheet({required this.paramId, this.onTypeValue});
  final String paramId;
  final VoidCallback? onTypeValue;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final m = scope.matrix!;
    final p = t.param(paramId);
    if (p == null) return const SizedBox.shrink();
    final routes = m.routesTo(paramId);
    final unused = [for (final s in stripSources) if (!routes.any((r) => r.source == s)) s];
    final full = m.freeSlot == null;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: ListView(
        key: const ValueKey('mod-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('MODULATION', style: TextStyle(fontSize: 10, letterSpacing: 1.6, fontWeight: FontWeight.w800,
                color: scope.accent)),
              Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ])),
            if (onTypeValue != null) TextButton.icon(
              key: const ValueKey('mod-sheet-type'),
              onPressed: onTypeValue,
              icon: const Icon(Icons.keyboard_outlined, size: 16),
              label: Text(formatParamValue(p, t.value(p.id)), style: Neon.code(size: 13, color: scope.accent))),
          ]),
          Align(alignment: Alignment.centerLeft, child: MidiLearnButton(target: t, paramId: p.id, color: scope.accent)),
          const SizedBox(height: 10),
          if (routes.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
              'Nothing moves ${shortParamLabel(p, p.id).toLowerCase()} yet. Pick a source below, or drag a source chip onto the knob.',
              style: const TextStyle(fontSize: 12, color: Neon.dim))),
          for (final r in routes) ModRouteCard(key: ValueKey('mod-sheet-route-${r.slot}'), route: r, matrix: m,
            showDestination: false),
          const SizedBox(height: 6),
          Text(full ? 'All ${m.slotCount} modulation slots are in use' : '+ ADD SOURCE', style: const TextStyle(
            fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in unused) _AddChip(source: s, enabled: !full, onTap: () {
              final slot = m.add(s, paramId);
              if (slot != null) {
                DeviceFeel.detent();
                scope.selectedSlot?.value = slot;
              }
            }),
          ]),
        ],
      ),
    );
  }
}

class _AddChip extends StatelessWidget {
  const _AddChip({required this.source, required this.onTap, this.enabled = true});
  final ModSource source;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = modSourceColor(source);
    return GestureDetector(
      key: ValueKey('mod-sheet-add-${source.name}'),
      onTap: enabled ? onTap : null,
      child: Pressable(glow: c, radius: 18, enabled: enabled, child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), color: c.withValues(alpha: enabled ? 0.1 : 0.03),
          border: Border.all(color: c.withValues(alpha: enabled ? 0.5 : 0.15))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add, size: 14, color: enabled ? c : Neon.dim),
          const SizedBox(width: 4),
          Text(source.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: enabled ? c : Neon.dim)),
        ]),
      )),
    );
  }
}

/// Assign mode's banner (a tapped source chip): names the source and what a tap on a knob does, counts its routes,
/// and ends with Done; "Edit" shows the source's own controls when the editor has them.
class ModAssignBanner extends StatelessWidget {
  const ModAssignBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final assigning = scope.assigning;
    if (assigning == null) return const SizedBox.shrink();
    return ValueListenableBuilder<ModSource?>(
      valueListenable: assigning,
      builder: (context, src, _) {
        final Widget child;
        if (src == null) {
          child = const SizedBox(width: double.infinity);
        } else {
          final c = modSourceColor(src);
          final n = scope.matrix?.routes.where((r) => r.source == src).length ?? 0;
          child = Container(
            key: const ValueKey('mod-assign-banner'),
            margin: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            padding: const EdgeInsets.only(left: 12),
            height: 44,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: c.withValues(alpha: 0.16),
              border: Border.all(color: c.withValues(alpha: 0.8)), boxShadow: [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 12)]),
            child: Row(children: [
              Icon(Icons.touch_app_outlined, size: 18, color: c),
              const SizedBox(width: 8),
              Expanded(child: Text.rich(TextSpan(children: [
                const TextSpan(text: 'Tap knobs to route '),
                TextSpan(text: src.label, style: TextStyle(color: c, fontWeight: FontWeight.w800)),
                TextSpan(text: n == 0 ? '' : ' · $n on', style: const TextStyle(color: Neon.dim)),
              ]), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Neon.text))),
              if (scope.openSource != null) TextButton(
                key: const ValueKey('mod-assign-edit'),
                onPressed: () {
                  assigning.value = null;
                  scope.openSource!(src);
                },
                child: const Text('Edit', style: TextStyle(fontSize: 12))),
              TextButton(
                key: const ValueKey('mod-assign-done'),
                onPressed: () {
                  DeviceFeel.tap();
                  assigning.value = null;
                },
                child: Text('Done', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: c))),
            ]),
          );
        }
        return foldSize(context, child);
      },
    );
  }
}
