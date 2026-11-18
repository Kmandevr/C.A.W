// The trust sheet: "This plug-in can:" rows from the scan and the declarations, the why fold, a blocked component offering no Trusted, and the pre-1.0.7 grace line.
import 'package:caw/engine/engine.dart';
import 'package:caw/model/capabilities.dart';
import 'package:caw/ui/capability_text.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/native_trust_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ComponentScan _scan(Map<String, dynamic> j) => ComponentScan.fromJson({'ok': true, 'sha256': 'ab', ...j});

Map<String, dynamic> _finding(String cap, {String severity = 'warning', bool declared = false, bool blocks = false}) => {
      'capability': cap, 'title': cap, 'kind': 'import', 'evidence': 'x', 'strength': 'certain',
      'severity': severity, 'declared': declared, 'blocks': blocks,
    };

void main() {
  var motion = MotionLevel.full;
  setUp(() {
    motion = Motion.setting;
    Motion.setting = MotionLevel.off;
  });
  tearDown(() => Motion.setting = motion);

  Future<NativeComponentTrust?> open(WidgetTester tester, {ComponentScan? scan, List<CapabilityDeclaration> declared = const []}) async {
    NativeComponentTrust? picked;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Builder(builder: (context) => Center(child: TextButton(
        onPressed: () async {
          picked = await showNativeTrustSheet(context, name: 'Space Delay', scan: scan, declared: declared);
          done = true;
        },
        child: const Text('open'),
      ))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(done, isFalse);
    return picked;
  }

  test('rows: declared ones with their reasons, then findings that aren\'t plain notices', () {
    final rows = TrustRow.rowsFor(scan: _scan({
      'verdict': 'warning',
      'declared': [
        {'id': 'internet', 'title': 'Internet', 'reason': 'presets', 'sites': ['a.example.com']},
        {'id': 'background_threads', 'title': 'Threads', 'reason': 'loads samples', 'sites': []},
      ],
      'findings': [
        _finding('internet', severity: 'notice', declared: true),
        _finding('read_files', severity: 'notice'), // a plain notice: no row
        _finding('encryption'), // a hint warning
        _finding('encryption'),
      ],
    }));
    expect(rows.map((r) => r.id), ['internet', 'encryption', 'background_threads']);
    expect(rows[0].normal, isFalse);
    expect(rows[0].reason, 'presets');
    expect(rows[2].normal, isTrue);
    expect(rows[1].reason, isNull);
    // Without a build, the manifest's list stands in.
    expect(TrustRow.rowsFor(declared: const [CapabilityDeclaration('write_files', 'saves loops')]).single.normal, isTrue);
  });

  testWidgets('the owner\'s layout: a warning row with its risk and fold, a normal row, three choices', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, scan: _scan({
      'verdict': 'notice',
      'declarations': 'valid',
      'declared': [
        {'id': 'internet', 'title': 'Internet', 'reason': 'Downloads the factory presets', 'sites': ['presets.example.com']},
        {'id': 'background_threads', 'title': 'Threads', 'reason': 'Loads long samples', 'sites': []},
      ],
      'findings': [_finding('internet', severity: 'notice', declared: true)],
    }));
    expect(find.text('Add "Space Delay"'), findsOneWidget);
    expect(find.text(CapabilityText.sheetHeading), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-row-internet')), findsOneWidget);
    expect(find.textContaining('Use the internet'), findsOneWidget);
    expect(find.text(CapabilityText.all['internet']!.risk), findsOneWidget);
    expect(find.textContaining('Downloads the factory presets'), findsOneWidget);
    expect(find.textContaining('presets.example.com'), findsOneWidget);
    expect(find.textContaining('Start background threads'), findsOneWidget);
    expect(find.textContaining(CapabilityText.normalTag), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-why-background_threads')), findsNothing); // normal rows stay one line

    // The fold opens and closes.
    expect(find.text(CapabilityText.all['internet']!.why), findsNothing);
    await tester.tap(find.byKey(const ValueKey('trust-why-internet')));
    await tester.pumpAndSettle();
    expect(find.text(CapabilityText.all['internet']!.why), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trust-why-internet')));
    await tester.pumpAndSettle();
    expect(find.text(CapabilityText.all['internet']!.why), findsNothing);

    // Isolated is there but can't be chosen yet; Trusted and Blocked can.
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('trust-isolated'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('trust-trusted')), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-blocked')), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-grace')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Trusted and Blocked return the choice', (tester) async {
    for (final (key, want) in [('trust-trusted', NativeComponentTrust.trusted), ('trust-blocked', NativeComponentTrust.blocked)]) {
      NativeComponentTrust? picked;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () async => picked = await showNativeTrustSheet(context, name: 'X'),
        child: const Text('open'),
      ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trust-nothing')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(picked, want);
    }
  });

  testWidgets('a blocked component says why and offers no Trusted', (tester) async {
    await open(tester, scan: _scan({
      'verdict': 'blocked',
      'declarations': 'valid',
      'blocked_by': ['internet', 'start_programs'],
      'findings': [_finding('internet', blocks: true), _finding('start_programs', blocks: true)],
    }));
    expect(find.byKey(const ValueKey('trust-trusted')), findsNothing);
    expect(find.byKey(const ValueKey('trust-blocked')), findsOneWidget);
    expect(find.text('Blocked: it uses Internet and Start programs without declaring them.'), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-row-internet')), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-row-start_programs')), findsOneWidget);
  });

  testWidgets('a scan that failed blocks too', (tester) async {
    await open(tester, scan: const ComponentScan(ok: false, error: 'malformed'));
    expect(find.byKey(const ValueKey('trust-trusted')), findsNothing);
    expect(find.byKey(const ValueKey('trust-blocked-why')), findsOneWidget);
  });

  testWidgets('a build from before 1.0.7 loading under grace shows the rebuild line', (tester) async {
    await open(tester, scan: _scan({
      'verdict': 'warning',
      'declarations': 'absent',
      'grace_applied': true,
      'findings': [_finding('background_threads')],
    }));
    expect(find.byKey(const ValueKey('trust-grace')), findsOneWidget);
    expect(find.text(CapabilityText.graceLine), findsOneWidget);
    expect(find.byKey(const ValueKey('trust-trusted')), findsOneWidget);
  });

  testWidgets('the fold animates at full and reduced motion inside the phone sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final level in [MotionLevel.full, MotionLevel.reduced]) {
      Motion.setting = level;
      await open(tester, scan: _scan({'verdict': 'warning', 'findings': [_finding('encryption')]}));
      await tester.tap(find.byKey(const ValueKey('trust-why-encryption')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();
      expect(find.text(CapabilityText.all['encryption']!.why), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('trust-blocked')));
      await tester.pumpAndSettle();
    }
  });

  test('an unknown verdict reads as blocked, never clean', () {
    expect(_scan({'verdict': 'quarantined'}).blocked, isTrue);
    expect(ComponentScan.fromJsonText('not json').blocked, isTrue);
  });
}
