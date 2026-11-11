// Settings › MIDI and input, devices: every MIDI device with an activity light and an on/off switch, the in-app
// Bluetooth scan (Android), MPE and bend range, and the controller mappings made with "Learn MIDI CC".
import 'dart:async';

import 'package:flutter/material.dart';

import '../../model/device_target.dart';
import '../../model/live_midi.dart';
import '../../model/midi_mapping.dart';
import '../../model/settings.dart';
import '../../platform/midi_input.dart';
import '../haptics.dart';
import '../theme.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';
import '../pointer_input.dart';

class MidiDevicesSettings extends StatelessWidget {
  const MidiDevicesSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) {
    final midi = LiveMidi.current;
    final s = deps.settings;
    final input = midi?.input;
    Widget page() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          settingHeading('Devices'),
          if (midi == null || input == null)
            settingAction('midi.devices', icon: Icons.usb, subtitle: 'This platform reads no MIDI devices yet; the on-screen keys play')
          else if (midi.ports.isEmpty)
            settingAction('midi.devices', icon: Icons.usb, subtitle: input.bluetooth == null
                ? 'None connected: plug in a USB keyboard or pad controller'
                : 'None connected: plug in a USB keyboard or pad controller, or scan for a Bluetooth one below')
          else
            SettingRow(id: 'midi.devices', child: Column(children: [
              for (final p in midi.ports) _DeviceRow(port: p, midi: midi, settings: s),
            ])),
          if (input?.bluetooth case final bt?)
            _BluetoothScan(bluetooth: bt)
          else
            settingAction('midi.bluetooth', icon: Icons.bluetooth_disabled,
                subtitle: 'Pair a Bluetooth MIDI device in the system\'s Bluetooth settings; it then shows above'),
          settingSwitch('midi.mpe', s.midiMpe, (v) => s.update((x) => x.midiMpe = v),
              icon: Icons.blur_on,
              subtitle: s.midiMpe
                  ? 'Channel 1 is the master; channels 2 to 16 each bend and press one note'
                  : 'Off: pitch bend and pressure move every note on their channel'),
          settingDropdown<int>('midi.bendRange', s.midiBendRange,
              [for (final r in const [1, 2, 3, 5, 7, 12, 24, 48]) (r, '±$r')], (v) => s.update((x) => x.midiBendRange = v),
              icon: Icons.swap_vert),
          if (midi == null)
            settingAction('midi.mappings', icon: Icons.tune, subtitle: 'None yet')
          else
            _Mappings(midi: midi),
        ]);
    return midi == null ? page() : ListenableBuilder(listenable: midi, builder: (context, _) => page());
  }
}

/// One device: its kind, a light that flashes while it sends, and whether C.A.W reads it.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.port, required this.midi, required this.settings});
  final MidiPort port;
  final LiveMidi midi;
  final Settings settings;

  @override
  Widget build(BuildContext context) {
    final on = !settings.midiClosed.contains(port.name);
    final kind = switch (port.kind) {
      'bluetooth' => 'Bluetooth',
      'virtual' => 'App',
      'port' => 'MIDI port',
      _ => 'USB',
    };
    return SwitchListTile(
        key: ValueKey('midi-device-${port.name}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        secondary: _ActivityLight(midi: midi, name: port.name, on: on && port.open),
        title: Text(port.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('$kind${port.ump ? ' · MIDI 2.0' : ''} · ${on ? (port.open ? 'connected' : 'connecting…') : 'off'}',
            style: const TextStyle(color: Neon.dim, fontSize: 12)),
        value: on,
        onChanged: (v) {
          Haptics.tap();
          settings.update((x) => x.midiClosed = v ? ({...x.midiClosed}..remove(port.name)) : {...x.midiClosed, port.name});
        },
    );
  }
}

/// Lights while [name] sends (each message relights it for a moment).
class _ActivityLight extends StatefulWidget {
  const _ActivityLight({required this.midi, required this.name, required this.on});
  final LiveMidi midi;
  final String name;
  final bool on;

  @override
  State<_ActivityLight> createState() => _ActivityLightState();
}

class _ActivityLightState extends State<_ActivityLight> {
  Timer? _off;
  bool _lit = false;

  @override
  void initState() {
    super.initState();
    widget.midi.activity.addListener(_tick);
  }

  @override
  void dispose() {
    widget.midi.activity.removeListener(_tick);
    _off?.cancel();
    super.dispose();
  }

  void _tick() {
    final at = widget.midi.lastActivity[widget.name];
    if (at == null || DateTime.now().difference(at).inMilliseconds > 150) return;
    if (!_lit) setState(() => _lit = true);
    _off?.cancel();
    _off = Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _lit = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.on ? Neon.green : Neon.dim;
    return SizedBox(
      width: 20,
      child: Center(
        child: AnimatedContainer(
          key: ValueKey('midi-light-${widget.name}'),
          duration: const Duration(milliseconds: 60),
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _lit ? c : c.withValues(alpha: 0.25),
            boxShadow: _lit ? Neon.glow(c) : null,
          ),
        ),
      ),
    );
  }
}

/// The Bluetooth LE MIDI scan: asks for Nearby devices only when started, lists what it finds, connects on a tap.
class _BluetoothScan extends StatelessWidget {
  const _BluetoothScan({required this.bluetooth});
  final BluetoothMidi bluetooth;

  @override
  Widget build(BuildContext context) => StreamBuilder<BluetoothMidiState>(
        stream: bluetooth.states,
        initialData: bluetooth.state,
        builder: (context, snap) {
          final b = snap.data ?? const BluetoothMidiState();
          final problem = switch (b.error) {
            'permission' => 'C.A.W needs the Nearby devices permission to find Bluetooth MIDI',
            'off' => 'Bluetooth is off: turn it on, then scan again',
            'unsupported' => 'This device has no Bluetooth LE',
            'connect' => "Couldn't connect: wake the device and try again",
            _ => null,
          };
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            settingAction('midi.bluetooth',
                icon: Icons.bluetooth_searching,
                subtitle: problem ?? (b.scanning ? 'Looking for Bluetooth MIDI devices…' : null),
                trailing: b.scanning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right),
                onTap: () => bluetooth.scan(!b.scanning)),
            for (final d in b.found)
              ListTile(
                key: ValueKey('ble-${d.address}'),
                dense: true,
                contentPadding: const EdgeInsets.only(left: 44, right: 8),
                title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    b.connected.contains(d.address)
                        ? 'Connected'
                        : b.connecting.contains(d.address)
                            ? 'Connecting…'
                            : 'Tap to connect',
                    style: const TextStyle(color: Neon.dim, fontSize: 12)),
                trailing: b.connected.contains(d.address)
                    ? TextButton(
                        onPressed: () {
                          Haptics.tap();
                          bluetooth.disconnect(d.address);
                        },
                        child: const Text('Disconnect'))
                    : null,
                onTap: b.connected.contains(d.address) || b.connecting.contains(d.address)
                    ? null
                    : () {
                        Haptics.tap();
                        bluetooth.connect(d.address);
                      },
              ),
          ]);
        },
      );
}

/// The controller mappings: each CC, the knob it moves, and a remove button.
class _Mappings extends StatelessWidget {
  const _Mappings({required this.midi});
  final LiveMidi midi;

  @override
  Widget build(BuildContext context) {
    final state = midi.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final maps = state.project.midiMappings;
        String where(MidiCcMapping m) {
          final layer = state.project.layers.where((l) => l.id == m.layerId).firstOrNull;
          if (layer == null) return 'a removed track';
          final t = DeviceTarget(state, m.layerId, m.slot);
          if (t.use == null) return '${layer.name} › a removed device';
          return '${layer.name} › ${t.label} › ${t.param(m.paramId)?.label ?? m.paramId}';
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          settingHeading('Controller mappings'),
          if (maps.isEmpty)
            settingAction('midi.mappings', icon: Icons.tune,
                subtitle: 'None yet: ${PointerInput.hold} a knob, choose Learn MIDI CC, and move a control on your device')
          else
            SettingRow(id: 'midi.mappings', child: Column(children: [
              for (final m in maps)
                ListTile(
                key: ValueKey('midi-map-${m.channel}-${m.cc}-${m.layerId}-${m.slot}-${m.paramId}'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: const Icon(Icons.tune, color: Neon.blue, size: 20),
                title: Text('CC ${m.cc} · channel ${m.channel + 1}', style: Neon.code(size: 13)),
                subtitle: Text(where(m), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Neon.dim, fontSize: 12)),
                trailing: IconButton(
                  key: ValueKey('midi-map-remove-${m.cc}-${m.paramId}'),
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    Haptics.tap();
                    midi.forget(m);
                  },
                ),
              ),
            ])),
        ]);
      },
    );
  }
}
