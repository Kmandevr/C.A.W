// Settings › Projects and files: autosave, restore points kept, what a new project starts with, storage and caches.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../model/settings.dart';
import '../../model/storage.dart';
import '../../model/templates.dart';
import '../widgets.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class ProjectsSettings extends StatefulWidget {
  const ProjectsSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  State<ProjectsSettings> createState() => _ProjectsSettingsState();
}

class _ProjectsSettingsState extends State<ProjectsSettings> {
  StorageUse? _use;
  Directory? _temp;
  bool _clearing = false;

  Settings get s => widget.deps.settings;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final support = s.dir;
    if (support == null) return; // settings in memory only (tests): nothing on disk to measure
    try {
      _temp ??= await getTemporaryDirectory();
    } catch (_) {
      _temp = null;
    }
    final use = await StorageUse.measure(support, _temp);
    if (mounted) setState(() => _use = use);
  }

  Future<void> _clear() async {
    final temp = _temp;
    if (temp == null) return;
    setState(() => _clearing = true);
    final freed = await StorageUse.clearCaches(temp);
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cleared ${StorageUse.format(freed)}')));
    await _measure();
  }

  @override
  Widget build(BuildContext context) {
    final use = _use;
    String delay(int ms) => ms < 1000 ? '$ms ms' : '${ms ~/ 1000} s';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      settingDropdown<int>('projects.autosave', s.autosaveMs,
          [for (final d in Settings.autosaveDelays) (d, d == 500 ? 'As you edit (0.5 s)' : 'After ${delay(d)}')],
          (v) => s.update((x) => x.autosaveMs = v),
          icon: Icons.save_outlined,
          subtitle: 'Saved this long after the last edit, and always on leaving the app or switching project'),
      settingSlider('projects.restorePoints', s,
          value: s.restorePointsKept.toDouble(), min: 1, max: 100, divisions: 99, icon: Icons.history,
          show: (v) => '${v.round()}', set: (x, v) => x.restorePointsKept = v.round(), reset: 20,
          subtitle: 'The newest this many per project; older ones go when a new one is made'),
      settingDropdown<String>('projects.newStart', s.newProjectTemplate, [
            (blankTemplateId, 'Blank'),
            ...switch (widget.deps.state) {
              final app? => [for (final t in app.projectTemplates) (t.id, t.name)],
              null => [(firstLoopTemplateId, 'Mid tempo')],
            },
            // A saved template that was deleted elsewhere still shows until another is picked.
            if (s.newProjectTemplate != blankTemplateId && widget.deps.state?.templateById(s.newProjectTemplate) == null &&
                s.newProjectTemplate != firstLoopTemplateId)
              (s.newProjectTemplate, templateLabel(s.newProjectTemplate)),
          ], (v) => s.update((x) => x.newProjectTemplate = v),
          icon: Icons.add_box_outlined,
          subtitle: 'What the project menu\'s New project opens; save your own with Save as template'),
      settingAction('projects.newTempo',
          icon: Icons.speed,
          subtitle: '${s.newProjectBpm.toStringAsFixed(s.newProjectBpm % 1 == 0 ? 0 : 1)} BPM (a blank project); tap to type',
          onTap: () => typeValue(context,
              title: 'New project tempo (BPM)',
              initial: s.newProjectBpm.toStringAsFixed(s.newProjectBpm % 1 == 0 ? 0 : 1),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              parse: (t) {
                final v = double.tryParse(t.trim());
                return v != null && v >= 20 && v <= 400 ? v : null;
              },
              apply: (v) => s.update((x) => x.newProjectBpm = v))),
      settingDropdown<int>('projects.newMeter', s.newProjectBeatsPerBar,
          [for (var b = 1; b <= 16; b++) (b, '$b/4')], (v) => s.update((x) => x.newProjectBeatsPerBar = v),
          icon: Icons.straighten),
      settingAction('projects.storage',
          icon: Icons.storage,
          subtitle: use == null
              ? (s.dir == null ? 'Not on disk here' : 'Measuring…')
              : '${StorageUse.format(use.total)}: projects ${StorageUse.format(use.projects)}, restore points '
                  '${StorageUse.format(use.restorePoints)}, themes ${StorageUse.format(use.themes)}, settings and builds '
                  '${StorageUse.format(use.other)}, caches ${StorageUse.format(use.caches)}'),
      settingAction('projects.clearCaches',
          icon: Icons.cleaning_services_outlined,
          subtitle: 'Deletes temporary renders waiting to be saved; projects, settings and restore points stay. '
              'Not while an export runs',
          trailing: FilledButton.tonal(
            key: const ValueKey('clear-caches'),
            onPressed: _temp == null || _clearing ? null : _clear,
            child: Text(_clearing ? 'Clearing…' : 'Clear'),
          )),
    ]);
  }
}
