// CRC-32 (the IEEE 802.3 polynomial, as zip and PNG use it) for the host's write-ahead log frames.
import 'dart:typed_data';

final Uint32List _table = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// The CRC-32 of [data] (bytes [start] to [end]); `crc32('123456789'.codeUnits)` is 0xcbf43926.
int crc32(List<int> data, [int start = 0, int? end]) {
  var c = 0xffffffff;
  final stop = end ?? data.length;
  for (var i = start; i < stop; i++) {
    c = _table[(c ^ data[i]) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
