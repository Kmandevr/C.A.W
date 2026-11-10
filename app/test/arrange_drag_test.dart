// The REAPER-style arranger (#172): clips moved and copied between tracks, drops below the last track making a new
// track, instruments added like effects, track headers dragged, clip edges trimmed and empty clips drawn.
import 'dart:convert';

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/frame/sections.dart';
import 'package:flutter_test/flutter_test.dart';

const synth = NativeComponentInfo(id: 'org.caw.synth.basic', name: 'Basic synth', role: 'instrument', builtin: true,
    ports: [
      ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
      ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
    ],
    parameters: [ComponentParameterInfo(id: 'cutoff', name: 'Cutoff', defaultValue: 2400, min: 20, max: 20000)]);
const width = NativeComponentInfo(id: 'org.caw.stereo.width', name: 'Width', role: 'effect', builtin: true,
    parameters: [ComponentParameterInfo(id: 'width', name: 'Width', defaultValue: 1, min: 0, max: 2)]);

ProjectDoc project() => ProjectDoc(id: 'p', name: 'Drag test', modules: [
      ModuleDoc(id: 'pat', name: 'Beat', source: '---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n'),
      ModuleDoc(id: 'gen', name: 'Saw', source: '---\nkind: generator\n---\n'),
      ModuleDoc(id: 'fx1', name: 'Echo', source: '---\nkind: effect\n---\n'),
    ], layers: [
      LayerDoc(id: 'a', name: 'Drums', color: 0, clips: [ClipDoc(id: 'c1', patternId: 'pat', startSteps: 16, lengthSteps: 16)]),
      LayerDoc(id: 'f', name: 'Group', color: 1, isFolder: true),
      LayerDoc(id: 'b', name: 'Bass', color: 2, parentId: 'f'),
      LayerDoc(id: 'c', name: 'Lead', color: 3),
    ]);

void main() {
  late AppState s;
  setUp(() {
    s = AppState(settings: Settings());
    s.project = project();
    s.componentCatalog.set(const [synth, width]);
  });
  tearDown(() => s.dispose());

  LayerDoc layer(String id) => s.project.layers.firstWhere((l) => l.id == id);

  group('clips between tracks', () {
    test('a move keeps the clip and its pattern, at the new time', () {
      final clip = layer('a').clips.single;
      s.moveClipTo(layer('a'), clip, layer('c'), 32);
      expect(layer('a').clips, isEmpty);
      expect(layer('c').clips.single, same(clip));
      expect(clip.startSteps, 32);
      expect(clip.patternId, 'pat');
      expect(s.selectedLayerId, 'c');
    });

    test('a copy (REAPER Ctrl-drag) leaves the original and gets its own notes', () {
      final clip = layer('a').clips.single;
      final copy = s.moveClipTo(layer('a'), clip, layer('c'), 0, copy: true)!;
      expect(layer('a').clips.single, same(clip));
      expect(layer('c').clips.single, same(copy));
      expect(copy.patternId, isNot('pat'));
      expect(s.project.module(copy.patternId)!.source, s.project.module('pat')!.source);
    });

    test('dropped on a folder it goes on the first track inside; on an empty folder, on a new track inside', () {
      s.moveClipTo(layer('a'), layer('a').clips.single, layer('f'), 0);
      expect(layer('b').clips, hasLength(1));
      s.editProject((p) => p.layers.add(LayerDoc(id: 'g', name: 'Empty', color: 0, isFolder: true)));
      s.moveClipTo(layer('b'), layer('b').clips.single, layer('g'), 0);
      final made = s.project.layers.last;
      expect(made.parentId, 'g');
      expect(made.clips, hasLength(1));
    });

    test('below the last track: a new track named after the pattern', () {
      s.moveClipTo(layer('a'), layer('a').clips.single, null, 8);
      final made = s.project.layers.last;
      expect(made.name, 'Beat');
      expect(made.parentId, isNull);
      expect(made.clips.single.startSteps, 8);
    });

    test('a move is one undo step, new track and all', () async {
      s.starting = false; // as after a project opens
      s.history.reset(jsonEncode(s.project.toJson()));
      s.moveClipTo(layer('a'), layer('a').clips.single, null, 8);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(s.undo(), isTrue);
      expect(s.project.layers, hasLength(4));
      expect(s.project.layers.first.clips, hasLength(1));
      expect(s.canUndo, isFalse);
    });
  });

  group('drops below the last track', () {
    test('each kind makes a new track with it', () {
      s.project.midiFiles.add(MidiFileDoc(id: 'mf', name: 'Song.mid', parts: ['pat']));
      final pattern = s.dropOnNewTrack(const AssetDrag(AssetKind.pattern, 'pat', 'Beat'), atStep: 4)!;
      expect(pattern.clips.single.patternId, 'pat');
      final midi = s.dropOnNewTrack(const AssetDrag(AssetKind.midiFile, 'mf', 'Song.mid'), atStep: 0)!;
      expect(midi.clips.single.patternId, 'pat');
      final inst = s.dropOnNewTrack(const AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Basic synth',
          instrument: true))!;
      expect(inst.instrument?.id, 'org.caw.synth.basic');
      expect(inst.name, 'Basic synth');
      final gen = s.dropOnNewTrack(const AssetDrag(AssetKind.cawModule, 'gen', 'Saw', instrument: true))!;
      expect(gen.generatorId, 'gen');
      final fx = s.dropOnNewTrack(const AssetDrag(AssetKind.nativeEffect, 'org.caw.stereo.width', 'Width'))!;
      expect(fx.components.single.id, 'org.caw.stereo.width');
      expect(fx.instrument, isNull);
      final caw = s.dropOnNewTrack(const AssetDrag(AssetKind.cawModule, 'fx1', 'Echo'))!;
      expect(caw.effectIds, ['fx1']);
      expect(s.project.layers, hasLength(10));
    });

    test('something that cannot go on a track leaves no track', () {
      expect(s.dropOnNewTrack(const AssetDrag(AssetKind.pattern, 'missing', 'Gone')), isNull);
      expect(s.project.layers, hasLength(4));
    });
  });

  group('instruments like effects', () {
    test('an instrument replaces the old one; the UI is told to ask first', () {
      final a = layer('a');
      const drag = AssetDrag(AssetKind.nativeEffect, 'org.caw.synth.basic', 'Basic synth', instrument: true);
      expect(s.replacesInstrument(a, drag), isFalse, reason: 'nothing plays it yet');
      s.dropAsset(a, drag);
      expect(s.instrumentName(a), 'Basic synth');
      expect(s.replacesInstrument(a, drag), isFalse, reason: 'the same instrument');
      const saw = AssetDrag(AssetKind.cawModule, 'gen', 'Saw');
      expect(s.replacesInstrument(a, saw), isTrue);
      s.dropAsset(a, saw);
      expect(a.instrument, isNull);
      expect(a.generatorId, 'gen');
      expect(s.replacesInstrument(a, const AssetDrag(AssetKind.cawModule, 'fx1', 'Echo')), isFalse,
          reason: 'an effect joins the chain');
    });
  });

  group('tracks dragged', () {
    test('above, below and into a folder, with what is inside', () {
      expect(s.moveTrack(layer('c'), layer('a'), TrackDrop.above), isTrue);
      expect(s.project.layers.map((l) => l.id), ['c', 'a', 'f', 'b']);
      expect(s.moveTrack(layer('c'), layer('f'), TrackDrop.into), isTrue);
      expect(layer('c').parentId, 'f');
      expect(s.moveTrack(layer('f'), null, TrackDrop.below), isTrue);
      expect(s.project.layers.map((l) => l.id), ['a', 'f', 'b', 'c']);
      expect(s.moveTrack(layer('a'), layer('f'), TrackDrop.below), isTrue);
      expect(s.project.layers.map((l) => l.id), ['f', 'b', 'c', 'a']);
      expect(layer('a').parentId, isNull);
      expect(s.moveTrack(layer('f'), layer('b'), TrackDrop.above), isFalse, reason: 'not into itself');
      expect(s.moveTrack(layer('b'), layer('a'), TrackDrop.below), isTrue);
      expect(layer('b').parentId, isNull, reason: 'out of the folder');
    });
  });

  group('edit in place', () {
    test('the left edge trims and keeps the notes where they were', () {
      final a = layer('a');
      final clip = a.clips.single;
      s.trimClipStart(a, clip, 20);
      expect((clip.startSteps, clip.lengthSteps, clip.sourceOffsetSteps), (20, 12, 4));
      s.trimClipStart(a, clip, 0);
      expect((clip.startSteps, clip.lengthSteps, clip.sourceOffsetSteps), (16, 16, 0),
          reason: 'not before the source starts');
    });

    test('an empty clip gets its own blank pattern', () {
      final clip = s.addEmptyClip(layer('c'), 8, 32)!;
      final m = s.project.module(clip.patternId)!;
      expect(m.name, 'Pattern 1');
      expect(s.isPattern(m.id), isTrue);
      expect((clip.startSteps, clip.lengthSteps), (8, 32));
    });
  });
}
