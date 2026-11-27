// MIDI out to devices: the platform sender that takes the engine's timed messages (caw_engine_midi_out_drain, API
// 47) to ports. No platform sender is built yet (Android's MidiReceiver, a Windows native sender thread), so every
// platform gets the no-op output; the engine side, the model and the bindings are in place for them.

/// One outbound message from the engine: when it should reach its port, on the engine's MIDI clock
/// (`caw_midi_clock_ns`), which port (0..15, as a MIDI-out layer names it), and its MIDI 1.0 bytes (1..3).
class MidiOutEvent {
  const MidiOutEvent(this.timeNs, this.port, this.bytes);
  final int timeNs;
  final int port;
  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      other is MidiOutEvent &&
      other.timeNs == timeNs &&
      other.port == port &&
      other.bytes.length == bytes.length &&
      Iterable.generate(bytes.length).every((i) => other.bytes[i] == bytes[i]);

  @override
  int get hashCode => Object.hash(timeNs, port, Object.hashAll(bytes));

  @override
  String toString() => 'MidiOutEvent($timeNs, port $port, $bytes)';
}

/// A device output a port can send to (its id and name as the platform lists it).
class MidiOutDevice {
  const MidiOutDevice({required this.id, required this.name});
  final String id;
  final String name;
}

/// Where the engine's outbound MIDI goes. A sender keeps a map from the engine's ports (0..15) to devices and sends
/// each message at its time: on Android by `MidiReceiver.send(msg, offset, count, timestamp)` with the time as is
/// (the same clock as System.nanoTime); where the API takes no timestamp (WinMM's midiOutShortMsg), from a native
/// thread that waits for each time.
abstract class MidiOutput {
  /// Whether this platform can send at all (false: the no-op output).
  bool get available;

  /// The devices it can send to, each time that changes.
  Stream<List<MidiOutDevice>> get devices;

  /// Routes engine port [port] (0..15) to [deviceId] (null: nowhere).
  Future<void> route(int port, String? deviceId);

  /// Sends [events], each at its time.
  void send(List<MidiOutEvent> events);

  /// Closes every device.
  Future<void> close();
}

/// The output where no sender exists: it lists no device and drops what it is given.
class NoMidiOutput implements MidiOutput {
  const NoMidiOutput();
  @override
  bool get available => false;
  @override
  Stream<List<MidiOutDevice>> get devices => const Stream.empty();
  @override
  Future<void> route(int port, String? deviceId) async {}
  @override
  void send(List<MidiOutEvent> events) {}
  @override
  Future<void> close() async {}
}

/// The platform's MIDI output. Every platform returns [NoMidiOutput] until its sender is built.
MidiOutput platformMidiOutput() => const NoMidiOutput();
