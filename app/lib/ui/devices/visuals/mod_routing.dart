// The mod matrix's touch affordances: source chips to drag onto knobs, the strip that holds them, the list of routes.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../glass.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_scope.dart';

/// The sources a strip offers: the shaped ones first, then the note's own.
const List<ModSource> stripSources = [
  ModSource.env1, ModSource.env2, ModSource.env3, ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.random,
  ModSource.velocity, ModSource.note, ModSource.bend, ModSource.pressure, ModSource.timbre, ModSource.modWheel,
];

/// A mod source as a chip: drag it onto a knob for a new route; tap it ([onTap]) to open the source.
class ModSourceChip extends StatelessWidget {
  const ModSourceChip(this.source, {super.key, this.selected = false, this.onTap, this.count = 0});
  final ModSource source;
  final bool selected;
  final VoidCallback? onTap;

  /// How many routes this source already has (a small number on the chip).
  final int count;

  Widget _chip(BuildContext context, {bool lifted = false}) {
    final c = modSourceColor(source);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        color: c.withValues(alpha: selected || lifted ? 0.28 : 0.1),
        border: Border.all(color: c.withValues(alpha: selected || lifted ? 0.95 : 0.45), width: selected ? 1.4 : 1),
        boxShadow: lifted ? Neon.glow(c) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.drag_indicator, size: 12, color: c.withValues(alpha: 0.8)),
        const SizedBox(width: 2),
        Text(source.short, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: c,
          decoration: TextDecoration.none)),
        if (count > 0) ...[
          const SizedBox(width: 4),
          Text('$count', style: Neon.code(size: 9, color: c.withValues(alpha: 0.8)).copyWith(decoration: TextDecoration.none)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return Draggable<ModSource>(
      key: ValueKey('modsrc-${source.name}'),
      data: source,
      feedback: Material(type: MaterialType.transparency, child: _chip(context, lifted: true)),
      childWhenDragging: Opacity(opacity: 0.4, child: _chip(context)),
      onDragStarted: () {
        Motion.tick();
        scope.dragging.value = source;
      },
      onDragEnd: (_) => scope.dragging.value = null,
      onDraggableCanceled: (_, _) => scope.dragging.value = null,
      child: Tooltip(
        message: 'Drag ${source.label} onto a knob to modulate it',
        waitDuration: const Duration(milliseconds: 700),
        child: InkWell(borderRadius: BorderRadius.circular(13), onTap: onTap, child: _chip(context)),
      ),
    );
  }
}

/// A row of source chips, scrolling sideways, under the editor's tabs on every page.
class ModSourceStrip extends StatelessWidget {
  const ModSourceStrip({super.key, this.selected, this.onSelect});
  final ModSource? selected;
  final ValueChanged<ModSource>? onSelect;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final routes = scope.matrix?.routes ?? const <ModRoute>[];
    return SizedBox(height: 36, child: ListView(
      key: const ValueKey('mod-source-strip'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      children: [
        const Center(child: Padding(padding: EdgeInsets.only(right: 6), child: Text('MOD', style: TextStyle(
          fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)))),
        for (final s in stripSources)
          Padding(padding: const EdgeInsets.only(right: 5), child: ModSourceChip(s,
            selected: s == selected,
            count: routes.where((r) => r.source == s).length,
            onTap: onSelect == null ? null : () => onSelect!(s))),
      ],
    ));
  }
}

/// Every route in the matrix as an editable row (source, destination, amount, polarity, remove), and a way to add one.
class ModRouteList extends StatelessWidget {
  const ModRouteList({super.key, this.newSource = ModSource.lfo1});

  /// The source a route added from the list starts with.
  final ModSource newSource;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final m = scope.matrix;
    if (m == null) return const SizedBox.shrink();
    final routes = m.routes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(height: 28, child: Row(children: [
        Text('ROUTES · ${routes.length} of ${m.slotCount}', style: const TextStyle(
          fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: Neon.dim)),
        const Spacer(),
        TextButton.icon(
          key: const ValueKey('modroute-add'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: m.freeSlot == null ? null : () async {
            final dst = await pickModDestination(context, m);
            if (dst != null) m.add(newSource, dst);
          },
          icon: const Icon(Icons.add, size: 14),
          label: Text('${newSource.short} route', style: const TextStyle(fontSize: 11))),
      ])),
      if (routes.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text(
          'Drag a source chip onto any knob to route it.', style: TextStyle(fontSize: 11, color: Neon.dim))),
      for (final r in routes) _RouteRow(key: ValueKey('modroute-${r.slot}'), route: r, matrix: m),
    ]);
  }
}

class _RouteRow extends StatefulWidget {
  const _RouteRow({super.key, required this.route, required this.matrix});
  final ModRoute route;
  final ModMatrix matrix;

  @override
  State<_RouteRow> createState() => _RouteRowState();
}

class _RouteRowState extends State<_RouteRow> {
  double? _amount;

  @override
  Widget build(BuildContext context) {
    final r = widget.route, m = widget.matrix;
    final c = modSourceColor(r.source);
    final dst = m.target.param(r.paramId);
    final amount = _amount ?? r.amount;
    return Container(
      height: 34,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 6),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: c.withValues(alpha: 0.06),
        border: Border.all(color: c.withValues(alpha: 0.25))),
      child: Row(children: [
        SizedBox(width: 62, child: DropdownButtonHideUnderline(child: DropdownButton<ModSource>(
          value: r.source,
          isDense: true,
          isExpanded: true,
          iconSize: 14,
          style: Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 10, fontWeight: FontWeight.w800, color: c),
          items: [for (final s in stripSources) DropdownMenuItem(value: s, child: Text(s.short))],
          onChanged: (s) { if (s != null) m.setSource(r.slot, s); },
        ))),
        const Icon(Icons.arrow_right_alt, size: 14, color: Neon.dim),
        Expanded(flex: 5, child: InkWell(
          onTap: () async {
            final d = await pickModDestination(context, m);
            if (d != null) m.setDestination(r.slot, d);
          },
          child: Text(dst?.label ?? r.paramId, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Neon.text)),
        )),
        Expanded(flex: 4, child: LayoutBuilder(builder: (context, box) => GestureDetector(
          key: ValueKey('modroute-amount-${r.slot}'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _amount = r.amount,
          onHorizontalDragUpdate: (d) {
            setState(() => _amount = ((_amount ?? r.amount) + 2 * d.delta.dx / box.maxWidth).clamp(-1.0, 1.0));
            m.setAmountLive(r.slot, _amount!);
          },
          onHorizontalDragEnd: (_) {
            m.target.commit();
            setState(() => _amount = null);
          },
          onDoubleTap: () => m.target.set(ModMatrix.amtId(r.slot), 0),
          child: SizedBox(height: 34, child: CustomPaint(painter: _AmountPainter(amount, c), child: Center(child: Text(
            '${amount > 0 ? '+' : ''}${(amount * 100).round()}%', style: Neon.code(size: 9, color: c))))),
        ))),
        InkWell(
          onTap: () => m.setBipolar(r.slot, !r.bipolar),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Text(r.bipolar ? '±' : '+',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: c))),
        ),
        IconButton(
          key: ValueKey('modroute-remove-${r.slot}'),
          tooltip: 'Remove this route',
          iconSize: 14,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          color: Neon.dim,
          onPressed: () => m.remove(r.slot),
          icon: const Icon(Icons.close)),
      ]),
    );
  }
}

class _AmountPainter extends CustomPainter {
  _AmountPainter(this.amount, this.color);
  final double amount;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2, y = size.height / 2;
    canvas.drawLine(Offset(4, y + 8), Offset(size.width - 4, y + 8), Paint()..color = Neon.line..strokeWidth = 2);
    canvas.drawLine(Offset(mid, y + 8), Offset(mid + amount * (mid - 4), y + 8), Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _AmountPainter o) => o.amount != amount || o.color != color;
}

/// Asks for a destination: every parameter the matrix can reach, grouped by its section, with a filter.
Future<String?> pickModDestination(BuildContext context, ModMatrix m) => showGlassSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _DestinationPicker(matrix: m),
);

class _DestinationPicker extends StatefulWidget {
  const _DestinationPicker({required this.matrix});
  final ModMatrix matrix;

  @override
  State<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<_DestinationPicker> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final m = widget.matrix;
    final items = [
      for (final id in m.destinations)
        if (m.target.param(id) case final p? when p.modulatable && !p.isChoice &&
            (_filter.isEmpty || p.label.toLowerCase().contains(_filter.toLowerCase()))) p,
    ];
    return SizedBox(height: MediaQuery.sizeOf(context).height * 0.6, child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: TextField(
        autofocus: false,
        decoration: const InputDecoration(isDense: true, hintText: 'Find a knob', prefixIcon: Icon(Icons.search, size: 16)),
        style: const TextStyle(fontSize: 12),
        onChanged: (v) => setState(() => _filter = v),
      )),
      Expanded(child: ListView(children: [
        for (final p in items)
          ListTile(dense: true, visualDensity: VisualDensity.compact, title: Text(p.label, style: const TextStyle(fontSize: 12)),
            onTap: () => Navigator.pop(context, p.id)),
      ])),
    ]));
  }
}
