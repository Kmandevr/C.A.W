// The devices the Audio page offers where the platform lists them itself (#242, Android's AudioManager): which ones, their labels by type, a key that survives reconnects, and the engine id the key names now.
import '../platform/audio_route.dart';

/// Saved choices from the platform's own list start with this; the rest is the device's type and product name
/// (and `#n` for the n-th of several alike), never its address.
const platformChoicePrefix = 'android:';

/// One device the user can pick.
class AudioChoice {
  const AudioChoice({required this.key, required this.label, required this.endpoint, this.callQuality = false});

  /// What the settings keep: the same device keeps its key across reconnects and restarts (its id does not).
  final String key;

  /// By type, plus the product name for display (a built-in device's product name is the phone's model: left out).
  final String label;
  final AudioEndpoint endpoint;

  /// A Bluetooth headset's microphone over SCO, the call path: narrowband.
  final bool callQuality;

  /// The id the engine opens it by now (AAudio's AudioDeviceInfo id; engine/src/device_choice.h).
  String get engineId => 'aaudio:${endpoint.id}';
}

/// Android's AudioDeviceInfo TYPE_* names for the Audio page (the constants as audio_route.dart reads them, from
/// developer.android.com AudioDeviceInfo, read 2026-11-12). Null: not offered (calls, telephony, the system's own
/// routes: SCO output, telephony, IP, bus, speaker-safe, remote submix, echo reference, broadcast, tuners).
String? androidTypeLabel(int type, {required bool input}) => input
    ? switch (type) {
        15 => 'Phone microphone',
        3 => 'Wired headset mic',
        5 || 6 => 'Line in',
        11 || 12 => 'USB input',
        22 => 'USB headset mic',
        7 => 'Bluetooth mic, call quality',
        26 => 'Bluetooth LE mic',
        13 || 31 => 'Dock input',
        _ => null,
      }
    : switch (type) {
        2 => 'Phone speaker',
        1 => 'Phone earpiece',
        3 => 'Wired headset',
        4 => 'Wired headphones',
        5 || 6 => 'Line out',
        8 => 'Bluetooth',
        26 => 'Bluetooth LE headset',
        27 => 'Bluetooth LE speaker',
        23 || 33 => 'Hearing aid',
        11 || 12 => 'USB audio',
        22 => 'USB headset',
        9 => 'HDMI',
        10 => 'HDMI ARC',
        29 => 'HDMI eARC',
        13 || 31 => 'Dock',
        19 => 'Aux line',
        _ => null,
      };

bool _builtIn(int type) => type == 1 || type == 2 || type == 15;

/// The choices in [devices] (the platform's outputs, or its inputs when [input]), in the platform's order. Several
/// alike (two built-in microphones) are numbered, in the same order each time.
List<AudioChoice> platformChoices(List<AudioEndpoint> devices, {required bool input}) {
  final out = <AudioChoice>[];
  final seen = <String, int>{};
  for (final d in devices) {
    final type = androidTypeLabel(d.platformType, input: input);
    if (type == null) continue;
    final name = _builtIn(d.platformType) ? '' : d.name.trim();
    final base = '$platformChoicePrefix${d.platformType}:$name';
    final n = (seen[base] ?? 0) + 1;
    seen[base] = n;
    out.add(AudioChoice(
        key: n == 1 ? base : '$base#$n',
        label: '${name.isEmpty ? type : '$type · $name'}${n == 1 ? '' : ' ($n)'}',
        endpoint: d,
        callQuality: input && d.platformType == 7));
  }
  // The first of several alike gets its number too, once there is a second.
  return [
    for (final c in out)
      if (!c.key.contains('#') && out.any((o) => o.key.startsWith('${c.key}#')))
        AudioChoice(key: c.key, label: '${c.label} (1)', endpoint: c.endpoint, callQuality: c.callQuality)
      else
        c,
  ];
}

/// The choice a saved [key] names among [choices], or null (not connected now, or not a platform choice).
AudioChoice? choiceFor(String key, List<AudioChoice> choices) =>
    key.startsWith(platformChoicePrefix) ? choices.where((c) => c.key == key).firstOrNull : null;

/// The choice the engine's stream runs on ([routedId]: AAudio's device id; 0 unknown).
AudioChoice? choiceRouted(int routedId, List<AudioChoice> choices) =>
    routedId > 0 ? choices.where((c) => c.endpoint.id == routedId).firstOrNull : null;

/// The device id to open for the saved [key]: a platform choice by its id now ('' when it is not connected: the
/// default), any other saved id as it is (the backend's own: WASAPI's endpoint id).
String engineDeviceId(String key, List<AudioChoice> choices) {
  if (!key.startsWith(platformChoicePrefix)) return key;
  return choiceFor(key, choices)?.engineId ?? '';
}
