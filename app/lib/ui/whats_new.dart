// What's new: the bundled changelog as a page (Settings › About and beta › What's new) and the sheet shown once
// after an update with the new version's entry ("See all changes", "Close"); docs/app.md "Updates".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/changelog.dart';
import '../model/settings.dart';
import '../version.dart';
import 'adaptive_sheet.dart';
import 'motion.dart';
import 'panel_motion.dart';
import 'privacy/privacy_pages.dart' show copyWithNote;
import 'theme.dart';

/// The bundled copy of the repository's CHANGELOG.md.
const changelogAsset = 'assets/CHANGELOG.md';

/// The changelog on GitHub.
const changelogUrl = 'https://github.com/Kmandevr/C.A.W/blob/Main/CHANGELOG.md';

/// Reads an asset (tests pass their own).
typedef AssetLoader = Future<String> Function(String asset);

Future<Changelog> loadChangelog([AssetLoader? load]) async {
  try {
    return Changelog.parse(await (load ?? rootBundle.loadString)(changelogAsset));
  } catch (_) {
    return const Changelog(); // a missing asset shows an empty list, never an error
  }
}

/// The changelog's blocks, styled like the app's other text pages.
class ChangelogBlocks extends StatelessWidget {
  const ChangelogBlocks(this.lines, {super.key});
  final List<ChangelogLine> lines;

  static TextSpan _spans(List<ChangelogSpan> spans, TextStyle base) => TextSpan(style: base, children: [
        for (final s in spans)
          TextSpan(
            text: s.text,
            style: s.code
                ? Neon.code(size: (base.fontSize ?? 14) - 1, color: base.color ?? Neon.text)
                : (s.bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(fontSize: 14, height: 1.4, color: Neon.text);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final l in lines)
        switch (l.kind) {
          ChangelogKind.subheading => Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text.rich(_spans(l.spans,
                  const TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: Neon.dim))),
            ),
          ChangelogKind.paragraph => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(_spans(l.spans, const TextStyle(fontSize: 14, height: 1.4, color: Neon.dim))),
            ),
          ChangelogKind.bullet => Padding(
              padding: EdgeInsets.only(left: 4.0 + 16 * l.depth, bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // A drawn dot, filled at the top level and a ring below it (no glyph a font may lack).
                SizedBox(
                  width: 14,
                  height: 19.6, // the first line's height (14 × 1.4)
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: l.depth == 0 ? Neon.dim : null,
                        border: l.depth == 0 ? null : Border.all(color: Neon.dim),
                      ),
                    ),
                  ),
                ),
                Expanded(child: Text.rich(_spans(l.spans, body))),
              ]),
            ),
        },
    ]);
  }
}

/// The version heading of an entry: the version, then its date or note.
class _EntryHeading extends StatelessWidget {
  const _EntryHeading(this.entry);
  final ChangelogEntry entry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 2),
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
          Text('v${entry.version}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          if (entry.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(entry.note, style: const TextStyle(fontSize: 13, color: Neon.dim)),
            ),
        ]),
      );
}

/// Opens What's new as a page.
Future<void> showWhatsNewPage(BuildContext context, {AssetLoader? load}) =>
    Navigator.of(context).push(panelRoute<void>(context, (_) => WhatsNewPage(load: load)));

/// Every version's changes, newest first.
class WhatsNewPage extends StatefulWidget {
  const WhatsNewPage({super.key, this.load});
  final AssetLoader? load;

  @override
  State<WhatsNewPage> createState() => _WhatsNewPageState();
}

class _WhatsNewPageState extends State<WhatsNewPage> {
  late final Future<Changelog> _log = loadChangelog(widget.load);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("What's new"), backgroundColor: Neon.panel, actions: [
          IconButton(
            key: const ValueKey('whats-new-copy-link'),
            tooltip: 'Copy the link to the changelog on GitHub',
            icon: const Icon(Icons.link),
            onPressed: () => copyWithNote(context, changelogUrl, 'Link copied: $changelogUrl'),
          ),
        ]),
        body: SafeArea(top: false, child: FutureBuilder<Changelog>(
          future: _log,
          builder: (context, snap) => AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, Motion.of(context)),
            child: switch (snap.data) {
              final log? => ListView(
                  key: const ValueKey('whats-new-list'),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    if (log.intro.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: ChangelogBlocks(log.intro)),
                    for (final e in log.entries) ...[
                      KeyedSubtree(key: ValueKey('whats-new-entry:${e.version}'), child: _EntryHeading(e)),
                      ChangelogBlocks(e.lines),
                    ],
                    if (log.entries.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text('The changelog is not in this build.', style: TextStyle(color: Neon.dim)),
                      ),
                  ],
                ),
              null => const SizedBox.shrink(key: ValueKey('whats-new-loading')),
            },
          ),
        )),
      );
}

/// After [AppPrompts] has given this launch its turn: for [WhatsNewDue.show], this version's entry as a sheet (a
/// dialog on a wide screen), once; otherwise nothing is shown. Either way this version is stored as seen first, so
/// the sheet never shows twice, even if the app closes while it is open. A version with no entry shows nothing.
Future<void> showWhatsNew(BuildContext context, Settings settings, WhatsNewDue due,
    {String version = appVersion, AssetLoader? load}) async {
  if (due == WhatsNewDue.none) return;
  await settings.update((s) => s.lastSeenVersion = version);
  if (due != WhatsNewDue.show || !context.mounted) return;
  final entry = (await loadChangelog(load)).entryFor(version);
  if (entry == null || !context.mounted) return;
  final all = await showDialogOrSheet<bool>(
    context: context,
    builder: (c) => AlertDialog(
      key: const ValueKey('whats-new-sheet'),
      scrollable: true,
      title: Text("What's new in v${entry.version}"),
      content: ChangelogBlocks(entry.lines),
      // One Wrap, as in the update prompt: it measures the rows it really makes on a narrow phone.
      actions: [
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 4, children: [
          TextButton(
              key: const ValueKey('whats-new-all'), onPressed: () => Navigator.pop(c, true), child: const Text('See all changes')),
          FilledButton(key: const ValueKey('whats-new-close'), onPressed: () => Navigator.pop(c, false), child: const Text('Close')),
        ]),
      ],
    ),
  );
  if (all == true && context.mounted) await showWhatsNewPage(context, load: load);
}
