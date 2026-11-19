// The flagship's one-screen editor: the phone's three panels (swipe, dots, a dragged source flipping them at the
// edge), the wide screen with every part at once, the matrix list, the keys strip, Init, Random patch, oscillator
// copy and paste, and the "What's modulating?" highlight.
import 'dart:math' as math;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/mod_matrix.dart';
import 'package:caw/ui/devices/flagship/flagship_tools.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

const _id = 'org.caw.synth.flagship';

void main() {
  var motion = MotionLevel.full;
  final states = <AppState>[];
  setUp(() {
    motion = Motion.setting;
    FlagshipUi.keysShown = false;
    flagshipOscClipboard = null;
  });
  tearDown(() {
    Motion.setting = motion;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  Future<PreviewState> open(WidgetTester tester, {Size size = const Size(412, 915)}) async {
    final s = stateWith(_id, make: PreviewState.new) as PreviewState;
    states.add(s);
    Motion.setting = MotionLevel.off;
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, _id);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  DeviceTarget synth(AppState s) => DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
  String panelName(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('flagship-panel-name'))).data!;

  testWidgets('phone portrait: three panels, swiped or picked by their dots, each holding its parts', (tester) async {
    await open(tester);
    expect(panelName(tester), 'OSCILLATORS');
    expect(find.byKey(const ValueKey('osc-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-tab-synth')), findsNothing, reason: 'one page, no tabs');
    await tester.flingFrom(tester.getCenter(find.text('OSC 1')), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(panelName(tester), 'FILTERS');
    expect(find.byKey(const ValueKey('filter-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('flagship-routing')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
    await tester.pumpAndSettle();
    expect(panelName(tester), 'MODULATION');
    expect(find.byKey(const ValueKey('flagship-sources')), findsOneWidget);
    expect(find.byKey(const ValueKey('flagship-matrix')), findsOneWidget);
    // A source tab opens that source drawn big.
    await tester.tap(find.byKey(const ValueKey('fsrc-tab-random')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lfo-rnd_rate')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fsrc-tab-note')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('modsrc-velocity')), findsWidgets);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a source dragged onto the right edge flips to the next panel, then drops on a knob there', (tester) async {
    final s = await open(tester);
    final chip = find.descendant(of: find.byKey(const ValueKey('mod-source-strip')),
        matching: find.byKey(const ValueKey('modsrc-env2')));
    final g = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await g.moveBy(const Offset(0, 30));
    await tester.pump();
    await g.moveTo(const Offset(405, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(panelName(tester), 'FILTERS', reason: 'held at the edge, the next panel came');
    await g.moveTo(tester.getCenter(find.byKey(const ValueKey('dknob-flt1_drive'))));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(ModMatrix(synth(s)).routeOf(ModSource.env2, 'flt1_drive'), isNotNull);
    expect(panelName(tester), 'FILTERS', reason: 'leaving the edge stops the flipping');
    await close(tester);
  });

  testWidgets('wide: one screen with the oscillators, filters, effects, sources, matrix and voice', (tester) async {
    final s = await open(tester, size: const Size(1280, 800));
    for (final k in ['osc-1', 'osc-2', 'osc-3', 'filter-1', 'filter-2', 'flagship-routing', 'flagship-fx',
      'flagship-sources', 'flagship-matrix', 'flagship-voice']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('flagship-pages')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('flagship-routing')));
    await tester.pumpAndSettle();
    expect(synth(s).value('flt_routing'), 1, reason: 'the switch between the filters: parallel');
    // The effects rack: a tab per effect, the picked one's power and knobs.
    await tester.tap(find.byKey(const ValueKey('ffx-tab-delay')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dpower-fx_delay_on')));
    await tester.pumpAndSettle();
    expect(synth(s).value('fx_delay_on'), 1);
    expect(find.byKey(const ValueKey('dknob-fx_delay_feedback')), findsOneWidget);
    // A source dropped on the wavetable modulates its position.
    final chip = find.descendant(of: find.byKey(const ValueKey('mod-source-strip')),
        matching: find.byKey(const ValueKey('modsrc-lfo2')));
    final g = await tester.startGesture(tester.getCenter(chip));
    await tester.pump();
    await g.moveBy(const Offset(0, 30));
    await tester.pump();
    await g.moveTo(tester.getCenter(find.byKey(const ValueKey('wt-osc2_'))));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(ModMatrix(synth(s)).routeOf(ModSource.lfo2, 'osc2_frame'), isNotNull);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('phone landscape lays out as the wide screen without overflow', (tester) async {
    await open(tester, size: const Size(915, 412));
    expect(find.byKey(const ValueKey('flagship-wide')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('the matrix list: polarity, remove, and the target that shows the knob it moves', (tester) async {
    final s = await open(tester);
    final slot = ModMatrix(synth(s)).add(ModSource.lfo1, 'osc1_level', bipolar: true)!;
    await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey('fmatrix-$slot')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('fmatrix-polarity-$slot')));
    await tester.pumpAndSettle();
    expect(ModMatrix(synth(s)).route(slot)!.bipolar, isFalse);
    // What's modulating this knob: its panel comes, the knob names its source.
    await tester.tap(find.byKey(ValueKey('fmatrix-locate-$slot')));
    await tester.pumpAndSettle();
    expect(panelName(tester), 'OSCILLATORS');
    expect(find.descendant(of: find.byKey(const ValueKey('whomods-osc1_level')), matching: find.text('LFO 1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('fmatrix-remove-$slot')));
    await tester.pumpAndSettle();
    expect(ModMatrix(synth(s)).route(slot), isNull);
    expect(find.byKey(ValueKey('fmatrix-$slot')), findsNothing);
    await close(tester);
  });

  testWidgets('What\'s modulating? names each knob\'s sources and fades the rest', (tester) async {
    final s = await open(tester);
    ModMatrix(synth(s)).add(ModSource.env3, 'osc1_pan');
    ModMatrix(synth(s)).add(ModSource.random, 'osc1_pan');
    await tester.pump();
    expect(find.byKey(const ValueKey('whomods-osc1_pan')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('flagship-whomods')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('whomods-osc1_pan')), matching: find.text('ENV 3 · RND')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('whomods-osc1_level')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('flagship-whomods')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('whomods-osc1_pan')), findsNothing);
    await close(tester);
  });

  testWidgets('the keys strip shows and hides, and plays the synth while editing', (tester) async {
    final s = await open(tester);
    expect(find.byKey(const ValueKey('flagship-keys')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('flagship-keys-toggle')));
    await tester.pumpAndSettle();
    final keys = find.byKey(const ValueKey('flagship-keys'));
    expect(keys, findsOneWidget);
    final r = tester.getRect(keys);
    final g = await tester.startGesture(Offset(r.center.dx, r.bottom - 8));
    await tester.pump();
    expect(s.played, hasLength(1));
    expect(s.held, hasLength(1));
    await g.up();
    await tester.pump();
    expect(s.held, isEmpty);
    await tester.tap(find.byKey(const ValueKey('flagship-keys-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flagship-keys')), findsNothing);
    await close(tester);
  });

  testWidgets('Init returns every knob to its default; Random patch moves them by its amount', (tester) async {
    final s = await open(tester);
    final t = synth(s);
    t.set('osc1_level', 0.2);
    t.set('flt1_cutoff', 300);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('flagship-init')));
    await tester.pumpAndSettle();
    expect(t.value('osc1_level'), 0.7);
    expect(t.value('flt1_cutoff'), 2400);
    flagshipRandom = math.Random(7);
    await tester.tap(find.byKey(const ValueKey('flagship-random')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flagship-random-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flagship-random-go')));
    await tester.pumpAndSettle();
    expect(t.value('flt1_cutoff'), isNot(2400));
    expect(t.value('volume'), 0.7, reason: 'the volume stays');
    expect(t.value('osc2_on'), 0, reason: 'power switches stay');
    expect(ModMatrix(t).routes, hasLength(1), reason: 'the matrix stays');
    // Amount 0 leaves it alone.
    final before = t.value('osc1_detune');
    randomizeFlagship(t, 0);
    expect(t.value('osc1_detune'), before);
    await close(tester);
  });

  testWidgets('an oscillator copies and pastes onto another', (tester) async {
    final s = await open(tester);
    final t = synth(s);
    t.set('osc1_detune', 60);
    t.set('osc1_table', 2);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('osc1-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('osc1-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('osc2-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('osc2-paste')));
    await tester.pumpAndSettle();
    expect(t.value('osc2_detune'), 60);
    expect(t.value('osc2_table'), 2);
    expect(t.value('osc2_on'), 1, reason: 'oscillator 1 was on, so the copy is');
    await close(tester);
  });

  testWidgets('MORE shows an oscillator\'s other knobs', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('dknob-osc1_frame')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('osc1-toggle')));
    await tester.pumpAndSettle();
    for (final k in ['frame', 'warp_amt', 'octave', 'fine', 'spread', 'blend', 'detune_power', 'phase', 'phase_rand']) {
      expect(find.byKey(ValueKey('dknob-osc1_$k')), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('dknob-osc1_level')), findsNothing);
    await close(tester);
  });
}
