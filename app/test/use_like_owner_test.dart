// Every built-in device used the way the owner uses it on a phone (1.1.3-alpha.1, "most of the knobs and all of the effects don't do anything"): each device of the library on a new project's track, its page at phone size, and every control on it touched with a real finger and a mouse; the value must move and reach the engine. The big group runs in use_like_owner_<n>_test.dart, a quarter of the devices each (harness: use_like_owner/harness.dart).
import 'package:caw/engine/component_info.dart';
import 'package:caw/model/app_state.dart';
import 'package:caw/model/files_catalog.dart';
import 'package:caw/model/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'use_like_owner/harness.dart';

Future<void> main() async {
  final o = await ownerSuite();
  final cases = o.cases;
  // A device the library offers must play where it goes: a MIDI effect on an effect chain is left out by the engine.
  testWidgets('the library offers no MIDI effect for a chain', (tester) async {
    final s = AppState(settings: Settings());
    s.nativeCatalog = [
      ...o.catalog,
      const NativeComponentInfo(id: 'org.caw.midi.test', name: 'Arp', role: 'event_processor', ports: [], parameters: []),
    ];
    expect(s.builtinAssets.where((a) => a.native?.role == 'event_processor'), isEmpty);
    expect(s.builtinAssets.where((a) => a.native?.id == 'org.caw.drive'), isNotEmpty);
    s.dispose();
  });

  // The big group's parts (use_like_owner_<n>_test.dart) together run every device, each once.
  test('the parts of "$everyControlGroup" run every device once', () {
    final runs = <String, int>{};
    for (var p = 1; p <= ownerParts; p++) {
      for (final c in o.part(p)) {
        runs.update(o.name(c), (n) => n + 1, ifAbsent: () => 1);
      }
    }
    expect(runs.keys.toSet(), {for (final c in cases) o.name(c)});
    expect(runs.entries.where((e) => e.value != 1), isEmpty);
    expect(runs.values.fold(0, (a, b) => a + b), cases.length);
  });

  // Settings › Knobs turn with › Up and down: a quick swipe still scrolls, a rest then any drag turns the knob.
  group('with knobs set to turn up and down', () {
    for (final c in cases.where((c) => const {'org.caw.drive#0', 'org.caw.reverb#0', 'org.caw.synth.flagship',
        'org.caw.timber'}.contains(o.name(c)))) {
      testWidgets(o.name(c), (tester) async {
        final (s, t, engine) = await o.open(tester, c, sideways: false);
        final findings = await o.work(tester, c, s, t, engine);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        s.dispose();
        expect(findings, isEmpty, reason: findings.join('\n'));
      });
    }
  });
}
