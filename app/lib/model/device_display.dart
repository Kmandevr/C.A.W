// Live display data from the engine (spectrum, gain reduction, levels) that device editors draw, polled while one is open.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../engine/engine.dart';
import 'arrange_fx.dart';
import 'mixer_fx.dart';
import 'device_target.dart';
import 'fx_space_display.dart'; // fx-space
import 'drums.dart';
import 'project.dart';
// fx-filters begin
import '../ui/devices/effects/filters/filters_display.dart' show decodeFiltersDisplay;
// fx-filters end

/// One frame of what a device shows besides its parameters, read from the engine at the meter rate.
class DeviceDisplayFrame {
  const DeviceDisplayFrame({this.spectrum, this.gainReductionDb, this.inputDb, this.outputDb, this.values = const {}});

  /// Magnitudes 0..1, low to high on a log frequency axis from 20 Hz to 20 kHz (an EQ's analyser).
  final List<double>? spectrum;

  /// The gain reduction now, in dB (≤ 0): a compressor's or limiter's meter.
  final double? gainReductionDb;

  /// The input and output levels in dB.
  final double? inputDb, outputDb;

  /// Anything else by name (an LFO's phase, an envelope's stage), for the device's own editor.
  final Map<String, double> values;
}

/// Where editors get display frames: [engine] reads `caw_engine_component_display` (API version 6); [none] gives no
/// frames, and editors then draw parameters only.
abstract class DeviceDisplaySource {
  const DeviceDisplaySource();

  /// Frames for [target] while an editor shows it; the editor stops listening when it closes.
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target);

  static const DeviceDisplaySource none = _NoDisplay();
  static final DeviceDisplaySource engine = EngineDisplaySource();

  /// The source editors use.
  static DeviceDisplaySource current = engine;
}

class _NoDisplay extends DeviceDisplaySource {
  const _NoDisplay();
  static final _empty = ValueNotifier<DeviceDisplayFrame?>(null);

  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) => _empty;
}

/// Frames from the engine: each device being shown is read about 30 times a second while anything listens (an
/// editor is open) and the track's engine plays it; nothing is polled otherwise.
class EngineDisplaySource extends DeviceDisplaySource {
  EngineDisplaySource({this.interval = const Duration(milliseconds: 33)});
  final Duration interval;
  final Map<String, _Poll> _polls = {};

  @override
  ValueListenable<DeviceDisplayFrame?> frames(DeviceTarget target) =>
      _polls.putIfAbsent('${target.layerId}\u0000${target.slot}\u0000${target.displayChild}', () => _Poll(target, interval));
}

class _Poll extends ValueNotifier<DeviceDisplayFrame?> {
  _Poll(this.target, this.interval) : super(null);
  final DeviceTarget target;
  final Duration interval;
  final Float32List _buffer = Float32List(Engine.maxDisplayFloats);
  Timer? _timer;
  int _listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_listeners++ == 0 && target.state.engine != null) {
      _timer = Timer.periodic(interval, (_) => _read());
      _read();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (--_listeners <= 0) {
      _listeners = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  void _read() {
    // In the background nothing is drawn: no reads over FFI until the app is back.
    final life = SchedulerBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    final engine = target.state.engine;
    final layer = target.layer;
    final id = target.componentId;
    if (engine == null || layer == null || id == null) {
      value = null;
      return;
    }
    final int? index = target.isInstrument
        ? ProjectDoc.instrumentIndex
        : target.state.engineComponentIndex(layer, target.slot);
    if (index == null) {
      value = null;
      return;
    }
    // A rack's child (fx-racks): the rack's index + (child + 1) * 65536.
    final n = engine.componentDisplay(engineLayerId(layer), target.displayChild == 0 ? index : index + target.displayChild * 65536, _buffer);
    if (n > 0) value = decodeDisplay(id, _buffer, n);  // 0: nothing new to show (or the engine is busy): keep the last
    if (n < 0) value = null;
  }
}

/// A built-in's display floats as a frame (the layouts in docs/engine.md, "Display data"). Unknown components give
/// their floats as values named "0", "1", ...
DeviceDisplayFrame decodeDisplay(String componentId, List<double> f, int n) {
  double at(int i) => i < n ? f[i] : 0;
  Map<String, double> named(List<String> names, int from) =>
      {for (var i = 0; i < names.length && from + i < n; ++i) names[i]: f[from + i]};
  // fx-space begin
  if (decodeFxSpaceDisplay(componentId, f, n) case final space?) return space;
  // fx-space end
  if (componentId == drumsComponentId) return DrumsDisplayFrame.decode(f, n) ?? const DeviceDisplayFrame();
  // fx-filters begin
  if (decodeFiltersDisplay(componentId, f, n) case final frame?) return frame;
  // fx-filters end
  switch (componentId) {
    // fx-racks begin
    case 'org.caw.rack.multiband':
      final bins = at(12).toInt();
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          spectrum: at(13) > 0.5 && 14 + 2 * bins <= n
              ? [for (var j = 0; j < bins; ++j) ((f[14 + j] + 90) / 90).clamp(0.0, 1.0).toDouble()]
              : null,
          values: {'bands': at(2), for (var c = 0; c < 4; ++c) 'xover${c + 1}': at(3 + c),
            for (var b = 0; b < 5; ++b) 'band${b + 1}_db': at(7 + b),
            if (at(13) > 0.5 && 14 + 2 * bins <= n) for (var j = 0; j < bins; ++j) 'out$j': f[14 + bins + j]});
    case 'org.caw.rack.fx':
      final sources = at(2).toInt();
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: {
        for (var s = 1; s <= sources; ++s) 'src$s': at(2 + s),
        for (var r = 0; r < 16; ++r) 'route${r + 1}': at(3 + sources + r)});
    // fx-racks end
    case 'org.caw.eq':
      final bins = at(0).toInt();
      final watched = at(3) > 0.5;
      final post = 4 + bins;
      return DeviceDisplayFrame(
        spectrum: watched && post + bins <= n
            ? [for (var j = 0; j < bins; ++j) ((f[post + j] + 90) / 90).clamp(0.0, 1.0).toDouble()]
            : null,
        inputDb: at(4 + 3 * bins + 48 + 1),
        outputDb: at(4 + 3 * bins + 48 + 2),
        values: {'output_db': at(4 + 3 * bins + 48)});
    case 'org.caw.compressor':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), gainReductionDb: -at(3),
          values: named(['gr_max', 'gr', 'detector_db', 'threshold', 'ratio', 'knee', 'makeup_db', 'lookahead_ms'], 2));
    case 'org.caw.limiter':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), gainReductionDb: -at(3),
          values: named(['gr_max', 'gr', 'ceiling_db', 'gain_db', 'true_peak'], 2));
    case 'org.caw.gate':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), gainReductionDb: -at(2),
          values: named(['gr', 'gr_max', 'detector_db', 'threshold', 'open'], 2));
    case 'org.caw.ducker':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), gainReductionDb: -at(4), values: named(['key_db', 'duck', 'gr',
        'gr_max', 'pos_ms', 'mode', 'threshold', 'depth', 'lookahead_ms', 'triggers', 'period_ms', 'phase', 'attack_ms',
        'hold_ms', 'release_ms', 'tension'], 2));
    case 'org.caw.reverb.pro':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(2),
          values: named(['input_db', 'wet_db', 'output_db', 'duck_db', 'decay_s', 'predelay_s', 'freeze', 'size'], 0));
    case 'org.caw.delay.pro':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(2),
          values: named(['input_db', 'wet_db', 'output_db', 'time_l_s', 'time_r_s', 'feedback', 'duck_db', 'freeze', 'mode'], 0));
    case 'org.caw.saturator':
      final points = at(7).toInt();
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: {
        ...named(['mode', 'drive_db', 'bias', 'tone', 'auto_gain_db'], 2),
        for (var k = 0; k < points && 8 + k < n; ++k) 'curve$k': f[8 + k],
      });
    case 'org.caw.transient':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['gain_db', 'boost_db', 'cut_db'], 2));
    case 'org.caw.filter':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['type', 'cutoff_l', 'cutoff_r', 'resonance', 'lfo', 'envelope'], 2));
    case 'org.caw.phaser':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['lfo_l', 'lfo_r', 'freq_l', 'freq_r', 'stages'], 2));
    case 'org.caw.flanger':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['lfo_l', 'lfo_r', 'delay_l_ms', 'delay_r_ms'], 2));
    case 'org.caw.utility':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['correlation', 'gain_db', 'width', 'pan'], 2));
    // fx-dynamics begin
    case 'org.caw.dynamics':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['gain_db', 'boost_db', 'cut_db', 'level_db',
        'low_threshold', 'low_ratio', 'high_threshold', 'high_ratio', 'knee', 'range', 'in_gain_db', 'out_gain_db'], 2));
    case 'org.caw.multiband':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: {
        ...named(['ott', 'xover_low_hz', 'xover_high_hz'], 2),
        for (var b = 1; b <= 3; ++b)
          ...named([for (final k in ['level_db', 'gr_db', 'boost_db', 'cut_db', 'down_db', 'up_db', 'makeup_db']) 'b${b}_$k'],
              5 + 7 * (b - 1)),
      });
    case 'org.caw.deesser':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), gainReductionDb: -at(2),
          values: named(['gr', 'gr_max', 'level_db', 'threshold', 'freq', 'range', 'wideband'], 2));
    case 'org.caw.clipper':
      final points = at(9).toInt();
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: {
        ...named(['mode', 'drive_db', 'ceiling_db', 'softness', 'oversample', 'over_db', 'master'], 2),
        for (var k = 0; k < points && 10 + k < n; ++k) 'curve$k': f[10 + k],
      });
    case 'org.caw.phasedist':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['drive', 'normalize', 'bias', 'spread', 'mod_l', 'mod_r', 'delay_l_ms', 'delay_r_ms'], 2));
    // fx-dynamics end
    // fx-creative begin: the Creative and Pitch & Time effects (docs/engine.md, Display data)
    case 'org.caw.tapestop':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['speed', 'state', 'lag_ms', 'progress', 'stop_s', 'start_s'], 2));
    case 'org.caw.reverser':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['chunk_ms', 'position', 'crossfade', 'grain'], 2));
    case 'org.caw.stutter':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['active', 'repeat', 'progress', 'slice_ms', 'triggers', 'length_ms'], 2));
    case 'org.caw.pitchshift':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['semitones_now', 'grain_ms', 'latency_ms', 'phase'], 2));
    case 'org.caw.freqshift':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['shift_l', 'shift_r', 'direction', 'feedback', 'phase'], 2));
    case 'org.caw.trancegate':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['step', 'env', 'steps'], 2));
    case 'org.caw.bitcrush':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['bits', 'rate_hz', 'adc_hz', 'dac_hz', 'holds'], 2));
    case 'org.caw.ringmod':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['source', 'freq_l', 'freq_r', 'carrier_phase', 'carrier_peak', 'oversample'], 2));
    // fx-creative end
    default:
      return DeviceDisplayFrame(values: {for (var i = 0; i < n && i < 64; ++i) '$i': f[i]});
  }
}
