// The built-in effects suite (#173) in the app: each opens its plugin UI from the FX stack, and display floats decode into frames.
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/motion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every device shows the same live frame: input -6 dB, output -9 dB, 3 dB of gain reduction, a flat spectrum.
class _FakeDisplay extends DeviceDisplaySource {
  final _frame = ValueNotifier<DeviceDisplayFrame?>(DeviceDisplayFrame(
      inputDb: -6, outputDb: -9, gainReductionDb: -3, spectrum: List.filled(128, 0.5), values: const {'wet_db': -12}));
  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) => _frame;
}

const suite = [
  'org.caw.eq', 'org.caw.compressor', 'org.caw.limiter', 'org.caw.reverb.pro', 'org.caw.delay.pro', 'org.caw.saturator',
  'org.caw.gate', 'org.caw.transient', 'org.caw.filter', 'org.caw.phaser', 'org.caw.flanger', 'org.caw.utility',
];

void main() {
  test('an EQ\'s floats give its post spectrum as 0..1 and its levels', () {
    final f = List<double>.filled(439, -120);
    f[0] = 128;
    f[1] = 20;
    f[2] = 20000;
    f[3] = 1;
    f[4 + 128 + 10] = 0; // the post spectrum's bin 10 at 0 dB
    f[4 + 128 + 11] = -45;
    f[436] = -2;
    f[437] = -6;
    f[438] = -8;
    final frame = decodeDisplay('org.caw.eq', f, 439);
    expect(frame.spectrum!.length, 128);
    expect(frame.spectrum![10], 1.0);
    expect(frame.spectrum![11], closeTo(0.5, 1e-9));
    expect(frame.spectrum![0], 0.0);
    expect(frame.inputDb, -6);
    expect(frame.outputDb, -8);
    f[3] = 0; // nobody was watching when it was published: no spectrum
    expect(decodeDisplay('org.caw.eq', f, 439).spectrum, isNull);
  });

  test('a compressor\'s and a limiter\'s floats give their gain reduction as a negative dB', () {
    final c = decodeDisplay('org.caw.compressor', [-3, -9, 7, 6, -4, -18, 4, 6, 6.75, 0, 0], 11);
    expect((c.inputDb, c.outputDb, c.gainReductionDb), (-3, -9, -6));
    expect(c.values['threshold'], -18);
    final l = decodeDisplay('org.caw.limiter', [1, -1, 3, 2, -1, 6, 1], 7);
    expect(l.gainReductionDb, -2);
    expect(l.values['ceiling_db'], -1);
  });

  final lib = Platform.environment['CAW_LIB'];
  test('every effect of the suite opens a visual editor, not the fallback page', () async {
    final e = Engine.create();
    final list = await e.nativeComponents();
    for (final id in suite) {
      final info = list.where((c) => c.id == id).firstOrNull;
      expect(info, isNotNull, reason: id);
      expect(DeviceEditors.custom(id, info), isNotNull, reason: '$id has no editor');
    }
    e.dispose();
  }, skip: lib == null || lib.isEmpty ? 'set CAW_LIB to the built engine library' : null);

  testWidgets('each effect\'s editor opens from the FX stack with live data', (tester) async {
    late List infos;
    await tester.runAsync(() async {
      final e = Engine.create();
      infos = await e.nativeComponents();
      e.dispose();
    });
    final motion = Motion.setting;
    Motion.setting = MotionLevel.off;
    final source = DeviceDisplaySource.current;
    DeviceDisplaySource.current = _FakeDisplay();
    addTearDown(() {
      DeviceDisplaySource.current = source;
      Motion.setting = motion;
    });
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final id in suite) {
      final s = AppState(settings: Settings());
      Motion.setting = MotionLevel.off; // the state applies its settings' motion; animated visuals stand still
      s.project = ProjectDoc(id: 'p', name: 'Fx', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'T', color: 0)]);
      s.componentCatalog.set([for (final c in infos) c]);
      s.addNativeEffect(s.project.layers.first, id);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 900,
          child: ListenableBuilder(listenable: s, builder: (_, _) => FxStack(state: s, layer: s.project.layers.first))))));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fx-open-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('device-editor')), findsOneWidget, reason: id);
      expect(find.byKey(const ValueKey('device-fallback')), findsNothing, reason: id);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('fx-page-')),
          findsOneWidget, reason: '$id shows its plugin UI');
      expect(tester.takeException(), isNull, reason: id);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      s.dispose();
    }
  }, skip: lib == null || lib.isEmpty);
}
