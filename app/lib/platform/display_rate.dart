// The screen's display modes and asking for a refresh rate: Android's display-rate channel; elsewhere the screen's own rate.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// One display mode: a resolution, a refresh rate, the platform's id for it (0: unknown) and its seamless
/// alternative rates (`Display.Mode.getAlternativeRefreshRates()`, API 31: an LTPO/VRR panel may list 120 Hz only
/// there, on a mode that reports 60).
class DisplayMode {
  const DisplayMode(this.width, this.height, this.hz, {this.id = 0, this.alternatives = const []});
  final int width, height, id;
  final double hz;
  final List<double> alternatives;

  bool sameSize(DisplayMode o) => o.width == width && o.height == height;

  static String _r(double hz) => hz.toStringAsFixed(hz == hz.roundToDouble() ? 0 : 2);

  @override
  String toString() => '${id == 0 ? '' : '#$id '}$width×$height @ ${_r(hz)} Hz'
      '${alternatives.isEmpty ? '' : ' (alternatives ${alternatives.map(_r).join(', ')} Hz)'}';
}

/// What the platform says about the screen and what may hold its rate down. Everything is optional: a platform that
/// knows less says less.
class DisplayInfo {
  const DisplayInfo({
    this.modes = const [],
    this.active,
    this.alternatives = const [],
    this.currentHz = 0,
    this.powerSave = false,
    this.thermal = 0,
    this.maker = '',
  });

  /// Every mode `Display.getSupportedModes()` lists, at every resolution.
  final List<DisplayMode> modes;

  /// The mode the display is in now (`Display.getMode()`); its resolution picks [rates].
  final DisplayMode? active;

  /// The active mode's seamless alternatives (`Display.Mode.getAlternativeRefreshRates()`, API 31): rates at the
  /// same resolution, kept even where a vendor lists fewer modes.
  final List<double> alternatives;

  /// The rate the display runs at as it was read (`Display.getRefreshRate()`): it moves with every request and with
  /// the system's own choices, so it is never taken as what the screen can do.
  final double currentHz;

  /// Battery saver (`PowerManager.isPowerSaveMode()`); on Samsung it sets Motion smoothness to Standard.
  final bool powerSave;

  /// `PowerManager.getCurrentThermalStatus()` (API 29; 0 none, 3 severe and up).
  final int thermal;

  /// `Build.MANUFACTURER`, as given.
  final String maker;

  static const severe = 3;

  bool get samsung => maker.toLowerCase() == 'samsung';
  bool get hot => thermal >= severe;

  /// The rates the app can ask for: every mode at the active mode's resolution (every mode when that is unknown)
  /// and each one's alternatives, plus the active mode's; ascending, one per 0.1 Hz.
  List<double> get rates {
    final a = active;
    final all = [
      for (final m in modes)
        if (a == null || m.sameSize(a)) ...[m.hz, ...m.alternatives],
      if (a != null) ...[a.hz, ...a.alternatives],
      ...alternatives,
    ].where((r) => r.isFinite && r > 0).toList()..sort();
    final out = <double>[];
    for (final r in all) {
      if (out.isEmpty || (r - out.last).abs() >= 0.1) out.add(r);
    }
    return out;
  }

  /// The mode id to ask for [hz] with: a mode at the active resolution whose own rate it is, else 0, which asks by
  /// rate alone (`preferredRefreshRate`), as a rate only an alternative lists must be.
  int modeFor(double hz) {
    final a = active;
    for (final m in modes) {
      if ((a == null || m.sameSize(a)) && m.id != 0 && (m.hz - hz).abs() <= 0.5) return m.id;
    }
    return 0;
  }

  /// The raw read as copyable text, for Engine diagnostics (what the phone reports, nothing worked out).
  String report({double? requested}) => [
        'Display modes (${modes.length}):',
        for (final m in modes) '  $m${m.id != 0 && m.id == active?.id ? '  [active]' : ''}',
        'Active: ${active ?? 'unknown'}',
        if (alternatives.isNotEmpty) 'Active alternatives: ${alternatives.map(DisplayMode._r).join(', ')} Hz',
        'Current rate: ${currentHz > 0 ? '${DisplayMode._r(currentHz)} Hz' : 'unknown'}',
        if (requested != null) 'Asked for: ${requested > 0 ? '${DisplayMode._r(requested)} Hz' : 'no preference'}',
        'Rates offered here: ${rates.isEmpty ? 'none' : '${rates.map(DisplayMode._r).join(', ')} Hz'}',
        'Battery saver: ${powerSave ? 'on' : 'off'}',
        'Thermal status: $thermal${thermal >= severe ? ' (severe or worse)' : ''}',
        'Manufacturer: ${maker.isEmpty ? 'unknown' : maker}',
      ].join('\n');

  /// The highest-rate mode at another resolution, when it beats every rate at this one (a screen that offers its
  /// top rate only at some resolutions); null otherwise.
  DisplayMode? get fasterElsewhere {
    final a = active;
    if (a == null || modes.isEmpty) return null;
    final here = rates.isEmpty ? 0.0 : rates.last;
    DisplayMode? best;
    for (final m in modes) {
      if (!m.sameSize(a) && m.hz > here + 1 && (best == null || m.hz > best.hz)) best = m;
    }
    return best;
  }
}

/// What the frame-rate setting needs from the platform (`lib/ui/frame_rate.dart` decides what to ask for).
abstract class DisplayRateDevice {
  /// The screen's modes and what may limit them; [DisplayInfo] with no modes when unknown.
  Future<DisplayInfo> read();

  /// Whether [request] can change the rate here.
  bool get canRequest;

  /// Asks for the highest rate not above [hz] (0: no preference, the system chooses). Only a request: the system
  /// (battery saver, its own Motion smoothness setting, heat) has the last word.
  Future<void> request(double hz);
}

/// Android: `caw/display` (MainActivity, DisplayRate.kt) lists `Display.getSupportedModes` at every resolution with
/// ids and alternative rates, the active mode and what may limit the rate. A request names the mode to use
/// ([DisplayInfo.modeFor]; 0 asks by rate alone, `preferredRefreshRate`) and the rate.
class AndroidDisplayRate implements DisplayRateDevice {
  AndroidDisplayRate({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/display');
  final MethodChannel _channel;

  /// After the channel fails once (an old build, a test), nothing more is asked.
  bool _failed = false;

  @override
  bool get canRequest => !_failed;

  /// The last read, which picks the mode id each request names ([DisplayInfo.modeFor]).
  DisplayInfo _last = const DisplayInfo();

  @override
  Future<DisplayInfo> read() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('info');
      return _last = r == null ? const DisplayInfo() : parse(r);
    } catch (_) {
      _failed = true;
      return const DisplayInfo();
    }
  }

  static double _hz(Object? v) => v is num && v.isFinite && v > 0 && v < 10000 ? v.toDouble() : 0;

  static DisplayMode? _mode(Object? v) {
    if (v is! Map) return null;
    final w = v['w'], h = v['h'], hz = _hz(v['hz']), id = v['id'], alt = v['alt'];
    if (w is! int || h is! int || w <= 0 || h <= 0 || hz == 0) return null;
    return DisplayMode(w, h, hz,
        id: id is int && id > 0 ? id : 0,
        alternatives: [if (alt is List) for (final a in alt.take(16)) if (_hz(a) > 0) _hz(a)]);
  }

  /// The channel's answer, read with limits (64 modes at most; anything malformed is skipped).
  static DisplayInfo parse(Map<String, Object?> r) {
    final modes = r['modes'], alt = r['alternatives'], thermal = r['thermal'], maker = r['maker'];
    return DisplayInfo(
      modes: [
        if (modes is List)
          for (final m in modes.take(64)) ?_mode(m),
      ],
      active: _mode(r['active']),
      alternatives: [
        if (alt is List)
          for (final v in alt.take(64))
            if (_hz(v) > 0) _hz(v),
      ],
      currentHz: _hz(r['current']),
      powerSave: r['powerSave'] == true,
      thermal: thermal is int ? math.max(0, thermal) : 0,
      maker: maker is String ? maker.substring(0, math.min(maker.length, 40)) : '',
    );
  }

  @override
  Future<void> request(double hz) async {
    if (_failed) return;
    try {
      await _channel.invokeMethod<Object?>('request', {'hz': hz, 'modeId': hz > 0 ? _last.modeFor(hz) : 0});
    } catch (_) {
      _failed = true;
    }
  }
}

/// Windows and tests: Flutter draws at the monitor's rate and there is no request to make; the rate shown is the
/// one `dart:ui` reports for the first display (0 or none: unknown).
class FixedDisplayRate implements DisplayRateDevice {
  const FixedDisplayRate();

  @override
  bool get canRequest => false;

  @override
  Future<DisplayInfo> read() async {
    final displays = ui.PlatformDispatcher.instance.displays;
    final hz = displays.isEmpty ? 0.0 : displays.first.refreshRate;
    return hz.isFinite && hz > 0 ? DisplayInfo(alternatives: [hz], currentHz: hz) : const DisplayInfo();
  }

  @override
  Future<void> request(double hz) async {}
}

/// The device for this platform.
DisplayRateDevice platformDisplayRate() => Platform.isAndroid ? AndroidDisplayRate() : const FixedDisplayRate();
