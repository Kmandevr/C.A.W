// Screens of the sampler's page for the owner (not goldens): empty, mapped, each phone panel and the recording prompt, at phone (412x915) and wide (1280x800) size. Runs only with CAW_SAMPLER_SCREENS=<dir> set, writing PNGs there at 2x.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/sampler.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/audio_edit.dart';
import 'package:caw/ui/arrange/audio_waveform.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:caw/ui/devices/sampler/sampler_editor.dart';
import 'package:caw/ui/glass.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fake.dart';
import 'golden_util.dart';

final _dir = Platform.environment['CAW_SAMPLER_SCREENS'];

const _sizes = {'phone': Size(412, 915), 'wide': Size(1280, 800)};

void main() {
  if (_dir == null) return;
  final states = <AppState>[];
  tearDown(() {
    for (final s in states) {
      s.dispose();
    }
    states.clear();
  });

  AppState make({bool zones = true}) {
    final s = AppState(settings: Settings());
    states.add(s);
    s.project = ProjectDoc(id: 'p', name: 'Sampler', bpm: 120, layers: [LayerDoc(id: 'a', name: 'Keys', color: 3)]);
    s.componentCatalog.set(NativeComponentInfo.listFromJson(
        jsonDecode(File('test/fixtures/sampler_component.json').readAsStringSync()) as Map<String, dynamic>));
    s.setNativeInstrument(s.project.layers.first, samplerComponentId);
    s.audioIo = FakeAudioIo()..seconds['/abs/piano_c4.wav'] = 2..seconds['/abs/piano_c3.wav'] = 2
      ..seconds['/abs/piano_c5.wav'] = 2;
    if (zones) {
      s.setSamplerState(s.project.layers.first, SamplerState([
        SamplerZone(path: '/abs/piano_c3.wav', loKey: 0, hiKey: 53, root: 48, hiVel: 90),
        SamplerZone(path: '/abs/piano_c3.wav', loKey: 0, hiKey: 53, root: 48, loVel: 91),
        SamplerZone(path: '/abs/piano_c4.wav', loKey: 54, hiKey: 65, root: 60, loopMode: 'loop_sustain', loopStart: 20000,
            loopEnd: 70000, stretch: true),
        SamplerZone(path: '/abs/piano_c5.wav', loKey: 66, hiKey: 127, root: 72),
      ]));
    }
    return s;
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    final ro = tester.renderObject<RenderRepaintBoundary>(goldenScreen);
    await tester.runAsync(() async {
      final img = await ro.toImage(pixelRatio: 2);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      Directory(_dir!).createSync(recursive: true);
      File('${_dir!}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> open(WidgetTester tester, AppState s, Size size) async {
    Motion.setting = MotionLevel.off;
    WaveformCache.instance.clear();
    await loadAppFonts(tester);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: Neon.theme(),
      builder: (context, c) => RepaintBoundary(key: goldenKey, child: GlassBackdrop(child: c ?? const SizedBox.shrink())),
      home: Scaffold(body: DeviceEditor(target: DeviceTarget(s, 'a', DeviceTarget.instrumentSlot), onClose: () {})),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, int key) async {
    final map = tester.getRect(find.byKey(const ValueKey('sampler-zone-map')));
    final (lo, hi) = ZoneMap.keySpan(tester.widget<ZoneMap>(find.byKey(const ValueKey('sampler-zone-map'))).zones);
    await tester.tapAt(Offset(map.left + (key - lo + 0.5) * map.width / (hi - lo + 1), map.top + map.height * 0.6));
    await tester.pumpAndSettle();
  }

  for (final e in _sizes.entries) {
    testWidgets('screens ${e.key}', (tester) async {
      await open(tester, make(zones: false), e.value);
      await shot(tester, '${e.key}_empty');
      final s = make();
      await open(tester, s, e.value);
      await pick(tester, 60);
      await shot(tester, '${e.key}_zone');
      if (e.key == 'phone') {
        await tester.tap(find.byKey(const ValueKey('flagship-dot-1')));
        await shot(tester, 'phone_sound');
        await tester.tap(find.byKey(const ValueKey('flagship-dot-2')));
        await shot(tester, 'phone_tools');
      } else {
        await tester.drag(find.byKey(const ValueKey('sampler-wide')), const Offset(0, -500));
        await shot(tester, 'wide_tools');
      }
      await tester.ensureVisible(find.byKey(const ValueKey('sampler-record')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sampler-record')));
      await shot(tester, '${e.key}_record');
    });
  }
}

