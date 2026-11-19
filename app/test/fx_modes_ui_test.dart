// The 1.1.0 modes' and tools' device pages: each opens its own page (no fallback), its visual's drags edit the right parameters, and nothing overflows at four sizes; with CAW_MODES_SCREENS=<dir>, phone and wide PNGs at 2x for the owner.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/model/variant_edit.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_ui_fixture.dart';
import 'golden_util.dart';

final _dir = Platform.environment['CAW_MODES_SCREENS'];

/// Each page: its device, variant, values and file name.
const modePages = <(String, int, Map<String, double>, String)>[
  ('org.caw.drive', 4, {}, 'drive_amp'),
  ('org.caw.drive', 5, {}, 'drive_pedal'),
  ('org.caw.drive', 6, {}, 'drive_bands'),
];

/// A playing frame for [pageId] (the variant's page id, as the display decodes it) at [tick]: every float of its
/// layout set like a drum loop.
DeviceDisplayFrame modeFrame(String pageId, {int tick = 0}) {
  final ph = (tick % 22) / 22;
  final hit = math.exp(-ph * 5);
  final level = -40 + 34 * hit;
  final raw = List<double>.filled(900, 0);
  raw[0] = level;
  raw[1] = level - 3;
  switch (pageId) {
    case 'org.caw.drive.bands':
      raw[2] = 3;
      for (var k = 0; k < 4; k++) {
        raw[6 + k * 5] = level - 4 * k;
        raw[7 + k * 5] = level - 2 - 3 * k;
        raw[10 + k * 5] = 1;
      }
  }
  final f = List<double>.of(raw);
  return decodeDisplay(pageId, f, f.length);
}

void main() {
  late DeviceDisplaySource source;
  late FakeDisplay display;
  var motion = MotionLevel.full;
  final states = <AppState>[];
  setUp(() {
    motion = Motion.setting;
    source = DeviceDisplaySource.current;
    display = FakeDisplay();
    DeviceDisplaySource.current = display;
    MotionClock.hold = true;
  });
  tearDown(() {
    Motion.setting = motion;
    DeviceDisplaySource.current = source;
    MotionClock.hold = false;
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  Future<(AppState, DeviceTarget)> open(WidgetTester tester, String id, int variant,
      {Size size = const Size(412, 915), Map<String, double> values = const {}}) async {
    final s = stateWith(id, make: PreviewState.new);
    Motion.setting = MotionLevel.off;
    states.add(s);
    final t = targetOf(s, id);
    if (variant != 0) s.setDeviceVariant(t, variant);
    s.project.layers.first.components.single.params.addAll(values);
    s.starting = false;
    s.history.reset(jsonEncode(s.project.toJson()));
    display.frame.value = modeFrame(MergedDevices.isMerged(id) ? MergedDevices.pageId(id, variant) : id);
    late BuildContext ctx;
    await pumpGolden(tester, Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })), size);
    openDevice(ctx, s, id);
    await tester.pumpAndSettle();
    return (s, t);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  test('no 1.1.0 mode waits for a page', () {
    expect(MergedDevices.pagesToCome, isEmpty);
  });

  for (final (id, variant, values, name) in modePages) {
    testWidgets('$name opens its own page and fits every size', (tester) async {
      for (final size in const [Size(360, 740), Size(412, 915), Size(844, 390), Size(1280, 800)]) {
        final (s, t) = await open(tester, id, variant, size: size, values: values);
        expect(t.info?.variantIndex, variant, reason: name);
        expect(DeviceEditors.custom(id, t.info), isNotNull, reason: name);
        expect(find.byKey(const ValueKey('device-fallback')), findsNothing, reason: name);
        expect(tester.takeException(), isNull, reason: '$name at $size');
        await close(tester);
      }
    });
  }

  /// Scrolls the device page until [key] is on screen.
  Future<void> reveal(WidgetTester tester, Key key) async {
    for (var i = 0; i < 30 && find.byKey(key).hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -100));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> drag(WidgetTester tester, Key key, Offset by, {Offset at = Offset.zero}) async {
    final c = tester.getCenter(find.byKey(key)) + at;
    final g = await tester.startGesture(c);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(c + by * (i / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('Amp: the curve drags its gain; the face has the tone stack', (tester) async {
    final (_, t) = await open(tester, 'org.caw.drive', 4);
    expect(find.byKey(const ValueKey('amp-face')), findsOneWidget);
    final before = t.value('gain');
    await drag(tester, const ValueKey('drive-hero'), const Offset(0, -80));
    expect(t.value('gain'), greaterThan(before));
    await close(tester);
  });

  testWidgets('Pedal: the footswitch bypasses, the curve drags the drive', (tester) async {
    final (_, t) = await open(tester, 'org.caw.drive', 5);
    expect(t.bypass, isFalse);
    await tester.tap(find.byKey(const ValueKey('pedal-footswitch')));
    await tester.pumpAndSettle();
    expect(t.bypass, isTrue);
    final before = t.value('drive');
    await drag(tester, const ValueKey('drive-hero'), const Offset(0, -80));
    expect(t.value('drive'), greaterThan(before));
    await close(tester);
  });

  testWidgets('Bands: a crossover handle drags its frequency, a band strip selects and solos', (tester) async {
    final (_, t) = await open(tester, 'org.caw.drive', 6);
    final x1 = t.value('x1');
    final box = tester.getRect(find.byKey(const ValueKey('bands-spectrum')));
    final ux = (math.log(x1 / 20) / math.log(1000));
    final at = Offset(box.left + 8 + ux * (box.width - 16), box.center.dy + 8);
    final g = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(at + Offset(40.0 * i / 8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(t.value('x1'), greaterThan(x1));
    expect(t.value('x2'), closeTo(1000, 1));
    await reveal(tester, const ValueKey('band-1-solo'));
    await tester.tap(find.byKey(const ValueKey('band-1-solo')));
    await tester.pumpAndSettle();
    expect(t.value('b2_solo'), 1);
    final d = t.value('b2_drive');
    await reveal(tester, const ValueKey('drive-hero'));
    await drag(tester, const ValueKey('drive-hero'), const Offset(0, -60));
    expect(t.value('b2_drive'), greaterThan(d), reason: 'the curve shows the selected band');
    await close(tester);
  });

  if (_dir != null) {
    for (final (id, variant, values, name) in modePages) {
      for (final MapEntry(key: label, value: size) in const {'phone': Size(412, 915), 'wide': Size(1280, 800)}.entries) {
        testWidgets('screen $name $label', (tester) async {
          await open(tester, id, variant, size: size, values: values);
          for (var i = 60; i >= 0; i--) {
            display.frame.value = modeFrame(MergedDevices.isMerged(id) ? MergedDevices.pageId(id, variant) : id, tick: i + 3);
            await tester.pump();
          }
          await tester.pumpAndSettle();
          final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
          await tester.runAsync(() async {
            final img = await ro.toImage(pixelRatio: 2);
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            Directory(_dir!).createSync(recursive: true);
            File('${_dir!}/${name}_$label.png').writeAsBytesSync(data!.buffer.asUint8List());
          });
          await close(tester);
        });
      }
    }
  }
}
