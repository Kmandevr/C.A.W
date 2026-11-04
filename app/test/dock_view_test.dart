// Tests the dock view: drop zones, tab taps, divider drags, long-press drags onto a drop zone, maximise, panels that
// keep their state when they move, hidden tabs with tickers off, and goldens of the presets at the three sizes.
import 'package:caw/ui/dock/dock_view.dart';
import 'package:caw/ui/dock/layout.dart';
import 'package:caw/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

/// Holds the layout like the shell will, and records it for the test.
class _Host extends StatefulWidget {
  const _Host(this.initial, {this.onLayout});
  final DockLayout initial;
  final ValueChanged<DockLayout>? onLayout;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late DockLayout layout = widget.initial;
  void set(DockLayout l) {
    setState(() => layout = l);
    widget.onLayout?.call(l);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DockView(layout: layout, onChanged: set, panelBuilder: (_, id) => _Probe(id)),
      );
}

/// A panel body with state (a tap count) and a note of whether its tickers run.
class _Probe extends StatefulWidget {
  const _Probe(this.id);
  final String id;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => taps++),
        child: Center(
          child: Text('${dockPanelTitle(widget.id)} $taps ${TickerMode.of(context) ? 'live' : 'paused'}',
              style: TextStyle(color: Neon.text)),
        ),
      );
}

DockLayout _two() => DockLayout(SplitNode(DockAxis.row, [
      TabsNode([Panels.arrangement]),
      TabsNode([Panels.mixer, Panels.files]),
    ]));

Future<void> _pump(WidgetTester tester, DockLayout l, {ValueChanged<DockLayout>? onLayout, Size? size}) async {
  tester.view.physicalSize = size ?? const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: _Host(l, onLayout: onLayout)));
  await tester.pumpAndSettle();
}

void main() {
  group('drop zones', () {
    test('the middle half joins the group; near an edge splits on that edge', () {
      const s = Size(400, 200);
      expect(dockEdgeAt(const Offset(200, 100), s), DockEdge.center);
      expect(dockEdgeAt(const Offset(20, 100), s), DockEdge.left);
      expect(dockEdgeAt(const Offset(390, 100), s), DockEdge.right);
      expect(dockEdgeAt(const Offset(200, 10), s), DockEdge.top);
      expect(dockEdgeAt(const Offset(200, 195), s), DockEdge.bottom);
      expect(dockEdgeAt(const Offset(5, 5), Size.zero), DockEdge.center);
    });
  });

  testWidgets('shows each group\'s active panel; a tab tap shows another; hidden tabs keep state with tickers off',
      (tester) async {
    await _pump(tester, _two());
    expect(find.text('Arrange 0 live'), findsOneWidget);
    expect(find.text('Mixer 0 live'), findsOneWidget);
    await tester.tap(find.text('Mixer 0 live'));
    await tester.pump();
    expect(find.text('Mixer 1 live'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dock-tab-files')));
    await tester.pumpAndSettle();
    expect(find.text('Files 0 live'), findsOneWidget);
    // The mixer is still mounted, with its state, and its tickers are off.
    expect(find.text('Mixer 1 paused', skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dock-tab-mixer')));
    await tester.pumpAndSettle();
    expect(find.text('Mixer 1 live'), findsOneWidget);
  });

  testWidgets('a panel keeps its state when it moves to another group', (tester) async {
    await _pump(tester, _two());
    await tester.tap(find.text('Mixer 0 live'));
    await tester.pump();
    final host = tester.state<_HostState>(find.byType(_Host));
    host.set(host.layout.dock(Panels.mixer, target: Panels.arrangement, edge: DockEdge.bottom));
    await tester.pumpAndSettle();
    expect(find.text('Mixer 1 live'), findsOneWidget);
  });

  testWidgets('dragging a divider moves the boundary, never below the minimum share', (tester) async {
    DockLayout? last;
    await _pump(tester, _two(), onLayout: (l) => last = l);
    final divider = find.byKey(const ValueKey('dock-divider-row-0'));
    await tester.drag(divider, const Offset(120, 0));
    await tester.pumpAndSettle();
    final w = (last!.root as SplitNode).weights;
    expect(w[0], greaterThan(0.6));
    await tester.drag(divider, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect((last!.root as SplitNode).weights[1], closeTo(DockLayout.minWeight, 1e-6));
  });

  testWidgets('a long-pressed tab dropped near another group\'s edge splits it there', (tester) async {
    DockLayout? last;
    await _pump(tester, _two(), onLayout: (l) => last = l);
    final tab = tester.getCenter(find.byKey(const ValueKey('dock-tab-files')));
    final arrange = tester.getRect(find.text('Arrange 0 live').hitTestable());
    final g = await tester.startGesture(tab);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // Move to the bottom edge of the arrangement's group (its body spans most of the left half).
    await g.moveTo(Offset(arrange.center.dx, 590));
    await tester.pump();
    expect(find.byKey(const ValueKey('dock-drop-bottom')), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    expect(last, isNotNull);
    final left = (last!.root as SplitNode).children.first as SplitNode;
    expect(left.axis, DockAxis.column);
    expect([for (final c in left.children) (c as TabsNode).panels], [
      [Panels.arrangement],
      [Panels.files],
    ]);
    expect(find.text('Files 0 live'), findsOneWidget);
  });

  testWidgets('maximise fills the view with one panel and keeps the rest; restore brings the layout back',
      (tester) async {
    await _pump(tester, _two());
    await tester.tap(find.text('Arrange 0 live'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dock-max-mixer')));
    await tester.pumpAndSettle();
    expect(find.text('Mixer 0 live'), findsOneWidget);
    expect(find.text('Arrange 1 live'), findsNothing);
    expect(find.text('Arrange 1 paused', skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dock-max-mixer')));
    await tester.pumpAndSettle();
    expect(find.text('Arrange 1 live'), findsOneWidget);
    expect(find.text('Mixer 0 live'), findsOneWidget);
  });

  group('goldens', () {
    for (final (name, form) in [
      ('phone', FormFactor.phonePortrait),
      ('landscape', FormFactor.phoneLandscape),
      ('desktop', FormFactor.desktop),
    ]) {
      testWidgets('arrange preset, $name', (tester) async {
        final l = DockLayout.preset(form);
        await pumpGolden(
          tester,
          Scaffold(body: DockView(layout: l, onChanged: (_) {}, panelBuilder: (_, id) => _Probe(id))),
          goldenSizes[name]!,
        );
        await expectLater(find.byType(DockView), matchesGoldenFile('goldens/dock_$name.png'));
      });
    }
  });
}
