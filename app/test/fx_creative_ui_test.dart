// The Creative and Pitch & Time plugin UIs (fx-creative): each hero's drag edits its parameters, the hold pads, the drawable gate pattern, the catalog and the ring mod's key.
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/routing_edit.dart';
import 'package:caw/model/project.dart';
import 'package:caw/ui/devices/effects/creative/creative_catalog.dart';
import 'package:caw/ui/devices/effects/creative/creative_common.dart';
import 'package:caw/ui/devices/kit/device_style.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

void main() {
  var motion = MotionLevel.full;
  late DeviceDisplaySource source;
  late FakeDisplay display;
  final states = <AppState>[];

  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  Future<AppState> open(WidgetTester tester, String id, {Size size = const Size(390, 844)}) async {
    final s = stateWith(id, make: PreviewState.new);
    Motion.setting = MotionLevel.off;
    states.add(s);
    display.frame.value = fakeFrame(id);
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Rect hero(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

  test('the catalog: every effect has a browser category, a description and its own UI and family', () {
    expect(creativeCatalog.map((e) => e.id).toSet(), creativeEditors.keys.toSet());
    for (final e in creativeCatalog) {
      expect(['Pitch & Time', 'Creative'], contains(e.category));
      expect(e.description.length, inInclusiveRange(20, 100), reason: e.id);
      expect(familyOfComponent(e.id), DeviceFamily.creative);
      expect(builtinInfo(e.id).parameters, isNotEmpty);
    }
  });

  test('a division label is its length in seconds', () {
    expect(divisionSeconds('1/4', 120), closeTo(0.5, 1e-9));
    expect(divisionSeconds('1/8 T', 120), closeTo(0.25 * 2 / 3, 1e-9));
    expect(divisionSeconds('1/16 D', 120), closeTo(0.125 * 1.5, 1e-9));
    expect(divisionSeconds('2 bars', 120), closeTo(4, 1e-9));
    expect(divisionSeconds('Free', 120), isNull);
  });

  testWidgets('tape stop: the hold pad stops while held; the hero drags the stop time and the curve', (tester) async {
    final s = await open(tester, 'org.caw.tapestop');
    final t = targetOf(s, 'org.caw.tapestop');
    final pad = tester.getCenter(find.byKey(const ValueKey('hold-stop')));
    final g = await tester.startGesture(pad);
    await tester.pump();
    expect(t.value('stop'), 1);
    await g.up();
    await tester.pump();
    expect(t.value('stop'), 0);
    final r = hero(tester, 'tapestop-hero');
    await tester.dragFrom(r.center, const Offset(60, -40));
    await tester.pumpAndSettle();
    expect(t.value('stop_time'), greaterThan(600));
    expect(t.value('curve'), greaterThan(0.2));
    await close(tester);
  });

  testWidgets('reverser: sideways steps the division, up raises the crossfade', (tester) async {
    final s = await open(tester, 'org.caw.reverser');
    final t = targetOf(s, 'org.caw.reverser');
    final r = hero(tester, 'reverser-hero');
    await tester.dragFrom(r.center, const Offset(80, -40));
    await tester.pumpAndSettle();
    expect(t.value('sync'), greaterThan(9));
    expect(t.value('crossfade'), greaterThan(10));
    await close(tester);
  });

  testWidgets('stutter: up raises the pitch per repeat, sideways the decay; the pad holds', (tester) async {
    final s = await open(tester, 'org.caw.stutter');
    final t = targetOf(s, 'org.caw.stutter');
    final r = hero(tester, 'stutter-hero');
    await tester.dragFrom(r.center, const Offset(60, -40));
    await tester.pumpAndSettle();
    expect(t.value('pitch'), greaterThan(1));
    expect(t.value('decay'), greaterThan(0.2));
    final g = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('hold-hold'))));
    await tester.pump();
    expect(t.value('hold'), 1);
    await g.up();
    await tester.pump();
    expect(t.value('hold'), 0);
    await close(tester);
  });

  testWidgets('pitch shifter: sideways moves whole semitones', (tester) async {
    final s = await open(tester, 'org.caw.pitchshift');
    final t = targetOf(s, 'org.caw.pitchshift');
    final r = hero(tester, 'pitchshift-hero');
    await tester.dragFrom(r.center, Offset(r.width / 4, 0));
    await tester.pumpAndSettle();
    expect(t.value('semitones'), inInclusiveRange(10, 14));
    expect(t.value('semitones') % 1, 0);
    await close(tester);
  });

  testWidgets('frequency shifter: sideways shifts, up feeds back; a tile picks the direction', (tester) async {
    final s = await open(tester, 'org.caw.freqshift');
    final t = targetOf(s, 'org.caw.freqshift');
    final r = hero(tester, 'freqshift-hero');
    await tester.dragFrom(r.center, const Offset(60, -40));
    await tester.pumpAndSettle();
    expect(t.value('shift'), greaterThan(100));
    expect(t.value('feedback'), greaterThan(0.1));
    await tester.tap(find.byKey(const ValueKey('mode-direction-2')));
    await tester.pumpAndSettle();
    expect(t.value('direction'), 2);
    await close(tester);
  });

  testWidgets('trance gate: a tap turns a step off and on; a drag paints levels', (tester) async {
    final s = await open(tester, 'org.caw.trancegate');
    final t = targetOf(s, 'org.caw.trancegate');
    final r = hero(tester, 'trancegate-hero');
    final sw = (r.width - 20) / 16;
    Offset step(int k, double level) => Offset(r.left + 10 + (k + 0.5) * sw, r.bottom - 10 - (r.height - 36) * level);
    expect(t.value('s1'), 1);
    await tester.tapAt(step(0, 0.5));
    await tester.pumpAndSettle();
    expect(t.value('s1'), 0);
    await tester.tapAt(step(0, 0.5));
    await tester.pumpAndSettle();
    expect(t.value('s1'), 1);
    // Paint across steps 2..4 at about half height.
    final g = await tester.startGesture(step(1, 0.5));
    for (var k = 1; k <= 3; k++) {
      await g.moveTo(step(k, 0.5));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    for (final id in ['s2', 's3', 's4']) {
      expect(t.value(id), closeTo(0.5, 0.1), reason: id);
    }
    await close(tester);
  });

  testWidgets('bitcrush: up adds bits, sideways raises the rate', (tester) async {
    final s = await open(tester, 'org.caw.bitcrush');
    final t = targetOf(s, 'org.caw.bitcrush');
    final r = hero(tester, 'bitcrush-hero');
    await tester.dragFrom(r.center, const Offset(60, -40));
    await tester.pumpAndSettle();
    expect(t.value('bits'), greaterThan(9));
    expect(t.value('rate'), greaterThan(8000));
    await close(tester);
  });

  testWidgets('ring mod: sideways moves the frequency, up the bias; a tile picks the carrier', (tester) async {
    final s = await open(tester, 'org.caw.ringmod');
    final t = targetOf(s, 'org.caw.ringmod');
    final r = hero(tester, 'ringmod-hero');
    await tester.dragFrom(r.center, const Offset(60, -40));
    await tester.pumpAndSettle();
    expect(t.value('freq'), greaterThan(440));
    expect(t.value('bias'), greaterThan(0.1));
    await tester.tap(find.byKey(const ValueKey('mode-source-2')));
    await tester.pumpAndSettle();
    expect(t.value('source'), 2);
    await close(tester);
  });

  test('a key turns the ring mod to its sidechain carrier, and removing it turns it back to a sine', () {
    final s = stateWith('org.caw.ringmod');
    states.add(s);
    s.project.layers.add(LayerDoc(id: 'k', name: 'Kick', color: 1));
    final layer = s.project.layers.first;
    expect(s.hasSidechain('org.caw.ringmod'), isTrue);
    expect(s.setComponentKey(layer, 0, 'k'), isTrue);
    expect(layer.components.first.params['source'], 5);
    expect(s.setComponentKey(layer, 0, null), isTrue);
    expect(layer.components.first.params['source'], 0);
  });
}
