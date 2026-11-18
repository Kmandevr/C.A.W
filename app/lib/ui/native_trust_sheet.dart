// The Isolated / Trusted / Blocked sheet for a native component: "This plug-in can:" with a row per scan finding and declared capability, why it is blocked, and the pre-1.0.7 grace line.
import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../model/app_state.dart';
import '../model/arrange_fx.dart';
import '../model/capabilities.dart';
import '../model/cpp_component.dart';
import 'adaptive_sheet.dart';
import 'capability_text.dart';
import 'haptics.dart';
import 'motion.dart';
import 'theme.dart';

/// One row of the sheet: a capability the plug-in has (or declares), with its author's reason when declared.
class TrustRow {
  const TrustRow({required this.id, required this.normal, this.blocks = false, this.reason, this.sites = const []});
  final String id;

  /// Weighed as a notice: the row says "(normal)" and shows no risk.
  final bool normal;

  /// Used without being declared: the reason the component is blocked.
  final bool blocks;
  final String? reason;
  final List<String> sites;

  /// The rows for [scan] (when there is a build to scan), else for what the manifest [declared]: each declared
  /// capability with its reason and each other capability with a finding that isn't a plain notice.
  static List<TrustRow> rowsFor({ComponentScan? scan, List<CapabilityDeclaration> declared = const []}) {
    if (scan == null || !scan.ok) {
      return _ordered([for (final d in declared) TrustRow(id: d.id, normal: CapabilityText.of(d.id).normal, reason: d.reason, sites: d.sites)]);
    }
    final rows = <TrustRow>[];
    for (final d in scan.declared) {
      rows.add(TrustRow(id: d.id, normal: CapabilityText.of(d.id).normal, reason: d.reason, sites: d.sites));
    }
    final groups = <String, List<ScanFinding>>{};
    for (final f in scan.findings) {
      if (f.declared || (!f.warning && !f.blocks)) continue; // a plain notice, or covered by its declaration
      groups.putIfAbsent(f.capability, () => []).add(f);
    }
    for (final MapEntry(key: id, value: found) in groups.entries) {
      if (rows.any((r) => r.id == id)) continue;
      final blocks = found.any((f) => f.blocks) || scan.blockedBy.contains(id);
      rows.add(TrustRow(id: id, normal: !blocks && !found.any((f) => f.warning) && CapabilityText.of(id).normal, blocks: blocks));
    }
    return _ordered(rows);
  }

  // What blocks first, then the warnings, then the normal ones (each group in its own order), as the owner's layout.
  static List<TrustRow> _ordered(List<TrustRow> rows) {
    int rank(TrustRow r) => r.blocks ? 0 : r.normal ? 2 : 1;
    return [for (final k in [0, 1, 2]) ...rows.where((r) => rank(r) == k)];
  }
}

/// Asks Isolated / Trusted / Blocked for [name]. Rows come from [scan] when there is a build, else from what its
/// manifest [declared]. A blocked scan explains why and offers no Trusted. Isolated is shown but can't be chosen
/// until a separate-process host exists. Null: closed without a choice.
Future<NativeComponentTrust?> showNativeTrustSheet(BuildContext context,
        {required String name, ComponentScan? scan, List<CapabilityDeclaration> declared = const []}) =>
    showDialogOrSheet<NativeComponentTrust>(
      context: context,
      builder: (c) => NativeTrustSheet(name: name, scan: scan, declared: declared),
    );

/// The sheet for a project's C++ component waiting for the user's choice: this device's build of its sources is
/// scanned when there is one (with grace for a build trusted before 1.0.7), else its manifest's declarations are
/// shown; the choice is remembered for exactly this code (AppState.decideNativeTrust).
Future<void> askNativeTrust(BuildContext context, AppState state, CppComponentDoc component) async {
  ComponentScan? scan;
  try {
    scan = await state.nativeComponents?.scanBuild(component);
  } catch (_) {
    scan = null; // no engine library here: the manifest's list stands in
  }
  var declared = const <CapabilityDeclaration>[];
  try {
    declared = Capabilities.ofManifest(component.files['caw-component.json'] ?? '');
  } on FormatException {
    // An invalid list: its build fails and says why.
  }
  if (!context.mounted) return;
  final name = component.name.isEmpty ? component.componentId : component.name;
  final choice = await showNativeTrustSheet(context, name: name, scan: scan, declared: declared);
  if (choice == null || choice == NativeComponentTrust.isolated) return;
  await state.decideNativeTrust(component, trust: choice == NativeComponentTrust.trusted);
}

class NativeTrustSheet extends StatelessWidget {
  const NativeTrustSheet({super.key, required this.name, this.scan, this.declared = const []});
  final String name;
  final ComponentScan? scan;
  final List<CapabilityDeclaration> declared;

  bool get blocked => scan?.blocked ?? false;

  @override
  Widget build(BuildContext context) {
    final s = scan;
    final rows = TrustRow.rowsFor(scan: s, declared: declared);
    final blockedNames = <String>[
      if (s != null)
        for (final id in {...s.blockedBy, ...s.findings.where((f) => f.blocks).map((f) => f.capability)})
          CapabilityText.of(id).name,
    ];
    void choose(NativeComponentTrust t) {
      Haptics.tap();
      Navigator.of(context).pop(t);
    }

    return AlertDialog(
      key: const ValueKey('trust-sheet'),
      title: Text('Add "$name"'),
      scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (blocked)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s!.ok ? CapabilityText.blockedLine(blockedNames) : CapabilityText.blockedLine(const []),
              key: const ValueKey('trust-blocked-why'),
              style: const TextStyle(color: Neon.pink, fontSize: 12.5),
            ),
          ),
        if (s?.graceApplied ?? false)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(key: const ValueKey('trust-grace'), children: [
              const Icon(Icons.history, size: 15, color: Neon.yellow),
              const SizedBox(width: 6),
              const Expanded(child: Text(CapabilityText.graceLine, style: TextStyle(color: Neon.yellow, fontSize: 12))),
            ]),
          ),
        const Text(CapabilityText.sheetHeading, style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (rows.isEmpty)
          const Text(CapabilityText.nothingFound, key: ValueKey('trust-nothing'), style: TextStyle(color: Neon.dim, fontSize: 12))
        else
          for (final r in rows) _CapabilityRow(row: r, key: ValueKey('trust-row-${r.id}')),
      ]),
      actions: [
        Tooltip(
          message: CapabilityText.isolatedLater,
          child: OutlinedButton(key: const ValueKey('trust-isolated'), onPressed: null, child: const Text('Isolated')),
        ),
        if (!blocked)
          FilledButton(
            key: const ValueKey('trust-trusted'),
            onPressed: () => choose(NativeComponentTrust.trusted),
            child: const Text('Trusted'),
          ),
        OutlinedButton(
          key: const ValueKey('trust-blocked'),
          onPressed: () => choose(NativeComponentTrust.blocked),
          style: OutlinedButton.styleFrom(foregroundColor: Neon.pink),
          child: const Text('Blocked'),
        ),
      ],
    );
  }
}

class _CapabilityRow extends StatefulWidget {
  const _CapabilityRow({super.key, required this.row});
  final TrustRow row;

  @override
  State<_CapabilityRow> createState() => _CapabilityRowState();
}

class _CapabilityRowState extends State<_CapabilityRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final t = CapabilityText.of(r.id);
    final level = Motion.of(context);
    final color = r.blocks ? Neon.pink : r.normal ? Neon.dim : Neon.yellow;
    final reason = r.reason;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(r.normal ? t.icon : Icons.error_outline, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: t.can, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (r.normal) const TextSpan(text: '   ${CapabilityText.normalTag}', style: TextStyle(color: Neon.dim, fontSize: 12)),
            ])),
            if (!r.normal) Text(t.risk, style: const TextStyle(fontSize: 12, color: Neon.text)),
            if (reason != null)
              Text(
                '${CapabilityText.authorSays} "$reason"${r.sites.isEmpty ? '' : ' (${r.sites.join(', ')})'}',
                key: ValueKey('trust-reason-${r.id}'),
                style: const TextStyle(fontSize: 12, color: Neon.dim, fontStyle: FontStyle.italic),
              ),
            if (!r.normal) ...[
              InkWell(
                key: ValueKey('trust-why-${r.id}'),
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Haptics.tap();
                  setState(() => _open = !_open);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    AnimatedRotation(
                      turns: _open ? 0.25 : 0,
                      duration: Motion.move(Motion.standard, level),
                      child: const Icon(Icons.chevron_right, size: 16, color: Neon.blue),
                    ),
                    const Flexible(child: Text(CapabilityText.whyFold, style: TextStyle(fontSize: 12, color: Neon.blue))),
                  ]),
                ),
              ),
              // Folds open: grows and fades in at full motion, fades only when reduced, at once when off. (A size
              // transition, not AnimatedSize, which the phone sheet's intrinsic height can't lay out.)
              AnimatedSwitcher(
                duration: Motion.fade(Motion.standard, level),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: level == MotionLevel.full ? SizeTransition(sizeFactor: a, alignment: Alignment.topLeft, child: child) : child,
                ),
                child: _open
                    ? Padding(
                        key: ValueKey('trust-why-text-${r.id}'),
                        padding: const EdgeInsets.only(left: 16, bottom: 2),
                        child: Text(t.why, style: const TextStyle(fontSize: 12, color: Neon.dim)),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
