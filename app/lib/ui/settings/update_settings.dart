// Settings › About › Updates: this version and the last check, Check now, Update now with the release notes, the
// channel, automatic checks, prompts and automatic updates, and Install another version (older ones too).
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/updates/releases.dart';
import '../../model/updates/update_service.dart';
import '../motion.dart';
import '../theme.dart';
import '../updates/update_flow.dart';
import 'settings_widgets.dart';

/// The privacy line under the Updates row (owner, 2026-11-12: say it plainly).
const String updatePrivacyNote = 'Checks GitHub Releases. The request carries nothing about you beyond what any web '
    'request does: your IP address and the app\'s generic name (CAW-app). It is not telemetry.';

String _date(DateTime d) {
  final l = d.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

class UpdateSettings extends StatelessWidget {
  const UpdateSettings({super.key, required this.service, this.state});
  final UpdateService service;
  final AppState? state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final s = service;
          final offer = s.offer;
          final level = Motion.of(context);
          final status = s.checking
              ? 'Checking…'
              : s.lastError != null
                  ? 'The last check failed: ${s.lastError}'
                  : offer != null
                      ? 'Update available: ${offer.label}'
                      : s.lastCheck != null
                          ? 'Up to date (checked ${_date(s.lastCheck!)})'
                          : 'Not checked yet';
          const dim = TextStyle(color: Neon.dim, fontSize: 12);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            settingHeading('Updates'),
            SettingRow(
              id: 'about.updates',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    const Icon(Icons.system_update_alt, color: Neon.green, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('This is v${s.current}${s.build.isEmpty ? '' : ' (${s.build})'}'),
                        Text(status, key: const ValueKey('update-status'), style: dim),
                      ]),
                    ),
                    TextButton(
                      key: const ValueKey('update-check-now'),
                      onPressed: s.checking ? null : s.check,
                      child: const Text('Check now'),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  const Text(updatePrivacyNote, style: dim),
                  AnimatedSize(
                    duration: Motion.move(Motion.standard, level),
                    alignment: Alignment.topCenter,
                    child: offer == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Text(offer.title.isEmpty ? offer.label : offer.title,
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              // "Update 4.7 MB instead of 54.5 MB" once a small update is known to fit.
                              AnimatedSwitcher(
                                duration: Motion.fade(Motion.standard, level),
                                child: Text(s.sizeLine(offer) ?? '',
                                    key: ValueKey('update-size:${s.sizeLine(offer)}'), style: dim),
                              ),
                              if (offer.notes.trim().isNotEmpty)
                                Container(
                                  key: const ValueKey('update-notes'),
                                  margin: const EdgeInsets.only(top: 6),
                                  constraints: const BoxConstraints(maxHeight: 160),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                      border: Border.all(color: Neon.line), borderRadius: BorderRadius.circular(6)),
                                  child: SingleChildScrollView(child: Text(offer.notes.trim(), style: dim)),
                                ),
                              const SizedBox(height: 6),
                              Wrap(spacing: 8, runSpacing: 4, children: [
                                FilledButton(
                                  key: const ValueKey('update-now-settings'),
                                  onPressed: () => startUpdate(context, s, offer, state: state),
                                  child: const Text('Update now'),
                                ),
                                TextButton(
                                  key: const ValueKey('update-copy-link'),
                                  onPressed: () => copyDownloadLink(context, offer),
                                  child: const Text('Copy download link'),
                                ),
                              ]),
                            ]),
                          ),
                  ),
                ]),
              ),
            ),
            _choiceRow(
              id: 'about.updates.channel',
              icon: Icons.alt_route,
              title: 'Update channel',
              note: Text(s.channel.description,
                  style: TextStyle(color: s.channel == UpdateChannel.everyChange ? Neon.pink : Neon.dim, fontSize: 12)),
              choice: DropdownButton<UpdateChannel>(
                key: const ValueKey('update-channel'),
                value: s.channel,
                isExpanded: true,
                items: [
                  for (final c in UpdateChannel.values) DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (c) {
                  if (c != null) s.setChannel(c);
                },
              ),
            ),
            settingSwitch('about.updates.check', s.auto, s.setAuto),
            settingSwitch('about.updates.prompts', s.prompts, s.setPrompts,
                subtitle: s.prompts ? null : 'Off: this row still shows an update when one is found'),
            if (s.channel == UpdateChannel.stable)
              _choiceRow(
                id: 'about.updates.install',
                icon: Icons.auto_mode,
                title: 'Automatic updates',
                note: Text('${s.autoLevel.description} Never an older version, and never while playing, recording or '
                    'rendering.', style: dim),
                choice: DropdownButton<AutoUpdateLevel>(
                  key: const ValueKey('update-auto-level'),
                  value: s.autoLevel,
                  isExpanded: true,
                  items: [
                    for (final l in AutoUpdateLevel.values) DropdownMenuItem(value: l, child: Text(l.label)),
                  ],
                  onChanged: (l) {
                    if (l != null) s.setAutoLevel(l);
                  },
                ),
              )
            else
              settingSwitch('about.updates.install', s.autoPreRelease, s.setAutoPreRelease,
                  subtitle: 'On ${s.channel.label}, automatic updates take the newest build of the channel, whatever '
                      'the step. Never while playing, recording or rendering.'),
            settingAction('about.updates.versions',
                icon: Icons.history, iconColor: Neon.violet,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => InstallAnotherVersionPage(service: s, state: state)))),
          ]);
        },
      );
}

/// A setting with a choice under its title (full width, so long choices fit a 360 dp phone) and a note.
Widget _choiceRow({required String id, required IconData icon, required String title, required Widget note, required Widget choice}) =>
    SettingRow(
      id: id,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: Neon.blue, size: 20)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title),
              choice,
              note,
            ]),
          ),
        ]),
      ),
    );

/// Every release of the channel, newest first, with its date, a badge for test builds, its notes and Install.
class InstallAnotherVersionPage extends StatefulWidget {
  const InstallAnotherVersionPage({super.key, required this.service, this.state});
  final UpdateService service;
  final AppState? state;

  @override
  State<InstallAnotherVersionPage> createState() => _InstallAnotherVersionPageState();
}

class _InstallAnotherVersionPageState extends State<InstallAnotherVersionPage> {
  bool _pre = false;

  @override
  void initState() {
    super.initState();
    if (widget.service.releases.isEmpty && !widget.service.checking) widget.service.check();
  }

  /// The releases listed: the channel's, or with the switch on a Stable install, the Beta channel's too.
  List<ReleaseInfo> get _list {
    final s = widget.service;
    final channel = _pre && s.channel == UpdateChannel.stable ? UpdateChannel.beta : s.channel;
    return releasesFor(s.releases, channel);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Install another version')),
        body: SafeArea(top: false, child: ListenableBuilder(
          listenable: widget.service,
          builder: (context, _) {
            final s = widget.service;
            final list = _list;
            return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              if (s.channel == UpdateChannel.stable)
                SwitchListTile(
                  key: const ValueKey('versions-prerelease'),
                  dense: true,
                  title: const Text('Show beta builds'),
                  subtitle: const Text('Tagged test builds of changes not yet public', style: TextStyle(color: Neon.dim)),
                  value: _pre,
                  onChanged: (v) => setState(() => _pre = v),
                ),
              if (s.checking) const LinearProgressIndicator(),
              if (!s.checking && list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(s.lastError == null ? 'No releases in this channel yet.' : 'The list did not load: ${s.lastError}',
                      style: const TextStyle(color: Neon.dim)),
                ),
              for (final r in list) _ReleaseTile(service: s, release: r, state: widget.state),
            ]);
          },
        )),
      );
}

class _ReleaseTile extends StatelessWidget {
  const _ReleaseTile({required this.service, required this.release, this.state});
  final UpdateService service;
  final ReleaseInfo release;
  final AppState? state;

  @override
  Widget build(BuildContext context) {
    final r = release;
    final v = r.version;
    final installed = v != null && v == service.current && (!r.rolling || r.build == service.build);
    final older = service.isDowngrade(r);
    final badges = [
      if (r.rolling) 'Every change' else if (v != null && v.stage == 'beta') 'Beta' else if (v != null && !v.isFull) 'Alpha',
      if (installed) 'Installed' else if (older) 'Older',
    ];
    return ExpansionTile(
      key: ValueKey('release-${r.tag}'),
      dense: true,
      title: Text(r.label),
      subtitle: Text([if (r.published != null) _date(r.published!), ...badges].join(' · '),
          style: const TextStyle(color: Neon.dim, fontSize: 12)),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (r.notes.trim().isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
                child: Text(r.notes.trim(), style: const TextStyle(color: Neon.dim, fontSize: 12))),
          ),
        Wrap(spacing: 8, children: [
          if (!installed)
            FilledButton(
              key: ValueKey('install-${r.tag}'),
              onPressed: () => startUpdate(context, service, r, state: state),
              child: Text(older ? 'Install this older version' : 'Install'),
            ),
          TextButton(onPressed: () => copyDownloadLink(context, r), child: const Text('Copy download link')),
        ]),
      ],
    );
  }
}

