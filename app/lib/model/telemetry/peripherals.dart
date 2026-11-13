// What H2's `device.audio.output` and `device.peripherals` say about the sound route and MIDI devices (contract
// addition, owner 2026-11-12): kinds and connections, and for USB MIDI its vendor and product ids. Never a name: not
// an audio device's (a Bluetooth headset's is the user's), a MIDI port's, or a USB product string (DIY boards let their
// owner set it); no address, port path or in-use flag. At most 8, sorted by kind, so the list says little about
// which day it came from (security review, 2026-11-12).
import '../../platform/audio_route.dart';
import '../../platform/midi_input.dart';

/// An audio route kind as H2's connection ("builtin", "usb", "bluetooth", "wired", "hdmi", "network", "unknown").
String connectionOf(AudioDeviceKind kind) => switch (kind) {
      AudioDeviceKind.builtIn => 'builtin',
      AudioDeviceKind.wired => 'wired',
      AudioDeviceKind.bluetooth || AudioDeviceKind.bluetoothLe => 'bluetooth',
      AudioDeviceKind.usb => 'usb',
      AudioDeviceKind.hdmi => 'hdmi',
      AudioDeviceKind.remote => 'network',
      AudioDeviceKind.unknown => 'unknown',
    };

/// The app sends at most this many peripherals (H2 allows 16).
const maxPeripherals = 8;

String _hex4(int v) => (v & 0xffff).toRadixString(16).padLeft(4, '0');

/// The peripherals: the audio output and input when they aren't the device's own, and each MIDI device; sorted by
/// kind and connection, at most [maxPeripherals].
List<Map<String, Object?>> peripheralsOf({AudioRouteInfo? route, List<MidiPort> midi = const []}) {
  final out = <Map<String, Object?>>[];
  if (route != null) {
    for (final (kind, end) in [('audio-output', route.output), ('audio-input', route.input)]) {
      if (end.kind == AudioDeviceKind.builtIn || end.kind == AudioDeviceKind.unknown) continue;
      // Kind and connection only: AudioDeviceInfo.getProductName is the device's visible name, a Bluetooth one the
      // user's own.
      out.add({'kind': kind, 'connection': connectionOf(end.kind)});
    }
  }
  for (final p in midi) {
    final usb = p.kind == 'usb';
    out.add({
      'kind': 'midi',
      'connection': switch (p.kind) { 'usb' => 'usb', 'bluetooth' => 'bluetooth', 'virtual' => 'other', _ => 'unknown' },
      if (usb && p.usbVendorId != null) 'vendorId': _hex4(p.usbVendorId!),
      if (usb && p.usbProductId != null) 'productId': _hex4(p.usbProductId!),
    });
  }
  String key(Map<String, Object?> m) => '${m['kind']}|${m['connection']}|${m['vendorId'] ?? ''}|${m['productId'] ?? ''}';
  out.sort((a, b) => key(a).compareTo(key(b)));
  return out.take(maxPeripherals).toList();
}
