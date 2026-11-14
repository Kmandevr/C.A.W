// Settings › About and beta: the version, What's new, Updates, Privacy (telemetry, what's sent, My data), Send feedback, Report a
// problem (a report copied to paste into an issue), Engine diagnostics, the Privacy Policy and Terms, and licences.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/problem_log.dart';
import '../../model/telemetry/telemetry.dart';
import '../../model/updates/update_service.dart';
import '../../version.dart';
import '../privacy/feedback_sheet.dart';
import '../privacy/privacy_pages.dart';
import '../startup_screen.dart' show openAlphaNotice;
import '../theme.dart';
import '../whats_new.dart';
import 'engine_diagnostics.dart';
import 'privacy_settings.dart';
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
            subtitle: 'C.A.W v$appVersion · $openAlphaNotice Projects are saved as you go.'),
        // The changelog, bundled (the sheet after an update shows this version's entry).
        settingAction('about.whatsNew',
            icon: Icons.new_releases_outlined, iconColor: Neon.violet, onTap: () => showWhatsNewPage(context)),
        // Updates (owner, 2026-11-12); where Settings opens without the app, an inert service that checks nothing.
        UpdateSettings(service: UpdateService.running ?? UpdateService.inert, state: deps.state),
        // Telemetry and feedback exist once the app has started them (not in Settings opened alone).
        settingAction('about.privacy',
            icon: Icons.privacy_tip_outlined, iconColor: Neon.green,
            subtitle: privacySummary(Telemetry.current),
            onTap: () => showPrivacyPage(context, deps)),
        settingAction('about.feedback',
            icon: Icons.rate_review_outlined, iconColor: Neon.blue,
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
