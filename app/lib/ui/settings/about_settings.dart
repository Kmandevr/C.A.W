// Settings › About and beta: the version, Privacy (telemetry, My data), Send feedback, Report a problem (a report
// copied to paste into an issue), Engine diagnostics, the Privacy Policy and Terms, and licences.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/problem_log.dart';
import '../../model/telemetry/telemetry.dart';
import '../../version.dart';
import '../privacy/feedback_sheet.dart';
import '../privacy/privacy_pages.dart';
import '../theme.dart';
import 'engine_diagnostics.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

class AboutSettings extends StatelessWidget {
  const AboutSettings({super.key, required this.deps});
  final SettingsDeps deps;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        settingAction('about.beta',
            icon: Icons.science_outlined, iconColor: Neon.yellow,
            subtitle: 'C.A.W open beta $appVersion · things may change or break; projects are saved as you go'),
        // Telemetry and feedback exist once the app has started them (not in Settings opened alone).
        settingAction('about.privacy',
            icon: Icons.privacy_tip_outlined, iconColor: Neon.green,
            subtitle: switch (Telemetry.current) {
              final t? => t.enabled
                  ? 'Anonymous telemetry on · what\'s sent, My data'
                  : 'Anonymous telemetry off · what\'s sent, My data',
              null => 'Anonymous telemetry, what\'s sent and My data',
            },
            onTap: switch (Telemetry.current) {
              final t? => () => showPrivacyPage(context, t),
              null => null,
            }),
        settingAction('about.feedback',
            icon: Icons.rate_review_outlined, iconColor: Neon.blue,
            subtitle: 'A bug, an idea, something confusing or praise; posted publicly',
            onTap: switch (Telemetry.current) {
              final t? => () => showFeedbackSheet(context, t),
              null => null,
            }),
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
        settingAction('about.policy',
            icon: Icons.policy_outlined, iconColor: Neon.dim,
            onTap: () => showLegalText(context, LegalText.privacy)),
        settingAction('about.terms',
            icon: Icons.gavel_outlined, iconColor: Neon.dim,
            onTap: () => showLegalText(context, LegalText.terms)),
        settingAction('about.licences',
            icon: Icons.description_outlined, iconColor: Neon.dim,
            subtitle: 'Including JetBrains Mono (SIL Open Font License 1.1)',
            onTap: () => showLicensePage(context: context, applicationName: 'C.A.W')),
      ]);
}
