// Windows MIDI input through WinMM (MIDI 1.0 ports, every Windows version): a small dart:ffi binding, each message
// timed from its driver timestamp. Used only on Windows; it compiles everywhere.
import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'midi_input.dart';

// WinMM, from learn.microsoft.com (checked 2026-11-11): midiInOpen(LPHMIDIIN, UINT, DWORD_PTR callback, DWORD_PTR
// instance, DWORD flags) with CALLBACK_FUNCTION; MIM_DATA's dwParam1 packs status (low byte), data 1 and data 2,
// with running status expanded, and dwParam2 is the driver's time in milliseconds since midiInStart. SysEx never
// comes as MIM_DATA. The constant values and the MIDIINCAPSW layout are the Windows SDK's mmeapi.h / mmsystem.h ones
// [Assumption: from the headers as known, not re-read this session]: CALLBACK_FUNCTION 0x00030000, MIM_DATA 0x3C3,
// MIDIINCAPSW {WORD wMid, WORD wPid, UINT vDriverVersion, WCHAR szPname[32], DWORD dwSupport} (76 bytes).
const _callbackFunction = 0x00030000;
const _mimData = 0x3C3;
const _capsBytes = 76;
const _nameOffset = 8;

typedef _InProcC = Void Function(IntPtr handle, Uint32 msg, IntPtr instance, IntPtr param1, IntPtr param2);

class _WinMM {
  _WinMM(DynamicLibrary l)
      : numDevs = l.lookupFunction<Uint32 Function(), int Function()>('midiInGetNumDevs'),
        caps = l.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>(
            'midiInGetDevCapsW'),
        open = l.lookupFunction<Uint32 Function(Pointer<IntPtr>, Uint32, IntPtr, IntPtr, Uint32),
            int Function(Pointer<IntPtr>, int, int, int, int)>('midiInOpen'),
        start = l.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInStart'),
        reset = l.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInReset'),
        close = l.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('midiInClose');
  final int Function() numDevs;
  final int Function(int, Pointer<Uint8>, int) caps;
  final int Function(Pointer<IntPtr>, int, int, int, int) open;
  final int Function(int) start, reset, close;
}

/// Every WinMM input port, open unless Settings › MIDI turned it off. WinMM has no plug-in notification: the port
/// list is checked every two seconds, and a change reopens the ports (their numbers shift when one goes).
class WindowsMidiInput implements MidiInput {
  WindowsMidiInput(this._clock);
  final int Function() _clock;

  _WinMM? _mm;
  bool _failed = false;
  NativeCallable<_InProcC>? _callback;
  final _messages = StreamController<MidiMessage>.broadcast();
  final _names = StreamController<List<String>>.broadcast();
  final _ports = StreamController<List<MidiPort>>.broadcast();
  final Map<int, ({int handle, String name, int startNs})> _open = {}; // by port number
  List<String> _seen = const [];
  Set<String> _closed = {};
  Timer? _poll;
  int _listeners = 0;

  StreamController<T> _watched<T>(StreamController<T> c) {
    c.onListen = () {
      _listeners++;
      _start();
    };
    c.onCancel = () {
      if (--_listeners == 0) _stop();
    };
    return c;
  }

  late final _m = _watched(_messages);
  late final _n = _watched(_names);
  late final _p = _watched(_ports);

  @override
  Stream<MidiMessage> get messages => _m.stream;
  @override
  Stream<List<String>> get devices => _n.stream;
  @override
  Stream<List<MidiPort>> get ports => _p.stream;
  @override
  BluetoothMidi? get bluetooth => null; // Windows pairs Bluetooth MIDI in its own settings

  @override
  void setClosed(Set<String> names) {
    _closed = names;
    if (_mm != null) _reopen();
  }

  void _start() {
    if (_mm != null || _failed) return;
    try {
      _mm = _WinMM(DynamicLibrary.open('winmm.dll'));
    } catch (_) {
      _failed = true;
      return;
    }
    _callback = NativeCallable<_InProcC>.listener(_onData);
    _reopen();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_sameNames(_list(), _seen)) _reopen();
    });
  }

  void _stop() {
    _poll?.cancel();
    _poll = null;
    _closeAll();
    // The callable stays: a message already on its way may still arrive after close.
  }

  static bool _sameNames(List<String> a, List<String> b) =>
      a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  /// The ports' names, in WinMM's order (a repeated name gets " 2", " 3").
  List<String> _list() {
    final mm = _mm;
    if (mm == null) return const [];
    final n = mm.numDevs();
    final caps = calloc<Uint8>(_capsBytes);
    final names = <String>[];
    try {
      for (var i = 0; i < n; i++) {
        if (mm.caps(i, caps, _capsBytes) != 0) {
          names.add('MIDI input ${i + 1}');
          continue;
        }
        final name = (caps + _nameOffset).cast<Utf16>().toDartString();
        var unique = name.isEmpty ? 'MIDI input ${i + 1}' : name;
        for (var k = 2; names.contains(unique); k++) {
          unique = '$name $k';
        }
        names.add(unique);
      }
    } finally {
      calloc.free(caps);
    }
    return names;
  }

  void _closeAll() {
    final mm = _mm;
    if (mm == null) return;
    for (final p in _open.values) {
      mm.reset(p.handle);
      mm.close(p.handle);
    }
    _open.clear();
  }

  void _reopen() {
    final mm = _mm, cb = _callback;
    if (mm == null || cb == null) return;
    _closeAll();
    _seen = _list();
    final handle = calloc<IntPtr>();
    try {
      for (var i = 0; i < _seen.length; i++) {
        if (_closed.contains(_seen[i])) continue;
        if (mm.open(handle, i, cb.nativeFunction.address, i, _callbackFunction) != 0) continue;
        final h = handle.value;
        mm.start(h);
        _open[i] = (handle: h, name: _seen[i], startNs: _clock());
      }
    } finally {
      calloc.free(handle);
    }
    _p.add([
      for (var i = 0; i < _seen.length; i++)
        MidiPort(id: i, name: _seen[i], kind: 'port', open: _open.containsKey(i), off: _closed.contains(_seen[i])),
    ]);
    _n.add([for (final p in _open.values) p.name]);
  }

  void _onData(int handle, int msg, int instance, int param1, int param2) {
    if (msg != _mimData) return;
    final port = _open[instance];
    if (port == null || port.handle != handle) return;
    final status = param1 & 0xFF;
    if (status < 0x80 || status >= 0xF0) return; // real-time and system messages
    final t = port.startNs > 0 ? port.startNs + (param2 & 0xFFFFFFFF) * 1000000 : 0;
    _m.add(MidiMessage(status, (param1 >> 8) & 0x7F, (param1 >> 16) & 0x7F, port.name, t));
  }
}
