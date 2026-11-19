// The flagship synth's editor (`org.caw.synth.flagship`): one screen, Vital-style. Wide: oscillators on top, filters and effects in the middle, mod sources as tabs at the bottom. Phone portrait: three swipeable panels (Oscillators, Filters, Modulation).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../model/device_target.dart';
import '../../../model/mod_matrix.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import 'flagship_mod_fx.dart';
import 'flagship_panels.dart';
import 'flagship_tools.dart';

const flagshipComponentId = 'org.caw.synth.flagship';

/// Width from which the editor is one screen; narrower, the three panels.
const double flagshipWide = 700;

/// One page (owner, 2026-11-18: one cohesive screen, no accordions); the mod sources live on it.
List<DeviceSection> flagshipSections(DeviceTarget target) => [
  DeviceSection('synth', 'SYNTH', Icons.graphic_eq, (_) => const FlagshipPage(), showsSources: true, stripAtBottom: true),
];

/// Plain names for the flagship's knobs (owner, 2026-11-10: no cryptic abbreviations), by parameter id suffix.
const Map<String, String> flagshipLabels = {
  'frame': 'Position', 'warp_amt': 'Warp', 'level': 'Level', 'pan': 'Pan', 'octave': 'Octave', 'semi': 'Semitones',
  'fine': 'Fine tune', 'phase': 'Start phase', 'phase_rand': 'Random phase', 'unison': 'Voices', 'detune': 'Detune',
  'detune_power': 'Detune curve', 'spread': 'Stereo width', 'blend': 'Blend', 'cutoff': 'Cutoff',
  'resonance': 'Resonance', 'drive': 'Drive', 'keytrack': 'Key tracking', 'mix': 'Mix', 'attack': 'Attack',
  'decay': 'Decay', 'sustain': 'Sustain', 'release': 'Release',
};

/// A row of segments with an on-dot each: picks the oscillator, filter or source shown.
class DevicePicker extends StatelessWidget {
  const DevicePicker({super.key, required this.labels, required this.selected, required this.onPick, this.on,
    this.keyPrefix = 'pick', this.colors});
  final List<String> labels;
  final List<bool>? on;
  final int selected;
  final ValueChanged<int> onPick;
  final String keyPrefix;

  /// Each segment's own colour (a mod source's); the device's accent when null.
  final List<Color>? colors;

  @override
  Widget build(BuildContext context) {
    final accent = DeviceScope.of(context).accent;
    return SizedBox(height: 36, child: Row(children: [
      for (var i = 0; i < labels.length; i++)
        Expanded(child: Padding(padding: EdgeInsets.only(right: i < labels.length - 1 ? 4 : 0), child: InkWell(
          key: ValueKey('$keyPrefix-${i + 1}'),
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            Motion.tick();
            onPick(i);
          },
          child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: i == selected ? (colors?[i] ?? accent).withValues(alpha: 0.2) : Neon.ink.withValues(alpha: 0.03),
              border: Border.all(color: i == selected ? (colors?[i] ?? accent) : Neon.line),
              boxShadow: i == selected ? [BoxShadow(color: (colors?[i] ?? accent).withValues(alpha: 0.25), blurRadius: 8)] : null),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (on != null) Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(
                shape: BoxShape.circle, color: on![i] ? Neon.green : Neon.line)),
              Flexible(child: Text(labels[i], maxLines: 1, overflow: TextOverflow.clip, softWrap: false,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6,
                  color: i == selected ? Neon.text : Neon.dim))),
            ]),
          ),
        ))),
    ]));
  }
}

/// A label over a control (a choice in a section): small, dim, spaced.
class LabeledRow extends StatelessWidget {
  const LabeledRow(this.label, this.child, {super.key});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 2),
    child: Row(children: [
      // One line: a long label under a large text size shrinks to fit instead of breaking mid-word.
      SizedBox(width: 78, child: Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown,
        child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 10, letterSpacing: 0.6,
          fontWeight: FontWeight.w700, color: Neon.dim))))),
      Flexible(child: Align(alignment: Alignment.centerLeft, child: child)),
    ]),
  );
}

/// The phone's three panels, by name.
const flagshipPanels = ['Oscillators', 'Filters', 'Modulation'];

/// The flagship's editor page: a toolbar (the phone's panel dots, Init, Random patch, What's modulating? and the
/// keys), the screen (wide) or the three panels (narrow), and the keys strip when shown.
class FlagshipPage extends StatefulWidget {
  const FlagshipPage({super.key});

  @override
  State<FlagshipPage> createState() => _FlagshipPageState();
}

class _FlagshipPageState extends State<FlagshipPage> {
  final _ui = FlagshipUi();
  final _pages = PageController();
  int _panel = 0;
  bool _narrow = false;
  ValueNotifier<ModSource>? _focus;
  Timer? _flip;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final f = DeviceScope.of(context).focusSource;
    if (f != _focus) {
      _focus?.removeListener(_focused);
      _focus = f..addListener(_focused);
    }
  }

  @override
  void dispose() {
    _flip?.cancel();
    _focus?.removeListener(_focused);
    _pages.dispose();
    _ui.dispose();
    super.dispose();
  }

  // A source opened from elsewhere (assign mode's Edit, a tab): on a phone, the Modulation panel.
  void _focused() {
    if (_narrow && _panel != 2) goTo(2);
  }

  /// Shows panel [i] (a phone's); nothing when everything shows at once.
  void goTo(int i) {
    if (!_narrow || !_pages.hasClients) return;
    i = i.clamp(0, flagshipPanels.length - 1);
    final d = Motion.fade(Motion.standard * 2, Motion.of(context));
    if (d == Duration.zero) {
      _pages.jumpToPage(i);
    } else {
      _pages.animateToPage(i, duration: d, curve: Curves.easeOutCubic);
    }
  }

  // A source dragged to a side: the next panel that way, again every 700 ms while it stays there.
  void _edgeEnter(int dir) {
    _flip?.cancel();
    _flip = Timer(const Duration(milliseconds: 350), () {
      goTo(_panel + dir);
      _flip = Timer.periodic(const Duration(milliseconds: 700), (_) => goTo(_panel + dir));
    });
  }

  void _edgeLeave() {
    _flip?.cancel();
    _flip = null;
  }

  @override
  Widget build(BuildContext context) => FlagshipUiScope(ui: _ui, child: ListenableBuilder(listenable: _ui,
    builder: (context, _) => LayoutBuilder(builder: (context, box) {
      _narrow = box.maxWidth < flagshipWide;
      final accent = DeviceScope.of(context).accent;
      return Column(key: const ValueKey('flagship-synth'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: 36, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          if (_narrow) ...[
            PanelDots(count: flagshipPanels.length, index: _panel, color: accent, onPick: goTo),
            const SizedBox(width: 6),
            Flexible(child: Text(flagshipPanels[_panel].toUpperCase(), key: const ValueKey('flagship-panel-name'),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text))),
          ] else
            const Flexible(child: Text('Drag a source\'s chip onto any knob; drag a ring to set how much.', maxLines: 1,
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Neon.dim))),
          const Spacer(),
          FlagshipActions(ui: _ui),
        ]))),
        Expanded(child: _narrow ? _panels(context) : _wide(context, box.maxWidth)),
        foldSize(context, _ui.keys ? const FlagshipKeys() : const SizedBox(width: double.infinity)),
      ]);
    })));

  /// The one screen: oscillators, then filters with their switch and the effects, then the mod sources, the matrix
  /// and the voice. It scrolls where the window is short.
  Widget _wide(BuildContext context, double width) {
    final roomy = width >= 1200;
    final k = roomy ? 40.0 : 32.0;
    const gap = SizedBox(width: 8, height: 8);
    return SingleChildScrollView(key: const ValueKey('flagship-wide'), padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var o = 1; o <= 3; o++) ...[
            if (o > 1) gap,
            Expanded(child: OscPanel(o, knobSize: k, waveHeight: roomy ? 92 : 60)),
          ],
        ]),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: FilterPanel(1, knobSize: k, curveHeight: roomy ? 76 : 48)),
          const Padding(padding: EdgeInsets.only(top: 40), child: FilterRouteSwitch()),
          Expanded(flex: 5, child: FilterPanel(2, knobSize: k, curveHeight: roomy ? 76 : 48)),
          gap,
          const Expanded(flex: 4, child: FlagshipFxRack()),
        ]),
        gap,
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Expanded(flex: 5, child: FPanel(title: 'MODULATION', child: ModSourceTabs(wide: true))),
          gap,
          Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FPanel(title: 'MATRIX', child: FlagshipMatrixList()),
            gap,
            VoicePanel(knobSize: k - 2),
          ])),
        ]),
      ]));
  }

  /// The phone's three panels, swiped sideways; a source dragged to either side goes to the next panel.
  Widget _panels(BuildContext context) {
    final scope = DeviceScope.of(context);
    Widget panel(String key, List<Widget> children) => ListView(key: ValueKey(key),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: c)]);
    Widget edge(int dir) => Positioned(top: 0, bottom: 0, left: dir < 0 ? 0 : null, right: dir > 0 ? 0 : null, width: 28,
      child: DragTarget<ModSource>(
        key: ValueKey('flagship-edge-${dir < 0 ? 'left' : 'right'}'),
        onWillAcceptWithDetails: (_) {
          _edgeEnter(dir);
          return false;
        },
        onLeave: (_) => _edgeLeave(),
        builder: (context, _, _) => ValueListenableBuilder<ModSource?>(valueListenable: scope.dragging,
          builder: (context, src, _) {
            final can = src != null && (dir < 0 ? _panel > 0 : _panel < flagshipPanels.length - 1);
            final c = src == null ? Neon.dim : modSourceColor(src);
            return IgnorePointer(child: AnimatedOpacity(duration: Motion.fade(Motion.small, Motion.of(context)),
              opacity: can ? 1 : 0, child: DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(
                  begin: dir < 0 ? Alignment.centerLeft : Alignment.centerRight,
                  end: dir < 0 ? Alignment.centerRight : Alignment.centerLeft,
                  colors: [c.withValues(alpha: 0.35), c.withValues(alpha: 0)])),
                child: Icon(dir < 0 ? Icons.chevron_left : Icons.chevron_right, color: c))));
          }),
      ));
    return Stack(children: [
      PageView(
        key: const ValueKey('flagship-pages'),
        controller: _pages,
        onPageChanged: (i) {
          Motion.tick();
          setState(() => _panel = i);
        },
        children: [
          panel('flagship-panel-osc', [for (var o = 1; o <= 3; o++) OscPanel(o), const VoicePanel()]),
          panel('flagship-panel-filters', [const FilterPanel(1), const FilterRouteSwitch(vertical: false),
            const FilterPanel(2), const FlagshipFxRack()]),
          panel('flagship-panel-mod', [
            const FPanel(title: 'MODULATION', child: ModSourceTabs()),
            FPanel(title: 'MATRIX', child: FlagshipMatrixList(onLocate: (id) => goTo(flagshipPanelOf(id)))),
          ]),
        ],
      ),
      edge(-1),
      edge(1),
    ]);
  }
}

