// Tests the shared building blocks (context toolbar, tool buttons, info button), the design tokens and eight track
// colours, with a golden of the toolbar in its three piano-roll states at phone width.
import 'package:caw/model/project.dart';
import 'package:caw/ui/kit.dart';
import 'package:caw/ui/motion.dart';
import 'package:caw/ui/theme.dart';
import 'package:caw/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_util.dart';

Widget _toolbar(String state, {String tool = 'draw'}) => ContextToolbar(
      contextKey: state,
      leading: [
        ToolButton(icon: Icons.edit, label: 'Draw', selected: tool == 'draw', onPressed: () {}),
        ToolButton(icon: Icons.highlight_alt, label: 'Select', selected: tool == 'select', onPressed: () {}),
        ToolButton(icon: Icons.gesture, label: 'Curve', selected: tool == 'curve', onPressed: () {}),
        ToolButton(icon: Icons.backspace_outlined, label: 'Erase', selected: tool == 'erase', onPressed: () {}),
      ],
      middle: switch (state) {
        'notes' => [
            ToolButton(icon: Icons.content_copy, label: 'Copy', onPressed: () {}),
            ToolButton(icon: Icons.content_paste, label: 'Paste', onPressed: () {}),
            ToolButton(icon: Icons.copy_all, label: 'Duplicate', onPressed: () {}),
            ToolButton(icon: Icons.delete_outline, label: 'Delete', color: Roles.danger, onPressed: () {}),
          ],
        _ => [
            ToolButton(icon: Icons.equalizer, label: 'Velocity lane', onPressed: () {}),
            ToolButton(icon: Icons.fit_screen, label: 'Zoom to fit', onPressed: () {}),
          ],
      },
      trailing: [ToolButton(icon: Icons.more_vert, label: 'More', onPressed: () {})],
    );

void main() {
  tearDown(() => Motion.setting = MotionLevel.full);

  test('every theme has eight track colours and new tracks use all of them', () {
    expect(Neon.layers, hasLength(LayerDoc.trackColors));
    for (final t in starterThemes) {
      for (var i = 1; i <= 8; i++) {
        expect(t.colors.containsKey('layer$i'), isTrue, reason: '${t.name} layer$i');
      }
    }
    expect(Roles.track(8), Neon.layer(0));
  });

  test('a theme file without the new track colours still loads, falling back to Calm neon', () {
    final t = CawTheme.parse('---\nkind: theme\nname: Old\n---\nlayer1: #112233\n');
    expect(t['layer1'], const Color(0xFF112233));
    expect(t['layer8'], calmNeon['layer8']);
  });

  testWidgets('the middle part changes with the context, animating at full motion', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: Scaffold(body: _toolbar('none'))));
    expect(find.byTooltip('Zoom to fit'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: Scaffold(body: _toolbar('notes'))));
    await tester.pump(const Duration(milliseconds: 80));
    // Mid-transition both parts are on screen; after the standard duration only the new one remains.
    expect(find.byTooltip('Zoom to fit'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Zoom to fit'), findsNothing);
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('with motion off the middle part swaps at once', (tester) async {
    Motion.setting = MotionLevel.off;
    await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: Scaffold(body: _toolbar('none'))));
    await tester.pumpWidget(MaterialApp(theme: Neon.theme(), home: Scaffold(body: _toolbar('notes'))));
    await tester.pump();
    expect(find.byTooltip('Zoom to fit'), findsNothing);
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('tool buttons are 48 dp targets that report their selected state', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: Neon.theme(),
      home: Scaffold(body: Row(children: [
        ToolButton(icon: Icons.edit, label: 'Draw', selected: true, onPressed: () => taps++),
      ])),
    ));
    expect(tester.getSize(find.byType(ToolButton)), const Size(48, 48));
    await tester.tap(find.byType(ToolButton));
    expect(taps, 1);
    expect(tester.getSemantics(find.byType(ToolButton)), matchesSemantics(label: 'Draw', isButton: true, isSelected: true, hasSelectedState: true));
  });

  testWidgets('compact density makes tool buttons 36 dp', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: Neon.theme(compact: true),
      home: Scaffold(body: Row(children: [ToolButton(icon: Icons.edit, label: 'Draw', onPressed: () {})])),
    ));
    expect(tester.getSize(find.byType(ToolButton)), const Size(36, 36));
  });

  testWidgets('the info button shows its help in a sheet', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: Neon.theme(),
      home: const Scaffold(body: InfoButton(title: 'Exports', text: 'Offline exports use the native renderer.')),
    ));
    await tester.tap(find.byTooltip('About Exports'));
    await tester.pumpAndSettle();
    expect(find.text('Offline exports use the native renderer.'), findsOneWidget);
  });

  testWidgets('toolbar states, phone', (tester) async {
    await pumpGolden(
      tester,
      Scaffold(
        body: Column(children: [
          _toolbar('none'),
          const SizedBox(height: Space.s),
          _toolbar('notes', tool: 'select'),
          const SizedBox(height: Space.s),
          Row(children: [for (var i = 0; i < 8; i++) Expanded(child: Container(height: 24, color: Roles.track(i)))]),
        ]),
      ),
      const Size(390, 160),
    );
    await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/toolbar_phone.png'));
  });
}
