// The device header's preset button (name, "*" when changed, quick save, Ctrl+S) and the preset browser: My presets
// and Factory with search, favourites and tags; rename, duplicate, export and delete on long-press; track presets.
import 'package:flutter/material.dart';
import '../../panel_motion.dart';
import 'package:flutter/services.dart';

import 'param_watch.dart';
import '../../../model/app_state.dart';
import '../../../model/arrange_fx.dart';
import '../../../model/device_target.dart';
import '../../../model/project.dart';
import '../../../model/user_presets.dart';
import '../../feedback.dart';
import '../../files/asset_views.dart' show MenuEntry, showCompactMenu;
import '../../theme.dart';
import 'device_style.dart' show spectrumColors;
import 'feel.dart';
import 'preset_actions.dart';
import 'presets.dart';
import '../../../model/mixer_fx.dart' show isMasterLayer;

/// The header's preset button: the current preset's name ("*" once a value changed); a tap opens the browser. While
/// the current preset is the user's and changed, a save icon beside it saves over it. With [shortcuts] (the full
/// editor) Ctrl+S does the same on a keyboard, or asks for a name when the preset isn't the user's.
class DevicePresetChip extends StatefulWidget {
  const DevicePresetChip({super.key, required this.target, required this.color, this.maxWidth = 150, this.chipKey,
    this.shortcuts = false});
  final DeviceTarget target;
  final Color color;
  final double maxWidth;
  final Key? chipKey;
  final bool shortcuts;

  @override
  State<DevicePresetChip> createState() => _DevicePresetChipState();
}

class _DevicePresetChipState extends State<DevicePresetChip> {
  DeviceTarget get t => widget.target;

  @override
  void initState() {
    super.initState();
    if (widget.shortcuts) HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    if (widget.shortcuts) HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyS || !mounted) return false;
    final k = HardwareKeyboard.instance;
    if (!(k.isControlPressed || k.isMetaPressed) || k.isAltPressed) return false;
    // Only while this editor is on top (no dialog or sheet over it).
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    if (!k.isShiftPressed && quickSavePreset(context, t)) return true;
    savePresetAs(context, t);
    return true;
  }

  @override
  // Its own watch (param_watch.dart): it compares every value with the presets, so a knob step rebuilds the chip,
  // not the editor around it.
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: t.state.userPresets,
    builder: (context, _) => Flexible(child: ParamWatch(target: t, builder: (context) {
      final name = DevicePresets.label(t);
      final quick = DevicePresets.currentUser(t) != null && DevicePresets.modified(t);
      final color = widget.color;
      return ConstrainedBox(constraints: BoxConstraints(maxWidth: widget.maxWidth), child: Row(
        mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Pressable(glow: color, radius: 15, child: InkWell(
            key: widget.chipKey ?? const ValueKey('device-presets'),
            borderRadius: BorderRadius.circular(15),
            onTap: () {
              DeviceFeel.tap();
              showPresetBrowser(context, t, color);
            },
            child: Container(
              height: 30,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), color: color.withValues(alpha: 0.1),
                border: Border.all(color: color.withValues(alpha: 0.45))),
              // While the save icon shows, the chip's own icons give their room to the name.
              padding: EdgeInsets.symmetric(horizontal: quick ? 8 : 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (!quick) ...[Icon(Icons.bookmarks_outlined, size: 14, color: color), const SizedBox(width: 5)],
                Flexible(child: Text(name, key: const ValueKey('device-preset-name'), maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
                if (!quick) const Icon(Icons.arrow_drop_down, size: 16, color: Neon.dim),
              ]),
            ),
          ))),
          if (quick) Pressable(glow: color, circle: true, child: Tooltip(
            message: 'Save over "${DevicePresets.currentUser(t)!.name}"${widget.shortcuts ? ' (Ctrl+S)' : ''}',
            child: InkResponse(
              key: const ValueKey('device-preset-quicksave'),
              radius: 18,
              onTap: () => quickSavePreset(context, t),
              child: SizedBox(width: 30, height: 34, child: Icon(Icons.save_outlined, size: 17, color: color))))),
        ]));
    })),
  );
}

/// The preset browser: a tap loads a preset (one undo step).
Future<void> showPresetBrowser(BuildContext context, DeviceTarget target, Color color) {
  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: sheetAnimation(context), // in and out at the theme's pace
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Neon.panel,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => _SheetToasts(height: 0.7, child: PresetBrowser(target: target, color: color)),
  );
}

/// Toasts raised inside a sheet show at its bottom, above it (the page's own would be under the sheet).
class _SheetToasts extends StatelessWidget {
  const _SheetToasts({required this.height, required this.child});

  /// The sheet's height, as a part of the screen's.
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(height: MediaQuery.sizeOf(context).height * height,
    child: ScaffoldMessenger(child: Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: child,
    )));
}

/// What the browser's chips narrow the list to.
sealed class _Filter {
  const _Filter();
}

class _All extends _Filter {
  const _All();
}

class _Favourites extends _Filter {
  const _Favourites();
}

class _Mine extends _Filter {
  const _Mine();
}

class _Factory extends _Filter {
  const _Factory();
}

class _Tag extends _Filter {
  const _Tag(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is _Tag && other.tag == tag;
  @override
  int get hashCode => tag.hashCode;
}

class PresetBrowser extends StatefulWidget {
  const PresetBrowser({super.key, required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  State<PresetBrowser> createState() => _PresetBrowserState();
}

class _PresetBrowserState extends State<PresetBrowser> {
  _Filter _filter = const _All();
  String _query = '';

  DeviceTarget get t => widget.target;
  UserPresetStore get store => t.state.userPresets;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, t.tick]),
    builder: (context, _) => _build(context),
  );

  bool _passes(DevicePreset p, String componentId) {
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty && !p.name.toLowerCase().contains(q) && !p.category.toLowerCase().contains(q)) return false;
    return switch (_filter) {
      _All() => true,
      _Favourites() => store.isFavourite(p.favouriteKey(componentId)),
      _Mine() => p.isUser,
      _Factory() => !p.isUser,
      _Tag(:final tag) => p.category == tag,
    };
  }

  Widget _build(BuildContext context) {
    final id = t.componentId ?? '';
    final factory = DevicePresets.factory(t), mine = DevicePresets.user(t);
    final tags = <String>{
      for (final p in [...mine, ...factory]) if (p.category.isNotEmpty && p.category != 'Init' && p.category != 'Factory') p.category,
    }.toList();
    final shownMine = [for (final p in mine) if (_passes(p, id)) p];
    final shownFactory = [for (final p in factory) if (_passes(p, id)) p];
    final current = DevicePresets.current(t);
    final colors = spectrumColors();
    final color = widget.color;
    Widget chip(String label, _Filter f, {IconData? icon}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: ValueKey('preset-filter-$label'),
        avatar: icon == null ? null : Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        selected: _filter == f,
        selectedColor: color.withValues(alpha: 0.25),
        visualDensity: VisualDensity.compact,
        onSelected: (_) {
          DeviceFeel.tap();
          setState(() => _filter = _filter == f ? const _All() : f);
        }));
    Widget header(String text, int count) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: Text('$text · $count', style: const TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800,
        color: Neon.dim)));
    Widget row(DevicePreset p) {
      final selected = current?.key == p.key;
      final fav = store.isFavourite(p.favouriteKey(id));
      final user = p.isUser ? store.byId(p.userId!) : null;
      final tagIndex = tags.indexOf(p.category);
      // A right-click opens the menu a long-press does.
      return Pressable(glow: color, child: GestureDetector(
        onSecondaryTap: user == null ? null : () => _menu(context, user),
        child: ListTile(
        key: ValueKey(p.isUser ? 'preset-user-${p.name}' : 'preset-${p.name}'),
        dense: true,
        selected: selected,
        selectedTileColor: color.withValues(alpha: 0.08),
        leading: Icon(p.isUser ? Icons.person_outline : Icons.inventory_2_outlined, size: 18,
          color: tagIndex < 0 ? Neon.dim : colors[tagIndex % colors.length]),
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: Neon.text,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w500)),
        subtitle: p.category.isEmpty || p.category == 'Init' ? null
            : Text(p.category, style: const TextStyle(fontSize: 10, color: Neon.dim)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected) Icon(DevicePresets.modified(t) ? Icons.edit_outlined : Icons.check, size: 16, color: color),
          IconButton(
            key: ValueKey('preset-fav-${p.key}'),
            tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: fav ? Neon.yellow : Neon.dim,
            onPressed: () {
              DeviceFeel.tap();
              store.setFavourite(p.favouriteKey(id), !fav);
            },
            icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded)),
        ]),
        onTap: () {
          DeviceFeel.tap();
          DevicePresets.apply(t, p);
          Navigator.of(context).maybePop();
        },
        onLongPress: user == null ? null : () => _menu(context, user),
      )));
    }

    final empty = shownMine.isEmpty && shownFactory.isEmpty;
    return SizedBox.expand(child: Column(
      key: const ValueKey('preset-browser'),
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 4, 4), child: Row(children: [
        Expanded(child: Text('${t.label} presets', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
        Pressable(glow: color, child: FilledButton.tonalIcon(
          key: const ValueKey('preset-save'),
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact,
            backgroundColor: color.withValues(alpha: 0.2), foregroundColor: Neon.text),
          onPressed: () async {
            DeviceFeel.tap();
            await savePresetAs(context, t);
          },
          icon: const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save preset…', style: TextStyle(fontSize: 12)))),
        PopupMenuButton<String>( popUpAnimationStyle: menuAnimation(context),
          key: const ValueKey('preset-more'),
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, size: 20),
          color: Neon.panelHi,
          onSelected: (v) => _more(context, v),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'import', child: Text('Import preset file…')),
            if (t.layer != null && !(t.layer!.isFolder) && !isMasterLayer(t.layer)) ...[
              const PopupMenuItem(value: 'track-save', child: Text('Save track preset…')),
              const PopupMenuItem(value: 'track-load', child: Text('Load track preset…')),
            ],
          ]),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: SizedBox(height: 38, child: TextField(
        key: const ValueKey('preset-search'),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 18),
          hintText: 'Search presets',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(vertical: 8)),
        onChanged: (v) => setState(() => _query = v),
      ))),
      SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          chip('All', const _All()),
          chip('Favourites', const _Favourites(), icon: Icons.star_rounded),
          chip('My presets', const _Mine()),
          chip('Factory', const _Factory()),
          for (final tag in tags) chip(tag, _Tag(tag)),
        ])),
      Expanded(child: empty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(
              _filter is _Favourites ? 'Tap a star to keep a preset here.' : 'Nothing matches.',
              textAlign: TextAlign.center, style: const TextStyle(color: Neon.dim))))
          : ListView(padding: const EdgeInsets.only(bottom: 16), children: [
              if (shownMine.isNotEmpty || (_filter is _All && _query.isEmpty)) header('MY PRESETS', shownMine.length),
              if (shownMine.isEmpty && _filter is _All && _query.isEmpty) const Padding(
                key: ValueKey('preset-mine-empty'),
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text('Your own sounds go here: shape the device, then Save preset…',
                  style: TextStyle(fontSize: 12, color: Neon.dim))),
              for (final p in shownMine) row(p),
              if (shownFactory.isNotEmpty) header('FACTORY', shownFactory.length),
              for (final p in shownFactory) row(p),
            ])),
    ]));
  }

  Future<void> _more(BuildContext context, String v) async {
    final layer = t.layer;
    switch (v) {
      case 'import':
        await importPreset(context, store);
      case 'track-save':
        if (layer != null) await saveTrackPreset(context, t.state, layer);
      case 'track-load':
        if (layer != null) await showTrackPresets(context, t.state, layer);
    }
  }

  Future<void> _menu(BuildContext context, UserPreset p) async {
    final box = context.findRenderObject() as RenderBox?;
    final at = box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero));
    DeviceFeel.grab();
    await presetMenu(context, store, p, at);
  }
}

/// The long-press menu of a user preset: rename, duplicate, export, delete.
Future<void> presetMenu(BuildContext context, UserPresetStore store, UserPreset p, Offset at) async {
  final action = await showCompactMenu<String>(context, at, const [
    MenuEntry('rename', Icons.drive_file_rename_outline, 'Rename'),
    MenuEntry('duplicate', Icons.copy, 'Duplicate'),
    MenuEntry('export', Icons.file_upload_outlined, 'Export preset file'),
    MenuEntry('delete', Icons.delete_outline, 'Delete', danger: true, dividerBefore: true),
  ]);
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'rename':
      await renamePreset(context, store, p);
    case 'duplicate':
      duplicatePreset(context, store, p);
    case 'export':
      await exportPreset(context, p);
    case 'delete':
      deletePreset(context, store, p);
  }
}

/// The track presets: a tap loads one onto [layer] (one undo step); Save keeps the track's chain as one.
Future<void> showTrackPresets(BuildContext context, AppState state, LayerDoc layer) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: sheetAnimation(context), // in and out at the theme's pace
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Neon.panel,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) => _SheetToasts(height: 0.6, child: ListenableBuilder(listenable: state.userPresets, builder: (context, _) {
        final store = state.userPresets;
        final list = store.trackPresets;
        return SizedBox.expand(child: Column(
          key: const ValueKey('track-presets'),
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 8, 4), child: Row(children: [
            const Expanded(child: Text('Track presets', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
            Pressable(child: FilledButton.tonalIcon(
              key: const ValueKey('track-preset-save'),
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => saveTrackPreset(context, state, layer),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text('Save ${layer.name}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)))),
          ])),
          Expanded(child: list.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text(
                  'A track preset keeps a track\'s instrument and effects with their settings. Save one, then load it on '
                  'any track or drag it from Files › Presets onto the empty area for a new track.',
                  textAlign: TextAlign.center, style: TextStyle(color: Neon.dim))))
              : ListView(children: [
                  for (final p in list) Builder(builder: (context) {
                    void menu() {
                      final box = context.findRenderObject() as RenderBox?;
                      DeviceFeel.grab();
                      presetMenu(context, store, p,
                        box == null ? Offset.zero : box.localToGlobal(box.size.center(Offset.zero)));
                    }
                    // A right-click opens the menu a long-press does.
                    return Pressable(child: GestureDetector(onSecondaryTap: menu, child: ListTile(
                    key: ValueKey('track-preset-${p.name}'),
                    dense: true,
                    leading: const Icon(Icons.view_list_outlined, size: 18, color: Neon.green),
                    title: Text(p.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(trackPresetSummary(state, p), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Neon.dim)),
                    onTap: () {
                      loadTrackPreset(context, state, layer, p);
                      Navigator.of(context).maybePop();
                    },
                    onLongPress: menu,
                  )));
                  }),
                ])),
        ]));
      })),
    );

/// "Flagship · Delay · Reverb": what a track preset holds.
String trackPresetSummary(AppState state, UserPreset p) => [
      if (p.instrument != null) state.componentLabel(p.instrument!.componentId),
      for (final e in p.effects) state.componentLabel(e.componentId),
    ].join(' · ');
