// Shared building blocks for the redesigned screens: the context-aware toolbar row, tool buttons and the info button.
import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';
import 'glass.dart';

/// One toolbar row (owner, 2026-11-04): fixed [leading] (tools, snap), a [middle] part that changes with what you
/// are doing, and fixed [trailing] (the ⋮ menu). When [contextKey] changes, the middle slides and fades to the new
/// part in [Motion.standard]; Reduced motion only fades and Off swaps at once. The middle scrolls sideways if needed.
class ContextToolbar extends StatelessWidget {
  const ContextToolbar({
    super.key,
    required this.leading,
    required this.contextKey,
    required this.middle,
    this.trailing = const [],
  });

  final List<Widget> leading, middle, trailing;

  /// Identifies the middle part's state (e.g. 'none', 'notes', 'curve'); a new value animates the change.
  final Object contextKey;

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    return Material(
      color: Neon.panel,
      child: SizedBox(
        height: Targets.of(context),
        child: Row(children: [
          ...leading,
          const _Divider(),
          Expanded(
            child: AnimatedSwitcher(
              duration: Motion.fade(Motion.standard, level),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) {
                final faded = FadeTransition(opacity: anim, child: child);
                if (level != MotionLevel.full) return faded;
                return SlideTransition(
                  position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(anim),
                  child: faded,
                );
              },
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: KeyedSubtree(
                key: ValueKey(contextKey),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(mainAxisSize: MainAxisSize.min, children: middle),
                ),
              ),
            ),
          ),
          if (trailing.isNotEmpty) const _Divider(),
          ...trailing,
        ]),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: Targets.of(context) * 0.5, color: Neon.line, margin: const EdgeInsets.symmetric(horizontal: Space.xs));
}

/// A toolbar button: an icon with a tooltip (its accessible name), a touch target from [Targets], and a [selected]
/// state for tools, shown as a tinted background in the accent colour.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final size = Targets.of(context);
    final c = color ?? Roles.accent;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: SizedBox(
          width: size,
          height: size,
          child: AnimatedContainer(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            margin: const EdgeInsets.all(Space.xs),
            decoration: BoxDecoration(
              color: selected ? c.withValues(alpha: 0.18) : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.s),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.s),
              onTap: onPressed,
              child: Icon(icon, size: 20, color: onPressed == null ? Neon.line : (selected ? c : Neon.text)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small ⓘ button that shows help on demand, so screens don't print explanations as body text (UI plan finding 6).
class InfoButton extends StatelessWidget {
  const InfoButton({super.key, required this.title, required this.text});

  final String title, text;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'About $title',
        icon: const Icon(Icons.info_outline, size: 18, color: Neon.dim),
        onPressed: () => showGlassSheet<void>(
          context: context,
          backgroundColor: Neon.panelHi,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.l, Space.l),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: TypeScale.title, fontWeight: FontWeight.w700)),
                const SizedBox(height: Space.s),
                Text(text, style: const TextStyle(fontSize: TypeScale.body, color: Neon.dim, height: 1.4)),
              ]),
            ),
          ),
        ),
      );
}
