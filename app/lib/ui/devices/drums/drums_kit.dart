// The drums' kit cards: building a kit (Synth, Produced or Acoustic), mode and MIDI (channel, first note, volume, variation seed), the note map of a bank with Learn, the kit effects (glue, drive, room, echo, EQ, clip) and Explode to tracks.
import 'dart:math' as math;

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
    const DrumBuildCard(),
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

/// Building a kit (1.1.2): its kind and style, a key and an Acoustic kit's e-drum map; Build makes a new kit over
/// this one (one undo step), and the kit tools (mutate, tune to the key, match loudness, map the pads, a finishing
/// chain) work on the kit as it is. Minimal by design: the builder's own screens are the owner's to design.
class DrumBuildCard extends StatefulWidget {
  const DrumBuildCard({super.key});

  @override
  State<DrumBuildCard> createState() => _DrumBuildCardState();
}

class _DrumBuildCardState extends State<DrumBuildCard> {
  static const _keys = ['No key', 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  static final _random = math.Random();
  int _kind = 2, _style = 0, _key = 0, _map = 0, _chain = 0;

  Widget _pick(String label, int value, List<String> items, ValueChanged<int> onChanged, {required String key}) =>
      LabeledRow(label, DropdownButton<int>(
        key: ValueKey(key),
        value: items.isEmpty ? null : value.clamp(0, items.length - 1),
        isExpanded: true,
        isDense: true,
        items: [for (final (i, s) in items.indexed) DropdownMenuItem(value: i, child: Text(s, overflow: TextOverflow.ellipsis))],
        onChanged: items.isEmpty ? null : (v) => setState(() => onChanged(v ?? 0)),
      ));

  @override
  Widget build(BuildContext context) {
    final scope = DeviceScope.of(context);
    final t = scope.target;
    final builders = DrumsApi.current.builders();
    final styles = builders?[drumKitKinds[_kind].toLowerCase()] ?? const <String>[];
    final maps = builders?['maps'] ?? const <String>[];
    final chains = builders?['chains'] ?? const <String>[];
    final ready = t.isInstrument && builders != null;
    String pickOf(List<String> l, int i) => l.isEmpty ? '' : l[i.clamp(0, l.length - 1)];
    Widget action(String id, String label, IconData icon, bool Function() run, String done) => Pressable(
        glow: scope.accent,
        child: OutlinedButton.icon(
            key: ValueKey(id),
            onPressed: ready
                ? () {
                    DeviceFeel.tap();
                    drumsToast(context, run() ? done : 'Needs the engine');
                  }
                : null,
            icon: Icon(icon, size: 16),
            label: Text(label)));
    return DeviceExpandCard(
      key: const ValueKey('drum-build-card'),
      storageId: 'drums-build', title: 'BUILD A KIT', color: scope.accent, initiallyOpen: false,
      summary: builders == null ? 'Needs the engine' : '${drumKitKinds[_kind]} · ${pickOf(styles, _style)}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        LabeledRow('KIND', SegmentedButton<int>(
          key: const ValueKey('drum-build-kind'),
          segments: [for (final (i, k) in drumKitKinds.indexed) ButtonSegment(value: i, label: Text(k))],
          selected: {_kind},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() {
            _kind = v.first;
            _style = 0;
          }),
        )),
        _pick('STYLE', _style, styles, (v) => _style = v, key: 'drum-build-style'),
        _pick('KEY', _key, _keys, (v) => _key = v, key: 'drum-build-key'),
        if (_kind == 2) _pick('E-DRUM MAP', _map, maps, (v) => _map = v, key: 'drum-build-map'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          Pressable(glow: scope.accent, child: FilledButton.icon(
            key: const ValueKey('drum-build'),
            onPressed: ready && styles.isNotEmpty
                ? () {
                    DeviceFeel.tap();
                    final ok = buildDrumKit(t, kind: _kind, style: _style, seed: _random.nextInt(1 << 31), key: _key - 1,
                        map: _map);
                    drumsToast(context, ok ? 'New ${drumKitKinds[_kind]} kit · Undo restores' : 'Build needs the engine');
                  }
                : null,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Build'))),
          if (_kind != 2)
            action('drum-build-mutate', 'Mutate kit', Icons.shuffle,
                () => drumKitTool(t, 'mutate', {'amount': 0.15, 'seed': _random.nextInt(1 << 31)}), 'Kit mutated · Undo restores'),
          action('drum-build-tune', 'Tune to key', Icons.music_note,
              () => _key > 0 && drumKitTool(t, 'tune_to_key', {'key': _key - 1}), 'Tuned to ${_keys[_key]}'),
          if (_kind != 2)
            action('drum-build-loudness', 'Match loudness', Icons.equalizer, () => drumKitTool(t, 'match_loudness', {}),
                'Pads level-matched'),
          if (_kind == 2)
            action('drum-build-remap', 'Map pads', Icons.grid_view, () => drumKitTool(t, 'map', {'map': _map}),
                'Pads follow ${pickOf(maps, _map)}'),
        ]),
        if (_kind == 1) ...[
          const SizedBox(height: 8),
          _pick('FINISH', _chain, chains, (v) => _chain = v, key: 'drum-build-chain'),
          Align(alignment: Alignment.centerLeft, child: action('drum-build-finish', 'Finish the bus', Icons.tune,
              () => chains.isNotEmpty && drumKitTool(t, 'finish', {'chain': pickOf(chains, _chain), 'pad': -1}),
              'Finishing chain on the bus')),
        ],
      ]),
    );
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
