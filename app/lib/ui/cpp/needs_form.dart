// The "Needs" form on a C++ component's plug-in page: the capabilities it declares, each with its reason (and, for Internet, its sites), written into caw-component.json.
import 'package:flutter/material.dart';

import '../../model/capabilities.dart';
import '../../model/cpp_workbench.dart';
import '../adaptive_sheet.dart';
import '../capability_text.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';

/// One row being edited. [written] is what the manifest has for it (null: a new row not written yet).
class _NeedRow {
  _NeedRow(this.id, {CapabilityDeclaration? written})
      : written = written,
        reason = TextEditingController(text: written?.reason ?? ''),
        sites = TextEditingController(text: written?.sites.join(' ') ?? ''),
        focus = FocusNode();

  final String id;
  CapabilityDeclaration? written;
  final TextEditingController reason, sites;
  final FocusNode focus;
  String? error;

  List<String> get siteList =>
      sites.text.toLowerCase().split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();

  /// What this row declares as typed, or null with [error] set.
  CapabilityDeclaration? read() {
    final problem = Capabilities.reasonProblem(reason.text);
    if (problem != null) {
      error = 'Reason: $problem';
      return null;
    }
    final list = id == 'internet' ? siteList : const <String>[];
    if (list.length > Capabilities.maxSites) {
      error = 'At most ${Capabilities.maxSites} sites';
      return null;
    }
    final bad = list.where((s) => !Capabilities.validHost(s)).firstOrNull;
    if (bad != null) {
      error = '"$bad" is not a host name (like presets.example.com)';
      return null;
    }
    error = null;
    return CapabilityDeclaration(id, reason.text, list);
  }

  void dispose() {
    reason.dispose();
    sites.dispose();
    focus.dispose();
  }
}

/// Lists what [workbench]'s component declares it needs. "+ Add" picks a capability; each row's reason (1 to 200
/// characters, one line) and Internet's sites are written when a field is done (Enter or leaving it), one undo step
/// each; a row that breaks the rules says why on one line and isn't written.
class NeedsForm extends StatefulWidget {
  const NeedsForm({super.key, required this.workbench});
  final CppWorkbench workbench;

  @override
  State<NeedsForm> createState() => _NeedsFormState();
}

class _NeedsFormState extends State<NeedsForm> {
  final List<_NeedRow> _rows = [];
  List<CapabilityDeclaration> _synced = const [];

  CppWorkbench get w => widget.workbench;

  @override
  void initState() {
    super.initState();
    _sync();
    w.addListener(_onWorkbench);
  }

  @override
  void didUpdateWidget(NeedsForm old) {
    super.didUpdateWidget(old);
    if (old.workbench != w) {
      old.workbench.removeListener(_onWorkbench);
      w.addListener(_onWorkbench);
      _sync();
    }
  }

  @override
  void dispose() {
    w.removeListener(_onWorkbench);
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  bool _same(List<CapabilityDeclaration> a, List<CapabilityDeclaration> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  // The manifest changed from elsewhere (typed in the code, an undo): the rows follow it.
  void _onWorkbench() {
    if (!_same(w.needs, _synced)) setState(_sync);
  }

  // Rows leave the tree on the next build: their controllers go after that frame.
  void _disposeLater(Iterable<_NeedRow> rows) {
    final list = rows.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final r in list) {
        r.dispose();
      }
    });
  }

  void _sync() {
    _disposeLater(_rows);
    _rows
      ..clear()
      ..addAll([for (final d in w.needs) _NeedRow(d.id, written: d)]);
    _synced = w.needs;
  }

  /// Writes every row that reads well (a row that doesn't keeps what the manifest had for it).
  void _commit() {
    final list = <CapabilityDeclaration>[];
    for (final r in _rows) {
      final d = r.read() ?? r.written;
      if (d != null) list.add(d);
    }
    if (!_same(list, _synced) && w.setNeeds(list)) {
      for (final r in _rows) {
        if (r.error == null) r.written = list.where((d) => d.id == r.id).firstOrNull;
      }
      _synced = w.needs;
    }
    setState(() {});
  }

  Future<void> _add() async {
    Haptics.tap();
    final taken = _rows.map((r) => r.id).toSet();
    final id = await showDialogOrSheet<String>(
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('needs-picker'),
        title: const Text('What does it need?'),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final id in capabilityIds.where((id) => !taken.contains(id)))
            ListTile(
              key: ValueKey('needs-pick-$id'),
              dense: true,
              leading: Icon(CapabilityText.of(id).icon, size: 20),
              title: Text(CapabilityText.of(id).name),
              subtitle: Text(CapabilityText.of(id).does, style: const TextStyle(fontSize: 11.5, color: Neon.dim)),
              onTap: () => Navigator.of(c).pop(id),
            ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Cancel'))],
      ),
    );
    if (id == null || !mounted) return;
    final row = _NeedRow(id);
    setState(() => _rows.add(row));
    row.focus.requestFocus();
  }

  void _remove(_NeedRow r) {
    Haptics.tap();
    _rows.remove(r);
    _commit();
    _disposeLater([r]);
  }

  @override
  Widget build(BuildContext context) {
    final level = Motion.of(context);
    final problem = w.needsProblem;
    return Column(key: const ValueKey('needs-form'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('needs-add'),
          onPressed: _rows.length >= capabilityIds.length || problem != null ? null : _add,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add'),
        ),
      ),
      AnimatedSize(
        duration: Motion.move(Motion.panel, level),
        alignment: Alignment.topCenter,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(problem, key: const ValueKey('needs-problem'), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Neon.pink)),
            )
          else if (_rows.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(CapabilityText.needsEmpty, key: ValueKey('needs-empty'), style: TextStyle(fontSize: 11.5, color: Neon.dim)),
            ),
          for (final r in _rows) _row(r, level),
        ]),
      ),
    ]);
  }

  Widget _row(_NeedRow r, MotionLevel level) {
    final t = CapabilityText.of(r.id);
    InputDecoration deco(String hint) => InputDecoration(
          isDense: true,
          hintText: hint,
          counterText: '',
          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        );
    return Padding(
      key: ValueKey('needs-row-${r.id}'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 96,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(t.name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ),
        Expanded(
          child: Focus(
            onFocusChange: (has) {
              if (!has) _commit();
            },
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: ValueKey('needs-reason-${r.id}'),
                controller: r.reason,
                focusNode: r.focus,
                maxLines: 1,
                maxLength: Capabilities.maxReasonChars,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 12.5),
                decoration: deco(CapabilityText.reasonHint),
                onSubmitted: (_) => _commit(),
              ),
              if (r.id == 'internet')
                TextField(
                  key: const ValueKey('needs-sites'),
                  controller: r.sites,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  keyboardType: TextInputType.url,
                  style: Neon.code(size: 11.5, color: Neon.text),
                  decoration: deco(CapabilityText.sitesHint),
                  onSubmitted: (_) => _commit(),
                ),
              AnimatedSwitcher(
                duration: Motion.fade(Motion.standard, level),
                child: r.error == null
                    ? const SizedBox(width: double.infinity)
                    : Text(r.error!, key: ValueKey('needs-error-${r.id}'), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Neon.pink)),
              ),
            ]),
          ),
        ),
        IconButton(
          key: ValueKey('needs-remove-${r.id}'),
          tooltip: 'Remove ${t.name}',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => _remove(r),
        ),
      ]),
    );
  }
}
