// Tests the shared atomic file writer: overlapping writes to one path land whole, newest last.
import 'dart:convert';
import 'dart:io';

import 'package:caw/model/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('writes started together land in call order and the file always parses', () async {
    final dir = await Directory.systemTemp.createTemp('atomic');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/x.json');
    for (var round = 0; round < 20; ++round) {
      final writes = <Future<void>>[];
      for (var i = 0; i < 8; ++i) {
        writes.add(writeFileAtomically(file, jsonEncode({'i': i, 'pad': 'x' * ((i * 997 + round * 31) % 4000)})));
      }
      await Future.wait(writes);
      final back = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(back['i'], 7, reason: 'round $round');
    }
  });
}
