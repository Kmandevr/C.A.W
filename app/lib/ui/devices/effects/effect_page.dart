// What every built-in effect page shares: the scrolling page, the single-section registry entry, and the hero-with-meters row.
import 'package:flutter/material.dart';

import '../device_registry.dart';
import '../device_scope.dart';
import '../kit/controls.dart';
import '../kit/device_style.dart';
import '../kit/hero.dart';

/// A device page: the hero first, then its controls, scrolling on a phone; inline in the FX stack, a column the
/// stack scrolls. [id] keys it for tests.
Widget effectPage(String id, List<Widget> children) => Builder(key: ValueKey('fx-page-$id'), builder: (context) =>
    DeviceScope.isInline(context)
        ? Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 4), child: InlineSplit(children: children))
        : ListView(padding: const EdgeInsets.fromLTRB(10, 10, 10, 28), children: children));

/// An inline device's body: stacked on a narrow panel; on a wide one (landscape, desktop) the hero ([children]'s
/// first child not wrapped in padding) beside the rest, so a short panel shows a whole device. [lead] (a row of switches) goes above the hero, or
/// atop the controls when split.
class InlineSplit extends StatelessWidget {
  const InlineSplit({super.key, required this.children, this.minWidth = 480, this.lead});
  final List<Widget> children;
  final double minWidth;
  final Widget? lead;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    Widget column(List<Widget> c) =>
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: c);
    // The hero is the first child not wrapped in padding (mode tiles above a hero come padded): what comes before
    // it joins [lead].
    final h = children.indexWhere((w) => w is! Padding);
    if (box.maxWidth < minWidth || h < 0 || h == children.length - 1) return column([?lead, ...children]);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(flex: 11, child: children[h]),
      const SizedBox(width: 10),
      Expanded(flex: 9, child: column([?lead, ...children.take(h), ...children.skip(h + 1)])),
    ]);
  });
}

/// An editor with one section (most effects: no tabs).
DeviceEditorEntry singlePage(String id, String label, IconData icon, DeviceFamily family, Widget Function() page) =>
    DeviceEditorEntry((_) => [DeviceSection(id, label, icon, (_) => page())], family: family);

/// The hero beside the device's meters (IN, GR, OUT) when the page is wide enough, else the hero alone.
class HeroWithMeters extends StatelessWidget {
  const HeroWithMeters({super.key, required this.hero, this.height = 190, this.gr = true});
  final Widget hero;
  final double height;
  final bool gr;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    if (box.maxWidth < 330) return hero;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: hero),
      const SizedBox(width: 6),
      Padding(padding: const EdgeInsets.only(bottom: 10), child: MeterStack(height: heroHeight(context, height) - 10, gr: gr)),
    ]);
  });
}

/// A titled group of controls on a page (smaller than a card: a label and a hairline).
class ControlGroup extends StatelessWidget {
  const ControlGroup({super.key, required this.title, required this.child, this.color, this.trailing});
  final String title;
  final Widget child;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 26, child: Row(children: [
          Text(title, style: TextStyle(fontSize: 10, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: c)),
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: c.withValues(alpha: 0.18))),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ])),
        child,
      ]));
  }
}
