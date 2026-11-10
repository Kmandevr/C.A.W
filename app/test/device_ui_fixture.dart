// Test fixture for the built-in device UIs: the engine's built-in descriptors (test/fixtures/builtin_components.json,
// dumped from the engine and checked against it when CAW_LIB is set), a fake live display, and opening a device.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/arrange_fx.dart';
import 'package:caw/model/device_display.dart';
import 'package:caw/model/device_target.dart';
import 'package:caw/model/project.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/ui/devices/device_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'flagship_fixture.dart';

/// Every built-in effect and instrument with a plugin UI.
const builtinEffects = [
  'org.caw.eq', 'org.caw.compressor', 'org.caw.limiter', 'org.caw.gate', 'org.caw.transient', 'org.caw.reverb.pro',
  'org.caw.delay.pro', 'org.caw.delay.pingpong', 'org.caw.saturator', 'org.caw.distortion', 'org.caw.filter',
  'org.caw.phaser', 'org.caw.flanger', 'org.caw.chorus', 'org.caw.utility', 'org.caw.stereo.width',
  'org.caw.stereo.balance',
];
const builtinInstruments = ['org.caw.synth.flagship', 'org.caw.drum.kick', 'org.caw.drum.snare', 'org.caw.drum.hats',
  'org.caw.drum.kit'];

List<NativeComponentInfo>? _infos;

/// The built-ins' descriptors, as the engine gives them (the flagship from its Dart fixture).
List<NativeComponentInfo> builtinInfos() => _infos ??= [
      ...NativeComponentInfo.listFromJson(
          jsonDecode(File('test/fixtures/builtin_components.json').readAsStringSync()) as Map<String, dynamic>),
      flagshipFixture(),
    ];

NativeComponentInfo builtinInfo(String id) => builtinInfos().firstWhere((c) => c.id == id);

/// A frame like a playing device's: a pink-noise-ish spectrum, levels that pulse like a drum loop over [tick]
/// (−6 dB in, −9 dB out and 4 dB of reduction at tick 0), and the component's own values ([values]).
DeviceDisplayFrame fakeFrame(String id, {int tick = 0, Map<String, double> values = const {}}) {
  final ph = (tick % 22) / 22;
  final hit = math.exp(-ph * 5);
  final dyn = id.contains('compressor') || id.contains('limiter') || id.contains('gate');
  return DeviceDisplayFrame(
      inputDb: tick == 0 ? -6 : -40 + 37 * hit,
      outputDb: tick == 0 ? -9 : -42 + 32 * hit,
      gainReductionDb: dyn ? (tick == 0 ? -4 : -9 * hit) : null,
      spectrum: [for (var i = 0; i < 128; i++) (0.78 - i / 128 * 0.45 + 0.06 * math.sin(i * 0.7)).clamp(0.0, 1.0)],
      values: {
        'detector_db': tick == 0 ? -12 : -40 + 37 * hit, 'open': ph < 0.55 ? 1 : 0, 'gain_db': 2.5, 'correlation': 0.62,
        'cutoff_l': 1600, 'lfo': 0.4, 'envelope': 0.3, 'freq_l': 900, 'freq_r': 1400, 'lfo_l': 0.3, 'lfo_r': -0.5,
        'delay_l_ms': 2.6, 'delay_r_ms': 3.4, 'wet_db': -14,
        ...values,
      });
}

/// Display frames a test sets.
class FakeDisplay extends DeviceDisplaySource {
  final frame = ValueNotifier<DeviceDisplayFrame?>(null);
  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) => frame;
}

/// An app state with one track holding [id] (as its instrument or as its only effect).
AppState stateWith(String id) {
  final s = AppState(settings: Settings());
  s.project = ProjectDoc(id: 'p', name: 'Devices', bpm: 120, modules: [], layers: [LayerDoc(id: 'a', name: 'Track', color: 2)]);
  s.componentCatalog.set(builtinInfos());
  final info = builtinInfo(id);
  if (info.isInstrument) {
    s.setNativeInstrument(s.project.layers.first, id);
  } else {
    s.addNativeEffect(s.project.layers.first, id);
  }
  return s;
}

/// The device [id] of [s]'s track.
DeviceTarget targetOf(AppState s, String id) =>
    DeviceTarget(s, 'a', builtinInfo(id).isInstrument ? DeviceTarget.instrumentSlot : 0);

/// Opens the editor of [s]'s device from [context].
void openDevice(BuildContext context, AppState s, String id) {
  final t = targetOf(s, id);
  openDeviceEditor(context, s, s.project.layers.first, t.slot);
}
