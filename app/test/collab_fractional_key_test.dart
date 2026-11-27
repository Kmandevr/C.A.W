// caw_collab's fractional keys: strict order, between() always between, bounded growth under repeated inserts,
// the host's tie-break suffix, and refusals of malformed keys.
import 'dart:math';

import 'package:caw_collab/caw_collab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void between(String? a, String? b, String k) {
    expect(FractionalKeys.isValid(k), isTrue, reason: '$k from ($a, $b)');
    if (a != null) expect(a.compareTo(k), lessThan(0), reason: '$a < $k');
    if (b != null) expect(k.compareTo(b), lessThan(0), reason: '$k < $b');
  }

  test('the first key and keys at the ends', () {
    expect(FractionalKeys.between(null, null), 'V');
    between('V', null, FractionalKeys.between('V', null));
    between(null, 'V', FractionalKeys.between(null, 'V'));
    between(null, '1', FractionalKeys.between(null, '1'));
    between(null, '01', FractionalKeys.between(null, '01'));
    between('z', null, FractionalKeys.between('z', null));
    between('zzz', null, FractionalKeys.between('zzz', null));
  });

  test('between neighbouring and nested keys', () {
    for (final (a, b) in [('V', 'W'), ('V', 'V1'), ('V', 'VV'), ('a', 'a01'), ('0z', '1'), ('Vz', 'W'), ('y', 'z'), ('1', 'z'), ('V1', 'W')]) {
      between(a, b, FractionalKeys.between(a, b));
    }
  });

  test('random pairs: the key is always strictly between', () {
    final r = Random(7);
    String rand() {
      final n = 1 + r.nextInt(6);
      final s = StringBuffer();
      for (var i = 0; i < n - 1; i++) {
        s.write(FractionalKeys.digits[r.nextInt(62)]);
      }
      s.write(FractionalKeys.digits[1 + r.nextInt(61)]);
      return s.toString();
    }

    for (var i = 0; i < 20000; i++) {
      var a = rand(), b = rand();
      if (a == b) continue;
      if (a.compareTo(b) > 0) (a, b) = (b, a);
      between(a, b, FractionalKeys.between(a, b));
      between(a, null, FractionalKeys.between(a, null));
      between(null, b, FractionalKeys.between(null, b));
    }
  });

  test('random inserts into one list keep a strict order and short keys', () {
    final r = Random(11);
    final keys = <String>[];
    for (var i = 0; i < 5000; i++) {
      final at = r.nextInt(keys.length + 1);
      final k = FractionalKeys.between(at == 0 ? null : keys[at - 1], at == keys.length ? null : keys[at]);
      keys.insert(at, k);
    }
    for (var i = 1; i < keys.length; i++) {
      expect(keys[i - 1].compareTo(keys[i]), lessThan(0));
    }
    // 5,000 random inserts: the longest key stays a few characters (log-like growth).
    expect(keys.map((k) => k.length).reduce(max), lessThanOrEqualTo(12));
  });

  test('appending and prepending grow by about one character per 61 inserts', () {
    var last = FractionalKeys.between(null, null);
    var first = last;
    for (var i = 0; i < 10000; i++) {
      final a = FractionalKeys.between(last, null);
      expect(last.compareTo(a), lessThan(0));
      last = a;
      final p = FractionalKeys.between(null, first);
      expect(p.compareTo(first), lessThan(0));
      first = p;
    }
    expect(last.length, lessThanOrEqualTo(10000 ~/ 61 + 2));
    expect(first.length, lessThanOrEqualTo(10000 ~/ 61 + 2));
  });

  test('inserting again and again at one gap grows by about one character per 6 inserts', () {
    for (final after in [true, false]) {
      var a = 'V', b = 'W';
      for (var i = 0; i < 600; i++) {
        final k = FractionalKeys.between(a, b);
        between(a, b, k);
        if (after) {
          b = k;
        } else {
          a = k;
        }
      }
      expect((after ? b : a).length, lessThanOrEqualTo(600 ~/ 5 + 2));
    }
  });

  test('the tie-break suffix is unique per author and drops trailing zeros', () {
    final k = FractionalKeys.between('V', 'X');
    final s1 = FractionalKeys.withSuffix(k, 'Kim123456');
    final s2 = FractionalKeys.withSuffix(k, 'Sam987654');
    expect(s1, '${k}Kim123');
    expect(s1, isNot(s2));
    expect(k.compareTo(s1), lessThan(0));
    expect(FractionalKeys.isValid(FractionalKeys.withSuffix(k, 'ab0000')), isTrue);
    expect(FractionalKeys.withSuffix(k, '000000'), '${k}1');
  });

  test('malformed keys are refused', () {
    for (final bad in ['', 'V0', 'a-b', 'é', 'V V']) {
      expect(FractionalKeys.isValid(bad), isFalse, reason: bad);
      expect(() => FractionalKeys.between(bad, null), throwsArgumentError);
    }
    expect(FractionalKeys.isValid('a' * 1025), isFalse);
    expect(() => FractionalKeys.between('W', 'V'), throwsArgumentError);
    expect(() => FractionalKeys.between('V', 'V'), throwsArgumentError);
  });
}
