// Screens of the Dynamics and Drive device pages for the owner (not goldens): every variant at phone and wide size, and the FX stack's inline forms. Runs only with CAW_DYN_SCREENS=<dir> set, writing PNGs there at 2x from a fake engine's display.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/model/variant_edit.dart';
import 'package:caw/ui/arrange/fx_stack.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

final _dir = Platform.environment['CAW_DYN_SCREENS'];

const _sizes = {'phone': Size(412, 915), 'wide': Size(1280, 800)};

/// A playing device's frame: a drum loop's levels, and each layout's own values.
DeviceDisplayFrame dynFrame(int tick) {
  final ph = (tick % 22) / 22;
  final hit = math.exp(-ph * 5);
  final gr = 7 * hit + 0.5;
  return DeviceDisplayFrame(inputDb: -36 + 33 * hit, outputDb: -38 + 28 * hit, gainReductionDb: -gr, values: {
    'detector_db': -36 + 33 * hit, 'level_db': -36 + 33 * hit, 'gain_db': 6 * hit - 2.5, 'open': ph < 0.55 ? 1 : 0,
    'gr': gr, 'gr_max': gr + 1.5, 'makeup_db': 4, 'key_db': -40 + 37 * hit, 'duck': hit, 'pos_ms': ph * 300, 'phase': ph,
    'mode': 2, 'threshold': -24,
  });
}

class _Display extends DeviceDisplaySource {
  final frame = ValueNotifier<DeviceDisplayFrame?>(null);
  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) => frame;
}

void main() {
  if (_dir == null) return;
  late DeviceDisplaySource saved;
  late _Display display;
  final states = <AppState>[];
  setUp(() {
    saved = DeviceDisplaySource.current;
    display = _Display();
    DeviceDisplaySource.current = display;
    MotionClock.hold = true;
  });
  tearDown(() {
    DeviceDisplaySource.current = saved;
    MotionClock.hold = false;
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
    await tester.pumpAndSettle();
  }

  Future<void> play(WidgetTester tester) async {
    for (var i = 150; i >= 0; i--) {
      display.frame.value = dynFrame(i + 3);
      await tester.pump();
    }
  }

  // Each page: the merged device, its variant and (Drive) a mode, and the file's name.
  const pages = <(String, int, Map<String, double>, String)>[
    ('org.caw.compressor', 0, {}, 'compressor_down'),
    ('org.caw.compressor', 1, {}, 'compressor_dynamics'),
    ('org.caw.compressor', 2, {}, 'compressor_gate'),
    ('org.caw.compressor', 3, {}, 'compressor_shape'),
    ('org.caw.compressor', 4, {}, 'compressor_duck'),
    ('org.caw.limiter', 0, {'gain': 6}, 'limiter'),
    ('org.caw.transient', 0, {'attack': 0.45, 'sustain': -0.3}, 'transient'),
    ('org.caw.drive', 0, {'drive': 6}, 'drive_distortion'),
    ('org.caw.drive', 1, {'drive': 14, 'mode': 1, 'bias': 0.2}, 'drive_saturate'),
    ('org.caw.drive', 2, {'drive': 9}, 'drive_clip'),
    ('org.caw.drive', 3, {'drive': 0.6}, 'drive_phase'),
    ('org.caw.bits', 0, {'bits': 4, 'rate': 6000}, 'bits'),
  ];

  for (final (id, variant, values, name) in pages) {
    for (final MapEntry(key: size, value: dims) in _sizes.entries) {
      testWidgets('$name $size', (tester) async {
        Motion.setting = MotionLevel.off;
        final s = stateWith(id);
        states.add(s);
        Motion.setting = MotionLevel.off;
        final t = targetOf(s, id);
        if (variant != 0) s.setDeviceVariant(t, variant);
        t.setAll(values);
        late BuildContext ctx;
        await pumpAt(tester, Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        })), dims);
        openDevice(ctx, s, id);
        await tester.pumpAndSettle();
        await play(tester);
        await shot(tester, '${name}_$size');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }

  for (final MapEntry(key: size, value: dims) in _sizes.entries) {
    testWidgets('inline FX stack $size', (tester) async {
      Motion.setting = MotionLevel.off;
      final s = stateWith('org.caw.compressor');
      states.add(s);
      Motion.setting = MotionLevel.off;
      final layer = s.project.layers.first;
      for (final id in ['org.caw.limiter', 'org.caw.drive', 'org.caw.transient', 'org.caw.bits']) {
        addBuiltinEffect(s, layer, id);
      }
      expect(MergedDevices.isMerged('org.caw.drive'), isTrue);
      await pumpAt(tester, Scaffold(body: SafeArea(child: ListenableBuilder(listenable: s,
          builder: (_, _) => FxStack(state: s, layer: layer)))), dims);
      await play(tester);
      await shot(tester, 'inline_stack_$size');
      final list = tester.state<ScrollableState>(find.descendant(
          of: find.byKey(const ValueKey('fx-stack-list')), matching: find.byType(Scrollable), matchRoot: true).first).position;
      for (var k = 1; k <= 3; k++) {
        list.jumpTo(math.min(list.maxScrollExtent, list.maxScrollExtent * k / 3));
        await tester.pumpAndSettle();
        await shot(tester, 'inline_stack_${size}_$k');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
