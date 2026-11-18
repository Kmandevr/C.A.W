// Which output and input device the sound goes through, and when that changes, so latency compensation can pick
// that device's offset: Android over "caw/audio_route" (AudioRoute.kt: AudioManager.getDevices, Android 13's
// getAudioDevicesForAttributes, AudioDeviceCallback); Windows and the desktop builds by the device's name.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What kind of link a device is, which sets its latency preset.
enum AudioDeviceKind { builtIn, wired, bluetooth, bluetoothLe, usb, hdmi, remote, unknown }

extension AudioDeviceKindLabel on AudioDeviceKind {
  String get label => switch (this) {
        AudioDeviceKind.builtIn => 'Built-in',
        AudioDeviceKind.wired => 'Wired',
        AudioDeviceKind.bluetooth => 'Bluetooth',
        AudioDeviceKind.bluetoothLe => 'Bluetooth LE',
        AudioDeviceKind.usb => 'USB',
        AudioDeviceKind.hdmi => 'HDMI',
        AudioDeviceKind.remote => 'Cast or network',
        AudioDeviceKind.unknown => 'Unknown',
      };

  bool get isBluetooth => this == AudioDeviceKind.bluetooth || this == AudioDeviceKind.bluetoothLe;
}

/// One device as the route reports it. [key] names it for its saved offset: the kind and the product name, never a
/// hardware address.
class AudioEndpoint {
  const AudioEndpoint({this.id = 0, this.name = '', this.kind = AudioDeviceKind.unknown, this.platformType = -1});
  final int id;
  final String name;
  final AudioDeviceKind kind;

  /// Android's AudioDeviceInfo TYPE_* (-1 elsewhere).
  final int platformType;

  String get key => kind == AudioDeviceKind.builtIn ? 'builtIn' : '${kind.name}:${name.trim()}';

  /// The Bluetooth link an Android device type names (#237), for the latency UI: 'le_audio' (TYPE_BLE_HEADSET 26,
  /// TYPE_BLE_SPEAKER 27, API 31; TYPE_BLE_BROADCAST 30, API 33; TYPE_BLE_HEARING_AID 33, API 37), 'a2dp'
  /// (TYPE_BLUETOOTH_A2DP 8), 'sco' (TYPE_BLUETOOTH_SCO 7, calls), 'asha' (TYPE_HEARING_AID 23, the older hearing
  /// aid protocol), else '' (not Bluetooth, or not Android). [Fact, developer.android.com AudioDeviceInfo, read
  /// 2026-11-17] for the values and levels; the BLE audio overview names TYPE_BLE_HEADSET as "a LEA device". The
  /// app can't choose LE Audio over A2DP: the system routes a dual-mode headset ([Assumption] by its own policy).
  String get bluetoothProfile => switch (platformType) {
        26 || 27 || 30 || 33 => 'le_audio',
        8 => 'a2dp',
        7 => 'sco',
        23 => 'asha',
        _ => '',
      };

  bool get isLeAudio => bluetoothProfile == 'le_audio';

  String get label => name.trim().isEmpty ? kind.label : '${name.trim()} (${kind.label})';

  @override
  bool operator ==(Object other) => other is AudioEndpoint && other.key == key && other.id == id;
  @override
  int get hashCode => Object.hash(key, id);
}

class AudioRouteInfo {
  const AudioRouteInfo({this.output = const AudioEndpoint(), this.input = const AudioEndpoint()});
  final AudioEndpoint output, input;
}

/// What the engine knows of the running device: AAudio's routed device ids (0 when unknown), the names the
/// backend gave and the kinds it read (WASAPI's bus and form factor; 'unknown' elsewhere).
class AudioRouteHint {
  const AudioRouteHint({this.outputId = 0, this.inputId = 0, this.outputName = '', this.inputName = '',
      this.outputKind = 'unknown', this.inputKind = 'unknown'});
  final int outputId, inputId;
  final String outputName, inputName, outputKind, inputKind;
}

/// The engine's kind name, else the device's name read by [kindFromName].
AudioDeviceKind hintedKind(String engineKind, String name) {
  final k = AudioDeviceKind.values.where((k) => k.name == engineKind).firstOrNull;
  return k != null && k != AudioDeviceKind.unknown ? k : kindFromName(name);
}

/// The devices the platform lists itself, to choose from (#242): Android's outputs and inputs; empty where the
/// engine's backend lists them instead (Windows, the desktop builds).
class AudioDeviceLists {
  const AudioDeviceLists({this.outputs = const [], this.inputs = const []});
  final List<AudioEndpoint> outputs, inputs;
}

abstract class AudioRoute {
  Future<AudioRouteInfo> current(AudioRouteHint hint);

  /// Every output and input the platform has now (none where it does not list them).
  Future<AudioDeviceLists> devices();

  /// Fires when a device is plugged in, connected or removed (the route may have moved).
  Stream<void> get changes;
}

/// Android's AudioDeviceInfo TYPE_* to a kind (constant values from the AudioDeviceInfo reference, read 2026-11-12).
AudioDeviceKind androidDeviceKind(int type) => switch (type) {
      1 || 2 || 15 || 24 => AudioDeviceKind.builtIn,         // earpiece, speaker, mic, speaker safe
      3 || 4 || 5 || 6 || 13 || 19 || 31 => AudioDeviceKind.wired, // headset, headphones, line analog/digital, dock, aux, dock analog
      7 || 8 => AudioDeviceKind.bluetooth,                     // SCO, A2DP
      23 || 26 || 27 || 30 || 33 => AudioDeviceKind.bluetoothLe, // hearing aid (ASHA), BLE headset, speaker, broadcast, BLE hearing aid
      11 || 12 || 22 => AudioDeviceKind.usb,                   // USB device, accessory, headset
      9 || 10 || 29 => AudioDeviceKind.hdmi,                   // HDMI, ARC, eARC
      20 || 25 || 32 => AudioDeviceKind.remote,                // IP, remote submix, multichannel speaker group
      _ => AudioDeviceKind.unknown,
    };

/// A device's kind from its name, where the platform says no more (Windows, Linux). [Assumption] these words are
/// in the names Windows gives Bluetooth, USB and HDMI endpoints often enough to set a preset; "unknown" otherwise.
AudioDeviceKind kindFromName(String name) {
  final n = name.toLowerCase();
  if (n.isEmpty) return AudioDeviceKind.unknown;
  if (RegExp(r'bluetooth|hands-free|airpods|\bbuds\b|wh-1000|wf-1000|bose qc').hasMatch(n)) return AudioDeviceKind.bluetooth;
  if (RegExp(r'\busb\b').hasMatch(n)) return AudioDeviceKind.usb;
  if (RegExp(r'hdmi|displayport|nvidia high definition|amd high definition|intel\(r\) display').hasMatch(n)) {
    return AudioDeviceKind.hdmi;
  }
  if (RegExp(r'^speakers? \(realtek|built-in|internal speaker').hasMatch(n)) return AudioDeviceKind.builtIn;
  return AudioDeviceKind.unknown;
}

/// Picks the routed output and input from an Android snapshot ({"outputs", "inputs", "routed": [{"id", "type",
/// "name"}]}): the engine's AAudio device id when it has one, else Android 13's routed device for media, else the
/// device Android routes media to first by its usual priority (a Bluetooth or USB device over a wired one over the
/// speaker; [Assumption] the platform's ordinary media routing). An input is the built-in microphone unless the
/// engine names another or a USB or wired headset is in: Android does not route media capture to a Bluetooth
/// headset's microphone on its own.
/// An Android snapshot's device list ({"id", "type", "name"} maps) as endpoints.
List<AudioEndpoint> androidEndpoints(Object? o) => [
        if (o is List)
          for (final d in o)
            if (d is Map)
              AudioEndpoint(
                  id: (d['id'] as num?)?.toInt() ?? 0,
                  name: d['name'] as String? ?? '',
                  platformType: (d['type'] as num?)?.toInt() ?? -1,
                  kind: androidDeviceKind((d['type'] as num?)?.toInt() ?? -1)),
      ];

AudioRouteInfo pickAndroidRoute(Map<Object?, Object?> snap, AudioRouteHint hint) {
  final list = androidEndpoints;
  final outputs = list(snap['outputs']), inputs = list(snap['inputs']), routed = list(snap['routed']);
  AudioEndpoint? byId(List<AudioEndpoint> l, int id) => id > 0 ? l.where((d) => d.id == id).firstOrNull : null;
  AudioEndpoint? firstOf(List<AudioEndpoint> l, List<AudioDeviceKind> order) {
    for (final k in order) {
      final d = l.where((d) => d.kind == k && d.platformType != 7).firstOrNull; // SCO is for calls
      if (d != null) return d;
    }
    return null;
  }

  const outOrder = [AudioDeviceKind.bluetooth, AudioDeviceKind.bluetoothLe, AudioDeviceKind.usb, AudioDeviceKind.wired,
      AudioDeviceKind.hdmi, AudioDeviceKind.builtIn];
  const inOrder = [AudioDeviceKind.usb, AudioDeviceKind.wired, AudioDeviceKind.builtIn];
  final out = byId(outputs, hint.outputId) ?? routed.firstOrNull ?? firstOf(outputs, outOrder) ??
      const AudioEndpoint(kind: AudioDeviceKind.builtIn);
  final input = byId(inputs, hint.inputId) ?? firstOf(inputs, inOrder) ?? const AudioEndpoint(kind: AudioDeviceKind.builtIn);
  return AudioRouteInfo(output: out, input: input);
}

class AndroidAudioRoute implements AudioRoute {
  AndroidAudioRoute({MethodChannel? channel, EventChannel? events})
      : _channel = channel ?? const MethodChannel('caw/audio_route'),
        _events = events ?? const EventChannel('caw/audio_route/events');
  final MethodChannel _channel;
  final EventChannel _events;

  @override
  Future<AudioRouteInfo> current(AudioRouteHint hint) async {
    try {
      final snap = await _channel.invokeMethod<Map<Object?, Object?>>('snapshot');
      return pickAndroidRoute(snap ?? const {}, hint);
    } on PlatformException {
      return const AudioRouteInfo();
    } on MissingPluginException {
      return const AudioRouteInfo();
    }
  }

  @override
  Future<AudioDeviceLists> devices() async {
    try {
      final snap = await _channel.invokeMethod<Map<Object?, Object?>>('snapshot') ?? const {};
      return AudioDeviceLists(outputs: androidEndpoints(snap['outputs']), inputs: androidEndpoints(snap['inputs']));
    } on PlatformException {
      return const AudioDeviceLists();
    } on MissingPluginException {
      return const AudioDeviceLists();
    }
  }

  @override
  Stream<void> get changes => _events.receiveBroadcastStream().map((_) {}).handleError((Object _) {});
}

/// Windows and the desktop builds: the kind the engine read from WASAPI's property store, else the device's name
/// ([kindFromName]); no change events (a device
/// switch in Settings reopens the device, and the app looks again then).
class NamedAudioRoute implements AudioRoute {
  const NamedAudioRoute();

  @override
  Future<AudioRouteInfo> current(AudioRouteHint hint) async => AudioRouteInfo(
      output: AudioEndpoint(name: hint.outputName, kind: hintedKind(hint.outputKind, hint.outputName)),
      input: AudioEndpoint(name: hint.inputName, kind: hintedKind(hint.inputKind, hint.inputName)));

  @override
  Future<AudioDeviceLists> devices() async => const AudioDeviceLists();

  @override
  Stream<void> get changes => const Stream.empty();
}

AudioRoute platformAudioRoute() => Platform.isAndroid ? AndroidAudioRoute() : const NamedAudioRoute();

/// The system's Bluetooth settings page, where LE Audio or a device's low-latency mode is turned on (#236). C.A.W
/// does not choose the Bluetooth codec: the owner's brief (2026-11-17) says that is a privileged system API since
/// Android 14 (not checked here against a primary source), so it only opens the page.
abstract class BluetoothSettings {
  /// Whether this platform has a page to open (the button shows only then).
  bool get canOpen;

  /// Opens it; false when it could not.
  Future<bool> open();

  /// Opens Developer options (where the user picks the Bluetooth codec and its rate; no app can).
  Future<DeveloperOptions> openDeveloperOptions();

  /// The app's (tests swap it).
  static BluetoothSettings current = Platform.isAndroid ? AndroidBluetoothSettings() : const NoBluetoothSettings();
}

/// What opening Developer options did: opened, not turned on on this phone (nothing opened), or failed.
enum DeveloperOptions { opened, off, failed }

/// Android: `Settings.ACTION_BLUETOOTH_SETTINGS` and `ACTION_APPLICATION_DEVELOPMENT_SETTINGS` through
/// "caw/audio_route" (AudioRoute.kt).
class AndroidBluetoothSettings implements BluetoothSettings {
  AndroidBluetoothSettings({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('caw/audio_route');
  final MethodChannel _channel;

  @override
  bool get canOpen => true;

  @override
  Future<bool> open() async {
    try {
      return await _channel.invokeMethod<bool>('openBluetoothSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<DeveloperOptions> openDeveloperOptions() async {
    try {
      final r = await _channel.invokeMethod<String>('openDeveloperOptions');
      return DeveloperOptions.values.where((d) => d.name == r).firstOrNull ?? DeveloperOptions.failed;
    } on PlatformException {
      return DeveloperOptions.failed;
    } on MissingPluginException {
      return DeveloperOptions.failed;
    }
  }
}

/// Windows and the desktop builds: no page is opened from the app.
class NoBluetoothSettings implements BluetoothSettings {
  const NoBluetoothSettings();

  @override
  bool get canOpen => false;

  @override
  Future<bool> open() async => false;

  @override
  Future<DeveloperOptions> openDeveloperOptions() async => DeveloperOptions.failed;
}
