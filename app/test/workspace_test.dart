import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:caw/actions/actions.dart';
import 'package:caw/actions/macro.dart';
import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/pattern_templates.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/automation_panel.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/arranger_screen.dart';
import 'package:caw/ui/settings/engine_diagnostics.dart';
import 'package:caw/ui/export_page.dart';
import 'package:caw/ui/files/library_manager.dart';
import 'package:caw/ui/arrange/channel_strip.dart';
import 'package:caw/ui/key_router.dart';
import 'package:caw/ui/volume_fader.dart';
import 'package:caw/ui/widgets.dart';

void main() {
  late AppState state;

  setUp(() {
    state = AppState(settings: Settings());
  });

  tearDown(() {
    state.dispose();
  });


  testWidgets('workspace shortcuts and focus traversal work through the action router', (tester) async {
    final routerKey = GlobalKey<KeyRouterState>();
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var selectedView = -1;

    await tester.pumpWidget(MaterialApp(
      home: KeyRouter(
        key: routerKey,
        state: state,
        screenArea: Area.global,
        onView: (index) => selectedView = index,
        child: Column(children: [
          TextButton(focusNode: first, onPressed: () {}, child: const Text('First')),
          TextButton(focusNode: second, onPressed: () {}, child: const Text('Second')),
        ]),
      ),
    ));

    first.requestFocus();
    routerKey.currentState!.vim.run(const ActionRef.action('focus.next'));
    await tester.pump();
    expect(second.hasFocus, isTrue);
    routerKey.currentState!.vim.run(const ActionRef.action('focus.prev'));
    await tester.pump();
    expect(first.hasFocus, isTrue);

    routerKey.currentState!.vim.run(const ActionRef.action('view.files'));
    expect(selectedView, 2);
  });

  testWidgets('custom toggle controls provide a 48 dp touch target', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ToggleChip(
        label: 'M', on: false, color: Colors.green, onTap: () {},
      )),
    ));
    expect(tester.getSize(find.byType(InkWell)), const Size(48, 48));
  });

  test('peak meters read in dB from -60 to 0 dBFS', () {
    expect(PeakMeter.db(1.0), 0);
    expect(PeakMeter.db(0.5), closeTo(-6.02, 0.01));
    expect(PeakMeter.db(0), PeakMeter.floorDb);
    expect(PeakMeter.fraction(PeakMeter.db(0.1)), closeTo(2 / 3, 1e-9)); // -20 dB: two thirds up, not a tenth
    expect(PeakMeter.fraction(PeakMeter.db(2.0)), 1.0);
  });

  testWidgets('a stereo track meters each side; a mono one shows one meter', (tester) async {
    // Owner, 2026-11-10 (feel pass): stereo track meters, from the engine's caw_engine_layer_meter_stereo.
    final mono = LayerDoc(id: 'm', name: 'M', color: 0);
    final stereo = LayerDoc(id: 's', name: 'S', color: 0)..instrument = ComponentUseDoc('org.caw.drum.kick');
    expect(mono.isStereo, isFalse);
    expect(stereo.isStereo, isTrue);
    expect((LayerDoc(id: 'f', name: 'F', color: 0)..isFolder = true).isStereo, isTrue);
    state.layerMeters = const [LayerMeterValue(peak: 0.5, peakL: 0.5, peakR: 0.125, active: true)];
    Widget strip(bool isStereo) => MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 10, height: 120,
        child: TrackMeter(state: state, index: 0, stereo: isStereo, color: Colors.green, vertical: true)))));
    await tester.pumpWidget(strip(true));
    state.tick.value++;
    await tester.pump();
    PeakMeterState m() => tester.state<PeakMeterState>(find.byType(PeakMeter));
    expect(m().shownDb, closeTo(-6.02, 0.01)); // left
    expect(m().shownRightDb, closeTo(-18.06, 0.01)); // right
    await tester.pumpWidget(strip(false));
    state.tick.value++;
    await tester.pump();
    expect(find.byType(PeakMeter), findsOneWidget);
    expect(m().shownDb, closeTo(-6.02, 0.01)); // the louder side
  });

  testWidgets('a stereo meter shows left and right apart, and the fall rate follows the setting', (tester) async {
    final wall = PeakMeter.clock, start = tester.binding.clock.now(), fall = PeakMeter.fallDbPerSecond;
    addTearDown(() { PeakMeter.clock = wall; PeakMeter.fallDbPerSecond = fall; });
    PeakMeter.clock = () => tester.binding.clock.now().difference(start);
    final settings = Settings()..fromJson({'meter_fall': 96});
    expect(settings.meterFall, 96);
    expect(PeakMeter.fallDbPerSecond, fall, reason: 'fromJson alone does not apply it');
    settings.adjust((x) => x.meterFall = 96);
    expect(PeakMeter.fallDbPerSecond, 96);
    var l = 0.0, r = 0.0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeakMeter(
        state: state, read: () => l, readRight: () => r, color: Colors.green))));
    PeakMeterState m() => tester.state<PeakMeterState>(find.byType(PeakMeter));
    expect(find.byType(Bar), findsNWidgets(2));
    l = 0.5;
    r = 0.25;
    state.tick.value++;
    await tester.pump();
    expect(m().shownDb, closeTo(-6.02, 0.01));
    expect(m().shownRightDb, closeTo(-12.04, 0.01));
    l = r = 0;
    state.tick.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 250));
    expect(m().shownDb, closeTo(-6.02 - 96 * .266, 0.05));
    await tester.pumpAndSettle();
  });

  testWidgets('peak meters rise at once, fall on wall-clock time, hold the peak and show a clip', (tester) async {
    final wall = PeakMeter.clock, start = tester.binding.clock.now();
    addTearDown(() => PeakMeter.clock = wall);
    PeakMeter.clock = () => tester.binding.clock.now().difference(start); // test time, not the runner's speed
    var peak = 0.0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PeakMeter(state: state, read: () => peak, color: Colors.green)),
    ));
    PeakMeterState m() => tester.state<PeakMeterState>(find.byType(PeakMeter));

    peak = 0.5; // -6 dB
    state.tick.value++;
    await tester.pump();
    expect(m().shownDb, closeTo(-6.02, 0.01));
    expect(tester.widget<Bar>(find.byType(Bar)).value, closeTo(0.9, 0.001));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'while sound comes in, the reads move it: no ticker');
    // A silent read, then no more (the engine went quiet): the bar falls at the set rate, the line holds 1.5 s.
    peak = 0;
    state.tick.value++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 500));
    expect(m().shownDb, closeTo(-6.02 - PeakMeter.fallDbPerSecond * .516, 0.01));
    expect(m().holdDb, closeTo(-6.02, 0.01));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
    expect(m().shownDb, PeakMeter.floorDb);
    expect(m().holdDb, PeakMeter.floorDb);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: 'it stops ticking once empty');
    // Within 0.1 dB of 0 dBFS, or over: pink for a while.
    peak = 0.995;
    state.tick.value++;
    await tester.pump();
    expect(m().clipped, isTrue);
    expect(tester.widget<Bar>(find.byType(Bar)).color, Neon.pink);
    peak = 0;
    state.tick.value++;
    await tester.pumpAndSettle();
    expect(m().clipped, isFalse);
  });

  testWidgets('peak readouts hold the peak in dB, then show silence even after the reads stop', (tester) async {
    final wall = PeakMeter.clock, start = tester.binding.clock.now();
    addTearDown(() => PeakMeter.clock = wall);
    PeakMeter.clock = () => tester.binding.clock.now().difference(start);
    var peak = 0.5;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PeakReadout(state: state, read: () => peak))));
    state.tick.value++;
    await tester.pump();
    expect(find.text('-6.0 dB'), findsOneWidget);
    peak = 0;
    state.tick.value++; // a silent read inside the hold, then no more (the poller settled)
    await tester.pump();
    expect(find.text('-6.0 dB'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('-∞ dB'), findsOneWidget);
  });

  test('master gain updates shared state without a full app notification', () {
    state.project = ProjectDoc(id: 'project-1', name: 'Master test', master: 0.7);
    var valueTicks = 0;
    var appNotifications = 0;
    state.values.addListener(() => valueTicks++);
    state.addListener(() => appNotifications++);

    state.setMaster(0.42);

    expect(state.project.master, closeTo(0.42, 0.0001));
    expect(valueTicks, 1);
    expect(appNotifications, 0);
  });

  test('track and master gain go up to +12 dB, as the engine allows', () {
    // Owner, 2026-11-10: faders like REAPER's, to +12 dB (a gain of 3.981); the model held them at 0 dB.
    state.project = ProjectDoc(id: 'project-1', name: 'Gain test', master: 0.7, layers: [LayerDoc(id: 'l', name: 'L', color: 0)]);
    state.setMaster(2.0);
    expect(state.project.master, closeTo(2.0, 1e-9));
    state.setMaster(9.0);
    expect(state.project.master, closeTo(kMaxMixGain, 1e-9));
    state.mixLayer(state.project.layers.first, volume: 3.0);
    expect(state.project.layers.first.volume, closeTo(3.0, 1e-9));
    state.mixLayer(state.project.layers.first, volume: -1.0);
    expect(state.project.layers.first.volume, 0.0);
    expect(kMaxMixGain, closeTo(math.pow(10, 12 / 20), 1e-12));
  });

  /// The master strip and every track's strip, as Arrange's mixer card and focus view show them.
  Widget strips() => MaterialApp(home: Scaffold(body: ListenableBuilder(listenable: state, builder: (_, _) =>
      SizedBox(height: 700, child: ListView(key: const ValueKey('mixer-strips'), scrollDirection: Axis.horizontal, children: [
        MasterStrip(state: state),
        for (final (i, l) in state.project.layers.indexed) ChannelStrip(state: state, layer: l, index: i),
      ])))));

  testWidgets('Mixer strips: the fader, pan and typed values set the shared model', (tester) async {
    final layer = LayerDoc(id: 'layer-1', name: 'Bass', color: 0, volume: 0.5);
    state.project = ProjectDoc(id: 'project-1', name: 'Workspace test', layers: [layer]);

    await tester.pumpWidget(strips());

    expect(find.text('MASTER'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);

    tester.widget<VolumeFader>(find.descendant(of: find.byKey(const ValueKey('fader-layer-1')), matching: find.byType(VolumeFader)))
      .onChanged(0.72);
    await tester.pump();
    expect(layer.volume, closeTo(0.72, 0.0001));
    expect(find.text('-2.9 dB'), findsOneWidget);

    // Typed values: the level in dB, the pan as C, 30L or 30R.
    await tester.tap(find.byKey(const ValueKey('level-layer-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'NaN');
    await tester.tap(find.text('Set'));
    await tester.pump();
    expect(find.text('Not a value'), findsOneWidget);
    expect(layer.volume, closeTo(0.72, 0.0001));
    await tester.enterText(find.byType(TextField), '-6');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(layer.volume, closeTo(0.5012, 0.0001));
    await tester.tap(find.byKey(const ValueKey('pan-value-layer-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'left');
    await tester.tap(find.text('Set'));
    await tester.pump();
    expect(find.text('Not a value'), findsOneWidget, reason: 'a bad entry stays open and changes nothing');
    expect(layer.pan, 0);
    await tester.enterText(find.byType(TextField), '30L');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(layer.pan, closeTo(-0.3, 0.0001));
    expect(find.text('30L'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('a strip routes its track to a folder bus', (tester) async {
    final folder = LayerDoc(id: 'bus', name: 'Drum bus', color: 0, isFolder: true, busEnabled: true);
    final track = LayerDoc(id: 'kick', name: 'Kick', color: 1);
    state.project = ProjectDoc(id: 'strip-route', name: 'Strip routing', layers: [folder, track]);

    await tester.pumpWidget(strips());
    final routePicker = find.ancestor(of: find.text('Master').last, matching: find.byType(DropdownButton<String?>)).first;
    await tester.tap(routePicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drum bus').last);
    await tester.pumpAndSettle();

    expect(track.parentId, folder.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mixer strips stay usable on phone widths with long effect chains', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state.project = ProjectDoc(id: 'mobile-mixer', name: 'Mobile mixer', layers: [
      LayerDoc(id: 'mobile-layer', name: 'Mobile layer', color: 0, instrument: ComponentUseDoc('org.caw.synth.flagship'),
          components: [for (var i = 1; i <= 6; i++) ComponentUseDoc('org.caw.fx$i')]),
      for (var i = 1; i <= 4; i++) LayerDoc(id: 'more-$i', name: 'Track $i', color: i),
    ]);

    await tester.pumpWidget(strips());
    expect(tester.takeException(), isNull);
    // The slot list scrolls inside its strip; the strips scroll sideways.
    await tester.ensureVisible(find.text('Fx6'));
    await tester.pumpAndSettle();
    expect(find.text('Fx6'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Track 4'), 200, scrollable: find.descendant(
      of: find.byKey(const ValueKey('mixer-strips')), matching: find.byType(Scrollable)).first);
    expect(find.text('Track 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Automation point edits update the same serialized lane model', (tester) async {
    final lane = AutomationLaneDoc(target: 'volume', points: [
      AutomationPointDoc(step: 0, value: 0.2),
      AutomationPointDoc(step: 64, value: 0.8),
    ]);
    final layer = LayerDoc(id: 'layer-1', name: 'Lead', color: 0, automation: [lane]);
    state.project = ProjectDoc(id: 'project-1', name: 'Automation test', layers: [layer]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: state,
          builder: (context, _) => TrackAutomationPanel(state: state, layer: layer),
        ),
      ),
    ));

    expect(find.text('VOLUME'), findsOneWidget);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.length, 4);
    sliders[1].onChanged!(0.55);
    await tester.pump();
    expect(lane.points.first.value, closeTo(VolumeTaper.gain(0.55), 0.0001), reason: 'volume points ride the fader taper');

    await tester.tap(find.byTooltip('Add midpoint point'));
    await tester.pump();
    expect(lane.points, hasLength(3));
    final pointSliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    pointSliders[4].onChanged!(700);
    await tester.pump();
    final updatedPointSliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    updatedPointSliders[5].onChanged!(0.6);
    await tester.pump();
    expect(lane.points.last.step, greaterThan(512));
    expect(lane.points.last.value, closeTo(VolumeTaper.gain(0.6), 1e-9));

    await tester.tap(find.byTooltip('Remove automation point').last);
    await tester.pump();
    expect(lane.points, hasLength(2));
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('Automation point editors fit narrow mobile layouts', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final lane = AutomationLaneDoc(target: 'volume', points: [
      AutomationPointDoc(step: 0, value: 0.2),
      AutomationPointDoc(step: 64, value: 0.8),
    ]);
    final layer = LayerDoc(id: 'mobile-track', name: 'Mobile lead', color: 0, automation: [lane]);
    state.project = ProjectDoc(id: 'mobile-project', name: 'Mobile automation', layers: [layer]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(listenable: state, builder: (context, _) => TrackAutomationPanel(state: state, layer: layer)),
      ),
    ));

    expect(find.text('POINT 1'), findsOneWidget);
    expect(find.text('TIME'), findsNWidgets(2));
    expect(find.text('LEVEL'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    final valueSlider = tester.widgetList<Slider>(find.byType(Slider)).last;
    valueSlider.onChanged!(0.45);
    await tester.pump();
    expect(lane.points.last.value, closeTo(VolumeTaper.gain(0.45), 0.0001));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('Engine diagnostics (Settings › About and beta) report the meters, the scope and track signal paths',
      (tester) async {
    final pattern = ModuleDoc(id: 'pat-1', name: 'Beat pattern', source: '---\\nkind: pattern\\n---\\n0 C3 1');
    final layer = LayerDoc(id: 'layer-1', name: 'Noise', color: 0, instrument: ComponentUseDoc('org.caw.synth.flagship'),
      components: [ComponentUseDoc('org.caw.chorus')], patternId: pattern.id);
    state.project = ProjectDoc(id: 'project-1', name: 'Diagnostics test', modules: [pattern], layers: [layer]);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EngineDiagnostics(state: state))));

    final scrollable = find.byType(Scrollable).first;
    expect(find.text('CPU'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('SPECTRUM · 0–24 kHz'), 200, scrollable: scrollable);
    expect(find.text('512-POINT HANN / FFT'), findsOneWidget);
    expect(tester.widgetList<CustomPaint>(find.byType(CustomPaint)).length, greaterThanOrEqualTo(3));
    await tester.scrollUntilVisible(find.text('TRACK SIGNAL PATHS'), 200, scrollable: scrollable);
    expect(find.text('MIDI'), findsOneWidget);
    expect(find.text('Beat pattern'), findsOneWidget);
    expect(find.text('Chorus'), findsOneWidget);
    expect(find.text('COMPILED MODULES'), findsNothing);
  });

  testWidgets('Arranger master gain uses the native value-only update path', (tester) async {
    state.project = ProjectDoc(id: 'project-1', name: 'Master gain test', master: 0.7);
    var appNotifications = 0;
    var valueTicks = 0;
    state.addListener(() => appNotifications++);
    state.values.addListener(() => valueTicks++);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ArrangerScreen(state: state)),
    ));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final fader = find.byWidgetPredicate((w) => w is VolumeFader && w.label == 'Master level');
    tester.widget<VolumeFader>(fader).onChanged(0.42);
    await tester.pump();

    expect(state.project.master, closeTo(0.42, 0.0001));
    expect(valueTicks, 1);
    expect(appNotifications, 0);
    expect(tester.widget<VolumeFader>(fader).value, closeTo(0.42, 0.0001));
    expect(find.text('-7.5 dB'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('seed field keeps edits, including Backspace, across rebuilds until Enter (#20)', (tester) async {
    state.editProject((p) => p.seed = 0xabc);
    // The shell rebuilds the screen on every app change; do the same here.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListenableBuilder(listenable: state, builder: (_, _) => ArrangerScreen(state: state))),
    ));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final shown = find.widgetWithText(TextField, 'abc');
    expect(shown, findsOneWidget);
    final ctrl = tester.widget<TextField>(shown).controller!;
    // Found by its controller, since the text it shows changes during the test.
    final seed = find.byWidgetPredicate((w) => w is TextField && identical(w.controller, ctrl));
    TextEditingController controller() => tester.widget<TextField>(seed).controller!;

    // Backspace through an on-screen keyboard arrives as a new editing value, not a key press.
    await tester.enterText(seed, 'ab');
    state.editProject((p) => p.bpm = p.bpm + 1); // any app change rebuilds the settings
    await tester.pump();
    expect(controller().text, 'ab');
    expect(state.project.seed, 0xabc);

    await tester.enterText(seed, '');
    state.editProject((p) => p.bpm = p.bpm + 1);
    await tester.pump();
    expect(controller().text, '');

    await tester.enterText(seed, '1f');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(state.project.seed, 0x1f);
    expect(controller().text, '1f');

    // A seed changed elsewhere (an undo, another project) still shows in the field.
    state.editProject((p) => p.seed = 0x77);
    await tester.pump();
    expect(controller().text, '77');
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('Arranger playhead updates from meter ticks without rebuilding the grid', (tester) async {
    final layer = LayerDoc(id: 'layer-1', name: 'Lead', color: 0);
    state.project = ProjectDoc(id: 'project-1', name: 'Timeline test', layers: [layer]);
    state.meters = const EngineMeters(playing: true, position: 0, loopLength: 256);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ArrangerScreen(state: state)),
    ));
    await tester.tap(find.byTooltip('Track height'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Extra tall · 120 px'));
    await tester.pumpAndSettle();

    CustomPaint painted(String name) => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((w) => w.painter.runtimeType.toString().contains(name));
    final gridBefore = painted('ArrangementGrid').painter;
    final playheadBefore = painted('PlayheadPainter').painter;

    state.meters = const EngineMeters(playing: true, position: 32, loopLength: 256);
    state.tick.value++;
    await tester.pump();

    expect(identical(gridBefore, painted('ArrangementGrid').painter), isTrue);
    expect(identical(playheadBefore, painted('PlayheadPainter').painter), isFalse);
  });

  testWidgets('File Manager exposes portable project and pattern actions', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state.project = ProjectDoc(id: 'project-1', name: 'Portable project', modules: [
      ModuleDoc(id: 'gen-1', name: 'Bass', source: '---\nkind: pattern\n---\n0 A1 1 1'),
    ]);
    state.createLibraryFolder('Synths');
    state.saveLibrarySearch('Bass search', 'bass');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LibraryManagerView(state: state, onOpenBuilder: () {})),
    ));

    expect(find.text('CURRENT PROJECT'), findsOneWidget);
    expect(find.text('Portable project'), findsOneWidget);
    expect(find.text('Export project…'), findsOneWidget);
    expect(find.text('Import project'), findsOneWidget);
    expect(find.byTooltip('Import .caw module into this folder'), findsNothing);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('Bass search'), findsOneWidget);
    final soloPreview = find.ancestor(
      of: find.byTooltip('Solo preview in Build'),
      matching: find.byType(IconButton),
    ).first;
    await tester.tap(soloPreview);
    expect(state.previewOnly, isTrue);
    state.setPreviewOnly(false);
    expect(find.byTooltip('Undo library operation'), findsOneWidget);
    expect(find.byTooltip('Redo library operation'), findsOneWidget);
    await tester.tap(find.text('Bass search'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, 'bass');

    await tester.tap(find.byTooltip('Select patterns'));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Move selected modules'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Synths'));
    await tester.pumpAndSettle();
    expect(state.project.module('gen-1')?.folderPath, 'Synths');
  });



  testWidgets('Files can search across folders and rename or delete a module safely', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final module = ModuleDoc(id: 'nested-module', name: 'Old bass', source: '---\nkind: pattern\n---\n0 A1 1 1',
      folderPath: 'Synths/Bass', tags: ['low']);
    state.project = ProjectDoc(id: 'files-search', name: 'Files search',
      modules: [module], libraryFolders: ['Synths', 'Synths/Bass']);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LibraryManagerView(state: state, onOpenBuilder: () {})),
    ));

    await tester.enterText(find.byType(TextField).first, 'bass');
    await tester.pump();
    expect(find.text('No modules match this search.'), findsOneWidget);
    await tester.ensureVisible(find.text('Search all folders'));
    await tester.tap(find.text('Search all folders'));
    await tester.pump();
    await tester.ensureVisible(find.text('Old bass'));
    expect(find.text('Old bass'), findsOneWidget);
    expect(find.text('Synths/Bass'), findsWidgets);

    final moduleActions = find.byTooltip('Pattern actions');
    await tester.ensureVisible(moduleActions);
    await tester.tap(moduleActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename pattern'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Sub bass');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(module.name, 'Sub bass');

    await tester.ensureVisible(moduleActions);
    await tester.tap(moduleActions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete pattern'));
    await tester.pumpAndSettle();
    expect(find.text('Delete pattern?'), findsOneWidget);
    await tester.tap(find.text('Delete pattern').last);
    await tester.pumpAndSettle();
    expect(state.project.module('nested-module'), isNull);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Exporter queues and removes a reproducible quick-export snapshot', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExportPage(state: state)),
    ));

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('EXPORT QUEUE · 1'), findsOneWidget);
    expect(find.textContaining('bars.wav').first, findsOneWidget);
    expect(find.text('loop · 48 kHz'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Remove queued export'));  // below the Export song panel
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove queued export'));
    await tester.pumpAndSettle();
    expect(find.textContaining('EXPORT QUEUE'), findsNothing);
  });

  testWidgets('Exporter applies saved profiles and exposes recent history', (tester) async {
    state.settings.exportProfiles = [
      const ExportProfile(name: 'Master WAV', kind: 'loop', sampleRate: 44100, float32: true),
    ];
    state.settings.exportHistory = [
      ExportHistoryEntry(fileName: 'Recent_take.wav', kind: 'loop',
        createdAtMs: DateTime(2026, 11, 1).millisecondsSinceEpoch),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExportPage(state: state)),
    ));

    expect(find.text('Choose a saved profile'), findsOneWidget);
    expect(find.text('Recent_take.wav'), findsOneWidget);
    final profilePicker = find.byType(DropdownButton<String>);
    await tester.ensureVisible(profilePicker);
    await tester.tap(profilePicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Master WAV').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('44.1 kHz'), 180,
      scrollable: find.byType(Scrollable).first);
    expect(find.text('44.1 kHz'), findsOneWidget);
    expect(find.text('32-bit float'), findsOneWidget);
  });

  testWidgets('Exporter uses a compact format selector on phone widths', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExportPage(state: state)),
    ));
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButton<ExportKind>), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(DropdownButton<ExportKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MIDI').last);
    await tester.pumpAndSettle();

    expect(find.text('Export MIDI'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<ExportKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wavetable').last);
    await tester.pumpAndSettle();
    expect(find.text('Sweep'), findsOneWidget);
    expect(find.text('Frames'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Arranger toolbar is one row on phone widths, with compact track headers', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    state.project = ProjectDoc(id: 'mobile-arranger', name: 'Mobile arrangement', layers: [
      LayerDoc(id: 'mobile-track', name: 'Mobile track', color: 0),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ArrangerScreen(state: state)),
    ));

    // One sideways-scrolling row of icon buttons, no heading (owner, 2026-11-05).
    expect(find.text('ARRANGEMENT'), findsNothing);
    expect(find.byTooltip('Add track'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('arrange-toolbar'))).height, lessThanOrEqualTo(48));
    // The header: name, M, S and a meter, with the instrument in its menu.
    expect(find.text('Mobile track'), findsOneWidget);
    expect(find.byTooltip('Mute'), findsOneWidget);
    expect(find.byTooltip('Solo'), findsOneWidget);
    expect(find.byKey(const ValueKey('meter-mobile-track')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Exporter switches between quick loop and advanced MIDI options', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExportPage(state: state)),
    ));

    expect(find.text('Quick Export'), findsWidgets);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('MIDI'), findsOneWidget);
    await tester.tap(find.text('MIDI'));
    await tester.pumpAndSettle();
    expect(find.text('Export MIDI'), findsOneWidget);
  });

  testWidgets('Exporter applies saved profiles and reuses recent export settings', (tester) async {
    state.settings.exportProfiles = [
      const ExportProfile(name: 'Pattern MIDI', kind: 'midi', sampleRate: 44100),
    ];
    state.settings.exportHistory = [
      ExportHistoryEntry(fileName: 'Earlier.mid', kind: 'midi',
        createdAtMs: DateTime(2026, 10, 31).millisecondsSinceEpoch, sampleRate: 44100),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ExportPage(state: state)),
    ));

    expect(find.text('RECENT EXPORTS'), findsOneWidget);
    expect(find.text('Earlier.mid'), findsOneWidget);
    final profilePicker = find.byType(DropdownButton<String>);
    await tester.ensureVisible(profilePicker);
    await tester.tap(profilePicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pattern MIDI').last);
    await tester.pumpAndSettle();
    expect(find.text('Export MIDI'), findsOneWidget);
  });

  test('imported projects receive a new identity and preserve project content', () async {
    state.starting = false;
    state.createLibraryFolder('Previous project folder');
    expect(state.canUndoLibrary, isTrue);
    final imported = ProjectDoc(id: 'external-id', name: 'Imported session', bpm: 128);
    await state.importProject(imported);

    expect(state.project.id, isNot('external-id'));
    expect(state.project.name, 'Imported session');
    expect(state.project.bpm, 128);
    expect(state.canUndoLibrary, isFalse);
    expect(state.canRedoLibrary, isFalse);
  });



  test('project import sanitizes virtual folder metadata', () {
    final imported = ProjectDoc.fromJson({
      'caw_app_project': 2,
      'id': 'unsafe-project',
      'name': 'Imported',
      'library_folders': ['Good/Child', '../outside', 'Bad\\\\Path'],
      'modules': [
        {'id': 'safe', 'name': 'Safe', 'source': '---\nkind: pattern\n---\n', 'folder_path': 'Good/Child'},
        {'id': 'unsafe', 'name': 'Unsafe', 'source': '---\nkind: pattern\n---\n', 'folder_path': '../../outside'},
      ],
      'layers': [],
    });

    expect(imported.libraryFolders, containsAll(['Good', 'Good/Child']));
    expect(imported.libraryFolders.any((path) => path.contains('..') || path.contains(String.fromCharCode(92))), isFalse);
    expect(imported.module('safe')?.folderPath, 'Good/Child');
    expect(imported.module('unsafe')?.folderPath, '');
  });

  test('library folder operations preserve patterns through rename and delete', () {
    state.createLibraryFolder('Drums/Kicks');
    final id = state.addModule(const PatternTemplate('Folder.caw', '---\nkind: pattern\nname: Folder test\n---\n0 C2 1 1'));
    final secondId = state.addModule(const PatternTemplate('Second.caw', '---\nkind: pattern\nname: Folder second\n---\n0 D2 1 1'));
    state.moveModulesToFolder([id, secondId], 'Drums/Kicks');
    expect(state.project.libraryFolders, containsAll(['Drums', 'Drums/Kicks']));
    expect(state.project.module(id)?.folderPath, 'Drums/Kicks');

    state.setModuleTags(id, ['bass', 'Analog', 'bass']);
    expect(state.project.module(id)?.tags, ['bass', 'Analog']);
    expect(state.setModulesTags([id, secondId], ['synth', 'analog', 'synth']), isTrue);
    expect(state.project.module(id)?.tags, ['synth', 'analog']);
    expect(state.project.module(secondId)?.tags, ['synth', 'analog']);
    expect(state.undoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.tags, ['bass', 'Analog']);
    expect(state.project.module(secondId)?.tags, isEmpty);
    expect(state.redoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.tags, ['synth', 'analog']);
    state.saveLibrarySearch('Bass modules', 'bass');
    expect(state.project.savedLibrarySearches['Bass modules'], 'bass');

    state.createLibraryFolder('Synths');
    expect(state.moveModulesToFolder([id, secondId], 'Synths'), isTrue);
    expect(state.project.module(id)?.folderPath, 'Synths');
    expect(state.project.module(secondId)?.folderPath, 'Synths');
    expect(state.canUndoLibrary, isTrue);
    expect(state.undoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.folderPath, 'Drums/Kicks');
    expect(state.canRedoLibrary, isTrue);
    expect(state.redoLibraryOperation(), isTrue);
    expect(state.project.module(id)?.folderPath, 'Synths');
    expect(state.renameLibraryFolder('Synths', 'Sounds/Synths'), isTrue);
    expect(state.project.libraryFolders, containsAll(['Sounds', 'Sounds/Synths']));
    expect(state.project.module(id)?.folderPath, 'Sounds/Synths');
    expect(state.project.module(secondId)?.folderPath, 'Sounds/Synths');
    final restored = ProjectDoc.fromJson(state.project.toJson());
    expect(restored.libraryFolders, containsAll(['Sounds', 'Sounds/Synths']));
    expect(restored.module(id)?.tags, ['synth', 'analog']);
    expect(restored.savedLibrarySearches['Bass modules'], 'bass');

    expect(state.deleteLibraryFolder('Sounds'), isTrue);
    expect(state.project.module(id)?.folderPath, '');
    expect(state.project.libraryFolders, isNot(contains('Sounds/Synths')));
    expect(state.project.module(id)?.source, contains('0 C2 1 1'));
    expect(state.project.module(secondId)?.source, contains('0 D2 1 1'));
  });


}
