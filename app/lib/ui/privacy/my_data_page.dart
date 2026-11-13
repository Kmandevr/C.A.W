// "My data" (beta readiness plan E5): every report this device made with its date, status and exact JSON, a copy
// of its public link and receipt, Check on server, Export my receipts and Delete my data. Receipts and delete keys
// exist only on this device.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../model/telemetry/telemetry.dart';
import '../../model/telemetry/telemetry_config.dart';
import '../../platform/save_copy.dart';
import '../haptics.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../theme.dart';
import 'privacy_pages.dart';

Future<void> showMyData(BuildContext context, Telemetry t) =>
    Navigator.of(context).push(panelRoute<void>(context, (_) => MyDataPage(telemetry: t)));

String statusLabel(ReportStatus s) => switch (s) {
      ReportStatus.queued => 'Queued',
      ReportStatus.sent => 'Sent',
      ReportStatus.published => 'Published',
      ReportStatus.rejected => 'Not accepted',
      ReportStatus.deleteRequested => 'Deletion asked',
      ReportStatus.notFound => 'Not on the server',
    };

Color statusColor(ReportStatus s) => switch (s) {
      ReportStatus.queued => Neon.yellow,
      ReportStatus.sent => Neon.blue,
      ReportStatus.published => Neon.green,
      ReportStatus.rejected || ReportStatus.notFound => Neon.pink,
      ReportStatus.deleteRequested => Neon.dim,
    };

class MyDataPage extends StatefulWidget {
  const MyDataPage({super.key, required this.telemetry, this.saveReceipts});
  final Telemetry telemetry;

  /// Saves the exported receipts (tests pass their own); the system's save picker by default.
  final Future<bool> Function(String json)? saveReceipts;

  @override
  State<MyDataPage> createState() => _MyDataPageState();
}

class _MyDataPageState extends State<MyDataPage> {
  bool _busy = false;
  String? _expanded;

  Telemetry get t => widget.telemetry;

  void _say(String text) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() => _run(() async {
        final n = await t.checkOnServer();
        if (!mounted) return;
        _say(n == null ? 'The server could not be reached. Try again later.' : 'Checked $n report${n == 1 ? '' : 's'}.');
      });

  Future<bool> _defaultSave(String json) async {
    final dir = await Directory.systemTemp.createTemp('caw-receipts');
    final f = File('${dir.path}${Platform.pathSeparator}caw-receipts.json');
    await f.writeAsString(json);
    try {
      return await saveCopyOf(f, name: 'caw-receipts.json', mimeType: 'application/json', extension: 'json');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<void> _export() async {
    // The warning comes before the save picker, so nobody saves the keys somewhere shared without knowing.
    final go = await showDialog<bool>(
      context: context,
      animationStyle: dialogAnimation(context),
      builder: (c) => AlertDialog(
        title: const Text('Export my receipts'),
        content: const Text('Keep this file private: its keys can delete your reports. Anyone who has it can ask '
            'the relay to delete them, so don\'t share it or save it to a shared folder.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('my-data-export-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Choose where to save')),
        ],
      ),
    );
    if (go != true) return;
    await _run(() async {
      final ok = await (widget.saveReceipts ?? _defaultSave)(t.exportReceipts());
      if (mounted && ok) _say('Receipts saved.');
    });
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      animationStyle: dialogAnimation(context),
      builder: (c) => AlertDialog(
        title: const Text('Delete my data?'),
        content: const Text('Every report this device sent is removed from C.A.W-Telemetry\'s files within about an '
            'hour, and anything waiting here is dropped.\n\nGit keeps a repository\'s history, and others may already '
            'have copied public files, so deleted reports can remain in its history and in earlier copies. They hold '
            'nothing about you, by design.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(
              key: const ValueKey('my-data-delete-confirm'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete', style: TextStyle(color: Neon.pink))),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final n = await t.deleteMyData();
      if (!mounted) return;
      _say(n == null
          ? 'The server could not be reached, so nothing was deleted there yet. Try again later.'
          : 'Deletion asked for $n report${n == 1 ? '' : 's'}.');
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('My data'), backgroundColor: Neon.panel),
        body: ListenableBuilder(
          listenable: t,
          builder: (context, _) {
            final reports = t.reports;
            final sent = reports.any((r) => r.status != ReportStatus.queued && r.status != ReportStatus.rejected);
            return ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 32), children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      key: const ValueKey('my-data-check'),
                      onPressed: _busy || !sent ? null : _check,
                      icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                      label: const Text('Check on server')),
                  OutlinedButton.icon(
                      key: const ValueKey('my-data-export'),
                      onPressed: _busy || reports.isEmpty ? null : _export,
                      icon: const Icon(Icons.file_download_outlined, size: 18),
                      label: const Text('Export my receipts')),
                  OutlinedButton.icon(
                      key: const ValueKey('my-data-delete'),
                      onPressed: _busy || reports.isEmpty ? null : _delete,
                      style: OutlinedButton.styleFrom(foregroundColor: Neon.pink),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete my data')),
                ]),
              ),
              AnimatedSize(
                duration: Motion.move(Motion.standard, Motion.of(context)),
                child: _busy ? const LinearProgressIndicator(minHeight: 2) : const SizedBox(width: double.infinity),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 10, 8, 4),
                child: Text('Receipts and delete keys exist only on this device. A reinstall loses them, so export them '
                    'to keep the ability to delete.', style: TextStyle(color: Neon.dim, fontSize: 12)),
              ),
              if (reports.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No reports yet. The first one is made the day after you start using C.A.W with telemetry on.',
                      style: TextStyle(color: Neon.dim)),
                ),
              for (final r in reports) _reportCard(context, r),
            ]);
          },
        ),
      );

  Widget _reportCard(BuildContext context, ReportRecord r) {
    final open = _expanded == r.receipt;
    final color = statusColor(r.status);
    return Card(
      key: ValueKey('report-${r.receipt}'),
      color: Neon.panel.withValues(alpha: 0.5),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text('${r.day} · ${r.kind == ReportKind.stress ? 'Benchmark' : 'Daily'}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            AnimatedContainer(
              duration: Motion.fade(Motion.standard, Motion.of(context)),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withValues(alpha: 0.6)),
              ),
              child: Text(statusLabel(r.status), style: TextStyle(color: color, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 2),
          Text(r.receipt, style: Neon.code(size: 11, color: Neon.dim)),
          Wrap(spacing: 4, children: [
            TextButton.icon(
              key: ValueKey('report-json-${r.receipt}'),
              onPressed: () {
                Haptics.tap();
                setState(() => _expanded = open ? null : r.receipt);
              },
              icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
              label: const Text('JSON'),
            ),
            TextButton.icon(
              key: ValueKey('report-repo-${r.receipt}'),
              onPressed: () => copyWithNote(context, reportRepoUrl(r.receipt),
                  'Link copied: open it in a browser. It appears within about an hour of sending.'),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open in repo'),
            ),
            TextButton.icon(
              key: ValueKey('report-copy-${r.receipt}'),
              onPressed: () => copyWithNote(context, r.receipt, 'Receipt ID copied'),
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy receipt ID'),
            ),
          ]),
          AnimatedSize(
            duration: Motion.move(Motion.panel, Motion.of(context)),
            alignment: Alignment.topCenter,
            child: open
                ? jsonBlock(
                    r.json.isEmpty
                        ? 'Older than ${Telemetry.keepJsonFor.inDays} days: only the receipt and its key are kept here. '
                            'The published copy is in the repository.'
                        : const JsonEncoder.withIndent('  ').convert(jsonDecode(r.json)),
                    key: ValueKey('json-${r.receipt}'))
                : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
  }
}
