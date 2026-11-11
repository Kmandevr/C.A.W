// Per-note FX (#127) in the app: the layer's noteComponents and noteVoices round trip and reach the engine JSON,
// "Run per note" moves an effect (greyed out with a reason when it can't), and the Per note section's golden.
import 'dart:convert';

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/note_fx.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// An instrument without a voice bus (whole only).
const _plain = NativeComponentInfo(id: 'com.example.plain', name: 'Plain', role: 'instrument', ports: [
  ComponentPortInfo(id: 'notes', type: 'event', input: true, layout: 'none', channels: 0),
  ComponentPortInfo(id: 'out', type: 'audio', input: false, layout: 'stereo', channels: 2),
]);

void main() {
  test('noteComponents and noteVoices round trip and reach the engine with the instrument', () {
    final l = LayerDoc(id: 't', name: 'T', color: 0,
        instrument: ComponentUseDoc('org.caw.synth.flagship'),
        noteComponents: [ComponentUseDoc('org.caw.filter', {'cutoff': 800})], noteVoices: 5);
    final back = LayerDoc.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>);
    expect(back.noteComponents.single.id, 'org.caw.filter');
    expect(back.noteComponents.single.params['cutoff'], 800);
    expect(back.noteVoices, 5);
    // The defaults stay out of the saved file, and a bad count is held to 1..16.
    final plain = LayerDoc(id: 'p', name: 'P', color: 0).toJson();
    expect(plain.containsKey('noteComponents'), isFalse);
    expect(plain.containsKey('noteVoices'), isFalse);
    expect(LayerDoc.fromJson({'id': 'x', 'noteVoices': 40}).noteVoices, 16);
    expect(LayerDoc.fromJson({'id': 'x', 'noteVoices': 0}).noteVoices, 1);
    final p = ProjectDoc(id: 'p', name: 'P', bpm: 120, modules: [], layers: [l]);
    final layer = (jsonDecode(p.toEngineJson())['layers'] as List).single as Map<String, dynamic>;
    expect((layer['noteComponents'] as List).single['id'], 'org.caw.filter');
    expect(layer['noteVoices'], 5);
    // Without an instrument they aren't sent (they run inside it).
    l.instrument = null;
    final none = (jsonDecode(p.toEngineJson())['layers'] as List).single as Map<String, dynamic>;
    expect(none.containsKey('noteComponents'), isFalse);
  });

  group('the FX stack', () {
    var motion = MotionLevel.full;
    late AppState s;
    setUp(() {
      motion = Motion.setting;
      Motion.setting = MotionLevel.off;
      s = AppState(settings: Settings());
      s.project = ProjectDoc(id: 'p', name: 'Per note', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Keys', color: 3)]);
      s.componentCatalog.set([...builtinInfos(), _plain]);
      s.setNativeInstrument(s.project.layers.first, 'org.caw.synth.flagship');
      s.addNativeEffect(s.project.layers.first, 'org.caw.filter');
      s.addNativeEffect(s.project.layers.first, 'org.caw.limiter');
    });
    tearDown(() {
      Motion.setting = motion;
      s.dispose();
    });
    LayerDoc layer() => s.project.layers.first;

    test('Run per note moves an effect, and says why when it can\'t', () {
      expect(s.perNoteBlocker(layer(), 'org.caw.filter'), isNull);
      expect(s.perNoteBlocker(layer(), 'org.caw.limiter'), contains('whole track'));
      expect(s.runPerNote(layer(), 1), isFalse);
      expect(s.runPerNote(layer(), 0), isTrue);
      expect(layer().noteComponents.single.id, 'org.caw.filter');
      expect(layer().components.single.id, 'org.caw.limiter');
      s.setNoteVoices(layer(), 4);
      expect(layer().noteVoices, 4);
      s.runOnTrack(layer(), 0);
      expect(layer().noteComponents, isEmpty);
      expect(layer().components.first.id, 'org.caw.filter');
      s.setNativeInstrument(layer(), 'com.example.plain');
      expect(s.perNoteBlocker(layer(), 'org.caw.filter'), contains('no per-note output'));
    });

    testWidgets('the Per note section sits above the track effects, with its chip and dots', (tester) async {
      s.runPerNote(layer(), 0);
      await pumpGolden(tester, Scaffold(body: SizedBox(height: 844,
          child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: layer())))),
          goldenSizes['phone']!);
      expect(find.byKey(const ValueKey('note-fx-section')), findsOneWidget);
      expect(find.text('PER NOTE'), findsOneWidget);
      expect(find.byKey(const ValueKey('note-fx-voices')), findsOneWidget);
      expect(find.text('8 voices'), findsOneWidget);
      final perNote = tester.getTopLeft(find.text('PER NOTE')).dy;
      final track = tester.getTopLeft(find.text('NATIVE EFFECTS · C++')).dy;
      expect(perNote, lessThan(track));
      await expectLater(goldenScreen, matchesGoldenFile('goldens/note_fx_section_phone.png'));
      await tester.tap(find.byKey(const ValueKey('note-fx-bypass-0')));
      await tester.pump();
      expect(layer().noteComponents.single.bypass, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
