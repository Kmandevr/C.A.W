// The drums' editor (org.caw.drums) in the instruments' one-screen layout: the pads on top (lit by their hits), the picked pad's cards below in three panels (Sound, Shape, Groove & kit; a phone swipes between them, wide shows them side by side), and the Character and source strip at the bottom; and its inline view in the FX stack.
import 'package:flutter/material.dart';

import '../../../model/drums.dart';
import '../../motion.dart';
import '../../theme.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../flagship/flagship_tools.dart' show PanelDots;
import '../kit/device_style.dart';
import '../kit/param_watch.dart';
import 'drums_cards.dart';
import 'drums_hero.dart';
import 'drums_kit.dart';
import 'drums_pads.dart';
import 'drums_voice.dart';

/// The drums' editor entry: one page (owner, 2026-11-19: Kestrel's one-screen layout for every instrument).
final Map<String, DeviceEditorEntry> drumEditors = {
  drumsComponentId: DeviceEditorEntry(
    (_) => [DeviceSection('drums', 'DRUMS', Icons.grid_view_rounded, (_) => const DrumsPage())],
    family: DeviceFamily.drums,
    inline: (_) => const DrumsInline(),
  ),
};

/// Width from which the three panels sit side by side under the pads.
const double drumsWide = 820;

/// The three panels, by name (a phone's swipes).
const drumsPanels = ['Sound', 'Shape', 'Groove & kit'];

/// The panel a card is in.
int drumsPanelOf(String card) =>
    drumSoundCards.contains(card) ? 0 : (drumShapeCards.contains(card) ? 1 : 2);

/// The page: the pads and the picked pad's header (with its hero beside them when wide), the panels, the strip.
class DrumsPage extends StatefulWidget {
  const DrumsPage({super.key});

  @override
  State<DrumsPage> createState() => DrumsPageState();
}

class DrumsPageState extends State<DrumsPage> {
  final _pages = PageController();
  int _panel = 0;
  bool _narrow = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Shows panel [i] (a phone's); nothing when all three show.
  void goTo(int i) {
    if (!_narrow || !_pages.hasClients) return;
    i = i.clamp(0, drumsPanels.length - 1);
    final d = Motion.fade(Motion.standard * 2, Motion.of(context));
    if (d == Duration.zero) {
      _pages.jumpToPage(i);
    } else {
      _pages.animateToPage(i, duration: d, curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final sel = DrumsSelection.of(t);
    return DrumLearn(child: LayoutBuilder(builder: (context, box) {
      final flat = box.maxHeight < 460 && box.maxWidth > box.maxHeight;  // a phone on its side
      _narrow = box.maxWidth < drumsWide || flat;
      final short = box.maxHeight < 560;
      final accent = DeviceScope.of(context).accent;
      void source(String card) {
        if (_narrow) goTo(drumsPanelOf(card));
      }
      Widget dots() => SizedBox(height: 30, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
        PanelDots(count: drumsPanels.length, index: _panel, color: accent, onPick: goTo),
        const SizedBox(width: 6),
        Text(drumsPanels[_panel].toUpperCase(), key: const ValueKey('drums-panel-name'),
          style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Neon.text)),
      ])));
      if (flat) {  // the pads, the pad's header and the strip on the left; the panels swipe on the right
        return ValueListenableBuilder<int>(valueListenable: sel.pad, builder: (context, pad, _) => Row(
          key: const ValueKey('drums-page'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: 330, child: ListView(padding: const EdgeInsets.fromLTRB(8, 6, 4, 8), children: [
              const DrumBankBar(),
              const SizedBox(height: 4),
              const DrumPadGrid(padHeight: 40, gap: 4),
              DrumVoiceHeader(pad: pad),
              DrumSourceStrip(pad: pad, onSource: source),
            ])),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              dots(),
              Expanded(child: _panels(context, pad)),
            ])),
          ]));
      }
      return ValueListenableBuilder<int>(valueListenable: sel.pad, builder: (context, pad, _) => Column(
        key: const ValueKey('drums-page'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // The centrepiece: the pads, lit by their hits.
          Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 0), child: _narrow
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const DrumBankBar(),
                  const SizedBox(height: 4),
                  DrumPadGrid(padHeight: short ? 30 : 40, gap: 4),
                  DrumVoiceHeader(pad: pad),
                ])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const DrumBankBar(),
                    const SizedBox(height: 4),
                    DrumPadGrid(padHeight: short ? 46 : 58, gap: 5),
                  ])),
                  const SizedBox(width: 10),
                  Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    DrumVoiceHeader(pad: pad),
                    watchDevice(context, (_) => DrumHero(pad: pad, height: short ? 120 : 196)),
                  ])),
                ])),
          if (_narrow) dots(),
          Expanded(child: _narrow ? _panels(context, pad) : _wide(context, pad)),
          DrumSourceStrip(pad: pad, onSource: source),
        ]));
    }));
  }

  List<Widget> _cards(BuildContext context, int pad, int panel) => switch (panel) {
    0 => [
      if (_narrow) watchDevice(context, (_) => DrumHero(pad: pad, height: 120)),
      for (final c in drumSoundCards) DrumCard(pad: pad, layer: c),
    ],
    1 => [for (final c in drumShapeCards) DrumCard(pad: pad, layer: c)],
    _ => [for (final c in drumGrooveCards) DrumCard(pad: pad, layer: c), ...drumKitCards(context)],
  };

  Widget _list(String key, List<Widget> children) => ListView.builder(
    key: ValueKey(key),
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
    itemCount: children.length,
    itemBuilder: (context, i) => Padding(padding: const EdgeInsets.only(bottom: 8), child: children[i]));

  static const _keys = ['drums-panel-sound', 'drums-panel-shape', 'drums-panel-groove'];

  Widget _panels(BuildContext context, int pad) => PageView(
    key: const ValueKey('drums-pages'),
    controller: _pages,
    onPageChanged: (i) {
      Motion.tick();
      setState(() => _panel = i);
    },
    children: [for (var i = 0; i < 3; i++) _list(_keys[i], _cards(context, pad, i))],
  );

  Widget _wide(BuildContext context, int pad) => Row(key: const ValueKey('drums-wide'), crossAxisAlignment: CrossAxisAlignment.start,
    children: [for (var i = 0; i < 3; i++) Expanded(child: _list(_keys[i], _cards(context, pad, i)))]);
}

/// The strip at the bottom: the picked pad's Character macros (its own mod sources: each moves many settings at
/// once) and chips for the per-hit sources (velocity, pressure, random, groove) that open their cards.
class DrumSourceStrip extends StatelessWidget {
  const DrumSourceStrip({super.key, required this.pad, this.onSource});
  final int pad;
  final ValueChanged<String>? onSource;

  static const sources = [('var', 'Velocity', Icons.speed), ('press', 'Pressure', Icons.touch_app_outlined),
    ('var', 'Random', Icons.casino_outlined), ('groove', 'Groove', Icons.timeline)];

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    return DecoratedBox(
      key: const ValueKey('drums-strip'),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Neon.ink.withValues(alpha: 0.08)))),
      child: Padding(padding: const EdgeInsets.fromLTRB(6, 2, 6, 2), child: Row(children: [
        Expanded(child: DrumCharacterStrip(pad: pad, size: 30)),
        const SizedBox(width: 4),
        Wrap(direction: Axis.vertical, spacing: 2, children: [
          for (final (card, name, icon) in sources)
            InkWell(
              key: ValueKey('drum-source-${name.toLowerCase()}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSource?.call(card),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 12, color: Neon.violet),
                const SizedBox(width: 3),
                Text(name, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: scope.accent == Neon.violet ? Neon.text : Neon.dim)),
              ]))),
        ]),
      ])),
    );
  }
}

/// The drums inline in the FX stack: the bank bar and a compact grid, then the picked pad's hero and Character.
class DrumsInline extends StatelessWidget {
  const DrumsInline({super.key});

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final sel = DrumsSelection.of(t);
    return DrumLearn(child: Padding(
      key: const ValueKey('drums-inline'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const DrumBankBar(),
        const SizedBox(height: 6),
        const DrumPadGrid(padHeight: 44, gap: 5),
        const SizedBox(height: 8),
        ValueListenableBuilder<int>(valueListenable: sel.pad, builder: (context, pad, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            DrumVoiceHeader(pad: pad),
            watchDevice(context, (_) => DrumHero(pad: pad, height: 160)), // its own watch (param_watch.dart)
            DrumCharacterStrip(pad: pad, size: 34),
          ])),
      ]),
    ));
  }
}
