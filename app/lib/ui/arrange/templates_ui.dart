// Templates on screen: the project menu's New from template and Save as template, the track menu's Save as track
// template, and the add-track menu (the toolbar's + long-pressed) that inserts track templates.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/project.dart';
import '../../model/templates.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';
import '../widgets.dart';
import 'long_press_menu.dart';

/// Asks for a name (and with [clipsChoice], whether to include the clips); null when cancelled.
Future<(String, bool)?> _askName(BuildContext context, {required String title, required String initial,
    bool clipsChoice = false}) {
  final c = TextEditingController(text: initial);
  var clips = false;
  return showDialog<(String, bool)>(context: context, builder: (context) => StatefulBuilder(
    builder: (context, setState) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(key: const ValueKey('template-name'), controller: c, autofocus: true, maxLength: 64,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, (v, clips))),
        if (clipsChoice) CheckboxListTile(key: const ValueKey('template-clips'), contentPadding: EdgeInsets.zero,
          value: clips, onChanged: (v) => setState(() => clips = v ?? false),
          title: const Text('Include clips'), subtitle: const Text('Their patterns go with them')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(key: const ValueKey('template-save'), onPressed: () => Navigator.pop(context, (c.text, clips)),
          child: const Text('Save')),
      ],
    ),
  ));
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

/// The project menu's Save as template: the whole project (tracks, effects, sends, clips, master) under a name.
Future<void> saveProjectTemplate(BuildContext context, AppState s) async {
  final r = await _askName(context, title: 'Save project as template', initial: s.project.name);
  if (r == null || r.$1.trim().isEmpty || !context.mounted) return;
  final t = s.saveProjectTemplate(r.$1);
  Haptics.drop();
  _say(context, 'Saved template ${t.name}: project menu › New from template');
}

/// The track menu's Save as track template: [layer] (a folder with what is inside it), optionally with its clips.
Future<void> saveTrackTemplate(BuildContext context, AppState s, LayerDoc layer) async {
  final r = await _askName(context, title: 'Save as track template', initial: layer.name, clipsChoice: true);
  if (r == null || r.$1.trim().isEmpty || !context.mounted) return;
  final t = s.saveTrackTemplate(layer, r.$1, clips: r.$2);
  Haptics.drop();
  _say(context, 'Saved track template ${t.name}: long-press + to add it');
}

/// The project menu's New from template: every project template; tap one to start a project from it, ☆ to make it
/// what New project opens, and a saved one can be deleted.
Future<void> showProjectTemplates(BuildContext context, AppState s) => showGlassSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(child: ConstrainedBox(
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
    child: ListenableBuilder(listenable: Listenable.merge([s.templateStore, s.settings]), builder: (context, _) {
      final current = s.settings.newProjectTemplate;
      Widget star(String id) => IconButton(
        key: ValueKey('template-default-$id'),
        tooltip: current == id ? 'New project opens this' : 'Make this what New project opens',
        color: current == id ? Neon.yellow : Neon.dim,
        icon: Icon(current == id ? Icons.star : Icons.star_border),
        onPressed: () {
          Haptics.tap();
          s.settings.update((x) => x.newProjectTemplate = id);
        });
      return ListView(shrinkWrap: true, children: [
        const Heading('New from template'),
        ListTile(
          key: const ValueKey('template-blank'),
          leading: const Icon(Icons.crop_square, color: Neon.dim),
          title: const Text('Blank'),
          subtitle: Text('${s.settings.newProjectBpm.toStringAsFixed(0)} BPM, ${s.settings.newProjectBeatsPerBar}/4',
            style: const TextStyle(color: Neon.dim)),
          trailing: star(blankTemplateId),
          onTap: () {
            Navigator.pop(context);
            s.newProjectFromTemplate(TemplateDoc(id: blankTemplateId, name: 'Blank', kind: TemplateKind.project, json: const {}));
          }),
        for (final t in s.projectTemplates)
          ListTile(
            key: ValueKey('template-${t.id}'),
            leading: Icon(t.bundled ? Icons.auto_awesome_mosaic : Icons.bookmark_outline,
              color: t.bundled ? Neon.green : Neon.blue),
            title: Text(t.name),
            subtitle: t.summary.isEmpty ? null : Text(t.summary, style: const TextStyle(color: Neon.dim)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              star(t.id),
              if (!t.bundled) IconButton(key: ValueKey('template-delete-${t.id}'), tooltip: 'Delete ${t.name}',
                color: Neon.pink, icon: const Icon(Icons.delete_outline), onPressed: () {
                  if (s.settings.newProjectTemplate == t.id) s.settings.update((x) => x.newProjectTemplate = blankTemplateId);
                  s.templateStore.remove(t.id);
                }),
            ]),
            onTap: () {
              Navigator.pop(context);
              s.newProjectFromTemplate(t);
            }),
        ListTile(
          key: const ValueKey('template-save-current'),
          leading: const Icon(Icons.save_outlined, color: Neon.yellow),
          title: const Text('Save this project as a template…'),
          onTap: () async {
            Navigator.pop(context);
            await saveProjectTemplate(context, s);
          }),
      ]);
    }),
  )),
);

/// The add-track menu (the toolbar's + long-pressed, or right-clicked): an empty track, a folder, and every track
/// template; a template's tracks go at the end, selected.
Future<void> showAddTrackMenu(BuildContext context, AppState s, Offset at) async {
  final templates = s.trackTemplates;
  final v = await showLongPressMenu<String>(context, at: at, title: 'Add track', style: s.settings.longPressMenu, actions: [
    const MenuAction('track', 'Empty track', Icons.add),
    const MenuAction('folder', 'Folder', Icons.create_new_folder_outlined),
    for (final t in templates)
      MenuAction('tpl:${t.id}', t.bundled ? t.name : '${t.name} (saved)', t.bundled ? Icons.auto_awesome_mosaic : Icons.bookmark_outline),
  ]);
  if (v == null) return;
  if (v == 'track') s.addLayer();
  if (v == 'folder') s.addFolder();
  if (v.startsWith('tpl:')) {
    final t = templates.where((t) => 'tpl:${t.id}' == v).firstOrNull;
    if (t != null && s.insertTrackTemplate(t) != null) Haptics.drop();
  }
}
