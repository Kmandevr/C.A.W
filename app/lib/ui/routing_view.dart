// Routing, mobile-first: the "Send to…" menu (New reverb bus, New delay bus, an existing bus), send knobs for strips
// and the focus panel, a send's options, and the routing view (each track's output, sends and keys as chips).
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import '../model/arrange_fx.dart';
import '../model/project.dart';
import '../model/routing.dart';
import '../model/routing_edit.dart';
import '../model/modulation.dart';
import 'arrange/knob.dart';
import 'arrange/long_press_menu.dart';
import 'arrange/track_color.dart';
import 'devices/modulators/modulator_devices.dart' show modulatorColor, showModLinkSheet;
import 'feedback.dart';
import 'glass.dart';
import 'haptics.dart';
import 'theme.dart';
import 'volume_fader.dart';
import 'pointer_input.dart';

/// What "Send to…" offers: a new reverb or delay bus (made with its effect and the send in one tap), or a bus that
/// exists and wouldn't make a loop.
sealed class _SendChoice {
  const _SendChoice();
}

class _NewBus extends _SendChoice {
  const _NewBus(this.kind);
  final FxBusKind kind;
}

class _ToBus extends _SendChoice {
  const _ToBus(this.id);
  final String id;
}

/// "Send to…" for [layer] at [at] (a global position). Returns the send made, or null.
Future<SendDoc?> showSendToMenu(BuildContext context, AppState s, LayerDoc layer, {Offset? at}) async {
  if (layer.sends.length >= SendDoc.maxSends) {
    Haptics.error();
    _say(context, '${layer.name} has ${SendDoc.maxSends} sends, the most a track can have.');
    return null;
  }
  final targets = s.sendTargets(layer);
  final choice = await showLongPressMenu<_SendChoice>(context, at: at ?? menuAnchorOf(context), title: 'Send ${layer.name} to', actions: [
    const MenuAction(_NewBus(FxBusKind.reverb), 'New reverb bus', Icons.blur_on),
    const MenuAction(_NewBus(FxBusKind.delay), 'New delay bus', Icons.blur_linear),
    for (final b in targets) MenuAction(_ToBus(b.id), b.name, Icons.call_split),
    if (targets.isEmpty && s.buses.isNotEmpty)
      const MenuAction(_ToBus(''), 'No other bus', Icons.block, enabled: false,
          hint: 'Already sent there, or it would feed itself'),
  ]);
  if (choice == null) return null;
  Haptics.drop();
  switch (choice) {
    case _NewBus(:final kind):
      s.newFxBus(kind, from: layer);
      return layer.sends.lastOrNull;
    case _ToBus(:final id):
      return id.isEmpty ? null : s.addSend(layer, id);
  }
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));

enum _SendOption { pre, post, mute, unmute, open, remove }

/// A send's options (long-press its knob or chip): pre or post fader, mute, show the bus, remove.
Future<void> showSendOptions(BuildContext context, AppState s, LayerDoc layer, int index, {Offset? at,
    ValueChanged<LayerDoc>? onOpenBus}) async {
  if (index >= layer.sends.length) return;
  final send = layer.sends[index];
  final bus = s.layerById(send.to);
  final pick = await showLongPressMenu<_SendOption>(context, at: at ?? menuAnchorOf(context),
      title: 'Send to ${bus?.name ?? 'missing bus'}', actions: [
    MenuAction(send.pre ? _SendOption.post : _SendOption.pre, send.pre ? 'Post-fader' : 'Pre-fader',
        Icons.swap_vert, hint: null),
    MenuAction(send.mute ? _SendOption.unmute : _SendOption.mute, send.mute ? 'Unmute send' : 'Mute send',
        send.mute ? Icons.volume_up : Icons.volume_off),
    if (bus != null && onOpenBus != null) const MenuAction(_SendOption.open, 'Show the bus', Icons.open_in_new),
    const MenuAction(_SendOption.remove, 'Remove send', Icons.delete_outline, danger: true),
  ]);
  switch (pick) {
    case null:
      return;
    case _SendOption.pre || _SendOption.post:
      s.setSendFlags(layer, index, pre: pick == _SendOption.pre);
    case _SendOption.mute || _SendOption.unmute:
      s.setSendFlags(layer, index, mute: pick == _SendOption.mute);
    case _SendOption.open:
      if (bus != null) onOpenBus?.call(bus);
    case _SendOption.remove:
      s.removeSend(layer, index);
  }
  Haptics.tap();
}

String _sendLabel(SendDoc s) => '${VolumeTaper.label(s.level)}${s.pre ? ' pre' : ''}';

/// A track's sends as knobs (on the fader's dB taper; double-tap for −6 dB), each named for its bus; long-press one
/// for its options. A "+ Send" button opens "Send to…". [compact]: a channel strip's narrow column.
class SendKnobs extends StatelessWidget {
  const SendKnobs({super.key, required this.state, required this.layer, this.compact = false, this.size = 30,
    this.showAdd = true});
  final AppState state;
  final LayerDoc layer;
  final bool compact;

  /// Ends with the "Send" button (a strip puts its own [SendButton] beside the output instead).
  final bool showAdd;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (layer.isFolder && !layer.busEnabled) return const SizedBox.shrink();
    final plan = s.routing;
    final knobs = [
      for (var i = 0; i < layer.sends.length; i++)
        _SendKnob(state: s, layer: layer, index: i, size: size, plays: plan.sendPlays(layer, i), compact: compact),
    ];
    final add = Builder(builder: (context) => Pressable(child: InkWell(
      key: ValueKey('send-add-${layer.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => showSendToMenu(context, s, layer),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Neon.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.call_split, size: 14, color: Neon.violet),
          const SizedBox(width: 4),
          Text(compact ? 'Send' : 'Send to…', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
      ),
    )));
    if (compact) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        ...knobs,
        if (showAdd && layer.sends.length < SendDoc.maxSends) add,
      ]);
    }
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      ...knobs,
      if (layer.sends.length < SendDoc.maxSends) add,
    ]);
  }
}

/// A small "Send to…" icon button (a channel strip's, beside its output).
class SendButton extends StatelessWidget {
  const SendButton({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  @override
  Widget build(BuildContext context) => SizedBox(width: 30, height: 36, child: IconButton(
    key: ValueKey('send-add-${layer.id}'),
    padding: EdgeInsets.zero,
    tooltip: 'Send ${layer.name} to…',
    iconSize: 16,
    color: Neon.violet,
    onPressed: layer.sends.length >= SendDoc.maxSends ? null : () => showSendToMenu(context, state, layer),
    icon: const Icon(Icons.call_split)));
}

class _SendKnob extends StatelessWidget {
  const _SendKnob({required this.state, required this.layer, required this.index, required this.size,
    required this.plays, required this.compact});
  final AppState state;
  final LayerDoc layer;
  final int index;
  final double size;
  final bool plays, compact;

  @override
  Widget build(BuildContext context) {
    final send = layer.sends[index];
    final bus = state.layerById(send.to);
    final color = bus == null ? Neon.dim : trackColor(state, bus);
    final name = bus?.name ?? 'Missing';
    return GestureDetector(
      onLongPressStart: (d) => showSendOptions(context, state, layer, index, at: d.globalPosition),
      onSecondaryTapUp: (d) => showSendOptions(context, state, layer, index, at: d.globalPosition),
      child: Opacity(opacity: plays && !send.mute ? 1 : 0.45, child: Tooltip(
        message: plays ? 'Send to $name (${PointerInput.hold} for options)' : 'Send to $name: not playing (it would feed itself, or the bus is off)',
        child: Knob(
          key: ValueKey('send-${layer.id}-$index'),
          value: VolumeTaper.position(send.level), min: 0, max: 1,
          defaultValue: VolumeTaper.position(SendDoc.defaultLevel),
          label: compact ? (name.length > 9 ? '${name.substring(0, 8)}…' : name) : name,
          color: color, size: size,
          valueText: (_) => _sendLabel(send),
          onChanged: (p) => state.setSendLevelLive(layer, index, VolumeTaper.gain(p)),
          onChangeEnd: () => state.commitSend(layer),
        ),
      )),
    );
  }
}

/// The routing view in a sheet (from the mixer and the focus panel's Mixer tab).
Future<void> showRoutingView(BuildContext context, AppState s, {ValueChanged<LayerDoc>? onOpenLayer}) => showGlassSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SafeArea(child: ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    child: RoutingView(state: s, onOpenLayer: onOpenLayer),
  )),
);

/// Every track and bus with where its sound goes: its output (its folder's bus or the master), its sends and the
/// keys it gives, as chips to tap. Tap the output chip to move the track to another bus; tap "+" for "Send to…";
/// long-press a send for its options. A bus row also lists what feeds it, so it reads both ways.
class RoutingView extends StatelessWidget {
  const RoutingView({super.key, required this.state, this.onOpenLayer});
  final AppState state;
  final ValueChanged<LayerDoc>? onOpenLayer;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: state, builder: (context, _) {
    final s = state;
    final layers = s.project.layers;
    return ListView(key: const ValueKey('routing-view'), shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 16), children: [
      Row(children: [
        const Expanded(child: Text('ROUTING', style: TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.4,
          fontWeight: FontWeight.w800))),
        TextButton.icon(
          key: const ValueKey('routing-new-reverb'),
          onPressed: () {
            Haptics.tap();
            s.newFxBus(FxBusKind.reverb);
          },
          icon: const Icon(Icons.add, size: 16), label: const Text('Reverb bus')),
        TextButton.icon(
          key: const ValueKey('routing-new-delay'),
          onPressed: () {
            Haptics.tap();
            s.newFxBus(FxBusKind.delay);
          },
          icon: const Icon(Icons.add, size: 16), label: const Text('Delay bus')),
      ]),
      if (layers.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Add a track to route it.',
          style: TextStyle(color: Neon.dim)))),
      for (final l in layers) _RouteRow(state: s, layer: l, depth: _depth(s.project, l), onOpenLayer: onOpenLayer),
    ]);
  });

  static int _depth(ProjectDoc p, LayerDoc l) {
    var d = 0;
    var parent = l.parentId;
    while (parent != null && d < 8) {
      d++;
      parent = p.layers.where((x) => x.id == parent).firstOrNull?.parentId;
    }
    return d;
  }
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({required this.state, required this.layer, required this.depth, this.onOpenLayer});
  final AppState state;
  final LayerDoc layer;
  final int depth;
  final ValueChanged<LayerDoc>? onOpenLayer;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final tint = trackColor(s, layer);
    final organises = layer.isFolder && !layer.busEnabled;
    final plan = s.routing;
    final out = s.outputOf(layer);
    // What feeds a bus: the tracks routed into it and the sends to it.
    final heard = layer.isFolder && layer.busEnabled
        ? [
            for (final l in s.project.layers)
              if (routeTarget(s.project, l) == layer.id && !(l.isFolder && !l.busEnabled)) (l, false),
            for (final l in s.project.layers)
              for (var i = 0; i < l.sends.length; i++)
                if (l.sends[i].to == layer.id && plan.sendPlays(l, i)) (l, true),
          ]
        : const <(LayerDoc, bool)>[];
    final keys = [
      for (final c in layer.components)
        if (c.key case final k?) (s.componentLabel(c.id), s.layerById(k.layer), plan.keyPlays(layer, c)),
    ];
    return Padding(
      padding: EdgeInsets.only(left: 12.0 * depth, top: 6),
      child: GlassPanel(tint: tint, radius: 10, child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 4, height: 18, decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 6),
            Icon(layer.isFolder ? (organises ? Icons.folder_outlined : Icons.merge_type) : Icons.graphic_eq, size: 14, color: Neon.dim),
            const SizedBox(width: 4),
            Expanded(child: InkWell(
              onTap: onOpenLayer == null ? null : () => onOpenLayer!(layer),
              child: Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)))),
            if (layer.isFolder) Text(organises ? 'GROUP' : 'BUS',
              style: TextStyle(fontSize: 9, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: organises ? Neon.dim : tint)),
          ]),
          const SizedBox(height: 6),
          if (organises)
            const Text('Only groups its tracks: they go on to the bus above it.', style: TextStyle(fontSize: 10, color: Neon.dim))
          else
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _Chip(
                key: ValueKey('route-out-${layer.id}'),
                icon: Icons.arrow_forward,
                label: out?.name ?? 'Master',
                color: out == null ? Neon.pink : trackColor(s, out),
                tooltip: 'Where ${layer.name} goes: ${PointerInput.tap} to change',
                onTap: (at) => _pickOutput(context, at),
              ),
              for (var i = 0; i < layer.sends.length; i++)
                _Chip(
                  key: ValueKey('route-send-${layer.id}-$i'),
                  icon: Icons.call_split,
                  label: '${s.layerById(layer.sends[i].to)?.name ?? 'Missing'} ${_sendLabel(layer.sends[i])}',
                  color: _busColor(s, layer.sends[i].to),
                  faded: !plan.sendPlays(layer, i) || layer.sends[i].mute,
                  tooltip: plan.sendPlays(layer, i) ? 'A send: ${PointerInput.tap} for its options' : 'Not playing: it would feed itself, or the bus is off',
                  onTap: (at) => showSendOptions(context, s, layer, i, at: at, onOpenBus: onOpenLayer),
                ),
              if (layer.sends.length < SendDoc.maxSends)
                _Chip(
                  key: ValueKey('route-add-${layer.id}'),
                  icon: Icons.add,
                  label: 'Send',
                  color: Neon.violet,
                  tooltip: 'Send to…',
                  onTap: (at) => showSendToMenu(context, s, layer, at: at),
                ),
            ]),
          for (final (name, from, plays) in keys)
            Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
              const Icon(Icons.key, size: 12, color: Neon.yellow),
              const SizedBox(width: 4),
              Expanded(child: Text('$name hears ${from?.name ?? 'a missing track'}${plays ? '' : ' (not playing: it would hear itself)'}',
                style: TextStyle(fontSize: 10, color: plays ? Neon.text : Neon.dim))),
            ])),
          // Project modulation (#161): what moves this layer, and the modulators that hear it.
          if (s.project.linksOnLayer(layer.id) case final links when links.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final l in links)
                _Chip(
                  key: ValueKey('route-mod-${l.id}'),
                  icon: Icons.waves,
                  label: '${s.modSourceLabel(l.ref)} → ${s.modTargetLabel(l.target).split(' · ').skip(1).join(' · ')}',
                  color: modulatorColor(s, l.source),
                  tooltip: 'A modulation: ${PointerInput.tap} for its amount',
                  onTap: (_) => showModLinkSheet(context, s, l.target),
                ),
            ])),
          if ([for (final m in s.project.modulators) if (m.inputId == layer.id && m.hears != 'none') m.name] case final names
              when names.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
              const Icon(Icons.hearing, size: 12, color: Neon.violet),
              const SizedBox(width: 4),
              Expanded(child: Text('Heard by ${names.join(', ')}', style: const TextStyle(fontSize: 10, color: Neon.text))),
            ])),
          if (heard.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(
              'Hears: ${[for (final (l, send) in heard) send ? '${l.name} (send)' : l.name].join(', ')}',
              style: const TextStyle(fontSize: 10, color: Neon.dim))),
        ]),
      )),
    );
  }

  Future<void> _pickOutput(BuildContext context, Offset at) async {
    final s = state;
    // Buses this layer can go into: not itself, nor one inside it.
    bool inside(LayerDoc candidate) {
      var parent = candidate.parentId;
      for (var d = 0; parent != null && d <= s.project.layers.length; d++) {
        if (parent == layer.id) return true;
        parent = s.layerById(parent)?.parentId;
      }
      return false;
    }
    final options = [for (final b in s.buses) if (b.id != layer.id && !inside(b)) b];
    final current = s.outputOf(layer)?.id;
    final pick = await showLongPressMenu<String>(context, at: at, title: '${layer.name} goes to', actions: [
      MenuAction('', 'Master', Icons.speaker, checked: current == null),
      for (final b in options) MenuAction(b.id, b.name, Icons.merge_type, checked: current == b.id),
    ]);
    if (pick == null || pick == (current ?? '')) return;
    if (s.moveLayerIntoFolder(layer, pick.isEmpty ? null : pick)) {
      Haptics.drop();
    } else {
      Haptics.error();
    }
  }
}

Color _busColor(AppState s, String id) {
  final b = s.layerById(id);
  return b == null ? Neon.dim : trackColor(s, b);
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.icon, required this.label, required this.color, required this.onTap,
    this.tooltip, this.faded = false});
  final IconData icon;
  final String label;
  final Color color;
  final void Function(Offset at) onTap;
  final String? tooltip;
  final bool faded;

  @override
  Widget build(BuildContext context) => Tooltip(message: tooltip ?? label, child: Opacity(
    opacity: faded ? 0.45 : 1,
    child: Pressable(glow: color, child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => onTap(d.globalPosition),
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.7))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        ]),
      ),
    )),
  ));
}
