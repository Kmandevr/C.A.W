// The plug-in page of one C++ component: the Write → Build → Test → Export pipeline with each step's status, one-line result and next button; Test, Export (CLAP, VST3) and Sample pack open the existing tool pages.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/build_tools.dart';
import '../../model/cpp_diagnostics.dart';
import '../../model/cpp_workbench.dart';
import '../../model/plugin_export.dart';
import '../../model/plugin_pipeline.dart';
import '../haptics.dart';
import '../theme.dart';
import 'plugin_export_screen.dart';
import 'sample_pack_screen.dart';
import 'test_suite_screen.dart';
import 'tool_kit.dart';
import '../panel_motion.dart';

/// Builds [w]; code from elsewhere asks "Trust and build" first (the editor's ▶ Build and the plug-in page share it).
Future<void> buildWithTrust(BuildContext context, CppWorkbench w) async {
  final ok = await w.build();
  if (ok || !context.mounted) return;
  final trust = await showDialog<bool>(
    context: context, animationStyle: dialogAnimation(context),
    builder: (c) => AlertDialog(
      title: const Text('Native code from elsewhere'),
      content: const Text('This effect came with the project, not from this device. Building runs it in the app '
          'as trusted code. Trust it and treat your edits as your own?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Trust and build')),
      ],
    ),
  );
  if (trust == true) await w.build(trustConfirmed: true);
}

/// Opens [w]'s plug-in page full screen. [onOpenCode] shows the code (at a problem when given) after the page closes.
Future<void> openPluginPage(BuildContext context, CppWorkbench w, {void Function(CppDiagnostic?)? onOpenCode}) =>
    openToolPage(context, PluginScreen(workbench: w, onOpenCode: onOpenCode));

extension PluginStepLook on PluginStepState {
  Color get color => switch (this) {
        PluginStepState.done => Neon.green,
        PluginStepState.warn => Neon.yellow,
        PluginStepState.failed => Neon.pink,
        PluginStepState.notRun => Neon.dim,
        PluginStepState.outdated => Neon.yellow,
        PluginStepState.running => Neon.blue,
      };
  String get label => switch (this) {
        PluginStepState.done => 'DONE',
        PluginStepState.warn => 'CHECK',
        PluginStepState.failed => 'FAILED',
        PluginStepState.notRun => 'NOT RUN',
        PluginStepState.outdated => 'OUT OF DATE',
        PluginStepState.running => 'RUNNING',
      };
  IconData get icon => switch (this) {
        PluginStepState.done => Icons.check_circle,
        PluginStepState.warn => Icons.error_outline,
        PluginStepState.failed => Icons.cancel,
        PluginStepState.notRun => Icons.radio_button_unchecked,
        PluginStepState.outdated => Icons.update,
        PluginStepState.running => Icons.autorenew,
      };
}

extension on PluginStepKind {
  String get title => switch (this) {
        PluginStepKind.write => 'Write',
        PluginStepKind.build => 'Build',
        PluginStepKind.test => 'Test',
        PluginStepKind.export => 'Export',
      };
  IconData get icon => switch (this) {
        PluginStepKind.write => Icons.code,
        PluginStepKind.build => Icons.construction,
        PluginStepKind.test => Icons.science_outlined,
        PluginStepKind.export => Icons.file_upload_outlined,
      };
}

class PluginScreen extends StatefulWidget {
  const PluginScreen({super.key, required this.workbench, this.onOpenCode, this.backend});
  final CppWorkbench workbench;

  /// Shows the code, at a problem when given (the page has closed first); without it the page only closes.
  final void Function(CppDiagnostic?)? onOpenCode;

  /// Where the test suite and the sample-pack maker send renders (the engine unless a test passes a fake).
  final BuildToolsBackend? backend;

  @override
  State<PluginScreen> createState() => PluginScreenState();
}

class PluginScreenState extends State<PluginScreen> {
  final _buildCard = GlobalKey();

  CppWorkbench get w => widget.workbench;

  void openCode([CppDiagnostic? at]) {
    Haptics.tap();
    Navigator.of(context).maybePop();
    widget.onOpenCode?.call(at);
  }

  Future<void> runBuild() async {
    Haptics.tap();
    await buildWithTrust(context, w);
  }

  Future<void> openTests() => openToolPage(context, TestSuiteScreen(workbench: w, backend: widget.backend));

  Future<void> openExport([PluginFormat format = PluginFormat.clap]) =>
      openToolPage(context, PluginExportScreen(workbench: w, format: format));

  Future<void> openSamplePack() => openToolPage(context, SamplePackScreen(state: w.state, instrumentId: w.componentId,
      backend: widget.backend, onRendered: (name) => w.recordExport('Sample pack', name)));

  /// What tapping a step (its card or its node in the strip) does: the step's page, or the build's own card.
  void openStep(PluginStepKind k) {
    switch (k) {
      case PluginStepKind.write:
        openCode(PluginPipeline(w).errors.firstOrNull);
      case PluginStepKind.build:
        final c = _buildCard.currentContext;
        if (c != null) unawaited(Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 200)));
      case PluginStepKind.test:
        unawaited(openTests());
      case PluginStepKind.export:
        unawaited(openExport());
    }
  }

  void runNext() {
    final p = PluginPipeline(w);
    switch (p.next) {
      case PluginNext.fixErrors:
        openCode(p.errors.firstOrNull);
      case PluginNext.build:
        unawaited(runBuild());
      case PluginNext.test || PluginNext.reviewTests:
        unawaited(openTests());
      case PluginNext.export:
        unawaited(openExport());
    }
  }

  static (String, IconData) nextLook(PluginPipeline p) => switch (p.next) {
        PluginNext.fixErrors => ('Fix ${p.errors.length == 1 ? 'the error' : '${p.errors.length} errors'}', Icons.code),
        PluginNext.build => (p.w.artifactPath == null ? 'Build' : 'Build again', Icons.play_arrow),
        PluginNext.test => ('Run the test suite', Icons.science_outlined),
        PluginNext.reviewTests => ('Review the failed tests', Icons.science_outlined),
        PluginNext.export => ('Export…', Icons.file_upload_outlined),
      };

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => unawaited(runBuild()),
          const SingleActivator(LogicalKeyboardKey.keyT, control: true): () => unawaited(openTests()),
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () => unawaited(openExport()),
          const SingleActivator(LogicalKeyboardKey.enter, control: true): runNext,
        },
        child: Focus(autofocus: true, child: ListenableBuilder(listenable: w, builder: (context, _) => _page(context))),
      );

  Widget _page(BuildContext context) {
    final p = PluginPipeline(w);
    final steps = p.steps;
    final building = w.phase == CppBuildPhase.building;
    final (nextLabel, nextIcon) = nextLook(p);
    const accent = Neon.violet;
    return ToolPage(
      title: 'Plug-in',
      subtitle: '${w.name} · ${w.isInstrument ? 'instrument' : 'effect'}',
      icon: Icons.extension_outlined,
      accent: accent,
      bottom: ToolAction(
        label: nextLabel,
        icon: nextIcon,
        color: accent,
        busyLabel: 'Building…',
        progress: building ? -1 : null,
        onPressed: runNext,
      ),
      children: [
        _Strip(steps: steps, next: p.nextStep, onTap: openStep),
        const SizedBox(height: 6),
        for (final (i, s) in steps.indexed)
          _StepCard(
            key: s.kind == PluginStepKind.build ? _buildCard : null,
            number: i + 1,
            step: s,
            isNext: s.kind == p.nextStep,
            onTap: () => openStep(s.kind),
            actions: _actions(s.kind, p, s.kind == p.nextStep),
            detail: _detail(s.kind, p),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Text('Ctrl+B builds, Ctrl+T opens the tests, Ctrl+E the export, Ctrl+Enter does the next step; Esc closes.',
              style: TextStyle(fontSize: 10.5, color: Neon.dim)),
        ),
      ],
    );
  }

  List<Widget> _actions(PluginStepKind k, PluginPipeline p, bool next) => switch (k) {
        PluginStepKind.write => [_StepButton('plugin-open-code', 'Open code', Icons.code, () => openCode(p.errors.firstOrNull), next && p.next == PluginNext.fixErrors)],
        PluginStepKind.build => [
            _StepButton('plugin-build', p.w.artifactPath == null ? 'Build' : 'Build again', Icons.play_arrow,
                p.w.phase == CppBuildPhase.building ? null : () => unawaited(runBuild()), next),
          ],
        PluginStepKind.test => [
            _StepButton('plugin-open-tests', p.testCurrent ? 'Open results' : 'Open test suite', Icons.science_outlined,
                p.w.artifactPath == null ? null : () => unawaited(openTests()), next),
          ],
        PluginStepKind.export => const [],
      };

  Widget? _detail(PluginStepKind k, PluginPipeline p) {
    switch (k) {
      case PluginStepKind.write || PluginStepKind.build:
        // The errors sit under the step that found them: the failed build, else the live check.
        final failedBuild = p.w.phase == CppBuildPhase.failed;
        if (p.errors.isEmpty || failedBuild != (k == PluginStepKind.build)) return null;
        return _errorList(p.errors);
      case PluginStepKind.export:
        final warning = p.exportWarning;
        final next = p.next == PluginNext.export;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (warning != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(key: const ValueKey('plugin-export-warning'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.warning_amber_rounded, size: 15, color: Neon.yellow),
                const SizedBox(width: 6),
                Expanded(child: Text(warning, style: const TextStyle(fontSize: 11.5, color: Neon.yellow))),
              ]),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _TargetTile(key: const ValueKey('plugin-target-clap'), label: 'CLAP', detail: 'Plug-in project', icon: Icons.extension_outlined,
                primary: next, onTap: () => unawaited(openExport(PluginFormat.clap))),
            _TargetTile(key: const ValueKey('plugin-target-vst3'), label: 'VST3', detail: 'Plug-in project', icon: Icons.extension_outlined,
                primary: false, onTap: () => unawaited(openExport(PluginFormat.vst3))),
            if (p.w.isInstrument)
              _TargetTile(key: const ValueKey('plugin-target-pack'), label: 'Sample pack', detail: 'WAVs + SFZ', icon: Icons.library_music_outlined,
                  primary: false, onTap: p.w.artifactPath == null ? null : () => unawaited(openSamplePack())),
          ]),
        ]);
      case PluginStepKind.test:
        return null;
    }
  }

  /// The first errors, each a tap from its line in the code.
  Widget _errorList(List<CppDiagnostic> errors) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, d) in errors.take(3).indexed)
          InkWell(
            key: ValueKey('plugin-error-$i'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => openCode(d),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                const Icon(Icons.subdirectory_arrow_right, size: 14, color: Neon.pink),
                const SizedBox(width: 4),
                Expanded(child: Text('${d.file.split('/').last}:${d.line}  ${d.message}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Neon.code(size: 11, color: Neon.text))),
              ]),
            ),
          ),
        if (errors.length > 3) Text('and ${errors.length - 3} more in Problems', style: const TextStyle(fontSize: 11, color: Neon.dim)),
      ]);
}

/// Write → Build → Test → Export at a glance: a node per step in its status colour, the next one glowing.
class _Strip extends StatelessWidget {
  const _Strip({required this.steps, required this.next, required this.onTap});
  final List<PluginStep> steps;
  final PluginStepKind next;
  final ValueChanged<PluginStepKind> onTap;

  @override
  Widget build(BuildContext context) {
    final nodes = <Widget>[];
    for (final (i, s) in steps.indexed) {
      if (i > 0) {
        nodes.add(Expanded(child: Container(
          height: 2,
          margin: const EdgeInsets.only(bottom: 16),
          color: (steps[i - 1].settled ? Neon.green : Neon.line).withValues(alpha: 0.7),
        )));
      }
      final c = s.state.color;
      final isNext = s.kind == next;
      nodes.add(GestureDetector(
        key: ValueKey('plugin-node-${s.kind.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          Haptics.tap();
          onTap(s.kind);
        },
        child: Tooltip(message: '${s.kind.title}: ${s.summary}', child: SizedBox(width: 64, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.withValues(alpha: s.state == PluginStepState.notRun ? 0.06 : 0.18),
              border: Border.all(color: isNext ? Neon.violet : c, width: isNext ? 2 : 1.2),
              boxShadow: [if (isNext) BoxShadow(color: Neon.violet.withValues(alpha: 0.5), blurRadius: 12)],
            ),
            child: Icon(s.state == PluginStepState.notRun ? s.kind.icon : s.state.icon, size: 18, color: c),
          ),
          const SizedBox(height: 4),
          Text(s.kind.title, style: TextStyle(fontSize: 11, fontWeight: isNext ? FontWeight.w800 : FontWeight.w600,
              color: isNext ? Neon.violet : Neon.text)),
        ]))),
      ));
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: nodes));
  }
}

/// A step as a frosted card: number and name, its status pill, the one-line result, details, and its buttons.
class _StepCard extends StatelessWidget {
  const _StepCard({super.key, required this.number, required this.step, required this.isNext, required this.onTap,
    required this.actions, this.detail});
  final int number;
  final PluginStep step;
  final bool isNext;
  final VoidCallback onTap;
  final List<Widget> actions;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    final s = step.state;
    return GestureDetector(
      key: ValueKey('plugin-step-${step.kind.name}'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.tap();
        onTap();
      },
      child: ToolCard(
        title: '$number · ${step.kind.title}',
        color: isNext ? Neon.violet : (s == PluginStepState.notRun ? Neon.line : s.color),
        trailing: _StateBadge(s, key: ValueKey('plugin-state-${step.kind.name}')),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(step.summary, key: ValueKey('plugin-summary-${step.kind.name}'), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: s == PluginStepState.failed ? Neon.pink : Neon.text)),
          if (detail != null) ...[const SizedBox(height: 8), detail!],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: actions),
          ],
        ]),
      ),
    );
  }
}

/// DONE / CHECK / FAILED / NOT RUN / OUT OF DATE / RUNNING as the kit's small glowing pill.
class _StateBadge extends StatelessWidget {
  const _StateBadge(this.state, {super.key});
  final PluginStepState state;

  @override
  Widget build(BuildContext context) {
    final c = state.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c),
        boxShadow: [if (state != PluginStepState.notRun) BoxShadow(color: c.withValues(alpha: 0.3), blurRadius: 8)]),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(state.icon, size: 12, color: c),
        const SizedBox(width: 4),
        Text(state.label, style: TextStyle(fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w800, color: c)),
      ]),
    );
  }
}

/// A step's button: filled in violet on the step that comes next, outlined otherwise.
class _StepButton extends StatelessWidget {
  const _StepButton(this.id, this.label, this.icon, this.onPressed, this.primary);
  final String id, label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
    final text = Text(label, style: TextStyle(fontSize: 12.5, fontWeight: primary ? FontWeight.w800 : FontWeight.w600,
        color: onPressed == null ? Neon.dim : (primary ? Neon.bg : Neon.text)));
    return SizedBox(height: 36, child: primary
        ? FilledButton.icon(key: ValueKey(id), onPressed: onPressed, icon: Icon(icon, size: 16), label: text,
            style: FilledButton.styleFrom(backgroundColor: Neon.violet, foregroundColor: Neon.bg, shape: shape))
        : OutlinedButton.icon(key: ValueKey(id), onPressed: onPressed, icon: Icon(icon, size: 16), label: text,
            style: OutlinedButton.styleFrom(foregroundColor: Neon.text, shape: shape, side: BorderSide(color: Neon.line))));
  }
}

/// An export target: CLAP, VST3 or a sample pack, as a tile that opens its page.
class _TargetTile extends StatelessWidget {
  const _TargetTile({super.key, required this.label, required this.detail, required this.icon, required this.primary,
    required this.onTap});
  final String label, detail;
  final IconData icon;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = onTap == null ? Neon.dim : (primary ? Neon.violet : Neon.text);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap == null ? null : () {
        Haptics.tap();
        onTap!();
      },
      child: Container(
        width: 140,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: primary ? Neon.violet.withValues(alpha: 0.16) : Colors.transparent,
          border: Border.all(color: primary ? Neon.violet : Neon.line),
          boxShadow: [if (primary) BoxShadow(color: Neon.violet.withValues(alpha: 0.3), blurRadius: 10)],
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: c)),
            Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Neon.dim)),
          ])),
        ]),
      ),
    );
  }
}
