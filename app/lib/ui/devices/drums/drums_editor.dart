// The drums' editor (org.caw.drums): PADS (the 4×4 grid, then the picked pad's hero, Character strip and layer cards in place) and KIT (MIDI, note map, kit effects, explode); and its inline view in the FX stack.
import 'package:flutter/material.dart';

import '../../../model/drums.dart';
import '../kit/param_watch.dart';
import '../device_registry.dart';
import '../device_scope.dart';
import '../kit/device_style.dart';
import 'drums_hero.dart';
import 'drums_kit.dart';
import 'drums_pads.dart';
import 'drums_voice.dart';

/// The drums' editor entry.
final Map<String, DeviceEditorEntry> drumEditors = {
  drumsComponentId: DeviceEditorEntry(
    (_) => [
      DeviceSection('pads', 'PADS', Icons.grid_view_rounded, (_) => const DrumsPadsPage()),
      DeviceSection('kit', 'KIT', Icons.tune, (_) => const DrumsKitPage()),
    ],
    family: DeviceFamily.drums,
    inline: (_) => const DrumsInline(),
  ),
};

/// Width from which the grid and the voice sit side by side.
const double drumsWide = 820;

/// The PADS page: the bank bar and grid, then the picked pad's voice and its layer cards. Only the cards on screen
/// are built (a lazy list), so a pad's 162 knobs cost what is visible.
class DrumsPadsPage extends StatelessWidget {
  const DrumsPadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = DeviceScope.of(context).target;
    final layout = drumsLayout(t);
    final sel = DrumsSelection.of(t);
    final cards = [for (final id in drumCardOrder) ?layout.byId[id]];
    return DrumLearn(child: LayoutBuilder(builder: (context, box) => ValueListenableBuilder<int>(
      valueListenable: sel.pad,
      builder: (context, pad, _) {
        Widget card(int i) => DrumLayerCard(key: ValueKey('drum-card-${cards[i].id}'), pad: pad, layer: cards[i]);
        if (box.maxWidth >= drumsWide) {
          return Row(key: const ValueKey('drums-pads'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 400, child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 4, 24), children: [
              const DrumBankBar(),
              const SizedBox(height: 6),
              DrumPadGrid(padHeight: box.maxHeight < 520 ? 50 : 76),
              const SizedBox(height: 10),
              DrumVoiceTop(pad: pad),
            ])),
            Expanded(child: ListView.builder(
              key: const ValueKey('drum-cards'),
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 32),
              itemCount: cards.length,
              itemBuilder: (context, i) => card(i))),
          ]);
        }
        return CustomScrollView(key: const ValueKey('drums-pads'), slivers: [
          SliverPadding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 0), sliver: SliverToBoxAdapter(child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const DrumBankBar(),
              const SizedBox(height: 6),
              DrumPadGrid(padHeight: box.maxWidth > box.maxHeight * 1.4 ? 52 : 64),
              const SizedBox(height: 8),
              DrumVoiceTop(pad: pad),
            ]))),
          SliverPadding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 32), sliver: SliverList.builder(
            key: const ValueKey('drum-cards'),
            itemCount: cards.length,
            itemBuilder: (context, i) => card(i))),
        ]);
      },
    )));
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
