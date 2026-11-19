// The drums' kit cards: mode and MIDI (channel, first note, volume, variation seed), the note map of a bank with Learn, the kit effects (glue, drive, room, echo, EQ, clip) and Explode to tracks.
import 'package:flutter/material.dart';

import '../../../model/drums.dart';
import '../../feedback.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../flagship/flagship_editor.dart' show LabeledRow;
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../flagship/flagship_panels.dart' show FPanel;
import 'drums_cards.dart';
import 'drums_pads.dart';
import 'drums_voice.dart';

/// The kit's cards (the third panel's lower half): mode and MIDI, the note map, glue, drive, room, echo, EQ, clip and
/// Explode, each with its picture.
List<Widget> drumKitCards(BuildContext context) {
  final scope = DeviceScope.of(context);
  final t = scope.target;
  final layout = drumsLayout(t);
  final c = scope.accent, c2 = scope.secondary;
  List<String> group(String g) => layout.kitGroups[g] ?? const [];
  return [
    FPanel(key: const ValueKey('drum-kit-midi'), title: 'MODE & MIDI', color: c, child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const LabeledRow('MODE', DeviceChoice('mode', labels: ['Kit · pads on notes', 'Single · A1 plays all'])),
        const LabeledRow('CHANNEL', DeviceChoice('channel', maxSegments: 0)),
        KnobRow(const ['base_note', 'volume', 'seed'], size: 40,
          labels: {'base_note': 'First note', 'volume': 'Volume', 'seed': 'Variation seed'}),
      ])),
    DrumNoteMapCard(layout: layout),
    DrumKitCard(id: 'glue', title: 'GLUE', color: c, visual: 'kit_glue', on: 'glue', ids: group('glue')),
    DrumKitCard(id: 'drive', title: 'KIT DRIVE', color: c2, visual: 'kit_drive', on: 'kit_drive_type', ids: group('drive')),
    DrumKitCard(id: 'room', title: 'ROOM', color: Neon.violet, visual: 'kit_room', on: 'room', ids: group('room'),
      note: 'Each pad sends to it by its Space card\'s Room send.'),
    DrumKitCard(id: 'echo', title: 'ECHO', color: Neon.blue, visual: 'kit_echo', on: 'echo', ids: group('echo'),
      note: 'Each pad sends to it by its Pad FX card\'s Echo send.'),
    DrumKitCard(id: 'eq', title: 'KIT EQ', color: Neon.blue, visual: 'kit_eq', ids: group('eq')),
    DrumKitCard(id: 'clip', title: 'CLIP', color: c2, visual: 'kit_clip', on: 'kit_clip', ids: group('clip')),
    const DrumExplodeCard(),
  ];
}

/// The note map of the selected bank: each pad's note (a picker) and channel, and Learn.
class DrumNoteMapCard extends StatelessWidget {
  const DrumNoteMapCard({super.key, required this.layout});
  final DrumsLayout layout;

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final sel = DrumsSelection.of(t);
    return ValueListenableBuilder<int>(valueListenable: sel.bank, builder: (context, bank, _) => DeviceExpandCard(
      key: const ValueKey('drum-note-map'),
      storageId: 'drums-note-map', title: 'NOTE MAP', color: Neon.yellow,
      summary: 'Bank ${bankLabel(bank)}${t.value('mode').round() == 1 ? ' · Single mode plays A1 only' : ''}',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < drumPadsPerBank; i++) Builder(builder: (context) {
          final pad = bank * drumPadsPerBank + i;
          final p = DrumPadView(t, layout, pad);
          return SizedBox(height: 44, child: Row(children: [
            SizedBox(width: 34, child: Text(padLabel(pad), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900,
              color: p.used ? drumTypeColor(p.v('type').round()) : Neon.dim))),
            SizedBox(width: 70, child: Text(p.used ? p.typeName : '—', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Neon.dim))),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: DrumNoteButton(pad: pad))),
            DeviceChoice(p.id('chan'), maxSegments: 0),
            const SizedBox(width: 4),
            DrumLearnButton(pad: pad),
          ]));
        }),
      ]),
    ));
  }
}

/// Explode to tracks: one Single-mode Drums track per used pad, the notes moved onto them; one undo step.
class DrumExplodeCard extends StatelessWidget {
  const DrumExplodeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    return DeviceExpandCard(
      key: const ValueKey('drum-explode-card'),
      storageId: 'drums-explode', title: 'EXPLODE TO TRACKS', color: Neon.pink, initiallyOpen: true,
      summary: 'One track per pad',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Text('Makes a track for each pad that makes sound, playing that pad alone, and moves its notes from '
            'this track\'s clips onto it. Choke groups across tracks and the kit effects stay here. Undo brings '
            'everything back in one step.', style: TextStyle(fontSize: 11, color: Neon.dim)),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: Pressable(glow: Neon.pink, child: FilledButton.icon(
          key: const ValueKey('drum-explode'),
          style: FilledButton.styleFrom(backgroundColor: Neon.pink.withValues(alpha: 0.85), foregroundColor: Neon.bg),
          onPressed: t.isInstrument ? () {
            DeviceFeel.tap();
            final layer = t.layer;
            final n = layer == null ? null : explodeDrums(t.state, layer);
            drumsToast(context, n == null ? 'Explode needs the engine' : 'Made $n track${n == 1 ? '' : 's'} · Undo restores');
          } : null,
          icon: const Icon(Icons.call_split),
          label: const Text('Explode to tracks')))),
      ]),
    );
  }
}
