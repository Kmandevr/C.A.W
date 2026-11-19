// Screens of the device shell for the owner (not goldens): the FX chain with rows collapsed and open, the ⋯ menu, a
// knob's hold menu, React to…, the footer and the preset preview, at phone and wide size. Runs only with
// CAW_SHELL_SCREENS=<dir> set, writing PNGs there at 2x; a fake engine shows the meters and the ear.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_slot_audio.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/user_presets.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

/// A stand-in for the engine's per-slot meters and auto gain, for the pictures.
class FakeSlotAudio extends DeviceSlotAudio {
  final on = <String>{};
  int reads = 0;
  @override
  bool get hasMeter => true;
  @override
  bool get hasAutoGain => true;
  @override
  double? outputPeak(DeviceTarget t) {
    reads++;
    final k = t.slot + 2;
    return t.slot == 2 ? 1.1 : 0.25 + 0.12 * k * (1 + math.sin(reads / 7)) / 2;
  }

  @override
  bool autoGain(DeviceTarget t) => on.contains('${t.layerId}/${t.slot}');
  @override
  void setAutoGain(DeviceTarget t, bool v) => v ? on.add('${t.layerId}/${t.slot}') : on.remove('${t.layerId}/${t.slot}');
  @override
  double? autoGainTrimDb(DeviceTarget t) => autoGain(t) ? -2.4 : null;
}

final _dir = Platform.environment['CAW_SHELL_SCREENS'];

const _sizes = {'phone': Size(412, 915), 'wide': Size(1280, 800)};

void main() {
  late AppState s;
  late DeviceDisplaySource display;

  setUp(() {
    display = DeviceDisplaySource.current;
    DeviceDisplaySource.current = DeviceDisplaySource.none;
    Motion.setting = MotionLevel.off;
    MotionClock.hold = true;
    DeviceSlotAudio.current = FakeSlotAudio()..on.add('a/1');
    s = AppState(settings: Settings());
    s.project = ProjectDoc(id: 'p', name: 'Shell', bpm: 120, modules: [], layers: [
      LayerDoc(id: 'a', name: 'Lead', color: 2),
      LayerDoc(id: 'k', name: 'Kick', color: 0),
      LayerDoc(id: 'b', name: 'Bass', color: 4),
    ]);
    s.componentCatalog.set(builtinInfos());
    final a = s.project.layers.first;
    s.setNativeInstrument(a, 'org.caw.synth.flagship');
    for (final id in ['org.caw.chorus', 'org.caw.compressor', 'org.caw.eq', 'org.caw.delay', 'org.caw.reverb']) {
      addBuiltinEffect(s, a, id);
    }
  });
  tearDown(() {
    DeviceSlotAudio.current = null;
    DeviceDisplaySource.current = display;
    MotionClock.hold = false;
    s.dispose();
  });

  Future<void> pumpAt(WidgetTester tester, Widget child, Size size) async {
    await loadAppFonts(tester);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Neon.theme(),
      builder: (context, c) => RepaintBoundary(key: goldenKey, child: GlassBackdrop(child: c ?? const SizedBox.shrink())),
      home: child,
    ));
    await settle(tester);
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
    await tester.runAsync(() async {
      final img = await ro.toImage(pixelRatio: 2);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(_dir!).createSync(recursive: true);
      File('${_dir!}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Widget stack() => Scaffold(body: SafeArea(child: ListenableBuilder(listenable: s,
      builder: (_, _) => FxStack(state: s, layer: s.project.layers.first))));

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    testWidgets('FX chain, header menu, knob menu, React to, footer, preview: $name', (tester) async {
      // Rows: the instrument, the EQ, the delay and the reverb collapsed; the chorus and the compressor open.
      for (final k in ['a/-1/org.caw.synth.flagship', 'a/2/org.caw.eq', 'a/3/org.caw.delay', 'a/4/org.caw.reverb']) {
        s.settings.setFxRowOpen('p', k, false);
      }
      await pumpAt(tester, stack(), size);
      await shot(tester, 'fx_chain_$name');
      final list = tester.state<ScrollableState>(find.descendant(
          of: find.byKey(const ValueKey('fx-stack-list')), matching: find.byType(Scrollable), matchRoot: true).first).position;
      list.jumpTo(list.maxScrollExtent);
      await settle(tester);
      await shot(tester, 'fx_chain_end_$name');
      list.jumpTo(0);

      // The full editor of the compressor: header, ⋯ menu, a knob's hold menu, React to…, footer.
      final ctx = tester.element(find.byType(FxStack));
      openDeviceEditor(ctx, s, s.project.layers.first, 1);
      await settle(tester);
      await shot(tester, 'footer_$name');
      await tester.tap(find.byKey(const ValueKey('device-more')).last);
      await settle(tester);
      await shot(tester, 'header_menu_$name');
      await tester.tapAt(const Offset(4, 4));
      await settle(tester);
      final knob = find.descendant(of: find.byKey(const ValueKey('device-editor')),
          matching: find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('dknob-'))).first;
      await tester.longPress(knob);
      await settle(tester);
      await shot(tester, 'knob_menu_$name');
      await tester.tap(find.byKey(const ValueKey('knob-menu-react')));
      await settle(tester);
      await shot(tester, 'react_to_tracks_$name');
      await tester.tap(find.text('Kick').last);
      await settle(tester);
      await shot(tester, 'react_to_kind_$name');
      await tester.tapAt(const Offset(4, 4));
      await settle(tester);

      // The preset browser with Preview on, a preset tapped (two of the user's own to pick from).
      final comp = DeviceTarget(s, 'a', 1);
      for (final (i, n) in ['Glue', 'Punchy drums', 'Vocal smooth'].indexed) {
        comp.set('threshold', -10.0 - 8 * i);
        s.userPresets.put(UserPreset(id: s.userPresets.newId(), kind: UserPresetKind.device, name: n,
            category: i == 1 ? 'Drums' : 'Mix', device: s.captureDevice(comp), modified: DateTime(2026, 11, 18)));
      }
      comp.set('threshold', -18);
      await tester.tap(find.byKey(const ValueKey('device-presets')).last);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('preset-preview')));
      await settle(tester);
      final rows = find.byWidgetPredicate((w) => w is ListTile && w.key is ValueKey &&
          '${(w.key as ValueKey).value}'.startsWith('preset-') && !'${(w.key as ValueKey).value}'.contains('Init'));
      if (rows.evaluate().isNotEmpty) await tester.tap(rows.first);
      await settle(tester);
      await shot(tester, 'preset_preview_$name');
      await tester.tap(find.byKey(const ValueKey('preset-preview-cancel')));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }, skip: _dir == null);
  }
}

/// Lets animations finish while the meters' tickers keep running (pumpAndSettle would never end).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
