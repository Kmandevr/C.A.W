// The flagship synth's modulation and effects: the mod sources as tabs (the open one drawn big, its ⊕ chip to drag onto knobs), the compact matrix list, and the effects rack.
import 'package:flutter/material.dart';

import '../../../model/mod_matrix.dart';
import '../../motion.dart';
import '../../pointer_input.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../kit/device_style.dart';
import '../kit/feel.dart';
import '../kit/param_watch.dart';
import '../visuals/envelope_view.dart';
import '../visuals/fx_visuals.dart';
import '../visuals/lfo_view.dart';
import '../visuals/mod_routing.dart';
import '../visuals/mod_sheet.dart';
import 'flagship_editor.dart' show LabeledRow;
import 'flagship_panels.dart';
import 'flagship_tools.dart';

/// What each note-driven source means, for the NOTE tab.
const Map<ModSource, String> _noteSourceNotes = {
  ModSource.velocity: 'How hard each note is played.',
  ModSource.note: 'The note\'s pitch: higher notes, more.',
  ModSource.bend: 'The note\'s own pitch bend, over the bend range.',
  ModSource.pressure: 'Pressure (aftertouch) on each note.',
  ModSource.timbre: 'Each note\'s timbre (MPE slide).',
  ModSource.modWheel: 'The mod wheel (controller 1) of a connected keyboard.',
};

/// The sources with a shape of their own, each a tab; the note's own sources share the NOTE tab.
const List<ModSource> shapedSources = [
  ModSource.env1, ModSource.env2, ModSource.env3, ModSource.lfo1, ModSource.lfo2, ModSource.lfo3, ModSource.random,
];

/// The mod sources as tabs (ENV 1 · AMP, ENV 2, ENV 3, LFO 1–3, RANDOM, NOTE), each with its colour and how many
/// knobs it moves; the open one drawn big under them. The open tab is the editor's focused source, so a source
/// opened from the strip (assign mode's Edit) opens here.
class ModSourceTabs extends StatelessWidget {
  const ModSourceTabs({super.key, this.wide = false});

  /// The open source's drawing beside its controls instead of above them.
  final bool wide;

  static String _tabLabel(ModSource s) => s == ModSource.env1 ? 'ENV 1 · AMP' : s.short == 'RND' ? 'RANDOM' : s.short;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final routes = scope.matrix?.routes ?? const <ModRoute>[];
    return ValueListenableBuilder<ModSource>(valueListenable: scope.focusSource, builder: (context, focus, _) {
      final noteOpen = !shapedSources.contains(focus);
      Widget tab(String key, String label, Color c, bool selected, int count, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(9),
          onTap: () {
            Motion.tick();
            onTap();
          },
          child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(9),
              color: selected ? c.withValues(alpha: 0.22) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: selected ? c : Neon.line),
              boxShadow: selected ? [BoxShadow(color: c.withValues(alpha: 0.25), blurRadius: 8)] : null),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5,
                color: selected ? Neon.text : Neon.dim)),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Text('$count', style: Neon.code(size: 9, color: c).copyWith(fontWeight: FontWeight.w800)),
              ],
            ]),
          ),
        ),
      );
      return Column(key: const ValueKey('flagship-sources'), crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min, children: [
          // Every tab in sight: they wrap onto a second row rather than scroll out of view.
          Wrap(runSpacing: 4, children: [
            for (final s in shapedSources)
              tab('fsrc-tab-${s.name}', _tabLabel(s), modSourceColor(s), s == focus,
                routes.where((r) => r.source == s).length, () => scope.focusSource.value = s),
            tab('fsrc-tab-note', 'NOTE', Neon.yellow, noteOpen,
              routes.where((r) => !shapedSources.contains(r.source)).length,
              () => scope.focusSource.value = ModSource.velocity),
          ]),
          const SizedBox(height: 8),
          AnimatedSwitcher(duration: Motion.fade(Motion.standard, Motion.of(context)),
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: noteOpen
                ? const _NoteSources(key: ValueKey('source-note'))
                : watchDevice(context, (_) => SourceBody(focus, key: ValueKey('source-${focus.name}'), wide: wide))),
        ]);
    });
  }
}

/// The note's own sources: each chip (drag it onto a knob) with what it follows.
class _NoteSources extends StatelessWidget {
  const _NoteSources({super.key});

  @override
  Widget build(BuildContext context) {
    final routes = DeviceScope.of(context).matrix?.routes ?? const <ModRoute>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      for (final e in _noteSourceNotes.entries) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
        SizedBox(width: 92, child: Align(alignment: Alignment.centerLeft, child: ModSourceChip(e.key,
          count: routes.where((r) => r.source == e.key).length))),
        const SizedBox(width: 8),
        Expanded(child: Text(e.value, style: const TextStyle(fontSize: 11, color: Neon.dim))),
      ])),
    ]);
  }
}

/// A mod source's own controls: an envelope's shape (drag its handles) and times, an LFO's shape (drag sideways
/// for the rate), shape, sync and mode, random's rate; a note source says what it follows. Its chip (the ⊕ handle:
/// drag it onto a knob, or tap for assign mode) sits on top. [wide] puts the drawing beside the controls.
class SourceBody extends StatelessWidget {
  const SourceBody(this.source, {super.key, this.compact = false, this.wide = false});
  final ModSource source;
  final bool compact, wide;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final c = modSourceColor(source);
    final bpm = scope.target.state.project.bpm;
    final count = scope.matrix?.routes.where((r) => r.source == source).length ?? 0;
    final chipRow = Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
      ModSourceChip(source, selected: true, count: count),
      const SizedBox(width: 8),
      Expanded(child: Text('Drag onto a knob, or ${PointerInput.tap} it, then knobs', maxLines: 2,
        style: const TextStyle(fontSize: 10, color: Neon.dim))),
    ]));
    final big = wide ? 96.0 : (compact ? 84.0 : 110.0);
    final Widget visual;
    final List<Widget> controls;
    switch (source) {
      case ModSource.env1 || ModSource.env2 || ModSource.env3:
        final p = 'env${source.index - ModSource.env1.index + 1}_';
        visual = EnvelopeView(prefix: p, color: c, height: big);
        controls = [
          FKnobRow(['${p}attack', '${p}decay', '${p}sustain', '${p}release'], color: c, size: compact ? 46 : 40),
          if (source == ModSource.env1) const Padding(padding: EdgeInsets.only(top: 4), child: Text(
            'Env 1 shapes each note\'s level.', style: TextStyle(fontSize: 9, color: Neon.dim))),
        ];
      case ModSource.lfo1 || ModSource.lfo2 || ModSource.lfo3:
        final p = 'lfo${source.index - ModSource.lfo1.index + 1}_';
        final synced = scope.target.value('${p}sync') >= 1;
        visual = LfoView(rateParam: '${p}rate', shapeParam: '${p}shape', syncParam: '${p}sync', bpm: bpm, color: c,
          height: wide ? big : (compact ? 64 : 84));
        controls = [
          LabeledRow('SHAPE', DeviceChoice('${p}shape', maxSegments: 0, color: c)),
          LabeledRow('TEMPO SYNC', DeviceChoice('${p}sync', maxSegments: 0, color: c)),
          LabeledRow('RESTARTS', DeviceChoice('${p}mode', color: c)),
          if (!synced) FKnobRow(['${p}rate'], size: compact ? 46 : 40, color: c, labels: {'${p}rate': 'Rate'}),
        ];
      case ModSource.random:
        visual = LfoView(rateParam: 'rnd_rate', randomModeParam: 'rnd_mode', bpm: bpm, color: c,
          height: wide ? big : (compact ? 64 : 84));
        controls = [
          LabeledRow('STEPS', DeviceChoice('rnd_mode', color: c)),
          FKnobRow(const ['rnd_rate'], size: compact ? 46 : 40, color: c, labels: const {'rnd_rate': 'Rate'}),
        ];
      default:
        visual = Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
          _noteSourceNotes[source] ?? '', style: const TextStyle(fontSize: 11, color: Neon.dim)));
        controls = const [];
    }
    if (wide) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        chipRow,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: visual),
          const SizedBox(width: 10),
          Expanded(flex: 4, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
            children: controls)),
        ]),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [chipRow, visual, ...controls]);
  }
}

/// Which of the phone's panels holds knob [paramId]: 0 oscillators (and the voice), 1 filters and effects,
/// 2 modulation.
int flagshipPanelOf(String paramId) {
  if (paramId.startsWith('flt') || paramId.startsWith('fx_')) return 1;
  if (RegExp(r'^(env|lfo|rnd)').hasMatch(paramId)) return 2;
  return 0;
}

/// The mod matrix as a compact list: a row per route (source, the knob it moves, its amount as a slim slider,
/// polarity, "show it", remove) and + to add one. A tap on the knob's name opens its Modulation sheet (every route
/// on it, Scaled by); the target shows which knob it is, lit, and goes to its panel on a phone.
class FlagshipMatrixList extends StatelessWidget {
  const FlagshipMatrixList({super.key, this.onLocate});

  /// Goes to the panel holding a knob (the phone's panels); null when everything shows at once.
  final ValueChanged<String>? onLocate;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final m = scope.matrix;
    if (m == null) return const SizedBox.shrink();
    final routes = m.routes;
    return ValueListenableBuilder<ModSource>(valueListenable: scope.focusSource, builder: (context, focus, _) {
      final add = shapedSources.contains(focus) || _noteSourceNotes.containsKey(focus) ? focus : ModSource.lfo1;
      return Column(key: const ValueKey('flagship-matrix'), crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min, children: [
          SizedBox(height: 34, child: Row(children: [
            Expanded(child: Text('${routes.length} of ${m.slotCount} slots', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: Neon.dim))),
            TextButton.icon(
              key: const ValueKey('fmatrix-add'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: modSourceColor(add)),
              onPressed: m.freeSlot == null ? null : () async {
                final dst = await pickModDestination(context, m);
                if (dst != null) {
                  final slot = m.add(add, dst);
                  if (slot != null) scope.selectedSlot?.value = slot;
                }
              },
              icon: const Icon(Icons.add, size: 16),
              label: Text('${add.short} to a knob', maxLines: 1, style: const TextStyle(fontSize: 11))),
          ])),
          if (routes.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(
              'Nothing modulated yet. Drag a source\'s chip onto a knob, or ${PointerInput.tap} a chip, then knobs.',
              style: const TextStyle(fontSize: 11, color: Neon.dim))),
          for (final r in routes) _MatrixRow(route: r, matrix: m, onLocate: onLocate),
        ]);
    });
  }
}

class _MatrixRow extends StatelessWidget {
  const _MatrixRow({required this.route, required this.matrix, this.onLocate});
  final ModRoute route;
  final ModMatrix matrix;
  final ValueChanged<String>? onLocate;

  @override
  Widget build(BuildContext context) {
    final r = route, m = matrix;
    final c = modSourceColor(r.source);
    final dst = m.target.param(r.paramId);
    final ui = FlagshipUi.maybeOf(context);
    final located = ui != null && ui.whoMods && ui.only == r.paramId;
    Widget small(String key, String tip, Widget icon, VoidCallback onTap, {Color? color}) => IconButton(
      key: ValueKey(key), tooltip: tip, iconSize: 16, padding: EdgeInsets.zero, color: color ?? Neon.dim,
      visualDensity: VisualDensity.compact,
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 34),
      onPressed: () {
        DeviceFeel.tap();
        onTap();
      },
      icon: icon);
    return Container(
      key: ValueKey('fmatrix-${r.slot}'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 4),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: c.withValues(alpha: 0.06),
        border: Border.all(color: c.withValues(alpha: 0.3))),
      child: SizedBox(height: 38, child: Row(children: [
        Container(width: 48, height: 22, alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: c.withValues(alpha: 0.2),
            border: Border.all(color: c)),
          child: Text(r.source.short, maxLines: 1, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: c))),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 2), child: Icon(Icons.arrow_forward, size: 12, color: Neon.dim)),
        Expanded(flex: 5, child: InkWell(
          key: ValueKey('fmatrix-dst-${r.slot}'),
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            DeviceScope.maybeSelect(context, r.slot);
            showModulationSheet(context, r.paramId);
          },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8), child: Text(
            dst?.label ?? r.paramId, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Neon.text))),
        )),
        Expanded(flex: 6, child: ModAmountSlider(key: ValueKey('fmatrix-amount-${r.slot}'), route: r, matrix: m, height: 30)),
        small('fmatrix-polarity-${r.slot}', r.bipolar ? 'Both ways: tap for one way' : 'One way: tap for both ways',
          Text(r.bipolar ? '±' : '+', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: c)),
          () => m.setBipolar(r.slot, !r.bipolar)),
        if (ui != null) small('fmatrix-locate-${r.slot}', 'Show this knob', Icon(located ? Icons.visibility : Icons.my_location),
          () {
            ui.showSources(r.paramId);
            if (ui.whoMods) onLocate?.call(r.paramId);
          }, color: located ? c : null),
        small('fmatrix-remove-${r.slot}', 'Remove this modulation', const Icon(Icons.close), () => m.remove(r.slot)),
      ])),
    );
  }
}

/// The effects rack, in the engine's order (distortion, EQ, chorus, delay, reverb): a tab per effect with its on
/// light, the picked one's power, drawing and knobs under them.
class FlagshipFxRack extends StatefulWidget {
  const FlagshipFxRack({super.key});

  @override
  State<FlagshipFxRack> createState() => _FlagshipFxRackState();
}

class _FlagshipFxRackState extends State<FlagshipFxRack> {
  static const _ids = ['dist', 'eq', 'chorus', 'delay', 'reverb'];
  static const _names = ['DRIVE', 'EQ', 'CHORUS', 'DELAY', 'REVERB'];
  static const _delayWholes = [0.0, 0.0625, 0.125, 0.1875, 0.25, 0.375, 0.5, 1.0];
  int? _picked;

  @override
  Widget build(BuildContext context) => watchDevice(context, _body);

  Widget _body(BuildContext context) {
    final t = DeviceScope.of(context).target;
    double v(String id) => t.value(id);
    bool on(String id) => v(id) >= 0.5;
    // The first effect that is on to start with.
    final picked = _picked ??= () {
      final i = _ids.indexWhere((id) => on('fx_${id}_on'));
      return i < 0 ? 0 : i;
    }();
    final drive = deviceStyle(DeviceFamily.drive).primary, eq = deviceStyle(DeviceFamily.eq).primary;
    final mod = deviceStyle(DeviceFamily.modulation).primary, space = deviceStyle(DeviceFamily.space);
    final colors = [drive, eq, mod, space.secondary, space.primary];
    final id = _ids[picked], c = colors[picked];
    final bpm = t.state.project.bpm;
    final Widget body;
    switch (id) {
      case 'dist':
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(alignment: Alignment.centerLeft, child: DeviceChoice('fx_dist_type', color: c)),
          const SizedBox(height: 4),
          SaturationCurve(type: v('fx_dist_type').round(), drive: v('fx_dist_drive'), mix: v('fx_dist_mix'), height: 60, color: c),
          FKnobRow(const ['fx_dist_drive', 'fx_dist_mix'], color: c, size: 38,
            labels: const {'fx_dist_drive': 'Drive', 'fx_dist_mix': 'Mix'}),
        ]);
      case 'eq':
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EqCurve(color: c, height: 72, bands: const [
            EqBand(kind: EqKind.lowShelf, fixedFreq: 250, gainParam: 'fx_eq_low', label: 'LOW'),
            EqBand(kind: EqKind.peak, freqParam: 'fx_eq_mid_freq', gainParam: 'fx_eq_mid', label: 'MID'),
            EqBand(kind: EqKind.highShelf, fixedFreq: 4000, gainParam: 'fx_eq_high', label: 'HIGH'),
          ]),
          FKnobRow(const ['fx_eq_low', 'fx_eq_mid', 'fx_eq_mid_freq', 'fx_eq_high', 'fx_eq_mix'], color: c, size: 36,
            labels: const {'fx_eq_low': 'Low', 'fx_eq_mid': 'Mid', 'fx_eq_mid_freq': 'Freq', 'fx_eq_high': 'High', 'fx_eq_mix': 'Mix'}),
        ]);
      case 'chorus':
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LfoView(rateParam: 'fx_chorus_rate', height: 56, bpm: bpm, color: c),
          FKnobRow(const ['fx_chorus_rate', 'fx_chorus_depth', 'fx_chorus_mix'], color: c, size: 38,
            labels: const {'fx_chorus_rate': 'Rate', 'fx_chorus_depth': 'Depth', 'fx_chorus_mix': 'Mix'}),
        ]);
      case 'delay':
        final sync = v('fx_delay_sync').round().clamp(0, _delayWholes.length - 1);
        final seconds = sync == 0 ? v('fx_delay_time') : _delayWholes[sync] * 4 * 60 / bpm;
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [fLabel('SYNC'), Flexible(child: DeviceChoice('fx_delay_sync', maxSegments: 0, color: c))]),
          DelayEchoes(seconds: seconds, feedback: v('fx_delay_feedback'), mix: v('fx_delay_mix'), color: c, height: 56),
          FKnobRow([if (sync == 0) 'fx_delay_time', 'fx_delay_feedback', 'fx_delay_mix'], color: c, size: 38,
            labels: const {'fx_delay_time': 'Time', 'fx_delay_feedback': 'Feedback', 'fx_delay_mix': 'Mix'}),
        ]);
      default:
        body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ReverbTail(decaySeconds: v('fx_reverb_decay'), size: v('fx_reverb_size'), damping: v('fx_reverb_damping'),
            mix: v('fx_reverb_mix'), height: 56, color: c),
          FKnobRow(const ['fx_reverb_size', 'fx_reverb_decay', 'fx_reverb_damping', 'fx_reverb_mix'], color: c, size: 38,
            labels: const {'fx_reverb_size': 'Size', 'fx_reverb_decay': 'Decay', 'fx_reverb_damping': 'Damping',
              'fx_reverb_mix': 'Mix'}),
          if (!on('fx_reverb_on')) const Text('Off by default: a reverb on every track costs about two voices.',
            style: TextStyle(fontSize: 9, color: Neon.dim)),
        ]);
    }
    return FPanel(
      key: const ValueKey('flagship-fx'),
      title: 'EFFECTS',
      color: c,
      trailing: [DevicePower('fx_${id}_on', color: c)],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 30, child: Row(children: [
          for (var i = 0; i < _ids.length; i++) Expanded(child: Padding(
            padding: EdgeInsets.only(right: i < _ids.length - 1 ? 3 : 0),
            child: InkWell(
              key: ValueKey('ffx-tab-${_ids[i]}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                Motion.tick();
                setState(() => _picked = i);
              },
              child: AnimatedContainer(
                duration: Motion.fade(Motion.small, Motion.of(context)),
                alignment: Alignment.center,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                  color: i == picked ? colors[i].withValues(alpha: 0.2) : Colors.transparent,
                  border: Border.all(color: i == picked ? colors[i] : Neon.line)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle,
                    color: on('fx_${_ids[i]}_on') ? colors[i] : Neon.line)),
                  const SizedBox(width: 3),
                  // A narrow rack shrinks the names to fit whole rather than cutting them.
                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(_names[i], maxLines: 1, softWrap: false,
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.3,
                      color: i == picked ? Neon.text : Neon.dim)))),
                ]),
              ),
            ),
          )),
        ])),
        const SizedBox(height: 6),
        AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)), opacity: on('fx_${id}_on') ? 1 : 0.55,
          child: KeyedSubtree(key: ValueKey('ffx-body-$id'), child: body)),
      ]),
    );
  }
}
