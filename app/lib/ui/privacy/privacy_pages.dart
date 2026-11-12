// Privacy on screen (beta readiness plan E2, E3; owner's look 2026-11-12, "simple sheets"): the first-run page,
// "Show exactly what's sent", the once-only question after a beta build, and the bundled Privacy Policy and Terms.
// Settings › About and beta › Privacy itself is settings/privacy_settings.dart.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/telemetry/telemetry.dart';
import '../../model/telemetry/telemetry_config.dart';
import '../haptics.dart';
import '../motion.dart';
import '../panel_motion.dart';
import '../theme.dart';
import '../widgets.dart';

/// The bundled texts: copies of C.A.W-Telemetry's PRIVACY.md and TERMS.md, for reading offline.
enum LegalText {
  privacy('Privacy Policy', 'assets/legal/PRIVACY.md', privacyPolicyUrl),
  terms('Terms', 'assets/legal/TERMS.md', termsUrl);

  const LegalText(this.title, this.asset, this.url);
  final String title, asset, url;
}

/// Copies [text] and says so in one line.
void copyWithNote(BuildContext context, String text, String note) {
  Clipboard.setData(ClipboardData(text: text));
  Haptics.tap();
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(note), duration: const Duration(seconds: 4)));
}

/// Opens a bundled text as a page.
Future<void> showLegalText(BuildContext context, LegalText which) =>
    Navigator.of(context).push(panelRoute<void>(context, (_) => LegalTextPage(which: which)));

class LegalTextPage extends StatelessWidget {
  const LegalTextPage({super.key, required this.which, this.load});
  final LegalText which;

  /// Reads the asset (tests pass their own).
  final Future<String> Function(String asset)? load;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(which.title), backgroundColor: Neon.panel, actions: [
          IconButton(
            key: const ValueKey('legal-copy-link'),
            tooltip: 'Copy the link to the published text',
            icon: const Icon(Icons.link),
            onPressed: () => copyWithNote(context, which.url, 'Link copied: ${which.url}'),
          ),
        ]),
        body: FutureBuilder<String>(
          future: (load ?? rootBundle.loadString)(which.asset),
          builder: (context, snap) => AnimatedSwitcher(
            duration: Motion.fade(Motion.standard, Motion.of(context)),
            child: switch (snap.data) {
              final text? => SingleChildScrollView(
                  key: const ValueKey('legal-text'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  child: SelectableText(text, style: const TextStyle(fontSize: 14, height: 1.45)),
                ),
              null => const SizedBox.shrink(key: ValueKey('legal-loading')),
            },
          ),
        ),
      );
}

/// A short block of the first-run summary: a coloured icon, a heading and plain lines.
class _Point extends StatelessWidget {
  const _Point(this.icon, this.color, this.title, this.lines);
  final IconData icon;
  final Color color;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 4),
              for (final l in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(l, style: const TextStyle(color: Neon.dim, fontSize: 13, height: 1.35)),
                ),
            ]),
          ),
        ]),
      );
}

/// The first run (E2): one scrollable page, then Continue (= accepted). [telemetryOn] is the build's default.
class FirstRunPage extends StatelessWidget {
  const FirstRunPage({super.key, required this.telemetryOn, required this.onContinue});
  final bool telemetryOn;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          body: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: ListView(key: const ValueKey('first-run-list'), padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), children: [
                  const Text('Welcome to C.A.W', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(
                      telemetryOn
                          ? 'This early version sends anonymous performance and device data, so the developer can see how well '
                              'C.A.W runs on real devices. Nothing about you is collected.'
                          : 'This build can send anonymous performance and device data if you turn it on. It is off now.',
                      style: const TextStyle(fontSize: 14, height: 1.4)),
                  const SizedBox(height: 18),
                  const _Point(Icons.upload_outlined, Neon.green, 'What is sent', [
                    'Once a day: the device (maker, model, OS, CPU, memory, screen, audio setup) and the kinds of '
                        'peripherals in use (a USB MIDI keyboard\'s maker-given product name and ids), how well C.A.W runs '
                        '(CPU load, dropouts, frame and startup times), which built-in instruments, effects and screens you '
                        'use, project size as a range, and error types with the line of C.A.W code. Benchmark results each '
                        'time you run one.',
                  ]),
                  const _Point(Icons.block, Neon.pink, 'What is never sent', [
                    'Your projects or their names, audio, code, MIDI notes, file names or paths, your own components\' '
                        'names, any name you can set (your phone\'s or computer\'s name, a Bluetooth device\'s name, a '
                        'renamed port), serial numbers or hardware addresses, accounts, contact details, location, or any '
                        'ID that follows you.',
                  ]),
                  const _Point(Icons.public, Neon.blue, 'All of it is public', [
                    'Every report is published in github.com/Kmandevr/C.A.W-Telemetry. Each one has a receipt only your '
                        'device knows: see, check and delete your reports in Settings › About and beta › Privacy › My data.',
                    'Feedback you send is posted publicly there too; an email you add is never published.',
                  ]),
                  const _Point(Icons.toggle_off_outlined, Neon.yellow, 'Turning it off', [
                    'Settings › About and beta › Privacy, at any time. Off stops sending at once and deletes what is '
                        'waiting on this device.',
                  ]),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final t in LegalText.values)
                      TextButton.icon(
                        key: ValueKey('first-run-${t.name}'),
                        onPressed: () => showLegalText(context, t),
                        icon: const Icon(Icons.description_outlined, size: 18),
                        label: Text(t.title),
                      ),
                  ]),
                ]),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: Neon.line))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Continuing means you accept the Privacy Policy and Terms.',
                      textAlign: TextAlign.center, style: TextStyle(color: Neon.dim, fontSize: 12)),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const ValueKey('first-run-continue'),
                    onPressed: () {
                      Haptics.tap();
                      onContinue();
                    },
                    child: const Text('Continue'),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      );
}

/// Shows the first-run page over the app until Continue.
Future<void> showFirstRun(BuildContext context, Telemetry t) => Navigator.of(context).push(panelRoute<void>(
    context,
    (c) => FirstRunPage(
          telemetryOn: t.enabled,
          onContinue: () async {
            await t.acceptFirstRun();
            if (c.mounted) Navigator.of(c).pop();
          },
        )));

/// The first release launch after a beta build (E1): telemetry is off; asked once whether to turn it back on.
Future<void> askKeepTelemetry(BuildContext context, Telemetry t) async {
  final keep = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    animationStyle: dialogAnimation(context),
    builder: (c) => AlertDialog(
      title: const Text('Keep sending anonymous data?'),
      content: const Text('This is a release build, so telemetry is now off. The beta build sent anonymous performance and '
          'device data, published openly. Turn it back on to keep helping? You can change this in Settings › '
          'About and beta › Privacy.'),
      actions: [
        TextButton(key: const ValueKey('keep-off'), onPressed: () => Navigator.pop(c, false), child: const Text('Leave it off')),
        FilledButton(key: const ValueKey('keep-on'), onPressed: () => Navigator.pop(c, true), child: const Text('Turn it on')),
      ],
    ),
  );
  await t.answerKeep(keep ?? false);
}

/// "Show exactly what's sent": the queued reports' JSON as it will go, and today's report so far.
class WhatsSentPage extends StatelessWidget {
  const WhatsSentPage({super.key, required this.telemetry});
  final Telemetry telemetry;

  static const _pretty = JsonEncoder.withIndent('  ');

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("What's sent"), backgroundColor: Neon.panel),
        body: FutureBuilder<Map<String, Object?>?>(
          future: telemetry.previewToday(),
          builder: (context, snap) {
            final queued = telemetry.queued;
            return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: [
              Heading(queued.isEmpty ? 'Waiting to be sent: nothing' : 'Waiting to be sent (${queued.length})'),
              for (final r in queued) _JsonBlock(key: ValueKey('queued-${r.receipt}'), text: _pretty.convert(jsonDecode(r.json))),
              const Heading('Today so far (sent tomorrow; receipt made then)'),
              AnimatedSwitcher(
                duration: Motion.fade(Motion.standard, Motion.of(context)),
                child: switch (snap.data) {
                  final today? => _JsonBlock(key: const ValueKey('today'), text: _pretty.convert(today)),
                  null => Text(
                      key: const ValueKey('today-none'),
                      snap.connectionState == ConnectionState.done ? 'Telemetry is off: nothing is being collected.' : '',
                      style: const TextStyle(color: Neon.dim)),
                },
              ),
            ]);
          },
        ),
      );
}

class _JsonBlock extends StatelessWidget {
  const _JsonBlock({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Neon.panel.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Neon.line),
        ),
        child: SelectableText(text, style: Neon.code(size: 11)),
      );
}

/// The JSON block, for My data and the feedback form.
Widget jsonBlock(String text, {Key? key}) => _JsonBlock(key: key, text: text);
