// Screens of Timber's page for the owner (not goldens): each model playing at phone (412x915) and wide (1280x800) size, and the phone's three panels. Runs only with CAW_TIMBER_SCREENS=<dir> set, writing PNGs there at 2x.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/variant_edit.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/timber/timber_editor.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart' show FakeDisplay;
import 'golden_util.dart';
import 'timber_ui_test.dart' show timberFrame, timberState;

final _dir = Platform.environment['CAW_TIMBER_SCREENS'];

const _sizes = {'phone': Size(412, 915), 'wide': Size(1280, 800)};

/// Each model's own display floats while a note sounds (docs/engine.md, Display data).
const _own = <int, List<double>>{
  TimberModel.piano: [0, 4000, 6, 3, 0, 0, 0],
  TimberModel.epiano: [0, 0.3, 0.5],
  TimberModel.organ: [1, 3, 0, 0, 0.15, 0.6, 6.7],
  TimberModel.plucked: [0, 0.2, 0],
  TimberModel.bowed: [0, 0.5, 0.5],
  TimberModel.mallets: [1, 0.2, 4],
  TimberModel.winds: [3, 0.7, 0.5],
};

void main() {
  if (_dir == null) return;
  final states = <AppState>[];
  late DeviceDisplaySource source;
  final display = FakeDisplay();
  setUp(() {
    source = DeviceDisplaySource.current;
    DeviceDisplaySource.current = display;
  });
  tearDown(() {
    DeviceDisplaySource.current = source;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
    await tester.runAsync(() async {
      final img = await ro.toImage(pixelRatio: 2);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(_dir!).createSync(recursive: true);
      File('${_dir!}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<AppState> open(WidgetTester tester, Size size, int model) async {
    Motion.setting = MotionLevel.off;
    final s = timberState();
    states.add(s);
    final t = DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
    if (model > 0) s.setDeviceVariant(t, model);
    if (model == TimberModel.organ) t.setAll({'db4': 6, 'db2': 4, 'db1': 2, 'perc': 1});
    if (model == TimberModel.epiano) t.set('tremolo', 0.5);
    if (model == TimberModel.mallets) t.setAll({'instrument': 1, 'motor': 4});
    if (model == TimberModel.winds) t.set('instrument', 3);
    display.frame.value = timberFrame(model: model, own: _own[model]!, key: 64, peakDb: -10);
    await loadAppFonts(tester);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Neon.theme(),
      builder: (context, c) => RepaintBoundary(key: goldenKey, child: GlassBackdrop(child: c ?? const SizedBox.shrink())),
      home: Scaffold(body: DeviceEditor(target: t, onClose: () {})),
    ));
    await tester.pumpAndSettle();
    return s;
  }

  for (final e in _sizes.entries) {
    testWidgets('screens ${e.key}', (tester) async {
      for (var m = 0; m < timberModels.length; m++) {
        await open(tester, e.value, m);
        await shot(tester, '${e.key}_${m}_${timberModels[m].replaceAll(RegExp('[^A-Za-z]'), '').toLowerCase()}');
      }
      if (e.key == 'phone') {
        await open(tester, e.value, 0);
        await tester.tap(find.byKey(const ValueKey('flagship-dot-1')));
        await shot(tester, 'phone_sound');
        await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
        await shot(tester, 'phone_space');
      }
    });
  }
}
