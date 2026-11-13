// What pressing Update does: for an older version, the honest warnings and a backup offer first; then the download
// with progress and Cancel, and the platform's install (or the download link where there is none).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/app_state.dart';
import '../../model/updates/releases.dart';
import '../../model/updates/update_fetch.dart';
import '../../model/updates/update_service.dart';
import '../adaptive_sheet.dart';
import '../theme.dart';

/// Copies [r]'s release page (where every download is) and says so.
Future<void> copyDownloadLink(BuildContext context, ReleaseInfo r) async {
  final link = r.page?.toString() ?? 'https://github.com/Kmandevr/C.A.W/releases';
  await Clipboard.setData(ClipboardData(text: link));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download link copied: $link')));
}

/// Installs [r] after the user pressed Update (the prompt, Update now, or a version picked in Install another
/// version). Nothing downloads or runs without that press.
Future<void> startUpdate(BuildContext context, UpdateService service, ReleaseInfo r, {AppState? state}) async {
  if (service.isDowngrade(r)) {
    final go = await showDowngradeWarning(context, service, r, state: state);
    if (go != true || !context.mounted) return;
  }
  if (assetFor(r, service.installer.platform) == null) {
    await copyDownloadLink(context, r);
    return;
  }
  final outcome = await showDialog<UpdateOutcomeView>(
    context: context,
    barrierDismissible: false,
    builder: (c) => _DownloadDialog(service: service, release: r),
  );
  if (outcome == null || !context.mounted) return;
  if (outcome.needsPermission) {
    final open = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Allow C.A.W to install updates'),
        content: const Text('Android asks you to allow "Install unknown apps" for C.A.W once. Turn it on, come back, '
            'and press Update again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open settings')),
        ],
      ),
    );
    if (open == true) await service.installer.openInstallPermission();
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(outcome.message), duration: const Duration(seconds: 8)));
}

/// What the download dialog ended with.
class UpdateOutcomeView {
  const UpdateOutcomeView(this.message, {this.needsPermission = false});
  final String message;
  final bool needsPermission;
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.service, required this.release});
  final UpdateService service;
  final ReleaseInfo release;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  final _cancel = DownloadCancel();
  int _got = 0, _total = -1;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    UpdateOutcomeView view;
    try {
      final o = await widget.service.downloadAndInstall(widget.release, cancel: _cancel, progress: (got, total) {
        if (mounted) {
          setState(() {
            _got = got;
            _total = total;
          });
        }
      });
      view = UpdateOutcomeView(o.message, needsPermission: o.needsPermission);
    } on DownloadCancelled {
      view = const UpdateOutcomeView('Download cancelled.');
    } catch (e) {
      view = UpdateOutcomeView('The update did not download ($e).');
    }
    if (mounted) Navigator.pop(context, view);
  }

  @override
  Widget build(BuildContext context) {
    final mb = (_got / 1048576).toStringAsFixed(1);
    final of = _total > 0 ? ' of ${(_total / 1048576).toStringAsFixed(1)} MB' : ' MB';
    return AlertDialog(
      title: Text('Downloading ${widget.release.label}'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LinearProgressIndicator(value: _total > 0 ? _got / _total : null),
        const SizedBox(height: 8),
        Text('$mb$of', style: const TextStyle(color: Neon.dim, fontSize: 12)),
      ]),
      actions: [
        TextButton(key: const ValueKey('update-cancel'), onPressed: _cancel.cancel, child: const Text('Cancel')),
      ],
    );
  }
}

/// Before an older version: what the platform allows, that newer projects may not open in it, and a backup.
/// True when the user goes on (never on Android, where the installer refuses it: there are steps instead).
Future<bool?> showDowngradeWarning(BuildContext context, UpdateService service, ReleaseInfo r, {AppState? state}) =>
    showDialogOrSheet<bool>(
      context: context,
      builder: (c) => _DowngradeSheet(service: service, release: r, state: state),
    );

class _DowngradeSheet extends StatefulWidget {
  const _DowngradeSheet({required this.service, required this.release, this.state});
  final UpdateService service;
  final ReleaseInfo release;
  final AppState? state;

  @override
  State<_DowngradeSheet> createState() => _DowngradeSheetState();
}

class _DowngradeSheetState extends State<_DowngradeSheet> {
  String? _backup;
  bool _backingUp = false;

  Future<void> _backUp() async {
    final s = widget.state;
    if (s == null) return;
    setState(() => _backingUp = true);
    final n = await s.backUpAllProjects();
    if (mounted) {
      setState(() {
        _backingUp = false;
        _backup = 'Restore points made for $n project${n == 1 ? '' : 's'}.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final android = widget.service.installer.refusesDowngrade;
    final r = widget.release;
    const dim = TextStyle(color: Neon.dim, fontSize: 13);
    return AlertDialog(
      title: Text('Go back to ${r.label}?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Projects saved by this version may not open in an older one. An older C.A.W refuses them '
              'and leaves the files as they are.'),
          const SizedBox(height: 10),
          if (android) ...[
            const Text('Android only installs an older version after C.A.W is uninstalled, and uninstalling deletes '
                'its data: projects, settings and restore points. C.A.W never uninstalls itself.'),
            const SizedBox(height: 8),
            const Text('1. Export each project you want to keep (Files › a project › Export project…).\n'
                '2. Copy the download link below and download the older APK.\n'
                '3. Uninstall C.A.W, then install the older APK.\n'
                '4. Import your exported projects.', style: dim),
          ] else ...[
            const Text('Windows: the older version is a zip of the app\'s files. Unzip it into a folder and run '
                'caw.exe; your projects and settings stay where they are.', style: dim),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('downgrade-backup'),
              onPressed: widget.state == null || _backingUp ? null : _backUp,
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Make restore points of all projects first'),
            ),
            if (_backup != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_backup!, style: dim)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        if (android)
          FilledButton(
              key: const ValueKey('downgrade-copy-link'),
              onPressed: () async {
                await copyDownloadLink(context, r);
                if (context.mounted) Navigator.pop(context, false);
              },
              child: const Text('Copy download link'))
        else
          FilledButton(
              key: const ValueKey('downgrade-continue'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Download')),
      ],
    );
  }
}
