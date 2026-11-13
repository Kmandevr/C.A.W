// Keeps the app's startup prompts (the first-run page, the keep-telemetry question, the update prompt) one at a time
// and never over the startup screen.
import 'package:flutter/foundation.dart';

/// What the prompts wait for. [StartupGate] sets [startupInFront] while the startup screen shows (fading included);
/// a prompt sets [showing] while it is open. Each prompt opens only when [free], and listens to [changes] to try again.
/// Order: the first-run page and the keep question (Shell) come first; the update prompt waits for them.
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
}
