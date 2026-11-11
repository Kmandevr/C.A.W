// The EQ & Filter group's display floats decoded into frames (the engine's layouts, docs/engine.md "Display data") and each effect's device family.
import '../../../../model/device_display.dart';
import '../../kit/device_style.dart' show DeviceFamily;

/// The family of a group effect, or null for any other id.
DeviceFamily? filtersFamily(String id) => switch (id) {
      'org.caw.eq.dj' || 'org.caw.tilt' || 'org.caw.geq' => DeviceFamily.eq,
      'org.caw.ladder' || 'org.caw.nlfilter' || 'org.caw.comb' || 'org.caw.resonator' || 'org.caw.formant' ||
      'org.caw.disperser' => DeviceFamily.filter,
      _ => null,
    };

/// A group effect's display floats as a frame (the engine's layouts), or null for any other id.
DeviceDisplayFrame? decodeFiltersDisplay(String id, List<double> f, int n) {
  double at(int i) => i < n ? f[i] : 0;
  Map<String, double> named(List<String> names, int from) =>
      {for (var i = 0; i < names.length && from + i < n; ++i) names[i]: f[from + i]};
  switch (id) {
    case 'org.caw.ladder':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['mode', 'slope', 'cutoff', 'resonance', 'drive_db', 'oscillating', 'oversampling'], 2));
    case 'org.caw.nlfilter':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['type', 'shape', 'cutoff', 'q', 'drive_db'], 2));
    case 'org.caw.comb':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['hz', 'feedback', 'damping'], 2));
    case 'org.caw.resonator':
      final modes = at(5).toInt();
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: {
        ...named(['mode', 'note', 'ceiling_db', 'modes'], 2),
        for (var j = 0; j < modes && 6 + modes + j < n; ++j) ...{'hz$j': f[6 + j], 'level$j': f[6 + modes + j]},
      });
    case 'org.caw.formant':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['f1', 'f2', 'f3', 'x', 'y'], 2));
    case 'org.caw.disperser':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['stages', 'freq', 'q', 'spread'], 2));
    case 'org.caw.eq.dj':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          values: named(['low_db', 'mid_db', 'high_db', 'kill_low', 'kill_mid', 'kill_high', 'low_x', 'high_x'], 2));
    case 'org.caw.tilt':
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1), values: named(['tilt', 'freq', 'q', 'channel'], 2));
    case 'org.caw.geq':
      final bins = at(2).toInt(), watched = at(3) > 0.5;
      return DeviceDisplayFrame(inputDb: at(0), outputDb: at(1),
          spectrum: watched && 4 + 2 * bins <= n ? [for (var j = 0; j < bins; ++j) ((f[4 + j] + 90) / 90).clamp(0.0, 1.0).toDouble()] : null,
          values: watched && 4 + 2 * bins <= n ? {for (var j = 0; j < bins; ++j) 'c$j': f[4 + bins + j]} : const {});
    default:
      return null;
  }
}
