// Settings' row building blocks: a row that a search can scroll to and flash, and its switch, choice and slider forms.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import '../widgets.dart';
import 'settings_registry.dart';

/// The setting a search jumped to: its row scrolls into view and flashes once.
class SettingsHighlight extends InheritedWidget {
  const SettingsHighlight({super.key, required this.id, required super.child});
  final String? id;

  static String? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SettingsHighlight>()?.id;

  @override
  bool updateShouldNotify(SettingsHighlight old) => old.id != id;
}

/// One setting's row, keyed by its registry [id] (`setting-<id>`). When it is the highlighted one it scrolls into
/// view and its background flashes the section's colour for a moment.
class SettingRow extends StatefulWidget {
  SettingRow({required this.id, required this.child}) : super(key: ValueKey('setting-$id'));
  final String id;
  final Widget child;

  @override
  State<SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<SettingRow> with SingleTickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  String? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = SettingsHighlight.of(context);
    if (id == widget.id && _shown != id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final level = Motion.of(context);
        Scrollable.ensureVisible(context, alignment: 0.25, duration: Motion.move(Motion.panel, level));
        _flash.forward(from: 0);
      });
    }
    _shown = id;
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = settingEntry(widget.id)?.section.color ?? Neon.green;
    return AnimatedBuilder(
      animation: _flash,
      child: widget.child,
      builder: (context, child) {
        // Up quickly, then fading: a pulse, not a blink.
        final t = _flash.value;
        final a = _flash.isAnimating ? (t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85) * 0.28 : 0.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: a),
            borderRadius: BorderRadius.circular(10),
            border: a > 0 ? Border.all(color: color.withValues(alpha: a * 2.4)) : null,
          ),
          child: child,
        );
      },
    );
  }
}

String _title(String id) => settingEntry(id)?.title ?? id;
String _description(String id) => settingEntry(id)?.description ?? '';

Text _sub(String text) => Text(text, style: const TextStyle(color: Neon.dim, fontSize: 12));

/// A setting with a switch.
Widget settingSwitch(String id, bool value, ValueChanged<bool>? onChanged, {String? subtitle, IconData? icon}) =>
    SettingRow(
      id: id,
      child: SwitchListTile(
        key: ValueKey('switch-$id'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        secondary: icon == null ? null : Icon(icon, color: Neon.blue, size: 20),
        title: Text(_title(id)),
        subtitle: _sub(subtitle ?? _description(id)),
        value: value,
        onChanged: onChanged == null
            ? null
            : (v) {
                Haptics.tap();
                onChanged(v);
              },
      ),
    );

/// A setting with a few choices side by side (segmented), under its title.
Widget settingChoice<T>(String id, T value, List<(T, String)> choices, ValueChanged<T>? onChanged,
        {String? subtitle, IconData? icon}) =>
    SettingRow(
      id: id,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: icon == null ? null : Icon(icon, color: Neon.blue, size: 20),
        title: Text(_title(id)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sub(subtitle ?? _description(id)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<T>(
              key: ValueKey('choice-$id'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              segments: [for (final (v, label) in choices) ButtonSegment(value: v, label: Text(label))],
              selected: {value},
              onSelectionChanged: onChanged == null
                  ? null
                  : (v) {
                      Haptics.tap();
                      onChanged(v.first);
                    },
            ),
          ),
        ]),
      ),
    );

/// A setting with a drop-down list of choices on the right.
Widget settingDropdown<T>(String id, T? value, List<(T, String)> choices, ValueChanged<T>? onChanged,
        {String? subtitle, IconData? icon}) =>
    SettingRow(
      id: id,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: icon == null ? null : Icon(icon, color: Neon.blue, size: 20),
        title: Text(_title(id)),
        subtitle: _sub(subtitle ?? _description(id)),
        trailing: DropdownButton<T>(
          key: ValueKey('dropdown-$id'),
          value: choices.any((c) => c.$1 == value) ? value : null,
          underline: const SizedBox.shrink(),
          isDense: true,
          items: [for (final (v, label) in choices) DropdownMenuItem(value: v, child: Text(label))],
          onChanged: onChanged == null
              ? null
              : (v) {
                  if (v == null) return;
                  Haptics.tap();
                  onChanged(v);
                },
        ),
      ),
    );

/// A setting with a slider: [settings.adjust] while it moves (shown, not saved), saved when let go; a double-tap
/// puts back [reset].
Widget settingSlider(String id, Settings settings,
        {required double value,
        required double min,
        required double max,
        int? divisions,
        required String Function(double) show,
        required void Function(Settings, double) set,
        double? reset,
        bool enabled = true,
        String? subtitle,
        IconData? icon}) =>
    SettingRow(
      id: id,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: icon == null ? null : Icon(icon, color: Neon.blue, size: 20),
        title: Row(children: [
          Expanded(child: Text(_title(id))),
          Text(show(value), style: Neon.code(size: 12, color: Neon.yellow)),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sub(subtitle ?? _description(id)),
          ResetOnDoubleTap(
            onReset: () => reset == null ? null : settings.update((s) => set(s, reset)),
            child: Slider(
              key: ValueKey('slider-$id'),
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: enabled ? (v) => settings.adjust((s) => set(s, v)) : null,
              onChangeEnd: enabled
                  ? (v) {
                      settings.save();
                      Haptics.tick();
                    }
                  : null,
            ),
          ),
        ]),
      ),
    );

/// A setting that opens something (a sheet, a page) or shows a value, with a chevron when it opens something.
Widget settingAction(String id, {String? subtitle, IconData? icon, Color? iconColor, VoidCallback? onTap, Widget? trailing}) =>
    SettingRow(
      id: id,
      child: ListTile(
        key: ValueKey('action-$id'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: icon == null ? null : Icon(icon, color: iconColor ?? Neon.blue, size: 20),
        title: Text(_title(id)),
        subtitle: _sub(subtitle ?? _description(id)),
        trailing: trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
        onTap: onTap == null
            ? null
            : () {
                Haptics.tap();
                onTap();
              },
      ),
    );

/// A heading inside a section page.
Widget settingHeading(String text) => Heading(text);
