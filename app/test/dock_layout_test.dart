// Tests the docking layout model: every edit, its invariants (each panel at most once, at least one panel), the
// presets per form factor and the damage-tolerant JSON form.
import 'dart:convert';

import 'package:caw/ui/dock/layout.dart';
import 'package:flutter_test/flutter_test.dart';

void expectValid(DockLayout l) {
  final ps = l.panels;
  expect(ps.toSet().length, ps.length, reason: 'a panel appears twice: $ps');
  expect(ps, isNotEmpty);
  void check(DockNode n) {
    switch (n) {
      case TabsNode t:
        expect(t.panels, isNotEmpty);
        expect(t.active, inInclusiveRange(0, t.panels.length - 1));
      case SplitNode s:
        expect(s.children.length, greaterThanOrEqualTo(2), reason: 'one-child splits collapse');
        expect(s.weights.fold(0.0, (a, b) => a + b), closeTo(1, 1e-9));
        for (final c in s.children) {
          if (c is SplitNode) expect(c.axis, isNot(s.axis), reason: 'same-axis splits merge');
          check(c);
        }
    }
  }

  check(l.root);
}

void main() {
  group('presets', () {
    for (final form in FormFactor.values) {
      for (final p in DockPreset.values) {
        test('${form.name} ${p.name} holds every panel once', () {
          final l = DockLayout.preset(form, p);
          expectValid(l);
          expect(l.panels.toSet(), Panels.all.toSet());
        });
      }
    }

    test('phone portrait stacks the arrangement over the other panels; landscape and desktop put them side by side', () {
      final portrait = DockLayout.preset(FormFactor.phonePortrait).root as SplitNode;
      expect(portrait.axis, DockAxis.column);
      expect((portrait.children.first as TabsNode).panels, [Panels.arrangement]);
      expect(portrait.weights.first, closeTo(0.55, 1e-9));
      expect((DockLayout.preset(FormFactor.phoneLandscape).root as SplitNode).axis, DockAxis.row);
      expect((DockLayout.preset(FormFactor.desktop).root as SplitNode).weights.first, closeTo(0.62, 1e-9));
    });

    test('the Code preset leads with the builder', () {
      expect(DockLayout.preset(FormFactor.desktop, DockPreset.code).visible.first, Panels.builder);
    });

    test('the retired workspaces are no panels: a saved layout naming one drops it (#139)', () {
      expect(Panels.all, [Panels.arrangement, Panels.builder, Panels.files]);
      for (final gone in ['mixer', 'automation', 'exporter', 'engineLab', 'pluginBuilder']) {
        expect(Panels.known(gone), isFalse, reason: gone);
      }
      final l = DockLayout.fromJson({'tabs': ['arrangement', 'mixer', 'exporter'], 'active': 1})!;
      expect(l.panels, [Panels.arrangement]);
    });
  });

  group('edits', () {
    final base = DockLayout.preset(FormFactor.phonePortrait);

    test('activate shows a panel in its group; the visible list is each group\'s active panel', () {
      expect(base.visible, [Panels.arrangement, Panels.builder]);
      final l = base.activate(Panels.files);
      expect(l.visible, [Panels.arrangement, Panels.files]);
      expectValid(l);
    });

    test('dock to the centre moves a panel into another group and shows it there', () {
      final l = base.dock(Panels.files, target: Panels.arrangement);
      expectValid(l);
      final top = (l.root as SplitNode).children.first as TabsNode;
      expect(top.panels, [Panels.arrangement, Panels.files]);
      expect(top.activePanel, Panels.files);
      expect(l.panels.where((p) => p == Panels.files), hasLength(1));
    });

    test('dock to an edge splits the target, and a same-axis split joins its parent', () {
      // Bottom of the arrangement, in a column layout: a third row of the root, sharing the arrangement's share.
      final l = base.dock(Panels.files, target: Panels.arrangement, edge: DockEdge.bottom);
      expectValid(l);
      final root = l.root as SplitNode;
      expect(root.axis, DockAxis.column);
      expect(root.children, hasLength(3));
      expect((root.children[1] as TabsNode).panels, [Panels.files]);
      expect(root.weights[0], closeTo(0.275, 1e-9));
      expect(root.weights[1], closeTo(0.275, 1e-9));
      // Right of the arrangement: a row nested in the column.
      final r = base.dock(Panels.files, target: Panels.arrangement, edge: DockEdge.right);
      expectValid(r);
      final row = (r.root as SplitNode).children.first as SplitNode;
      expect(row.axis, DockAxis.row);
      expect([for (final c in row.children) (c as TabsNode).panels.first], [Panels.arrangement, Panels.files]);
    });

    test('moving the only panel of a group removes the group and collapses its split', () {
      final single = DockLayout(SplitNode(DockAxis.row, [TabsNode([Panels.arrangement]), TabsNode([Panels.files])]));
      final l = single.dock(Panels.files, target: Panels.arrangement);
      expectValid(l);
      expect(l.root, isA<TabsNode>());
      expect((l.root as TabsNode).panels, [Panels.arrangement, Panels.files]);
    });

    test('a panel can\'t dock onto itself, onto a missing target, or be an unknown id', () {
      expect(identical(base.dock(Panels.arrangement, target: Panels.arrangement, edge: DockEdge.left), base), isTrue);
      final small = DockLayout(TabsNode([Panels.arrangement]));
      expect(identical(small.dock(Panels.builder, target: Panels.files), small), isTrue);
      expect(identical(small.dock('nope', target: Panels.arrangement), small), isTrue);
    });

    test('remove keeps at least one panel and keeps a neighbour in view', () {
      final one = DockLayout(TabsNode([Panels.arrangement]));
      expect(identical(one.remove(Panels.arrangement), one), isTrue);
      final l = base.activate(Panels.files).remove(Panels.files);
      expectValid(l);
      expect(l.contains(Panels.files), isFalse);
      expect(l.visible.last, isNot(Panels.files));
      // Removing the last tab of a group removes the group.
      final g = base.remove(Panels.arrangement);
      expectValid(g);
      expect(g.root, isA<TabsNode>());
    });

    test('reveal activates a present panel, and adds a missing one to the main group', () {
      final shown = base.reveal(Panels.files);
      expect(shown.visible, contains(Panels.files));
      final gone = base.remove(Panels.files);
      final back = gone.reveal(Panels.files);
      expectValid(back);
      expect(back.visible, contains(Panels.files));
      final mainGroup = (back.root as SplitNode).children.last as TabsNode;
      expect(mainGroup.panels, contains(Panels.files));
    });

    test('setWeights keeps every share at least the minimum and the total at 1', () {
      final l = base.setWeights(const [], [0.99, 0.01]);
      expectValid(l);
      final w = (l.root as SplitNode).weights;
      expect(w[1], closeTo(DockLayout.minWeight, 1e-9));
      expect(w[0], closeTo(1 - DockLayout.minWeight, 1e-9));
      expect(identical(base.setWeights(const [5], [0.5, 0.5]), base), isTrue);
      expect(identical(base.setWeights(const [], [1.0]), base), isTrue);
    });

    test('docking many panels onto one edge keeps every share at the minimum or more', () {
      var l = DockLayout.preset(FormFactor.desktop);
      for (final p in [Panels.builder, Panels.files]) {
        l = l.dock(p, target: Panels.arrangement, edge: DockEdge.right);
      }
      expectValid(l);
      final row = l.root as SplitNode;
      expect(row.children, hasLength(3));
      for (final w in row.weights) {
        expect(w, greaterThanOrEqualTo(DockLayout.minWeight - 1e-9));
      }
    });

    test('a hand-built tree loses repeated and unknown ids', () {
      final l = DockLayout(SplitNode(DockAxis.row, [
        TabsNode([Panels.arrangement, 'gone', Panels.files], 2),
        TabsNode([Panels.files]),
      ]));
      expectValid(l);
      expect(l.root, isA<TabsNode>());
      expect((l.root as TabsNode).panels, [Panels.arrangement, Panels.files]);
      expect((l.root as TabsNode).activePanel, Panels.files);
    });

    test('long sequences of random edits always leave a valid layout', () {
      var l = DockLayout.preset(FormFactor.desktop);
      var seed = 7;
      int next(int n) => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n;
      for (var i = 0; i < 2000; i++) {
        final a = Panels.all[next(Panels.all.length)], b = Panels.all[next(Panels.all.length)];
        switch (next(4)) {
          case 0:
            l = l.dock(a, target: b, edge: DockEdge.values[next(DockEdge.values.length)]);
          case 1:
            l = l.remove(a);
          case 2:
            l = l.reveal(a);
          default:
            l = l.activate(a);
        }
        expectValid(l);
      }
    });
  });

  group('JSON', () {
    test('a layout survives a round trip, through text as well', () {
      final l = DockLayout.preset(FormFactor.desktop)
          .dock(Panels.builder, target: Panels.arrangement, edge: DockEdge.bottom)
          .activate(Panels.files);
      final back = DockLayout.fromJson(jsonDecode(jsonEncode(l.toJson())))!;
      expect(back.toJson(), l.toJson());
      expectValid(back);
    });

    test('unknown and repeated ids are dropped; empty groups and splits vanish', () {
      final l = DockLayout.fromJson({
        'split': 'row',
        'weights': [1, 1, 1],
        'children': [
          {'tabs': ['arrangement', 'gone', 'builder'], 'active': 9},
          {'tabs': ['builder', 'nope']},
          {'tabs': ['files']},
        ],
      })!;
      expectValid(l);
      expect(l.panels, [Panels.arrangement, Panels.builder, Panels.files]);
      expect((l.root as SplitNode).children, hasLength(2));
    });

    test('the active tab is the same panel after dropped ids, and ids are the Panels constants', () {
      final l = DockLayout.fromJson(jsonDecode('{"tabs": ["old", "builder", "files"], "active": 1}'))!;
      expect((l.root as TabsNode).activePanel, Panels.builder);
      for (final p in l.panels) {
        expect(identical(p, Panels.all.firstWhere((q) => q == p)), isTrue, reason: p);
      }
      final built = DockLayout(TabsNode([String.fromCharCodes('files'.codeUnits)]));
      expect(identical(built.panels.single, Panels.files), isTrue);
    });

    test('damage gives null so the caller uses a preset', () {
      for (final bad in [null, 3, 'x', <String, Object?>{}, {'tabs': []}, {'split': 'diagonal', 'children': []},
        {'tabs': ['gone']}]) {
        expect(DockLayout.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('bad weights fall back to equal shares, and very deep nesting is refused', () {
      final l = DockLayout.fromJson({
        'split': 'column',
        'weights': ['a', -2],
        'children': [{'tabs': ['arrangement']}, {'tabs': ['files']}],
      })!;
      expect((l.root as SplitNode).weights, [0.5, 0.5]);
      Object? deep = {'tabs': ['arrangement']};
      for (var i = 0; i < 40; i++) {
        deep = {'split': i.isEven ? 'row' : 'column', 'children': [deep]};
      }
      expect(DockLayout.fromJson(deep), isNull);
    });
  });
}
