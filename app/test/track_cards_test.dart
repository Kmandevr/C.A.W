// Arrange's track cards against real projects (owner report, 2026-11-11): each card names its C++ instrument and
// preset, draws its clips' notes, knows audio tracks and folders, and its panel's notes, effects and mix edit the
// project (and survive undo); Back leaves the view.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_clips.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/arrange/clip_preview.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/arrange/note_fx_section.dart';
import 'package:caw/ui/arrange/track_color.dart';
import 'package:caw/ui/track_cards_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppState _state(ProjectDoc Function(AppState) project) {
  final s = AppState();
  s.project = project(s);
  s.ready = true;
  s.starting = false;
  s.history.reset(jsonEncode(s.project.toJson())); // as opening a project does: the first edit is undoable
  return s;
}

Future<void> _show(WidgetTester tester, AppState s, {ValueChanged<String>? onOpen, VoidCallback? onBack}) async {
  tester.view.physicalSize = const Size(412, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ListenableBuilder(
              listenable: s,
              builder: (context, _) => TrackCardsScreen(state: s, onOpenModule: onOpen ?? (_) {}, onBack: onBack)))));
  await tester.pump();
}

String _detail(WidgetTester tester, LayerDoc l) =>
    (tester.widget<Text>(find.byKey(ValueKey('track-card-detail-${l.id}')))).data!;

Map<String, dynamic> _engineLayer(AppState s, LayerDoc l) =>
    ((jsonDecode(s.project.toEngineJson()) as Map<String, dynamic>)['layers'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((j) => j['id'] == l.id);

Future<void> _openSheet(WidgetTester tester, LayerDoc l) async {
  await tester.tap(find.text(l.name).first);
  await tester.pumpAndSettle();
}

/// Folders, an audio track, a sampler and per-note FX: a bus folder holding a track and a nested folder.
ProjectDoc _mixed(AppState s) {
  final p = s.starterProject();
  p.assets.add(AudioAssetDoc(id: 'a1', path: '/nowhere/loop.wav', name: 'Loop', seconds: 2));
  p.layers.addAll([
    LayerDoc(id: 'bus', name: 'Drum bus', color: 2, isFolder: true),
    LayerDoc(id: 'inner', name: 'Inner', color: 3, isFolder: true, busEnabled: false, parentId: 'bus'),
    LayerDoc(id: 'audio', name: 'Vocals', color: 4, parentId: 'inner',
        audioClips: [AudioClipDoc(id: 'ac1', assetId: 'a1', startSteps: 16, lengthSeconds: 2)]),
    LayerDoc(id: 'smp', name: 'Chops', color: 5, parentId: 'bus', instrument: ComponentUseDoc('org.caw.sampler'),
        noteComponents: [ComponentUseDoc('org.caw.filter', {'cutoff': 800})]),
  ]);
  return p;
}

final _lib = Platform.environment['CAW_LIB'];
final _noEngine = _lib?.isEmpty ?? true;

void main() {
  testWidgets('each card names its C++ instrument and preset, not "No instrument"', (tester) async {
    final s = _state((s) => s.starterProject());
    await _show(tester, s);
    expect(find.textContaining('No instrument'), findsNothing);
    for (final l in s.project.layers) {
      final detail = _detail(tester, l);
      expect(detail, contains(s.componentLabel(l.instrument!.id)), reason: l.name);
      expect(detail, contains(l.instrument!.preset!), reason: '${l.name}: $detail');
      expect(detail, contains(s.project.module(l.clips.single.patternId)!.name), reason: 'the clip\'s pattern');
    }
    s.dispose();
  });

  testWidgets('each card draws its clips with their notes (Arrange\'s clip preview, loops included)', (tester) async {
    final s = _state((s) => s.starterProject());
    final bass = s.project.layers.firstWhere((l) => l.name == 'Bass');
    bass.clips.single
      ..loop = true
      ..loopSteps = 8;
    await _show(tester, s);
    for (final l in s.project.layers) {
      final clip = l.clips.single;
      expect(find.byKey(ValueKey('card-clip-${clip.id}')), findsOneWidget, reason: l.name);
      final paint = tester.widget<CustomPaint>(find.byKey(ValueKey('card-notes-${clip.id}')));
      final preview = (paint.painter! as ClipPreviewPainter).preview as MidiClipPreview;
      expect(preview.patternId, clip.patternId);
      expect(preview.loop, clip.loop);
      expect(preview.loopSteps, clip.loopSteps);
    }
    s.dispose();
  });

  testWidgets('folders, nested tracks, audio and sampler tracks get cards of their own kind', (tester) async {
    final s = _state(_mixed);
    await _show(tester, s);
    final layers = {for (final l in s.project.layers) l.id: l};
    expect(_detail(tester, layers['bus']!), 'Bus folder  ·  2 tracks');
    expect(_detail(tester, layers['inner']!), 'Folder  ·  1 track');
    expect(_detail(tester, layers['audio']!), 'Audio  ·  1 clip');
    expect(_detail(tester, layers['smp']!), contains(s.componentLabel('org.caw.sampler')));
    expect(_detail(tester, layers['smp']!), contains('1 fx'), reason: 'per-note FX count');
    expect(find.byKey(const ValueKey('card-audio-ac1')), findsWidgets, reason: 'the audio clip, also under its folders');
    expect(find.textContaining('No instrument'), findsNothing);
    // Nested cards are indented under their folders, and take their folder's shade.
    double left(String id) => tester.getTopLeft(find.byKey(ValueKey('track-card-$id'))).dx;
    expect(left('inner'), greaterThan(left('bus')));
    expect(left('audio'), greaterThan(left('inner')));
    s.dispose();
  });

  testWidgets('the panel lists the track\'s clips and opens a clip\'s notes in Build', (tester) async {
    final s = _state((s) => s.starterProject());
    final kick = s.project.layers.first;
    String? opened;
    await _show(tester, s, onOpen: (id) => opened = id);
    await _openSheet(tester, kick);
    expect(find.text('Loops every'), findsNothing, reason: 'the engine ignores a clip track\'s loop length');
    final clip = kick.clips.single;
    await tester.tap(find.byKey(ValueKey('track-sheet-clip-${clip.id}')));
    await tester.pumpAndSettle();
    expect(opened, clip.patternId);
    expect(s.selectedClipId, clip.id);
    expect(find.text('INSTRUMENT'), findsNothing, reason: 'the panel closed for Build');
    s.dispose();
  });

  testWidgets('an empty track\'s panel starts a pattern as a clip on it', (tester) async {
    final s = _state((s) => s.starterProject()..layers.clear());
    final track = s.addEmptyTrack();
    await _show(tester, s);
    expect(_detail(tester, track), contains('No clips'));
    await _openSheet(tester, track);
    await tester.tap(find.byKey(const ValueKey('track-sheet-new-pattern')));
    await tester.pumpAndSettle();
    expect(track.clips, hasLength(1));
    expect(_engineLayer(s, track)['clips'], hasLength(1));
    s.dispose();
  });

  testWidgets('the panel\'s effects are the focus view\'s FX stack: remove reaches the engine, per-note FX show',
      (tester) async {
    final s = _state(_mixed);
    final lead = s.project.layers.firstWhere((l) => l.name == 'Lead');
    await _show(tester, s);
    await _openSheet(tester, lead);
    expect(find.byType(FxStack), findsOneWidget);
    expect(_engineLayer(s, lead)['components'], hasLength(1));
    final name = s.componentLabel(lead.components.single.id);
    await tester.tap(find.byTooltip('Remove $name'));
    await tester.pumpAndSettle();
    expect(lead.components, isEmpty);
    expect(_engineLayer(s, lead).containsKey('components'), isFalse);
    s.endUndoStep();
    s.undo();
    await tester.pumpAndSettle();
    expect(s.project.layers.firstWhere((l) => l.id == lead.id).components, hasLength(1));
    Navigator.of(tester.element(find.byType(FxStack))).pop();
    await tester.pumpAndSettle();

    final sampler = s.project.layers.firstWhere((l) => l.id == 'smp');
    await _openSheet(tester, sampler);
    expect(find.byType(NoteFxSection), findsOneWidget);
    s.dispose();
  });

  testWidgets('the panel stays open on its track through undo and redo, and its mix edits stick', (tester) async {
    final s = _state((s) => s.starterProject());
    final bass = s.project.layers.firstWhere((l) => l.name == 'Bass');
    await _show(tester, s);
    await _openSheet(tester, bass);
    await tester.tap(find.byTooltip('Mute').last);
    await tester.pumpAndSettle();
    expect(bass.mute, isTrue);
    expect(_engineLayer(s, bass)['mute'], isTrue);
    await tester.drag(find.byKey(const ValueKey('track-sheet-pan')), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(bass.pan, greaterThan(0.1));
    expect(_engineLayer(s, bass)['pan'], bass.pan);
    s.endUndoStep();

    s.undo();
    await tester.pumpAndSettle();
    expect(find.text('MIX'), findsOneWidget, reason: 'an undo rebuilds the project; the panel follows the track by id');
    final restored = s.project.layers.firstWhere((l) => l.id == bass.id);
    expect(identical(restored, bass), isFalse);
    expect(restored.pan, 0);
    expect(tester.widget<Slider>(find.byKey(const ValueKey('track-sheet-pan'))).value, 0);
    s.redo();
    await tester.pumpAndSettle();
    final redone = s.project.layers.firstWhere((l) => l.id == bass.id);
    expect(redone.pan, greaterThan(0.1));
    expect(tester.widget<Slider>(find.byKey(const ValueKey('track-sheet-pan'))).value, redone.pan);
    // Edits after the undo land on the restored track, and survive a save and reload.
    await tester.drag(find.byKey(const ValueKey('track-sheet-pan')), const Offset(-240, 0));
    await tester.pumpAndSettle();
    expect(redone.pan, lessThan(0));
    final reloaded = ProjectDoc.fromJson(jsonDecode(jsonEncode(s.project.toJson())) as Map<String, dynamic>);
    expect(reloaded.layers.firstWhere((l) => l.id == bass.id).pan, redone.pan);
    s.dispose();
  });

  testWidgets('the panel\'s colour dot recolours a track inside a folder', (tester) async {
    final s = _state(_mixed);
    final sampler = s.project.layers.firstWhere((l) => l.id == 'smp');
    await _show(tester, s);
    await _openSheet(tester, sampler);
    final before = trackColor(s, sampler);
    await tester.tap(find.byTooltip('Change colour'));
    await tester.pumpAndSettle();
    expect(trackColor(s, sampler), isNot(before));
    expect(sampler.ownColor, isTrue);
    s.dispose();
  });

  testWidgets('Back and Android\'s back gesture leave the cards for the arrangement', (tester) async {
    final s = _state((s) => s.starterProject());
    var backs = 0;
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      TrackCardsHeader(onBack: () => backs++),
      Expanded(child: TrackCardsScreen(state: s, onOpenModule: (_) {}, onBack: () => backs++)),
    ]))));
    await tester.tap(find.byKey(const ValueKey('track-cards-back')));
    expect(backs, 1);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(backs, 2, reason: 'system back goes back to the arrangement');
    expect(find.byType(TrackCardsScreen), findsOneWidget, reason: 'the route itself stays');
    s.dispose();
  });

  testWidgets('with the engine: cards name the loaded instruments, and the panel\'s FX stack and mix work', (tester) async {
    final s = _state((s) => s.starterProject());
    s.engine = Engine.create();
    await tester.runAsync(() async {
      s.info = await s.engine!.setProject(s.project.toEngineJson());
      s.componentCatalog.refreshIfStale();
      for (var i = 0; i < 100 && s.componentCatalog.value.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(s.componentCatalog.value, isNotEmpty);
    await _show(tester, s);
    final bass = s.project.layers.firstWhere((l) => l.name == 'Bass');
    final drums = s.componentInfo('org.caw.drums')!.label, flagship = s.componentInfo('org.caw.synth.flagship')!.label;
    expect(_detail(tester, s.project.layers.first), startsWith('$drums · Kit: 808'));
    expect(_detail(tester, bass), startsWith('$flagship · Mono bass'));
    await _openSheet(tester, bass);
    expect(tester.takeException(), isNull);
    expect(find.byType(FxStack), findsOneWidget);
    await tester.tap(find.byTooltip('Solo').last);
    await tester.pumpAndSettle();
    expect(bass.solo, isTrue);
    expect(_engineLayer(s, bass)['solo'], isTrue);
    s.dispose();
  }, skip: _noEngine);
}
