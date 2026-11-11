// The mod matrix's touch affordances: source chips to drag onto knobs or tap for assign mode, the strip that holds them, the list of routes.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../glass.dart';
import '../../feedback.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_scope.dart';
import '../kit/feel.dart';
import 'mod_sheet.dart';

/// The sources a strip offers: the shaped ones first, then the note's own.
const List<ModSource> stripSources = [
  ModSource.env1, ModSource.env2, ModSource.env3, ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.random,
  ModSource.velocity, ModSource.note, ModSource.bend, ModSource.pressure, ModSource.timbre, ModSource.modWheel,
];

/// A mod source as a chip (34 dp tall): drag it onto a knob for a new route, or tap it for assign mode (then tap
/// knobs to route it; the editor's banner says so). Without assign mode a tap runs [onTap].
class ModSourceChip extends StatelessWidget {
  const ModSourceChip(this.source, {super.key, this.selected = false, this.onTap, this.count = 0});
  final ModSource source;
  final bool selected;
  final VoidCallback? onTap;

  /// How many routes this source already has (a small number on the chip).
  final int count;

  Widget _chip(BuildContext context, {bool lifted = false, bool active = false}) {
    final c = modSourceColor(source);
    final on = selected || lifted || active;
    return AnimatedContainer(
      duration: Motion.fade(Motion.small, Motion.of(context)),
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        color: c.withValues(alpha: active ? 0.4 : (on ? 0.26 : 0.1)),
        border: Border.all(color: c.withValues(alpha: on ? 0.95 : 0.45), width: active ? 2 : (selected ? 1.4 : 1)),
        boxShadow: lifted || active ? Neon.glow(c) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (active) ...[Icon(Icons.touch_app, size: 14, color: c), const SizedBox(width: 3)]
        else ...[Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
          const SizedBox(width: 5)],
        Text(source.short, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: c,
          decoration: TextDecoration.none)),
        if (count > 0) ...[
          const SizedBox(width: 5),
          Container(
            constraints: const BoxConstraints(minWidth: 16),
            height: 16,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8)),
            child: Text('$count', style: Neon.code(size: 9, color: Neon.bg).copyWith(fontWeight: FontWeight.w800,
              decoration: TextDecoration.none))),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final assigning = scope.assigning;
    Widget body(bool active) => Draggable<ModSource>(
      key: ValueKey('modsrc-${source.name}'),
      data: source,
      // Only a drag that starts downwards (towards the knobs) lifts the chip; sideways scrolls the strip.
      affinity: Axis.vertical,
      feedback: Material(type: MaterialType.transparency, child: _chip(context, lifted: true)),
      childWhenDragging: Opacity(opacity: 0.4, child: _chip(context)),
      onDragStarted: () {
        DeviceFeel.grab();
        assigning?.value = null;
        scope.dragging.value = source;
      },
      onDragEnd: (_) => scope.dragging.value = null,
      onDraggableCanceled: (_, _) => scope.dragging.value = null,
      child: Tooltip(
        message: 'Tap, then tap knobs, or drag onto a knob: ${source.label} moves it',
        waitDuration: const Duration(milliseconds: 700),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: assigning == null ? onTap : () {
            DeviceFeel.tap();
            assigning.value = assigning.value == source ? null : source;
          },
          child: Pressable(glow: modSourceColor(source), radius: 17, child: _chip(context, active: active)),
        ),
      ),
    );
    if (assigning == null) return body(false);
    return ValueListenableBuilder<ModSource?>(valueListenable: assigning, builder: (context, a, _) => body(a == source));
  }
}

/// A row of source chips, scrolling sideways, under the editor's tabs on every page (and inline in the FX tab).
class ModSourceStrip extends StatelessWidget {
  const ModSourceStrip({super.key, this.selected, this.onSelect});
  final ModSource? selected;
  final ValueChanged<ModSource>? onSelect;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final routes = scope.matrix?.routes ?? const <ModRoute>[];
    return SizedBox(height: 44, child: ListView(
      key: const ValueKey('mod-source-strip'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      children: [
        const Center(child: Padding(padding: EdgeInsets.only(right: 6), child: Text('MOD', style: TextStyle(
          fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Neon.dim)))),
        for (final s in stripSources)
          Padding(padding: const EdgeInsets.only(right: 6), child: ModSourceChip(s,
            selected: s == selected,
            count: routes.where((r) => r.source == s).length,
            onTap: onSelect == null ? null : () => onSelect!(s))),
      ],
    ));
  }
}

/// Every route in the matrix as a card with a big amount slider (source, the knob it moves, polarity, scale,
/// remove), and a way to add one.
class ModRouteList extends StatelessWidget {
  const ModRouteList({super.key, this.newSource = ModSource.lfo1, this.only});

  /// The source a route added from the list starts with.
  final ModSource newSource;

  /// Only this source's routes (a source card in the FX tab).
  final ModSource? only;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final m = scope.matrix;
    if (m == null) return const SizedBox.shrink();
    final routes = [for (final r in m.routes) if (only == null || r.source == only) r];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(height: 40, child: Row(children: [
        Expanded(child: Text(only == null ? 'ROUTES · ${routes.length} of ${m.slotCount}' : '${only!.short} MOVES ${routes.length}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: Neon.dim))),
        TextButton.icon(
          key: const ValueKey('modroute-add'),
          onPressed: m.freeSlot == null ? null : () async {
            final dst = await pickModDestination(context, m);
            if (dst != null) {
              final slot = m.add(only ?? newSource, dst);
              if (slot != null) scope.selectedSlot?.value = slot;
            }
          },
          icon: const Icon(Icons.add, size: 16),
          label: Text('${(only ?? newSource).short} to a knob', maxLines: 1, style: const TextStyle(fontSize: 12))),
      ])),
      if (routes.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text(
          'Tap a source chip, then tap knobs. Or drag a chip onto a knob, or long-press a knob.',
          style: TextStyle(fontSize: 11, color: Neon.dim))),
      for (final r in routes) ModRouteCard(route: r, matrix: m),
    ]);
  }
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
          ListTile(key: ValueKey('moddst-${p.id}'), title: Text(p.label, style: const TextStyle(fontSize: 13)),
            onTap: () => Navigator.pop(context, p.id)),
      ])),
    ]));
  }
}
