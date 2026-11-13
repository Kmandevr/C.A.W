// Settings › About and beta › Privacy (beta readiness plan E3; the published policy's name for it): anonymous
// telemetry on or off, "Show exactly what's sent", My data, Send feedback, the Privacy Policy and Terms, and the public
// dashboard.
import 'package:flutter/material.dart';

import '../../model/telemetry/telemetry.dart';
import '../panel_motion.dart';
import '../privacy/feedback_sheet.dart';
import '../privacy/my_data_page.dart';
import '../privacy/privacy_pages.dart';
import '../theme.dart';
import 'settings_deps.dart';
import 'settings_widgets.dart';

/// The public dashboard of everything collected (the relay's own page).
const telemetryDashboardUrl = 'https://caw-telemetry.kmandevr.workers.dev/dashboard';

/// Opens the Privacy page.
Future<void> showPrivacyPage(BuildContext context, SettingsDeps deps, {Telemetry? telemetry}) => Navigator.of(context)
    .push(panelRoute<void>(context, (_) => PrivacyPage(deps: deps, telemetry: telemetry)));

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key, required this.deps, this.telemetry});
  final SettingsDeps deps;
  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Privacy'), backgroundColor: Neon.panel),
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            key: const ValueKey('privacy-page'),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
            child: PrivacySettings(deps: deps, telemetry: telemetry),
          ),
        ),
      );
}

/// The About and beta row's line for Privacy.
String privacySummary(Telemetry? t) => switch (t) {
      null => 'Anonymous telemetry, what\'s sent and My data',
      final t => [
          t.enabled ? 'Telemetry on' : 'Telemetry off',
          '${t.reports.length} report${t.reports.length == 1 ? '' : 's'}',
        ].join(' · '),
    };

class PrivacySettings extends StatelessWidget {
  const PrivacySettings({super.key, required this.deps, this.telemetry});
  final SettingsDeps deps;

  /// The app's telemetry ([Telemetry.current] when null). Without one (Settings opened alone) the rows that need it
  /// show but open nothing.
  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final t = telemetry ?? Telemetry.current;
    Widget rows() {
      final queued = t?.queued.length ?? 0;
      final reports = t?.reports.length ?? 0;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        settingSwitch(
          'privacy.telemetry',
          t?.enabled ?? false,
          t == null ? null : (v) => t.setEnabled(v),
          icon: Icons.insights_outlined,
          subtitle: [
            if (t == null)
              'Not running here'
            else if (t.enabled)
              'On: one report a day about how C.A.W runs on this device (and one per Benchmark run), published openly'
            else
              'Off: nothing is sent or kept',
            if (t != null && !t.config.canSend) 'This build has no relay set, so nothing can be sent',
          ].join('. '),
        ),
        settingAction('privacy.whatsSent',
            icon: Icons.data_object,
            subtitle: queued == 0 ? 'Nothing waiting; today\'s report so far' : '$queued waiting to be sent, and today\'s so far',
            onTap: t == null
                ? null
                : () => Navigator.of(context).push(panelRoute<void>(context, (_) => WhatsSentPage(telemetry: t)))),
        settingAction('privacy.myData',
            icon: Icons.receipt_long_outlined, iconColor: Neon.yellow,
            subtitle: reports == 0 ? 'No reports yet' : '$reports report${reports == 1 ? '' : 's'}: see, check, export or delete them',
            onTap: t == null ? null : () => showMyData(context, t)),
        settingAction('privacy.feedback',
            icon: Icons.rate_review_outlined, iconColor: Neon.pink,
            onTap: t == null ? null : () => showFeedbackSheet(context, t)),
        settingHeading('The texts'),
        settingAction('privacy.policy',
            icon: Icons.policy_outlined, iconColor: Neon.dim, onTap: () => showLegalText(context, LegalText.privacy)),
        settingAction('privacy.terms',
            icon: Icons.gavel_outlined, iconColor: Neon.dim, onTap: () => showLegalText(context, LegalText.terms)),
        settingAction('privacy.dashboard',
            icon: Icons.insert_chart_outlined, iconColor: Neon.blue,
            subtitle: 'Everything collected, from every device, at $telemetryDashboardUrl',
            trailing: const Icon(Icons.link),
            onTap: () => copyWithNote(context, telemetryDashboardUrl, 'Link copied: $telemetryDashboardUrl')),
      ]);
    }

    return t == null ? rows() : ListenableBuilder(listenable: t, builder: (_, _) => rows());
  }
}
