// MIDI out's routing on this machine (engine API 48): each MIDI-out port a project names (0..15) goes to the device
// the settings chose for it, by name; the sender attaches to the engine while any port has its device. No screen.
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import '../platform/midi_output.dart';
import 'app_state.dart';

class MidiOutRouting extends ChangeNotifier {
  /// [routes] reads the settings' port-to-device-name map, [save] writes it; [host] is the engine now (null: none);
  /// [awake] whether the sender should run (false: detached, which sends CC 123 on the channels used).
  MidiOutRouting(this.output, {required this.routes, required this.save, required this.host, bool Function()? awake})
      : awake = awake ?? (() => true);

  /// The app's one instance (main.dart), for a later screen that picks the devices.
  static MidiOutRouting? current;

  /// Wired to the app: the settings' `midiOutDevices`, re-synced when they or the engine change. The sender runs
  /// while the app is in front or the transport plays (background playback keeps it; a stopped app behind others
  /// detaches, ending the devices' notes, and attaches again on its return), and the app's exit or detach closes
  /// every device after CC 123 (the engine would otherwise never be told: Windows' window closing, Android ending
  /// the app).
  factory MidiOutRouting.forApp(AppState state, MidiOutput output) {
    final r = MidiOutRouting(
      output,
      routes: () => state.settings.midiOutDevices,
      save: (m) => state.settings.update((x) => x.midiOutDevices = m),
      host: () => state.engine,
      awake: () => state.foreground.value || state.transportOn,
    );
    state.addListener(r._maybeSync);
    state.foreground.addListener(r._maybeSync);
    state.settings.addListener(r._maybeSync);
    r._life = AppLifecycleListener(
      onDetach: () => unawaited(r.shutdown()),
      onExitRequested: () async {
        await r.shutdown();
        return AppExitResponse.exit;
      },
    );
    r.start();
    return r;
  }

  AppLifecycleListener? _life;
  bool _shut = false;

  /// The app is going: the sender detached and every device closed, each after its CC 123s. Nothing opens again.
  Future<void> shutdown() async {
    if (_shut) return;
    _shut = true;
    await _sub?.cancel();
    _sub = null;
    await _running;
    _attached = null;
    _open.clear();
    try {
      await output.close();
    } catch (_) {
      // the platform side is already gone
    }
  }

  final MidiOutput output;
  final Map<int, String> Function() routes;
  final Future<void> Function(Map<int, String>) save;
  final MidiSenderHost? Function() host;
  final bool Function() awake;

  /// The engine the sender should be on now: none while asleep or shut down.
  MidiSenderHost? _wantedHost() => _shut || !awake() ? null : host();

  /// The devices the platform can send to now.
  List<MidiOutDevice> devices = const [];

  final Map<int, String> _open = {}; // port -> the device id opened for it
  MidiSenderHost? _attached;
  MidiSenderHost? _hostSeen; // the engine the last sync saw (a failed attach isn't retried until it changes)
  StreamSubscription<List<MidiOutDevice>>? _sub;
  Future<void>? _running;
  bool _again = false;
  Map<int, String> _lastRoutes = const {};

  /// Whether a sender is attached to the engine (some port has its device).
  bool get sending => _attached != null;

  /// The device name chosen for [port] (null: none).
  String? deviceFor(int port) => routes()[port];

  /// Whether [port]'s chosen device is present and open.
  bool isOpen(int port) => _open.containsKey(port);

  /// Chooses [deviceName] for [port] (null: none), saved in the settings; what a later screen calls.
  Future<void> choose(int port, String? deviceName) async {
    if (port < 0 || port > 15) return;
    final m = {...routes()};
    if (deviceName == null || deviceName.isEmpty) {
      m.remove(port);
    } else {
      m[port] = deviceName;
    }
    await save(m);
    await sync();
  }

  void start() {
    if (!output.available || _sub != null) return;
    _sub = output.devices.listen((d) {
      devices = d;
      sync();
      notifyListeners();
    });
    sync();
  }

  void _maybeSync() {
    final r = routes();
    if (!identical(_wantedHost(), _hostSeen) || !mapEquals(r, _lastRoutes)) sync();
  }

  /// Opens and closes the ports to match the settings and the devices present, then attaches or detaches the
  /// sender. Calls while one runs make it run once more.
  Future<void> sync() {
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = () async {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
      _running = null;
    }();
  }

  Future<void> _syncOnce() async {
    if (_shut) return;
    final r = routes();
    _lastRoutes = {...r};
    final want = <int, String>{};
    for (final e in r.entries) {
      for (final d in devices) {
        if (d.name == e.value) {
          want[e.key] = d.id;
          break;
        }
      }
    }
    var changed = false;
    for (var port = 0; port < 16; port++) {
      final id = want[port];
      if (_open[port] == id) continue;
      changed = true;
      if (id == null) {
        await output.route(port, null);
        _open.remove(port);
      } else if (await output.route(port, id)) {
        _open[port] = id;
      } else {
        _open.remove(port);
      }
    }
    final h = _wantedHost();
    final newHost = !identical(h, _hostSeen);
    _hostSeen = h;
    if (_open.isNotEmpty && h != null) {
      if (!identical(h, _attached) && (newHost || changed)) {
        changed = true;
        _attached = await output.attach(h) ? h : null;
      }
    } else if (_attached != null) {
      changed = true;
      _attached = null;
      await output.detach();
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _life?.dispose();
    _sub?.cancel();
    if (!_shut) output.close();
    super.dispose();
  }
}
