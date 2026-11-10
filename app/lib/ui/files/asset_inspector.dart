// The Files inspector: the selected asset's name, type, place, build state, where it's used, and ▶ preview, open and menu.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/files_catalog.dart';
import '../theme.dart';
import '../tokens.dart';
import 'asset_actions.dart';
import 'asset_views.dart';

class AssetInspector extends StatelessWidget {
  const AssetInspector({super.key, required this.state, required this.asset, required this.actions, required this.onClose,
    this.compact = false});

  final AppState state;
  final FileAsset asset;
  final FilesActions actions;
  final VoidCallback onClose;

  /// The bottom strip (portrait, narrow landscape): fewer lines.
  final bool compact;

  String get _where => switch (asset.type) {
        FileAssetType.builtinEffect => 'Built-in · ${asset.native!.id}',
        FileAssetType.cppComponent => 'C++ components · ${asset.cpp!.componentId}',
        FileAssetType.cppFile => 'C++ components / ${asset.cpp!.name}',
        _ => asset.module!.folderPath.isEmpty ? '.caw modules' : '.caw modules / ${asset.module!.folderPath}',
      };

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final uses = state.usesOf(a);
    final status = a.cpp != null && a.type == FileAssetType.cppComponent ? state.cppStatus(a.cpp!) : null;
    final params = a.native?.parameters.length ?? 0;
    final fav = state.isFavourite(a);
    final previewing = actions.isPreviewing(a);
    Widget line(IconData icon, String text, {Color color = Neon.dim}) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Expanded(child: Text(text, maxLines: compact ? 1 : 3, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TypeScale.caption, color: color))),
          ]),
        );
    Widget button(IconData icon, String tip, VoidCallback? onPressed, {Color? color}) => IconButton(
          tooltip: tip,
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          iconSize: 18,
          icon: Icon(icon, color: onPressed == null ? Neon.line : (color ?? Neon.text)),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.xs, Space.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          AssetIcon(type: a.type, size: 28, warning: status != null),
          const SizedBox(width: Space.s),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: TypeScale.body, fontWeight: FontWeight.w600)),
            Text(a.type.label, style: TextStyle(fontSize: TypeScale.caption, color: assetColor(a.type))),
          ])),
          if (a.previewable)
            button(previewing ? Icons.stop : Icons.play_arrow, previewing ? 'Stop preview' : 'Preview',
                () => actions.togglePreview(a), color: Neon.green),
          if (a.buildTab != null) button(Icons.open_in_new, 'Open in Build', () => actions.open(a)),
          button(fav ? Icons.star_rounded : Icons.star_outline_rounded, fav ? 'Remove from Favourites' : 'Add to Favourites',
              () {
                state.setFavourite(a, !fav);
                actions.onSelect(a.key); // redraws with the new star
              },
              color: fav ? Neon.yellow : null),
          Builder(builder: (c) => button(Icons.more_horiz, 'More', () {
                final box = c.findRenderObject() as RenderBox;
                actions.assetMenu(a, box.localToGlobal(box.size.center(Offset.zero)));
              })),
          button(Icons.close, 'Close inspector', onClose),
        ]),
        line(Icons.place_outlined, _where),
        if (status != null) line(Icons.build_circle_outlined, status, color: Neon.yellow),
        if (a.type == FileAssetType.builtinEffect || a.type == FileAssetType.cppComponent)
          line(Icons.tune, params == 0 ? 'No parameters read yet' : '$params parameters'),
        if (a.type == FileAssetType.cppFile)
          line(Icons.notes, '${'\n'.allMatches(a.cpp!.files[a.filePath] ?? '').length + 1} lines'),
        if (a.module != null && a.module!.tags.isNotEmpty) line(Icons.sell_outlined, a.module!.tags.join(', ')),
        if (a.type != FileAssetType.cppFile && a.type != FileAssetType.cawLibrary)
          line(Icons.view_stream_outlined, uses.isEmpty ? 'Not used on any track' : 'Used on ${uses.join(', ')}',
              color: uses.isEmpty ? Neon.dim : Neon.text),
        if (!compact && a.drag != null)
          line(Icons.pan_tool_alt_outlined, 'Hold and drag onto a track in Arrange'),
      ]),
    );
  }
}
