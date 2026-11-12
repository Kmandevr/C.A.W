// What H2's `device.audio.output` and `device.peripherals` say about the sound route and MIDI devices (contract
// addition, owner 2026-11-12): kinds and connections, and for USB MIDI only the maker's ids and product string.
// Never a name the user can set: an audio device's name (a Bluetooth headset's is the user's), a MIDI port's name,
// an address or a port path.
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

String _hex4(int v) => (v & 0xffff).toRadixString(16).padLeft(4, '0');

/// The peripherals in use: the audio output and input when they aren't the device's own, and each MIDI device.
/// At most 16 (H2).
List<Map<String, Object?>> peripheralsOf({AudioRouteInfo? route, List<MidiPort> midi = const []}) {
  final out = <Map<String, Object?>>[];
  if (route != null) {
    for (final (kind, end) in [('audio-output', route.output), ('audio-input', route.input)]) {
      if (end.kind == AudioDeviceKind.builtIn || end.kind == AudioDeviceKind.unknown) continue;
      // Kind and connection only: AudioDeviceInfo.getProductName is the device's visible name, a Bluetooth one the
      // user's own.
      out.add({'kind': kind, 'connection': connectionOf(end.kind), 'inUse': true});
    }
  }
  for (final p in midi) {
    final usb = p.kind == 'usb';
    out.add({
      'kind': 'midi',
      'connection': switch (p.kind) { 'usb' => 'usb', 'bluetooth' => 'bluetooth', 'virtual' => 'other', _ => 'unknown' },
      if (usb && p.usbProduct != null && p.usbProduct!.trim().isNotEmpty) 'model': p.usbProduct!.trim(),
      if (usb && p.usbVendorId != null) 'vendorId': _hex4(p.usbVendorId!),
      if (usb && p.usbProductId != null) 'productId': _hex4(p.usbProductId!),
      'inUse': p.open,
    });
  }
  return out.take(16).toList();
}
