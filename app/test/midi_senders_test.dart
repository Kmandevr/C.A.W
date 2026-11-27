// MIDI out's routing and the MIDI clock's forwarding (engine API 48) with fakes: ports go to the devices the settings
// name, the sender attaches while one is open, devices coming and going, the clock bytes reach the engine only while
// following; the platforms' device lists and WinMM's clock messages; and (with CAW_LIB) the C API off a sender.
import 'dart:async';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/midi_clock_follow.dart';
import 'package:caw/model/midi_out_routing.dart';
import 'package:caw/model/settings.dart';
import 'package:caw/platform/midi_input.dart';
import 'package:caw/platform/midi_output.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHost implements MidiSenderHost {
  FakeHost({this.ok = true});
  final bool ok;
  int starts = 0, stops = 0;
  @override
  bool startMidiSender() {
    starts++;
    return ok;
  }

  @override
  void stopMidiSender() => stops++;
}

class FakeOutput implements MidiOutput {
  final list = StreamController<List<MidiOutDevice>>.broadcast();
  final log = <String>[];
  final Set<String> refuse = {};
  MidiSenderHost? attached;
  @override
  bool get available => true;
  @override
  Stream<List<MidiOutDevice>> get devices => list.stream;
  @override
  Future<bool> route(int port, String? deviceId) async {
    log.add('route $port ${deviceId ?? '-'}');
    return deviceId == null || !refuse.contains(deviceId);
  }

  @override
  Future<bool> attach(MidiSenderHost host) async {
    log.add('attach');
    if (attached != null && !identical(attached, host)) await detach();
    if (!host.startMidiSender()) return false;
    attached = host;
    return true;
  }

  @override
  Future<void> detach() async {
    log.add('detach');
    attached?.stopMidiSender();
    attached = null;
  }

  @override
  Future<void> close() async => log.add('close');
}

class FakeClockSource implements MidiClockSource {
  final _c = StreamController<MidiClockBytes>.broadcast();
  final follows = <bool>[];
  @override
  Stream<MidiClockBytes> get clock => _c.stream;
  @override
  void setClockFollow(bool on) => follows.add(on);
}

class FakeClockEngine implements MidiClockEngine {
  final follows = <bool>[];
  final bytes = <(List<int>, int)>[];
  @override
  void setMidiClockFollow(bool on) => follows.add(on);
  @override
  int midiClockIn(List<int> b, int timeNs) {
    bytes.add((b, timeNs));
    return 1;
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('MidiOutRouting', () {
    late FakeOutput out;
    late Map<int, String> routes;
    MidiSenderHost? host;
    late MidiOutRouting r;
    setUp(() {
      out = FakeOutput();
      routes = {};
      host = FakeHost();
      r = MidiOutRouting(out, routes: () => routes, save: (m) async => routes = m, host: () => host);
      r.start();
    });

    test('a port opens on the device its setting names, and the sender attaches', () async {
      routes = {2: 'Synth'};
      await r.sync();
      expect(out.log, isEmpty); // no such device yet: nothing opens, no sender
      expect(r.sending, isFalse);
      out.list.add(const [MidiOutDevice(id: '7:0', name: 'Synth'), MidiOutDevice(id: '8:0', name: 'Drums')]);
      await settle();
      await r.sync();
      expect(out.log, ['route 2 7:0', 'attach']);
      expect(r.isOpen(2), isTrue);
      expect(r.sending, isTrue);
      expect((host as FakeHost).starts, 1);
      // Synced again with nothing changed: nothing happens.
      await r.sync();
      expect(out.log.length, 2);
    });

    test('the device leaving closes the port and detaches; coming back (a new id) opens it again', () async {
      routes = {0: 'Synth'};
      out.list.add(const [MidiOutDevice(id: '7:0', name: 'Synth')]);
      await settle();
      await r.sync();
      out.log.clear();
      out.list.add(const []);
      await settle();
      await r.sync();
      expect(out.log, ['route 0 -', 'detach']);
      expect((host as FakeHost).stops, 1);
      out.log.clear();
      out.list.add(const [MidiOutDevice(id: '9:0', name: 'Synth')]);
      await settle();
      await r.sync();
      expect(out.log, ['route 0 9:0', 'attach']);
    });

    test('choose saves the device by name for the port; none closes it', () async {
      out.list.add(const [MidiOutDevice(id: 'a', name: 'A'), MidiOutDevice(id: 'b', name: 'B')]);
      await settle();
      await r.choose(3, 'B');
      expect(routes, {3: 'B'});
      expect(r.deviceFor(3), 'B');
      expect(out.log, ['route 3 b', 'attach']);
      await r.choose(3, 'A'); // another device on that port
      expect(out.log.sublist(2), ['route 3 a']);
      await r.choose(3, null);
      expect(routes, isEmpty);
      expect(out.log.sublist(3), ['route 3 -', 'detach']);
      await r.choose(16, 'A'); // no such port
      expect(routes, isEmpty);
    });

    test('a device that will not open stays closed; a new engine gets the sender; no engine detaches', () async {
      out.refuse.add('b');
      routes = {1: 'B', 4: 'A'};
      out.list.add(const [MidiOutDevice(id: 'a', name: 'A'), MidiOutDevice(id: 'b', name: 'B')]);
      await settle();
      await r.sync();
      expect(r.isOpen(1), isFalse);
      expect(r.isOpen(4), isTrue);
      final first = host as FakeHost;
      host = FakeHost();
      await r.sync();
      expect(out.attached, same(host));
      expect(first.stops, 1); // the old engine's sender went first
      host = null;
      await r.sync();
      expect(out.attached, isNull);
      expect(r.sending, isFalse);
    });

    test('an engine that has no sender is not asked again until it changes', () async {
      host = FakeHost(ok: false);
      routes = {0: 'A'};
      out.list.add(const [MidiOutDevice(id: 'a', name: 'A')]);
      await settle();
      await r.sync();
      await r.sync();
      expect((host as FakeHost).starts, 1);
      expect(r.sending, isFalse);
    });
  });

  test('the settings keep each port\'s device by name, within limits', () {
    final s = Settings()
      ..midiOutDevices = {0: 'Synth', 15: 'Drum "machine"'}
      ..midiClockFollow = true;
    final t = Settings()..fromJson(s.toJson());
    expect(t.midiOutDevices, {0: 'Synth', 15: 'Drum "machine"'});
    expect(t.midiClockFollow, isTrue);
    // Defaults save nothing new (older settings files stay as they were).
    expect(Settings().toJson().containsKey('midi_out_devices'), isFalse);
    expect(Settings().toJson().containsKey('midi_clock_follow'), isFalse);
    final bad = Settings()
      ..fromJson({
        'midi_out_devices': {'16': 'x', '-1': 'y', 'a': 'z', '3': 7, '4': '', '5': 'ok'},
      });
    expect(bad.midiOutDevices, {5: 'ok'});
  });

  group('MidiClockFollow', () {
    test('bytes reach the engine only while following, and both sides are told', () async {
      final src = FakeClockSource(), e = FakeClockEngine();
      final f = MidiClockFollow(src);
      final sub = src.clock.listen(f.add);
      f.apply(on: false, engine: e);
      expect(src.follows, [false]);
      src._c.add(const MidiClockBytes([0xF8], 100));
      await settle();
      expect(e.bytes, isEmpty);
      f.apply(on: true, engine: e);
      expect(src.follows, [false, true]);
      expect(e.follows.last, isTrue);
      src._c.add(const MidiClockBytes([0xFA], 200));
      src._c.add(const MidiClockBytes([0xF2, 4, 1], 300));
      await settle();
      expect(e.bytes.map((b) => b.$1), [
        [0xFA],
        [0xF2, 4, 1],
      ]);
      expect(e.bytes.map((b) => b.$2), [200, 300]);
      // The same again tells nobody; a new engine is told; off tells it and the devices.
      final n = e.follows.length;
      f.apply(on: true, engine: e);
      expect(e.follows.length, n);
      final e2 = FakeClockEngine();
      f.apply(on: true, engine: e2);
      expect(e2.follows, [true]);
      f.apply(on: false, engine: e2);
      expect(e2.follows, [true, false]);
      expect(src.follows.last, isFalse);
      src._c.add(const MidiClockBytes([0xF8], 400));
      await settle();
      expect(e2.bytes, isEmpty);
      // No engine: dropped.
      f.apply(on: true, engine: null);
      f.add(const MidiClockBytes([0xF8], 500));
      await sub.cancel();
    });
  });

  test('WinMM short messages: the clock and its transport, nothing else', () {
    expect(clockBytesOfShortMessage(0xF8), [0xF8]);
    expect(clockBytesOfShortMessage(0xFA), [0xFA]);
    expect(clockBytesOfShortMessage(0xFB), [0xFB]);
    expect(clockBytesOfShortMessage(0xFC), [0xFC]);
    expect(clockBytesOfShortMessage(0xF2 | 0x05 << 8 | 0x02 << 16), [0xF2, 5, 2]);
    expect(clockBytesOfShortMessage(0xFE), isNull); // Active Sensing
    expect(clockBytesOfShortMessage(0xFF), isNull);
    expect(clockBytesOfShortMessage(0xF3 | 1 << 8), isNull);
    expect(clockBytesOfShortMessage(0x903C64), isNull);
  });

  test('the platforms\' device lists', () {
    expect(WindowsMidiOutput.parseWindowsDevices('["Synth","Synth 2"]').map((d) => d.id), ['Synth', 'Synth 2']);
    expect(WindowsMidiOutput.parseWindowsDevices('[1,"A"]').map((d) => d.name), ['A']);
    expect(WindowsMidiOutput.parseWindowsDevices('nope'), isEmpty);
    expect(WindowsMidiOutput.parseWindowsDevices('{}'), isEmpty);
    final a = AndroidMidiOutput.parseAndroidDevices([
      {'id': '12:0', 'name': 'Synth'},
      {'id': 3, 'name': 'bad id'},
      'junk',
      {'id': '12:1'},
    ]);
    expect(a.map((d) => d.id), ['12:0', '12:1']);
    expect(a.last.name, 'MIDI device');
    expect(AndroidMidiOutput.parseAndroidDevices(null), isEmpty);
  });

  test('with the engine: no sender off Android and Windows, and an empty device list (needs CAW_LIB)', () async {
    final e = Engine.create();
    expect(e.startMidiSender(), isFalse);
    e.stopMidiSender();
    final w = WindowsMidiOutput(); // its calls go to the engine library, which lists nothing here
    final first = await w.devices.first;
    expect(first, isEmpty);
    expect(await w.route(0, 'x'), isFalse);
    expect(await w.route(0, null), isTrue);
    expect(await w.attach(e), isFalse);
    await w.close();
    e.dispose();
  }, skip: Platform.environment['CAW_LIB']?.isNotEmpty != true);
}
