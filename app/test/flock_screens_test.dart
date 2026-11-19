// Screens of Flock's page for the owner (not goldens): a built-in tone playing and at rest, and a sample, at phone (412x915) and wide (1280x800) size, and the phone's three panels. Runs only with CAW_FLOCK_SCREENS=<dir> set, writing PNGs there at 2x.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/flock.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'device_ui_fixture.dart' show FakeDisplay;
import 'flock_ui_test.dart' show cloud, flockFrame, flockState;
import 'golden_util.dart';

final _dir = Platform.environment['CAW_FLOCK_SCREENS'];

const _sizes = {'phone': Size(412, 915), 'wide': Size(1280, 800)};

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

  Future<void> open(WidgetTester tester, Size size, {DeviceDisplayFrame? frame, Map<String, double> knobs = const {},
      bool sample = false}) async {
    Motion.setting = MotionLevel.off;
    final s = flockState();
    states.add(s);
    s.audioIo = FakeAudioIo()..seconds['/abs/voice.wav'] = 3;
    final t = DeviceTarget(s, 'a', DeviceTarget.instrumentSlot);
    if (knobs.isNotEmpty) t.setAll(knobs);
    if (sample) s.setFlockSample(s.project.layers.first, '/abs/voice.wav');
    display.frame.value = frame;
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
  }

  for (final e in _sizes.entries) {
    testWidgets('screens ${e.key}', (tester) async {
      await open(tester, e.value, frame: flockFrame(grains: cloud(n: 24)), knobs: {'spray': 120, 'spread': 7});
      await shot(tester, '${e.key}_strings_playing');
      await open(tester, e.value, knobs: {'builtin': 3, 'position': 0.6, 'spray': 200, 'density': 60, 'freeze': 1});
      await shot(tester, '${e.key}_choir_resting');
      await open(tester, e.value, sample: true, frame: flockFrame(grains: cloud(n: 18), source: 0, seconds: 3));
      await shot(tester, '${e.key}_sample');
      if (e.key == 'phone') {
        await open(tester, e.value);
        await tester.tap(find.byKey(const ValueKey('flagship-dot-1')));
        await shot(tester, 'phone_play');
        await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
        await shot(tester, 'phone_shape');
      }
    });
  }
}
