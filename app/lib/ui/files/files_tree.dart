// The Files folder tree (Favourites, Effects & instruments, Code, Audio & MIDI): 32 dp rows that expand, select and open a folder menu.
import 'package:flutter/material.dart';

import '../../model/files_catalog.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'asset_views.dart';

class FilesTree extends StatefulWidget {
  const FilesTree({super.key, required this.tree, required this.current, required this.onOpen, required this.onMenu});

  final List<FilesFolder> tree;
  final String current;
  final ValueChanged<FilesFolder> onOpen;
  final void Function(FilesFolder folder, Offset at) onMenu;

  @override
  State<FilesTree> createState() => _FilesTreeState();
}

class _FilesTreeState extends State<FilesTree> {
  final Set<String> _expanded = {'fx', 'code', 'audio'};

  @override
  void didUpdateWidget(FilesTree old) {
    super.didUpdateWidget(old);
    // Keep the open folder's ancestors expanded.
    final parts = widget.current.split('/');
    for (var i = 1; i < parts.length; i++) {
      _expanded.add(parts.take(i).join('/'));
    }
  }

  Iterable<Widget> _rows(List<FilesFolder> level, int depth) sync* {
    for (final f in level) {
      final open = _expanded.contains(f.path);
      yield _TreeRow(
        folder: f,
        depth: depth,
        expanded: open,
        selected: f.path == widget.current,
        onToggle: f.children.isEmpty ? null : () => setState(() => open ? _expanded.remove(f.path) : _expanded.add(f.path)),
        onTap: () => widget.onOpen(f),
        onMenu: (at) => widget.onMenu(f, at),
      );
      if (open) yield* _rows(f.children, depth + 1);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.symmetric(vertical: Space.xs),
        children: [..._rows(widget.tree, 0)],
      );
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({required this.folder, required this.depth, required this.expanded, required this.selected,
    required this.onToggle, required this.onTap, required this.onMenu});

  final FilesFolder folder;
  final int depth;
  final bool expanded, selected;
  final VoidCallback? onToggle;
  final VoidCallback onTap;
  final void Function(Offset at) onMenu;

  @override
  Widget build(BuildContext context) {
    final c = folderColor(folder.kind);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPressStart: (d) {
        Motion.tick();
        onMenu(d.globalPosition);
      },
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: Container(
        height: 32,
        margin: const EdgeInsets.symmetric(horizontal: Space.xs),
        decoration: BoxDecoration(
          color: selected ? Neon.blue.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.s),
        ),
        padding: EdgeInsets.only(left: 2.0 + depth * 14),
        child: Row(children: [
          SizedBox(
            width: 24,
            height: 32,
            child: onToggle == null
                ? null
                : InkResponse(
                    radius: 16,
                    onTap: onToggle,
                    child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: Neon.dim),
                  ),
          ),
          Icon(folderIcon(folder.kind), size: 16, color: selected ? c : c.withValues(alpha: 0.75)),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text(folder.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TypeScale.label, color: selected ? Neon.text : Neon.text.withValues(alpha: 0.85),
                    fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.normal)),
          ),
        ]),
      ),
    );
  }
}
