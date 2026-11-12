// Project modulators (#161) as device-kit devices on a track's FX stack: output chips to drag or tap onto any knob, an LFO you draw, steps, envelopes, followers, macros, their links.
import '../kit/repaint.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../model/app_state.dart';
import '../../../model/arrange_fx.dart';
import '../../../model/mixer_fx.dart';
import '../../../model/flagship_shapes.dart' show lfoValue;
import '../../../model/mod_matrix.dart';
import '../../../model/modulation.dart';
import '../../../model/project.dart';
import '../../../model/routing_edit.dart';
import '../../arrange/long_press_menu.dart';
import '../../glass.dart';
import '../../feedback.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../../pointer_input.dart';

/// A modulator's colour: its kind's (LFOs blue, envelopes green, the follower amber, steps orange, random pink,
/// macros violet, MIDI yellow), each further one of a kind a shade on, so rings on one knob tell apart.
Color modulatorColor(AppState s, String modulatorId) {
  final m = s.project.modulator(modulatorId);
  if (m == null) return Neon.dim;
  final base = switch (m.componentId) {
    ModulatorKinds.lfo => Neon.blue,
    ModulatorKinds.envelope => Neon.green,
    ModulatorKinds.follower => Color.lerp(Neon.yellow, Neon.pink, 0.45)!,
    ModulatorKinds.steps => Color.lerp(Neon.yellow, Neon.pink, 0.2)!,
    ModulatorKinds.random => Neon.pink,
    ModulatorKinds.macros => Neon.violet,
    ModulatorKinds.midi => Neon.yellow,
    _ => Color.lerp(Neon.blue, Neon.green, 0.5)!,
  };
  final same = s.project.modulators.where((x) => x.componentId == m.componentId).toList();
  final i = same.indexOf(m);
  return i <= 0 ? base : Color.lerp(base, Neon.ink, (0.18 * i).clamp(0.0, 0.6))!;
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));

/// A modulator output as a chip: drag it onto any knob in the project for a new link, or tap it for assign mode
/// (every knob it can reach pulses; tap knobs to link or unlink, tap the chip again to end). Long-press lists every
/// other target (track volume, pan, sends, other modulators' knobs).
class ModOutputChip extends StatelessWidget {
  const ModOutputChip({super.key, required this.state, required this.source});
  final AppState state;
  final ModSourceRef source;

  Widget _chip(BuildContext context, {bool lifted = false, bool active = false}) {
    final c = modulatorColor(state, source.modulatorId);
    final m = state.project.modulator(source.modulatorId);
    final outs = m == null ? const <String>[] : state.modulatorOutputNames(m);
    final label = outs.length <= 1 ? (m?.name ?? '?') : (source.output < outs.length ? outs[source.output] : '?');
    final count = state.project.modLinks.where((l) => l.source == source.modulatorId && l.output == source.output).length;
    final on = lifted || active;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        color: c.withValues(alpha: active ? 0.4 : (on ? 0.26 : 0.1)),
        border: Border.all(color: c.withValues(alpha: on ? 0.95 : 0.5), width: active ? 2 : 1),
        boxShadow: on ? Neon.glow(c) : null,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(active ? Icons.touch_app : Icons.waves, size: 14, color: c),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: c, decoration: TextDecoration.none)),
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
  Widget build(BuildContext context) => ValueListenableBuilder<ModSourceRef?>(
    valueListenable: state.assigningModulation,
    builder: (context, a, _) => HoldDraggable<ModSourceRef>(
      key: ValueKey('modout-${source.modulatorId}-${source.output}'),
      data: source,
      delay: const Duration(milliseconds: 180),
      feedback: Material(type: MaterialType.transparency, child: _chip(context, lifted: true)),
      childWhenDragging: Opacity(opacity: 0.4, child: _chip(context)),
      onDragStarted: () {
        DeviceFeel.grab();
        state.assigningModulation.value = null;
        state.draggingModulation.value = source;
      },
      onDragEnd: (_) => state.draggingModulation.value = null,
      onDraggableCanceled: (_, _) => state.draggingModulation.value = null,
      child: Tooltip(
        message: '${PointerInput.tapCap}, then ${PointerInput.tap} any knob, or ${PointerInput.mouse ? 'drag' : 'hold and drag'} onto one: ${state.modSourceLabel(source)} moves it',
        waitDuration: const Duration(milliseconds: 700),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            DeviceFeel.tap();
            state.assigningModulation.value = a == source ? null : source;
          },
          child: Pressable(glow: modulatorColor(state, source.modulatorId), radius: 17,
            child: _chip(context, active: a == source)),
        ),
      ),
    ),
  );
}

/// Every target in the project a modulator output can reach that has no knob on screen: each track's volume, pan
/// and sends, then every device knob by track, then other modulators' knobs. Links [source] to the one picked.
Future<void> pickModTarget(BuildContext context, AppState s, ModSourceRef source, {Offset? at}) async {
  final p = s.project;
  final actions = <MenuAction<ModTarget>>[];
  void add(ModTarget t, IconData icon) {
    final why = s.whyNoLink(source, t);
    final linked = p.modLinks.any((l) => l.ref == source && l.target == t);
    actions.add(MenuAction(t, s.modTargetLabel(t), icon, checked: linked, enabled: linked || why == null, hint: linked ? null : why));
  }
  for (final l in p.layers) {
    if (l.isFolder && !l.busEnabled) continue;
    add(ModTarget.volume(l.id), Icons.volume_up);
    add(ModTarget.pan(l.id), Icons.swap_horiz);
    for (var i = 0; i < l.sends.length; i++) {
      add(ModTarget.send(l.id, i), Icons.call_split);
    }
  }
  void params(String? componentId, ModTarget Function(String param) make) {
    final info = componentId == null ? null : s.componentInfo(componentId);
    for (final prm in info?.parameters ?? const []) {
      if (!prm.modulatable || prm.isChoice || prm.id.startsWith('mod')) continue;
      add(make(prm.id), Icons.tune);
    }
  }
  for (final l in [...p.layers, masterLayerOf(p)]) {
    final layerId = isMasterLayer(l) ? null : l.id;
    if (l.instrument case final inst? when layerId != null) params(inst.id, (prm) => ModTarget.instrument(layerId, prm));
    for (var i = 0; i < l.components.length; i++) {
      params(l.components[i].id, (prm) => ModTarget.component(layerId, i, prm));
    }
  }
  for (final m in p.modulators) {
    if (m.id == source.modulatorId) continue;
    params(m.componentId, (prm) => ModTarget.modulator(m.id, prm));
  }
  final pick = await showLongPressMenu<ModTarget>(context, at: at ?? menuAnchorOf(context),
      title: '${s.modSourceLabel(source)} moves…', actions: actions);
  if (pick == null) return;
  final existing = p.modLinks.where((l) => l.ref == source && l.target == pick).firstOrNull;
  if (existing != null) {
    s.removeModLink(existing.id);
  } else if (s.addModLink(source, pick) == null && context.mounted) {
    _say(context, s.whyNoLink(source, pick) ?? 'Can\'t link that');
  }
}

/// A link's sheet: a big amount slider, polarity, curve and remove (long-press a knob's ring, or a link chip).
Future<void> showModLinkSheet(BuildContext context, AppState s, ModTarget target, {VoidCallback? onTypeValue}) =>
    showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => ValueListenableBuilder<int>(
        valueListenable: s.modulationTick,
        builder: (c, _, _) {
          final links = s.project.linksTo(target);
          return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('MODULATION · ${s.modTargetLabel(target)}', style: const TextStyle(fontSize: 11, letterSpacing: 1.2,
                fontWeight: FontWeight.w800, color: Neon.dim)),
              const SizedBox(height: 8),
              if (links.isEmpty) const Text('Nothing moves this yet: drag a modulator\'s output onto the knob.',
                style: TextStyle(fontSize: 12, color: Neon.dim)),
              for (final l in links) ModLinkCard(state: s, link: l),
              if (onTypeValue != null) Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                onPressed: () {
                  Navigator.of(c).pop();
                  onTypeValue();
                },
                icon: const Icon(Icons.keyboard, size: 16), label: const Text('Type a value'))),
            ])));
        },
      ),
    );

/// One link: its source, what it moves, a big amount slider (drag sideways, a detent at 0), polarity, curve, remove.
class ModLinkCard extends StatefulWidget {
  const ModLinkCard({super.key, required this.state, required this.link, this.showTarget = false});
  final AppState state;
  final ModLinkDoc link;
  final bool showTarget;

  @override
  State<ModLinkCard> createState() => _ModLinkCardState();
}

class _ModLinkCardState extends State<ModLinkCard> {
  @override
  Widget build(BuildContext context) {
    final s = widget.state, l = widget.link;
    final c = modulatorColor(s, l.source);
    return Container(
      key: ValueKey('modlink-${l.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: c.withValues(alpha: 0.08),
        border: Border.all(color: c.withValues(alpha: 0.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.waves, size: 14, color: c),
          const SizedBox(width: 6),
          Expanded(child: Text(widget.showTarget ? s.modTargetLabel(l.target) : s.modSourceLabel(l.ref),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c))),
          TextButton(
            key: ValueKey('modlink-polarity-${l.id}'),
            onPressed: () => s.editModLink(l.id, (x) => x.bipolar = !x.bipolar),
            child: Text(l.bipolar ? '±' : '+', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: c))),
          IconButton(
            key: ValueKey('modlink-remove-${l.id}'),
            tooltip: 'Remove this modulation',
            iconSize: 18,
            onPressed: () {
              DeviceFeel.tap();
              s.removeModLink(l.id);
            },
            icon: const Icon(Icons.close, color: Neon.dim)),
        ]),
        _LinkSlider(key: ValueKey('modlink-amount-${l.id}'), state: s, link: l, color: c,
          label: 'Amount', value: l.amount, onLive: (v) => s.setModLinkAmountLive(l.id, v)),
        _LinkSlider(key: ValueKey('modlink-curve-${l.id}'), state: s, link: l, color: c.withValues(alpha: 0.7),
          label: 'Curve', value: l.curve, onLive: (v) {
            l.curve = v;
            s.modulationTick.value++;
          }),
      ]),
    );
  }
}

/// A −1..1 slider the width of the card, with a detent at 0, that commits when the finger lifts.
class _LinkSlider extends StatelessWidget {
  const _LinkSlider({super.key, required this.state, required this.link, required this.color, required this.label,
    required this.value, required this.onLive});
  final AppState state;
  final ModLinkDoc link;
  final Color color;
  final String label;
  final double value;
  final ValueChanged<double> onLive;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final w = math.max(1.0, box.maxWidth - 8);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => DeviceFeel.grab(),
      onHorizontalDragUpdate: (d) {
        final before = value;
        var next = (before + 2 * d.delta.dx / w * DeviceFingers.fine).clamp(-1.0, 1.0);
        if (before != 0 && (next == 0 || (before > 0) != (next > 0))) {
          DeviceFeel.detent();
          if (next.abs() < 0.02) next = 0;
        }
        onLive(next);
      },
      onHorizontalDragEnd: (_) {
        DeviceFeel.release();
        state.commitModulation();
      },
      onDoubleTap: () {
        onLive(label == 'Amount' ? 0.25 : 0);
        state.commitModulation();
      },
      child: SizedBox(height: 34, child: CustomPaint(
        painter: _BipolarBar(value, color),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Neon.dim)),
          const Spacer(),
          Text('${value > 0 ? '+' : ''}${(value * 100).round()}%', style: Neon.code(size: 11, color: Neon.text)),
        ])),
      )),
    );
  });
}

class _BipolarBar extends CustomPainter {
  _BipolarBar(this.value, this.color);
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = Neon.line.withValues(alpha: 0.35));
    final mid = size.width / 2;
    final x = mid + value * mid;
    canvas.drawRect(Rect.fromLTRB(math.min(mid, x), 3, math.max(mid, x), size.height - 3),
        Paint()..color = color.withValues(alpha: 0.45));
    canvas.drawLine(Offset(mid, 2), Offset(mid, size.height - 2), Paint()..color = Neon.dim..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_BipolarBar old) => old.value != value || old.color != color;
}

/// The Modulators lane under a track's FX stack (on the master: the project's own): add one, and each as a card.
class ModulatorsSection extends StatelessWidget {
  const ModulatorsSection({super.key, required this.state, required this.layer});
  final AppState state;
  final LayerDoc layer;

  Future<void> _add(BuildContext context) async {
    final kinds = state.modulatorComponents;
    final pick = await showLongPressMenu<String>(context, at: menuAnchorOf(context), title: 'Add a modulator', actions: [
      for (final k in ModulatorKinds.builtins)
        MenuAction(k, state.componentInfo(k)?.label ?? ModulatorKinds.label(k), Icons.waves),
      for (final c in kinds)
        if (!ModulatorKinds.builtins.contains(c.id)) MenuAction(c.id, c.label, Icons.code),
    ]);
    if (pick == null) return;
    if (state.addModulator(pick, layerId: layer.id) == null && context.mounted) {
      _say(context, 'A project holds at most $kMaxModulators modulators');
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: state.modulationTick,
    builder: (context, _, _) {
      final mods = state.project.modulatorsOn(layer.id);
      return Column(key: const ValueKey('modulators-section'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 10),
        Row(children: [
          const Text('MODULATORS', style: TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: Neon.dim)),
          const SizedBox(width: 8),
          Expanded(child: Text('Drag an output onto any knob, or ${PointerInput.tap} it, then ${PointerInput.tap} knobs',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Neon.dim))),
          IconButton(
            key: const ValueKey('modulators-add'),
            tooltip: 'Add a modulator',
            iconSize: 18,
            color: Neon.violet,
            onPressed: () => _add(context),
            icon: const Icon(Icons.add_circle_outline)),
        ]),
        ValueListenableBuilder<ModSourceRef?>(
          valueListenable: state.assigningModulation,
          builder: (context, a, _) => a == null ? const SizedBox.shrink() : Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
                color: modulatorColor(state, a.modulatorId).withValues(alpha: 0.15)),
              child: Row(children: [
                Expanded(child: Text('Tap knobs for ${state.modSourceLabel(a)} to move', style: const TextStyle(fontSize: 11))),
                TextButton(key: const ValueKey('modulators-assign-done'),
                  onPressed: () => state.assigningModulation.value = null, child: const Text('Done')),
              ]),
            ),
          ),
        ),
        for (final m in mods) ModulatorCard(key: ValueKey('modulator-${m.id}'), state: state, modulator: m),
      ]);
    },
  );
}

/// One modulator: its title (bypass, its input, remove), its own controls, its outputs and what they move.
class ModulatorCard extends StatefulWidget {
  const ModulatorCard({super.key, required this.state, required this.modulator});
  final AppState state;
  final ModulatorDoc modulator;

  @override
  State<ModulatorCard> createState() => _ModulatorCardState();
}

class _ModulatorCardState extends State<ModulatorCard> {
  final _dragging = ValueNotifier<ModSource?>(null);
  final _focus = ValueNotifier<ModSource>(ModSource.none);
  final _level = ValueNotifier<List<double>>(const []);
  Timer? _poll;

  AppState get s => widget.state;
  ModulatorDoc get m => widget.modulator;

  @override
  void initState() {
    super.initState();
    // Its outputs as the engine runs them, for the live dot and meters (a few times a second is plenty here).
    if (s.engine == null) return;  // no engine (tests, no sound card): nothing to show
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final v = s.engine?.modulatorOutputs(m.id);
      if (v != null && mounted) _level.value = v;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _dragging.dispose();
    _focus.dispose();
    _level.dispose();
    super.dispose();
  }

  Future<void> _menu(BuildContext context) async {
    final pick = await showLongPressMenu<String>(context, at: menuAnchorOf(context), title: m.name, actions: [
      const MenuAction('input', 'Hears…', Icons.hearing),
      if (m.hearsAudio) MenuAction(m.post ? 'pre' : 'post', m.post ? 'Before the fader' : 'After the fader', Icons.swap_vert),
      const MenuAction('remove', 'Remove', Icons.delete_outline, danger: true),
    ]);
    if (!context.mounted || pick == null) return;
    switch (pick) {
      case 'remove':
        s.removeModulator(m.id);
      case 'pre' || 'post':
        s.editModulator(m.id, (x) => x.post = pick == 'post');
      case 'input':
        await _pickInput(context);
    }
  }

  Future<void> _pickInput(BuildContext context) async {
    final pick = await showLongPressMenu<String>(context, at: menuAnchorOf(context),
        title: m.hearsAudio ? '${m.name} follows' : '${m.name} plays from the notes of', actions: [
      MenuAction('', 'Nothing', Icons.block, checked: m.inputId == null),
      for (final l in s.project.layers)
        if (!(l.isFolder && !l.busEnabled) && (m.hearsAudio || !l.isFolder))
          MenuAction(l.id, l.name, l.isFolder ? Icons.merge_type : Icons.graphic_eq, checked: m.inputId == l.id),
    ]);
    if (pick == null) return;
    final before = m.inputId;
    s.editModulator(m.id, (x) => x.inputId = pick.isEmpty ? null : pick);
    // A follower hearing a track it moves would hear itself: put it back and say so.
    if (m.hearsAudio && pick.isNotEmpty && s.project.linksFrom(m.id).any((l) => s.project.modulationLoops(m.id, l.target))) {
      s.editModulator(m.id, (x) => x.inputId = before);
      if (context.mounted) _say(context, 'That would make a loop: ${m.name} moves that track');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = modulatorColor(s, m.id);
    final target = ModulatorDeviceTarget(s, m.id);
    final outs = s.modulatorOutputNames(m);
    final input = m.inputId == null ? null : s.layerById(m.inputId);
    final hears = m.hears == 'none' ? null : (input == null ? 'hears nothing' : '${m.hearsAudio ? 'follows' : 'notes of'} ${input.name}');
    final links = s.project.linksFrom(m.id);
    return DeviceScope(
      target: target, matrix: null, dragging: _dragging, accent: c, focusSource: _focus, inline: true,
      child: Builder(builder: (context) => DeviceExpandCard(
        storageId: 'modulator-${m.id}',
        title: m.name.toUpperCase(),
        color: c,
        initiallyOpen: true,
        dimmed: m.bypass,
        summary: [
          if ((s.componentInfo(m.componentId)?.label ?? ModulatorKinds.label(m.componentId)) case final kind
              when !m.name.startsWith(kind)) kind,
          ?hears,
        ].join(' · '),
        actions: [
          IconButton(key: ValueKey('modulator-bypass-${m.id}'), tooltip: m.bypass ? 'Turn it on' : 'Bypass',
            iconSize: 18, color: m.bypass ? Neon.dim : c,
            onPressed: () => s.setModulatorBypass(m.id, !m.bypass), icon: const Icon(Icons.power_settings_new)),
          if (m.hears != 'none') _SmallChip(key: ValueKey('modulator-input-${m.id}'), color: c,
            icon: m.hearsAudio ? Icons.graphic_eq : Icons.piano, label: input?.name ?? 'Hears nothing',
            onTap: () => _pickInput(context)),
          IconButton(key: ValueKey('modulator-menu-${m.id}'), tooltip: 'More', iconSize: 18,
            onPressed: () => _menu(context), icon: const Icon(Icons.more_horiz, color: Neon.dim)),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          _body(target, c),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (var o = 0; o < outs.length; o++) ModOutputChip(state: s, source: ModSourceRef(m.id, o)),
            _SmallChip(key: ValueKey('modulator-target-${m.id}'), color: Neon.dim, icon: Icons.add_link, label: 'Target…',
              onTap: () => pickModTarget(context, s, ModSourceRef(m.id, 0))),
          ]),
          if (links.isNotEmpty) const SizedBox(height: 6),
          for (final l in links) ModLinkCard(state: s, link: l, showTarget: true),
        ]),
      )),
    );
  }

  Widget _body(ModulatorDeviceTarget t, Color c) => switch (m.componentId) {
        ModulatorKinds.lfo => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _LfoShapeEditor(target: t, color: c, level: _level),
            const SizedBox(height: 6),
            const DeviceChoice('shape', maxSegments: 8),
            const SizedBox(height: 4),
            const Row(children: [Expanded(child: DeviceChoice('sync', maxSegments: 4)), SizedBox(width: 6), DeviceChoice('mode')]),
            KnobRow(t.value('sync') >= 0.5 ? const ['phase'] : const ['rate', 'phase'], size: 46),
          ]),
        ModulatorKinds.steps => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _StepEditor(target: t, color: c, level: _level),
            const SizedBox(height: 4),
            const DeviceChoice('sync', maxSegments: 4),
            KnobRow(t.value('sync') >= 0.5 ? const ['steps', 'glide'] : const ['steps', 'rate', 'glide'], size: 46),
          ]),
        ModulatorKinds.envelope => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _EnvelopeView(target: t, color: c, level: _level),
            const DeviceChoice('mode'),
            const KnobRow(['attack', 'decay', 'sustain', 'release'], size: 46),
          ]),
        ModulatorKinds.follower => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _LevelBar(level: _level, color: c),
            const KnobRow(['attack', 'release', 'gain'], size: 46),
          ]),
        ModulatorKinds.random => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _LevelBar(level: _level, color: c),
            const DeviceChoice('sync', maxSegments: 4),
            KnobRow(t.value('sync') >= 0.5 ? const ['smooth', 'seed'] : const ['rate', 'smooth', 'seed'], size: 46),
          ]),
        ModulatorKinds.macros => const KnobRow(['macro1', 'macro2', 'macro3', 'macro4', 'macro5', 'macro6', 'macro7', 'macro8'],
            size: 46, labels: {'macro1': 'M1', 'macro2': 'M2', 'macro3': 'M3', 'macro4': 'M4', 'macro5': 'M5', 'macro6': 'M6',
              'macro7': 'M7', 'macro8': 'M8'}),
        ModulatorKinds.midi => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _LevelBar(level: _level, color: c),
            const DeviceChoice('priority'),
            const KnobRow(['low', 'high', 'glide'], size: 46),
          ]),
        _ => const ParamGrid(),  // a user's C++ modulator: its knobs as any device's
      };
}

/// A meter of the modulator's first output (0..1) as the engine runs it.
class _LevelBar extends StatelessWidget {
  const _LevelBar({required this.level, required this.color});
  final ValueNotifier<List<double>> level;
  final Color color;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<double>>(
    valueListenable: level,
    builder: (context, v, _) => Container(
      height: 10,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: Neon.line.withValues(alpha: 0.4)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(widthFactor: (v.isEmpty ? 0.0 : v.first).clamp(0.0, 1.0),
        child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: color))),
    ),
  );
}

/// The LFO's cycle, drawn; drag on it to draw your own (it switches to Custom and sets the 16 points under the finger).
class _LfoShapeEditor extends StatelessWidget {
  const _LfoShapeEditor({required this.target, required this.color, required this.level});
  final ModulatorDeviceTarget target;
  final Color color;
  final ValueNotifier<List<double>> level;

  static const points = 16;

  double _at(double x) {
    final shape = target.value('shape').round();
    if (shape == 7) {
      final f = x * points;
      final i = f.floor().clamp(0, points - 1);
      final a = target.value('p${i + 1}'), b = target.value('p${(i + 1) % points + 1}');
      return a + (b - a) * (f - i);
    }
    return (lfoValue(shape, x, cycle: 0) + 1) / 2;
  }

  void _draw(Offset p, Size size) {
    final x = (p.dx / size.width).clamp(0.0, 0.999);
    final y = (1 - p.dy / size.height).clamp(0.0, 1.0);
    if (target.value('shape').round() != 7) {
      // Start the drawing from the shape it showed, so a touch edits it rather than replacing it.
      for (var i = 0; i < points; i++) {
        target.setLive('p${i + 1}', _at(i / points));
      }
      target.setLive('shape', 7);
    }
    target.setLive('p${(x * points).floor() + 1}', y);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final size = Size(box.maxWidth, 84);
    return GestureDetector(
      key: const ValueKey('lfo-draw'),
      onPanStart: (d) {
        DeviceFeel.grab();
        _draw(d.localPosition, size);
      },
      onPanUpdate: (d) => _draw(d.localPosition, size),
      onPanEnd: (_) {
        DeviceFeel.release();
        target.commit();
      },
      onTapUp: (d) {
        _draw(d.localPosition, size);
        target.commit();
      },
      child: ValueListenableBuilder<List<double>>(
        valueListenable: level,
        builder: (context, v, _) => CustomPaint(size: size,
          painter: _CurvePainter(_at, color, v.isEmpty ? null : v.first, custom: target.value('shape').round() == 7)),
      ),
    );
  });
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.f, this.color, this.now, {this.custom = false});
  final double Function(double x) f;
  final Color color;
  final double? now;
  final bool custom;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10));
    canvas.drawRRect(r, Paint()..color = Neon.line.withValues(alpha: 0.25));
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), Paint()..color = Neon.line..strokeWidth = 1);
    final path = Path();
    for (var i = 0; i <= 96; i++) {
      final x = i / 96;
      final y = (1 - f(x).clamp(0.0, 1.0)) * (size.height - 8) + 4;
      i == 0 ? path.moveTo(x * size.width, y) : path.lineTo(x * size.width, y);
    }
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.2..color = color);
    if (custom) {
      for (var i = 0; i < 16; i++) {
        final x = i / 16;
        canvas.drawCircle(Offset(x * size.width, (1 - f(x).clamp(0.0, 1.0)) * (size.height - 8) + 4), 2.5, Paint()..color = color);
      }
    }
    if (now != null) {
      final y = (1 - now!.clamp(0.0, 1.0)) * (size.height - 8) + 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()..color = color.withValues(alpha: 0.35)..strokeWidth = 1);
      canvas.drawCircle(Offset(size.width - 6, y), 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) =>
      paintInputsChanged([old.f, old.color, old.now, old.custom], [f, color, now, custom]);
}

/// The step sequencer's bars: drag across them to set each step's level (the steps past its length dimmed).
class _StepEditor extends StatelessWidget {
  const _StepEditor({required this.target, required this.color, required this.level});
  final ModulatorDeviceTarget target;
  final Color color;
  final ValueNotifier<List<double>> level;

  void _set(Offset p, Size size) {
    final i = (p.dx / size.width * 16).floor().clamp(0, 15);
    target.setLive('s${i + 1}', (1 - p.dy / size.height).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final size = Size(box.maxWidth, 84);
    return GestureDetector(
      key: const ValueKey('steps-draw'),
      onPanStart: (d) {
        DeviceFeel.grab();
        _set(d.localPosition, size);
      },
      onPanUpdate: (d) => _set(d.localPosition, size),
      onPanEnd: (_) => target.commit(),
      onTapUp: (d) {
        _set(d.localPosition, size);
        target.commit();
      },
      child: ValueListenableBuilder<List<double>>(
        valueListenable: level,
        builder: (context, v, _) => CustomPaint(size: size, painter: _StepsPainter(
          [for (var i = 0; i < 16; i++) target.value('s${i + 1}')], target.value('steps').round(), color,
          v.isEmpty ? null : v.first)),
      ),
    );
  });
}

class _StepsPainter extends CustomPainter {
  _StepsPainter(this.values, this.count, this.color, this.now);
  final List<double> values;
  final int count;
  final Color color;
  final double? now;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
        Paint()..color = Neon.line.withValues(alpha: 0.25));
    final w = size.width / 16;
    for (var i = 0; i < 16; i++) {
      final h = values[i].clamp(0.0, 1.0) * (size.height - 6);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * w + 2, size.height - 3 - h, w - 4, math.max(2, h)),
          const Radius.circular(3)), Paint()..color = color.withValues(alpha: i < count ? 0.75 : 0.15));
    }
    if (now != null) {
      final y = (1 - now!.clamp(0.0, 1.0)) * (size.height - 6) + 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()..color = Neon.ink.withValues(alpha: 0.4));
    }
  }

  @override
  bool shouldRepaint(covariant _StepsPainter old) =>
      paintInputsChanged([old.values, old.count, old.color, old.now], [values, count, color, now]);
}

/// The envelope's shape (attack, decay to sustain, a held part, release) with its level now.
class _EnvelopeView extends StatelessWidget {
  const _EnvelopeView({required this.target, required this.color, required this.level});
  final ModulatorDeviceTarget target;
  final Color color;
  final ValueNotifier<List<double>> level;

  @override
  Widget build(BuildContext context) {
    final a = target.value('attack'), d = target.value('decay'), sus = target.value('sustain'), r = target.value('release');
    double f(double x) {
      // Log-ish time axis: each stage gets room in proportion to the cube root of its length, a hold between.
      final ta = math.pow(a, 1 / 3).toDouble(), td = math.pow(d, 1 / 3).toDouble(), tr = math.pow(r, 1 / 3).toDouble();
      const hold = 0.6;
      final total = ta + td + hold + tr;
      final t = x * total;
      if (t < ta) return ta <= 0 ? 1 : t / ta;
      if (t < ta + td) return 1 - (1 - sus) * (t - ta) / math.max(1e-6, td);
      if (t < ta + td + hold) return sus;
      return sus * (1 - (t - ta - td - hold) / math.max(1e-6, tr));
    }
    return ValueListenableBuilder<List<double>>(
      valueListenable: level,
      builder: (context, v, _) => CustomPaint(size: const Size(double.infinity, 70),
        painter: _CurvePainter(f, color, v.isEmpty ? null : v.first)),
    );
  }
}

/// A small outlined chip in a device's colour (the input picker, Target…).
class _SmallChip extends StatelessWidget {
  const _SmallChip({super.key, required this.color, required this.icon, required this.label, required this.onTap});
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(glow: color, radius: 17, child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.45))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Neon.text)),
      ]),
    ),
  ));
}
