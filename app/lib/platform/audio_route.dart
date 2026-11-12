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

abstract class AudioRoute {
  Future<AudioRouteInfo> current(AudioRouteHint hint);

  /// Fires when a device is plugged in, connected or removed (the route may have moved).
  Stream<void> get changes;
}

/// Android's AudioDeviceInfo TYPE_* to a kind (constant values from the AudioDeviceInfo reference, read 2026-11-12).
AudioDeviceKind androidDeviceKind(int type) => switch (type) {
      1 || 2 || 15 || 24 => AudioDeviceKind.builtIn,         // earpiece, speaker, mic, speaker safe
      3 || 4 || 5 || 6 || 13 || 19 || 31 => AudioDeviceKind.wired, // headset, headphones, line analog/digital, dock, aux, dock analog
      7 || 8 => AudioDeviceKind.bluetooth,                     // SCO, A2DP
      23 || 26 || 27 || 30 || 33 => AudioDeviceKind.bluetoothLe, // hearing aid, BLE headset, speaker, broadcast, hearing aid
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
AudioRouteInfo pickAndroidRoute(Map<Object?, Object?> snap, AudioRouteHint hint) {
  List<AudioEndpoint> list(Object? o) => [
        if (o is List)
          for (final d in o)
            if (d is Map)
              AudioEndpoint(
                  id: (d['id'] as num?)?.toInt() ?? 0,
                  name: d['name'] as String? ?? '',
                  platformType: (d['type'] as num?)?.toInt() ?? -1,
                  kind: androidDeviceKind((d['type'] as num?)?.toInt() ?? -1)),
      ];
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
  Stream<void> get changes => const Stream.empty();
}

AudioRoute platformAudioRoute() => Platform.isAndroid ? AndroidAudioRoute() : const NamedAudioRoute();
