// The 1.1.0 modes' and tools' device pages: each opens its own page (no fallback), its visual's drags edit the right parameters, and nothing overflows at four sizes; with CAW_MODES_SCREENS=<dir>, phone and wide PNGs at 2x for the owner.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/merged_devices.dart';
import 'package:caw/model/variant_edit.dart';
import 'package:caw/ui/devices/device_registry.dart';
import 'package:caw/ui/devices/effects/dyn_drive/bitwise_device.dart';
import 'package:caw/ui/devices/effects/effect_catalog.dart';
import 'package:caw/ui/devices/effects/pack/pack_bend_iris.dart';
import 'package:caw/ui/devices/effects/pack/pack_devices.dart';
import 'package:caw/ui/devices/kit/hero.dart' show MotionClock;
import 'package:caw/ui/devices/kit/presets.dart' show DevicePresets;
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
  ('org.caw.delay', 2, {'sync': 0}, 'delay_tape'),
  ('org.caw.delay', 3, {}, 'delay_reverse'),
  ('org.caw.delay', 4, {}, 'delay_multitap'),
  ('org.caw.reverb', 2, {}, 'reverb_room'),
  ('org.caw.reverb', 3, {}, 'reverb_plate'),
  ('org.caw.reverb', 4, {}, 'reverb_spring'),
  ('org.caw.reverb', 5, {}, 'reverb_gated'),
  ('org.caw.reverb', 6, {}, 'reverb_reverse'),
  ('org.caw.convolver', 1, {}, 'convolver_cab'),
  ('org.caw.eq', 4, {'b3_gain': 6, 'b6_gain': -4}, 'eq_linear'),
  ('org.caw.eq', 5, {}, 'eq_match'),
  ('org.caw.filter', 3, {}, 'filter_wah'),
  ('org.caw.compressor', 2, {}, 'compressor_up'),
  ('org.caw.compressor', 3, {}, 'compressor_bus'),
  ('org.caw.gate', 1, {}, 'gate_expand'),
  ('org.caw.gate', 2, {}, 'gate_pedal'),
  ('org.caw.duck', 1, {}, 'duck_level'),
  ('org.caw.duck', 2, {}, 'duck_carve'),
  ('org.caw.tremolo', 2, {}, 'tremolo_shape'),
  ('org.caw.meters', 0, {}, 'meters_analyzer'),
  ('org.caw.meters', 1, {}, 'meters_tuner'),
  ('org.caw.meters', 2, {}, 'meters_loudness'),
  ('org.caw.lofi', 0, {'age': 0.5, 'band': 3}, 'lofi'),
  ('org.caw.phasealign', 0, {'invert': 1}, 'phasealign'),
  ('org.caw.bits', 1, {'bits': 8, 'xor': 4352}, 'bits_bitwise'),
  ('org.caw.shift', 2, {'voices': 3}, 'shift_harmonizer'),
  ('org.caw.shift', 3, {'up': 0.4}, 'shift_octaver'),
  ('org.caw.exciter', 0, {}, 'glint_exciter'),
  ('org.caw.exciter', 1, {}, 'glint_bass'),
  ('org.caw.vocoder', 0, {}, 'mimic'),
  ('org.caw.clean', 0, {}, 'preen_denoise'),
  ('org.caw.clean', 1, {}, 'preen_dehum'),
  ('org.caw.clean', 2, {}, 'preen_dereverb'),
  ('org.caw.vocalclean', 0, {}, 'hush_declick'),
  ('org.caw.vocalclean', 1, {}, 'hush_deplosive'),
  ('org.caw.vocalclean', 2, {}, 'hush_breath'),
  ('org.caw.pitchfix', 0, {'scale': 1}, 'lark'),
  // The AutoStacc pack (1.1.0).
  (murmurId, 0, {}, 'pack_murmur'),
  (peckId, 0, {}, 'pack_peck'),
  (bendId, 0, {}, 'pack_bend'),
  (irisId, 0, {'freeze': 1}, 'pack_iris'),
];

/// A playing frame for [pageId] (the variant's page id, as the display decodes it) at [tick]: every float of its
/// layout set like a drum loop.
DeviceDisplayFrame modeFrame(String pageId, {int tick = 0, int variant = 0}) {
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
    case 'org.caw.delay.tape':
      raw.setAll(3, [0.375, 0.39, 0.45, 2.4 * math.sin(tick * 0.4), 0.25, 0.15, 0.3, 0.35, 0.15, 1]);
    case 'org.caw.delay.reverse':
      raw.setAll(3, [0.5, (tick % 20) / 20, ((tick + 10) % 20) / 20, 0.3, 0]);
    case 'org.caw.delay.multitap':
      for (var k = 0; k < 4; k++) {
        raw[9 + k * 5] = level - 6 * k;
      }
    case 'org.caw.reverb.gated':
      raw[3] = hit > 0.3 ? 1 : hit * 3;
    case 'org.caw.convolver.cab':
      raw.setAll(2, [2, 0.3, 0.2, 128, 2.7, 64]);
      for (var k = 0; k < 64; k++) {
        raw[8 + k] = math.exp(-k / 9) * math.cos(k * 1.3);
      }
    case 'org.caw.eq.linear':
      raw[0] = 128;
      raw[3] = 1;
      for (var j = 0; j < 128; j++) {
        raw[4 + j] = -30 - j * 0.3 + 4 * math.sin(j * 0.5) + 10 * hit;
        raw[132 + j] = raw[4 + j] + 2;
      }
      raw.setAll(456, [48, 4096, 0]);
    case 'org.caw.eq.match':
      raw.setAll(0, [0, 12.5, 9.8, 120, 20, 20000]);
      for (var j = 0; j < 120; j++) {
        raw[6 + j] = -24 - j * 0.25 + 6 * math.sin(j * 0.11);
        raw[126 + j] = -28 - j * 0.3 + 4 * math.cos(j * 0.07);
        raw[246 + j] = (raw[6 + j] - raw[126 + j]).clamp(-12, 12) * 0.8;
      }
    case 'org.caw.filter.wah':
      raw.setAll(2, [400 * math.pow(5.5, 0.3 + 0.5 * hit).toDouble(), 0.3 + 0.5 * hit, level, 0, 80, 8000, 0]);
    case 'org.caw.compressor.up':
      raw.setAll(2, [6 * (1 - hit), 8, level, -30]);
    case 'org.caw.compressor.bus' || 'org.caw.gate.expand':
      raw.setAll(2, [5, 4 * hit, level, -18]);
      if (pageId == 'org.caw.gate.expand') raw.setAll(2, [12 * (1 - hit), 20, level, -40]);
    case 'org.caw.gate.pedal':
      raw.setAll(2, [hit > 0.2 ? 0 : 60, 60, level, -50, -56, hit > 0.2 ? 1 : 0, 80]);
    case 'org.caw.duck.level':
      raw.setAll(2, [-24 + 10 * hit, -18, 4 - 6 * hit, 6, -12, -50, 1]);
    case 'org.caw.duck.carve':
      raw.setAll(2, [level, 16, 1]);
      for (var k = 0; k < 16; k++) {
        final hz = 40 * math.pow(400, k / 15).toDouble();
        raw[5 + 3 * k] = hz;
        raw[6 + 3 * k] = -6 * hit * math.exp(-math.pow((k - 7) / 2.5, 2));
        raw[7 + 3 * k] = -4 * hit * math.exp(-math.pow((k - 9) / 2, 2));
      }
    case 'org.caw.meters':
      // One layout per meter, told apart by what the test plays: the analyzer's first, then the tuner's and loudness'.
      raw.setAll(2, [128, 1, 0, 4.5, 110, -12]);
      for (var j = 0; j < 128; j++) {
        raw[8 + j] = -20 - j * 0.15 + 8 * math.sin(j * 0.3) * hit - (j < 6 ? 20 : 0);
        raw[136 + j] = raw[8 + j] - 6;
      }
    case 'org.caw.lofi':
      raw.setAll(2, [0.5, 0.3, 0.5, 0.25, 0.25, 3, 0.1, 1.2, 9000, 12]);
    case 'org.caw.phasealign':
      raw.setAll(2, [1.6, 1, 1, 1, 1.6, 0.92, 0.6 + 0.2 * hit, level]);
    case 'org.caw.shift.harmonizer':
      raw.setAll(2, [1, 220, 57 + 0.2 * math.sin(tick * 0.5), 0, 0, 3, 3, 7, -5, 0, 60, 64, 52, -1, 21.5, 0.9]);
    case 'org.caw.shift.octaver':
      raw.setAll(2, [0, 110, 0.85, 0.8, level - 4, level - 12]);
    case 'org.caw.exciter':
      raw.setAll(2, [variant.toDouble(), variant == 0 ? 3000 : 100, level, level - 14, 0.35, 8]);
      for (var k = 0; k < 8; k++) {
        raw[8 + k] = k < (variant == 0 ? 2 : 4) ? -6 - 5.0 * k + 3 * hit : -120;
      }
      raw[16] = variant == 0 ? 2 : 1;
    case 'org.caw.vocoder':
      raw.setAll(2, [20, 0, 3, 0, 0, -120]);
      for (var k = 0; k < 20; k++) {
        final hz = 80 * math.pow(150, (k + 0.5) / 20).toDouble();
        raw[8 + 3 * k] = hz;
        raw[9 + 3 * k] = -50 + 36 * math.exp(-math.pow((k - 6 - 2 * math.sin(tick * 0.3)) / 3, 2)) * hit + 6 * math.sin(k * 1.1);
        raw[10 + 3 * k] = -30 - k * 0.8;
      }
    case 'org.caw.clean' when variant == 0:
      raw.setAll(2, [0, 4.2, 1, 43, 2048, -6.5, 0, 32]);
      for (var k = 0; k < 32; k++) {
        raw[10 + k] = -75 + 12 * math.exp(-k / 5) - k * 0.3;
        raw[42 + k] = -12 * (0.6 + 0.4 * math.sin(k * 0.7 + tick * 0.2).abs()) * (1 - 0.5 * hit);
      }
    case 'org.caw.clean' when variant == 1:
      raw.setAll(2, [50.1, 1, 0, 8]);
      for (var k = 0; k < 8; k++) {
        raw[6 + k] = -70 - 3.0 * k;
      }
    case 'org.caw.clean':
      raw.setAll(2, [1.3, 1.3, 12, 43, 2048, -4, 32]);
    case 'org.caw.vocalclean':
      raw.setAll(2, [variant == 0 ? 17 : -9, variant == 0 ? 1 : 4, 0.4, 6, 0.2, 5]);
    case 'org.caw.pitchfix':
      raw.setAll(2, [1, 61.7, 62, 0.3, 0.8, 25, 0, 2, 1, 0]);
      for (var k = 0; k < 12; k++) {
        raw[12 + k] = const {0, 2, 4, 5, 7, 9, 11}.contains((k + 10) % 12) ? 1 : 0;
      }
      raw[25] = 64;
      for (var k = 0; k < 64; k++) {
        final m = k < 6 ? -1.0 : 60.5 + 1.5 * math.min(1, (k - 6) / 10) + 0.3 * math.sin((k + tick) * 0.55);
        raw[26 + k] = m;
        raw[90 + k] = m < 0 ? -1 : 62 + 0.3 * math.sin((k + tick) * 0.55) * 0.8;
      }
    case murmurId:
      raw.setAll(2, [14, 32, 0, 0, 2, 0.3, 80, 40, 14]);
      for (var i = 0; i < 32; i++) {
        raw[11 + i] = (0.2 + 0.7 * math.exp(-((i + tick) % 8) / 2.5)).clamp(0, 1);
      }
      for (var g = 0; g < 14; g++) {
        raw.setAll(43 + 4 * g, [0.25 + 0.03 * g + 0.004 * tick % 0.2, ((g * 0.13 + tick * 0.05) % 1), math.sin(g * 1.7), (g % 5 - 2) * 3.0]);
      }
    case peckId:
      const plan = [0, 1, 0, 2, 0, 0, 3, 0, 4, 0, 1, 5, 0, 2, 0, 0];
      raw.setAll(2, [(tick % 16).toDouble(), plan[tick % 16].toDouble(), (tick % 5) / 5, 125, 0, 2]);
      for (var i = 0; i < 16; i++) {
        raw[8 + i] = plan[i].toDouble();
        raw[24 + i] = 2;
      }
    case bendId:
      raw.setAll(2, [0, 8, (tick % 40) / 40, 120, 1, 2000]);
      for (var k = 0; k < 16; k++) {
        raw[8 + k] = k < 8 ? math.sin(2 * math.pi * k / 8) : 0;
      }
      for (var s = 0; s < 64; s++) {
        raw[24 + s] = math.sin(2 * math.pi * s / 64);
      }
    case irisId:
      raw.setAll(2, [1, 1, 2048, 42.7, 0, -100, 64]);
      for (var k = 0; k < 64; k++) {
        raw[9 + k] = -30 - k * 0.6 + 14 * math.exp(-math.pow((k - 20) / 3, 2)) * hit;
        raw[73 + k] = -24 - k * 0.5 + 18 * math.exp(-math.pow((k - 28) / 2.5, 2)) + 6 * math.sin(k * 0.7);
      }
    case 'org.caw.bits.bitwise':
      for (var i = 0; i < 16; i++) {
        raw[6 + i] = i >= 8 ? (0.1 + 0.08 * (15 - i)) * hit : 0;
        raw[22 + i] = i >= 8 && (i * 7 + tick) % 3 == 0 ? 1 : 0;
      }
  }
  if (pageId == 'org.caw.meters' && variant == 1) raw.setAll(2, [1, 110.4, 45, 12.3, 0.9, 440, 45.12]);
  if (pageId == 'org.caw.meters' && variant == 2) {
    raw.setAll(2, [-12 + 3 * hit, -13.5, -14.2, -9.8, -12.6, -1.4, -1.2, -0.8, 64, -14, -0.2]);
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
    display.frame.value = modeFrame(MergedDevices.isMerged(id) ? MergedDevices.pageId(id, variant) : id, variant: variant);
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

  test('every 1.1.0 mode has a page of its own', () {
    for (final v in MergedDevices.variants.where((v) => !v.retired && v.oldId != MergedDevices.duckPageId)) {
      expect(modePages.any((p) => p.$1 == v.id && p.$2 == v.variant), isTrue, reason: v.oldId);
    }
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

  testWidgets('Bitwise: the word drags bits and shift, a lane flips its XOR bit', (tester) async {
    final (_, t) = await open(tester, 'org.caw.bits', 1);
    final bits = t.value('bits');
    await drag(tester, const ValueKey('bitwise-hero'), const Offset(60, 60));
    expect(t.value('bits'), lessThan(bits));
    expect(t.value('shift'), greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('bit-lane-15')));
    await tester.pumpAndSettle();
    expect(t.value('xor').round(), 1 << 15);
    await tester.tap(find.byKey(const ValueKey('bitwise-op-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bit-lane-15')));
    await tester.pumpAndSettle();
    expect(t.value('and').round(), 65535 ^ (1 << 15));
    await close(tester);
  });

  testWidgets('Delay modes: the picture drags time and feedback; a tap drags its pan', (tester) async {
    var (_, t) = await open(tester, 'org.caw.delay', 2, values: {'sync': 0});
    final time = t.value('time'), fb = t.value('feedback');
    await drag(tester, const ValueKey('tape-hero'), const Offset(60, -50));
    expect(t.value('time'), greaterThan(time));
    expect(t.value('feedback'), greaterThan(fb));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.delay', 3);
    final sync = t.value('sync');
    await drag(tester, const ValueKey('reverse-hero'), const Offset(70, 0));
    expect(t.value('sync'), greaterThan(sync), reason: 'in sync, sideways steps the division');
    await close(tester);
    (_, t) = await open(tester, 'org.caw.delay', 4, values: {'t1_pan': 0});
    final box = tester.getRect(find.byKey(const ValueKey('taps-hero')));
    // Straight: tap 1 at 1 step of 4.48 across the plot.
    final at = Offset(box.left + 14 + (box.width - 28) / 4.48, box.top + 26 + (box.height - 38) / 2);
    final g = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(at + Offset(0, 30.0 * i / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(t.value('t1_pan'), greaterThan(0.2));
    await close(tester);
  });

  testWidgets('Reverb modes: the decay picture drags each mode\'s two knobs', (tester) async {
    for (final (v, x, y) in const [(2, 'decay', 'size'), (3, 'decay', 'diffusion'), (4, 'decay', 'tension'), (5, 'hold', 'size'),
        (6, 'length', 'curve')]) {
      final (_, t) = await open(tester, 'org.caw.reverb', v);
      final x0 = t.value(x), y0 = t.value(y);
      await drag(tester, const ValueKey('reverb-hero'), const Offset(50, -40));
      expect(t.value(x), greaterThan(x0), reason: 'variant $v: $x');
      expect(t.value(y), greaterThan(y0), reason: 'variant $v: $y');
      await close(tester);
    }
  });

  testWidgets('Cab: a cabinet card picks it, the mic drags position and distance', (tester) async {
    final (_, t) = await open(tester, 'org.caw.convolver', 1);
    await tester.tap(find.byKey(const ValueKey('mode-cab-5')));
    await tester.pumpAndSettle();
    expect(t.value('cab'), 5);
    final p = t.value('position'), d = t.value('distance');
    await drag(tester, const ValueKey('cab-hero'), const Offset(40, -40));
    expect(t.value('position'), greaterThan(p));
    expect(t.value('distance'), greaterThan(d));
    await close(tester);
  });

  testWidgets('Match: Learn picks what to learn, the limits drag, Linear shows its latency', (tester) async {
    var (_, t) = await open(tester, 'org.caw.eq', 5);
    await tester.tap(find.byKey(const ValueKey('match-learn-1')));
    await tester.pumpAndSettle();
    expect(t.value('match_learn'), 1);
    final box = tester.getRect(find.byKey(const ValueKey('match-hero')));
    final at = Offset(box.left + 10 + 0.0 * (box.width - 20) + 2, box.top + 24 + 14);
    final g = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(at + Offset(60.0 * i / 8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(t.value('match_low'), greaterThan(40));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.eq', 4);
    expect(find.textContaining('48 ms'), findsOneWidget);
    await close(tester);
  });

  testWidgets('Wah: the treadle drags the pedal (Pedal) or the sensitivity (Envelope)', (tester) async {
    var (_, t) = await open(tester, 'org.caw.filter', 3, values: {'mode': 1});
    final p = t.value('pedal');
    await drag(tester, const ValueKey('wah-hero'), const Offset(0, -60));
    expect(t.value('pedal'), greaterThan(p));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.filter', 3);
    final s = t.value('sensitivity');
    await drag(tester, const ValueKey('wah-hero'), const Offset(0, -60));
    expect(t.value('sensitivity'), greaterThan(s));
    await close(tester);
  });

  testWidgets('Pedal gate, Level and Carve: their visuals drag threshold, target, amount and the window', (tester) async {
    var (_, t) = await open(tester, 'org.caw.gate', 2);
    expect(find.byKey(const ValueKey('gate-light')), findsOneWidget);
    final thr = t.value('threshold');
    await drag(tester, const ValueKey('gate-threshold-bar'), const Offset(50, 0));
    expect(t.value('threshold'), greaterThan(thr));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.duck', 1);
    final target = t.value('target');
    await drag(tester, const ValueKey('level-hero'), const Offset(0, -40));
    expect(t.value('target'), greaterThan(target));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.duck', 2);
    final amount = t.value('amount');
    await drag(tester, const ValueKey('carve-hero'), const Offset(0, -40));
    expect(t.value('amount'), greaterThan(amount));
    await close(tester);
  });

  testWidgets('Harmonizer: a voice lane drags its interval by whole degrees; Octaver: each half drags sub and up', (tester) async {
    var (_, t) = await open(tester, 'org.caw.shift', 2);
    final d1 = t.value('v1_degree');
    await drag(tester, const ValueKey('harmonizer-hero'), const Offset(60, 0), at: const Offset(0, 12));
    expect(t.value('v1_degree'), greaterThan(d1));
    expect(t.value('v1_degree') % 1, 0);
    expect(t.value('v2_degree'), t.param('v2_degree')!.defaultValue);
    await tester.tap(find.byKey(const ValueKey('voices-4')));
    await tester.pumpAndSettle();
    expect(t.value('voices'), 4);
    await close(tester);
    (_, t) = await open(tester, 'org.caw.shift', 3);
    final sub = t.value('sub');
    final r = tester.getRect(find.byKey(const ValueKey('octaver-hero')));
    await drag(tester, const ValueKey('octaver-hero'), const Offset(0, -40), at: Offset(-r.width / 4, 0));
    expect(t.value('sub'), greaterThan(sub));
    await drag(tester, const ValueKey('octaver-hero'), const Offset(0, -40), at: Offset(r.width / 4, 0));
    expect(t.value('up'), greaterThan(0));
    await close(tester);
  });

  testWidgets('Glint, Mimic, Preen and Hush: their pictures drag their knobs; Learn learns', (tester) async {
    var (_, t) = await open(tester, 'org.caw.exciter', 0);
    final amount = t.value('amount');
    await drag(tester, const ValueKey('glint-hero'), const Offset(40, -50));
    expect(t.value('amount'), greaterThan(amount));
    expect(t.value('character'), greaterThan(t.param('character')!.defaultValue));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.vocoder', 0);
    await drag(tester, const ValueKey('mimic-hero'), const Offset(60, 0));
    expect(t.value('formant'), greaterThan(0));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.clean', 0);
    final reduction = t.value('reduction');
    await drag(tester, const ValueKey('denoise-hero'), const Offset(0, -50));
    expect(t.value('reduction'), greaterThan(reduction));
    await tester.tap(find.byKey(const ValueKey('preen-learn')));
    await tester.pumpAndSettle();
    expect((t.value('learn'), t.value('adaptive')), (1, 0));
    await tester.tap(find.byKey(const ValueKey('preen-learn')));
    await tester.pumpAndSettle();
    expect(t.value('learn'), 0);
    await close(tester);
    (_, t) = await open(tester, 'org.caw.clean', 1);
    await drag(tester, const ValueKey('dehum-hero'), const Offset(0, 50));
    expect(t.value('depth'), lessThan(1));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.clean', 2);
    final dr = t.value('amount');
    await drag(tester, const ValueKey('dereverb-hero'), const Offset(0, -40));
    expect(t.value('amount'), greaterThan(dr));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.vocalclean', 2);
    final sens = t.value('sensitivity');
    await drag(tester, const ValueKey('hush-hero'), const Offset(0, -40));
    expect(t.value('sensitivity'), greaterThan(sens));
    await close(tester);
  });

  test("Mimic's Talking crow stays out of the preset list", () {
    final s = stateWith('org.caw.vocoder', make: PreviewState.new);
    final t = targetOf(s, 'org.caw.vocoder');
    expect(t.info!.presets.map((p) => p.name), contains('Talking crow'));
    final names = DevicePresets.factory(t).map((p) => p.name).toList();
    expect(names, isNot(contains('Talking crow')));
    expect(names.length, greaterThan(5));
    s.dispose();
  });

  testWidgets('Tools: Analyzer drags its tilt, Lo-fi its Age, Phase align its delay; Learn turns Auto on', (tester) async {
    var (_, t) = await open(tester, 'org.caw.meters', 0);
    final tilt = t.value('tilt');
    await drag(tester, const ValueKey('analyzer-hero'), const Offset(0, -50));
    expect(t.value('tilt'), greaterThan(tilt));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.meters', 2);
    await tester.tap(find.byKey(const ValueKey('loudness-reset')));
    await tester.pumpAndSettle();
    expect(t.value('reset'), 1);
    await close(tester);
    (_, t) = await open(tester, 'org.caw.lofi', 0);
    await drag(tester, const ValueKey('lofi-hero'), const Offset(0, -60));
    expect(t.value('age'), greaterThan(0));
    await close(tester);
    (_, t) = await open(tester, 'org.caw.phasealign', 0);
    await drag(tester, const ValueKey('phase-hero'), const Offset(80, 0));
    expect(t.value('delay'), greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('phase-learn')));
    await tester.pumpAndSettle();
    expect((t.value('mode'), t.value('learn')), (1, 1));
    await tester.tap(find.byKey(const ValueKey('phase-invert')));
    await tester.pumpAndSettle();
    expect(t.value('invert'), 1);
    await close(tester);
  });

  testWidgets('AutoStacc pack: each page has the badge; drags and the brush change the right knob or state', (tester) async {
    var (s, t) = await open(tester, murmurId, 0);
    expect(find.byKey(const ValueKey('autostacc-badge')), findsWidgets);
    final size = t.value('size'), position = t.value('position');
    await drag(tester, const ValueKey('murmur-hero'), const Offset(-60, -50));
    expect(t.value('size'), greaterThan(size));
    expect(t.value('position'), greaterThan(position), reason: 'left is older');
    await close(tester);
    (s, t) = await open(tester, peckId, 0);
    expect(find.byKey(const ValueKey('autostacc-badge')), findsWidgets);
    final chaos = t.value('chaos');
    await drag(tester, const ValueKey('peck-hero'), const Offset(0, -50));
    expect(t.value('chaos'), greaterThan(chaos));
    await close(tester);
    (s, t) = await open(tester, bendId, 0);
    expect(find.byKey(const ValueKey('autostacc-badge')), findsWidgets);
    final box = tester.getRect(find.byKey(const ValueKey('bend-hero')));
    final plot = bendPlot(box.size);
    final p2 = t.value('p2'), p3 = t.value('p3');
    final at = box.topLeft + Offset(plot.left + plot.width * 2 / 8, plot.center.dy);
    final g = await tester.startGesture(at);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 8; i++) {
      await g.moveTo(at + Offset(0, -60.0 * i / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(t.value('p2'), isNot(p2));
    expect(t.value('p2'), closeTo(1 - 2 * (plot.height / 2 - 60) / plot.height, 0.02));
    expect(t.value('p3'), p3, reason: 'only the point under the finger');
    await close(tester);
    (s, t) = await open(tester, irisId, 0, values: {'freeze': 1});
    expect(find.byKey(const ValueKey('autostacc-badge')), findsWidgets);
    expect(t.use!.state, isNull);
    final ibox = tester.getRect(find.byKey(const ValueKey('iris-hero')));
    final ip = irisPlot(ibox.size);
    // Paint the low half up near +12 dB.
    final from = ibox.topLeft + Offset(ip.left + 2, ip.top + 3), to = ibox.topLeft + Offset(ip.center.dx, ip.top + 3);
    final h = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 1; i <= 12; i++) {
      await h.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await h.up();
    await tester.pumpAndSettle();
    final paint = irisPaintOf(base64Decode(t.use!.state!));
    expect(paint, isNotNull);
    expect(t.use!.stateVersion, 1);
    expect(paint!.take(30).every((db) => db > 10), isTrue, reason: '$paint');
    expect(paint.skip(34).every((db) => db == 0), isTrue);
    // Double-tap: flat again.
    await tester.tap(find.byKey(const ValueKey('iris-hero')));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byKey(const ValueKey('iris-hero')));
    await tester.pumpAndSettle();
    expect(irisPaintOf(base64Decode(t.use!.state!))!.every((db) => db == 0), isTrue);
    await close(tester);
    expect(s.project.layers, isNotEmpty);
  });

  test('AutoStacc pack: the browser lists the four under its own tab; the state keeps a captured spectrum', () {
    for (final id in [murmurId, peckId, bendId, irisId]) {
      expect(EffectCatalog.of(id)!.category, EffectCategory.autostacc, reason: id);
      expect(builtinInfo(id).isAutoStacc, isTrue, reason: id);
    }
    expect(builtinInfo('org.caw.eq').isAutoStacc, isFalse);
    final flat = irisStateWith(null, List.filled(64, 0));
    expect(flat.length, 20 + 256);
    // A base with a spectrum (2 bins) keeps it, only the paint changes.
    final base = Uint8List.fromList([...irisStateWith(null, List.filled(64, -3)), ...List.filled(32, 7)]);
    final painted = irisStateWith(base, List.filled(64, 5));
    expect(painted.length, base.length);
    expect(painted.sublist(276), base.sublist(276));
    expect(irisPaintOf(painted)!.toSet(), {5});
  });

  test('Bitwise arithmetic: plain quantiser at defaults, silence stays silence', () {
    expect(bitwiseSample(0, bits: 12, shift: 0, xor: 0xffff, and: 0xffff), 0);
    expect(bitwiseSample(0.5, bits: 12, shift: 0, xor: 0, and: 0xffff), closeTo(0.5, 1e-3));
    expect(bitwiseSample(0.5, bits: 4, shift: 0, xor: 0, and: 0xffff), closeTo(4 / 7, 1e-9));
  });

  if (_dir != null) {
    for (final (id, variant, values, name) in modePages) {
      for (final MapEntry(key: label, value: size) in const {'phone': Size(412, 915), 'wide': Size(1280, 800)}.entries) {
        testWidgets('screen $name $label', (tester) async {
          await open(tester, id, variant, size: size, values: values);
          for (var i = 160; i >= 0; i--) {
            display.frame.value = modeFrame(MergedDevices.isMerged(id) ? MergedDevices.pageId(id, variant) : id, tick: i + 3, variant: variant);
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
