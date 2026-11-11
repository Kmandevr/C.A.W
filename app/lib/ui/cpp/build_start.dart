// Build's start page (no tab open): what Build is for, three starting cards, examples, the Library and the project's code.
import 'package:flutter/material.dart';

import '../../engine/engine.dart' show Template;
import '../../model/app_state.dart';
import '../../model/cpp_starters.dart';
import '../../model/cpp_workbench.dart';
import '../feedback.dart';
import '../glass.dart';
import '../haptics.dart';
import '../theme.dart';
import '../frame/sections.dart';

/// One entry of "Open an example": a bundled C++ starter (an instrument or an effect), or a pattern template
/// (read from its header: `kind:`, `name:`, `summary:`).
class StarterExample {
  StarterExample(this.key, this.kind, this.name, this.summary, {this.template, this.starter});
  final String key, kind, name, summary;
  final Template? template;
  final CppStarter? starter;

  /// Plays notes (an instrument), changes sound (an effect), or is notes for a track (a pattern).
  String get group => switch (kind) {
        'pattern' => 'Patterns',
        'effect' => 'Effects',
        _ => 'Instruments',
      };

  static StarterExample of(Template t) {
    String field(String key) => RegExp('^$key:\\s*(.*)\$', multiLine: true).firstMatch(t.source)?.group(1)?.trim() ?? '';
    final name = field('name');
    return StarterExample(t.file, field('kind'), name.isEmpty ? t.file : name, field('summary'), template: t);
  }

  static StarterExample cpp(CppStarter s) =>
      StarterExample('cpp/${s.folder}', s.instrument ? 'instrument' : 'effect', s.name, s.summary, starter: s);
}

/// The examples: the C++ starters, then the pattern templates (the .caw sound modules are replaced by the starters,
/// #122).
List<StarterExample> starterExamples(List<Template> templates) => [
      for (final s in cppStarters) StarterExample.cpp(s),
      for (final t in templates) StarterExample.of(t),
    ].where((e) => e.starter != null || e.kind == 'pattern').toList();

/// The three ways to start, with a one-line explanation and a tiny code preview each.
class StartCard {
  const StartCard(this.id, this.icon, this.color, this.title, this.detail, this.preview);
  final String id;
  final IconData icon;
  final Color color;
  final String title, detail, preview;
}

const startCards = [
  StartCard('new instrument', Icons.piano_outlined, Neon.green, 'New instrument', 'C++ that plays a track\'s notes',
      'class Synth : public caw::InstrumentProcessor\n  void onNote(const caw::NoteMessage& m)'),
  StartCard('new effect', Icons.tune, Neon.pink, 'New effect', 'C++ that shapes a track\'s sound',
      'void process(const caw::StereoProcessBlock& block)\n  block.outputLeft[i] = block.inputLeft[i];'),
  StartCard('new pattern', Icons.queue_music, Neon.yellow, 'New pattern', 'Notes for a track, as text or a piano roll',
      '// at  note  len  vel\n0     C4    1/4  0.8'),
];

/// No tab open: what Build is for, the starting cards, examples, the Library and the project's own code.
class BuildStartView extends StatelessWidget {
  const BuildStartView({
    super.key,
    required this.state,
    required this.onOpen,
    required this.onNewPattern,
    required this.onLibrary,
    required this.onFind,
  });

  final AppState state;
  final ValueChanged<BuildTab> onOpen;
  final VoidCallback onNewPattern, onLibrary, onFind;

  void _start(String id) {
    Haptics.tap();
    switch (id) {
      case 'new instrument' || 'new effect':
        final doc = state.newCppEffect(instrument: id == 'new instrument');
        onOpen(BuildTab(BuildTabKind.cpp, doc.componentId));
      case 'new pattern':
        onNewPattern();
    }
  }

  Future<void> _examples(BuildContext context) async {
    final examples = starterExamples(state.templates);
    final picked = await showGlassSheet<StarterExample>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      builder: (c) => ExamplesList(examples: examples, onPick: (e) => Navigator.pop(c, e)),
    );
    if (picked == null) return;
    final starter = picked.starter;
    if (starter != null) {
      final doc = state.addCppStarter(starter);
      onOpen(BuildTab(BuildTabKind.cpp, doc.componentId));
      return;
    }
    final id = state.addModule(picked.template!);
    state.selectModule(id);
    onOpen(BuildTab(BuildTabKind.pattern, id));
  }

  @override
  Widget build(BuildContext context) {
    final cpp = state.project.cppComponents;
    final patterns = state.project.modules.where((m) => state.isPattern(m.id)).toList();
    final desktop = Theme.of(context).platform == TargetPlatform.windows ||
        Theme.of(context).platform == TargetPlatform.linux ||
        Theme.of(context).platform == TargetPlatform.macOS;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 640;
      final pad = wide ? 24.0 : 14.0;
      final cards = [
        for (final c in startCards) _StartCardView(card: c, compact: !wide, onTap: () => _start(c.id)),
      ];
      Widget heading(String t, {int? count}) => Padding(
            padding: EdgeInsets.fromLTRB(pad, 18, pad, 6),
            child: Row(children: [
              Text(t.toUpperCase(), style: const TextStyle(fontSize: 10.5, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: Neon.dim)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count', style: Neon.code(size: 10.5, color: Neon.dim)),
              ],
            ]),
          );
      Widget row(String key, IconData icon, Color color, String title, String detail, VoidCallback onTap) => InkWell(
            key: ValueKey(key),
            onTap: () {
              Haptics.tap();
              onTap();
            },
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 8),
              child: Row(children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                Text(detail, style: Neon.code(size: 10.5, color: Neon.dim)),
              ]),
            ),
          );
      return ListView(key: const ValueKey('build start'), padding: const EdgeInsets.only(bottom: 32), children: [
        // The title: a code tool's header, in the mono font.
        Padding(
          padding: EdgeInsets.fromLTRB(pad, wide ? 22 : 14, pad, 2),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Neon.green.withValues(alpha: 0.6)),
                color: Neon.green.withValues(alpha: 0.08),
              ),
              child: Text('</>', style: Neon.code(size: 12, color: Neon.green)),
            ),
            const SizedBox(width: 10),
            Text('Build', style: Neon.code(size: wide ? 22 : 19, color: Neon.text).copyWith(fontWeight: FontWeight.w700)),
            Text(' · C++', style: Neon.code(size: wide ? 22 : 19, color: Neon.green)),
          ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 12),
          child: const Text('Write C++ instruments, effects and patterns, then hear them on your tracks.',
              key: ValueKey('build tagline'), style: TextStyle(fontSize: 13.5, color: Neon.dim, height: 1.35)),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: wide
              ? IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(child: cards[i]),
                    ],
                  ]),
                )
              : Column(children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    cards[i],
                  ],
                ]),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad - 4, 10, pad - 4, 0),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            _Link(key: const ValueKey('open example'), icon: Icons.auto_awesome, label: 'Open an example', onTap: () => _examples(context)),
            _Link(key: const ValueKey('start library'), icon: Icons.menu_book_outlined, label: 'Library reference', onTap: onLibrary),
            _Link(key: const ValueKey('start find'), icon: Icons.search, label: desktop ? 'Find a file  Ctrl+P' : 'Find a file', onTap: onFind),
          ]),
        ),
        heading('C++ code', count: cpp.length),
        if (cpp.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 2),
            child: const Text('None yet. A new instrument plays a sine and a new effect passes sound through: '
                'both build and play at once, ready to change.',
                style: TextStyle(fontSize: 12, color: Neon.dim, height: 1.35)),
          ),
        for (final c in cpp)
          row(
            'open cpp ${c.componentId}',
            cppIsInstrument(c.files.values) ? Icons.piano_outlined : Icons.tune,
            cppIsInstrument(c.files.values) ? Neon.green : Neon.pink,
            c.name,
            '${c.files.length} files',
            () => onOpen(BuildTab(BuildTabKind.cpp, c.componentId)),
          ),
        if (patterns.isNotEmpty) heading('Patterns', count: patterns.length),
        for (final m in patterns)
          row('open pattern ${m.id}', Icons.queue_music, Neon.yellow, m.name, 'pattern', () {
            state.selectModule(m.id);
            onOpen(BuildTab(BuildTabKind.pattern, m.id));
          }),
        if (desktop)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 20, pad, 0),
            child: Text('Ctrl+Shift+N new · Ctrl+P find · Ctrl+B build · F8 next error · Ctrl+Shift+E explorer',
                style: Neon.code(size: 10.5, color: Neon.dim)),
          ),
      ]);
    });
  }
}

/// A big starting card: icon, title, one line and a tiny code preview in the mono font.
class _StartCardView extends StatelessWidget {
  const _StartCardView({required this.card, required this.compact, required this.onTap});
  final StartCard card;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = card.color;
    final preview = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: c.withValues(alpha: 0.7), width: 2)),
      ),
      child: Text(card.preview, maxLines: 2, overflow: TextOverflow.ellipsis, style: Neon.code(size: 10.5, color: Neon.dim)),
    );
    final title = Row(children: [
      Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
        child: Icon(card.icon, size: 18, color: c),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(card.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          Text(card.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Neon.dim)),
        ]),
      ),
      Icon(Icons.add, size: 18, color: c),
    ]);
    return Pressable(
      glow: c,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey(card.id),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: c.withValues(alpha: 0.05),
              border: Border.all(color: c.withValues(alpha: 0.35)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              title,
              SizedBox(height: compact ? 6 : 10),
              preview,
            ]),
          ),
        ),
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: Neon.blue,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          onPressed: () {
            Haptics.tap();
            onTap();
          },
          icon: Icon(icon, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12.5)),
        ),
      );
}

/// The starter examples, grouped as instruments, effects and patterns; a tap adds one to the project.
class ExamplesList extends StatelessWidget {
  const ExamplesList({super.key, required this.examples, required this.onPick});
  final List<StarterExample> examples;
  final ValueChanged<StarterExample> onPick;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<StarterExample>>{};
    for (final e in examples) {
      (groups[e.group] ??= []).add(e);
    }
    final color = {'Instruments': Neon.green, 'Effects': Neon.pink, 'Patterns': Neon.yellow};
    final icon = {'Instruments': Icons.piano_outlined, 'Effects': Icons.tune, 'Patterns': Icons.queue_music};
    return ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 2),
        child: Text('Examples', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Text('A copy goes into this project for you to read, play and change.', style: TextStyle(fontSize: 12, color: Neon.dim)),
      ),
      if (examples.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('The examples load with the sound engine.', style: TextStyle(fontSize: 12, color: Neon.dim)),
        ),
      for (final g in const ['Instruments', 'Effects', 'Patterns'])
        if (groups[g] != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(g.toUpperCase(),
                style: TextStyle(fontSize: 10.5, letterSpacing: 1.3, fontWeight: FontWeight.w700, color: color[g])),
          ),
          for (final e in groups[g]!)
            ListTile(
              key: ValueKey('example ${e.key}'),
              dense: true,
              leading: Icon(icon[g], size: 18, color: color[g]),
              title: Text(e.name, style: const TextStyle(fontSize: 13)),
              subtitle: e.summary.isEmpty
                  ? null
                  : Text(e.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Neon.dim)),
              onTap: () => onPick(e),
            ),
        ],
    ]);
  }
}

/// Whether C++ sources make an instrument (derive from `caw::InstrumentProcessor`) rather than an effect.
bool cppIsInstrument(Iterable<String> sources) => sources.any((s) => s.contains('InstrumentProcessor'));

/// The icon and colour of a Build tab or explorer item by kind: C++ instrument, C++ effect or pattern.
({IconData icon, Color color}) buildKindLook(AppState state, BuildTab tab) {
  if (tab.kind == BuildTabKind.cpp) {
    final c = state.cppComponent(tab.id);
    final instrument = c != null && cppIsInstrument(c.files.values);
    return instrument ? (icon: Icons.piano_outlined, color: Neon.green) : (icon: Icons.tune, color: Neon.pink);
  }
  return (icon: Icons.queue_music, color: Neon.yellow);
}
