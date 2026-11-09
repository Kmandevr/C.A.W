// The trust rules for native components: own code is trusted, other code asks once per exact version.
import 'dart:convert';
import 'dart:io';

import 'package:caw/engine/engine.dart';
import 'package:caw/model/cpp_component.dart';
import 'package:caw/model/native_trust.dart';
import 'package:caw/model/sha256.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sha256 matches the standard test vectors', () {
    expect(sha256Hex(utf8.encode('')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256Hex(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    expect(sha256Hex(List<int>.filled(1000000, 0x61)), 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
  });

  test('own sources are trusted, others ask once per exact version, and choices survive a restart', () async {
    final dir = await Directory.systemTemp.createTemp('caw-trust');
    addTearDown(() => dir.delete(recursive: true));
    final store = NativeTrustStore(File('${dir.path}/trust.json'));
    await store.load();
    final mine = CppComponentDoc(id: 'a', name: 'Delay', componentId: 'org.me.delay', files: {'src/d.cpp': 'int x;'});
    expect(store.decide('org.me.delay', NativeTrustStore.sourceFingerprint(mine)), isNull);  // not yet known: ask
    store.markAuthored(mine);
    expect(store.decide('org.me.delay', NativeTrustStore.sourceFingerprint(mine)), NativeComponentTrust.trusted);

    final shared = CppComponentDoc(id: 'b', name: 'Fuzz', componentId: 'org.alex.fuzz', files: {'src/f.cpp': 'int y;'});
    final fingerprint = NativeTrustStore.sourceFingerprint(shared);
    expect(store.decide('org.alex.fuzz', fingerprint), isNull);
    store.remember('org.alex.fuzz', fingerprint, NativeComponentTrust.blocked);
    await store.save();

    final again = NativeTrustStore(File('${dir.path}/trust.json'));
    await again.load();
    expect(again.decide('org.me.delay', NativeTrustStore.sourceFingerprint(mine)), NativeComponentTrust.trusted);
    expect(again.decide('org.alex.fuzz', fingerprint), NativeComponentTrust.blocked);
    shared.files['src/f.cpp'] = 'int y = 1;';  // changed code asks again
    expect(again.decide('org.alex.fuzz', NativeTrustStore.sourceFingerprint(shared)), isNull);
    again.forget('org.alex.fuzz');
    expect(again.decide('org.alex.fuzz', fingerprint), isNull);
  });
}
