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
