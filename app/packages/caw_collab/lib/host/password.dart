// Lobby passwords: HMAC-SHA256 over caw_services' SHA-256, PBKDF2-HMAC-SHA256, a salted slow hash in one
// self-describing string, and a constant-time check.
//
// Assumption: the design proposes scrypt or Argon2id; the package's dependency set (caw_services) has neither, so
// this is PBKDF2-HMAC-SHA256 (RFC 8018), with OWASP's recommended 600,000 iterations as the default
// ([Fact, OWASP Password Storage Cheat Sheet, "PBKDF2-HMAC-SHA256: 600,000 iterations", read 2026-11-27]).
// PBKDF2 is not memory-hard, so it is weaker against GPU guessing than scrypt or Argon2id; the per-address attempt
// limit guards the online path, and a long password guards the offline one.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:caw_services/sha256.dart';

Uint8List _digest(List<int> a, [List<int>? b]) {
  final h = Sha256()..add(a);
  if (b != null) h.add(b);
  final hex = h.hex();
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// HMAC-SHA256 (RFC 2104) of [message] under [key].
Uint8List hmacSha256(List<int> key, List<int> message) => _Hmac(key).mac(message);

class _Hmac {
  _Hmac(List<int> key) {
    final k = Uint8List(64)..setAll(0, key.length > 64 ? _digest(key) : key);
    for (var i = 0; i < 64; i++) {
      _ipad[i] = k[i] ^ 0x36;
      _opad[i] = k[i] ^ 0x5c;
    }
  }
  final _ipad = Uint8List(64), _opad = Uint8List(64);

  Uint8List mac(List<int> message) => _digest(_opad, _digest(_ipad, message));
}

/// PBKDF2-HMAC-SHA256 (RFC 8018 section 5.2): [length] bytes from [password] and [salt] after [iterations].
///
/// The first HMAC of each block goes through caw_services' SHA-256; the iterations after it run on a fixed-size
/// SHA-256 compression with the key's inner and outer states computed once, which gives the same bytes (the
/// tests check it against the plain HMAC and RFC 7914's PBKDF2-HMAC-SHA256 vectors) about ten times faster, since
/// the general hash allocates and formats hex for every call.
Uint8List pbkdf2HmacSha256(List<int> password, List<int> salt, int iterations, int length) {
  if (iterations < 1 || length < 1) throw ArgumentError('iterations and length must be positive');
  final prf = _Hmac(password);
  final inner = _state(prf._ipad), outer = _state(prf._opad);
  final out = Uint8List(length);
  final w = Uint32List(64), h = Uint32List(8);
  final u = Uint32List(8), t = Uint32List(8);
  for (var block = 1, at = 0; at < length; block++) {
    final first = prf.mac([...salt, block >> 24 & 0xff, block >> 16 & 0xff, block >> 8 & 0xff, block & 0xff]);
    final view = ByteData.sublistView(first);
    for (var i = 0; i < 8; i++) {
      u[i] = t[i] = view.getUint32(i * 4);
    }
    for (var i = 1; i < iterations; i++) {
      // inner = H(ipad-state, u || padding for 64 + 32 bytes), then outer = H(opad-state, inner || padding).
      for (var pass = 0; pass < 2; pass++) {
        final st = pass == 0 ? inner : outer;
        for (var j = 0; j < 8; j++) {
          w[j] = u[j];
        }
        w[8] = 0x80000000;
        for (var j = 9; j < 15; j++) {
          w[j] = 0;
        }
        w[15] = (64 + 32) * 8;
        h.setAll(0, st);
        _compress(h, w);
        u.setAll(0, h);
      }
      for (var j = 0; j < 8; j++) {
        t[j] ^= u[j];
      }
    }
    final bytes = ByteData(32);
    for (var i = 0; i < 8; i++) {
      bytes.setUint32(i * 4, t[i]);
    }
    final n = min(32, length - at);
    out.setRange(at, at + n, bytes.buffer.asUint8List());
    at += n;
  }
  return out;
}

const _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

// The SHA-256 state after compressing one 64-byte block (a key xor pad) from the initial value.
Uint32List _state(Uint8List block) {
  final h = Uint32List.fromList([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  final w = Uint32List(64);
  final v = ByteData.sublistView(block);
  for (var i = 0; i < 16; i++) {
    w[i] = v.getUint32(i * 4);
  }
  _compress(h, w);
  return h;
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

// One SHA-256 compression of the 16 words in w[0..15] into h (FIPS 180-4 section 6.2.2).
void _compress(Uint32List h, Uint32List w) {
  for (var i = 16; i < 64; i++) {
    final a = w[i - 15], b = w[i - 2];
    final s0 = _rotr(a, 7) ^ _rotr(a, 18) ^ (a >> 3);
    final s1 = _rotr(b, 17) ^ _rotr(b, 19) ^ (b >> 10);
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
  }
  var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (var i = 0; i < 64; i++) {
    final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final ch = (e & f) ^ ((~e & 0xffffffff) & g);
    final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
    final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = (s0 + maj) & 0xffffffff;
    hh = g;
    g = f;
    f = e;
    e = (d + t1) & 0xffffffff;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xffffffff;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += hh;
}

/// Whether [a] and [b] are equal, in a time that depends only on their lengths.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// A lobby password kept only as a salted slow hash: `pbkdf2-sha256$<iterations>$<salt>$<hash>`, salt and hash
/// in unpadded base64url.
class PasswordHash {
  const PasswordHash._(this.encoded, this.iterations, this._salt, this._hash);

  /// OWASP's recommended iteration count for PBKDF2-HMAC-SHA256 (see the file comment).
  static const int defaultIterations = 600000;

  /// The most iterations a stored hash may claim, so a tampered store can't stall the host.
  static const int maxIterations = 10000000;

  /// The fewest iterations a new or stored hash may have, so a weak or tampered hash is refused.
  ///
  /// Assumption: 100,000, a sixth of OWASP's recommendation, leaves room for slow phones; the design sets no
  /// floor.
  static const int minIterations = 100000;

  /// The floor in force: [minIterations]. Lower it only in tests, which use small counts to stay fast.
  static int floor = minIterations;

  final String encoded;
  final int iterations;
  final Uint8List _salt, _hash;

  /// A new hash of [password] with a 16-byte random salt; [iterations] must be within [floor] and
  /// [maxIterations].
  factory PasswordHash.create(String password, {int iterations = defaultIterations, Random? random}) {
    if (iterations < floor || iterations > maxIterations) {
      throw ArgumentError.value(iterations, 'iterations', 'outside $floor..$maxIterations');
    }
    final r = random ?? Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    final hash = pbkdf2HmacSha256(utf8.encode(password), salt, iterations, 32);
    return PasswordHash._('pbkdf2-sha256\$$iterations\$${_b64(salt)}\$${_b64(hash)}', iterations, salt, hash);
  }

  /// Reads a stored hash, or returns null when [encoded] is not one or its iterations are outside [floor] and
  /// [maxIterations].
  static PasswordHash? parse(String encoded) {
    final p = encoded.split('\$');
    if (p.length != 4 || p[0] != 'pbkdf2-sha256') return null;
    final it = int.tryParse(p[1]);
    if (it == null || it < floor || it > maxIterations) return null;
    try {
      final salt = base64Url.decode(base64Url.normalize(p[2]));
      final hash = base64Url.decode(base64Url.normalize(p[3]));
      if (salt.length < 8 || salt.length > 64 || hash.length != 32) return null;
      return PasswordHash._(encoded, it, salt, hash);
    } on FormatException {
      return null;
    }
  }

  /// Whether [password] is the one hashed here.
  bool verify(String password) =>
      constantTimeEquals(pbkdf2HmacSha256(utf8.encode(password), _salt, iterations, 32), _hash);

  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');
}
