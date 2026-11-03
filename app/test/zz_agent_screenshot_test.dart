// TEMPORARY self-test for the Quick check `screenshot` command; removed in the next commit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('agent screenshot self-test', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: Text('C.A.W')))));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screens/selftest.png'));
  });
}
