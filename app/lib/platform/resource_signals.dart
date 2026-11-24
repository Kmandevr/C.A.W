// Reads optional platform thermal and power signals; unsupported signals stay explicitly unknown.
import 'package:flutter/services.dart';

import '../engine/execution.dart';

class ResourceSignals {
  ResourceSignals._();

  static const MethodChannel _method = MethodChannel('caw/resource_signals');
  static const EventChannel _events = EventChannel('caw/resource_signals/events');

  static Future<EnginePressure> read() async {
    try {
      final values = await _method.invokeMapMethod<Object?, Object?>('read');
      return decode(values);
    } on MissingPluginException {
      return EnginePressure.unknown;
    } on PlatformException {
      return EnginePressure.unknown;
    }
  }

  /// The thermal status (PowerManager, Android 10+) and headroom (getThermalHeadroom over 10 s, Android 11+: 1.0
  /// is where severe throttling starts), for the Benchmark's heat test; missing values are left out.
  static Future<Map<String, Object?>> readThermal() async {
    try {
      final values = await _method.invokeMapMethod<Object?, Object?>('thermal');
      if (values == null) return const {};
      final status = values['thermalStatus'];
      final headroom = values['thermalHeadroom'];
      return {
        if (status is int) 'status': status,
        if (headroom is num && headroom.isFinite) 'headroom': (headroom * 1000).round() / 1000,
      };
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  /// Sustained Performance Mode while playing (1.1.2, Android 7+): asked for only where the device says it has it;
  /// returns whether it does (false elsewhere, or with no platform).
  static Future<bool> setSustained(bool on) async {
    try {
      return await _method.invokeMethod<bool>('sustained', {'on': on}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// The Benchmark's device block (1.1.2): the Android API level and whether Sustained Performance Mode exists.
  static Future<Map<String, Object?>> readPerformance() async {
    try {
      final v = await _method.invokeMapMethod<Object?, Object?>('performance');
      if (v == null) return const {};
      return {
        if (v['sdk'] is int) 'sdk': v['sdk'],
        if (v['sustainedPerformance'] is bool) 'sustained_performance_supported': v['sustainedPerformance'],
      };
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

    static Stream<EnginePressure> get changes => _events.receiveBroadcastStream().map((event) {
        if (event is Map) return decode(Map<Object?, Object?>.from(event));
        return EnginePressure.unknown;
      }).distinct();

  /// Maps Android thermal status and battery-saver signals to the shared, conservative policy.
  /// A missing thermal value is not interpreted as normal; battery saver can still independently raise pressure.
  static EnginePressure decode(Map<Object?, Object?>? values) {
    if (values == null) return EnginePressure.unknown;
    final thermal = values['thermalStatus'];
    final batterySaver = values['batterySaver'];

    EnginePressure? pressure;
    if (thermal is int) {
      pressure = switch (thermal) {
        0 || 1 => EnginePressure.normal,
        2 => EnginePressure.thermalWarm,
        3 => EnginePressure.thermalHot,
        >= 4 => EnginePressure.thermalCritical,
        _ => null,
      };
    }
    if (batterySaver == true &&
        (pressure == null || pressure == EnginePressure.normal)) {
      pressure = EnginePressure.batterySaver;
    }
    return pressure ?? EnginePressure.unknown;
  }
}
