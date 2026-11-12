// Settings › About: the version, Updates, Report a problem (a report copied to paste into an issue), Engine
// diagnostics and licences.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/problem_log.dart';
import '../../model/updates/update_service.dart';
import '../../version.dart';
import '../theme.dart';
import 'engine_diagnostics.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';
import 'update_settings.dart';

class AboutSettings extends StatelessWidget {
  const AboutSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        settingAction('about.beta',
            icon: Icons.science_outlined, iconColor: Neon.yellow,
            subtitle: 'C.A.W open alpha $appVersion · things may change or break; projects are saved as you go'),
        // Updates (owner, 2026-11-12); where Settings opens without the app, an inert service that checks nothing.
        UpdateSettings(service: UpdateService.running ?? UpdateService.inert, state: deps.state),
        SettingRow(
          id: 'about.report',
          child: ListTile(
            key: const ValueKey('report-problem'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: const Icon(Icons.bug_report_outlined, color: Neon.pink, size: 20),
            title: const Text('Report a problem'),
            subtitle: Text('Copies a report (version, device, recent errors) to paste at $issuesUrl',
                style: const TextStyle(color: Neon.dim, fontSize: 12)),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: ProblemLog.report()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Report copied. Paste it into a new issue at $issuesUrl'),
                duration: const Duration(seconds: 6),
              ));
            },
          ),
        ),
        // Without the app (Settings opened alone: goldens, tests) the row shows but opens nothing.
        settingAction('about.diagnostics',
            icon: Icons.account_tree_outlined, iconColor: Neon.blue,
            subtitle: 'CPU, peaks, overloads, the master scope and spectrum, and each track\'s signal path',
            onTap: switch (deps.state) {
              final state? => () => showEngineDiagnostics(context, state),
              null => null,
            }),
        settingAction('about.licences',
            icon: Icons.description_outlined, iconColor: Neon.dim,
            subtitle: 'Including JetBrains Mono (SIL Open Font License 1.1)',
            onTap: () => showLicensePage(context: context, applicationName: 'C.A.W')),
      ]);
}
