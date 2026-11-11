// The effect browser that "+ FX", "Instrument…", "+ on a wire" and a rack's empty slot open: category tabs, search, favourites, recents.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/effect_recents.dart';
import '../../model/files_catalog.dart';
import '../../model/racks.dart';
import '../devices/effects/effect_catalog.dart';
import '../frame/sections.dart';
import '../glass.dart';
import '../theme.dart';
import '../tokens.dart';
import 'asset_actions.dart';
import 'asset_views.dart';

/// Slides up a half sheet listing [kinds] of assets (instruments: built-in and the project's C++ ones; effects:
/// built-in and the project's C++ effects; patterns) and returns the one tapped, or null when
/// dismissed. [instruments] and [effects] leave either group out; [rackChild] lists only what a rack's slot can hold
/// (built-in effects, no racks).
Future<AssetDrag?> showAssetPicker(BuildContext context, AppState state, {required Set<AssetKind> kinds,
    String title = 'Add FX', bool instruments = true, bool effects = true, bool rackChild = false}) {
  final height = MediaQuery.sizeOf(context).height;
  return showGlassSheet<AssetDrag>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: height * 0.72, maxWidth: 640),
    builder: (_) => AssetPickerSheet(state: state, kinds: kinds, title: title, instruments: instruments && !rackChild,
        effects: effects, rackChild: rackChild),
  );
}

/// The sheet's body: a title, search, category tabs (All, then [EffectCategory]'s nine), and the list. On All with
/// no search: Favourites and Recently used first, then Instruments, the built-ins by category and My effects (each
/// only when it has something). Each built-in shows its icon, name and one-line description ([EffectCatalog]) and a
/// star. A project C++ effect that isn't built or trusted yet is still listed, with a badge saying so.
class AssetPickerSheet extends StatefulWidget {
  const AssetPickerSheet({super.key, required this.state, required this.kinds, required this.title,
    this.instruments = true, this.effects = true, this.rackChild = false});
  final AppState state;
  final Set<AssetKind> kinds;
  final String title;
  final bool instruments, effects, rackChild;

  @override
  State<AssetPickerSheet> createState() => _AssetPickerSheetState();
}

class _AssetPickerSheetState extends State<AssetPickerSheet> {
  String _query = '';
  EffectCategory? _tab;  // null: All

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.refreshNativeCatalog().then((_) {
      if (mounted) setState(() {});
    });
    state.filesFavourites.load().then((_) {
      if (mounted) setState(() {});
    });
    state.effectRecents.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  String get _q => _query.trim().toLowerCase();

  bool _match(FileAsset a) {
    final q = _q;
    if (q.isEmpty) return true;
    if (a.builtin && a.native != null) return EffectCatalog.describe(a.native!).matches(q, a.name);
    return a.name.toLowerCase().contains(q) || a.type.label.toLowerCase().contains(q) ||
        (a.native?.id.toLowerCase().contains(q) ?? false);
  }

  EffectCategory _category(FileAsset a) => EffectCatalog.describe(a.native!).category;

  /// The built-in effects this sheet may list.
  List<FileAsset> get _builtinEffects => [
        if (widget.effects && widget.kinds.contains(AssetKind.nativeEffect))
          for (final a in state.builtinAssets)
            if (a.drag != null && !a.isInstrument && (!widget.rackChild || canGoInRack(a.native!))) a,
      ];

  List<(String, List<FileAsset>)> _groups() {
    final k = widget.kinds;
    final modules = state.moduleAssets;
    final native = k.contains(AssetKind.nativeEffect);
    final builtins = _builtinEffects;
    final tab = _tab;
    if (tab != null) {
      return [(tab.label, [for (final a in builtins) if (_category(a) == tab && _match(a)) a])];
    }
    final byId = {for (final a in builtins) a.native!.id: a};
    final browsing = _q.isEmpty;
    final groups = <(String, List<FileAsset>)>[
      if (browsing) ('Favourites', [for (final a in builtins) if (state.isFavourite(a)) a]),
      if (browsing) ('Recently used', [for (final id in state.effectRecents.ids) ?byId[id]]),
      // Instruments first, as REAPER puts the instrument first in a track's FX chain.
      if (widget.instruments) ('Instruments', [
        if (native) ...state.builtinAssets.where((a) => a.drag != null && a.isInstrument),
        if (native) ...state.cppAssets.where((a) => a.drag != null && a.isInstrument),
      ]),
      for (final c in EffectCategory.values) (c.label, [for (final a in builtins) if (_category(a) == c) a]),
      if (widget.effects && !widget.rackChild) ('My effects', [
        if (native) ...state.cppAssets.where((a) => a.drag != null && !a.isInstrument),
      ]),
      if (k.contains(AssetKind.pattern) && !widget.rackChild)
        ('Patterns', modules),
      // Packs: the app has no packs yet, so there is no group.
    ];
    return [for (final (name, list) in groups) if (list.where(_match).isNotEmpty) (name, list.where(_match).toList())];
  }

  void _pick(FileAsset a) {
    if (a.builtin && a.native != null && !a.isInstrument) state.effectRecents.use(a.native!.id);
    Navigator.of(context).pop(a.drag);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final groups = _groups();
          final actions = FilesActions(context: context, state: state, onOpenBuilder: () {}, onSelect: (_) {});
          final empty = groups.isEmpty || groups.every((g) => g.$2.isEmpty);
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.s, Space.xs),
              child: Row(children: [
                Expanded(child: Text(widget.title, style: const TextStyle(fontSize: TypeScale.title, fontWeight: FontWeight.w600))),
                IconButton(
                  tooltip: 'Close',
                  iconSize: 18,
                  constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: SizedBox(
                height: 34,
                child: TextField(
                  key: const ValueKey('fx-browser-search'),
                  style: const TextStyle(fontSize: TypeScale.label),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search name, what it does…',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    prefixIconConstraints: const BoxConstraints(minWidth: 30),
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.s)),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
            if (_builtinEffects.isNotEmpty) _tabs(),
            const SizedBox(height: Space.xs),
            Flexible(
              child: empty
                  ? Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Text(_q.isEmpty ? (_tab == null ? 'Nothing to add yet.' : 'No ${_tab!.label} effects yet.') : 'Nothing matches.',
                          textAlign: TextAlign.center, style: const TextStyle(color: Neon.dim)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.l),
                      children: [
                        for (final (name, list) in groups) ...[
                          if (_tab == null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(Space.s, Space.s, Space.s, 2),
                              child: Text(name.toUpperCase(), style: TypeScale.heading()),
                            ),
                          for (final a in list)
                            a.builtin && a.native != null && !a.isInstrument ? _effectRow(context, a, actions, name)
                                : _row(context, a, actions),
                        ],
                      ],
                    ),
            ),
          ]);
        },
      );

  Widget _tabs() => SizedBox(
        height: 40,
        child: ListView(
          key: const ValueKey('fx-browser-tabs'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.m, 0),
          children: [
            _tabChip(null, 'All', Icons.apps, Neon.text),
            for (final c in EffectCategory.values) _tabChip(c, c.label, c.icon, c.color),
          ],
        ),
      );

  Widget _tabChip(EffectCategory? c, String label, IconData icon, Color color) {
    final on = _tab == c;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: ChoiceChip(
        key: ValueKey('fx-tab-${c?.name ?? 'all'}'),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: Icon(icon, size: 14, color: on ? Neon.bg : color),
        label: Text(label, style: TextStyle(fontSize: 11, color: on ? Neon.bg : Neon.text)),
        selected: on,
        selectedColor: color,
        showCheckmark: false,
        onSelected: (_) => setState(() => _tab = c),
      ),
    );
  }

  /// A built-in effect: its picture, name, one-line description, a star and (if it has one) a preview.
  Widget _effectRow(BuildContext context, FileAsset a, FilesActions actions, String group) {
    final e = EffectCatalog.describe(a.native!);
    final color = e.category.color;
    final fav = state.isFavourite(a);
    final previewing = actions.isPreviewing(a);
    return InkWell(
      key: ValueKey('fx-browser-$group-${a.native!.id}'),
      borderRadius: BorderRadius.circular(Radii.s),
      onTap: () => _pick(a),
      child: SizedBox(
        height: 48,
        child: Row(children: [
          const SizedBox(width: Space.s),
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0.4)])),
            child: Icon(e.icon, size: 17, color: Neon.bg)),
          const SizedBox(width: Space.s),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TypeScale.label, fontWeight: FontWeight.w600)),
              Text(e.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Neon.dim)),
            ])),
          IconButton(
            key: ValueKey('fx-fav-${a.native!.id}'),
            tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
            iconSize: 18,
            constraints: const BoxConstraints.tightFor(width: 40, height: 44),
            onPressed: () => setState(() => state.setFavourite(a, !fav)),
            icon: Icon(fav ? Icons.star : Icons.star_border, color: fav ? Neon.yellow : Neon.dim),
          ),
          if (a.previewable)
            IconButton(
              tooltip: previewing ? 'Stop preview' : 'Preview',
              iconSize: 18,
              constraints: const BoxConstraints.tightFor(width: 40, height: 44),
              onPressed: () => actions.togglePreview(a),
              icon: Icon(previewing ? Icons.stop : Icons.play_arrow, color: Neon.green),
            ),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, FileAsset a, FilesActions actions) {
    final status = a.type == FileAssetType.cppComponent ? state.cppStatus(a.cpp!) : null;
    final previewing = actions.isPreviewing(a);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.s),
      onTap: () => _pick(a),
      child: SizedBox(
        height: 36,
        child: Row(children: [
          const SizedBox(width: Space.s),
          AssetIcon(type: a.type, size: 22, badge: false, warning: status != null),
          const SizedBox(width: Space.s),
          Expanded(child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: TypeScale.label))),
          if (status != null)
            Padding(padding: const EdgeInsets.only(right: Space.xs), child: TypeBadge(status, color: Neon.yellow)),
          TypeBadge(a.isInstrument ? 'INST' : a.type.badge,
              color: assetColor(a.type)),
          if (a.previewable)
            IconButton(
              tooltip: previewing ? 'Stop preview' : 'Preview',
              iconSize: 18,
              constraints: const BoxConstraints.tightFor(width: 40, height: 36),
              onPressed: () => actions.togglePreview(a),
              icon: Icon(previewing ? Icons.stop : Icons.play_arrow, color: Neon.green),
            )
          else
            const SizedBox(width: Space.s),
        ]),
      ),
    );
  }
}
