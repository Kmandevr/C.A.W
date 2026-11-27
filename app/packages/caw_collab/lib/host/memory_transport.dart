// An in-memory transport between one HostCore and any number of members, with seeded fault injection (drops,
// duplicates, reordering and host crashes), for tests and simulations.
import 'dart:collection';
import 'dart:math';

import 'host_core.dart';
import 'messages.dart';

/// The faults a [MemoryNetwork] injects, each a probability per delivered message.
class NetworkFaults {
  const NetworkFaults({this.drop = 0, this.duplicate = 0, this.reorder = 0});
  final double drop;
  final double duplicate;

  /// The chance a message is delivered after the one behind it (on the same connection and direction).
  final double reorder;

  static const none = NetworkFaults();
}

/// One member's end of a connection.
abstract interface class MemoryEndpoint {
  void onMessage(HostMessage message);
  void onClose(String reason);
}

class _Packet {
  _Packet.toHost(this.conn, this.text) : toHost = true, close = null;
  _Packet.toMember(this.conn, this.text, {this.close}) : toHost = false;
  final String conn;
  final String? text;
  final bool toHost;
  final String? close;
}

/// A network in memory. Messages travel as JSON text, so the codec is exercised too, and wait in one queue until
/// [deliver] or [settle] moves them, which keeps a run deterministic under its seed.
class MemoryNetwork implements HostOutbox {
  MemoryNetwork({int seed = 1, this.faults = NetworkFaults.none}) : random = Random(seed);
  final Random random;
  NetworkFaults faults;

  HostCore? _host;
  final _queue = ListQueue<_Packet>();
  final _ends = <String, MemoryEndpoint>{};
  int _next = 0;

  /// Called when the host throws [SimulatedCrash]: every connection is dropped and the host detached.
  void Function(SimulatedCrash crash)? onCrash;

  HostCore? get host => _host;

  /// Attaches [host] (a new or recovered one). Connections from before are gone.
  void attach(HostCore host) => _host = host;

  /// Whether messages are waiting.
  bool get busy => _queue.isNotEmpty;

  /// Opens a connection from [address] for [end]; returns its id.
  String open(MemoryEndpoint end, {String address = '10.0.0.1', String? identity}) {
    final id = 'c${_next++}';
    _ends[id] = end;
    _host?.connect(id, address: address, identity: identity);
    return id;
  }

  bool isOpen(String conn) => _ends.containsKey(conn);

  /// Sends [message] from a member to the host.
  void post(String conn, ClientMessage message) {
    if (!_ends.containsKey(conn)) return;
    _queue.add(_Packet.toHost(conn, encodeMessage(message)));
  }

  /// Closes a member's connection from the member's side.
  void hangUp(String conn) {
    if (_ends.remove(conn) == null) return;
    _host?.disconnect(conn);
    _queue.removeWhere((p) => p.conn == conn);
  }

  /// Drops every connection (a host crash or a network partition).
  void dropAll(String reason) {
    final ends = Map.of(_ends);
    _ends.clear();
    _queue.clear();
    for (final e in ends.entries) {
      _host?.disconnect(e.key);
      e.value.onClose(reason);
    }
  }

  // HostOutbox
  @override
  void send(String connection, HostMessage message) {
    if (_ends.containsKey(connection)) _queue.add(_Packet.toMember(connection, encodeMessage(message)));
  }

  @override
  void close(String connection, String reason) {
    if (_ends.containsKey(connection)) _queue.add(_Packet.toMember(connection, null, close: reason));
  }

  /// Delivers one waiting message, with the faults applied; returns whether there was one.
  Future<bool> deliver() async {
    if (_queue.isEmpty) return false;
    var p = _queue.removeFirst();
    if (p.close == null && _queue.isNotEmpty && random.nextDouble() < faults.reorder) {
      final q = _queue.first;
      if (q.conn == p.conn && q.toHost == p.toHost && q.close == null) {
        _queue.removeFirst();
        _queue.addFirst(p);
        p = q;
      }
    }
    if (p.close != null) {
      final end = _ends.remove(p.conn);
      end?.onClose(p.close!);
      return true;
    }
    if (random.nextDouble() < faults.drop) return true;
    final copies = random.nextDouble() < faults.duplicate ? 2 : 1;
    for (var i = 0; i < copies; i++) {
      if (!_ends.containsKey(p.conn)) break;
      if (p.toHost) {
        final h = _host;
        if (h == null) continue;
        try {
          await h.receiveText(p.conn, p.text!);
        } on SimulatedCrash catch (c) {
          _host = null;
          dropAll('host crashed');
          onCrash?.call(c);
          return true;
        }
      } else {
        _ends[p.conn]!.onMessage(decodeHostMessage(p.text!));
      }
    }
    return true;
  }

  /// Delivers until nothing waits (or [maxSteps] messages moved).
  Future<void> settle({int maxSteps = 1000000}) async {
    for (var i = 0; i < maxSteps && await deliver(); i++) {}
  }
}
