// Keeps the app's startup prompts (the first-run page, the keep-telemetry question, What's new, the update prompt)
// one at a time, in that order, and never over the startup screen.
import 'package:flutter/widgets.dart';

import '../model/changelog.dart';
import '../model/settings.dart';
import '../model/telemetry/telemetry.dart';
import '../version.dart';
import 'privacy/privacy_pages.dart';
import 'whats_new.dart';

/// What the prompts wait for. [StartupGate] sets [startupInFront] while the startup screen shows (fading included);
/// a prompt sets [showing] while it is open. Each prompt opens only when [free], and listens to [changes] to try again.
/// Order: the first-run page, the keep question and What's new ([startupPrompts], run by Shell as one hold) come
/// first; the update prompt waits for them.
abstract final class AppPrompts {
  static final ValueNotifier<bool> startupInFront = ValueNotifier(false);
  static final ValueNotifier<bool> showing = ValueNotifier(false);

  /// Changes to either.
  static final Listenable changes = Listenable.merge([startupInFront, showing]);

  /// No startup screen in front and no prompt open.
  static bool get free => !startupInFront.value && !showing.value;

  /// Runs [prompt] with [showing] set; its result comes back once it has closed.
  static Future<T> run<T>(Future<T> Function() prompt) async {
    showing.value = true;
    try {
      return await prompt();
    } finally {
      showing.value = false;
    }
  }

  /// Runs [prompts] one after another as one hold of [showing], so no other prompt opens between them.
  static Future<void> runInOrder(List<Future<void> Function()> prompts) => run(() async {
        for (final p in prompts) {
          await p();
        }
      });
}

/// The startup prompts due at this launch, in order: the first-run page, the keep question after a beta build, then
/// What's new for an updated version. A fresh install (the first-run page due and no settings file yet) stores its
/// version without showing What's new; so does a downgrade. Each step checks [context] is still mounted.
List<Future<void> Function()> startupPrompts(BuildContext context, Telemetry t, Settings settings,
    {String version = appVersion, AssetLoader? load}) {
  final firstRun = t.firstRunNeeded, keep = t.askKeepNeeded;
  final due = whatsNewDue(
      lastSeen: settings.lastSeenVersion, current: version, freshInstall: firstRun && !settings.existedOnLoad);
  return [
    if (firstRun) () async {
      if (context.mounted) await showFirstRun(context, t);
    },
    if (keep) () async {
      if (context.mounted) await askKeepTelemetry(context, t);
    },
    if (due != WhatsNewDue.none) () async {
      if (context.mounted) await showWhatsNew(context, settings, due, version: version, load: load);
    },
  ];
}
