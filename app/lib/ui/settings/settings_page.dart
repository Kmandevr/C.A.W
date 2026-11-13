// Settings: a searchable list of sections (icon, title, a line of current values) that opens each section's page;
// side by side on a wide window. A search result opens its page scrolled to the setting, which flashes.
import 'package:flutter/material.dart';

import '../../engine/execution.dart';
import '../../model/app_state.dart';
import '../../model/settings.dart';
import '../../actions/actions.dart';
import '../feedback.dart';
import '../keyboard/key_area.dart';
import '../haptics.dart';
import '../panel_motion.dart';
import '../theme.dart';
import '../widgets.dart';
import 'about_settings.dart';
import 'audio_settings.dart';
import 'code_settings.dart';
import 'editing_settings.dart';
import 'export_settings.dart';
import 'feel_settings.dart';
import 'keys_settings.dart';
import 'look_settings.dart';
import 'midi_settings.dart';
import 'performance_settings.dart';
import 'projects_settings.dart';
import 'recording_settings.dart';
import 'settings_deps.dart';
import 'settings_registry.dart';
import 'settings_widgets.dart';

/// From this width (logical pixels) the list and a section's page sit side by side.
const settingsTwoPaneWidth = 900.0;

class SettingsPage extends StatefulWidget {
  const SettingsPage(
      {super.key, required this.settings, this.state, this.engineProfile, this.executionPlan, this.onEditKeys, this.initial});
  final Settings settings;

  /// The app, for the audio device, the test tone and storage; null where Settings opens alone (tests, goldens).
  final AppState? state;
  final EngineHardwareProfile? engineProfile;
  final EngineExecutionPlan? executionPlan;

  /// Opens the key bindings editor; null hides its row (no key router above).
  final Future<void> Function(BuildContext context)? onEditKeys;

  /// The section shown first in the two-pane layout (Audio when null).
  final SettingsSection? initial;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _search = TextEditingController();
  late SettingsSection _open = widget.initial ?? SettingsSection.audio;
  String? _highlight;
  int _jump = 0; // a new jump to the same setting flashes it again

  SettingsDeps get _deps => SettingsDeps(
        settings: widget.settings,
        state: widget.state,
        engineProfile: widget.engineProfile,
        executionPlan: widget.executionPlan,
        onEditKeys: widget.onEditKeys,
      );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openSection(BuildContext context, SettingsSection section, {String? highlight, required bool wide}) {
    Haptics.tap();
    if (wide) {
      setState(() {
        _open = section;
        _highlight = highlight;
        _jump++;
      });
      return;
    }
    Navigator.of(context).push(panelRoute<void>(
      context,
      (_) => SettingsSectionPage(section: section, deps: _deps, highlight: highlight),
    ));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= settingsTwoPaneWidth;
          final list = _list(context, wide);
          if (!wide) {
            return Scaffold(
              appBar: AppBar(title: const Text('Settings'), backgroundColor: Neon.panel),
              body: SafeArea(top: false, child: SettingsKeyArea(label: 'Settings categories', autofocus: true, child: list)),
            );
          }
          return Scaffold(
            appBar: AppBar(title: Text('Settings · ${_open.title}'), backgroundColor: Neon.panel),
            body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 340, child: SettingsKeyArea(label: 'Settings categories', autofocus: true, child: list)),
              const VerticalDivider(width: 1, color: Neon.line),
              Expanded(
                child: SettingsSectionBody(
                  key: ValueKey('pane-${_open.name}-$_jump'),
                  section: _open,
                  deps: _deps,
                  highlight: _highlight,
                ),
              ),
            ]),
          );
        }),
      );

  Widget _list(BuildContext context, bool wide) {
    final query = _search.text.trim();
    final results = query.isEmpty ? null : searchSettings(query);
    return ListView(padding: const EdgeInsets.fromLTRB(10, 8, 10, 24), children: [
      TextField(
        key: const ValueKey('settings-search'),
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: 'Search settings',
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(_search.clear),
                ),
        ),
      ),
      const SizedBox(height: 8),
      if (results == null)
        for (final section in SettingsSection.values)
          _SectionTile(
            section: section,
            summary: section.summary(widget.settings),
            selected: wide && section == _open,
            onTap: () => _openSection(context, section, wide: wide),
          )
      else if (results.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Nothing matches "$query"', style: const TextStyle(color: Neon.dim)),
        )
      else
        for (final MapEntry(key: section, value: entries) in results.entries) ...[
          Heading(section.title),
          for (final e in entries)
            ListTile(
              key: ValueKey('result-${e.id}'),
              dense: true,
              leading: Icon(section.icon, color: section.color, size: 18),
              title: Text(e.title),
              subtitle: Text(e.description, style: const TextStyle(color: Neon.dim, fontSize: 12)),
              onTap: () => _openSection(context, section, highlight: e.id, wide: wide),
            ),
        ],
    ]);
  }
}

/// One section in the list: its icon in a small glowing tile, its title and one line of current values.
class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section, required this.summary, required this.selected, required this.onTap});
  final SettingsSection section;
  final String summary;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = section.color;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Pressable(
        glow: c,
        child: Material(
          color: selected ? c.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: ValueKey('section-${section.name}'),
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.withValues(alpha: 0.5)),
                    boxShadow: Neon.glow(c, strength: 0.25),
                  ),
                  child: Icon(section.icon, size: 18, color: c),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(section.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    Text(summary,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Neon.dim, fontSize: 12)),
                  ]),
                ),
                Icon(Icons.chevron_right, size: 18, color: selected ? c : Neon.dim),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section's page on a phone: its own app bar over the body.
class SettingsSectionPage extends StatelessWidget {
  const SettingsSectionPage({super.key, required this.section, required this.deps, this.highlight});
  final SettingsSection section;
  final SettingsDeps deps;
  final String? highlight;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(section.title), backgroundColor: Neon.panel),
        body: SafeArea(top: false, child: SettingsSectionBody(section: section, deps: deps, highlight: highlight, autofocus: true)),
      );
}

/// A section's settings, scrolled to [highlight] (which flashes) when one is given.
class SettingsSectionBody extends StatelessWidget {
  const SettingsSectionBody({super.key, required this.section, required this.deps, this.highlight, this.autofocus = false});
  final SettingsSection section;
  final SettingsDeps deps;
  final String? highlight;

  /// Takes the keyboard focus when shown (a section's own page).
  final bool autofocus;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: deps.settings,
        builder: (context, _) => SettingsKeyArea(label: 'Settings: ${section.title}', autofocus: autofocus, child: SettingsHighlight(
          id: highlight,
          // A column, not a lazy list, so the row a search jumps to exists to scroll to.
          child: SingleChildScrollView(
            key: ValueKey('section-page-${section.name}'),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
            child: switch (section) {
              SettingsSection.audio => AudioSettings(deps: deps),
              SettingsSection.midi => MidiSettings(deps: deps),
              SettingsSection.recording => RecordingSettings(deps: deps),
              SettingsSection.editing => EditingSettings(deps: deps),
              SettingsSection.code => CodeSettings(deps: deps),
              SettingsSection.look => LookSettings(deps: deps),
              SettingsSection.feel => FeelSettings(deps: deps),
              SettingsSection.performance => PerformanceSettings(deps: deps),
              SettingsSection.projects => ProjectsSettings(deps: deps),
              SettingsSection.export => ExportSettings(deps: deps),
              SettingsSection.keys => KeysSettings(deps: deps),
              SettingsSection.about => AboutSettings(deps: deps),
            },
          ),
        )),
      );
}

/// A Settings list's keys (owner, 2026-11-11): up and down (or W and S) move between rows, left and right turn the
/// focused switch off or on (a slider takes its own arrows), Space toggles or presses, Enter presses.
class SettingsKeyArea extends StatelessWidget {
  const SettingsKeyArea({super.key, required this.label, required this.child, this.autofocus = false});
  final String label;
  final Widget child;
  final bool autofocus;

  static bool _key(String id, int count, String? arg) {
    if (id != 'settings.left' && id != 'settings.right') return false;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    final on = findWidgetUnder<Switch>(ctx)?.value;
    if (on == null) return false;
    // Already where the arrow points: nothing to do, but the key is still the switch's.
    if (on != (id == 'settings.right')) activateFocused();
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      KeyArea(area: Area.settings, label: label, autofocus: autofocus, onAction: _key, child: child);
}
