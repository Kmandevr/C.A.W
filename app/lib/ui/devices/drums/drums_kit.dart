// The drums' KIT page: mode and MIDI (channel, first note, volume, variation seed), the note map of a bank with Learn, the kit effects (glue, drive, room, EQ, clip) and Explode to tracks.
import 'package:flutter/material.dart';

import '../../../model/drums.dart';
import '../../feedback.dart';
import '../../theme.dart';
import '../device_controls.dart';
import '../device_scope.dart';
import '../flagship/flagship_editor.dart' show LabeledRow;
import '../kit/controls.dart';
import '../kit/feel.dart';
import '../kit/hero.dart';
import 'drums_pads.dart';
import 'drums_voice.dart';

/// The kit page: MIDI, the note map, the kit's effects and Explode, as cards that open in place.
class DrumsKitPage extends StatelessWidget {
  const DrumsKitPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final layout = drumsLayout(t);
    final c = scope.accent, c2 = scope.secondary;
    String f(String id) => formatParamValue(t.param(id), t.value(id));
    Map<String, String> labels(List<String> ids) =>
        {for (final id in ids) id: t.param(id) == null ? id : drumKnobLabel(t.param(id)!).replaceFirst(RegExp(r'^(Kit|Glue|Room) '), '')};
    Widget knobs(List<String> ids) => KnobRow(ids, size: 44, labels: labels(ids));
    return ListView(key: const ValueKey('drums-kit'), padding: const EdgeInsets.fromLTRB(8, 8, 8, 32), children: [
      DeviceExpandCard(
        key: const ValueKey('drum-kit-midi'),
        storageId: 'drums-kit-midi', title: 'MODE & MIDI', color: c, initiallyOpen: true,
        summary: '${f('mode')} · ch ${f('channel')} · from ${noteName(t.value('base_note').round())}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const LabeledRow('MODE', DeviceChoice('mode', labels: ['Kit · pads on notes', 'Single · A1 plays all'])),
          const LabeledRow('CHANNEL', DeviceChoice('channel', maxSegments: 0)),
          knobs(const ['base_note', 'volume', 'seed']),
        ])),
      DrumNoteMapCard(layout: layout),
      DeviceExpandCard(
        key: const ValueKey('drum-kit-glue'),
        storageId: 'drums-kit-glue', title: 'GLUE', color: c, dimmed: t.value('glue') <= 0,
        summary: t.value('glue') <= 0 ? 'Off' : '${f('glue')} · ${f('glue_ratio')}:1',
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: knobs(layout.kitGroups['glue'] ?? const [])),
          DeviceDisplay(builder: (context, fr) => LevelMeter(
            db: fr is DrumsDisplayFrame ? -fr.glueGr : null, label: 'GR', reduction: true, height: 110)),
        ])),
      DeviceExpandCard(
        key: const ValueKey('drum-kit-drive'),
        storageId: 'drums-kit-drive', title: 'DRIVE', color: c2, dimmed: t.value('kit_drive_type') < 0.5,
        summary: t.value('kit_drive_type') < 0.5 ? 'Off' : '${f('kit_drive_type')} · ${f('kit_drive')}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const LabeledRow('TYPE', DeviceChoice('kit_drive_type')),
          knobs(const ['kit_drive', 'kit_drive_mix']),
        ])),
      DeviceExpandCard(
        key: const ValueKey('drum-kit-room'),
        storageId: 'drums-kit-room', title: 'ROOM', color: Neon.violet, dimmed: t.value('room') <= 0,
        summary: t.value('room') <= 0 ? 'Off' : '${f('room')} · ${f('room_decay')}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          knobs(layout.kitGroups['room'] ?? const []),
          const Text('Each pad sends to the room by its Space card\'s Room send.', style: TextStyle(fontSize: 10, color: Neon.dim)),
        ])),
      DeviceExpandCard(
        key: const ValueKey('drum-kit-eq'),
        storageId: 'drums-kit-eq', title: 'EQ', color: Neon.blue,
        summary: 'Low ${f('kit_low')} · High ${f('kit_high')}',
        child: knobs(const ['kit_low', 'kit_high'])),
      DeviceExpandCard(
        key: const ValueKey('drum-kit-clip'),
        storageId: 'drums-kit-clip', title: 'CLIP', color: c2, dimmed: t.value('kit_clip') < 0.5,
        summary: t.value('kit_clip') < 0.5 ? 'Off' : '${f('kit_clip')} · ${f('kit_clip_gain')}',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const LabeledRow('CLIPPER', DeviceChoice('kit_clip')),
          knobs(const ['kit_clip_gain']),
        ])),
      const DrumExplodeCard(),
    ]);
  }
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
