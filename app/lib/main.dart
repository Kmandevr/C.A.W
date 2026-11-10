// Entry point: loads the settings, starts the app state (engine, audio, startup choice) and shows the shell.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model/app_state.dart';
import 'model/live_midi.dart';
import 'model/problem_log.dart';
import 'model/settings.dart';
import 'platform/midi_input.dart';
import 'ui/glass.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Open beta: errors are kept (on the device only) for "Report a problem", then handled as before.
  final flutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    ProblemLog.add(details.exception, details.stack);
    flutterError?.call(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    ProblemLog.add(error, stack);
    return false;
  };
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['JetBrains Mono'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  final settings = await Settings.open();
  final state = AppState(settings: settings);
  // One MIDI listener for the app's life, above the shell (which a theme change rebuilds).
  LiveMidi.current = LiveMidi(state, platformMidiInput());
  runApp(CawApp(state: state));
  state.init();
}

class CawApp extends StatelessWidget {
  const CawApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state.settings,
        builder: (context, _) => MaterialApp(
          title: 'C.A.W',
          debugShowCheckedModeBanner: false,
          themeAnimationDuration: Duration.zero, // theme edits repaint once, with no animation frames
          theme: Neon.theme(look: state.settings.activeTheme, compact: state.settings.compact),
          // The glass backdrop sits behind every route (glass off: the plain background).
          builder: (context, child) => GlassBackdrop(child: child ?? const SizedBox.shrink()),
          // A new key after a theme or glass change (including a profile that turns glass or blur off) rebuilds every screen, so colours fixed at build time repaint too.
          home: Shell(key: ValueKey((state.settings.lookRevision, Glass.active, Glass.blurChosen)), state: state),
        ),
      );
}
