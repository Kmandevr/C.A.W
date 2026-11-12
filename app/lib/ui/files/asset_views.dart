// How Files draws assets and folders: icons with type badges, grid tiles, compact list rows, and their tap, double-tap, drag and menu gestures.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../model/files_catalog.dart';
import '../frame/sections.dart';
import '../motion.dart';
import '../theme.dart';
import '../pointer_input.dart';
import '../tokens.dart';
import '../panel_motion.dart';

IconData assetIcon(FileAssetType t) => switch (t) {
      FileAssetType.builtinEffect => Icons.graphic_eq,
      FileAssetType.cppComponent => Icons.memory,
      FileAssetType.cppFile => Icons.code,
      FileAssetType.pattern => Icons.piano,
      FileAssetType.midiFile => Icons.queue_music,
      FileAssetType.devicePreset => Icons.bookmarks_outlined,
      FileAssetType.trackPreset => Icons.view_list_outlined,
      FileAssetType.sampleFile => Icons.audio_file_outlined,
      FileAssetType.audioFile => Icons.graphic_eq_rounded,
    };

Color assetColor(FileAssetType t) => switch (t) {
      FileAssetType.builtinEffect => Neon.blue,
      FileAssetType.cppComponent || FileAssetType.cppFile => Neon.violet,
      FileAssetType.pattern || FileAssetType.midiFile || FileAssetType.sampleFile => Neon.yellow,
      FileAssetType.audioFile => Neon.green,
      FileAssetType.devicePreset || FileAssetType.trackPreset => Neon.green,
    };

IconData folderIcon(FilesFolderKind k) => switch (k) {
      FilesFolderKind.favourites => Icons.star_rounded,
      FilesFolderKind.effects => Icons.auto_awesome,
      FilesFolderKind.builtin => Icons.inventory_2_outlined,
      FilesFolderKind.cppEffects || FilesFolderKind.cppList || FilesFolderKind.cppComponent => Icons.memory,
      FilesFolderKind.code => Icons.code,
      FilesFolderKind.audio => Icons.music_note,
      FilesFolderKind.patterns => Icons.piano,
      FilesFolderKind.midiFiles => Icons.queue_music,
      FilesFolderKind.audioFiles => Icons.graphic_eq_rounded,
      FilesFolderKind.presets => Icons.bookmarks_outlined,
      FilesFolderKind.packs || FilesFolderKind.samplePack => Icons.inventory_outlined,
      FilesFolderKind.samplePacks => Icons.library_music_outlined,
    };

Color folderColor(FilesFolderKind k) => k == FilesFolderKind.favourites ? Neon.yellow : Neon.blue;

/// A small type badge ("FX", "C++", "MIDI").
class TypeBadge extends StatelessWidget {
  const TypeBadge(this.text, {super.key, this.color = Neon.dim});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: Neon.bg.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: 0.6), width: 0.8),
        ),
        child: Text(text, style: Neon.code(size: 8, color: color)),
      );
}

/// An asset's icon in a rounded box with its type badge in the corner.
class AssetIcon extends StatelessWidget {
  const AssetIcon({super.key, required this.type, required this.size, this.badge = true, this.warning = false});
  final FileAssetType type;
  final double size;
  final bool badge;

  /// A small warning dot (a C++ component that isn't built or trusted yet).
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final c = assetColor(type);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(size * 0.22),
              border: Border.all(color: c.withValues(alpha: 0.35)),
            ),
            child: Icon(assetIcon(type), size: size * 0.55, color: c),
          ),
        ),
        if (badge) Positioned(right: -2, bottom: -2, child: TypeBadge(type.badge, color: c)),
        if (warning)
          Positioned(
            right: -2,
            top: -2,
            child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: Neon.yellow, shape: BoxShape.circle)),
          ),
      ]),
    );
  }
}

/// Tap selects (at once), a second tap within the double-tap time opens, right-click or a long press without
/// moving opens the menu, and a long press that moves (a mouse: a press that moves) drags the asset (when it can go
/// on a track).
class AssetGestures extends StatefulWidget {
  const AssetGestures({
    super.key,
    required this.asset,
    required this.onSelect,
    required this.onOpen,
    required this.onMenu,
    required this.child,
  });

  final FileAsset asset;
  final VoidCallback onSelect;
  final VoidCallback onOpen;
  final void Function(Offset globalPosition) onMenu;
  final Widget child;

  @override
  State<AssetGestures> createState() => _AssetGesturesState();
}

class _AssetGesturesState extends State<AssetGestures> {
  static const _doubleTap = Duration(milliseconds: 300);
  DateTime? _lastTap;
  Offset? _down;
  double _moved = 0;
  PointerDeviceKind _kind = PointerDeviceKind.touch; // the last press's pointer

  void _tap() {
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null && now.difference(last) <= _doubleTap) {
      _lastTap = null;
      widget.onOpen();
    } else {
      _lastTap = now;
      widget.onSelect();
    }
  }

  void _menu(Offset at) {
    Motion.tick();
    widget.onMenu(at);
  }

  @override
  Widget build(BuildContext context) {
    final drag = widget.asset.drag;
    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _down = d.globalPosition,
      onTap: _tap,
      onSecondaryTapUp: (d) => _menu(d.globalPosition),
      onLongPressStart: drag == null ? (d) => _menu(d.globalPosition) : null,
      child: widget.child,
    );
    if (drag == null) return body;
    return HoldDraggable<AssetDrag>(
      data: drag,
      hapticFeedbackOnStart: false,
      onDragStarted: () {
        _moved = 0;
        Motion.tick();
        widget.onSelect();
      },
      onDragUpdate: (d) => _moved += d.delta.distance,
      // Held still and let go: the long-press menu (a finger; a mouse's drag starts at once and right-clicks for it).
      onDraggableCanceled: (_, offset) {
        if (_moved < 12 && !isMousePointer(_kind)) widget.onMenu(_down ?? offset);
      },
      feedback: AssetDragFeedback(asset: widget.asset),
      childWhenDragging: Opacity(opacity: 0.4, child: widget.child),
      child: Listener(onPointerDown: (e) => _kind = e.kind, child: body),
    );
  }
}

/// What follows the finger while an asset is dragged.
class AssetDragFeedback extends StatelessWidget {
  const AssetDragFeedback({super.key, required this.asset});
  final FileAsset asset;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s, vertical: Space.xs),
          decoration: BoxDecoration(
            color: Neon.panelHi.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(Radii.s),
            border: Border.all(color: assetColor(asset.type)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(assetIcon(asset.type), size: 18, color: assetColor(asset.type)),
            const SizedBox(width: Space.xs),
            Text(asset.name, style: const TextStyle(fontSize: TypeScale.label, color: Neon.text)),
          ]),
        ),
      );
}

BoxDecoration _selection(bool selected) => BoxDecoration(
      color: selected ? Neon.blue.withValues(alpha: 0.16) : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.s),
      border: Border.all(color: selected ? Neon.blue.withValues(alpha: 0.8) : Colors.transparent),
      boxShadow: selected ? [BoxShadow(color: Neon.blue.withValues(alpha: 0.25), blurRadius: 8)] : null,
    );

/// A grid tile: the icon with its badge, then the name.
class AssetTile extends StatelessWidget {
  const AssetTile({super.key, required this.asset, required this.extent, this.selected = false, this.favourite = false,
    this.warning = false});
  final FileAsset asset;
  final double extent;
  final bool selected, favourite, warning;

  @override
  // No Tooltip: its long press would win over the drag and the menu. The name is on the tile.
  Widget build(BuildContext context) => Semantics(
        label: '${asset.name}, ${asset.type.label}',
        selected: selected,
        child: Container(
          decoration: _selection(selected),
          padding: const EdgeInsets.all(Space.xs),
          child: Column(children: [
            Expanded(
              child: Center(
                child: Stack(clipBehavior: Clip.none, children: [
                  AssetIcon(type: asset.type, size: extent * 0.5, warning: warning),
                  if (favourite) const Positioned(left: -4, top: -4, child: Icon(Icons.star_rounded, size: 12, color: Neon.yellow)),
                ]),
              ),
            ),
            const SizedBox(height: 2),
            Text(asset.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                style: TextStyle(fontSize: TypeScale.caption, color: selected ? Neon.text : Neon.text.withValues(alpha: 0.85))),
          ]),
        ),
      );
}

/// A list row (the smallest size): 34 dp tall.
class AssetRow extends StatelessWidget {
  const AssetRow({super.key, required this.asset, this.selected = false, this.favourite = false, this.warning = false,
    this.detail});
  final FileAsset asset;
  final bool selected, favourite, warning;
  final String? detail;

  @override
  Widget build(BuildContext context) => Container(
        height: 34,
        decoration: _selection(selected),
        padding: const EdgeInsets.symmetric(horizontal: Space.s),
        child: Row(children: [
          AssetIcon(type: asset.type, size: 22, badge: false, warning: warning),
          const SizedBox(width: Space.s),
          Expanded(child: Text(asset.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: TypeScale.label))),
          if (favourite) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.star_rounded, size: 12, color: Neon.yellow)),
          if (detail != null)
            Padding(padding: const EdgeInsets.only(right: 6),
                child: Text(detail!, style: const TextStyle(fontSize: TypeScale.caption, color: Neon.dim))),
          TypeBadge(asset.type.badge, color: assetColor(asset.type)),
        ]),
      );
}

/// A folder in the grid or list: tap enters it, long press (or right-click) opens its menu.
class FolderItem extends StatelessWidget {
  const FolderItem({super.key, required this.folder, required this.list, required this.extent, required this.onOpen,
    required this.onMenu});
  final FilesFolder folder;
  final bool list;
  final double extent;
  final VoidCallback onOpen;
  final void Function(Offset at) onMenu;

  @override
  Widget build(BuildContext context) {
    final c = folderColor(folder.kind);
    final body = list
        ? SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.s),
              child: Row(children: [
                SizedBox(width: 22, child: Icon(Icons.folder, size: 18, color: c.withValues(alpha: 0.8))),
                const SizedBox(width: Space.s),
                Expanded(child: Text(folder.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: TypeScale.label))),
                const Icon(Icons.chevron_right, size: 16, color: Neon.dim),
              ]),
            ),
          )
        : Padding(
            padding: const EdgeInsets.all(Space.xs),
            child: Column(children: [
              Expanded(child: Center(child: Stack(alignment: Alignment.center, children: [
                Icon(Icons.folder, size: extent * 0.56, color: c.withValues(alpha: 0.55)),
                Padding(padding: EdgeInsets.only(top: extent * 0.06),
                    child: Icon(folderIcon(folder.kind), size: extent * 0.2, color: Neon.bg)),
              ]))),
              const SizedBox(height: 2),
              Text(folder.label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: TypeScale.caption)),
            ]),
          );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      onLongPressStart: (d) {
        Motion.tick();
        onMenu(d.globalPosition);
      },
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: body,
    );
  }
}

/// A compact long-press menu near the finger: 36 dp rows with an icon each.
class MenuEntry<T> {
  const MenuEntry(this.value, this.icon, this.label, {this.danger = false, this.dividerBefore = false});
  final T value;
  final IconData icon;
  final String label;
  final bool danger, dividerBefore;
}

Future<T?> showCompactMenu<T>(BuildContext context, Offset at, List<MenuEntry<T>> entries) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final size = overlay.size;
  return showMenu<T>(
    context: context, popUpAnimationStyle: menuAnimation(context),
    position: RelativeRect.fromLTRB(at.dx, at.dy, size.width - at.dx, size.height - at.dy),
    color: Neon.panelHi.withValues(alpha: 0.96),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.m), side: BorderSide(color: Neon.ink.withValues(alpha: 0.12))),
    menuPadding: const EdgeInsets.symmetric(vertical: Space.xs),
    items: [
      for (final e in entries) ...[
        if (e.dividerBefore) const PopupMenuDivider(height: 6),
        PopupMenuItem<T>(
          value: e.value,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: Space.m),
          child: Row(children: [
            Icon(e.icon, size: 18, color: e.danger ? Neon.pink : Neon.text),
            const SizedBox(width: Space.m),
            Flexible(child: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TypeScale.label, color: e.danger ? Neon.pink : Neon.text))),
          ]),
        ),
      ],
    ],
  );
}
