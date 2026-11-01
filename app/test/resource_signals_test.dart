// Tests platform resource-signal decoding, including unavailable and partial readings.
import 'package:caw/engine/execution.dart';
import 'package:caw/platform/resource_signals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing platform signals remain unknown', () {
    expect(ResourceSignals.decode(null), EnginePressure.unknown);
    expect(ResourceSignals.decode(const {}), EnginePressure.unknown);
    expect(ResourceSignals.decode(const {'batterySaver': false}), EnginePressure.unknown);
  });

  test('Android thermal status maps to shared pressure levels', () {
    expect(ResourceSignals.decode(const {'thermalStatus': 0}), EnginePressure.normal);
    expect(ResourceSignals.decode(const {'thermalStatus': 1}), EnginePressure.normal);
    expect(ResourceSignals.decode(const {'thermalStatus': 2}), EnginePressure.thermalWarm);
    expect(ResourceSignals.decode(const {'thermalStatus': 3}), EnginePressure.thermalHot);
    expect(ResourceSignals.decode(const {'thermalStatus': 4}), EnginePressure.thermalCritical);
    expect(ResourceSignals.decode(const {'thermalStatus': 6}), EnginePressure.thermalCritical);
  });

  test('battery saver raises pressure without inventing thermal state', () {
    expect(ResourceSignals.decode(const {'batterySaver': true}), EnginePressure.batterySaver);
    expect(
      ResourceSignals.decode(const {'thermalStatus': 0, 'batterySaver': true}),
      EnginePressure.batterySaver,
    );
    expect(
      ResourceSignals.decode(const {'thermalStatus': 2, 'batterySaver': true}),
      EnginePressure.thermalWarm,
    );
    expect(
      ResourceSignals.decode(const {'thermalStatus': 3, 'batterySaver': false}),
      EnginePressure.thermalHot,
    );
  });
}
