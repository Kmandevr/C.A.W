// The filtered browser sheet that "+ effect" and "+ on a wire" open: pick an asset of the given kinds, or nothing.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/files_catalog.dart';
import '../frame/sections.dart';
import '../glass.dart';
import '../theme.dart';
import '../tokens.dart';
import 'asset_actions.dart';
import 'asset_views.dart';

/// Slides up a half sheet listing [kinds] of assets (effects: built-in, the project's C++ effects, .caw effect
/// modules), with search and preview; returns the one tapped, or null when dismissed.
Future<AssetDrag?> showAssetPicker(BuildContext context, AppState state, {required Set<AssetKind> kinds,
    String title = 'Add effect'}) {
  final height = MediaQuery.sizeOf(context).height;
  return showGlassSheet<AssetDrag>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(maxHeight: height * 0.62, maxWidth: 640),
    builder: (_) => AssetPickerSheet(state: state, kinds: kinds, title: title),
  );
}

/// The sheet's body: a title, search, and the assets grouped as Built-in, My effects, My instruments, Patterns
/// and Packs (each only when it has something). A project C++ effect that isn't built or trusted yet is still
/// listed, with a badge saying so.
class AssetPickerSheet extends StatefulWidget {
  const AssetPickerSheet({super.key, required this.state, required this.kinds, required this.title});
  final AppState state;
  final Set<AssetKind> kinds;
  final String title;

  @override
  State<AssetPickerSheet> createState() => _AssetPickerSheetState();
}

class _AssetPickerSheetState extends State<AssetPickerSheet> {
  String _query = '';

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.refreshNativeCatalog().then((_) {
      if (mounted) setState(() {});
    });
  }

  bool _match(FileAsset a) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty || a.name.toLowerCase().contains(q) || a.type.label.toLowerCase().contains(q) ||
        (a.native?.id.toLowerCase().contains(q) ?? false);
  }

  List<(String, List<FileAsset>)> _groups() {
    final k = widget.kinds;
    final modules = state.moduleAssets;
    final groups = <(String, List<FileAsset>)>[
      if (k.contains(AssetKind.nativeEffect)) ('Built-in', state.builtinAssets.where((a) => a.drag != null).toList()),
      ('My effects', [
        if (k.contains(AssetKind.nativeEffect)) ...state.cppAssets.where((a) => a.drag != null),
        if (k.contains(AssetKind.cawModule)) ...modules.where((a) => a.type == FileAssetType.cawEffect),
      ]),
      if (k.contains(AssetKind.cawModule)) ('My instruments', modules.where((a) => a.type == FileAssetType.cawGenerator).toList()),
      if (k.contains(AssetKind.pattern)) ('Patterns', modules.where((a) => a.type == FileAssetType.pattern).toList()),
      // Packs: the app has no packs yet, so there is no group.
    ];
    return [for (final (name, list) in groups) if (list.where(_match).isNotEmpty) (name, list.where(_match).toList())];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final groups = _groups();
          final actions = FilesActions(context: context, state: state, onOpenBuilder: () {}, onSelect: (_) {});
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
                  style: const TextStyle(fontSize: TypeScale.label),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    prefixIconConstraints: const BoxConstraints(minWidth: 30),
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.s)),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
            const SizedBox(height: Space.xs),
            Flexible(
              child: groups.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Text(_query.trim().isEmpty ? 'Nothing to add yet.' : 'Nothing matches.',
                          textAlign: TextAlign.center, style: const TextStyle(color: Neon.dim)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.s, Space.l),
                      children: [
                        for (final (name, list) in groups) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(Space.s, Space.s, Space.s, 2),
                            child: Text(name.toUpperCase(), style: TypeScale.heading()),
                          ),
                          for (final a in list) _row(context, a, actions),
                        ],
                      ],
                    ),
            ),
          ]);
        },
      );

  Widget _row(BuildContext context, FileAsset a, FilesActions actions) {
    final status = a.type == FileAssetType.cppComponent ? state.cppStatus(a.cpp!) : null;
    final previewing = actions.isPreviewing(a);
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.s),
      onTap: () => Navigator.of(context).pop(a.drag),
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
          TypeBadge(a.type.badge, color: assetColor(a.type)),
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
